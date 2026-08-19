#!/bin/bash
# 在已有 graft 镜像上叠加 GApps（默认 MindTheGapps）
# 配方对齐 waydroid-helper/extensions 的 MindTheGapps / LiteGapps
# 须先有图形栈 + 建议先有 houdini/magisk:
#   ./scripts/gralloc4.sh && ./scripts/build.sh && ./scripts/inject-gapps.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DL="$HERE/dl"
SRC="$HERE/src/gapps"
OUT="$HERE/out"
CTR=${CTR:-podman}

# 默认叠在「挂机完整版」上; 也可 BASE_IMAGE=localhost/redroid13-graft:latest
BASE_IMAGE="${BASE_IMAGE:-localhost/redroid13-graft-houdini-magisk:latest}"
NEW_IMAGE="${NEW_IMAGE:-localhost/redroid13-graft-houdini-magisk-gapps:latest}"

# GAPPS=mindthe (默认) | lite
GAPPS="${GAPPS:-mindthe}"

# 无头多开一般不需要 Setup Wizard; 写入属性避免每次开机卡在向导
# 需要完整向导时: SKIP_SETUP=0 ./scripts/inject-gapps.sh
SKIP_SETUP="${SKIP_SETUP:-1}"

msg() { echo -e "\033[1;32m==>\033[0m $*"; }

case "$GAPPS" in
    mindthe|mindthegapps)
        # wh-extensions/gapps/mindthegapps/20250913/EXTENSION
        GAPPS_NAME="MindTheGapps"
        GAPPS_VER="20250913"
        GAPPS_ZIP="$DL/MindTheGapps-13.0.0-x86_64-${GAPPS_VER}.zip"
        GAPPS_URL="https://github.com/ayasa520/MindTheGappsBuilder/releases/download/${GAPPS_VER}/MindTheGapps-13.0.0-x86_64-${GAPPS_VER}.zip"
        GAPPS_SHA="71cf70e6358ecc4d536b9426e6e256d35d128741da48efab69ab6bf7544c6228"
        ;;
    lite|litegapps)
        # wh-extensions/gapps/litegapps/lite/13.0_20250810/EXTENSION
        GAPPS_NAME="LiteGapps"
        GAPPS_VER="13.0-20250810-unofficial"
        GAPPS_ZIP="$DL/LiteGapps-x86_64-13.0-20250810-unofficial.zip"
        GAPPS_URL="https://github.com/ayasa520/litegapps/releases/download/20250810/LiteGapps-x86_64-13.0-20250810-unofficial.zip"
        GAPPS_SHA="75f6643d4ca10e1fe005fed4c3db54d174b2470442f4da006bd137ebfb94083a"
        ;;
    *)
        echo "GAPPS 只支持 mindthe 或 lite"; exit 1 ;;
esac

if ! $CTR image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    echo "错误: 找不到底图 $BASE_IMAGE" >&2
    echo "请先: ./scripts/gralloc4.sh && ./scripts/build.sh" >&2
    exit 1
fi

fetch() {
    local url=$1 sha=$2 dest=$3
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
        msg "已缓存 $(basename "$dest")"
        return
    fi
    msg "下载 $(basename "$dest")"
    curl -fL --retry 3 -o "$dest" "$url"
    [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ] || {
        echo "sha256 校验失败: $dest" >&2; exit 1; }
}

mkdir -p "$DL" "$OUT"
rm -rf "$SRC"; mkdir -p "$SRC/layer" "$SRC/extract"

fetch "$GAPPS_URL" "$GAPPS_SHA" "$GAPPS_ZIP"

msg "解包 $GAPPS_NAME ($GAPPS_VER)"
case "$GAPPS" in
    mindthe|mindthegapps)
        # EXTENSION package(): unzip; cp -rf system $pkgdir/
        unzip -oq "$GAPPS_ZIP" -d "$SRC/extract"
        if [ -d "$SRC/extract/system" ]; then
            cp -a "$SRC/extract/system" "$SRC/layer/system"
        elif [ -d "$SRC/extract/system/system" ]; then
            mkdir -p "$SRC/layer/system"
            cp -a "$SRC/extract/system/system/." "$SRC/layer/system/"
        else
            echo "MindTheGapps zip 里找不到 system/" >&2
            find "$SRC/extract" -maxdepth 3 -type d | head -40 >&2
            exit 1
        fi
        # redroid 底图: /product -> /system/product, /system_ext -> /system/system_ext
        # 切勿 ADD 顶层 product/ 目录，否则会覆盖 symlink。顶层包内容并入 system/
        for p in product system_ext; do
            if [ -d "$SRC/extract/$p" ]; then
                mkdir -p "$SRC/layer/system/$p"
                cp -a "$SRC/extract/$p/." "$SRC/layer/system/$p/"
            fi
        done
        ;;
    lite|litegapps)
        # EXTENSION: tar -xvf files/files.tar.xz --strip-components=2 CARCH/33/system
        unzip -oq "$GAPPS_ZIP" -d "$SRC/extract"
        TARXZ=$(find "$SRC/extract" -name 'files.tar.xz' | head -1)
        [ -n "$TARXZ" ] || { echo "LiteGapps 缺少 files/files.tar.xz" >&2; exit 1; }
        mkdir -p "$SRC/tmp_lite" "$SRC/layer"
        tar -xJf "$TARXZ" -C "$SRC/tmp_lite"
        SYS=$(find "$SRC/tmp_lite" -type d -path '*/x86_64/33/system' | head -1)
        [ -n "$SYS" ] || SYS=$(find "$SRC/tmp_lite" -type d -path '*/33/system' | head -1)
        [ -n "$SYS" ] || { echo "LiteGapps 解不出 system" >&2; find "$SRC/tmp_lite" | head -40 >&2; exit 1; }
        BASE=$(dirname "$SYS")
        cp -a "$BASE/system" "$SRC/layer/system"
        # 同上: 并入 system/，勿造顶层 product/system_ext 目录
        for p in product system_ext; do
            if [ -d "$BASE/$p" ]; then
                mkdir -p "$SRC/layer/system/$p"
                cp -a "$BASE/$p/." "$SRC/layer/system/$p/"
            fi
        done
        ;;
