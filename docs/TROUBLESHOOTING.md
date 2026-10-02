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

**原因** — 装成了 41KB 的 stub 壳。壳要联网下载完整版，
Kitsune 上游地址已 404，于是自杀退出。

**这个问题修了四次**，前几次都没看到真正的因果，值得记下来：

**第一版**：复制到 `/data/adb/magisk` 时排除 `stub.apk`。
→ 无效，因为装壳的根本不是那条路径。

**第二版**：用 `install_app.sh` 按 versionName 判断，识别到 `1.0` 就覆盖。
→ 手动跑能修好，但开机时依旧是壳。

**真正的原因是时序**。`magisk.rc` 中的首次安装和 magiskd 自己安装 stub
没有固定先后。看日志：

```
22:28:49  I Magisk : pm_install: /data/stub.apk     ← magiskd 自己装的
22:28:50  I Magisk : pm_install: Success
```

magiskd 在它自己的时机 `pm_install /data/stub.apk`，
**而且这个时机可能在 `magisk.rc` 启动 `install_app.sh` 之后**。
只检查一次的脚本：开机时看到"未安装"→装了完整版→随后被 magiskd 覆盖回 stub。

**最终方案**：后台持续监视两分钟，发现壳就盖回来：

```sh
i=0
while [ $i -lt 60 ]; do
    ver=$(dumpsys package $PKG 2>/dev/null | sed -n "s/.*versionName=//p" | head -1)
    case "$ver" in
        ""|1.0) pm install -r -d "$APK" >/dev/null 2>&1 ;;
    esac
    i=$((i+1)); sleep 2
done
```

配合 init.rc 的 `exec_background`（不阻塞开机流程）。

（完整版 versionName 是 `ea3f64a9`，stub 永远是 `1.0`，可靠区分。）

**实测验证**：手动装上 stub 后，8 秒内被监视脚本自动覆盖回完整版。

**第四版（现行，Kitsune）**：读 magiskd 源码找到触发点——`--setup-sbin` 把
`/system/etc/init/magisk/stub.apk` 拷进 `/sbin`，`preserve_stub_apk()` 打开后删掉文件，
`--boot-complete` 时 `get_manager(..., install=true)` 找不到 app 就 `install_stub()`，
而它在 `stub_apk_fd < 0` 时直接返回。所以干脆不往镜像里放 `stub.apk`：magiskd 无壳可装，
`install_app.sh` 装好完整版就退出。这也解释了第一版为什么无效——它排除的是
`/data/adb/magisk` 里的副本，magiskd 用的是 `/sbin` 那份。
官方 Magisk（`ROOT=magisk`）仍走第三版的监视（原因见 ARCHITECTURE）。

> 教训：对于"有另一个守护进程也在操作同一资源"的情况，
> 一次性检查不够。要么找到它的触发点精确插入（第四版），要么就持续监视（第三版）。
> 先前两次失败都是因为只看到"现象消失了"就以为修好了，
> 没验证它会不会被重新触发。

**验证**
```bash
adb shell dumpsys package io.github.huskydg.magisk | grep versionName
#   ea3f64a9 = 完整版，1.0 = 壳
adb shell "echo id | /sbin/su"
#   uid=0(root) = root 正常
```

> 注意不是"崩溃"，crash buffer 是空的，是 `System.exit(0)` 正常退出。
> 看到 crash buffer 为空但进程消失，要往"主动退出"方向想。
>
> 另：`su` 命令超时无响应也是这个问题的表现之一（壳没有完整的授权界面）。

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

### 3.1 Houdini 到期后游戏卡死、CPU 满载

**现象** — ARM 游戏停在黑屏/标题前，进程持续占用数个 CPU 核；调试回溯落在
`libhoudini.so` 的循环或 `sched_yield` 附近。HPE 14 的内置有效期已触发。

