#!/bin/zsh
set -eu
cd "${0:A:h}"

archive="$PWD/dist/AI SubGauge.zip"
output="$PWD/dist/AI SubGauge-1.2.0-arm64.dmg"
[[ -f "$archive" ]] || { print -u2 '未找到已验收的应用 ZIP，请先完成构建与验收。'; exit 1; }
[[ ! -e "$output" ]] || { print -u2 '目标安装包已存在，请先保留或移走旧版本。'; exit 1; }

mkdir -p "$PWD/.build"
stage=$(mktemp -d "$PWD/.build/dmg.XXXXXX")
mkdir "$stage/磁盘内容" "$stage/解压"
# Read the clean ZIP, rather than the iCloud-managed .app that may regain Finder metadata.
ditto -x -k --noextattr --noqtn "$archive" "$stage/解压"
app="$stage/解压/AI SubGauge.app"
[[ -d "$app" ]] || { print -u2 'ZIP 中未找到 AI SubGauge.app。'; exit 1; }
codesign --verify --deep --strict "$app"
ditto --noextattr --noqtn --norsrc "$app" "$stage/磁盘内容/AI SubGauge.app"
codesign --verify --deep --strict "$stage/磁盘内容/AI SubGauge.app"
ln -s /Applications "$stage/磁盘内容/应用程序"
cat > "$stage/磁盘内容/安装说明.txt" <<'EOF'
AI SubGauge · AI SubGauge 1.2.0

将“AI SubGauge.app”拖入“应用程序”，然后从应用程序文件夹打开。

应用采用本机签名，尚未经过 Developer ID 公证。其他 Mac 首次打开可能出现系统安全提示；请确认来源后，在“系统设置 → 隐私与安全性”中允许打开。无法保证没有 Gatekeeper 提示。

辅助功能权限和排序位置文件访问按需授权。AI 账户连接为可选功能，全部功能免激活，无需激活密钥。
退出时可选择“退出并恢复所有图标”。
EOF
hdiutil create -srcfolder "$stage/磁盘内容" -volname 'AI SubGauge' -fs HFS+ -format UDZO "$stage/安装包.dmg"
hdiutil verify "$stage/安装包.dmg"
mv "$stage/安装包.dmg" "$output"
hdiutil verify "$output"
print "$output"
