#!/bin/bash
# 构建 redroid 13 (64_32) + libhoudini + Magisk 镜像
# 配方来源: https://github.com/waydroid-helper/extensions
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
SRC="$HERE/src"
OUT="$HERE/out"
CTR=${CTR:-podman}

BASE_IMAGE="docker.io/redroid/redroid:13.0.0-latest"

# ROOT=kitsune  -> Kitsune Magisk (Delta 后继, 内置 MagiskHide, 隐藏效果好)
# ROOT=magisk   -> 官方 Magisk v30.7 (只有 DenyList)
ROOT="${ROOT:-kitsune}"

HOUDINI_COMMIT="debc3dc91cf12b5c5b8a1c546a5b0b7bf7f838a8"
HOUDINI_URL="https://github.com/supremegamers/vendor_intel_proprietary_houdini/archive/${HOUDINI_COMMIT}.zip"
HOUDINI_SHA="7c78abbcced1f7c5c1cc794a0afb4010a2e5bb0bb18eadd6de3af2fe13e9dc25"

# linker 命名空间补丁: 默认 /system/lib64/arm64 不在 permitted.paths 里,
# libhoudini.so dlopen libtcb.so 会被 linker 拒绝 → arm 应用 SIGABRT
HACK_COMMIT="a2194c5e294cbbfdfe87e51eb9eddb4c3621d8c3"
HACK_URL="https://github.com/rote66/redroid_libhoudini_hack/archive/${HACK_COMMIT}.zip"
HACK_SHA="5c904d6db5e15adc37ffadde5f21437ccabf86c1e94a3a0e4f77371a90776983"

case "$ROOT" in
    kitsune)
        MAGISK_VER="27.2"
        MAGISK_URL="https://github.com/ayasa520/KitsuneMagisk/releases/download/ea3f64a/app-debug.apk"
        MAGISK_SHA="f7ecfdc6b07d1b7f60fae5231427c37c05f5ed705d619696968b71f4846886af"
        MAGISK_PKG="io.github.huskydg.magisk"
        MAGISK_BIN="magisk64"      # Kitsune 的 lib 叫 libmagisk64.so
        MAGISK_APK="kitsune.apk"
        ;;
    magisk)
        MAGISK_VER="v30.7"
        MAGISK_URL="https://github.com/ayasa520/Magisk/releases/download/${MAGISK_VER}/app-debug.apk"
        MAGISK_SHA="61467cfbbcad3754a29f53fe0e9bdef11d7c5961710d93089c8aa480cf4e126a"
        MAGISK_PKG="com.topjohnwu.magisk"
        MAGISK_BIN="magisk"
        MAGISK_APK="magisk.apk"
        ;;
    *)
        echo "ROOT 只支持 kitsune 或 magisk"; exit 1 ;;
esac

NEW_IMAGE="${NEW_IMAGE:-localhost/redroid:13.0.0-houdini-${ROOT}}"

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

fetch() { # url sha256 dest
    local url=$1 sha=$2 dest=$3
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
        msg "已缓存 $(basename "$dest")"
        return
    fi
    msg "下载 $(basename "$dest")"
    curl -fL --retry 3 -o "$dest" "$url"
    [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ] || { echo "sha256 校验失败: $dest"; exit 1; }
}

mkdir -p "$DL" "$OUT"
rm -rf "$SRC"; mkdir -p "$SRC"

fetch "$HOUDINI_URL" "$HOUDINI_SHA" "$DL/houdini.zip"
fetch "$HACK_URL" "$HACK_SHA" "$DL/houdini_hack.zip"
fetch "$MAGISK_URL" "$MAGISK_SHA" "$DL/$MAGISK_APK"

########################################
# 1. libhoudini
########################################
msg "组装 libhoudini"
HD="$SRC/houdini"
unzip -q "$DL/houdini.zip" -d "$SRC/houdini-zip"
mkdir -p "$HD/system"
cp -a "$SRC/houdini-zip/vendor_intel_proprietary_houdini-$HOUDINI_COMMIT/prebuilts/." "$HD/system/"

