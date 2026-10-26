#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_DIR="$PROJECT_ROOT/dist/我Due！.app"
APP_ARCH="${WODUE_ARCH:-arm64}"
if [[ "$APP_ARCH" != arm64 && "$APP_ARCH" != x86_64 ]]; then
    print -u2 'WODUE_ARCH must be arm64 or x86_64.'
    exit 2
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_ROOT/module-cache"
sources=("$PROJECT_ROOT"/Sources/*.swift)
xcrun swiftc -parse-as-library -O -target "$APP_ARCH-apple-macosx14.0" \
    -module-cache-path "$BUILD_ROOT/module-cache" \
    -file-prefix-map "$PROJECT_ROOT=." -debug-prefix-map "$PROJECT_ROOT=." \
    "${sources[@]}" -o "$APP_DIR/Contents/MacOS/Daylist" \
    -framework SwiftUI -framework AppKit -framework EventKit -framework UserNotifications
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun swift -module-cache-path "$BUILD_ROOT/module-cache" "$PROJECT_ROOT/scripts/Icon.swift" "$BUILD_ROOT/icons"
cp "$BUILD_ROOT/icons/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
print "Built: $APP_DIR"
