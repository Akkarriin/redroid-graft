# 架构说明

镜像由脚本叠加而成。**所有产出都带 gralloc4 + Mesa 26**：

```
redroid/redroid:13.0.0-latest                官方基础镜像
  └── gralloc4.tar    ── gralloc4.sh   →  redroid13-graft:latest
        ├── houdini.tar  ┐
        ├── magisk.tar   ├─ build.sh   →  redroid13-graft-houdini-magisk:latest
        └── props.tar    ┘
              └── gapps.tar ── inject-gapps.sh → redroid13-graft-houdini-magisk-gapps:latest
```

全部通过 `ADD xxx.tar /` 覆盖文件，不需要编译 AOSP。
变体写在**镜像名**里，tag 统一用 `latest`。
构建顺序：先 `gralloc4.sh`，再 `build.sh`，最后可选 `inject-gapps.sh`。
图形栈属性（`ro.hardware.gralloc/egl/vulkan`）不写在 `build.prop` 里，
而是由嫁接版 `gpu_config.sh` 开机设置，所以后续层改 `build.prop` 不会冲掉它们。
`build.sh` 的 props 层只改 native bridge 相关键，并以嫁接版 `gpu_config.sh`
为标记确认底图是 `gralloc4.sh` 的产物。

---

## 第一部分：gralloc4.sh

这是本项目的核心，也是 redroid 原本跑不了 Vulkan 游戏的原因。
产出 `redroid13-graft:latest`（仅图形栈）。

### 问题

redroid（13/14/15 全部版本）的图形栈：

```
graphics.allocator@2.0-service      老式 gralloc0 HAL
gralloc.gbm.so                      Mesa 时代的 gbm_gralloc
Mesa 24.0.8                         2024 年版本
```

Mesa 的 Vulkan 驱动（ANV）需要 gralloc 3.x/4.x 才能分配 swapchain buffer。
gralloc 2.0 下会得到：

```
E vulkan: dequeueBuffer[0] failed: Invalid argument (-22)
I Gralloc4: mapper 4.x is not supported
I MESA    : Using fallback gralloc implementation
```

对于**只打包了 Vulkan shader** 的 Unity 游戏（如少女前线2），
回退到 GLES 会导致：

```
E Unity: Desired shader compiler platform 5 is not available in shader blob
```

Platform 5 = Vulkan。拿不到 shader，画面全黑。**这是个死结**：
GLES 缺 shader，Vulkan 缺 buffer。

### 解法

Waydroid 的 vendor 镜像（LineageOS 20，同为 Android 13 / x86_64）里有全套现代图形栈。
直接搬运二进制，不需要编译。

从 SourceForge 下载 vendor.img（ext2），用 `debugfs` 免 root 提取：

**gralloc4 HAL**
```
vendor/bin/hw/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa
vendor/lib{,64}/hw/android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so
vendor/lib{,64}/hw/gralloc.minigbm_gbm_mesa.so
vendor/lib{,64}/libminigbm_gralloc_gbm_mesa.so
```

**Mesa 26 完整栈**
```
vendor/lib{,64}/dri_gbm.so           gbm 后端
vendor/lib{,64}/libgallium_dri.so    megadriver, 41MB
vendor/lib{,64}/libLLVM22.so         着色器编译器, 105MB
vendor/lib{,64}/libdrm{,_intel,_amdgpu,_radeon}.so
vendor/lib{,64}/egl/libEGL_mesa.so, libGLESv{1_CM,2}_mesa.so
vendor/lib{,64}/hw/vulkan.intel.so   ANV
```

**配置**
```
vendor/etc/vintf/manifest/gbm_mesa.{allocator,mapper}@4.0.xml   声明 4.0
vendor/etc/vintf/manifest.xml                                   删掉 2.0/2.1 声明
vendor/etc/init/...allocator@4.0-service...rc                   启动 4.0
vendor/etc/init/...allocator@2.0-service.rc                     加 disabled
vendor/bin/gpu_config.sh    替换原版：开机设置 ro.hardware.gralloc=minigbm_gbm_mesa、
                            ro.hardware.egl=mesa，并按 GPU 选 ro.hardware.vulkan
（构建时另：patch libgbm_mesa_wrapper.so，跳过 map_stride 探测）
```

