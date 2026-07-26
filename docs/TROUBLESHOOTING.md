# 调试历程

按实际遇到的顺序记录。每个问题都给出**日志特征**和**定位方法**，
遇到新问题时可以套用同样的思路。

通用起手式：

```bash
adb connect <IP>:<PORT>
adb -s <IP>:<PORT> logcat -d -b crash | tail -40      # 崩溃栈
adb -s <IP>:<PORT> logcat -d | grep -iE "关键词"      # 定向搜索
adb -s <IP>:<PORT> exec-out screencap -p > /tmp/s.png # 验证渲染
```

---

## 1. Magisk 点开就闪退

**日志**
```
x.COMPONENT_PLACEHOLDER_2
E DownloadActivity: java.io.FileNotFoundException:
    https://1q23lyc45.github.io/canary.json
I .huskydg.magisk: System.exit called, status: 0
```

**判断** — `dumpsys package io.github.huskydg.magisk | grep versionName`
返回 `1.0`（完整版应为 `ea3f64a9`）。

**原因** — 装成了 41KB 的 stub 壳。Magisk 守护进程发现
`/data/adb/magisk/stub.apk` 就优先装它，而壳要联网下载完整版，
Kitsune 上游地址已 404，于是自杀退出。

**修复** — 复制到 `/data/adb/magisk` 时排除 `stub.apk` 和 `magisk.apk`，
安装用 `pm install -r -d`。

> 注意不是"崩溃"，crash buffer 是空的，是 `System.exit(0)` 正常退出。
> 看到 crash buffer 为空但进程消失，要往"主动退出"方向想。

---

## 2. 帧率很低

**现象** — 感觉卡，怀疑没调用 GPU。

**排查**
```bash
adb shell dumpsys gfxinfo | grep -E "percentile|Janky|Missed"
# 50th percentile: 5ms      ← GPU 渲染一帧只要 5ms
# Janky frames: 0.76%
# Number Missed Vsync: 0

adb shell dumpsys display | grep fps
# supportedModes [{... fps=30.000002}]   ← 只有 30Hz
```

**结论** — GPU 完全没有瓶颈（5ms 相当于理论 200fps），
是被 `androidboot.redroid_fps` 默认值 30 锁死了。启动参数改 60 即可。

> 判断"是否 GPU 慢"看 gfxinfo 的 percentile，不要凭感觉。

---

## 3. ARM 游戏启动即 SIGABRT

**日志**
```
E linker : library "/system/lib64/arm64/libtcb.so" needed or dlopened by
           "/system/lib64/libhoudini.so" is not accessible for the namespace
           permitted_paths="/system/lib64/drm:/system/lib64/extractors:..."
I houdini: [26776] Fatal error (ID:0x0190015a).
F libc   : Fatal signal 6 (SIGABRT)
```

**原因** — linker 命名空间白名单不含 `/system/lib64/arm64`。

**修复** — ld.config 补丁（见 ARCHITECTURE.md）。

**验证**
```bash
adb shell "grep -c arm64 /linkerconfig/ld.config.txt"   # >0 即生效
```

> 补丁在 `/linkerconfig`（tmpfs），**容器重启会丢**，必须由 init.rc 每次开机重打。
> 调试时如果发现"昨天好的今天又坏了"，先查这个。

---

## 4. Unity 游戏黑屏

**日志**
```
E Unity: Desired shader compiler platform 5 is not available in shader blob
```

**原因** — Platform 5 = Vulkan。游戏只打包了 Vulkan shader，
而 redroid 默认只有 GLES，拿不到 shader，什么都渲染不出来。

**尝试开 Vulkan** → 撞上下一个问题：
```
E vulkan  : dequeueBuffer[0] failed: Invalid argument (-22)
I Gralloc4: mapper 4.x is not supported
I MESA    : Using fallback gralloc implementation
```

**结论** — 死结，需要移植 gralloc4。这是本项目的起点。

---

## 5. gralloc4 移植过程中的四个坎

### 5.1 `Unable to create gbm_mesa driver`

