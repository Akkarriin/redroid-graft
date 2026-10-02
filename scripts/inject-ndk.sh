#!/bin/bash
# 在 gralloc4 底图上注入 waydroid-helper 的 libndk_translation（默认 zork R136）
# 配方对齐 waydroid-helper/extensions 的 ndk_translation-chromeos_zork R136
#
# 已知坑（本脚本已避开）:
# 1. 只 patch native-bridge 相关 prop（图形栈属性由嫁接版 gpu_config.sh 开机设置）
# 2. redroid 的 init `copy` 写 /proc/sys/fs/binfmt_misc/register 常失败
#    → 改用 exec+cat（与 houdini.rc 同思路）
# 3. 勿叠在已注入 houdini 的镜像上（binfmt/桥会打架）；默认底图是 redroid13-graft
# 4. redroid userdebug 自带 /system/xbin/su → 默认白盒删除（可 KEEP_SU=1 保留）
# 5. ld.config 的 arm64/libtcb 补丁是 houdini 专用，ndk 不需要那套
#
# 用法:
#   ./scripts/gralloc4.sh
#   ./scripts/inject-ndk.sh
#   BASE_IMAGE=localhost/redroid13-graft-ndk:latest \
#   NEW_IMAGE=localhost/redroid13-graft-ndk-gapps:latest \
#   ./scripts/inject-gapps.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
SRC="$HERE/src/ndk"
OUT="$HERE/out"
CTR=${CTR:-podman}

BASE_IMAGE="${BASE_IMAGE:-localhost/redroid13-graft:latest}"
NEW_IMAGE="${NEW_IMAGE:-localhost/redroid13-graft-ndk:latest}"
KEEP_SU="${KEEP_SU:-0}"

# waydroid-helper EXTENSION: ndk_translation-chromeos_zork R136-16238.47.0
NDK_NAME="ndk_translation-chromeos_zork"
NDK_VER="R136-16238.47.0"
NDK_REPO="vendor_google_proprietary_ndk_translation-prebuilt"
NDK_COMMIT="68734c52556d3d7a6db34c603dd9276915c29f2f"
NDK_ZIP="$DL/${NDK_NAME}-${NDK_VER}.zip"
NDK_URL="https://github.com/supremegamers/${NDK_REPO}/archive/${NDK_COMMIT}.zip"
NDK_SHA="a142d1586c9eafb5edf62277110f2128bc03066179a6783bcaa33ee322e1cbd0"

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

if ! $CTR image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "错误: 找不到底图 $BASE_IMAGE" >&2
    echo "请先: ./scripts/gralloc4.sh" >&2
    exit 1
fi

# 若底图已是 houdini 变体，给出明确警告（仍允许强制）
case "$BASE_IMAGE" in
    *houdini*)
        if [ "${FORCE_ON_HOUDINI:-0}" != 1 ]; then
            echo "错误: 底图含 houdini（$BASE_IMAGE）。请用 redroid13-graft:latest，" >&2
            echo "或 FORCE_ON_HOUDINI=1 强制（不推荐，binfmt 易冲突）。" >&2
            exit 1
        fi
        ;;
esac

fetch() {
    local url=$1 sha=$2 dest=$3 tmp="${3}.part"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
        msg "已缓存 $(basename "$dest")"
        return
    fi
    msg "下载 $(basename "$dest")"
    rm -f "$tmp"
    curl -fL --retry 3 -o "$tmp" "$url"
    [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$sha" ] || {
        rm -f "$tmp"; echo "sha256 校验失败: $dest" >&2; exit 1; }
    mv -f "$tmp" "$dest"
}

copy_from_base() { # path-in-image dest
    local src=$1 dest=$2 cid
    cid=$($CTR create "$BASE_IMAGE")
    if ! $CTR cp "$cid:$src" "$dest"; then
        $CTR rm -f "$cid" >/dev/null 2>&1 || true
        return 1
    fi
    $CTR rm "$cid" >/dev/null
}

mkdir -p "$DL" "$OUT"
rm -f "$OUT/ndk.tar" "$OUT/Dockerfile.ndk"
rm -rf "$SRC"; mkdir -p "$SRC/layer" "$SRC/extract"

fetch "$NDK_URL" "$NDK_SHA" "$NDK_ZIP"

msg "解包 $NDK_NAME ($NDK_VER)"
unzip -oq "$NDK_ZIP" -d "$SRC/extract"
PRE="$SRC/extract/${NDK_REPO}-${NDK_COMMIT}/prebuilts"
[ -d "$PRE" ] || { echo "zip 里找不到 prebuilts/" >&2; find "$SRC/extract" -maxdepth 3 -type d | head -40 >&2; exit 1; }

mkdir -p "$SRC/layer/system"
cp -a "$PRE/." "$SRC/layer/system/"

# 权限: 目录 755；bin 下可执行；其余文件 644
find "$SRC/layer" -type d -exec chmod 755 {} +
find "$SRC/layer" -type f -exec chmod 644 {} +
find "$SRC/layer/system/bin" -type f -exec chmod 755 {} + 2>/dev/null || true

