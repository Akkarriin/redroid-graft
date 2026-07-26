# 架构说明

镜像由两个脚本、四个 Docker 层叠加而成：

```
redroid/redroid:13.0.0-latest          官方基础镜像
  ├── houdini.tar     ┐
  ├── magisk.tar      ├─ build.sh
  ├── props.tar       ┘
  └── gralloc4.tar    ── gralloc4.sh
```

全部通过 `ADD xxx.tar /` 覆盖文件，不需要编译 AOSP。

---

## 第一部分：build.sh

### houdini.tar — ARM 翻译

来源：`supremegamers/vendor_intel_proprietary_houdini` 的 `hpe-14` 分支
（Google Play Games for PC 的 HPE 镜像，版本 14.0.0_z）。

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
不能预先写死。解决办法是替换 `system/etc/init/hw/init.rc`，
在 `perform_apex_config` 之后插入两行：

```
exec -- /system/bin/sh -c "/system/bin/patch /linkerconfig/ld.config.txt < /system/etc/ld_config.patch"
exec -- /system/bin/sh -c "/system/bin/patch /linkerconfig/com.android.media.swcodec/ld.config.txt < /system/etc/ld_config_swcodec.patch"
```

替换整个 init.rc 有覆盖 redroid 自身改动的风险，所以脚本里加了硬校验：
diff 上游快照与基础镜像的 init.rc，**除这两行外必须完全一致**，否则报错退出。

### magisk.tar — Root

Kitsune Magisk 27.2（Magisk Delta 的继任分支，内置 MagiskHide，
比官方版只有 DenyList 的隐藏效果好）。

```
system/etc/init/magisk/{magisk64,magiskboot,magiskinit,magiskpolicy,busybox,...}
system/etc/init/bootanim.rc     ← 借 bootanim 服务启动 magisk
```

`bootanim.rc` 在 `post-fs-data` 阶段跑 magiskpolicy 和 `--setup-sbin`。
两个容易踩的点：

1. **magisk 目录属主必须是 `2000:0`**（shell:root），否则 magisk 拒绝加载
2. **stub 壳问题**（详见 TROUBLESHOOTING.md #1）。magiskd 在 `--boot-complete`
   发现 app 未安装时，会自己拿 `stub.apk` 装个 41KB 的壳（versionName=1.0），
   而壳要联网下载完整版，Kitsune 上游地址已 404 → `System.exit(0)` 自杀。
   关键是 **magiskd 装壳的时机可能晚于 bootanim.rc**，所以一次性检查会被覆盖。
   处理方式：`install_app.sh` 用 `exec_background` 后台持续监视两分钟，
   每 2 秒查一次 versionName，发现是 `1.0`（壳）或未安装就重装完整版

### props.tar — 属性

把 native bridge 从 redroid 自带的 `libnb.so` 切到 `libhoudini.so`：

```
ro.dalvik.vm.native.bridge = libhoudini.so
ro.enable.native.bridge.exec = 1
ro.dalvik.vm.isa.arm   = x86
ro.dalvik.vm.isa.arm64 = x86_64
ro.product.cpu.abilist = x86_64,x86,arm64-v8a,armeabi-v7a,armeabi
```

---

## 第二部分：gralloc4.sh

这是本项目的核心，也是 redroid 原本跑不了 Vulkan 游戏的原因。

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

从 `ota.waydro.id` 下载 vendor.img（ext2），用 `debugfs` 免 root 提取：

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
vendor/build.prop:  ro.hardware.gralloc=minigbm_gbm_mesa
                    ro.hardware.vulkan=intel
                    ro.hardware.egl=mesa
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

### GPU 厂商无关性

搬运的组件里只有 Vulkan HAL 是分厂商的：

| 组件 | 厂商相关？ |
|---|---|
| gralloc4 / minigbm | 否 |
| `libgallium_dri.so` | **否** — megadriver，41MB 里含 radeonsi/iris/nouveau/zink/llvmpipe... |
| `libLLVM22.so` | 否 |
| EGL / GLES | 否 |
| `libdrm_{intel,amdgpu,radeon}.so` | 三个都已打包 |
| `vulkan.*.so` | **是** — 分文件 |

所以把 Waydroid 有的 Vulkan 驱动全部打包（intel / intel_hasvk / radeon / lvp / virtio，
约 +50MB），开机时由 `/vendor/bin/detect_gpu.sh` 在 `early-init` 阶段自动选：

```sh
drv=$(sed -n 's/^DRIVER=//p' /sys/class/drm/renderD*/device/uevent | head -1)
case "$drv" in
    i915|xe)    vk=intel ;;
    amdgpu)     vk=radeon ;;
    virtio_gpu) vk=virtio ;;
    *)          vk=lvp ;;
esac
setprop ro.hardware.vulkan "$vk"
```

两个设计细节：

- 开头先查 `getprop ro.hardware.vulkan`，**非空则直接退出** ——
  让启动参数 `ro.hardware.vulkan=xxx` 能覆盖自动检测
  （redroid 打了 `allow override ro.* prop` 补丁，内核 cmdline 里的 `ro.*` 会被写入）
- **故意不映射 nouveau**。镜像里确实有 `vulkan.nouveau.so`，
  但那是 redroid 自带的旧 Mesa 24（Waydroid 没有 nouveau 可搬），
  与 gralloc4 不兼容，选中反而会崩。宁可回退到 `lvp` 软件渲染。

### 依赖闭包

脚本末尾会做一次校验：遍历所有新增 `.so` 的 `DT_NEEDED`，
确认每个依赖要么在本层、要么基础镜像已有。这个检查抓到过 `libLLVM22.so` 的缺失。

---

## 层间的坑

`gralloc4.sh` 生成 `vendor/build.prop` 时必须**从 houdini 层的镜像**取模板，
不能从原版 redroid 取——否则会把 native bridge 设置冲回 `libnb.so`，
ARM 游戏全部闪退。脚本里由 `BASE_IMAGE` 变量控制。

这类"后层覆盖前层同名文件"的问题在多层叠加时要特别小心。
