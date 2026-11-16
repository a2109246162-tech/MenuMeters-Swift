#!/bin/bash
# 一键构建 MenuMeters.app：编译源码 + 组装 bundle + ad-hoc 签名
set -e

# 基于脚本自身位置推导项目根目录，避免硬编码绝对路径
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/output/MenuMeters.app"

# 清理旧产物，重建目录结构
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 编译主程序（-O 优化，减小体积、提升性能）
swiftc -O -framework AppKit -framework IOKit "$ROOT/src/main.swift" -o "$APP/Contents/MacOS/MenuMeters"

# 拷贝图标与配置
cp "$ROOT/output/MenuMeters.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/src/Info.plist" "$APP/Contents/Info.plist"

# ad-hoc 签名（本地运行更稳妥；正式分发仍需 Developer ID + 公证）
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "BUILD_OK: $APP"
echo "App 体积："
du -sh "$APP"
