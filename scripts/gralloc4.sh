#!/bin/bash
# 把 Waydroid(LineageOS 20) 的 gralloc4/minigbm 移植进 redroid 13
#
# 背景: redroid 只有 graphics.allocator@2.0 + 老式 gbm_gralloc,
#       Mesa ANV(Vulkan) 需要 gralloc4 才能分配 swapchain buffer,
#       否则 dequeueBuffer 返回 -22, Vulkan-only 的 Unity 游戏无法运行。
# 两者同为 Android 13 / x86_64, ABI 兼容, 直接搬运二进制。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
SRC="$HERE/src/gralloc4"
OUT="$HERE/out"
CTR=${CTR:-podman}

WD_VENDOR_URL="https://sourceforge.net/projects/waydroid/files/images/vendor/waydroid_x86_64/lineage-20.0-20260428-MAINLINE-waydroid_x86_64-vendor.zip/download"
WD_VENDOR_ZIP="$DL/waydroid-vendor.zip"

# 基底镜像: 必须是已注入 houdini 的那个,
# 否则下面取 build.prop 会拿到原版值, 把 native bridge 设置冲掉
BASE_IMAGE="${BASE_IMAGE:-localhost/redroid-graft:13.0.0-houdini-magisk}"
NEW_IMAGE="${NEW_IMAGE:-localhost/redroid-graft:13.0.0}"

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

mkdir -p "$DL" "$OUT"
rm -rf "$SRC"; mkdir -p "$SRC/vendor/lib64/hw" "$SRC/vendor/bin/hw" \
                        "$SRC/vendor/etc/init" "$SRC/vendor/etc/vintf/manifest"

if [ ! -f "$WD_VENDOR_ZIP" ]; then
    msg "下载 Waydroid vendor 镜像"
    curl -fL --retry 3 -o "$WD_VENDOR_ZIP" "$WD_VENDOR_URL"
fi

msg "解包 vendor.img"
VIMG="$SRC/vendor.img"
unzip -oq "$WD_VENDOR_ZIP" -d "$SRC"

# debugfs 免 root 读取 ext 镜像
ex() { # src-in-img  dest
    debugfs -R "dump /$1 $2" "$VIMG" 2>/dev/null
    [ -s "$2" ] || { echo "提取失败: $1" >&2; exit 1; }
}

msg "提取 gralloc4 组件"
ex bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa \
   "$SRC/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa"
for l in android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so \
         gralloc.minigbm_gbm_mesa.so; do
    ex "lib64/hw/$l" "$SRC/vendor/lib64/hw/$l"
done
# minigbm 及其 gbm 后端 + libdrm (redroid 没有)
for l in libminigbm_gralloc_gbm_mesa.so libgbm_mesa.so libgbm_mesa_wrapper.so libdrm.so; do
    ex "lib64/$l" "$SRC/vendor/lib64/$l"
done

# Mesa 26 的 gbm 后端.
# redroid 自带 Mesa 24.0.8, 对 Arc(xe 内核驱动) 支持不完整,
# minigbm 会报 "Found GPU xe" 后 "Unable to create gbm_mesa driver".
# libgbm_mesa.so 通过 MESA-LOADER 在 /vendor/lib64 找 dri_gbm.so,
# dri_gbm.so 再链到 libgallium_dri.so(megadriver, 含 xe 支持)
# 注意: redroid 自带的是 libdrm.so.2 / libdrm_intel.so.1 这种带版本后缀的名字,
# Mesa 26 链的是无后缀的 libdrm.so / libdrm_intel.so, 两套可共存不冲突.
# libLLVM22.so 是 gallium 的着色器编译器, 缺失会导致 gbm_create_device 失败
for l in dri_gbm.so libgallium_dri.so libLLVM22.so \
         libdrm_intel.so libdrm_amdgpu.so libdrm_radeon.so; do
    ex "lib64/$l" "$SRC/vendor/lib64/$l"
done