# native bridge init.rc: 用 exec 写 binfmt_misc, 不依赖 init 的 copy 语义
mkdir -p "$HD/system/etc/init"
cat > "$HD/system/etc/init/houdini.rc" <<'EOF'
on early-init
    mount binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc

on property:ro.enable.native.bridge.exec=1
    exec -- /system/bin/sh -c "echo ':arm_exe:M::\\x7f\\x45\\x4c\\x46\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x28::/system/bin/houdini:P' > /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "echo ':arm_dyn:M::\\x7f\\x45\\x4c\\x46\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x03\\x00\\x28::/system/bin/houdini:P' >> /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "echo ':arm64_exe:M::\\x7f\\x45\\x4c\\x46\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7::/system/bin/houdini64:P' >> /proc/sys/fs/binfmt_misc/register"
    exec -- /system/bin/sh -c "echo ':arm64_dyn:M::\\x7f\\x45\\x4c\\x46\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x03\\x00\\xb7::/system/bin/houdini64:P' >> /proc/sys/fs/binfmt_misc/register"
EOF

# 基础镜像自带 libndk_translation, ADD tar 无法删除文件,
# 用空 rc 覆盖以禁用其 binfmt_misc 注册, 避免与 houdini 冲突
echo "# disabled: replaced by libhoudini" > "$HD/system/etc/init/ndk_translation.rc"
chmod 0644 "$HD/system/etc/init/ndk_translation.rc"

chmod 0755 "$HD/system/bin/houdini" "$HD/system/bin/houdini64"
chmod 0755 "$HD/system/bin" "$HD/system/lib" "$HD/system/lib64" \
           "$HD/system/lib/arm" "$HD/system/lib64/arm64" "$HD/system/etc" \
           "$HD/system/etc/binfmt_misc" "$HD/system/etc/init"
find "$HD/system/lib" "$HD/system/lib64" -type f -exec chmod 0644 {} +
find "$HD/system/etc/binfmt_misc" -type f -exec chmod 0644 {} +
chmod 0644 "$HD/system/etc/init/houdini.rc"

# linker 命名空间补丁: 把 /system/lib{,64}/arm{,64} 加入 permitted.paths,
# 并在 init.rc 的 apexd 之后自动应用(每次开机)
unzip -q "$DL/houdini_hack.zip" -d "$SRC/hack-zip"
HACKDIR="$SRC/hack-zip/redroid_libhoudini_hack-$HACK_COMMIT/13.0.0"
install -Dm644 "$HACKDIR/etc/ld_config.patch"         "$HD/system/etc/ld_config.patch"
install -Dm644 "$HACKDIR/etc/ld_config_swcodec.patch" "$HD/system/etc/ld_config_swcodec.patch"

# hack 的 init.rc 是上游快照, 必须确认它除了 patch 那几行外与基础镜像一致,
# 否则会静默覆盖掉 redroid 对 init.rc 的改动
BASE_INITRC="$SRC/base-init.rc"
CID=$($CTR create "$BASE_IMAGE")
$CTR cp "$CID:/system/etc/init/hw/init.rc" "$BASE_INITRC"
$CTR rm "$CID" >/dev/null
if ! diff <(grep -v 'ld_config.*\.patch\|# Patch ld.config after apexd\|^\s*$' "$HACKDIR/etc/init/hw/init.rc") \
          <(grep -v '^\s*$' "$BASE_INITRC") >/dev/null; then
    echo "错误: houdini_hack 的 init.rc 与基础镜像差异过大, 不能直接替换" >&2
    diff "$BASE_INITRC" "$HACKDIR/etc/init/hw/init.rc" | head -20 >&2
    exit 1
fi
install -Dm644 "$HACKDIR/etc/init/hw/init.rc"         "$HD/system/etc/init/hw/init.rc"

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/houdini.tar" -C "$HD" system

