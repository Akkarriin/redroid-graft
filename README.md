# redroid-graft

**让 [redroid](https://github.com/remote-android/redroid-doc) 跑起需要 Vulkan 支持的游戏。**

redroid 是很好的容器化 Android 方案（无头、多开、adb 直连），但它的图形栈
停留在 gralloc 2.0 + 旧版 Mesa，Vulkan 应用拿不到 swapchain buffer——
Vulkan-only 的手游（尤其是新版 Unity 游戏）直接黑屏或崩溃。

本项目把 [Waydroid](https://github.com/waydroid/waydroid) 的现代图形栈
**嫁接**（*graft*）到 redroid 上：gralloc4（minigbm_gbm_mesa）+ Mesa 26，
让 Vulkan 游戏在容器里正常渲染。两者同为 Android 13 / x86_64，ABI 兼容，
直接搬运二进制即可。在此之上还顺带补齐了 ARM 翻译、Root 和 GApps。

> 典型收益：原先黑屏/闪退的 Vulkan-only Unity 游戏（如少女前线2、赛马娘）
> 可以正常进入并渲染。

原版为什么跑不了，完整验证记录见 [TROUBLESHOOTING 附录 A](docs/TROUBLESHOOTING.md)。

本仓库**只含构建脚本和文档**。Waydroid vendor、houdini、Magisk、GApps
等第三方二进制在构建时下载，不入库。`scripts/dl/`、`scripts/src/`、
`scripts/out/` 已 gitignore，**请勿提交，也请勿公开分发构建出的镜像**。

## 解决了什么

| 问题 | 表现 | 本项目的处理 |
|---|---|---|
| **gralloc 只有 2.0，Mesa 过旧** | **Vulkan-only 的 Unity 游戏黑屏/崩溃** | **移植 Waydroid 的 gralloc4 + Mesa 26** |
| 只有 x86 指令集 | ARM-only 的游戏装不上/闪退 | 注入 libhoudini |
| linker 命名空间限制 | houdini 加载 `libtcb.so` 被拒 → SIGABRT | 打 ld.config 补丁 |
| Houdini 内置有效期 | 到期后游戏卡死、CPU 满载 | 构建时严格校验并移除 32/64 位到期分支 |
| 无 root | 很多工具/脚本用不了 | 注入 Kitsune Magisk |

第一项是核心。redroid 从 11 到 16 都只带 `graphics.allocator@2.0` 和 2024 年的 Mesa；
图形栈嫁接完成后，Vulkan 游戏、ARM 翻译、Root 可以按需叠加。

### 为什么不直接用 Waydroid

Waydroid 本身就有完整的 gralloc4 + Vulkan，桌面上跑游戏没问题。但：

- **硬编码单实例** —— 固定 `/var/lib/waydroid`、固定 LXC 容器名、
  独占 D-Bus 名 `id.waydro.Container`，多开需要改造 Waydroid 本身
- **强依赖 Wayland compositor** —— 无头服务器上还要再套 headless weston

而 redroid 天生无头、多开、adb 直连，正好相反。
所以选择保留 redroid 的骨架，只把 Waydroid 的图形栈嫁接过来。

## 快速开始

依赖：`podman` 或 `docker`、`curl`、`unzip`、`e2fsprogs`（`debugfs`）、
`python3`、`binutils`（`readelf`，做依赖闭包与符号校验）。LiteGapps 另需带 xz
支持的 `tar`；Android 15 实验脚本还需 `p7zip`（`7z`）。

下载会走 `curl`，脚本遵循标准的 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量。

```bash
# 1. 图形层：gralloc4 + Mesa 26 + Vulkan（所有变体的底图）
./scripts/gralloc4.sh

# 2. 可选：再叠 houdini + Kitsune Magisk（跑 ARM 手游需要）
#    默认同时移除 32/64 位 Houdini 内置有效期限制
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
| `redroid13-graft-houdini:latest` | 图形栈 + houdini（无 Magisk） |
| `redroid13-graft-houdini-gapps:latest` | 图形栈 + houdini + MindTheGapps（无 Magisk） |
| `redroid13-graft-ndk:latest` | 图形栈 + waydroid-helper ndk_translation（zork R136） |
| `redroid13-graft-ndk-gapps:latest` | 图形栈 + zork NDK + MindTheGapps（无 Magisk） |
| `redroid13-graft-ndk-stock-magisk:latest` | 诊断用：houdini-magisk 切回 redroid stock NDK |
| `redroid13-graft-houdini-magisk:latest` | 图形栈 + houdini + Magisk（手游常用） |
| `redroid13-graft-houdini-magisk-gapps:latest` | 图形栈 + houdini + Magisk + MindTheGapps |

`ROOT=none ./scripts/build.sh` 只要 houdini不要 Magisk。  
`./scripts/inject-ndk.sh` 在 `redroid13-graft` 上叠 ChromeOS ndk（勿叠在 houdini 镜像上）。

`GAPPS=lite ./scripts/inject-gapps.sh` 可改用 LiteGapps。
`SKIP_SETUP=0` 保留 Setup Wizard（默认写入 `ro.setupwizard.mode=DISABLED`）。

两个脚本都会缓存下载内容到 `dl/`，重跑不会重复下载（共约 350 MB）。
构建默认用 podman（须以 root 运行，见下），`CTR=docker` 切换到 docker。

运行（ARM 手游场景，用带 houdini 的变体）：

```bash
docker run -itd --privileged \
    --name android-1 \
    -v /srv/redroid-data/1:/data \
    -p 5555:5555 \
    localhost/redroid13-graft-houdini-magisk:latest \
    androidboot.use_memfd=1 \
    androidboot.redroid_gpu_mode=host \
    androidboot.redroid_fps=60 \
    androidboot.redroid_width=1080 \
    androidboot.redroid_height=1920 \
    androidboot.redroid_dpi=320

adb connect <IP>:5555
scrcpy -s <IP>:5555 --max-fps=60
```

镜像名要写全 `localhost/...`：脚本产出的镜像带 `localhost/` 前缀，docker 不会自动补
（podman 会）。多开就是改 `--name`、`-p` 和 `-v` 再跑一遍。

### 用 podman 运行

把上面的 `docker run` 换成下面这样，其余参数不变：

```bash
sudo podman run -d --privileged --pids-limit=-1 \
    --name android-1 \
    -v /srv/redroid-data/1:/data \
    -p 5555:5555 \
    localhost/redroid13-graft-houdini-magisk:latest \
    androidboot.use_memfd=1 androidboot.redroid_gpu_mode=host ...
```

和 docker 的差别：

- **必须 `--pids-limit=-1`**。podman 默认每个容器限 2048 个任务（`containers.conf` 的
  `pids_limit`），cgroup 按线程计数；Android 开机就有一两千个线程，再开游戏会
  `pthread_create` 失败、进程随机崩溃。docker 默认不限制。
- **必须 rootful**（`sudo podman` 或 root 用户）。rootless 的 `--privileged` 只在用户命名空间
  内有效，redroid 开机要挂 debugfs（`gpu_config.sh` 靠它识别 GPU）、访问 binder 和
  `/dev/dri`，都做不到。构建镜像和运行要用同一个用户，否则看不到镜像。
- **开机自启**靠 systemd（podman 没有常驻守护进程，`--restart=always` 管不到重启宿主后）。
  推荐 Quadlet（podman ≥ 4.4）：写入 `/etc/containers/systemd/android-1.container`

  ```ini
  [Unit]
  Description=redroid-graft android-1

  [Container]
  Image=localhost/redroid13-graft-houdini-magisk:latest
  ContainerName=android-1
  PodmanArgs=--privileged
  PidsLimit=-1
  Volume=/srv/redroid-data/1:/data
  PublishPort=5555:5555
  Exec=androidboot.use_memfd=1 androidboot.redroid_gpu_mode=host androidboot.redroid_fps=60 androidboot.redroid_width=1080 androidboot.redroid_height=1920 androidboot.redroid_dpi=320

  [Service]
  Restart=always
  TimeoutStartSec=300

  [Install]
  WantedBy=multi-user.target default.target
  ```

  然后 `sudo systemctl daemon-reload && sudo systemctl start android-1`。
  多开就复制成 `android-2.container`，改 `ContainerName`、`Volume`、`PublishPort`。

### 验证安装结果

```bash
D=<IP>:5555
adb -s $D shell dumpsys SurfaceFlinger | grep GLES
#   应为 Mesa 26.x，不是 24.x
adb -s $D shell getprop ro.hardware.gralloc      # minigbm_gbm_mesa
adb -s $D shell getprop ro.hardware.vulkan       # intel / intel_hasvk / radeon（按 GPU）
adb -s $D logcat -d -s gpu_config                # 开机时选了哪个节点和驱动
# 以下仅 houdini-magisk 镜像：
adb -s $D shell getprop ro.dalvik.vm.native.bridge  # libhoudini.so
adb -s $D shell sha256sum /system/lib{,64}/libhoudini.so
# 默认 (com1.3) 应分别为 fa74f6f7...（32 位）和 da7448b3...（64 位）
# HOUDINI_VERSION=1.2 构建的为 96fe3acc... 和 847be255...
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
- **GPU**：`/dev/dri/renderD*` 可用。Intel / AMD 开机自动识别，见下
- **磁盘**：镜像约 2.5 GB

没有 ashmem 的新内核要加 `androidboot.use_memfd=1`（多数情况都需要）。

### 实测机器

| 部件 | 配置 |
|---|---|
| 系统 | Ubuntu |
| CPU | AMD 锐龙 7 5800 |
| GPU | Intel Arc A380（`xe` 内核驱动） |

在这台机器上验证通过：gralloc4 + Mesa 26 嫁接后 Vulkan 游戏正常渲染；
**libhoudini ARM 翻译可以正常跑 ARM 手游**（含 32/64 位双 ABI）；
Kitsune Magisk 与 MindTheGapps 叠加均正常。其他 GPU 的选择逻辑有单元测试
（`scripts/test-gpu-config.sh`），但尚未实机验证。

### GPU 支持

镜像打包 Waydroid vendor 里全部 x86 PC 可用的 Mesa 26 Vulkan 驱动，
**开机时由 `/vendor/bin/gpu_config.sh` 按 render node 的内核驱动自动选择**
（替换了 redroid 原版脚本，见 [ARCHITECTURE](docs/ARCHITECTURE.md#gpu-属性开机探测)）：

| 内核驱动 | 典型硬件 | `ro.hardware.vulkan` | 状态 |
|---|---|---|---|
| `xe` | Arc A/B 系列、Lunar Lake 之后 | `intel`（ANV） | **实测** |
| `i915` Gen9+ | Skylake 之后核显、i915 上的 Arc | `intel`（ANV） | 未实机验证 |
| `i915` Gen7/8 | Haswell / Broadwell 等 | `intel_hasvk` | 未实机验证 |
| `amdgpu` | GCN / RDNA | `radeon`（RADV） | 未实机验证 |
| `virtio_gpu` | 虚拟机里的 venus | `virtio` | 未实机验证 |
| `nouveau` | NVIDIA | 不设（LOS20 vendor 不带 NVK），只有 GLES | — |
| `nvidia` 闭源驱动 | NVIDIA | 不可用：Android 侧没有对应的用户态驱动 | — |

- 多块 GPU 时取第一个可用节点；`androidboot.redroid_gpu_node=/dev/dri/renderD129` 指定。
- 自动选择不对时，`androidboot.redroid_vulkan=intel_hasvk`（等）强制指定。
- 只会选本镜像嫁接的 Mesa 26 驱动。原版 redroid 残留的 Mesa 24 驱动不认识 gralloc4
  buffer，宁可不开 Vulkan 也不加载它（`logcat -s gpu_config` 会有告警）。
- 只有 host 模式：`redroid_gpu_mode=guest/auto` 会按 host 处理并告警
  （guest 依赖的 allocator@2.0 已停用）。
- `VK_DRIVERS="vulkan.intel.so ..."` 可在构建时裁剪打包的驱动。旧的 `VULKAN_HW` 已废弃。

构建时会对 `libgbm_mesa_wrapper.so` 打补丁，跳过 allocate 时的 `gbm_bo_map`
探测（否则进系统设置会拖死 `allocator@4`）。详见 [TROUBLESHOOTING §7](docs/TROUBLESHOOTING.md)。

## Android 15（实验）

```bash
./scripts/gralloc4-15.sh    # 产出 redroid15-graft:latest
```

等价于 `ANDROID_VERSION=15 ./scripts/gralloc4.sh`：从 Waydroid LOS22 的 squashfs
`vendor.img` 提取图形栈（`libLLVM21.so`，另带 NVK）。主线是 13——libhoudini /
libndk_translation 的方案都针对 13；15 只保留图形层构建，不在维护范围。

## 仓库结构

```
docs/ARCHITECTURE.md              每一层做了什么
docs/TROUBLESHOOTING.md           踩过的坑
patches/kitsune-pid-set-dynamic.patch
                                  自编译 Kitsune 时修复 PID > 32768
scripts/patch-houdini-expiry.py   严格校验并移除 Houdini 双 ABI 到期分支
scripts/gralloc4.sh               redroid 13 图形栈（主路径；ANDROID_VERSION=15 为实验）
scripts/gralloc4-15.sh            等价于 ANDROID_VERSION=15 gralloc4.sh
scripts/files/gpu_config.sh       替换 redroid 的 gpu_config.sh：开机按 GPU 选驱动
scripts/test-gpu-config.sh        gpu_config.sh 的宿主机单元测试（不需要 GPU）
scripts/check-vendor-closure.py   按链接器命名空间校验依赖闭包与符号
scripts/build.sh                  叠 houdini + 可选 Magisk
scripts/inject-gapps.sh           叠 MindTheGapps / LiteGapps
scripts/inject-ndk.sh             叠 ChromeOS ndk_translation（勿叠 houdini）
scripts/switch-ndk.sh             切回 redroid 自带 ndk（对比用）
scripts/patch-gbm-mesa-skip-map-stride.py
                                  Arc/xe：跳过 allocate 时的 map_stride 探测
```

## Kitsune 的 PID 修复是否必要

问题是真实的，**而且上游没有修**：Kitsune `ea3f64a` 的 `ptrace.cpp` 用固定
`bitset<32768>` 按 PID 下标访问（`std::bitset::operator[]` 不做越界检查），PID 超过
32768 就会写坏相邻内存。截至 2026-10，ayasa520 fork 的 `kitsune`/`patch-1` 分支和原作者
1q23lyc45 仓库的最后一个提交（`8e854f3`，"Last Commit"）都还是 `bitset<32768>`。

在 redroid 里尤其容易触发：原版 `redroid.common.rc` 自己就会
`write /proc/sys/kernel/pid_max 65535`，长时间运行后 PID 超过 32768 是常态。
只有开启 MagiskHide（默认关闭，开启后且 Zygisk 关闭时才启动 ptrace 监视）才会走到这段代码。先前版本中的补丁还是损坏的
unified diff；现已在 `ea3f64a97757506707136ff88b0ec730574cae42` 上重新生成，并改用
按已见最高 PID 动态增长的 packed bitmap：查询 O(1)，没有 32768 硬上限，也没有
每个 PID 的树/哈希节点分配；即使增长到 Linux 当前 4194304 上限，每组也约 512 KiB。

**注意：默认下载的预编译 Kitsune APK 不含这项源码补丁。** 普通短期实例未必触发；
开启 MagiskHide 并长期挂机时，建议从上述 commit 自编译：

```bash
git checkout ea3f64a97757506707136ff88b0ec730574cae42
git apply --check /path/to/redroid-graft/patches/kitsune-pid-set-dynamic.patch
git apply /path/to/redroid-graft/patches/kitsune-pid-set-dynamic.patch
# 按 Kitsune 上游文档构建 APK，然后：
MAGISK_LOCAL_APK=/path/to/app-debug.apk ./scripts/build.sh
```

不开 MagiskHide，或容器内 `cat /proc/sys/kernel/pid_max` 不大于 32768 时，不需要这项补丁。
不建议为了规避它而降低宿主全局 `kernel.pid_max`。

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
PATCH_HOUDINI_EXPIRY=0 ./scripts/build.sh  # 诊断：保留原版有效期行为
HOUDINI_VERSION=1.2 ./scripts/build.sh     # 回退到实机验证过的 HPE 14 com1.2
CTR=docker ./scripts/gralloc4.sh      # 用 docker 而非 podman
BUILD_IMAGE=0 ./scripts/gralloc4.sh   # 只生成 tar 层，不构建镜像
NEW_IMAGE=myrepo/android:13 ./scripts/gralloc4.sh
```

## 已知限制

- **只在「实测机器」一节列出的配置上完整验证过**。AMD 等其它 GPU 的自动选择
  只有单元测试，尚未实机验证；NVIDIA 没有 Vulkan（见「GPU 支持」）。
- 镜像约 2.5 GB（主要是 Mesa 26 的 `libLLVM22` 64/32 位各一份；多厂商 Vulkan 驱动另占约 50 MB）。
- 基于 redroid 13。更高版本 redroid 的 vendor 分区布局相同，
  理论上改 `gralloc4.sh` 的 `BASE_IMAGE` 即可，但 houdini 的 linker 补丁需要对应版本
  （`rote66/redroid_libhoudini_hack` 提供 9.0 ~ 15.0）。
- 构建产物含专有二进制，**不要公开分发镜像**。
