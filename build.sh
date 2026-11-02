#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Monitor Brightness.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
make -C vendor/m1ddc
cp vendor/m1ddc/m1ddc "$APP/Contents/Helpers/m1ddc"
cp vendor/m1ddc/LICENSE "$APP/Contents/Resources/m1ddc-LICENSE.txt"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/main.swift -o "$APP/Contents/MacOS/MonitorBrightness" -framework AppKit -framework SwiftUI
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MonitorBrightness</string>
<key>CFBundleIdentifier</key><string>local.sankarshan.monitor-brightness</string>
<key>CFBundleName</key><string>Monitor Brightness</string>
<key>CFBundleDisplayName</key><string>Monitor Brightness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/m1ddc"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