**现行修复** — `build.sh` 默认调用 `patch-houdini-expiry.py`，同时禁用 32 位和
64 位到期失败分支。它是构建期补丁，已经进入镜像层，普通容器重启不会丢失：

```bash
adb shell sha256sum /system/lib/libhoudini.so
# com1.3 (默认): fa74f6f79ca55525e7ff057c03260ffa43eee905ea0320b5c2214829150452c8
# com1.2:        96fe3acce9aec00bf5d44a187e727aa6d1ef1cf29043c661fa26d4446044e993
adb shell sha256sum /system/lib64/libhoudini.so
# com1.3 (默认): da7448b3531865034e0e36425f18c4b55bf70f632518a272d469804370c13232
# com1.2:        847be255d03886974ff0cff09d09b7530301d24671ce0f80172ab3a0629d23b8
```

若构建报 `unsupported libhoudini.so SHA-256`，说明上游二进制已变化或缓存损坏。
**不要加 force、不要搜索相似字节后盲打**；先确认下载包 SHA，再对新版的两种 ABI
重新做控制流审计、更新原/目标完整 SHA 和偏移。可用
`PATCH_HOUDINI_EXPIRY=0` 构建原版做负对照，但它不会解决到期问题。

“永久”只针对当前锁定的 HPE 二进制及已知检查路径；更新 Houdini 后必须重新审计。

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

**根因（旧构建顺序）** — 当时是先叠 houdini 再叠 gralloc4，
`gralloc4.sh` 生成 `vendor/build.prop` 时从**原版 redroid** 取模板，
把 houdini 层改好的属性覆盖回了默认值。

**现行修复** — 构建顺序改为先 `gralloc4.sh` 再 `build.sh`：
图形栈底图先就位；`build.sh` 只 patch native bridge 相关键。
后来图形栈属性又从 `build.prop` 挪到了开机执行的 `gpu_config.sh`
（见 ARCHITECTURE「GPU 属性：开机探测」），这一类覆盖已经不会再波及图形栈。

> 多层叠加时，**后层的同名文件会完全覆盖前层**。
> 凡是要改配置文件的层，模板必须从直接上一层取，不能从原始镜像取；
> 能只改键就不要整文件重写。

---

## 7. 进系统设置 → 整屏崩（allocator@4 SIGSEGV）

**现象** — 桌面/截屏正常，一点「设置」子页（应用列表、显示等）就黑屏或重启 UI。

**日志**
```
F libc: Fatal signal 11 (SIGSEGV) ... allocator@4.0-service.minigbm_gbm_mesa
  #?? dri2_map_image / dri_flush   ← libgallium_dri.so
  #?? gbm_mesa_alloc              ← libgbm_mesa_wrapper.so
  #?? gbm_mesa_bo_create          ← libminigbm_gralloc_gbm_mesa.so
```

分配成功时也能看到：
```
V [minigbm:gbm_mesa_internals.cpp]: Allocated: 1080x1920, stride: 4352, map_stride: 0
```
`map_stride: 0` 表示没走（或没走完）SW 探测；崩的往往是带 `BO_USE_SW_MASK` 的那批。

**原因** — Settings 等 UI 会申请带 `BO_USE_SW_MASK` 的 buffer。
`gbm_mesa_alloc` 为了探测 `map_stride`，会在分配后再 `gbm_bo_import` + `gbm_bo_map` + `unmap`。
在 Intel Arc + `xe` 上，这条 map/flush 路径会空指针崩；
allocator 的 init 里有 `onrestart restart surfaceflinger`，于是把整桌面拖死。

**不是这些问题**（当时都试过）：

| 怀疑 | 实测 |
|---|---|
| 多实例抢同一块 GPU | 停掉其它 redroid 后**照样崩** |
| 打包了全厂商 Vulkan / `detect_gpu` | 退回 Intel-only **照样崩** |
| redroid-xe 的 minigbm 二进制补丁<br>（`patch-minigbm-bo-import` / `formats`） | bind-mount 后仍崩（有时变成 Scudo abort，本质还在 Mesa map 路径） |
| 退回 `gralloc=gbm` + Mesa 24 | Settings 是稳了，但 **Vulkan 游戏不可用**，不能接受 |

