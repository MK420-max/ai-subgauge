#!/bin/zsh
set -eu
cd "${0:A:h}/.."
# Package only this checkout's debug binary. No production app or data is accessed.
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
app="$PWD/.build/AI SubGauge UI v2.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/debug/AISubGauge "$app/Contents/MacOS/AISubGaugeUIV2"
chmod +x "$app/Contents/MacOS/AISubGaugeUIV2"
cp -R ../shared/{brand,logos,i18n} "$app/Contents/Resources/"
cp ../shared/{theme.json,running-processes.json} "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mike.aisubgauge.ui-v2</string>
<key>CFBundleName</key><string>AI SubGauge UI v2 Preview</string>
<key>CFBundleDisplayName</key><string>AI SubGauge UI v2 Preview</string>
<key>CFBundleExecutable</key><string>AISubGaugeUIV2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print "$app"
