# AI SubGauge shared assets

`logos/` is the common offline asset directory for the Windows and Mac versions. Windows embeds it using paths relative to `src/AISubGauge/AISubGauge.csproj`, while retaining the original `WindowsQuotaTray.assets.logos.*` manifest resource names. No runtime image download is needed. Mac packaging copies shared process and language resources through `mac/build.sh`.

## Lobe Icons

Provider identity PNGs, including the matching `dark/` variants, come from [Lobe Icons](https://github.com/lobehub/lobe-icons). The source package recorded with the supplied assets is `@lobehub/icons-static-png@1.97.1`. See [logos/LICENSE-LobeHub.txt](logos/LICENSE-LobeHub.txt) for its MIT license. Include that notice in distributions.

The supplied Lobe assets cover OpenAI, Anthropic/Claude, Gemini, GitHub Copilot, Cursor, Kimi, GLM/Zhipu, Mistral, DeepSeek, OpenRouter, MiniMax and xAI/Grok brand identifiers. Code licensing does not transfer trademark rights.

## Grok icons and optional private artwork

Public builds use the Lobe Icons Grok logo with the standard liquid gauge. The Grok Bot app extractions `grokbot.png` and `grokbot-head.png` are excluded from the open-source distribution and moved to `shared/private-logos/`, which is ignored by .gitignore; the old Windows copies are in its `windows/` subdirectory. Public builds exclude private artwork even when it exists locally. For a local private build, provide `shared/private-logos/grokbot-head.png` and explicitly add `-p:IncludePrivateLogos=true` to `dotnet build` or `dotnet publish` (for example, `dotnet build .\src\AISubGauge\AISubGauge.csproj -c Release -p:IncludePrivateLogos=true` from `windows/`). Only when the property is `true` and the file exists does the csproj embed it and define `PRIVATE_GROK_LOGO` to retain the head-mask gauge. Otherwise it uses `shared/logos/grok.png`. Tests support both builds. For a local private Mac build, provide `shared/private-logos/grokbot.png` and run `AISUBGAUGE_PRIVATE_LOGOS=1 zsh build.sh` from `mac/`. The private logo is copied only when the flag is explicitly set to `1` and the file exists. Redistribution permission for the private artwork has not been confirmed.

公开版使用 Lobe Icons 的 Grok 图标，按普通液位渲染。Grok Bot app 提取的 `grokbot.png` 与 `grokbot-head.png` 不随开源仓库分发，已移入被 .gitignore 忽略的 `shared/private-logos/`；旧 Windows 副本位于其 `windows/` 子目录。公开构建即使在本地发现私有素材也不会打包。本地私用构建须准备 `shared/private-logos/grokbot-head.png`，并为 `dotnet build` 或 `dotnet publish` 显式添加 `-p:IncludePrivateLogos=true`（例如从 `windows/` 运行 `dotnet build .\src\AISubGauge\AISubGauge.csproj -c Release -p:IncludePrivateLogos=true`）。只有属性为 `true` 且文件存在时，csproj 才会嵌入并定义 `PRIVATE_GROK_LOGO`，继续使用头像蒙版液位；否则回退到 `shared/logos/grok.png`。测试兼容两种构建。Mac 本地私用构建：将素材放在 `shared/private-logos/grokbot.png`，从 `mac/` 运行 `AISUBGAUGE_PRIVATE_LOGOS=1 zsh build.sh`。只有显式设置为 `1` 且文件存在时才复制私有图标。私有素材的再分发许可未确认。

## Trademarks

OpenAI and Codex belong to OpenAI; Anthropic and Claude to Anthropic PBC; Gemini to Google; GitHub and Copilot to GitHub/Microsoft; Cursor to Anysphere; Kimi to Moonshot AI; GLM/Zhipu to their respective owners; Mistral to Mistral AI; and Grok/Grok Bot/xAI to their respective xAI/SpaceXAI rights holders. Other marks belong to their respective owners. Names and logos identify services and do not imply endorsement or affiliation.

## Versions and installation

| Platform | Version | Installation location |
| --- | --- | --- |
| Windows | 1.2.0 | `%LOCALAPPDATA%\Programs\AISubGauge\AISubGauge.exe` |
| Mac | 1.2.0 | `/Applications/AI SubGauge.app` |

[Shared strings](strings.md) records the wording and formatting contract for both platforms. The Mac implementation now uses the shared language catalogs and process map described below. Windows can adopt the same JSON formats in its next implementation pass.

## Shared process map and languages

`running-processes.json` maps stable provider IDs to arrays of exact process names. Matching is case-insensitive. Windows must compare `ProcessName` without `.exe`; Mac compares app localized names, executable filenames and `proc_name` results. Mac's `build.sh` copies the map into Resources. A same-name file in the app settings directory replaces the whole map after restart; an invalid file falls back to the bundled map.

`i18n/en.json` and `i18n/zh-Hans.json` are flat string dictionaries shared by both platforms. Keys cover panels, menus, settings, errors, consent, demo data and diagnostics; placeholders use numbered braces such as `{0}`. Keep key sets and placeholder sets identical and values nonempty. Mac packages the files under Resources/i18n. The Windows implementation is a later task; these files do not add Windows runtime behavior themselves.

Run `python3 shared/i18n/check-keys.py` from the repository root, or pass one or more source directories to check literal `L10n.text`, `I18n.T`, `I18n.Get` and `L10n.Get` references. Mac's Swift tests also check catalog parity and source references.

## 共享进程映射与语言资源

`running-processes.json` 将固定厂商 ID 映射到一组进程名，采用不区分大小写的完整名称匹配。Windows 应匹配不带 `.exe` 的 `ProcessName`；Mac 匹配应用 localizedName、可执行文件名及 `proc_name` 结果。Mac 的 `build.sh` 将映射复制到 Resources。应用设置目录中的同名文件在重启后覆盖完整映射；文件无效时回退到打包默认值。

`i18n/en.json` 与 `i18n/zh-Hans.json` 是两端共用的扁平语言字典，覆盖面板、菜单、设置、错误、同意提示、演示和诊断。占位符使用 `{0}` 等编号格式；两种语言的键集合及占位符集合必须一致，值不能为空。Mac 打包到 Resources/i18n。Windows 运行时接入留待后续完成，共享文件本身不会启用 Windows 功能。

在仓库根目录运行 `python3 shared/i18n/check-keys.py`，也可附加一个或多个源码目录，检查 `L10n.text`、`I18n.T`、`I18n.Get` 和 `L10n.Get` 的固定键引用。Mac 单元测试也会检查语言键集合和源码引用。

## Shared app branding and themes / 共享品牌与主题

`brand/` contains the supplied app logos, `.icns`/`.ico` files and monochrome tray artwork. Mac packages the light/dark app icons and panel PNGs, plus `tray-mono.svg` and its 18/36px rasterizations. Runtime icon tinting uses macOS template images. Windows integration is deferred.

`theme.json` is the single color source. `themes.light` and `themes.dark` must have identical key sets. `backgroundGradient` is an ordered color array; remaining palette keys are colors in `#RRGGBB` or `#RRGGBBAA` form. Added panel tokens: `panelBorder`, `glassOverlay`, `buttonFill`, `buttonBorder`, `divider`, `wave`. `providers` preserves existing provider tints. `quota.high/mid/low` preserves existing Windows liquid colors (`#2CAC6D`, `#E7B228`, `#E04B52`); use low through 15%, interpolate low→mid through 32.5%, then mid→high through 50%, and high thereafter (round channels to nearest, ties to even). Do not replace them with platform-specific colors.

Panel text keys include `panel.settings`, `panel.refresh`, `panel.quotaLeft`, `panel.resetHoursMinutes`, `panel.resetDaysHours`, `panel.resetMinutes`, `panel.resetUnknown`, `panel.resetDue`, `panel.provider.grok`; theme choices use `settings.theme` and `settings.theme.system/light/dark`. `{0}` in `panel.quotaLeft` includes `%`. All are present in both catalogs. The compact panel order is Codex, Grok, Claude, then API accounts. Remaining values must retain unknown/error/demo semantics.

`theme.json` 是两端共用的颜色来源；浅深主题键集合必须相同，支持六位 RGB 或八位 RGBA。新增面板描边、玻璃叠层、按钮填充/描边、分隔线和波纹颜色。`quota` 已按现有 Windows 液位颜色回写，过渡规则见上；两端直接复用。Mac 主题设置为 `Theme=system|light|dark`，缺失时跟随系统，即时生效。Windows 后续在 `settings.json` 使用同名 `Theme` 字段，旧设置无此字段时跟随系统；本次未改动 Windows 实现。