对照：未嫁接 gralloc4 的旧实例能进设置（`ro.hardware.gralloc=gbm`，Mesa 24）。

**修复** — SW buffer 已 `force_linear`，`map_stride == stride`，不必真去 map。
`scripts/patch-gbm-mesa-skip-map-stride.py` 在 `gralloc4.sh` 里改掉
`libgbm_mesa_wrapper.so`：跳过探测，直接 `out_map_stride = out_stride`。
**不回退 gralloc4 / Mesa 26 / Vulkan。**

**验证**
```bash
adb shell am start -a android.settings.APPLICATION_SETTINGS
# crash buffer 不应再有 allocator@4
adb logcat -d -b crash | grep allocator@4   # 空
adb shell "ps -A | grep allocator@4"        # 仍在
# 分配日志里 map_stride 应等于 stride（不再是 0）
adb logcat -d | grep 'Allocated:'
#   Allocated: 1080x1920, stride: 4352, map_stride: 4352
```

---

## 8. 游戏到底有没有走 Vulkan？

**现象** — 画面能出来，但不确定是 GLES 还是 Vulkan
（尤其是少女前线2 这种 Vulkan-only Unity）。

**不要看** `dumpsys gfxinfo` 里的 `Pipeline=Skia (OpenGL)` ——
那是 Android 控件层（状态栏/View），不是 Unity SurfaceView 主渲染。

**要看** `dumpsys gpu`：

```bash
adb shell dumpsys gpu | grep -A20 'appPackageName = com.Sunborn.SnqxExilium'
#   vkDriverLoadingTime: <非空数字>   ← 已加载 Vulkan 驱动
#   cpuVulkanInUse = 0                ← 走 GPU，不是 CPU Vulkan
#
adb shell dumpsys gpu | head -20
#   vkLoadingCount = 1                ← 有进程成功加载过
#   vkLoadingFailureCount = 0
```

**失败时的老特征**（嫁接不完整时会出现）：
```
E Unity: Desired shader compiler platform 5 is not available
E vulkan: dequeueBuffer failed: Invalid argument (-22)
I Gralloc4: mapper 4.x is not supported
D vulkan: vkCreateImage w/ native buffer failed
```

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

**换更高版本 libhoudini** — 2026-09 上游 `hpe-14` 出了 com1.3（`2f8f0886`，
waydroid-helper 已跟进），现为默认；com1.2 可用 `HOUDINI_VERSION=1.2` 回退。
两者都带时间炸弹，都需要补丁。
`aow-13` 分支是**倒退**（13.0.1_z vs 14.0.0_z），实测导致赛马娘 SIGFPE 崩溃。

**换 libndk_translation** — 与图形无关。
它和 houdini 一样只是 CPU 指令翻译，不影响 Unity 选哪个图形 API。

**改用 Waydroid** — 与需求冲突。
Waydroid 的 gralloc4 确实是现成的，但它是**硬编码单实例**架构
（固定 `/var/lib/waydroid`、固定 LXC 容器名、独占 D-Bus 名 `id.waydro.Container`），
多开需要改造 Waydroid 本身；且强依赖 Wayland compositor，无头服务器上还要套
headless weston。对"多开 + scrcpy + 无头"的场景，redroid 才是对的，
只是需要把 Waydroid 的图形栈搬过来。

**为修 Settings 而退回未嫁接的旧图形栈（Mesa 24 + `gralloc=gbm`）** — 禁止。
Settings 是稳了，Vulkan-only 游戏会黑屏/崩。正确做法是保留 gralloc4，
打 `patch-gbm-mesa-skip-map-stride.py`（见 §7）。