比 Waydroid 原方案还简单一点：Waydroid 用 `manifest.disabled` 目录 + bind mount
在运行时切换，而 redroid 的 `vendor/etc/vintf/manifest/` 本身就是目录，直接放文件即可。

### 为什么每个组件都不能少

这四样是逐个调试出来的，缺任何一个都会失败：

| 组件 | 缺失时的表现 |
|---|---|
| `libLLVM22.so` | `Unable to create gbm device`（gallium 没有编译器后端） |
| Mesa 26 EGL | SurfaceFlinger 在 `gbm_mesa_bo_import` 空指针 SIGSEGV<br>（旧 EGL 走 gralloc0 接口，与 gralloc4 的 handle 结构不兼容） |
| **32 位全套** | `screenrecord`/scrcpy 灰屏<br>OMX 编码服务是 32 位进程，abort: `gralloc-mapper is missing` |
| Mesa 26 Vulkan HAL | `vkCreateImage w/ native buffer failed` → `GetSwapchainImagesKHR` 崩溃<br>（旧 ANV 不认识 gralloc4 的 buffer） |

mapper 是 **passthrough** 模式（在调用方进程内 dlopen，不走 binder），
所以 32 位进程必须有 32 位实现——这是最容易漏的一点。

### Arc/xe：跳过 allocate 时的 map_stride 探测

Waydroid 的 `gbm_mesa_alloc` 在 `BO_USE_SW_MASK` 时会 `import+map+unmap` 探测
`map_stride`。Intel Arc（内核 `xe`）上这条路径在 Mesa `dri_flush` 空指针，
进系统设置就会拖死 allocator@4 / SurfaceFlinger。

SW buffer 已 `force_linear`，`map_stride == stride`。构建时由
`scripts/patch-gbm-mesa-skip-map-stride.py` 改 `libgbm_mesa_wrapper.so`：
跳过探测，直接 `out_map_stride = out_stride`。详见 TROUBLESHOOTING §7。

### GPU 属性：开机探测

redroid 原版有 `/vendor/bin/gpu_config.sh`，由 `redroid.common.rc` 在 `early-boot`
执行（早于 allocator 和 SurfaceFlinger），按 `redroid_gpu_mode` 和 debugfs 里的 DRI
驱动名 `setprop ro.hardware.{egl,gralloc,vulkan}`。

旧做法把这三个属性写死进 `vendor/build.prop`。`ro.*` 先写者胜，于是原版脚本的
setprop 全部静默失败：一个镜像只能对应一个厂商，guest/auto 模式也被架空。

现在 `gralloc4.sh` 用 `scripts/files/gpu_config.sh` 替换原版（先校验原版 sha256，
上游改了就停下来要求重新审阅），保留原有结构，改动：

| | 原版 | 嫁接版 |
|---|---|---|
| gralloc | `gbm` | `minigbm_gbm_mesa` |
| 内核驱动 | 只认 `i915` | 另认 `xe`（Arc） |
| Intel Vulkan | 一律 `intel` | 读 `i915_capabilities`，Gen7/8 用 `intel_hasvk` |
| `nouveau` | 不设 Vulkan | 映射到 NVK，但仅当镜像里有 Mesa 26 的 `vulkan.nouveau.so` |
| 驱动白名单 | 无 | 只选嫁接的 Mesa 26 驱动；残留的 Mesa 24 驱动不认识 gralloc4 buffer |
| 强制指定 | 无 | `androidboot.redroid_vulkan=<名字>` |
| guest/auto | 软渲染 | 按 host 处理并告警（allocator@2.0 已停用） |
| 日志 | echo 到 init 的 `/dev/null` | `logcat -s gpu_config` |

`minigbm` 读 `gralloc.gbm.device` 选 render node（`strings` 可见
"Using device %s as requested by gralloc.gbm.device"），所以原版的节点选择和
`androidboot.redroid_gpu_node` 对 gralloc4 依然有效。

`scripts/test-gpu-config.sh` 用 mksh（Android 的 `/system/bin/sh`）加
`setprop/getprop` 桩和模拟的 debugfs 跑各类 GPU 组合，不需要 Android 或 GPU。

### Vulkan 驱动范围

