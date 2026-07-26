# redroid-graft

把 [Waydroid](https://github.com/waydroid/waydroid) 的现代图形栈**嫁接**到
[redroid](https://github.com/remote-android/redroid-doc) 上，再加上 ARM 翻译和 Root。

面向的场景：在 Linux 服务器 / NAS 上用 Docker 多开 Android 实例挂机手游，用 scrcpy 看画面。

> 名字里的 *graft*（嫁接）就是这个项目的方法论：
> redroid 的容器化骨架 + Waydroid 的 gralloc4/Mesa 26 图形栈，
> 两者同为 Android 13 / x86_64，ABI 兼容，直接搬运二进制即可。

## 解决了什么

redroid 是很好的容器化 Android 方案（无头、多开、adb 直连），但开箱跑不了很多手游：

| 问题 | 表现 | 本项目的处理 |
|---|---|---|
| 只有 x86 指令集 | ARM-only 的游戏装不上/闪退 | 注入 libhoudini |
| linker 命名空间限制 | houdini 加载 `libtcb.so` 被拒 → SIGABRT | 打 ld.config 补丁 |
| 无 root | 很多工具/脚本用不了 | 注入 Kitsune Magisk |
| **gralloc 只有 2.0** | **Vulkan-only 的 Unity 游戏黑屏/崩溃** | **移植 Waydroid 的 gralloc4 + Mesa 26** |

最后一项是核心。redroid 从 11 到 16 都只带 `graphics.allocator@2.0` 和 2024 年的 Mesa，
Vulkan 应用拿不到 swapchain buffer。本项目把 Waydroid（LineageOS 20）的整套现代图形栈
移植了过来，两者同为 Android 13 / x86_64，ABI 兼容。

实测环境：Ubuntu + Intel Arc A380（xe 驱动），少女前线2（Unity 2019.4 IL2CPP，Vulkan-only）、
赛马娘均可正常运行。

### 为什么不直接用 Waydroid

Waydroid 本身就有完整的 gralloc4 + Vulkan，桌面上跑游戏没问题。但：

- **硬编码单实例** —— 固定 `/var/lib/waydroid`、固定 LXC 容器名、
  独占 D-Bus 名 `id.waydro.Container`，多开需要改造 Waydroid 本身
- **强依赖 Wayland compositor** —— 无头服务器上还要再套 headless weston

而 redroid 天生无头、多开、adb 直连，正好相反。
所以选择保留 redroid 的骨架，只把 Waydroid 的图形栈嫁接过来。

## 快速开始

依赖：`podman` 或 `docker`、`curl`、`unzip`、`e2fsprogs`（提供 `debugfs`）、`python3`。

```bash
# 1. 基础层：houdini + Kitsune Magisk
./scripts/build.sh

# 2. 图形层：gralloc4 + Mesa 26 + Vulkan
./scripts/gralloc4.sh
```

产出两个镜像：

| 镜像 | 内容 |
|---|---|
| `redroid-graft:13.0.0-houdini-magisk` | 中间层，houdini + Magisk，没有图形栈改造 |
| `redroid-graft:13.0.0` | **最终镜像**，含完整 gralloc4 + Mesa 26 |

两个脚本都会缓存下载内容到 `dl/`，重跑不会重复下载（共约 350 MB）。
用 `CTR=docker` 切换容器引擎。

运行：

```bash
docker run -itd --privileged \
    --name android-1 \
    -v ~/redroid-data/1:/data \
    -p 5555:5555 \
    redroid-graft:13.0.0 \
    androidboot.use_memfd=1 \
    androidboot.redroid_fps=60 \
    androidboot.redroid_width=1080 \
    androidboot.redroid_height=1920 \
    androidboot.redroid_dpi=320

adb connect <IP>:5555
scrcpy -s <IP>:5555 --max-fps=60
```

多开就是改 `--name`、`-p` 和 `-v` 再跑一遍。

### 验证安装结果

```bash
D=<IP>:5555
adb -s $D shell dumpsys SurfaceFlinger | grep GLES
#   应为 Mesa 26.x，不是 24.x
adb -s $D shell getprop ro.hardware.gralloc      # minigbm_gbm_mesa
adb -s $D shell getprop ro.dalvik.vm.native.bridge  # libhoudini.so
adb -s $D shell grep -c arm64 /linkerconfig/ld.config.txt  # >0
adb -s $D shell "echo id | /sbin/su"            # uid=0(root)
adb -s $D shell dumpsys package io.github.huskydg.magisk | grep versionName  # 非 1.0
adb -s $D exec-out screencap -p > /tmp/s.png    # 有画面
adb -s $D shell screenrecord --time-limit 3 /data/local/tmp/t.mp4  # 编码器正常
```

任一项不对，看 [调试历程](docs/TROUBLESHOOTING.md)。

## 环境要求

- **宿主**：普通 Linux（Ubuntu/Debian/Arch 等），群晖等成品 NAS 固件通常不行
- **内核**：binder（`binder_linux` 模块或内置 binderfs）
- **GPU**：`/dev/dri/renderD128` 可用。默认打包 Intel 驱动，AMD/NVIDIA 见下
- **磁盘**：镜像约 2.5 GB

没有 ashmem 的新内核要加 `androidboot.use_memfd=1`（多数情况都需要）。

### GPU 支持

**不需要为不同显卡分别构建。** 镜像内置了各厂商驱动，开机自动选：

- **GL/GLES** — `libgallium_dri.so` 是 megadriver，一个文件内含
  radeonsi / iris / nouveau / zink / llvmpipe 等所有驱动，天然通用
- **Vulkan** — 分文件，所以全部打包（+50MB），
  `/vendor/bin/detect_gpu.sh` 在 early-init 读 `/sys/class/drm/renderD*/device/uevent`
  的内核驱动名自动选择

| 内核驱动 | Vulkan HAL | 状态 |
|---|---|---|
| `i915` / `xe` | `vulkan.intel` | 实测通过（Arc A380） |
| `amdgpu` | `vulkan.radeon` | 未实测 |
| `virtio_gpu` | `vulkan.virtio` | 未实测 |
| 其他 | `vulkan.lvp` | 软件渲染回退 |

需要时可用启动参数手动指定（优先于自动检测）：

```bash
docker run ... redroid-graft:13.0.0 ro.hardware.vulkan=radeon
```

> **NVIDIA 暂不可用**。Waydroid 镜像里没有 Mesa 26 的 nouveau/nvk驱动；
> redroid 自带的 `vulkan.nouveau.so` 是旧 Mesa 24，与 gralloc4 不兼容，
> 选中会崩溃，所以检测脚本故意不映射它，会回退到软件渲染。

## 文档

- [架构说明](docs/ARCHITECTURE.md) — 每一层做了什么，为什么这么做
- [调试历程](docs/TROUBLESHOOTING.md) — 踩过的坑和排查方法，遇到问题先看这里

## 致谢

本项目本质上只是把别人做好的东西接到一起，真正的工作在上游：

- [Waydroid](https://github.com/waydroid/waydroid) — **gralloc4 / minigbm_gbm_mesa / Mesa 26
  整套图形栈都是他们做的**，包括专为 Mesa 适配的 gralloc 实现
- [remote-android/redroid](https://github.com/remote-android/redroid-doc) — 容器化 Android 基础镜像
- [waydroid-helper/extensions](https://github.com/waydroid-helper/extensions) — houdini / Magisk 配方
- [rote66/redroid_libhoudini_hack](https://github.com/rote66/redroid_libhoudini_hack) — linker 补丁
- [supremegamers](https://github.com/supremegamers) — libhoudini 二进制
- [ayasa520/KitsuneMagisk](https://github.com/ayasa520/KitsuneMagisk) — 适配容器的 Magisk

## 许可

脚本本身 MIT。注意脚本会下载并重打包第三方专有二进制
（Intel libhoudini、Mesa、Magisk 等），各自遵循其原始许可，**请勿分发构建产物**。

## 构建选项

```bash
ROOT=magisk ./scripts/build.sh        # 用官方 Magisk 代替 Kitsune
CTR=docker ./scripts/build.sh         # 用 docker 而非 podman
BUILD_IMAGE=0 ./scripts/gralloc4.sh   # 只生成 tar 层，不构建镜像
NEW_IMAGE=myrepo/android:13 ./scripts/gralloc4.sh
```

## 已知限制

- **只在 Intel Arc A380 + xe 驱动上实测过**。AMD 的驱动已打包且检测逻辑已就位，
  但没有实机验证；NVIDIA 因缺少 Mesa 26 的 nouveau 驱动暂不可用（会回退软件渲染）。
- 镜像约 2.6 GB（Mesa 26 的 LLVM 后端 64/32 位各一份占 220 MB，全厂商 Vulkan 驱动占 50 MB）。
- 基于 redroid 13。更高版本 redroid 的 vendor 分区布局相同，
  理论上改 `BASE_IMAGE` 即可，但 houdini 的 linker 补丁需要对应版本
  （`rote66/redroid_libhoudini_hack` 提供 9.0 ~ 15.0）。
- 构建产物含专有二进制，**不要公开分发镜像**。