########################################
# 2. Magisk
########################################
msg "组装 $ROOT $MAGISK_VER"
MG="$SRC/magisk"
MGDIR="$MG/system/etc/init/magisk"
mkdir -p "$MGDIR/chromeos" "$MG/sbin" "$MG/system/etc/init"
unzip -q "$DL/$MAGISK_APK" -d "$SRC/magisk-apk"
LIB="$SRC/magisk-apk/lib/x86_64"
ASSETS="$SRC/magisk-apk/assets"

install -Dm755 "$LIB/libbusybox.so"      "$MGDIR/busybox"
install -Dm755 "$LIB/lib${MAGISK_BIN}.so" "$MGDIR/${MAGISK_BIN}"
install -Dm755 "$LIB/libmagiskboot.so"   "$MGDIR/magiskboot"
install -Dm755 "$LIB/libmagiskinit.so"   "$MGDIR/magiskinit"
install -Dm755 "$LIB/libmagiskpolicy.so" "$MGDIR/magiskpolicy"
install -Dm755 "$ASSETS/chromeos/futility" "$MGDIR/chromeos/futility"
install -Dm755 "$ASSETS/chromeos/kernel.keyblock" "$MGDIR/chromeos/kernel.keyblock"
install -Dm755 "$ASSETS/chromeos/kernel_data_key.vbprivk" "$MGDIR/chromeos/kernel_data_key.vbprivk"
install -Dm755 "$ASSETS/addon.d.sh"       "$MGDIR/addon.d.sh"
install -Dm755 "$ASSETS/boot_patch.sh"    "$MGDIR/boot_patch.sh"
install -Dm755 "$ASSETS/stub.apk"         "$MGDIR/stub.apk"
install -Dm755 "$ASSETS/util_functions.sh" "$MGDIR/util_functions.sh"
install -Dm755 "$DL/$MAGISK_APK"          "$MGDIR/magisk.apk"
# Kitsune 多出的资源, 存在则一并带上
for f in main.jar module_installer.sh uninstaller.sh bootctl; do
    [ -f "$ASSETS/$f" ] && install -Dm755 "$ASSETS/$f" "$MGDIR/$f"
done

# magiskd 在 --boot-complete 时, 如果发现 app 未安装,
# 会自己拿 stub.apk 装一个 41KB 的壳(versionName=1.0)。
# 那个壳启动后要联网下载完整版, 而 Kitsune 上游地址已 404,
# 于是 System.exit(0) 自杀 —— 表现为“点开就闪退”。
# 所以这里不能只判断“未安装才装”, 还要把已经装上的壳覆盖掉。
{
    echo '#!/system/bin/sh'
    echo '# 安装完整版 Magisk app; 若已装的是 stub 壳则强制覆盖'
    echo 'APK=/system/etc/init/magisk/magisk.apk'
    echo "PKG=$MAGISK_PKG"
    echo ''
    echo 'ver=$(dumpsys package $PKG 2>/dev/null | sed -n "s/.*versionName=//p" | head -1)'
    echo 'case "$ver" in'
    echo '    "")  ;;          # 未安装, 装'
    echo '    1.0) ;;          # stub 壳, 覆盖'
    echo '    *)   exit 0 ;;   # 已是完整版, 不动'
    echo 'esac'
    echo ''
    echo '# pm 在开机初期可能还没就绪, 重试几次'
    echo 'i=0'
    echo 'while [ $i -lt 10 ]; do'
    echo '    pm install -r -d "$APK" >/dev/null 2>&1 && exit 0'
    echo '    i=$((i+1)); sleep 3'
    echo 'done'
    echo 'exit 1'
} > "$MGDIR/install_app.sh"
chmod 0755 "$MGDIR/install_app.sh"


MAGISKSYSTEMDIR=/system/etc/init/magisk
MAGISKTMP=/sbin
cat > "$MG/system/etc/init/bootanim.rc" <<EOF
service bootanim /system/bin/bootanimation
    class core animation
    user graphics
    group graphics audio
    disabled
    oneshot
    ioprio rt 0
    task_profiles MaxPerformance

