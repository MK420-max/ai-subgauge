#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p "$PWD/dist" "$PWD/.build"
level=$(pmset -g batt | sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | head -1)
if [[ -n "$level" && "$level" -le 20 ]]; then
  print '电量已到停止阈值；保留当前构建。' >&2
  exit 20
fi
# Keep developer home/source paths out of distributable compiler metadata.
swift build --sdk "$(xcrun --show-sdk-path)" --triple arm64-apple-macosx26.0 "$@" -c release -debug-info-format none --scratch-path "$PWD/.build/release-build" \
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build" \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/src/AISubGauge" \
  -Xswiftc -file-prefix-map -Xswiftc "$HOME=/build" \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=/src/AISubGauge" \
  -Xcc "-ffile-prefix-map=$HOME=/build" \
  -Xcc "-ffile-prefix-map=$PWD=/src/AISubGauge"
stage=$(mktemp -d "$PWD/.build/package.XXXXXX")
app="$stage/AI SubGauge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$PWD/.build/release-build/release/AISubGauge" "$app/Contents/MacOS/AISubGauge"
# Drop the debug map (absolute object-file paths) from the shipped binary.
strip -S "$app/Contents/MacOS/AISubGauge"
if LC_ALL=C /usr/bin/grep -aFq "$HOME/" "$app/Contents/MacOS/AISubGauge"; then
  print -u2 '可执行文件含本机用户目录，已停止打包。'
  exit 1
fi
cp ../shared/running-processes.json "$app/Contents/Resources/running-processes.json"
cp ../shared/theme.json "$app/Contents/Resources/theme.json"
mkdir -p "$app/Contents/Resources/brand"
cp ../shared/brand/AISubGauge-{light,dark}.icns ../shared/brand/app-{light,dark}-1024.png \
  ../shared/brand/tray-mono.svg ../shared/brand/tray-mono-{18,36}.png "$app/Contents/Resources/brand/"
cp ../shared/brand/AISubGauge-light.icns "$app/Contents/Resources/AISubGauge-light.icns"
mkdir -p "$app/Contents/Resources/logos"
cp ../shared/logos/{claude,grok}.png ../shared/logos/LICENSE-LobeHub.txt "$app/Contents/Resources/logos/"
cp -R ../shared/logos/subscriptions "$app/Contents/Resources/logos/"
if [[ "${AISUBGAUGE_PRIVATE_LOGOS:-0}" == 1 && -f ../shared/private-logos/grokbot.png ]]; then
  mkdir -p "$app/Contents/Resources/private-logos"
  cp ../shared/private-logos/grokbot.png "$app/Contents/Resources/private-logos/"
fi
mkdir -p "$app/Contents/Resources/i18n"
cp ../shared/i18n/en.json ../shared/i18n/zh-Hans.json "$app/Contents/Resources/i18n/"
python3 Resources/localize-info.py "$app"
if [[ -d Resources/ProviderLogos ]]; then cp -R Resources/ProviderLogos "$app/Contents/Resources/ProviderLogos"; fi
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$app/Contents/Resources/LICENSE"
# Use the default cdhash-bound ad hoc requirement for the app and nested code.
source "$PWD/sign-app.sh"
sign_app "$app"
codesign -dr - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$PWD/dist/AI SubGauge.zip"
# Preserve the previous local build; merging signed bundles leaves stale sealed resources.
if [[ -e "$PWD/dist/AI SubGauge.app" ]]; then mv "$PWD/dist/AI SubGauge.app" "$stage/previous-AI SubGauge.app"; fi
ditto --norsrc "$app" "$PWD/dist/AI SubGauge.app"
xattr -cr "$PWD/dist/AI SubGauge.app"
codesign --verify --deep --strict "$PWD/dist/AI SubGauge.app"
print "$PWD/dist/AI SubGauge.app"