| 组件 | 厂商相关？ |
|---|---|
| gralloc4 / minigbm | 否 |
| `libgallium_dri.so` | **否** — megadriver，含 iris/crocus/radeonsi/nouveau/virtio_gpu/llvmpipe |
| `libLLVM22.so` / EGL / GLES | 否 |
| `libdrm_{intel,amdgpu,radeon}.so` | 三个都已打包（供 Mesa 链接） |
| `vulkan.*.so` | **是** — 分文件 |

默认打包 vendor.img 里有的 `vulkan.{intel,intel_hasvk,radeon,nouveau,virtio}.so`
（LOS20 没有 nouveau），64/32 位各一份，比只带 Intel 多约 50 MB。
`VK_DRIVERS` 可裁剪；Android Vulkan loader 只加载 `ro.hardware.vulkan` 指定的那一个。

曾打包全厂商 + 自写 `detect_gpu.sh`，在 Settings 崩溃（实为 map 探测，见上节）时
被误判而撤回。现在复用 redroid 自己的探测脚本，不另起一套。

### 依赖闭包与符号

`scripts/check-vendor-closure.py` 按 Android 链接器命名空间解析每个新增 ELF：

- 库按 **sphal**（EGL/GLES/Vulkan/mapper 在 system 进程里被 dlopen）：
  只能看到 `/vendor/${LIB}`、`/odm/${LIB}`、VNDK-SP、LLNDK
- `/vendor/bin` 下的服务按 **vendor**：再加 VNDK-core
- 每个依赖必须是正确的位数/架构，且本层库的强未定义符号必须在闭包内有定义

VNDK/LLNDK 列表取自基础镜像（13：VNDK apex；15：`system/etc/llndk.libraries.txt`，
apex 未展开时自动解包）。旧检查只看文件名是否在 `system/` 或 `vendor/` 下存在：
它抓到过 `libLLVM22.so` 缺失，但对"文件在 `/system/lib64`、vendor 命名空间却看不到"
无能为力——15 上 `libdmabufheap.so` 就是这种情况，新检查能直接报出来。

---

## 第二部分：build.sh

在 `redroid13-graft:latest` 上再叠 ARM 翻译和 Root，
产出 `redroid13-graft-houdini-magisk:latest`。

### houdini.tar — ARM 翻译

来源：`supremegamers/vendor_intel_proprietary_houdini` 的固定 commit
`debc3dc91cf12b5c5b8a1c546a5b0b7bf7f838a8`（Google Play Games for PC
的 HPE 镜像）。32 位库为 `14.0.0_y.GoogleGame_com1.2`，64 位库为
`14.0.0_z.GoogleGame_com1.2`。

```
system/bin/houdini, houdini64
system/lib/{arm/*, libhoudini.so}
system/lib64/{arm64/*, libhoudini.so}
system/etc/binfmt_misc/*
system/etc/init/houdini.rc
```

`houdini.rc` 在 `early-init` 挂载 binfmt_misc，然后在
`ro.enable.native.bridge.exec=1` 时注册四条 ARM ELF 魔数规则，
把 arm/arm64 可执行文件路由到 houdini 解释器。

#### 有效期补丁（默认开启）

HPE 库内置有效期；到期后不是正常退出，而是进入异常路径，表现为 ARM 游戏卡死、
CPU 满载。`scripts/patch-houdini-expiry.py` 在打包前同时处理两种 ABI：

| 路径 | 原 SHA256 | 偏移 / 原字节 | 补丁后 SHA256 |
|---|---|---|---|
| `system/lib/libhoudini.so` | `f8df8ff7…2f9866` | `0x8a29a` / `0f830b0d0000` | `96fe3acc…4e993` |
| `system/lib64/libhoudini.so` | `b321439d…5f1e` | `0xe6085` / `0f83680d0000` | `847be255…23b8` |

两条 `jae` 均替换为 6 个 NOP，完全绕过到期后的失败分支，而不是把日期延长到
另一个年份。补丁器同时检查压缩包 SHA、单文件完整 SHA、原指令和补丁后 SHA；
未知版本会失败退出，绝不按偏移盲打。重复运行是幂等的，且 `houdini.tar` 内的两个
成员会再次校验。`PATCH_HOUDINI_EXPIRY=0` 可保留原版行为用于负对照。