# EGL/GLES 也必须一起换成 Mesa 26:
# redroid 自带的 libEGL_mesa.so(Mesa 24) 走的是 gralloc0 接口(日志 "Using gralloc0 CrOS API"),
# 与 gralloc4 分配的 buffer handle 结构对不上,
# 导致 SurfaceFlinger 在 gbm_mesa_bo_import 里空指针 SIGSEGV。
# Mesa 26 的 EGL 直接链 mapper@4.0 + libgralloctypes, 原生支持 gralloc4。
mkdir -p "$SRC/vendor/lib64/egl"
for l in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so; do
    ex "lib64/egl/$l" "$SRC/vendor/lib64/egl/$l"
done

# Vulkan HAL 也必须是 Mesa 26 的 ANV:
# redroid 自带 Mesa 24 的 vulkan.intel.so 不认识 gralloc4 分配的 buffer,
# 导致 "vkCreateImage w/ native buffer failed" → GetSwapchainImagesKHR 空指针崩溃。
# 只带 intel(Arc/核显); 如果你的 GPU 是 AMD/NV, 把对应驱动加到这里
VK_DRIVERS="${VK_DRIVERS:-vulkan.intel.so vulkan.intel_hasvk.so}"
for l in $VK_DRIVERS; do
    ex "lib64/hw/$l" "$SRC/vendor/lib64/hw/$l"
done

########################################
# 32 位一整套
# mapper 是 passthrough(进程内加载), 32 位进程需要 32 位实现。
# redroid 的 android.hardware.media.omx@1.0-service 是 32 位,
# 缺失时会 abort: "gralloc-mapper is missing",
# 导致 screenrecord/scrcpy 编码器拿不到 buffer(灰屏)。
########################################
msg "提取 32 位组件"
mkdir -p "$SRC/vendor/lib/hw" "$SRC/vendor/lib/egl"
for l in android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so \
         gralloc.minigbm_gbm_mesa.so; do
    ex "lib/hw/$l" "$SRC/vendor/lib/hw/$l"
done
for l in libminigbm_gralloc_gbm_mesa.so libgbm_mesa.so libgbm_mesa_wrapper.so \
         libdrm.so dri_gbm.so libgallium_dri.so libLLVM22.so \
         libdrm_intel.so libdrm_amdgpu.so libdrm_radeon.so; do
    ex "lib/$l" "$SRC/vendor/lib/$l"
done
for l in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so; do
    ex "lib/egl/$l" "$SRC/vendor/lib/egl/$l"
done
for l in $VK_DRIVERS; do
    ex "lib/hw/$l" "$SRC/vendor/lib/hw/$l"
done

chmod 0755 "$SRC/vendor/bin/hw/"* 
chmod 0644 "$SRC/vendor/lib64/"*.so "$SRC/vendor/lib64/hw/"*.so "$SRC/vendor/lib64/egl/"*.so \
           "$SRC/vendor/lib/"*.so "$SRC/vendor/lib/hw/"*.so "$SRC/vendor/lib/egl/"*.so

########################################
# VINTF: 声明 allocator@4.0 / mapper@4.0
# redroid 的 vendor/etc/vintf/manifest/ 是目录, 直接放文件即可,
# 不需要 Waydroid 那套 manifest.disabled + bind mount
########################################
msg "生成 VINTF manifest"
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
chmod 0644 "$SRC/vendor/etc/vintf/manifest/"*.xml

########################################
# init: 启动 allocator@4.0, 停用 2.0
########################################
msg "生成 init rc"
cat > "$SRC/vendor/etc/init/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa.rc" <<'EOF'
service vendor.graphics.allocator-4-0 /vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa
    interface android.hardware.graphics.allocator@4.0::IAllocator default
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE
    onrestart restart surfaceflinger
    task_profiles ServiceCapacityLow

on early-init
    stop vendor.gralloc-2-0
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
# 主 manifest: 移除 allocator@2.0 / mapper@2.1 声明
########################################
msg "改写 vendor manifest.xml"
CID=$($CTR create "$BASE_IMAGE")
$CTR cp "$CID:/vendor/etc/vintf/manifest.xml" "$SRC/manifest.xml.orig"
$CTR rm "$CID" >/dev/null

python3 - "$SRC/manifest.xml.orig" "$SRC/vendor/etc/vintf/manifest.xml" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
x = open(src).read()
# 删掉 graphics.allocator 和 graphics.mapper 的 <hal> 块, 由新 manifest 文件提供 4.0 版本
pat = re.compile(
    r'[ \t]*<hal format="hidl">\s*<name>android\.hardware\.graphics\.'
    r'(?:allocator|mapper)</name>.*?</hal>\n', re.S)
