#!/bin/bash
# 在已嫁接 gralloc4 的底图上叠加 libhoudini + Magisk
# 配方来源: https://github.com/waydroid-helper/extensions
# 须先跑 ./scripts/gralloc4.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
SRC="$HERE/src"
OUT="$HERE/out"
CTR=${CTR:-podman}

# 基底必须是已嫁接 gralloc4 的镜像 (gralloc4.sh 的产物)
BASE_IMAGE="${BASE_IMAGE:-localhost/redroid13-graft:latest}"

# ROOT=kitsune  -> Kitsune Magisk (Delta 后继, 内置 MagiskHide, 隐藏效果好)
# ROOT=magisk   -> 官方 Magisk v30.7 (只有 DenyList)
# ROOT=none     -> 不注入 Magisk（仅 houdini；配合 inject-gapps 可出无 root 镜像）
ROOT="${ROOT:-kitsune}"

# 默认同时移除 32/64 位 HPE Houdini 的内置有效期失败分支。
# 设为 0 仅用于保留上游原版行为做对照；未知二进制始终 fail closed。
PATCH_HOUDINI_EXPIRY="${PATCH_HOUDINI_EXPIRY:-1}"
case "$PATCH_HOUDINI_EXPIRY" in
    0|1) ;;
    *) echo "PATCH_HOUDINI_EXPIRY 只支持 0 或 1" >&2; exit 1 ;;
esac

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
    none|off|no)
        ROOT=none
        MAGISK_VER=""
        ;;
    *)
        echo "ROOT 只支持 kitsune、magisk 或 none"; exit 1 ;;
esac

# 默认(Kitsune) 镜像名不带后缀; 换官方 Magisk / 无 root 时加上以示区分
_root_suffix=""
[ "$ROOT" = magisk ] && _root_suffix="-official"
if [ -z "${NEW_IMAGE:-}" ]; then
    if [ "$ROOT" = none ]; then
        NEW_IMAGE="localhost/redroid13-graft-houdini:latest"
    else
        NEW_IMAGE="localhost/redroid13-graft-houdini-magisk${_root_suffix}:latest"
    fi
fi

if ! $CTR image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "错误: 找不到底图 $BASE_IMAGE" >&2
    echo "请先运行: ./scripts/gralloc4.sh" >&2
    exit 1
fi

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