同时用一个空文件覆盖 `system/etc/init/ndk_translation.rc`，
禁用 redroid 自带的 libndk_translation——两者会争抢 binfmt_misc 注册。

> Docker 的 `ADD tar` 只能覆盖不能删除，所以用空文件"软禁用"。

### linker 补丁（关键）

houdini 会 dlopen `/system/lib64/arm64/libtcb.so`，但该路径不在
linker 命名空间的 `permitted.paths` 里，直接被拒：

```
E linker : library "/system/lib64/arm64/libtcb.so" ... is not accessible
           for the namespace ... permitted_paths="/system/lib64/drm:..."
I houdini: Fatal error (ID:0x0190015a).
F libc   : Fatal signal 6 (SIGABRT)
```

补丁（来自 `rote66/redroid_libhoudini_hack`）把这些路径加进
`default` 和 `sphal` 两个命名空间：

```
/system/${LIB}/arm      /system/${LIB}/arm/nb
/system/${LIB}/arm64    /system/${LIB}/arm64/nb
/apex/com.android.art/${LIB}
```

**难点在于 `/linkerconfig` 是 tmpfs，每次开机由 `linkerconfig` 工具重新生成**，
不能预先写死。构建时从直接父镜像提取 `system/etc/init/hw/init.rc`，要求
`perform_apex_config` 锚点恰好出现一次，并在其后插入两行：

```
exec -- /system/bin/sh -c "/system/bin/patch /linkerconfig/ld.config.txt < /system/etc/ld_config.patch"
exec -- /system/bin/sh -c "/system/bin/patch /linkerconfig/com.android.media.swcodec/ld.config.txt < /system/etc/ld_config_swcodec.patch"
```

最终层仍会覆盖这个文件，但内容来自直接父镜像而不是第三方仓库的陈旧快照；
因此父镜像新增的 trigger/服务参数会保留。已存在未知 linker 补丁或锚点数量异常时
会 fail closed。

### magisk.tar — Root

Kitsune Magisk 27.2（Magisk Delta 的继任分支，内置 MagiskHide，
比官方版只有 DenyList 的隐藏效果好）。

```
system/etc/init/magisk/{magisk64,magiskboot,magiskinit,magiskpolicy,busybox,...}
system/etc/init/magisk.rc       ← 独立的 Magisk 启动 trigger，不覆盖 bootanim 服务
```

`magisk.rc` 在 `post-fs-data` 阶段跑 magiskpolicy 和 `--setup-sbin`。
Android init 会加载 `/system/etc/init/*.rc`，无需重写父镜像的 `bootanim.rc`。
两个容易踩的点：

1. **magisk 目录属主必须是 `2000:0`**（shell:root），否则 magisk 拒绝加载
2. **stub 壳问题**（详见 TROUBLESHOOTING.md #1）。magiskd 在 `--boot-complete`
   发现 app 未安装时，会自己拿 `stub.apk` 装个 41KB 的壳（versionName=1.0），
   而壳要联网下载完整版，Kitsune 上游地址已 404 → `System.exit(0)` 自杀。
   而且 **magiskd 装壳的时机可能晚于 magisk.rc 的首次检查**，所以一次性检查会被覆盖。
   处理方式：`install_app.sh` 用 `exec_background` 后台持续监视两分钟，
   每 2 秒查一次 versionName，发现是 `1.0`（壳）或未安装就重装完整版

#### PID > 32768

Kitsune `ea3f64a` 源码用固定 `bitset<32768>` 追踪 PID，而现代内核的
`pid_max` 往往更高。`patches/kitsune-pid-set-dynamic.patch` 已在完整 commit
`ea3f64a97757506707136ff88b0ec730574cae42` 上重生成，改为按已见最高 PID
动态增长的 packed bitmap（O(1)，无逐节点分配）。但 `build.sh` 默认下载的是上游
预编译 APK，**不会自动带上源码补丁**；长期运行且 PID 可能超过 32768 时，应自编译后通过
`MAGISK_LOCAL_APK` 注入。应用命令见 README。

### props.tar — 属性

把 native bridge 从 redroid 自带的 `libnb.so` 切到 `libhoudini.so`：