x2, n = pat.subn('', x)
assert n == 2, f"预期删除 2 个 hal 块, 实际 {n}"
open(dst, 'w').write(x2)
print(f"已移除 {n} 个旧 graphics HAL 声明")
PYEOF
chmod 0644 "$SRC/vendor/etc/vintf/manifest.xml"

########################################
# 属性
########################################
msg "生成属性覆盖"
mkdir -p "$SRC/props"
CID=$($CTR create "$BASE_IMAGE")
$CTR cp "$CID:/vendor/build.prop" "$SRC/props/build.prop"
$CTR rm "$CID" >/dev/null

python3 - "$SRC/props/build.prop" <<'PYEOF'
import re, sys
p = sys.argv[1]
props = {
    "ro.hardware.gralloc": "minigbm_gbm_mesa",
    "ro.hardware.vulkan": "intel",
    "ro.hardware.egl": "mesa",
}
lines = open(p).read().splitlines()
seen = set()
out = []
for ln in lines:
    m = re.match(r"^([\w.]+)=", ln)
    if m and m.group(1) in props:
        k = m.group(1); out.append(f"{k}={props[k]}"); seen.add(k)
    else:
        out.append(ln)
rest = [k for k in props if k not in seen]
if rest:
    out.append("# gralloc4 / vulkan")
    out += [f"{k}={props[k]}" for k in rest]
open(p, "w").write("\n".join(out) + "\n")
print("patched vendor/build.prop:", ", ".join(props))
PYEOF

mkdir -p "$SRC/layer/vendor"
cp -a "$SRC/vendor/." "$SRC/layer/vendor/"
cp "$SRC/props/build.prop" "$SRC/layer/vendor/build.prop"
chmod 0644 "$SRC/layer/vendor/build.prop"

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/gralloc4.tar" -C "$SRC/layer" vendor
msg "gralloc4.tar 就绪"

########################################
# 依赖闭包校验
# 遍历新增的每个 .so, 确认其 DT_NEEDED 要么在本层、要么基础镜像已有。
# 这个检查抳到过 libLLVM22.so 的缺失(表现为 Unable to create gbm device)
########################################
msg "校验依赖闭包"
BASE_LIST="$SRC/base.filelist"
CID=$($CTR create "$BASE_IMAGE")
$CTR export "$CID" 2>/dev/null | tar tf - > "$BASE_LIST" 2>/dev/null || true
$CTR rm "$CID" >/dev/null

MISSING=0
for B in lib lib64; do
    d="$SRC/vendor/$B"
    [ -d "$d" ] || continue
    deps=$(cd "$d" && for f in *.so egl/*.so hw/*.so; do
        [ -f "$f" ] && readelf -d "$f" 2>/dev/null | grep NEEDED |
            grep -oE '\[[^]]+\]' | tr -d '[]'
    done | sort -u)
    for L in $deps; do
        [ -f "$d/$L" ] || [ -f "$d/hw/$L" ] || [ -f "$d/egl/$L" ] && continue
        esc=$(printf '%s' "$L" | sed 's/[.[\*^$]/\\&/g')
        grep -qE "(system|vendor)/$B/(hw/|egl/)?$esc\$" "$BASE_LIST" || {
            echo "  !! $B 缺失依赖: $L" >&2; MISSING=1; }
    done
done
[ "$MISSING" = 0 ] && msg "依赖闭包 OK" || { echo "存在未满足的依赖, 终止" >&2; exit 1; }

########################################
# 构建镜像
########################################
cat > "$OUT/Dockerfile.gralloc4" <<EOF
FROM $BASE_IMAGE

ADD gralloc4.tar /
EOF

if [ "${BUILD_IMAGE:-1}" = 1 ]; then
    msg "构建镜像 $NEW_IMAGE"
    $CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile.gralloc4" "$OUT"
    msg "完成: $NEW_IMAGE"
else
    msg "已生成 $OUT/Dockerfile.gralloc4, 自行构建"
fi