esac

# 权限: 目录 755, 普通文件 644, shell 755（与 EXTENSION 一致）
msg "修正权限"
find "$SRC/layer" -type d -exec chmod 755 {} +
find "$SRC/layer" -type f -exec chmod 644 {} +
find "$SRC/layer" -name '*.sh' -exec chmod 755 {} +
# 可执行 binary（无后缀且在 bin/）
find "$SRC/layer" \( -path '*/bin/*' -o -path '*/xbin/*' \) -type f -exec chmod 755 {} +

if [ "$SKIP_SETUP" = 1 ]; then
    msg "写入 ro.setupwizard.mode=DISABLED（跳过 GApps 向导）"
    mkdir -p "$SRC/layer/system/etc/prop.d" "$SRC/layer/system"
    # prop.d 在部分镜像不生效; 再 patch 一份从底图拷出的 system/build.prop
    CID=$($CTR create "$BASE_IMAGE")
    $CTR cp "$CID:/system/build.prop" "$SRC/layer/system/build.prop" 2>/dev/null || true
    $CTR rm "$CID" >/dev/null
    if [ -f "$SRC/layer/system/build.prop" ]; then
        python3 - "$SRC/layer/system/build.prop" <<'PY'
import re, sys
p = sys.argv[1]
props = {"ro.setupwizard.mode": "DISABLED"}
lines = open(p).read().splitlines()
seen, out = set(), []
for ln in lines:
    m = re.match(r"^([\w.]+)=", ln)
    if m and m.group(1) in props:
        k = m.group(1); out.append(f"{k}={props[k]}"); seen.add(k)
    else:
        out.append(ln)
rest = [k for k in props if k not in seen]
if rest:
    out.append("# gapps: skip setup wizard for headless")
    out += [f"{k}={props[k]}" for k in rest]
open(p, "w").write("\n".join(out) + "\n")
print("patched system/build.prop")
PY
        chmod 0644 "$SRC/layer/system/build.prop"
    else
        # 兜底: 单独 prop 文件 + 启动参数文档说明
        echo "ro.setupwizard.mode=DISABLED" > "$SRC/layer/system/etc/prop.d/99-gapps-skip-setup.prop"
        chmod 0644 "$SRC/layer/system/etc/prop.d/99-gapps-skip-setup.prop"
    fi
fi

msg "打包 gapps.tar"
# 统计一下装了什么
find "$SRC/layer" -name '*.apk' | sed 's|.*/||' | sort -u | head -40
APK_N=$(find "$SRC/layer" -name '*.apk' | wc -l)
msg "共 $APK_N 个 apk"

tar --owner=0 --group=0 --numeric-owner -cf "$OUT/gapps.tar" -C "$SRC/layer" .

cat > "$OUT/Dockerfile.gapps" <<EOF
FROM $BASE_IMAGE

ADD gapps.tar /
EOF

if [ "${BUILD_IMAGE:-1}" = 1 ]; then
    msg "构建镜像 $NEW_IMAGE"
    $CTR build -t "$NEW_IMAGE" -f "$OUT/Dockerfile.gapps" "$OUT"
    msg "完成: $NEW_IMAGE"
    echo
    echo "提示:"
    echo "  - Play 商店首次需注册设备 Android ID（GSF）:"
    echo "      adb shell sqlite3 /data/data/com.google.android.gsf/databases/gservices.db \\"
    echo "        \"select value from main where name='android_id';\""
    echo "      再到 https://www.google.com/android/uncertified/ 登记"
    echo "  - 若仍进向导, 启动加: ro.setupwizard.mode=DISABLED"
else
    msg "已生成 $OUT/gapps.tar / Dockerfile.gapps"
fi
