#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p ../.build/fixtures
app="$PWD/../.build/fixtures/菜单栏测试图标.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 5 TestMenu.swift -o "$app/Contents/MacOS/TestMenu"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>收纳测试图标</string>
<key>CFBundleIdentifier</key><string>com.mike.aisubgauge.fixture</string>
<key>CFBundleExecutable</key><string>TestMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
open "$app"
