#!/bin/bash
# redroid 15 (实验): 等价于 ANDROID_VERSION=15 ./gralloc4.sh
# 从 Waydroid LOS22 的 squashfs vendor.img 提取图形栈, 产出 redroid15-graft:latest
exec env ANDROID_VERSION=15 "$(dirname "$0")/gralloc4.sh" "$@"
