#!/bin/bash
# 在宿主机上测试 files/gpu_config.sh 的 GPU 选择逻辑 (不需要 Android / GPU)。
# setprop/getprop/log/chmod 用桩替代; ro.* 模拟 Android 的"先写者胜"。
# 用 mksh (Android /system/bin/sh 的实现) 跑; 没有则退回 sh。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SH=$(command -v mksh || command -v sh)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/setprop" <<'EOF'
#!/bin/sh
case "$1" in
    ro.*) grep -q "^$1=" "$PROPS" && exit 0 ;;
    *) sed -i "/^$1=/d" "$PROPS" ;;
esac
echo "$1=$2" >> "$PROPS"
EOF
cat > "$T/bin/getprop" <<'EOF'
#!/bin/sh
v=$(sed -n "s/^$1=//p" "$PROPS" | head -n 1)
echo "${v:-$2}"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/log"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/chmod"
chmod +x "$T/bin/"*

# 两种嫁接结果: LOS20 没有 NVK; LOS22 带 vulkan.nouveau.so
sed 's/@GRAFT_VK_DRIVERS@/intel intel_hasvk radeon virtio/' \
    "$HERE/files/gpu_config.sh" > "$T/gpu_config.sh"
sed 's/@GRAFT_VK_DRIVERS@/intel intel_hasvk radeon virtio nouveau/' \
    "$HERE/files/gpu_config.sh" > "$T/gpu_config_nvk.sh"

FAIL=0
# args: 名称 期望属性(空格分隔 k=v, v 为空表示未设置) [启动属性 k=v | 节点规格]...
# 节点规格: <minor>:<driver>[:<i915_capabilities 首行>];  @nvk 表示用带 NVK 的嫁接结果
run() {
    local name=$1 expect=$2; shift 2
    local dri="$T/dri" props="$T/props" script="$T/gpu_config.sh"
    rm -rf "$dri"; mkdir -p "$dri"; : > "$props"
    for spec in "$@"; do
        case "$spec" in
            @nvk) script="$T/gpu_config_nvk.sh"; continue ;;
            *=*) echo "$spec" >> "$props"; continue ;;
        esac
        IFS=: read -r minor drv caps <<< "$spec"
        mkdir -p "$dri/$minor" "$dri/$((minor - 128))"
        echo "$drv dev=0000:03:00.0 unique=0000:03:00.0" > "$dri/$minor/name"
        [ -n "$caps" ] && printf '%s\nplatform: X\n' "$caps" > "$dri/$((minor - 128))/i915_capabilities"
    done
    local out
    out=$(cd "$T" && PATH="$T/bin:$PATH" PROPS="$props" GRAFT_DRI_DEBUGFS="$dri" \
          "$SH" "$script" 2>&1)
    local ok=1 kv k v got
    for kv in $expect; do
        k=${kv%%=*}; v=${kv#*=}
        got=$(sed -n "s/^$k=//p" "$props" | head -n 1)
        if [ "$got" != "$v" ]; then
            echo "FAIL [$name] $k: got '$got', want '$v'"; ok=0
        fi
    done
    if [ $ok = 1 ]; then
        echo "ok   [$name]"
    else
        printf '       | %s\n' "${out//$'\n'/$'\n       | '}"; FAIL=1
    fi
}

G=ro.hardware.gralloc=minigbm_gbm_mesa
E=ro.hardware.egl=mesa

run "Arc on xe"            "$G $E ro.hardware.vulkan=intel gralloc.gbm.device=/dev/dri/renderD128" \
    128:xe
run "Arc/Xe on i915 (12.55)" "$G ro.hardware.vulkan=intel" \
    "128:i915:graphics version: 12.55"
run "Skylake (gen: 9)"     "ro.hardware.vulkan=intel"        "128:i915:gen: 9"
run "Haswell (gen: 7)"     "ro.hardware.vulkan=intel_hasvk"  "128:i915:gen: 7"
run "Broadwell new kernel" "ro.hardware.vulkan=intel_hasvk"  "128:i915:graphics version: 8"
run "i915 no capabilities" "ro.hardware.vulkan=intel"        128:i915
run "AMD"                  "$G ro.hardware.vulkan=radeon"    128:amdgpu
run "virtio-gpu (VM)"      "ro.hardware.vulkan=virtio"       128:virtio_gpu
run "nouveau without grafted NVK: GL only" \
    "$G gralloc.gbm.device=/dev/dri/renderD128 ro.hardware.vulkan=" 128:nouveau
run "nouveau with grafted NVK" "ro.hardware.vulkan=nouveau" @nvk 128:nouveau
run "skip unqualified node" "ro.hardware.vulkan=radeon gralloc.gbm.device=/dev/dri/renderD129" \
    128:vgem 129:amdgpu
run "first qualified wins (iGPU + dGPU)" \
    "ro.hardware.vulkan=intel gralloc.gbm.device=/dev/dri/renderD128" 128:i915 129:amdgpu
run "forced node picks dGPU" \
    "ro.hardware.vulkan=radeon gralloc.gbm.device=/dev/dri/renderD129" \
    ro.boot.redroid_gpu_node=/dev/dri/renderD129 128:i915 129:amdgpu
run "forced vulkan override" "ro.hardware.vulkan=intel_hasvk" \
    ro.boot.redroid_vulkan=intel_hasvk 128:xe
run "forced vulkan not grafted" "ro.hardware.vulkan=" \
    ro.boot.redroid_vulkan=lvp 128:xe
run "guest mode → host"    "$G $E ro.hardware.vulkan=intel" \
    ro.boot.redroid_gpu_mode=guest 128:xe
run "no GPU at all"        "$G ro.hardware.vulkan= gralloc.gbm.device="
run "fps default 30, explicit wins" "ro.boot.redroid_fps=60" ro.boot.redroid_fps=60 128:xe

exit $FAIL