# 坑: 用 exec+cat 注册 binfmt，避免 init copy 写 /proc 失败
msg "写入可靠的 ndk_translation.rc（exec+cat）"
mkdir -p "$SRC/layer/system/etc/init"
cat > "$SRC/layer/system/etc/init/ndk_translation.rc" <<'EOF'
# waydroid-helper ndk_translation; binfmt via exec (redroid-safe)
on early-init
    mount binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc

on property:ro.enable.native.bridge.exec=1
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm_exe > /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm_dyn > /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm64_exe > /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm64_dyn > /proc/sys/fs/binfmt_misc/register"
EOF
chmod 0644 "$SRC/layer/system/etc/init/ndk_translation.rc"

# 若底图曾叠过 houdini，空文件盖掉 houdini.rc（无害）
echo "# disabled: using libndk_translation" > "$SRC/layer/system/etc/init/houdini.rc"
chmod 0644 "$SRC/layer/system/etc/init/houdini.rc"

# 属性: 对齐 wh-extensions prop.json，但只改 bridge 相关键
msg "patch build.prop（只改 native bridge 相关键）"
mkdir -p "$SRC/layer/vendor" "$SRC/layer/system"
copy_from_base /vendor/build.prop "$SRC/layer/vendor/build.prop"
copy_from_base /system/build.prop "$SRC/layer/system/build.prop"

# 镜像名可能被改过，不能只靠 *houdini* 名称判断冲突。
if grep -qx 'ro.dalvik.vm.native.bridge=libhoudini.so' "$SRC/layer/vendor/build.prop" &&
   [ "${FORCE_ON_HOUDINI:-0}" != 1 ]; then
    echo "错误: BASE_IMAGE 的实际 native bridge 是 Houdini，拒绝叠加 NDK" >&2
    exit 1
fi

python3 - "$SRC/layer" <<'PY'
import os, re, sys
root = sys.argv[1]
# from wh-extensions/.../prop.json + redroid vendor abilist keys
overrides = {
    "vendor/build.prop": {
        "ro.dalvik.vm.native.bridge": "libndk_translation.so",
        "ro.enable.native.bridge.exec": "1",
        "ro.vendor.enable.native.bridge.exec": "1",
        "ro.vendor.enable.native.bridge.exec64": "1",
        "ro.ndk_translation.version": "0.2.3",
        "ro.dalvik.vm.isa.arm": "x86",
        "ro.dalvik.vm.isa.arm64": "x86_64",
        "ro.vendor.product.cpu.abilist": "x86_64,x86,arm64-v8a,armeabi-v7a,armeabi",
        "ro.vendor.product.cpu.abilist32": "x86,armeabi-v7a,armeabi",
        "ro.vendor.product.cpu.abilist64": "x86_64,arm64-v8a",
    },
    "system/build.prop": {
        "ro.dalvik.vm.native.bridge": "libndk_translation.so",
        "ro.system.product.cpu.abilist": "x86_64,x86,arm64-v8a,armeabi-v7a,armeabi",
        "ro.system.product.cpu.abilist32": "x86,armeabi-v7a,armeabi",
        "ro.system.product.cpu.abilist64": "x86_64,arm64-v8a",
        "ro.product.cpu.abilist": "x86_64,arm64-v8a,x86,armeabi-v7a,armeabi",
        "ro.product.cpu.abilist32": "x86,armeabi-v7a,armeabi",
        "ro.product.cpu.abilist64": "x86_64,arm64-v8a",
    },
}
for rel, props in overrides.items():
    path = os.path.join(root, rel)
    lines = open(path).read().splitlines()
    seen, out = set(), []
    for ln in lines:
        m = re.match(r"^([\w.]+)=", ln)
        if m and m.group(1) in props:
            k = m.group(1)
            out.append(f"{k}={props[k]}")
            seen.add(k)
        else:
            out.append(ln)
    rest = [k for k in props if k not in seen]
    if rest:
        out.append("# ndk_translation (waydroid-helper zork R136)")
        out += [f"{k}={props[k]}" for k in rest]
    open(path, "w").write("\n".join(out) + "\n")
    print(f"patched {rel}")
PY
chmod 0644 "$SRC/layer/vendor/build.prop" "$SRC/layer/system/build.prop"

if [ "$KEEP_SU" != 1 ]; then
    msg "白盒删除 stock su"
    mkdir -p "$SRC/layer/system/xbin" "$SRC/layer/system/bin"
    touch "$SRC/layer/system/xbin/.wh.su" "$SRC/layer/system/bin/.wh.su"
fi

msg "打包 ndk.tar"
tar --owner=0 --group=0 --numeric-owner -cf "$OUT/ndk.tar" -C "$SRC/layer" .

cat > "$OUT/Dockerfile.ndk" <<EOF
FROM $BASE_IMAGE

ADD ndk.tar /
EOF

if [ "${BUILD_IMAGE:-1}" = 1 ]; then
    msg "构建镜像 $NEW_IMAGE"
    $CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile.ndk" "$OUT"
    msg "完成: $NEW_IMAGE"
else
    msg "已生成 $OUT/ndk.tar / Dockerfile.ndk"
fi