on post-fs-data
    start logd
    exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:magisk:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:update_engine:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
    exec u:r:su:s0 root root -- /system/bin/sh -c "mkdir -p /data/adb/magisk && cp -af $MAGISKSYSTEMDIR/. /data/adb/magisk/ && rm -f /data/adb/magisk/stub.apk /data/adb/magisk/magisk.apk && chmod -R 755 /data/adb/magisk"
    exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/$MAGISK_BIN --auto-selinux --setup-sbin $MAGISKSYSTEMDIR $MAGISKTMP
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --post-fs-data

on nonencrypted
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service

on property:vold.decrypt=trigger_restart_framework
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service

on property:sys.boot_completed=1
    mkdir /data/adb/magisk 755
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --boot-complete
    exec -- /system/bin/sh -c "$MAGISKSYSTEMDIR/install_app.sh"

on property:init.svc.zygote=restarting
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart

on property:init.svc.zygote=stopped
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
EOF
chmod 0644 "$MG/system/etc/init/bootanim.rc"

# magisk 目录 owner 2000(shell):0
tar --numeric-owner --owner=0 --group=0 \
    -cf "$OUT/magisk.tar" -C "$MG" --exclude=system/etc/init/magisk system sbin
tar --numeric-owner --owner=2000 --group=0 \
    -rf "$OUT/magisk.tar" -C "$MG" system/etc/init/magisk

########################################
# 3. build.prop 覆盖 (native bridge -> houdini)
########################################
msg "生成 build.prop 覆盖层"
PR="$SRC/props"
mkdir -p "$PR/vendor" "$PR/system"
CID=$($CTR create "$BASE_IMAGE")
$CTR cp "$CID:/vendor/build.prop" "$PR/vendor/build.prop"
$CTR cp "$CID:/system/build.prop" "$PR/system/build.prop"
$CTR rm "$CID" >/dev/null

python3 - "$PR" <<'PYEOF'
import sys, os, re
pr = sys.argv[1]
overrides = {
    "vendor/build.prop": {
        "ro.dalvik.vm.native.bridge": "libhoudini.so",
        "ro.enable.native.bridge.exec": "1",
        "ro.dalvik.vm.isa.arm": "x86",
        "ro.dalvik.vm.isa.arm64": "x86_64",
        "ro.vendor.product.cpu.abilist": "x86_64,x86,arm64-v8a,armeabi-v7a,armeabi",
        "ro.vendor.product.cpu.abilist32": "x86,armeabi-v7a,armeabi",
        "ro.vendor.product.cpu.abilist64": "x86_64,arm64-v8a",
    },
    "system/build.prop": {
        "ro.system.product.cpu.abilist": "x86_64,x86,arm64-v8a,armeabi-v7a,armeabi",
        "ro.system.product.cpu.abilist32": "x86,armeabi-v7a,armeabi",
        "ro.system.product.cpu.abilist64": "x86_64,arm64-v8a",
        "ro.dalvik.vm.native.bridge": "libhoudini.so",
    },
}
for rel, props in overrides.items():
    path = os.path.join(pr, rel)
    lines = open(path).read().splitlines()
    seen = set()
    out = []
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
        out.append("# libhoudini native bridge")
        out += [f"{k}={props[k]}" for k in rest]
    open(path, "w").write("\n".join(out) + "\n")
    print(f"patched {rel}")
PYEOF

chmod 0644 "$PR/vendor/build.prop" "$PR/system/build.prop"
tar --owner=0 --group=0 --numeric-owner -cf "$OUT/props.tar" -C "$PR" vendor system

########################################
# 4. 构建镜像
########################################
msg "构建镜像 $NEW_IMAGE"
cat > "$OUT/Dockerfile" <<EOF
FROM $BASE_IMAGE

ADD houdini.tar /
ADD magisk.tar /
ADD props.tar /
EOF

$CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile" "$OUT"
msg "完成: $NEW_IMAGE"
