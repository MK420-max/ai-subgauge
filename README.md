<div align="center">

**English** · [简体中文](README.zh-CN.md)

<img src="shared/brand/app-light-1024.png" alt="AI SubGauge logo" width="120">

# AI SubGauge

Your AI subscription quotas, at a glance in the macOS menu bar or Windows tray.

[![macOS](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#macos)
[![Windows](https://img.shields.io/badge/Windows-x64-0078D6?logo=windows&logoColor=white)](#windows)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Mac version](https://img.shields.io/badge/Mac-2.0.4%20%28build%20204%29-blue)](#macos)
[![Windows version](https://img.shields.io/badge/Windows-2.0.0-blue)](#windows)
[![GitHub stars](https://img.shields.io/github/stars/MK420-max/ai-subgauge?style=social)](https://github.com/MK420-max/ai-subgauge/stargazers)

[Features](#features) · [Installation](#installation) · [Privacy](#privacy--security) · [Build from source](#build-from-source)

</div>

Keep track of remaining quota, reset times and refresh errors without opening each provider's dashboard. On macOS, organize your menu bar icons in the same app.

<p align="center">
  <img src="docs/images/mac-menubar.png" alt="AI SubGauge in the macOS menu bar" width="900">
</p>
<p align="center">
  <img src="docs/images/mac-popup.png" alt="AI SubGauge macOS quota panel" width="460">
</p>

## Features

### On macOS

- **Quota at a glance.** Codex, Claude and Grok Bot subscriptions get individual menu bar icons with remaining-quota arcs. Hide percentages or place them above the arc or beside the icon.
- **Details when you need them.** Open a glass panel for remaining quota, reset times and refresh errors. Manage subscriptions and menu bar collection in one settings window.
- **A tidier menu bar.** Move icons into visible, collected and always-hidden zones; search, reorder, group and back up positions.
- **Optional API accounts.** Connect supported API services to see balances or usage where their official APIs provide it.

### On Windows 2.0

- **One quota ring per provider.** Codex, Claude and Grok Bot appear in the tray. The ring uses the five-hour allowance when available, otherwise the weekly allowance. Percentages are off by default and can be enabled in **Settings → AI subscriptions**.
- **Separate usage windows.** The panel has five-hour and weekly quota bars. Missing values, reset times and plans are explicitly marked as unavailable. Grok usually provides only weekly quota.
- **Useful during failures.** The last successful percentages and timestamps are cached in `last-good.json`, without credentials. Failed reads retain those values with a stale label, update time and error reason.
- **Grok renewal.** The official local CLI renews tokens in the background starting 30 minutes before expiry, with retries after temporary failures. A re-login action opens the official CLI login flow.
- **Native desktop controls.** Click a tray icon for details; right-click to refresh, open settings or quit. Supports high DPI and separate system theme detection for windows and the tray.

### On both platforms

- Refresh every five minutes, or refresh manually.
- Show selected providers while their apps or CLIs are running, with a 30-second grace period after exit. Enable **Always show** to keep them visible.
- Reuse existing local logins with separate consent for each provider; reuse is off by default.
- English and Simplified Chinese, light and dark themes, and launch-at-login controls.

### Providers and quota sources

| Provider | macOS | Windows 2.0 |
|---|---|---|
| Codex | ChatGPT subscription | Official Codex CLI `app-server` JSON-RPC; ChatGPT subscription login required |
| Claude | Claude Code OAuth | Claude Code OAuth; official usage API |
| Grok Bot | Official Grok CLI login | Official Grok CLI login; official billing API |
| Gemini, Kimi | API key | — |
| OpenAI API, Anthropic API, xAI API | API key | — |
| DeepSeek API, OpenRouter API, MiniMax API | API key | — |

API availability depends on the provider and plan. See the [macOS provider guide](mac/AI_SUPPORT.md). The [legacy Windows 1.x guide](windows/README.md) also documents Gemini, GitHub Copilot, Kimi Code and GLM / z.ai readers; the Windows 2.0 package described here focuses on Codex, Claude and Grok Bot.

## Installation

### macOS

**Mac 2.0.4 · build 204 · Apple Silicon**

> The deployment target supports **macOS 26.0 or later**. The app has **not been tested on real hardware running macOS 26**. Menu bar icon detection and collection still need verification on that system.

1. [Build the macOS app](#macos-build) from source.
2. Move `mac/dist/AI SubGauge.app` to `/Applications`.
3. Open the app. Builds are ad hoc signed and are not Developer ID signed or notarized; Gatekeeper may require approval.
4. Grant **Accessibility** permission to use menu bar icon organization. Other permissions are requested only for the optional features that need them.

The menu bar bridge uses private macOS APIs and may need updates after system changes. Enable **Settings → General → Launch at login** if desired.

Upgrading from Mac AI Bar Cleaner / mac-menu-bar-tidy? Quit the old app first. The first normal launch copies preferences and this app's API Keychain entries to the new identity, preserves old data and keeps existing new settings. See the [migration guide](mac/docs/MIGRATION.md).

### Windows

**Windows 2.0.0 · x64**

> **Windows 10 / 11 compatibility is inferred** from the project's `net8.0-windows` target and `win-x64` runtime. The app has **not been verified on every Windows version**. The self-contained package does not require a separate .NET installation.

Use either Windows 2.0 package:

- **Installer:** run `AISubGauge2-Setup-2.0.0.exe`. Add `/Q` for silent installation.
- **Portable archive:** extract `AISubGauge2-2.0.0-win-x64.zip`, then run this command from the extracted directory:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
  ```

No administrator rights are required. Installation creates a Start menu shortcut and enables startup by default through the current user's `Run` key. Change this in **Settings → General**.

| Item | Location |
|---|---|
| App | `%LOCALAPPDATA%\Programs\AISubGauge2\AISubGauge2.exe` |
| Settings | `%LOCALAPPDATA%\AISubGauge2\settings.json` |
| Log | `%LOCALAPPDATA%\AISubGauge2\logs\app.log` |

Version 2.0 can coexist with 1.x. Uninstall with the Start menu shortcut or `uninstall.ps1` in the installation directory; add `-KeepSettings` to retain settings. The older WindowsQuotaTray migration applies to the [legacy Windows app](windows/README.md#migration-from-windowsquotatray).

## Getting started

1. **Sign in through an official app or CLI.** Codex needs a ChatGPT subscription login; an API key does not qualify. Claude uses Claude Code OAuth. Grok uses the official Grok CLI login.
2. **Allow local login reuse per provider.** On macOS, use **Settings → General**. On Windows, answer the provider consent prompt or use **Local login consent** in the tray menu.
3. **Choose what to display.** Select providers and optionally enable **Always show**. Windows 2.0 checks running apps every two seconds; macOS checks every five seconds.
4. **Open the panel for details.** Check reset times, refresh manually or follow a login error back to the official login flow. On Windows, click outside the panel or press Esc to close it.

macOS shortcuts: `⇧⌘B` toggles the collection bar; `⇧⌘Space` searches icons.

Windows 2.0 reads Claude OAuth from `CLAUDE_CODE_OAUTH_TOKEN` or `%USERPROFILE%\.claude\.credentials.json`, and expects the signed-in Grok CLI at `%USERPROFILE%\.grok\bin\grok.exe`. Codex and Grok CLI signatures are checked before execution. Unsigned npm Codex is rejected by default; the Windows setting permits an explicit opt-in. MSIX / Store Codex is not discovered automatically; use `CODEX_EXE` to specify it, with signature verification still required.

## Screenshots and icon guide

These earlier interface previews were rendered offline with demo data: Codex 72%, Grok 45%, Claude 88%. They illustrate themes and layouts; they do not establish live account readings or Windows 2.0 visuals.

| | Light | Dark |
|---|---|---|
| **macOS** | <img src="docs/images/screenshots/mac-light-en.png" width="380" alt="macOS panel, light theme"> | <img src="docs/images/screenshots/mac-dark-en.png" width="380" alt="macOS panel, dark theme"> |
| **Windows** | <img src="docs/images/screenshots/win-light-en.png" width="380" alt="Earlier Windows panel, light theme"> | <img src="docs/images/screenshots/win-dark-en.png" width="380" alt="Earlier Windows panel, dark theme"> |

![macOS menu bar legend](docs/images/mac-menubar-legend.png)

The macOS menu bar shows a provider icon and remaining-quota arc. Percentages are optional; the panel adds reset times and error details.

![Earlier Windows tray legend](docs/images/windows-tray-legend.png)

The earlier Windows liquid-level icons shown here use 10% steps: green at 50% and above, transitioning through yellow to red at 15% and below. Grey means unknown or failed. Hover for exact values and errors; click for details. Windows 2.0 uses quota rings.

![English and Simplified Chinese interface comparison](docs/images/ui-en-vs-zh.png)

Earlier bilingual previews with demo data; the bottom row includes a Windows refresh error.

## Privacy & security

- **Local login access only.** Subscription readers use existing official CLI/OAuth login information on your machine, after consent. They do not read browser cookies or chat history. Optional macOS API accounts use keys you explicitly add to the system Keychain.
- **Credentials stay local.** Credentials never leave the machine except in requests to the relevant provider's official APIs. There is no credential upload service and no telemetry.
- **No sensitive logs.** Logs contain no tokens, cookies or response bodies. Windows 2.0 logs only time, provider, stage, failure category and HTTP status—not raw exceptions or paths. Diagnostics offer a redacted preview before export.
- **No prompts.** Quota checks read usage endpoints without sending model prompts or consuming inference quota.
- **Limited process detection.** Visibility checks read process names only, never command lines, executable paths or process memory.
- **Controlled renewal.** Login reads do not rewrite credentials. The official Grok CLI can update its own login during renewal; the app then restricts credential permissions. Insecure credential files are refused. Official CLI execution is subject to platform signature checks, with the explicit Windows npm opt-in described above.

Optional macOS weather requests send the configured city coordinates to Open-Meteo. See [macOS privacy](mac/PRIVACY.md), [macOS security](mac/docs/SECURITY.md) and [legacy Windows security](windows/docs/SECURITY.md) for details.

## Build from source

Keep `mac/`, `windows/` and `shared/` side by side.

### macOS build

Use Apple Silicon with Xcode command-line tools and a suitable macOS SDK. The project uses Swift tools 5.9, Swift 5 language mode and Swift Testing. From the repository root:

```sh
cd mac
swift test --sdk "$(xcrun --show-sdk-path)" --triple arm64-apple-macosx26.0
zsh build.sh
# Optional: create a disk image.
zsh package-dmg.sh
```

Outputs go to `mac/dist/`: `AI SubGauge.app`, `AI SubGauge.zip` and, if requested, a versioned arm64 DMG. Packaging does not install or launch the app. See the [macOS build guide](mac/README.en.md).

### Windows build

Use Windows, PowerShell and the .NET 8 SDK with Windows Desktop support. From the repository root, build the checked-in solution:

```powershell
cd windows
dotnet restore .\AISubGauge.sln --locked-mode
dotnet build .\AISubGauge.sln -c Release --no-restore
dotnet test .\tests\AISubGauge.Tests\AISubGauge.Tests.csproj -c Release --no-build
dotnet publish .\src\AISubGauge\AISubGauge.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o .\publish\win-x64
```

This checkout's `windows/` directory still contains the legacy solution, which produces `AISubGauge.exe`; see its [build guide](windows/README.md#build-test-and-install). The Windows 2.0 packaging source described in the installation instructions uses the following command and writes to `artifacts\`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Run that command from the Windows 2.0 source directory. Its `build.ps1` is not included in this checkout; the legacy solution commands above do not produce the 2.0 installer.

## Project structure

```text
mac/       Swift, SwiftUI and AppKit menu bar app
windows/   C# / .NET WinForms tray app and tests
shared/    Branding, provider icons, themes and translations
docs/      Screenshots and technical notes
```

## FAQ

**Why does a provider disappear?** Only running apps and CLIs are shown by default. Enable **Always show**, check provider selection and confirm local login consent.

**What do `—` and `⚠︎` mean?** A current value is unavailable or a refresh failed. Open the panel for the reason. Missing five-hour data stays unavailable; weekly quota remains in its own window.

**What happens when Windows cannot refresh?** Version 2.0 keeps the last successful reading with a stale label and timestamp. Earlier 1.x builds may show explicitly labelled demo data after a failed read.

**When does Grok ask me to sign in again?** Windows 2.0 offers re-login after an authentication failure, six consecutive renewal failures, or an expired token with a failed renewal. Click **Re-login** to run `grok.exe login`. A signature failure requires reinstalling the official CLI. Verification uses the local revocation cache; missing cache data can prevent verification. If signature verification stops responding, restart AI SubGauge.

**Where is the Windows tray icon?** Windows controls tray overflow placement. Move the icon out of the overflow area using Windows settings if needed.

## Contributing

Issues and pull requests are welcome. Include the app version, OS version and steps to reproduce; redact private information from screenshots and diagnostics. Run the relevant platform tests above before opening a pull request. Keep shared UI text in sync in `shared/i18n/en.json` and `shared/i18n/zh-Hans.json`.

## License

[MIT](LICENSE) · Copyright © 2026 Mike Kou.

Provider names and logos belong to their respective owners. See the [macOS third-party notices](mac/THIRD_PARTY_NOTICES.md) and [Windows guide](windows/README.md).

[![Star history chart](https://api.star-history.com/svg?repos=MK420-max/ai-subgauge&type=Date)](https://star-history.com/#MK420-max/ai-subgauge&Date)

If AI SubGauge makes your day a little easier, [give it a star](https://github.com/MK420-max/ai-subgauge) ⭐ — it helps others find the project. Thank you!