```
I [minigbm:gbm_mesa_internals.cpp(221)]: Found GPU xe
E [minigbm:gbm_mesa_internals.cpp(254)]: Unable to create gbm_mesa driver
```

找到了 GPU 但建不了 gbm device。

第一轮怀疑是 Mesa 版本（redroid 24.0.8 对 Arc 的 `xe` 内核驱动支持不完整），
搬了 Mesa 26 的 `dri_gbm.so` + `libgallium_dri.so`，报错变成：

```
E GBM-MESA-WRAPPER: Unable to create gbm device
W MESA: Support for this platform is experimental with Xe KMD   ← Mesa 26 才有这句
```

说明新驱动加载了但初始化没走完。查 `libgallium_dri.so` 的 `DT_NEEDED`：

```bash
readelf -d libgallium_dri.so | grep NEEDED
# libLLVM22.so    ← 105MB，完全没搬
# libdrm_intel.so ← redroid 只有 libdrm_intel.so.1，名字对不上
```

**根因** — 缺 `libLLVM22.so`。gallium 初始化要编译器后端，没有直接失败。

> 教训：搬运二进制一定要做**递归依赖闭包检查**。
> 注意 redroid 用 `libdrm.so.2` 这种带版本后缀的名字，Mesa 26 链的是无后缀的，
> 名字不同 = 等于没有。

### 5.2 SurfaceFlinger SIGSEGV

buffer 分配成功了（`Allocated: 720x1280, stride: 3072`），但 SF 崩溃：

```
signal 11 (SIGSEGV), Cause: null pointer dereference
  #00 gbm_mesa_bo_import(bo*, drv_import_fd_data*)+250
  #02 cros_gralloc_driver::retain
  #03 CrosGralloc4Mapper::importBuffer
```

对比两个进程的日志发现差异：

| 进程 | 结果 |
|---|---|
| allocator 服务 | `Allocated: 720x1280` ✅ |
| surfaceflinger | `Unable to create gbm device` → import 空指针 ❌ |

关键线索是这句：
```
I MESA : Using gralloc0 CrOS API
```

用 `strings` 确认这句只存在于 redroid 的旧 `libEGL_mesa.so`，Mesa 26 里没有。

**根因** — 旧 EGL 走 gralloc0 接口，新分配器给的是 gralloc4 handle，
结构对不上，import 时解引用空指针。

**修复** — EGL/GLES 也换成 Mesa 26（其 `DT_NEEDED` 里直接有
`mapper@4.0.so` 和 `libgralloctypes.so`，原生 gralloc4）。

### 5.3 scrcpy 灰屏但截屏正常

`screencap` 有画面，scrcpy 灰屏 → 说明 SF 渲染没问题，是**编码路径**的问题。

用 `screenrecord` 复现（同一条链路，比开 scrcpy 快）：

```bash
adb shell screenrecord --time-limit 3 /data/local/tmp/t.mp4
# Encoder failed (err=-38)
```

```
E ACodec: OMX/mediaserver died, signalling error!
```

crash buffer：
```
Cmdline: media.codec hw/android.hardware.media.omx@1.0-service
Abort message: 'gralloc-mapper is missing'
eax ebx ecx edx    ← 32 位寄存器
```

**根因** — OMX 编码服务是 **32 位**进程，而只搬了 64 位 mapper。
mapper 是 passthrough（进程内 dlopen），32 位进程需要 32 位实现。

**修复** — 补齐整套 32 位库（mapper4 / minigbm / Mesa 26 / LLVM / EGL）。

> screencap 是 CPU 直读所以不受影响。
> **"截屏正常但录屏/串流不行" = 编码器问题**，这个分诊很有用。

### 5.4 `vkCreateImage w/ native buffer failed`

Unity 成功走上 Vulkan（`searching for layers`，shader 错误消失），但：

```
D vulkan: vkCreateImage w/ native buffer failed: 3294895293
F libc  : Fatal signal 11 (SIGSEGV)
  #00 vulkan::driver::GetSwapchainImagesKHR(...)+30
```

