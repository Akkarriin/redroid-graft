#!/system/bin/sh
# redroid-graft: 替换 redroid 原版 /vendor/bin/gpu_config.sh
# 由 redroid.common.rc 在 early-boot 执行, 早于 allocator / SurfaceFlinger。
#
# 与原版的差异:
#   - 图形栈是 gralloc4 (minigbm_gbm_mesa) + Mesa 26, 只有 host 模式。
#     原版 guest 模式依赖的 allocator@2.0 已停用, guest/auto 一律按 host 处理并告警
#   - 识别 Intel xe 内核驱动 (Arc 等), 原版只认 i915
#   - i915 按代际选 ANV (intel, Gen9+) 或 hasvk (intel_hasvk, Gen7/8)
#   - 只选本镜像嫁接的 Mesa 26 Vulkan 驱动 (GRAFT_VK_DRIVERS)。基础镜像残留的
#     Mesa 24 驱动不认识 gralloc4 buffer, 宁可不设也不加载
#   - nouveau 映射到 NVK (原版不给 nouveau 设 Vulkan)
#   - androidboot.redroid_vulkan=<名字> 可强制指定 (仍须在 GRAFT_VK_DRIVERS 内)
#   - 只给最终选中的 render node 设置 Vulkan (原版对每个节点都调用一次)
#   - 结果写进 logcat (tag gpu_config), 原版只 echo 到 init 的 /dev/null
#
# 属性在这里运行时设置, 不再写死进 vendor/build.prop: ro.* 先写者胜,
# build.prop 里写了会让这里的 setprop 静默失败。

# 构建时由 gralloc4.sh 替换为实际嫁接的驱动列表
GRAFT_VK_DRIVERS="@GRAFT_VK_DRIVERS@"
DRI_DEBUGFS=${GRAFT_DRI_DEBUGFS:-/sys/kernel/debug/dri}

log_i() { echo "$*"; log -p i -t gpu_config "$*" 2>/dev/null; }
log_w() { echo "WARN: $*"; log -p w -t gpu_config "$*" 2>/dev/null; }
log_e() { echo "ERROR: $*"; log -p e -t gpu_config "$*" 2>/dev/null; }

set_vulkan() {
    case " $GRAFT_VK_DRIVERS " in
        *" $1 "*)
            setprop ro.hardware.vulkan "$1"
            log_i "vulkan driver: $1"
            ;;
        *)
            log_w "vulkan driver '$1' is not grafted (have: $GRAFT_VK_DRIVERS), Vulkan disabled"
            ;;
    esac
}

# args: debugfs-index
# ANV 只支持 Gen9+ (Skylake 起); Gen7/7.5/8 (Ivy Bridge/Haswell/Broadwell) 要用 hasvk。
# i915_capabilities 旧内核写 "gen: 8", 新内核写 "graphics version: 12.55";
# 文件一般在 primary minor 目录下, 所以 render minor 和 minor-128 都试。
intel_vk() {
    case "$1" in
        ''|*[!0-9]*) echo intel; return ;;
    esac
    for idx in "$1" "$(($1 - 128))"; do
        f="$DRI_DEBUGFS/$idx/i915_capabilities"
        [ -r "$f" ] || continue
        ver=$(grep -E '^(gen|graphics version):' "$f" | head -n 1 | tr -dc '0-9.')
        ver=${ver%%.*}
        [ -n "$ver" ] || continue
        if [ "$ver" -lt 9 ]; then
            echo intel_hasvk
        else
            echo intel
        fi
        return
    done
    echo intel
}

# args: driver debugfs-index
setup_vulkan() {
    forced=$(getprop ro.boot.redroid_vulkan)
    if [ -n "$forced" ]; then
        log_i "vulkan forced by androidboot.redroid_vulkan=$forced"
        set_vulkan "$forced"
        return
    fi
    case "$1" in
        i915)
            set_vulkan "$(intel_vk "$2")"
            ;;
        xe)
            # xe 只驱动 Xe 架构 (Gen12+), 一律 ANV
            set_vulkan intel
            ;;
        amdgpu)
            set_vulkan radeon
            ;;
        virtio_gpu)
            set_vulkan virtio
            ;;
        nouveau)
            # NVK; 只有 Waydroid vendor 带了 Mesa 26 的 vulkan.nouveau.so 时才可用
            set_vulkan nouveau
            ;;
        *)
            log_w "no grafted vulkan driver for kernel driver: $1"
            ;;
    esac
}

# args: driver
qualified_driver() {
    case "$1" in
        i915|xe|amdgpu|nouveau|virtio_gpu) return 0 ;;
    esac
    return 1
}

# args: render-node debugfs-index driver
use_render_node() {
    log_i "use render node: $1 (driver: $3)"
    setprop gralloc.gbm.device "$1"
    chmod 666 "$1"
    setup_vulkan "$3" "$2"
}

setup_render_node() {
    node=$(getprop ro.boot.redroid_gpu_node)
    if [ -n "$node" ]; then
        idx=${node#/dev/dri/renderD}
        driver=$(cut -d' ' -f1 "$DRI_DEBUGFS/$idx/name")
        log_i "force render node: $node"
        use_render_node "$node" "$idx" "$driver"
        return 0
    fi

    cd "$DRI_DEBUGFS" || return 1
    for d in * ; do
        case "$d" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$d" -ge 128 ] || continue
        driver="$(cut -d' ' -f1 "$d/name")"
        log_i "DRI node exists, driver: $driver"
        if qualified_driver "$driver"; then
            use_render_node "/dev/dri/renderD$d" "$d" "$driver"
            return 0
        fi
    done

    log_e "NO qualified render node found"
    return 1
}

gpu_setup_host() {
    setprop ro.hardware.egl mesa
    setprop ro.hardware.gralloc minigbm_gbm_mesa
    setprop ro.boot.redroid_fps 30
}

gpu_setup() {
    mode=$(getprop ro.boot.redroid_gpu_mode host)
    if [ "$mode" != "host" ]; then
        log_w "redroid-graft only supports host GPU mode, ignoring redroid_gpu_mode=$mode"
    fi
    setup_render_node || log_e "graphics will not start without a GPU render node"
    gpu_setup_host
    log_i "gralloc=$(getprop ro.hardware.gralloc) egl=$(getprop ro.hardware.egl)" \
          "vulkan=$(getprop ro.hardware.vulkan) node=$(getprop gralloc.gbm.device)"
}

gpu_setup
