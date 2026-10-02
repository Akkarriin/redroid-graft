#!/usr/bin/env python3
"""按 Android 链接器命名空间校验搬运进 /vendor 的二进制的依赖闭包和符号.

原先的检查只看 DT_NEEDED 的文件名在 system/ 或 vendor/ 下是否存在, 会漏掉:
  - 文件在 /system/lib* 里, 但 vendor/sphal 命名空间看不到 (非 LLNDK/VNDK)
  - 名字对上了, 但对方不导出所需符号 (ABI 不匹配)
  - 位数/架构不对的同名库 (例如 /system/lib64/arm64 下的 ARM 副本)

命名空间模型 (Android 13, 与 linkerconfig 的 vendor/sphal 配置一致):
  sphal  (EGL/GLES/Vulkan/mapper 在 system 进程里 dlopen):
         /odm/${LIB}, /vendor/${LIB}  + VNDK-SP + LLNDK
  vendor (/vendor/bin 下的服务进程, 如 allocator@4.0):
         /odm/${LIB}, /vendor/${LIB}  + VNDK(core/sp/private) + LLNDK

用法: check-vendor-closure.py BASE_ROOT LAYER_ROOT
  BASE_ROOT  基础镜像的 rootfs (至少含 system/lib*, system/apex/*vndk*,
             system/apex/com.android.runtime, vendor/lib*, odm/lib*)
  LAYER_ROOT 本层要 ADD 进镜像的目录 (含 vendor/...)
层内文件优先于基础镜像 (ADD 覆盖语义). 只检查层内新增/覆盖的文件.
"""
from __future__ import annotations

import atexit
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from functools import lru_cache
from pathlib import Path

ARCH = {"lib": ("ELF32", "Intel 80386"), "lib64": ("ELF64", "Advanced Micro Devices X86-64")}


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(2)


def find_vndk_apex(base: Path) -> Path | None:
    cands = [c for c in sorted(base.glob("system/apex/com.android.vndk.*")) if c.is_dir()]
    return cands[0] if cands else None


_APEX_CACHE: dict[str, Path | None] = {}
_TMP = Path(tempfile.mkdtemp(prefix="vendor-closure-"))
atexit.register(shutil.rmtree, _TMP, True)


def apex_dir(root: Path, name: str) -> Path | None:
    """展开的 apex 直接用目录; 未展开 (Android 15) 则从 .apex 里解出 payload."""
    d = root / "system/apex" / name
    if d.is_dir():
        return d
    key = f"{root}:{name}"
    if key in _APEX_CACHE:
        return _APEX_CACHE[key]
    out = None
    for ext in (".apex", ".capex"):
        f = root / "system/apex" / (name + ext)
        if not f.is_file():
            continue
        try:
            with zipfile.ZipFile(f) as z:
                if ext == ".capex":  # 压缩 apex 里还套着一层 .apex
                    inner = _TMP / f"{name}.apex"
                    inner.write_bytes(z.read("original_apex"))
                    z = zipfile.ZipFile(inner)
                img = _TMP / f"{name}.img"
                img.write_bytes(z.read("apex_payload.img"))
        except (KeyError, zipfile.BadZipFile):
            break
        out = _TMP / name
        out.mkdir()
        subprocess.run(["debugfs", "-R", f"rdump / {out}", str(img)],
                       capture_output=True, check=False)
        img.unlink()
        break
    _APEX_CACHE[key] = out
    return out


def in_root(root: Path, rel: str, depth: int = 0) -> Path | None:
    """在 root 内解析 rel; 绝对路径的符号链接 (如 /apex/...) 按镜像根解释."""
    parts = Path(rel).parts
    if len(parts) > 2 and parts[:2] == ("system", "apex"):
        d = apex_dir(root, parts[2])
        if d is None:
            return None
        p = d.joinpath(*parts[3:])
        return p if p.is_file() else None
    p = root / rel
    if p.is_symlink() and depth < 8:
        t = os.readlink(p)
        nxt = t.lstrip("/") if t.startswith("/") else str(Path(rel).parent / t)
        if nxt.startswith("apex/"):  # apex 实体在 system/apex 下
            nxt = "system/" + nxt
        return in_root(root, os.path.normpath(nxt), depth + 1)
    return p if p.is_file() else None