fetch() { # url sha256 dest
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

# docker/podman cp 失败时也清掉临时容器。
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
rm -f "$OUT/houdini.tar" "$OUT/magisk.tar" "$OUT/strip-su.tar" \
      "$OUT/props.tar" "$OUT/Dockerfile"
rm -rf "$SRC"; mkdir -p "$SRC"

fetch "$HOUDINI_URL" "$HOUDINI_SHA" "$DL/houdini.zip"
fetch "$HACK_URL" "$HACK_SHA" "$DL/houdini_hack.zip"
if [ "$ROOT" != none ]; then
    if [ -n "${MAGISK_LOCAL_APK:-}" ]; then
        [ -f "$MAGISK_LOCAL_APK" ] || {
            echo "错误: 找不到 MAGISK_LOCAL_APK=$MAGISK_LOCAL_APK" >&2
            exit 1
        }
        cp -f "$MAGISK_LOCAL_APK" "$DL/$MAGISK_APK"
        MAGISK_SHA="$(sha256sum "$DL/$MAGISK_APK" | cut -d' ' -f1)"
        msg "使用本地 Magisk APK $(basename "$MAGISK_LOCAL_APK") (sha256=$MAGISK_SHA)"
    else
        fetch "$MAGISK_URL" "$MAGISK_SHA" "$DL/$MAGISK_APK"
    fi
fi

########################################
# 1. libhoudini
########################################
msg "组装 libhoudini"
HD="$SRC/houdini"
unzip -q "$DL/houdini.zip" -d "$SRC/houdini-zip"
mkdir -p "$HD/system"
cp -a "$SRC/houdini-zip/vendor_intel_proprietary_houdini-$HOUDINI_COMMIT/prebuilts/." "$HD/system/"

# hpe-14 的 32/64 位库各自带有效期路径。严格按完整输入/输出 SHA 和
# 原指令门控，未知版本拒绝按固定偏移盲打。
if [ "$PATCH_HOUDINI_EXPIRY" = 1 ]; then
    msg "移除 Houdini 32/64 位有效期限制"
    python3 "$HERE/patch-houdini-expiry.py" \
        "$HD/system/lib/libhoudini.so" \
        "$HD/system/lib64/libhoudini.so"
else
    msg "保留 Houdini 原版有效期限制（PATCH_HOUDINI_EXPIRY=0）"
    python3 "$HERE/patch-houdini-expiry.py" --verify-original \
        "$HD/system/lib/libhoudini.so" \
        "$HD/system/lib64/libhoudini.so"
fi

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

# 不再用第三方仓库的整份 init.rc 快照覆盖父镜像。以直接父镜像版本为模板，
# 在唯一的 perform_apex_config 锚点后插入两条命令，避免丢失 redroid 后续改动。
BASE_INITRC="$SRC/base-init.rc"
copy_from_base /system/etc/init/hw/init.rc "$BASE_INITRC"
mkdir -p "$HD/system/etc/init/hw"
python3 - "$BASE_INITRC" "$HD/system/etc/init/hw/init.rc" <<'PYEOF'
import sys
from pathlib import Path

src, dst = map(Path, sys.argv[1:])
text = src.read_text()
anchor = "    perform_apex_config\n"
marker = "    # redroid-graft: patch Houdini linker namespaces after apexd\n"
commands = (
    marker
    + '    exec -- /system/bin/sh -c "/system/bin/patch '
      '/linkerconfig/ld.config.txt < /system/etc/ld_config.patch"\n'
    + '    exec -- /system/bin/sh -c "/system/bin/patch '
      '/linkerconfig/com.android.media.swcodec/ld.config.txt '
      '< /system/etc/ld_config_swcodec.patch"\n'
)
if marker in text or "ld_config_swcodec.patch" in text:
    raise SystemExit("基础镜像 init.rc 已含未知的 ld.config 补丁，拒绝重复注入")
if text.count(anchor) != 1:
    raise SystemExit(
        f"init.rc 中应恰有一个 perform_apex_config 锚点，实际 {text.count(anchor)}"
    )
dst.write_text(text.replace(anchor, anchor + "\n" + commands, 1))
print("patched parent init.rc after perform_apex_config")
PYEOF
chmod 0644 "$HD/system/etc/init/hw/init.rc"

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/houdini.tar" -C "$HD" system

# 验证归档内容，而不只验证 staging 文件。
if [ "$PATCH_HOUDINI_EXPIRY" = 1 ]; then
    EXPECT_H32="96fe3acce9aec00bf5d44a187e727aa6d1ef1cf29043c661fa26d4446044e993"
    EXPECT_H64="847be255d03886974ff0cff09d09b7530301d24671ce0f80172ab3a0629d23b8"
else
    EXPECT_H32="f8df8ff7e4894feec7876135f88cb9b9f3e3c9a4221c909c9b45c35bc02f9866"
    EXPECT_H64="b321439df5a64ff29a62bb168303e58f800e94113c399f52795c42793f7f5f1e"
fi
for spec in "system/lib/libhoudini.so:$EXPECT_H32" \
            "system/lib64/libhoudini.so:$EXPECT_H64"; do
    member=${spec%%:*}; expected=${spec#*:}
    actual=$(tar -xOf "$OUT/houdini.tar" "$member" | sha256sum | cut -d' ' -f1)
    [ "$actual" = "$expected" ] || {
        echo "错误: houdini.tar 中 $member 的 SHA-256 不符" >&2; exit 1; }
done
msg "houdini.tar 双 ABI SHA-256 校验通过"

########################################
# 2. Magisk（可选）
########################################
if [ "$ROOT" = none ]; then
    msg "跳过 Magisk（ROOT=none）"
    rm -f "$OUT/magisk.tar"
    # redroid userdebug 自带 /system/xbin/su，无 Magisk 时仍会被游戏当 root
    msg "白盒删除 stock su（.wh.su）"
    mkdir -p "$OUT/strip-su/system/xbin" "$OUT/strip-su/system/bin"
    touch "$OUT/strip-su/system/xbin/.wh.su" "$OUT/strip-su/system/bin/.wh.su"
    tar --owner=0 --group=0 --numeric-owner -cf "$OUT/strip-su.tar" -C "$OUT/strip-su" .
else
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
# 注意时序: magiskd 在它自己的时机 pm_install /data/stub.apk,
# 可能发生在本脚本之后 —— 只跑一次会被它覆盖回去。
# 所以后台持续监视一段时间, 发现壳就盖回来。
{
    echo '#!/system/bin/sh'
    echo '# 确保装的是完整版 Magisk app 而不是 stub 壳'
    echo '#'
    echo '# magiskd 在 --boot-complete 后会自己 pm_install /data/stub.apk,'
    echo '# 时机不确定(可能在本脚本之后), 壳启动后要联网下载完整版而上游 404,'
    echo '# 于是 System.exit(0) —— 表现为“点开就闪退”。'
    echo '# 故持续监视而非只检查一次。'
    echo 'APK=/system/etc/init/magisk/magisk.apk'
    echo "PKG=$MAGISK_PKG"
    echo ''
    echo 'i=0'
    echo 'while [ $i -lt 60 ]; do'
    echo '    ver=$(dumpsys package $PKG 2>/dev/null | sed -n "s/.*versionName=//p" | head -1)'
    echo '    case "$ver" in'
    echo '        ""|1.0)'
    echo '            # 未安装或是 stub 壳 -> 装/覆盖完整版'
    echo '            pm install -r -d "$APK" >/dev/null 2>&1'
    echo '            ;;'
    echo '    esac'
    echo '    i=$((i+1)); sleep 2'
    echo 'done'
} > "$MGDIR/install_app.sh"
chmod 0755 "$MGDIR/install_app.sh"


MAGISKSYSTEMDIR=/system/etc/init/magisk
MAGISKTMP=/sbin
# Android init 会加载 /system/etc/init/*.rc；把 Magisk trigger 放在独立文件，
# 不覆盖父镜像的 bootanim 服务定义。
cat > "$MG/system/etc/init/magisk.rc" <<EOF
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
    exec_background -- /system/bin/sh -c "$MAGISKSYSTEMDIR/install_app.sh"

on property:init.svc.zygote=restarting
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart

on property:init.svc.zygote=stopped
    exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
EOF
chmod 0644 "$MG/system/etc/init/magisk.rc"

# magisk 目录 owner 2000(shell):0
tar --numeric-owner --owner=0 --group=0 \
    -cf "$OUT/magisk.tar" -C "$MG" --exclude=system/etc/init/magisk system sbin
tar --numeric-owner --owner=2000 --group=0 \
    -rf "$OUT/magisk.tar" -C "$MG" system/etc/init/magisk
fi

########################################
# 3. build.prop 覆盖 (native bridge -> houdini)
########################################
msg "生成 build.prop 覆盖层"
PR="$SRC/props"
mkdir -p "$PR/vendor" "$PR/system"
copy_from_base /vendor/build.prop "$PR/vendor/build.prop"
copy_from_base /system/build.prop "$PR/system/build.prop"
# 图形栈属性由嫁接版 gpu_config.sh 开机设置, 不在 build.prop 里; 以它为嫁接标记
copy_from_base /vendor/bin/gpu_config.sh "$SRC/gpu_config.sh.base"
if ! grep -q '^# redroid-graft:' "$SRC/gpu_config.sh.base"; then
    echo "错误: BASE_IMAGE 不是当前版本 gralloc4.sh 产出的底图: $BASE_IMAGE" >&2
    echo "      (旧版底图把 ro.hardware.* 写死在 build.prop 里, 请重新运行 ./scripts/gralloc4.sh)" >&2
    exit 1
fi

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
if [ "$ROOT" = none ]; then
cat > "$OUT/Dockerfile" <<EOF
FROM $BASE_IMAGE

ADD houdini.tar /
ADD props.tar /
ADD strip-su.tar /
EOF
else
cat > "$OUT/Dockerfile" <<EOF
FROM $BASE_IMAGE

ADD houdini.tar /
ADD magisk.tar /
ADD props.tar /
EOF
fi

$CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile" "$OUT"
msg "完成: $NEW_IMAGE"
