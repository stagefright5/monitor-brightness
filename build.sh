#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Monitor Brightness.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
make -C vendor/m1ddc
cp vendor/m1ddc/m1ddc "$APP/Contents/Helpers/m1ddc"
cp vendor/m1ddc/LICENSE "$APP/Contents/Resources/m1ddc-LICENSE.txt"
xcrun swift Tools/generate-icon.swift "$PWD/build"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -import-objc-header Sources/VirtualDisplay.h Sources/main.swift -o "$APP/Contents/MacOS/MonitorBrightness" -framework AppKit -framework SwiftUI -framework QuartzCore -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MonitorBrightness</string>
<key>CFBundleIdentifier</key><string>local.sankarshan.monitor-brightness</string>
<key>CFBundleName</key><string>Monitor Brightness</string>
<key>CFBundleDisplayName</key><string>Monitor Brightness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/m1ddc"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
