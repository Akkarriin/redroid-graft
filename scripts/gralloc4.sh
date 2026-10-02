#!/bin/bash
# 把 Waydroid 的 gralloc4 (minigbm_gbm_mesa) + Mesa 26 图形栈嫁接进 redroid
#   ANDROID_VERSION=13 (默认): Waydroid LOS20 vendor → redroid 13
#   ANDROID_VERSION=15 (实验): Waydroid LOS22 vendor → redroid 15
#
# 背景: redroid 只有 graphics.allocator@2.0 + 老式 gbm_gralloc,
#       Mesa ANV(Vulkan) 需要 gralloc4 才能分配 swapchain buffer,
#       否则 dequeueBuffer 返回 -22, Vulkan-only 的 Unity 游戏无法运行。
# 两者 Android 版本 / x86_64 ABI 一致, 直接搬运二进制; 依赖与符号由
# check-vendor-closure.py 按链接器命名空间校验。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
OUT="$HERE/out"
CTR=${CTR:-podman}
ANDROID_VERSION=${ANDROID_VERSION:-13}

case "$ANDROID_VERSION" in
13)
    WD_VENDOR_URL="${WD_VENDOR_URL:-https://sourceforge.net/projects/waydroid/files/images/vendor/waydroid_x86_64/lineage-20.0-20260428-MAINLINE-waydroid_x86_64-vendor.zip/download}"
    WD_VENDOR_ZIP="${WD_VENDOR_ZIP:-$DL/waydroid-vendor.zip}"
    WD_VENDOR_SHA="${WD_VENDOR_SHA:-cba35433ffca73ed349e096b1daec495b3204e01c0e541c4203671e6d648e874}"
    # graft 只支持 x86_64, 默认锁定该 tag 当前的 amd64 manifest digest
    DEFAULT_BASE="docker.io/redroid/redroid:13.0.0-latest@sha256:524987f1fc489f6018e2c9d0dd622e5eccea13eb896417cb4bfb26bc3fea9afd"
    DEFAULT_NEW="localhost/redroid13-graft:latest"
    # 已审阅过的原版 /vendor/bin/gpu_config.sh, 被 files/gpu_config.sh 替换
    GPU_CONFIG_SHA="86812ee33d1fa09cde706593586cd56f2196f7a01b026ad67dd4f151bfe32718"
    # Android 13 的 libdmabufheap 由 VNDK-SP 提供
    EXTRA_LIBS=""
    TAG=gralloc4
    ;;
15)
    WD_VENDOR_URL="${WD_VENDOR_URL:-https://github.com/WayDroid-ATV/waydroid-builds/releases/download/20260224/lineage-22.2-20260224-UNOFFICIAL-waydroid_x86_64.zip}"
    WD_VENDOR_ZIP="${WD_VENDOR_ZIP:-$DL/waydroid-los22-20260224-x86_64.zip}"
    WD_VENDOR_SHA="${WD_VENDOR_SHA:-6d08847141fe3668704bd5a9acb345cf2a8f295ccbc8e7cfb9c60149ca7b805b}"
    DEFAULT_BASE="docker.io/redroid/redroid:15.0.0-latest@sha256:25879821f13ffd38d5d6047d832379b96cf72ec520508b45036dca25cdc3737f"
    DEFAULT_NEW="localhost/redroid15-graft:latest"
    GPU_CONFIG_SHA="4b38dd8304fa30b20038f3d97e84c28eef1d44312c5dc485f2fc01f76a0e34fa"
    # Android 15 没有 VNDK: allocator/mapper@4 硬依赖的 libdmabufheap 必须放进 vendor,
    # /system/lib64 里那份 vendor 命名空间看不到
    EXTRA_LIBS="libdmabufheap.so"
    TAG=gralloc4-15
    ;;
*)
    echo "不支持的 ANDROID_VERSION=$ANDROID_VERSION (可选 13 / 15)" >&2; exit 1 ;;
esac

BASE_IMAGE="${BASE_IMAGE:-$DEFAULT_BASE}"
NEW_IMAGE="${NEW_IMAGE:-$DEFAULT_NEW}"
SRC="$HERE/src/$TAG"
BASE="$SRC/base"

# Vulkan 驱动: 默认带上 vendor 里所有 x86 PC 可用的 Mesa 26 驱动,
# 开机时由 gpu_config.sh 按内核驱动 (i915/xe/amdgpu/nouveau/virtio_gpu) 选择。
# 显式设置 VK_DRIVERS 时其中每一项都必须存在。
VK_CANDIDATES="vulkan.intel.so vulkan.intel_hasvk.so vulkan.radeon.so vulkan.nouveau.so vulkan.virtio.so"
VK_DRIVERS_EXPLICIT=${VK_DRIVERS:+1}
VK_DRIVERS=${VK_DRIVERS:-$VK_CANDIDATES}
for driver in $VK_DRIVERS; do
    [[ "$driver" =~ ^vulkan\.[A-Za-z0-9_.-]+\.so$ ]] || {
        echo "VK_DRIVERS 中的文件名非法: $driver" >&2; exit 1; }