def read_list(p: Path) -> set[str]:
    return {ln.strip() for ln in p.read_text().splitlines() if ln.strip() and not ln.startswith("#")}


class Image:
    def __init__(self, base: Path, layer: Path):
        self.base, self.layer = base, layer
        self.vndk_apex = find_vndk_apex(base)
        if self.vndk_apex is not None:
            # Android 13/14: VNDK apex 自带 llndk/vndksp/vndkcore 列表
            etc = self.vndk_apex / "etc"

            def lst(kind: str) -> set[str]:
                fs = sorted(etc.glob(f"{kind}.libraries.*.txt"))
                if not fs:
                    die(f"缺少 {etc}/{kind}.libraries.*.txt")
                return read_list(fs[0])

            self.llndk = lst("llndk")
            self.vndksp = lst("vndksp")
            self.vndk_all = self.vndksp | lst("vndkcore") | lst("vndkprivate")
        else:
            # Android 15+: VNDK 已弃用, vendor 自带 libbase 等, 只链 LLNDK
            f = base / "system/etc/llndk.libraries.txt"
            if not f.is_file():
                die(f"基础镜像里既没有 VNDK apex, 也没有 {f}")
            self.llndk = read_list(f)
            self.vndksp = self.vndk_all = set()

    def pick(self, rel: str) -> Path | None:
        for root in (self.layer, self.base):
            p = in_root(root, rel)
            if p:
                return p
        return None

    def show(self, p: Path) -> str:
        for tag, root in (("layer", self.layer), ("base", self.base)):
            if root in p.parents:
                return f"{tag}:/{p.relative_to(root)}"
        return str(p)

    def ns_of(self, path: Path, ns: str) -> str:
        """依赖解析跨出 vendor 后, 继续在对方所属的命名空间里解析."""
        if self.vndk_apex is not None and self.vndk_apex in path.parents:
            return "vndk"
        for root in (self.layer, self.base):
            for d in ("vendor", "odm"):
                if (root / d) in path.parents:
                    return ns
        return "system"

    def resolve(self, name: str, lib: str, ns: str) -> Path | None:
        if ns == "system":
            # 系统侧库的依赖不在本层控制范围, 只为符号检查找到实体
            for rel in (f"system/{lib}/{name}",
                        f"system/apex/com.android.runtime/{lib}/bionic/{name}"):
                p = in_root(self.base, rel)
                if p:
                    return p
            for a in sorted((self.base / "system/apex").iterdir()):
                n = a.name.removesuffix(".apex").removesuffix(".capex")
                p = in_root(self.base, f"system/apex/{n}/{lib}/{name}")
                if p:
                    return p
            return None
        if ns == "vndk" and self.vndk_apex is not None:
            p = self.vndk_apex / lib / name
            if p.is_file():
                return p
            return self.resolve(name, lib, "system") if name in self.llndk else None
        for d in (f"odm/{lib}", f"vendor/{lib}"):
            p = self.pick(f"{d}/{name}")
            if p:
                return p
        vndk = self.vndksp if ns == "sphal" else self.vndk_all
        if name in vndk and self.vndk_apex is not None:
            p = self.vndk_apex / lib / name
            return p if p.is_file() else None
        if name in self.llndk:
            for rel in (f"system/{lib}/{name}",
                        f"system/apex/com.android.runtime/{lib}/bionic/{name}"):
                p = in_root(self.base, rel)
                if p:
                    return p
        return None


@lru_cache(maxsize=None)
def elf_header(path: Path) -> tuple[str, str]:
    out = subprocess.run(["readelf", "-hW", str(path)], capture_output=True, text=True).stdout
    cls = re.search(r"Class:\s+(\S+)", out)
    mach = re.search(r"Machine:\s+(.+)", out)
    return (cls.group(1) if cls else "?", mach.group(1).strip() if mach else "?")


