# redroid-gaming

给 [redroid](https://github.com/remote-android/redroid-doc) 加上 **ARM 翻译**、**Root** 和 **完整 Vulkan 支持**的构建脚本。

面向的场景：在 Linux 服务器 / NAS 上用 Docker 多开 Android 实例挂机手游，用 scrcpy 看画面。

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

## 快速开始

依赖：`podman` 或 `docker`、`curl`、`unzip`、`e2fsprogs`（提供 `debugfs`）、`python3`。

```bash
# 1. 基础层：houdini + Kitsune Magisk
./scripts/build.sh

# 2. 图形层：gralloc4 + Mesa 26 + Vulkan
./scripts/gralloc4.sh
# 产出 localhost/redroid:13.0.0-gaming
```

两个脚本都会缓存下载内容到 `dl/`，重跑不会重复下载（共约 350 MB）。
用 `CTR=docker` 切换容器引擎。

运行：

```bash
docker run -itd --privileged \
    --name android-1 \
    -v ~/redroid-data/1:/data \
    -p 5555:5555 \
    redroid:13-gaming \
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

### 换 GPU 厂商

`gralloc4.sh` 里 Vulkan 驱动是变量：

```bash
VK_DRIVERS="vulkan.radeon.so" ./scripts/gralloc4.sh          # AMD
VK_DRIVERS="vulkan.nouveau.so" ./scripts/gralloc4.sh         # NVIDIA(nouveau)
```

同时把 `ro.hardware.vulkan` 改成 `radeon` / `nouveau`（脚本内 `props` 字典）。

## 文档

- [架构说明](docs/ARCHITECTURE.md) — 每一层做了什么，为什么这么做
- [调试历程](docs/TROUBLESHOOTING.md) — 踩过的坑和排查方法，遇到问题先看这里

## 致谢

- [remote-android/redroid](https://github.com/remote-android/redroid-doc) — 基础镜像
- [Waydroid](https://github.com/waydroid/waydroid) — gralloc4 / minigbm / Mesa 26 图形栈来源
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

- **只在 Intel Arc A380 + xe 驱动上实测过**。其他 GPU 理论可行但未验证。
- 镜像约 2.5 GB（Mesa 26 的 LLVM 后端 64/32 位各一份就占了 220 MB）。
- 基于 redroid 13。更高版本 redroid 的 vendor 分区布局相同，
  理论上改 `BASE_IMAGE` 即可，但 houdini 的 linker 补丁需要对应版本
  （`rote66/redroid_libhoudini_hack` 提供 9.0 ~ 15.0）。
- 构建产物含专有二进制，**不要公开分发镜像**。
