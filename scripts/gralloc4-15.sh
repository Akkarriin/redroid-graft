#!/bin/bash
# 把 Waydroid LOS22 (Android 15) 的 gralloc4/minigbm 嫁接到 redroid 15
#
# 与 gralloc4.sh (LOS20→redroid13) 的差异:
#   - vendor.img 是 squashfs → 用 7z 解包，不用 debugfs
#   - Mesa 链 libLLVM21.so（不是 LLVM22）
#   - map_stride 补丁覆盖 LOS22 wrapper（Intel Arc/xe）
#   - 默认底图 redroid:15.0.0-latest
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
SRC="$HERE/src/gralloc4-15"
OUT="$HERE/out"
CTR=${CTR:-podman}

WD_VENDOR_ZIP="${WD_VENDOR_ZIP:-$DL/waydroid-los22-20260224-x86_64.zip}"
WD_VENDOR_URL="${WD_VENDOR_URL:-https://github.com/WayDroid-ATV/waydroid-builds/releases/download/20260224/lineage-22.2-20260224-UNOFFICIAL-waydroid_x86_64.zip}"

BASE_IMAGE="${BASE_IMAGE:-docker.io/redroid/redroid:15.0.0-latest}"
NEW_IMAGE="${NEW_IMAGE:-localhost/redroid15-graft:latest}"

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

command -v 7z >/dev/null || { echo "需要 7z（squashfs vendor）" >&2; exit 1; }

mkdir -p "$DL" "$OUT"
rm -rf "$SRC"; mkdir -p "$SRC/vendor/lib64/hw" "$SRC/vendor/bin/hw" \
                        "$SRC/vendor/etc/init" "$SRC/vendor/etc/vintf/manifest"

if [ ! -f "$WD_VENDOR_ZIP" ]; then
    msg "下载 Waydroid LOS22 镜像"
    curl -fL --retry 3 -o "$WD_VENDOR_ZIP" "$WD_VENDOR_URL"
fi

msg "从 squashfs 提取 vendor.img"
unzip -oq "$WD_VENDOR_ZIP" vendor.img -d "$SRC"
VIMG="$SRC/vendor.img"
file "$VIMG" | grep -qi squashfs || { echo "预期 squashfs vendor.img" >&2; exit 1; }

ex() { # path-in-img  dest
    local src=$1 dest=$2
    mkdir -p "$(dirname "$dest")"
    7z e -so "$VIMG" "$src" > "$dest" 2>/dev/null
    [ -s "$dest" ] || { echo "提取失败: $src" >&2; exit 1; }
}

msg "提取 gralloc4 组件"
ex bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa \
   "$SRC/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa"
for l in android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so \
         gralloc.minigbm_gbm_mesa.so; do
    ex "lib64/hw/$l" "$SRC/vendor/lib64/hw/$l"
done
# libdmabufheap: allocator/mapper@4 硬依赖；必须放进 vendor，
# 否则 sphal 可能误解析到 /system/lib64/arm64 里 MuMu 的 ARM 副本。
for l in libminigbm_gralloc_gbm_mesa.so libgbm_mesa.so libgbm_mesa_wrapper.so \
         libdrm.so libdmabufheap.so; do
    ex "lib64/$l" "$SRC/vendor/lib64/$l"
done

# LOS22: LLVM21（LOS20/23 是 LLVM22）
for l in dri_gbm.so libgallium_dri.so libLLVM21.so \
         libdrm_intel.so libdrm_amdgpu.so libdrm_radeon.so; do
    ex "lib64/$l" "$SRC/vendor/lib64/$l"
done

mkdir -p "$SRC/vendor/lib64/egl"
for l in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so; do
    ex "lib64/egl/$l" "$SRC/vendor/lib64/egl/$l"
done

VK_DRIVERS="${VK_DRIVERS:-vulkan.intel.so vulkan.intel_hasvk.so}"
for l in $VK_DRIVERS; do
    ex "lib64/hw/$l" "$SRC/vendor/lib64/hw/$l"
done

msg "提取 32 位组件"
mkdir -p "$SRC/vendor/lib/hw" "$SRC/vendor/lib/egl"
for l in android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so \
         gralloc.minigbm_gbm_mesa.so; do
    ex "lib/hw/$l" "$SRC/vendor/lib/hw/$l"
done
for l in libminigbm_gralloc_gbm_mesa.so libgbm_mesa.so libgbm_mesa_wrapper.so \
         libdrm.so libdmabufheap.so dri_gbm.so libgallium_dri.so libLLVM21.so \
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

msg "打 map_stride 补丁（Intel Arc/xe：跳过 allocate 时 gbm_bo_map）"
python3 "$HERE/patch-gbm-mesa-skip-map-stride.py" \
    "$SRC/vendor/lib64/libgbm_mesa_wrapper.so"
if [ -f "$SRC/vendor/lib/libgbm_mesa_wrapper.so" ]; then
    python3 "$HERE/patch-gbm-mesa-skip-map-stride.py" \
        "$SRC/vendor/lib/libgbm_mesa_wrapper.so"
fi

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

msg "改写 vendor manifest.xml"
CID=$($CTR create "$BASE_IMAGE")
$CTR cp "$CID:/vendor/etc/vintf/manifest.xml" "$SRC/manifest.xml.orig"
$CTR rm "$CID" >/dev/null

python3 - "$SRC/manifest.xml.orig" "$SRC/vendor/etc/vintf/manifest.xml" <<'PYEOF'
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
chmod 0644 "$SRC/vendor/etc/vintf/manifest.xml"

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
seen, out = set(), []
for ln in lines:
    m = re.match(r"^([\w.]+)=", ln)
    if m and m.group(1) in props:
        k = m.group(1); out.append(f"{k}={props[k]}"); seen.add(k)
    else:
        out.append(ln)
rest = [k for k in props if k not in seen]
if rest:
    out.append("# gralloc4 / vulkan (LOS22)")
    out += [f"{k}={props[k]}" for k in rest]
open(p, "w").write("\n".join(out) + "\n")
print("patched vendor/build.prop:", ", ".join(props))
PYEOF

mkdir -p "$SRC/layer/vendor"
cp -a "$SRC/vendor/." "$SRC/layer/vendor/"
cp "$SRC/props/build.prop" "$SRC/layer/vendor/build.prop"
chmod 0644 "$SRC/layer/vendor/build.prop"
# vendor.img 本身不要打进层
rm -f "$SRC/layer/vendor/../vendor.img" 2>/dev/null || true
find "$SRC/layer" -name 'vendor.img' -delete 2>/dev/null || true

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/gralloc4-15.tar" -C "$SRC/layer" vendor
msg "gralloc4-15.tar 就绪"

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

cat > "$OUT/Dockerfile.gralloc4-15" <<EOF
FROM $BASE_IMAGE

ADD gralloc4-15.tar /
EOF

if [ "${BUILD_IMAGE:-1}" = 1 ]; then
    msg "构建镜像 $NEW_IMAGE"
    $CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile.gralloc4-15" "$OUT"
    msg "完成: $NEW_IMAGE"
else
    msg "已生成 $OUT/Dockerfile.gralloc4-15"
fi
