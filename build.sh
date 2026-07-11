#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="访达小宝"
BUNDLE="$APP_NAME.app"
MIN_MACOS="13.0"

# 清理旧名称产物，避免混淆
rm -rf "$BUNDLE" FinderGoUp.app build
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" build/arm64 build/x86_64

echo "🔧 正在编译（通用二进制 arm64 + x86_64）..."

swiftc -O -target arm64-apple-macosx$MIN_MACOS \
    Sources/main.swift -o build/arm64/$APP_NAME \
    -framework AppKit -framework CoreGraphics -framework ApplicationServices \
    -framework ServiceManagement -framework UserNotifications

swiftc -O -target x86_64-apple-macosx$MIN_MACOS \
    Sources/main.swift -o build/x86_64/$APP_NAME \
    -framework AppKit -framework CoreGraphics -framework ApplicationServices \
    -framework ServiceManagement -framework UserNotifications

lipo -create -output "$BUNDLE/Contents/MacOS/$APP_NAME" \
    build/arm64/$APP_NAME build/x86_64/$APP_NAME

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

echo "🔏 正在 ad-hoc 签名..."
codesign --force --deep --sign - "$BUNDLE"

echo "✅ 已构建 $BUNDLE"
echo "   路径：$(pwd)/$BUNDLE"