@lru_cache(maxsize=None)
def needed(path: Path) -> tuple[str, ...]:
    out = subprocess.run(["readelf", "-dW", str(path)], capture_output=True, text=True).stdout
    return tuple(re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out))


@lru_cache(maxsize=None)
def dynsyms(path: Path) -> tuple[frozenset[str], frozenset[str]]:
    """返回 (定义的符号, 强未定义符号). 去掉 @VERSION 后缀."""
    out = subprocess.run(["readelf", "-W", "--dyn-syms", str(path)],
                         capture_output=True, text=True).stdout
    defined, undef = set(), set()
    for ln in out.splitlines():
        # x86 的 IFUNC (memcpy 等) 显示为 "<OS specific>: 10", 先归一化再分列
        f = re.sub(r"<[^>]*>:\s*\d+", "IFUNC", ln).split()
        # Num: Value Size Type Bind Vis Ndx Name
        if len(f) < 8 or not f[0].endswith(":") or not f[0][:-1].isdigit():
            continue
        typ, bind, ndx, name = f[3], f[4], f[6], f[7]
        name = name.split("@", 1)[0]
        if not name or typ in ("FILE", "SECTION"):
            continue
        if ndx == "UND":
            if bind == "GLOBAL":
                undef.add(name)
        elif bind in ("GLOBAL", "WEAK", "UNIQUE", "GNU_UNIQUE"):
            defined.add(name)
    return frozenset(defined), frozenset(undef)


def check_root(img: Image, root: Path, lib: str, ns: str, errors: list[str]) -> None:
    rel = root.relative_to(img.layer)
    want_cls, want_mach = ARCH[lib]
    closure: dict[str, Path] = {}
    queue = [(root, ns)]
    while queue:
        cur, cur_ns = queue.pop()
        cls, mach = elf_header(cur)
        if (cls, mach) != (want_cls, want_mach):
            errors.append(f"{rel}: {img.show(cur)} 是 {cls}/{mach}, 期望 {want_cls}/{want_mach}")
            continue
        for dep in needed(cur):
            if dep in closure:
                continue
            p = img.resolve(dep, lib, cur_ns)
            if p is None:
                if cur_ns in ("sphal", "vendor"):
                    errors.append(f"{rel} ({cur_ns}): 依赖 {dep} 在命名空间内不可见"
                                  f" (需要者 {cur.name})")
                continue
            closure[dep] = p
            queue.append((p, img.ns_of(p, cur_ns)))

    defined: set[str] = set(dynsyms(root)[0])
    for p in closure.values():
        defined |= dynsyms(p)[0]
    # 只检查本层带进来的库; 基础镜像自身的库默认可信
    for p in [root, *closure.values()]:
        if img.layer not in p.parents:
            continue
        missing = sorted(dynsyms(p)[1] - defined)
        if missing:
            more = f" 等 {len(missing)} 个" if len(missing) > 5 else ""
            errors.append(f"{rel} ({ns}): {p.name} 有未解析符号 "
                          f"{', '.join(missing[:5])}{more}")


def main() -> int:
    if len(sys.argv) != 3:
        die(__doc__ or "")
    base, layer = Path(sys.argv[1]), Path(sys.argv[2])
    img = Image(base, layer)
    errors: list[str] = []
    n = 0
    for lib in ("lib", "lib64"):
        d = layer / "vendor" / lib
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*.so")):
            check_root(img, p, lib, "sphal", errors)
            n += 1
    for p in sorted((layer / "vendor" / "bin").rglob("*")):
        if p.is_file() and elf_header(p)[0] != "?":
            lib = "lib64" if elf_header(p)[0] == "ELF64" else "lib"
            check_root(img, p, lib, "vendor", errors)
            n += 1
    # 同一缺失往往被多个根重复报告, 去重后输出
    seen: set[str] = set()
    for e in errors:
        if e not in seen:
            seen.add(e)
            print(f"  !! {e}", file=sys.stderr)
    if errors:
        print(f"依赖/符号校验失败: {len(seen)} 项 (检查了 {n} 个 ELF)", file=sys.stderr)
        return 1
    print(f"依赖闭包与符号校验通过 ({n} 个 ELF, 命名空间 sphal/vendor)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
