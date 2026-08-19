# redroid-graft

把 [Waydroid](https://github.com/waydroid/waydroid) 的现代图形栈**嫁接**到
[redroid](https://github.com/remote-android/redroid-doc) 上，再加上 ARM 翻译和 Root。

面向的场景：在 Linux 服务器 / NAS 上用 Docker 多开 Android 实例挂机手游，用 scrcpy 看画面。

> 名字里的 *graft*（嫁接）就是这个项目的方法论：
> redroid 的容器化骨架 + Waydroid 的 gralloc4/Mesa 26 图形栈，
> 两者同为 Android 13 / x86_64，ABI 兼容，直接搬运二进制即可。

本仓库**只含构建脚本和文档**。Waydroid vendor、houdini、Magisk、GApps
等第三方二进制在构建时下载，不入库。`scripts/dl/`、`scripts/src/`、
`scripts/out/` 已 gitignore，**请勿提交，也请勿公开分发构建出的镜像**。

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

依赖：`podman` 或 `docker`、`curl`、`unzip`、`e2fsprogs`（`debugfs`）、
`python3`、`binutils`（`readelf`，做依赖闭包校验）。
Android 15 实验脚本额外需要 `p7zip`（`7z`，解 squashfs vendor）。

```bash
# 1. 图形层：gralloc4 + Mesa 26 + Vulkan（所有变体的底图）
./scripts/gralloc4.sh

# 2. 可选：再叠 houdini + Kitsune Magisk（跑 ARM 手游需要）
./scripts/build.sh
#    只要 houdini、不要 Magisk：
#    ROOT=none ./scripts/build.sh

# 3. 可选：再叠 GApps（Play 商店 / 登录；配方同 waydroid-helper MindTheGapps）
./scripts/inject-gapps.sh
#    叠到无 Magisk 的 houdini 底图：
#    BASE_IMAGE=localhost/redroid13-graft-houdini:latest \
#    NEW_IMAGE=localhost/redroid13-graft-houdini-gapps:latest \
#    ./scripts/inject-gapps.sh
```

产出镜像（**都带** gralloc4 + Mesa 26；变体写在镜像名里，tag 为 `latest`）：

| 镜像 | 内容 |
|---|---|
| `redroid13-graft:latest` | 仅图形栈改造 |
| `redroid13-graft-houdini:latest` | 同上 + houdini（无 Magisk） |
| `redroid13-graft-houdini-gapps:latest` | houdini + MindTheGapps（无 Magisk） |
| `redroid13-graft-ndk:latest` | 同上 + waydroid-helper ndk_translation（zork R136） |
| `redroid13-graft-ndk-gapps:latest` | ndk + MindTheGapps（无 Magisk） |
| `redroid13-graft-houdini-magisk:latest` | 同上 + houdini + Magisk（挂机手游常用） |
| `redroid13-graft-houdini-magisk-gapps:latest` | 同上 + MindTheGapps |

`ROOT=none ./scripts/build.sh` 只要 houdini不要 Magisk。  
`./scripts/inject-ndk.sh` 在 `redroid13-graft` 上叠 ChromeOS ndk（勿叠在 houdini 镜像上）。

`GAPPS=lite ./scripts/inject-gapps.sh` 可改用 LiteGapps。
`SKIP_SETUP=0` 保留 Setup Wizard（默认写入 `ro.setupwizard.mode=DISABLED`）。

两个脚本都会缓存下载内容到 `dl/`，重跑不会重复下载（共约 350 MB）。
用 `CTR=docker` 切换容器引擎。

运行（ARM 手游场景，用带 houdini 的变体）：

```bash
docker run -itd --privileged \
    --name android-1 \
    -v ~/redroid-data/1:/data \
    -p 5555:5555 \
    redroid13-graft-houdini-magisk:latest \
    androidboot.use_memfd=1 \
    androidboot.redroid_gpu_mode=host \
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
adb -s $D shell getprop ro.hardware.vulkan       # intel
# 以下仅 houdini-magisk 镜像：
adb -s $D shell getprop ro.dalvik.vm.native.bridge  # libhoudini.so
adb -s $D shell grep -c arm64 /linkerconfig/ld.config.txt  # >0
adb -s $D shell "echo id | /sbin/su"            # uid=0(root)
adb -s $D shell dumpsys package io.github.huskydg.magisk | grep versionName  # 非 1.0
adb -s $D exec-out screencap -p > /tmp/s.png    # 有画面
adb -s $D shell screenrecord --time-limit 3 /data/local/tmp/t.mp4  # 编码器正常
# Settings 不应拖死 allocator（见 TROUBLESHOOTING §7）
adb -s $D shell am start -a android.settings.APPLICATION_SETTINGS
adb -s $D logcat -d -b crash | grep allocator@4   # 应为空
# 游戏是否走 Vulkan：看 dumpsys gpu，别看 gfxinfo 的 Skia 行
adb -s $D shell dumpsys gpu | grep -E 'vkLoading|vkDriverLoadingTime|appPackageName'
```

任一项不对，看 [调试历程](docs/TROUBLESHOOTING.md)。

## 环境要求

- **宿主**：普通 Linux（Ubuntu/Debian/Arch 等），群晖等成品 NAS 固件通常不行
- **内核**：binder（`binder_linux` 模块或内置 binderfs）
- **GPU**：`/dev/dri/renderD128` 可用。默认打包 Intel 驱动，AMD/NVIDIA 见下
- **磁盘**：镜像约 2.5 GB

没有 ashmem 的新内核要加 `androidboot.use_memfd=1`（多数情况都需要）。

### GPU 支持

当前镜像**只打包 Intel Vulkan**（`vulkan.intel` / `intel_hasvk`），
`ro.hardware.vulkan=intel` 写死在属性里。实测环境：Intel Arc A380（`xe`）。

构建时会对 `libgbm_mesa_wrapper.so` 打补丁，跳过 allocate 时的 `gbm_bo_map`
探测（否则进系统设置会拖死 `allocator@4`）。详见 [TROUBLESHOOTING §7](docs/TROUBLESHOOTING.md)。

> 曾改为打包全厂商驱动 + `detect_gpu.sh` 自动选；后来确认 Settings 崩与此无关，
> 根因是 map_stride 探测。现保持 Intel-only 以减小面。

AMD/NVIDIA 需另改 `VK_DRIVERS` / `ro.hardware.vulkan` 再构建（尚未实机验证）。

## Android 15（实验）

```bash
./scripts/gralloc4-15.sh    # 产出 redroid15-graft:latest
```

从 Waydroid LOS22 的 squashfs `vendor.img` 提取图形栈（Mesa 链
`libLLVM21.so`，不是 13 上的 LLVM22）。houdini / Magisk / GApps
尚未针对 15 完整验证。

## 仓库结构

```
docs/ARCHITECTURE.md              每一层做了什么
docs/TROUBLESHOOTING.md           踩过的坑
patches/kitsune-pid-set-dynamic.patch
                                  可选：自编译 Kitsune 时用（pid_max > 32768）
scripts/gralloc4.sh               redroid 13 图形栈（主路径）
scripts/gralloc4-15.sh            redroid 15 图形栈（实验）
scripts/build.sh                  叠 houdini + 可选 Magisk
scripts/inject-gapps.sh           叠 MindTheGapps / LiteGapps
scripts/inject-ndk.sh             叠 ChromeOS ndk_translation（勿叠 houdini）
scripts/switch-ndk.sh             切回 redroid 自带 ndk（对比用）
scripts/patch-gbm-mesa-skip-map-stride.py
                                  Arc/xe：跳过 allocate 时的 map_stride 探测
```

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
ROOT=magisk ./scripts/build.sh        # 用官方 Magisk（产出 redroid13-graft-houdini-magisk-official:latest）
CTR=docker ./scripts/gralloc4.sh      # 用 docker 而非 podman
BUILD_IMAGE=0 ./scripts/gralloc4.sh   # 只生成 tar 层，不构建镜像
NEW_IMAGE=myrepo/android:13 ./scripts/gralloc4.sh
```

## 已知限制

- **只在 Intel Arc A380 + xe 驱动上实测过**。默认只打包 Intel Vulkan；
  AMD/NVIDIA 需改 `VK_DRIVERS` / `ro.hardware.vulkan`（尚未实机验证）。
- 镜像约 2.5 GB（主要是 Mesa 26 的 `libLLVM22` 64/32 位各一份）。
- 基于 redroid 13。更高版本 redroid 的 vendor 分区布局相同，
  理论上改 `gralloc4.sh` 的 `BASE_IMAGE` 即可，但 houdini 的 linker 补丁需要对应版本
  （`rote66/redroid_libhoudini_hack` 提供 9.0 ~ 15.0）。
- 构建产物含专有二进制，**不要公开分发镜像**。
