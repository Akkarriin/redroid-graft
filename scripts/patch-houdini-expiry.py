#!/usr/bin/env python3
"""Disable the built-in expiry failure branch in the pinned Houdini HPE 14 libs.

The patch is deliberately tied to exact input and output SHA-256 digests.  A
Houdini update must be reverse-engineered and added as a new variant instead of
silently applying an offset that may now point at unrelated code.
"""
from __future__ import annotations

import hashlib
import os
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Variant:
    name: str
    source_sha256: str
    patched_sha256: str
    offset: int
    original: bytes
    replacement: bytes


@dataclass
class Prepared:
    path: Path
    data: bytearray
    mode: int
    variant: Variant
    changed: bool


NOP6 = bytes.fromhex("90 90 90 90 90 90")
# 每个 libhoudini.so 里恰有一处 "cmp <到期状态>, 2; jae <失败分支>"，
# 改成 6 个 NOP。64 位偏移与 waydroid-helper 的 scripton.sh (issue #127) 一致；
# 32 位是同一结构的对应位置（waydroid-helper 只补 64 位）。
VARIANTS = (
    Variant(
        name="HPE 14.0.0_y.GoogleGame_com1.3 i386",
        source_sha256="bfdad39a4b658fdd7e03f2638d6ec314a8983ec7ec2cd55def510d31958d8489",
        patched_sha256="fa74f6f79ca55525e7ff057c03260ffa43eee905ea0320b5c2214829150452c8",
        offset=0x8A27A,
        original=bytes.fromhex("0f 83 0b 0d 00 00"),
        replacement=NOP6,
    ),
    Variant(
        name="HPE 14.0.0_z.GoogleGame_com1.3 x86_64",
        source_sha256="5ef64035ec89bca3d5e33b9f3b6556f98f6c11d11957387d403ae4a4d7cc40ec",
        patched_sha256="da7448b3531865034e0e36425f18c4b55bf70f632518a272d469804370c13232",
        offset=0xE61D5,
        original=bytes.fromhex("0f 83 68 0d 00 00"),
        replacement=NOP6,
    ),
    Variant(
        name="HPE 14.0.0_y.GoogleGame_com1.2 i386",
        source_sha256="f8df8ff7e4894feec7876135f88cb9b9f3e3c9a4221c909c9b45c35bc02f9866",
        patched_sha256="96fe3acce9aec00bf5d44a187e727aa6d1ef1cf29043c661fa26d4446044e993",
        offset=0x8A29A,
        original=bytes.fromhex("0f 83 0b 0d 00 00"),
        replacement=NOP6,
    ),
    Variant(
        name="HPE 14.0.0_z.GoogleGame_com1.2 x86_64",
        source_sha256="b321439df5a64ff29a62bb168303e58f800e94113c399f52795c42793f7f5f1e",
        patched_sha256="847be255d03886974ff0cff09d09b7530301d24671ce0f80172ab3a0629d23b8",
        offset=0xE6085,
        original=bytes.fromhex("0f 83 68 0d 00 00"),
        replacement=NOP6,
    ),
)


def sha256(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes | bytearray, mode: int) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as tmp:
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def prepare(path: Path, verify_original: bool) -> Prepared:
    data = bytearray(path.read_bytes())
    digest = sha256(data)
    mode = stat.S_IMODE(path.stat().st_mode)

    for variant in VARIANTS:
        if digest == variant.patched_sha256:
            if verify_original:
                raise RuntimeError(
                    f"{path}: {variant.name} is already patched, but original "
                    "Houdini was requested"
                )
            return Prepared(path, data, mode, variant, changed=False)
        if digest != variant.source_sha256:
            continue

        end = variant.offset + len(variant.original)
        found = bytes(data[variant.offset:end])
        if found != variant.original:
            raise RuntimeError(
                f"{path}: hash matched {variant.name}, but bytes at "
                f"{variant.offset:#x} are {found.hex()} (expected "
                f"{variant.original.hex()})"
            )
        if verify_original:
            return Prepared(path, data, mode, variant, changed=False)
        if len(variant.original) != len(variant.replacement):
            raise RuntimeError(f"{variant.name}: in-place patch changes file size")

        data[variant.offset:end] = variant.replacement
        result = sha256(data)
        if result != variant.patched_sha256:
            raise RuntimeError(
                f"{path}: patched SHA-256 is {result}, expected "
                f"{variant.patched_sha256}"
            )
        return Prepared(path, data, mode, variant, changed=True)

    known = "\n  ".join(
        f"{v.name}: original={v.source_sha256}, patched={v.patched_sha256}"
        for v in VARIANTS
    )
    raise RuntimeError(
        f"{path}: unsupported libhoudini.so SHA-256 {digest}; refusing an "
        f"unsafe offset-only patch. Known files:\n  {known}"
    )


def main() -> int:
    args = sys.argv[1:]
    verify_original = bool(args and args[0] == "--verify-original")
    if verify_original:
        args = args[1:]
    if not args:
        print(
            f"usage: {Path(sys.argv[0]).name} [--verify-original] "
            "LIBHOUDINI.SO [...]",
            file=sys.stderr,
        )
        return 2

    try:
        # Validate every input before writing either ABI, so an unknown second
        # file cannot leave a half-patched staging tree.
        prepared = [prepare(Path(arg), verify_original) for arg in args]
        for item in prepared:
            if item.changed:
                atomic_write(item.path, item.data, item.mode)
                print(
                    f"patched: {item.variant.name}: {item.path} "
                    f"@{item.variant.offset:#x} "
                    f"sha256={item.variant.patched_sha256}"
                )
            else:
                state = "verified original" if verify_original else "already patched"
                print(
                    f"{state}: {item.variant.name}: {item.path} "
                    f"sha256={sha256(item.data)}"
                )
    except (OSError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
