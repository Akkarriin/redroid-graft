#!/bin/bash
# 把镜像的 ARM 翻译层从 libhoudini 切回 redroid 自带的 libndk_translation
#
# 用途: 对比两种翻译层的性能。
# ndk_translation 是 Google 为 ChromeOS 做的, 带一整套图形/音频 proxy 库
# (libndk_translation_proxy_libvulkan.so 等), ARM 应用的图形调用可直通
# 宿主 x86 驱动而不逐指令翻译, 某些负载下比 houdini 快。
#
# 注意: 两者都不能把单线程的图形提交变成多线程。
# Unity 的 UnityGfxDeviceWorker 本来就是单线程设计, 翻译开销落在这一个线程上,
# 换翻译层只可能降低单条指令的开销, 不会有数量级差异。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/ndk-stock"
OUT="$HERE/out"
CTR=${CTR:-podman}

BASE_IMAGE="${BASE_IMAGE:-localhost/redroid13-graft-houdini-magisk:latest}"
# 这是“保留 Magisk、切回 redroid stock NDK”的诊断变体，不与正式 zork
# R136 的 redroid13-graft-ndk:latest 共用名称或输出文件。
NEW_IMAGE="${NEW_IMAGE:-localhost/redroid13-graft-ndk-stock-magisk:latest}"

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

copy_from_base() { # path-in-image dest
    local src=$1 dest=$2 cid
    cid=$($CTR create "$BASE_IMAGE")
    if ! $CTR cp "$cid:$src" "$dest"; then
        $CTR rm -f "$cid" >/dev/null 2>&1 || true
        return 1
    fi
    $CTR rm "$cid" >/dev/null
}

rm -rf "$SRC"; mkdir -p "$SRC/system/etc/init" "$SRC/props" "$OUT"
rm -f "$OUT/ndk-stock.tar" "$OUT/Dockerfile.ndk-stock"

########################################
# 1. 恢复 ndk_translation.rc
#    build.sh 用空文件覆盖过它(为了禁用), 这里写回原始内容
########################################
msg "恢复 ndk_translation.rc"
cat > "$SRC/system/etc/init/ndk_translation.rc" <<'EOF'
# Enable the stock native bridge; use exec+cat because init's copy command is
# unreliable when the destination is binfmt_misc's special register file.
on early-init && property:ro.enable.native.bridge.exec=1
    mount binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc

on property:ro.enable.native.bridge.exec=1 && property:ro.dalvik.vm.isa.arm=x86
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm_exe > /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm_dyn > /proc/sys/fs/binfmt_misc/register"

on property:ro.enable.native.bridge.exec=1 && property:ro.dalvik.vm.isa.arm64=x86_64
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm64_exe > /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "cat /system/etc/binfmt_misc/arm64_dyn > /proc/sys/fs/binfmt_misc/register"
EOF
chmod 0644 "$SRC/system/etc/init/ndk_translation.rc"

# 禁用 houdini 的 rc(同样用空文件覆盖)
echo "# disabled: using libndk_translation instead" \
    > "$SRC/system/etc/init/houdini.rc"
chmod 0644 "$SRC/system/etc/init/houdini.rc"

########################################
# 2. binfmt_misc 规则改回指向 ndk 的 program runner
#    houdini 层把这些文件覆盖成了指向 /system/bin/houdini
########################################
msg "恢复 binfmt_misc 规则"
mkdir -p "$SRC/system/etc/binfmt_misc"
R=/system/bin/ndk_translation_program_runner_binfmt_misc
printf ':arm_exe:M::\\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x28::%s:P\n' \
    "$R"   > "$SRC/system/etc/binfmt_misc/arm_exe"
printf ':arm_dyn:M::\\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x03\\x00\\x28::%s:P\n' \
    "$R"   > "$SRC/system/etc/binfmt_misc/arm_dyn"
printf ':arm64_exe:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7::%s_arm64:P\n' \
    "$R" > "$SRC/system/etc/binfmt_misc/arm64_exe"
printf ':arm64_dyn:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x03\\x00\\xb7::%s_arm64:P\n' \
    "$R" > "$SRC/system/etc/binfmt_misc/arm64_dyn"
chmod 0644 "$SRC/system/etc/binfmt_misc/"*

########################################
# 3. 属性: native bridge 指回 libnb.so (= libndk_translation.so 的软链)
########################################
msg "改写 build.prop"
copy_from_base /vendor/build.prop "$SRC/props/vendor.build.prop"
copy_from_base /system/build.prop "$SRC/props/system.build.prop"

python3 - "$SRC/props" <<'PYEOF'
import os, re, sys
d = sys.argv[1]
over = {
    "vendor.build.prop": {"ro.dalvik.vm.native.bridge": "libnb.so"},
    "system.build.prop": {"ro.dalvik.vm.native.bridge": "libnb.so"},
}
for f, props in over.items():
    p = os.path.join(d, f)
    lines = open(p).read().splitlines()
    seen, out = set(), []
    for ln in lines:
        m = re.match(r"^([\w.]+)=", ln)
        if m and m.group(1) in props:
            k = m.group(1); out.append(f"{k}={props[k]}"); seen.add(k)
        else:
            out.append(ln)
    for k in props:
        if k not in seen:
            out.append(f"{k}={props[k]}")
    open(p, "w").write("\n".join(out) + "\n")
    print(f"patched {f}")
PYEOF

mkdir -p "$SRC/layer/vendor" "$SRC/layer/system"
cp -a "$SRC/system/." "$SRC/layer/system/"
install -Dm644 "$SRC/props/vendor.build.prop" "$SRC/layer/vendor/build.prop"
install -Dm644 "$SRC/props/system.build.prop" "$SRC/layer/system/build.prop"

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/ndk-stock.tar" -C "$SRC/layer" system vendor

cat > "$OUT/Dockerfile.ndk-stock" <<EOF
FROM $BASE_IMAGE

ADD ndk-stock.tar /
EOF

if [ "${BUILD_IMAGE:-1}" = 1 ]; then
    msg "构建镜像 $NEW_IMAGE"
    $CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile.ndk-stock" "$OUT"
    msg "完成: $NEW_IMAGE"
fi
