#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
BUILD_DIR="$PROJECT_DIR/.build"
APP="$BUILD_DIR/QQQMBar.app"
CONTENTS="$APP/Contents"
DESTINATION="$HOME/Applications/QQQMBar.app"

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "未找到 Apple Swift 工具链。请安装 macOS Command Line Tools 或 Xcode 后重试。"
  exit 1
fi

# This directory contains only this script's generated output.
rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS/MacOS"
cp "$PROJECT_DIR/QQQMBar/Info.plist" "$CONTENTS/Info.plist"
plutil -replace CFBundleExecutable -string QQQMBar "$CONTENTS/Info.plist"
plutil -replace CFBundleIdentifier -string com.lyh.qqqmbar "$CONTENTS/Info.plist"
plutil -replace CFBundleName -string QQQMBar "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.13.8 "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string 31 "$CONTENTS/Info.plist"

xcrun swiftc -parse-as-library -O \
  "$PROJECT_DIR/QQQMBar/QQQMBarApp.swift" \
  -o "$CONTENTS/MacOS/QQQMBar"

codesign --force --sign - --options runtime \
  --entitlements "$PROJECT_DIR/QQQMBar/QQQMBar.entitlements" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$HOME/Applications"
INSTALL_BACKUP="$HOME/Applications/.QQQMBar-install-backup.app"
rm -rf "$INSTALL_BACKUP"
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$INSTALL_BACKUP"
fi
if mv "$APP" "$DESTINATION"; then
  rm -rf "$INSTALL_BACKUP"
else
  if [[ -e "$INSTALL_BACKUP" ]]; then mv "$INSTALL_BACKUP" "$DESTINATION"; fi
  exit 1
fi
open "$DESTINATION"
echo "已安装并启动：$DESTINATION"