```
ro.dalvik.vm.native.bridge = libhoudini.so
ro.enable.native.bridge.exec = 1
ro.dalvik.vm.isa.arm   = x86
ro.dalvik.vm.isa.arm64 = x86_64
ro.vendor.product.cpu.abilist = x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
ro.system.product.cpu.abilist = x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
```

Android 启动后会由这些分区属性汇总出通用 `ro.product.cpu.abilist`。
模板取自上一层（已含 gralloc4 的 `redroid13-graft`），**只改写上述键**。
图形栈属性不在 `build.prop` 里，不受影响。

---

## 第三部分：inject-gapps.sh

在 `redroid13-graft-houdini-magisk:latest` 上再叠 GApps，
产出 `redroid13-graft-houdini-magisk-gapps:latest`。

配方对齐 [waydroid-helper extensions](https://github.com/waydroid-helper/extensions)
里的 MindTheGapps（Android 13 / x86_64，`20250913`）：

```
unzip MindTheGapps-*.zip
cp -rf system/ → 镜像 /system/   # GmsCore 等在 system/product、system/system_ext
# 默认另写 ro.setupwizard.mode=DISABLED（无头场景跳过向导）
```

redroid 底图里 `/product`、`/system_ext` 是指向 `/system/...` 的 symlink。
注入时只写 `system/product` / `system/system_ext`，**不要** ADD 顶层
`product/` 目录，否则会把 symlink 盖成真实目录。

也可用 `GAPPS=lite` 换成同仓库的 LiteGapps。
Play 商店首次使用通常还要到 Google 登记设备的 GSF `android_id`
（与 Waydroid / redroid-script 相同）。

---

## 层间的坑

后层的同名文件会**整文件**覆盖前层。因此：

1. 必须先 `gralloc4.sh` 再 `build.sh`，最后可选 `inject-gapps.sh`
2. `build.sh` 改 `vendor/build.prop` 时模板必须来自直接上一层，
   且只 patch native bridge 相关键（脚本已如此）
3. `inject-gapps.sh` 若改 `system/build.prop`（跳过向导），模板取自
   houdini-magisk 底图，只追加 `ro.setupwizard.mode`，不动其它键

若把顺序反了，或后层用原版 redroid 的整份 `build.prop` 覆盖，
会把 `libhoudini.so` 冲回 `libnb.so`。详见 TROUBLESHOOTING.md #6。
（图形栈属性已移到 `gpu_config.sh`，不再有被冲掉的风险。）

---

## 第四部分：inject-ndk.sh

在 `redroid13-graft:latest` 上叠 ChromeOS `libndk_translation`（zork R136），
产出 `redroid13-graft-ndk:latest`。配方对齐 waydroid-helper extensions。

不要叠在已注入 houdini 的镜像上：两者会争抢 binfmt_misc 和 native bridge。
`switch-ndk.sh` 是另一条路径——把 houdini-magisk 镜像切回 redroid 自带的
`libndk_translation`，只用于对比，不下载 ChromeOS 那套。它使用独立的
`ndk-stock.tar` / `Dockerfile.ndk-stock`，默认镜像名为
`redroid13-graft-ndk-stock-magisk:latest`，不会覆盖正式 zork NDK 产物。

---

## Android 15：gralloc4-15.sh（实验，不在维护范围）

主线是 13：libhoudini / libndk_translation 的方案都针对 13。
`gralloc4-15.sh` 等价于 `ANDROID_VERSION=15 ./scripts/gralloc4.sh`，与 13 共用同一份脚本，
差异只在配置块里：

- vendor.img 是 squashfs，用 `7z` 提取（按文件头自动判断）
- Mesa 链 `libLLVM21.so`（版本号从 `libgallium_dri.so` 的 `DT_NEEDED` 读出）
- 额外搬 `libdmabufheap.so`：15 没有 VNDK，`/system/lib64` 里那份 vendor 命名空间看不到
- 默认底图 `redroid/redroid:15.0.0-latest`，产出 `redroid15-graft:latest`
- LOS22 带 `vulkan.nouveau.so`（NVK），NVIDIA + nouveau 可以有 Vulkan

houdini / Magisk 层没有针对 15 验证。