done

msg() { echo -e "\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }

if [ -n "${VULKAN_HW:-}" ]; then
    warn "VULKAN_HW 已废弃并被忽略: Vulkan 驱动改为开机时按 GPU 自动选择;" \
         "需要强制指定时在启动参数里加 androidboot.redroid_vulkan=$VULKAN_HW"
fi

fetch() { # url sha256 dest
    local url=$1 sha=$2 dest=$3 tmp="${3}.part"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
        msg "已缓存并校验 $(basename "$dest")"
        return
    fi
    msg "下载 $(basename "$dest")"
    rm -f "$tmp"
    curl -fL --retry 3 -o "$tmp" "$url"
    [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$sha" ] || {
        rm -f "$tmp"; echo "sha256 校验失败: $dest" >&2; exit 1; }
    mv -f "$tmp" "$dest"
}

# 只解出校验和改写要用的部分 (约 1 GB), 不落整个 rootfs
extract_base() { # dest
    local dest=$1 cid
    cid=$($CTR create "$BASE_IMAGE")
    if ! $CTR export "$cid" | python3 -c '
import sys, tarfile
dest = sys.argv[1]
want = ("system/lib/", "system/lib64/", "system/apex/", "system/etc/llndk.libraries.txt",
        "vendor/lib/", "vendor/lib64/", "odm/lib/", "odm/lib64/",
        "vendor/build.prop", "vendor/bin/gpu_config.sh", "vendor/etc/init/",
        "vendor/etc/vintf/manifest.xml")
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as t:
    t.extraction_filter = getattr(tarfile, "tar_filter", None)
    for m in t:
        if m.name.lstrip("./").startswith(want):
            t.extract(m, dest)
' "$dest"; then
        $CTR rm -f "$cid" >/dev/null 2>&1 || true
        return 1
    fi
    $CTR rm "$cid" >/dev/null
}

mkdir -p "$DL" "$OUT"
rm -f "$OUT/$TAG.tar" "$OUT/Dockerfile.$TAG"
rm -rf "$SRC"; mkdir -p "$SRC" "$BASE"

fetch "$WD_VENDOR_URL" "$WD_VENDOR_SHA" "$WD_VENDOR_ZIP"

msg "解包 vendor.img"
VIMG="$SRC/vendor.img"
unzip -oq "$WD_VENDOR_ZIP" vendor.img -d "$SRC"

# LOS20 是 ext2 (debugfs 免 root 读取), LOS22 是 squashfs (7z)
if [ "$(head -c 4 "$VIMG" | tr -d '\000')" = hsqs ]; then
    command -v 7z >/dev/null || { echo "squashfs vendor.img 需要 7z (p7zip)" >&2; exit 1; }
    has() { 7z l -slt "$VIMG" "$1" 2>/dev/null | grep -qx "Path = $1"; }
    dump() { 7z e -so "$VIMG" "$1" > "$2" 2>/dev/null; }
else
    has() { debugfs -R "stat /$1" "$VIMG" 2>/dev/null | grep -q '^Inode:'; }
    dump() { debugfs -R "dump /$1 $2" "$VIMG" 2>/dev/null; }
fi
ex() { # path-in-img  dest
    mkdir -p "$(dirname "$2")"
    dump "$1" "$2" || true
    [ -s "$2" ] || { echo "提取失败: $1" >&2; exit 1; }
}

if [ -z "$VK_DRIVERS_EXPLICIT" ]; then
    found=""
    for d in $VK_DRIVERS; do
        has "lib64/hw/$d" && found="$found $d"
    done
    VK_DRIVERS=${found# }
    [ -n "$VK_DRIVERS" ] || { echo "vendor.img 里没有任何可用的 Vulkan 驱动" >&2; exit 1; }
fi
msg "Vulkan 驱动: $VK_DRIVERS"

# 着色器编译器 libLLVM 的版本随 Waydroid 构建变化 (LOS20: 22, LOS22: 21), 从 DT_NEEDED 读
ex lib64/libgallium_dri.so "$SRC/probe/libgallium_dri.so"
LLVM_LIB=$(readelf -d "$SRC/probe/libgallium_dri.so" | grep -oE 'libLLVM[0-9.]*\.so' | head -n 1)
[ -n "$LLVM_LIB" ] || { echo "libgallium_dri.so 未链接 libLLVM*, 无法确定版本" >&2; exit 1; }
rm -rf "$SRC/probe"

########################################
# 提取组件 (64 位 + 32 位)
#
# gralloc4 HAL:   allocator@4.0 服务 + mapper@4.0 passthrough + minigbm
# Mesa 26:        dri_gbm(gbm 后端) → libgallium_dri(megadriver) → libLLVM(着色器编译器)
#                 libdrm 等 Mesa 链的是无版本后缀的名字, 与 redroid 的 libdrm.so.2 共存
# EGL/GLES:       必须一起换成 Mesa 26; redroid 的 Mesa 24 EGL 走 gralloc0 接口,
#                 与 gralloc4 handle 不兼容, SurfaceFlinger 会在 gbm_mesa_bo_import 崩
# Vulkan HAL:     必须是 Mesa 26; Mesa 24 的驱动不认识 gralloc4 buffer,
#                 "vkCreateImage w/ native buffer failed"
# 32 位:          mapper 是 passthrough (进程内加载), 32 位进程 (如 OMX 编码服务)
#                 需要 32 位实现, 否则 screenrecord/scrcpy 灰屏
########################################
msg "提取 gralloc4 + Mesa 26 组件 ($LLVM_LIB)"
ex bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa \
   "$SRC/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa"
for B in lib64 lib; do
    for l in android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so \
             gralloc.minigbm_gbm_mesa.so $VK_DRIVERS; do
        ex "$B/hw/$l" "$SRC/vendor/$B/hw/$l"
    done
    # shellcheck disable=SC2086
    for l in libminigbm_gralloc_gbm_mesa.so libgbm_mesa.so libgbm_mesa_wrapper.so \
             libdrm.so libdrm_intel.so libdrm_amdgpu.so libdrm_radeon.so \
             dri_gbm.so libgallium_dri.so "$LLVM_LIB" $EXTRA_LIBS; do
        ex "$B/$l" "$SRC/vendor/$B/$l"
    done
    for l in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so; do
        ex "$B/egl/$l" "$SRC/vendor/$B/egl/$l"
    done
done

chmod 0755 "$SRC/vendor/bin/hw/"*
find "$SRC/vendor/lib" "$SRC/vendor/lib64" -name '*.so' -exec chmod 0644 {} +

########################################
# Arc/xe: 跳过 allocate 时的 gbm_bo_map 探测 map_stride
# Settings 等带 BO_USE_SW_MASK 的分配会走 import+map+unmap → Mesa dri_flush SIGSEGV。
# SW buffer 已 force_linear, map_stride == stride, 直接抄 out_stride 即可。
########################################
msg "打补丁: 跳过 gbm_mesa_alloc 的 map_stride 探测 (xe)"
python3 "$HERE/patch-gbm-mesa-skip-map-stride.py" \
    "$SRC/vendor/lib64/libgbm_mesa_wrapper.so"
# allocator@4 是 64 位服务, 32 位 wrapper 不会走 allocate; 签名未知时跳过
python3 "$HERE/patch-gbm-mesa-skip-map-stride.py" \
    "$SRC/vendor/lib/libgbm_mesa_wrapper.so" || \
    msg "32 位 wrapper 签名不匹配, 跳过 (allocator 为 64 位)"

########################################
# 基础镜像: 后面的改写和依赖校验都基于它
########################################
msg "从基础镜像提取库与配置"
extract_base "$BASE"

########################################
# VINTF: 声明 allocator@4.0 / mapper@4.0
# redroid 的 vendor/etc/vintf/manifest/ 是目录, 直接放文件即可,
# 不需要 Waydroid 那套 manifest.disabled + bind mount
########################################
msg "生成 VINTF manifest"
mkdir -p "$SRC/vendor/etc/vintf/manifest"
cat > "$SRC/vendor/etc/vintf/manifest/gbm_mesa.allocator@4.0.xml" <<'EOF'
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.graphics.allocator</name>
        <transport>hwbinder</transport>
        <version>4.0</version>
        <interface>
            <name>IAllocator</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
EOF
cat > "$SRC/vendor/etc/vintf/manifest/gbm_mesa.mapper@4.0.xml" <<'EOF'
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>android.hardware.graphics.mapper</name>
        <transport arch="32+64">passthrough</transport>
        <version>4.0</version>
        <interface>
            <name>IMapper</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
EOF

# 主 manifest: 移除 allocator@2.0 / mapper@2.1 声明, 由上面的文件提供 4.0
python3 - "$BASE/vendor/etc/vintf/manifest.xml" "$SRC/vendor/etc/vintf/manifest.xml" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
x = open(src).read()
pat = re.compile(
    r'[ \t]*<hal format="hidl">\s*<name>android\.hardware\.graphics\.'
    r'(?:allocator|mapper)</name>.*?</hal>\n', re.S)
x2, n = pat.subn('', x)
assert n == 2, f"预期删除 2 个 hal 块, 实际 {n}"
open(dst, 'w').write(x2)
print(f"已移除 {n} 个旧 graphics HAL 声明")
PYEOF
chmod 0644 "$SRC/vendor/etc/vintf/manifest.xml" "$SRC/vendor/etc/vintf/manifest/"*.xml

########################################
# init: 启动 allocator@4.0, 停用 2.0
########################################
msg "生成 init rc"
mkdir -p "$SRC/vendor/etc/init"
cat > "$SRC/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa.rc" <<'EOF'
service vendor.graphics.allocator-4-0 /vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa
    interface android.hardware.graphics.allocator@4.0::IAllocator default
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE
    onrestart restart surfaceflinger
    task_profiles ServiceCapacityLow
EOF

# 覆盖原 2.0 服务定义, 加 disabled 使其不自动启动
cat > "$SRC/vendor/etc/init/android.hardware.graphics.allocator@2.0-service.rc" <<'EOF'
service vendor.gralloc-2-0 /vendor/bin/hw/android.hardware.graphics.allocator@2.0-service
    interface android.hardware.graphics.allocator@2.0::IAllocator default
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE
    onrestart restart surfaceflinger
    disabled
EOF
chmod 0644 "$SRC/vendor/etc/init/"*.rc

########################################
# GPU 属性: 替换 redroid 的 gpu_config.sh, 开机时按实际 GPU 设置
#   ro.hardware.gralloc=minigbm_gbm_mesa / ro.hardware.egl=mesa / ro.hardware.vulkan=<探测>
# 不再写进 vendor/build.prop: ro.* 先写者胜, 写死会让 gpu_config.sh 的探测静默失效,
# 一个镜像也就只能对应一个厂商。
########################################
msg "替换 gpu_config.sh (开机按 GPU 选 Vulkan 驱动)"
got=$(sha256sum "$BASE/vendor/bin/gpu_config.sh" | cut -d' ' -f1)
[ "$got" = "$GPU_CONFIG_SHA" ] || {
    echo "基础镜像的 gpu_config.sh 与已审阅版本不同 (sha256 $got)。" >&2
    echo "请对照 scripts/files/gpu_config.sh 合并上游改动, 再更新本脚本里的 GPU_CONFIG_SHA。" >&2
    exit 1; }
grep -q '^ *exec -- /vendor/bin/gpu_config.sh' "$BASE/vendor/etc/init/redroid.common.rc" || {
    echo "基础镜像的 redroid.common.rc 不再执行 gpu_config.sh, 需要重新审阅" >&2; exit 1; }
if grep -qE '^ro\.hardware\.(gralloc|egl|vulkan)=' "$BASE/vendor/build.prop"; then
    echo "基础镜像 vendor/build.prop 写死了 ro.hardware.{gralloc,egl,vulkan}," >&2
    echo "会让 gpu_config.sh 的设置失效。请以原版 redroid 为底图 (不要叠在旧的 graft 镜像上)。" >&2
    exit 1
fi
vk_names=$(for d in $VK_DRIVERS; do d=${d#vulkan.}; printf '%s ' "${d%.so}"; done)
vk_names=${vk_names% }
mkdir -p "$SRC/vendor/bin"
sed "s/@GRAFT_VK_DRIVERS@/$vk_names/" "$HERE/files/gpu_config.sh" > "$SRC/vendor/bin/gpu_config.sh"
! grep -q '@GRAFT_' "$SRC/vendor/bin/gpu_config.sh" || { echo "gpu_config.sh 模板未替换完整" >&2; exit 1; }
chmod 0755 "$SRC/vendor/bin/gpu_config.sh"

########################################
# 打包 + 依赖闭包/符号校验
# 按 vendor/sphal 链接器命名空间解析每个新增 ELF 的 DT_NEEDED, 并检查未定义符号。
# 抓到过 libLLVM 缺失 (Unable to create gbm device)、Android 15 的 libdmabufheap
# 只在 /system 下 (vendor 命名空间不可见)。
########################################
mkdir -p "$SRC/layer"
cp -a "$SRC/vendor" "$SRC/layer/"

msg "校验依赖闭包与符号 (链接器命名空间)"
python3 "$HERE/check-vendor-closure.py" "$BASE" "$SRC/layer"

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/$TAG.tar" -C "$SRC/layer" vendor
msg "$TAG.tar 就绪"

cat > "$OUT/Dockerfile.$TAG" <<EOF
FROM $BASE_IMAGE

ADD $TAG.tar /
EOF

if [ "${BUILD_IMAGE:-1}" = 1 ]; then
    msg "构建镜像 $NEW_IMAGE"
    $CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile.$TAG" "$OUT"
    msg "完成: $NEW_IMAGE"
else
    msg "已生成 $OUT/Dockerfile.$TAG, 自行构建"
fi