```bash
adb shell ls -la /vendor/lib64/hw/vulkan.intel.so
# 15865088  2024-05-27     ← 还是 redroid 原版 Mesa 24
```

**根因** — 换了 gralloc4 和 EGL，唯独没换 Vulkan HAL。
旧 ANV 不认识 gralloc4 分配的 buffer，`vkCreateImage w/ native buffer`
（Android 特有的 gralloc-Vulkan 互操作接口）失败，返回空 swapchain。

**修复** — 补 Mesa 26 的 `vulkan.intel.so`（21MB）。

---

## 6. ARM 游戏又闪退了（层覆盖事故）

gralloc4 层做好后，之前能跑的游戏反而启动 60ms 就崩：

```
F libc: Fatal signal 11 (SIGSEGV), fault addr 0xffffffffffffffda
  #00 pc ... <anonymous:7344ddc00000>      ← 崩在匿名内存
```

```bash
adb shell getprop ro.dalvik.vm.native.bridge
# libnb.so      ← 应该是 libhoudini.so
```

**根因** — `gralloc4.sh` 生成 `vendor/build.prop` 时从**原版 redroid** 取模板，
把 houdini 层改好的属性覆盖回了默认值。

**修复** — 改为从 houdini 层镜像取（`BASE_IMAGE` 变量）。

> 多层叠加时，**后层的同名文件会完全覆盖前层**。
> 凡是要改配置文件的层，模板必须从直接上一层取，不能从原始镜像取。

---

## 走过的弯路

记下来避免重复尝试。

**升级 redroid 到 14/15** — 无用。
```bash
podman create docker.io/redroid/redroid:15.0.0-latest
# vendor/bin/hw/android.hardware.graphics.allocator@2.0-service
```
13/14/15 用的是同一套 vendor 镜像，gralloc 完全没变。

**切 `ro.hardware.gralloc=cros`** — 系统直接挂掉。
镜像里那个 `gralloc.cros.so` 是残缺的，切过去连系统 UI 都分配不出 buffer
（`createGraphicBuffer failed`），system_server 崩溃，adb 断连。

**换更高版本 libhoudini** — 已经是最高。
上游 `hpe-14` 分支 2026-01 的新 commit，houdini 二进制 md5 与现用版本完全相同。
`aow-13` 分支是**倒退**（13.0.1_z vs 14.0.0_z），实测导致赛马娘 SIGFPE 崩溃。

**换 libndk_translation** — 与图形无关。
它和 houdini 一样只是 CPU 指令翻译，不影响 Unity 选哪个图形 API。

**改用 Waydroid** — 与需求冲突。
Waydroid 的 gralloc4 确实是现成的，但它是**硬编码单实例**架构
（固定 `/var/lib/waydroid`、固定 LXC 容器名、独占 D-Bus 名 `id.waydro.Container`），
多开需要改造 Waydroid 本身；且强依赖 Wayland compositor，无头服务器上还要套
headless weston。对"多开 + scrcpy + 无头"的场景，redroid 才是对的，
只是需要把 Waydroid 的图形栈搬过来。

---

## 排查思路小结

1. **先分诊，再深挖** — 截屏正常吗？服务进程活着吗？crash buffer 有东西吗？
   这三个问题能把范围缩小一大半。
2. **crash buffer 为空 ≠ 没问题** — 可能是主动 `System.exit`。
3. **对比两个进程的日志** — 同一套库在 A 进程能用、B 进程不行,
   差异往往在位数（32/64）、命名空间、或加载方式（passthrough vs binder）。
4. **`readelf -d` 查依赖闭包** — 搬运二进制时必做，能提前发现缺库。
5. **`strings` 定位日志来源** — 判断某条日志来自新库还是旧库，
   是确认"新组件是否真的生效"的可靠手段。
6. **用最快的命令复现** — `screenrecord` 比开 scrcpy 快，
   `screencap` 比看画面快，`getprop` 比翻日志快。