**以为 Settings 崩是「多厂商 Vulkan / detect_gpu」引起的** — 误判。
Intel-only 硬编码后照样崩；根因是 allocate 时的 `gbm_bo_map` 探测（§7）。

**只 bind-mount redroid-xe 的 patched minigbm** — 治不好 Settings。
那两处补丁针对 SW import / Unity 格式探测，不绕开 wrapper 里的 map_stride 探测。

---

## 排查思路小结

1. **先分诊，再深挖** — 截屏正常吗？服务进程活着吗？crash buffer 有东西吗？
   这三个问题能把范围缩小一大半。
2. **crash buffer 为空 ≠ 没问题** — 可能是主动 `System.exit`。
3. **对比两个进程的日志** — 同一套库在 A 进程能用、B 进程不行,
   差异往往在位数（32/64）、命名空间、或加载方式（passthrough vs binder）。
4. **按链接器命名空间查依赖闭包** — 搬运二进制时必做。文件"存在"不等于
   "可见"：sphal/vendor 命名空间看不到大部分 `/system/lib*`。
   `scripts/check-vendor-closure.py` 在构建时自动做，含符号检查。
5. **`strings` 定位日志来源** — 判断某条日志来自新库还是旧库，
   是确认"新组件是否真的生效"的可靠手段。
6. **用最快的命令复现** — `screenrecord` 比开 scrcpy 快，
   `screencap` 比看画面快，`getprop` 比翻日志快。
7. **游戏是否 Vulkan 看 `dumpsys gpu`，别看 gfxinfo 的 Skia 行**（见 §8）。
8. **「能进设置」的旧容器未必带 Vulkan** — 先 `getprop ro.hardware.gralloc`
   区分 `gbm`（旧）和 `minigbm_gbm_mesa`（嫁接）。
9. **Vulkan 驱动选得对不对** — `logcat -d -s gpu_config` 会打印选中的节点、内核驱动
   和 `ro.hardware.vulkan`；不对就用 `androidboot.redroid_vulkan=` 强制。

---

## 附录 A：原版 redroid 的 Vulkan 能力验证记录

"原版 redroid 跑不了需要 Vulkan 的游戏"不是猜测，验证分三步：

**1. 拆解原版镜像（`redroid/redroid:13.0.0-latest`）**

- vendor 里确实打了 Mesa Vulkan 驱动（`lib64/hw/vulkan.{intel,radeon,...}.so`）
  和 Vulkan feature XML，gpu_config.sh 还会按 DRI 驱动设置 `ro.hardware.vulkan`
- 但 gralloc 只有 `android.hardware.graphics.allocator@2.0`（gbm_gralloc），Mesa 版本为 24.0.8

**2. host GPU 模式实机启动**

- 在 Arc A380 上：SurfaceFlinger 能起，但 Vulkan 应用分配 swapchain buffer 失败
  （`dequeueBuffer -22` + `mapper 4.x is not supported`，见 §4），Vulkan-only 游戏黑屏
- 在新的 AMD GPU（RDNA4 世代）上：自带的 Mesa 24.0.8 太旧，连 gbm 设备都创建失败
  （`GRALLOC-GBM: failed to create gbm device`），SurfaceFlinger 起不来，boot 卡死

**3. guest（纯软件）模式实机启动**

- SwiftShader Vulkan（pastel）可加载，`pm list features` 声明 Vulkan，
  `debug.hwui.renderer=skiavk` 后设置界面确实走 `Skia (Vulkan)` 管线
- 但交换链每帧报 `VulkanManager::swapBuffers(): Failed to get semaphore Fd`
  （SwiftShader 不支持导出 sync fd），且全程 CPU 软渲——对游戏无实用价值

**结论**：原版 redroid 对 Vulkan 的支持停留在"镜像里有驱动文件"的层面，
两种模式下都拿不出可用的 GPU 加速 Vulkan 交换链。这正是本项目存在的原因。
