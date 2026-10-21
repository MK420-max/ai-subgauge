<img src="../shared/brand/app-light-1024.png" width="96" alt="AI SubGauge">

# AI SubGauge for Windows

AI SubGauge shows the remaining quota of mainstream AI subscriptions in the Windows notification area. Each provider has its own tray icon. Version **1.2.0** uses C# / .NET 8 WinForms.

[简体中文](#简体中文)

## Features

- Codex, Claude, Grok Bot, Gemini, GitHub Copilot, Kimi Code and GLM / z.ai quota readers. Availability depends on the provider's login, plan and usage endpoint.
- One icon per provider, with a full-size logo and a liquid level rounded to 10% steps. Public builds use the Lobe Icons Grok logo with the standard liquid gauge; local builds with explicitly enabled private artwork use the head silhouette. Icons have no badges.
- A compact rounded panel matching Mac: Codex, Grok and Claude first, then Windows-only providers. Each row shows an official logo, remaining quota bar, percentage and reset countdown. Settings and Refresh use equal-width buttons.
- Refresh quota every five minutes. Show selected providers only while they are running, with a 30-second grace period and an Always show switch.
- English and Simplified Chinese UI, light/dark themes, separate permission for each provider, launch at login and diagnostics preview.
- A failed usage read falls back to explicitly labelled **Demo data**, with the cause in the panel and tooltip. A provider without consent is never queried. Providers not signed in locally show an unavailable value.

Cursor and Mistral remain unregistered placeholders. The app does not collect browser cookies or run model prompts.

## Show only running AI

`AlwaysShowAll` defaults to `false`. Every **5 seconds**, the app calls `Process.GetProcesses()` and reads only `ProcessName` (the image name without `.exe`). Matching is exact and case insensitive. Detection reads no command lines, executable paths or process memory.

If any mapped process is running, that provider can appear. When all matching processes disappear, the provider stays visible for **30 seconds** after the first absent sample. It returns on the next sample when a matching process reappears. Quota refresh stays at five minutes.

Final visibility is **selected providers ∩ (Always show enabled OR running / within the grace period)**. In **Show providers**, a missing or `null` entry uses the existing local-sign-in default; explicit `true`/`false` entries override that default. Checkmarks represent selection even when a process is absent. **Always show all selected providers** bypasses the running filter and still respects selection.

When no provider is visible, one monochrome **AI SubGauge** idle icon remains, without a quota value. Left-click or right-click it to open the menu, including provider selection, Always show, language, theme, launch at login, diagnostics and quit. The idle gauge-and-star asset is white on a dark taskbar and black on a light taskbar, selected independently of the panel theme. Offline demo mode continues to show all seven providers for reproducible examples.

The shared map is embedded from `../shared/running-processes.json`:

| Provider | Process aliases |
| --- | --- |
| codex | `codex`, `Codex`, `ChatGPT` |
| grok | `grok`, `Grok Bot`, `Grok` |
| claude | `claude`, `Claude` |
| gemini | `gemini` |
| copilot | `copilot`, `GitHub Copilot` |
| kimi | `kimi`, `Kimi` |
| glm | `glm`, `zai` |

To override the map, place a UTF-8 `running-processes.json` in `%LOCALAPPDATA%\AISubGauge`, beside `settings.json`, and restart. It uses the same flat object of provider IDs and string arrays on both platforms. A valid override replaces the whole map, so omitted providers do not match. An unreadable, invalid or oversized (over 1 MiB) override falls back to the embedded map.

For acceptance without credentials, network requests or UI:

```powershell
.\AISubGauge.exe --running-status
```

This prints one JSON object with a current boolean for each of the seven providers, for example `{"codex":true,"claude":false,"grok":false,"gemini":false,"copilot":false,"kimi":false,"glm":false}`. It reports raw process-name matches, independent of selection, consent, grace periods and Always show. It includes no PIDs, process names, paths, arguments or memory contents.

## Language

All application-authored UI copy, provider errors, demo labels and diagnostic preview text use the shared flat catalogs `../shared/i18n/en.json` and `zh-Hans.json`, embedded in the Windows assembly. The catalogs share keys with Mac; preserve existing keys when extending them.

By default, `zh*` system UI languages select Simplified Chinese; all others select English. Choose **Language → Follow system / English / 简体中文** in any tray menu. `settings.json` stores `Language` as `system`, `en` or `zh-Hans`. Existing settings without `Language` follow the system. **Restart AI SubGauge after changing the language.**

`--lang en|zh-Hans` overrides the language for that invocation without saving it. It works with `--screenshot` and `--render-preview` (and other command modes). Offline previews do not load user settings. Theme and language suffixes let all four panel previews share an output directory:

```powershell
.\AISubGauge.exe --render-preview .\comparison --theme light --lang en
.\AISubGauge.exe --render-preview .\comparison --theme dark --lang zh-Hans
.\AISubGauge.exe --screenshot .\screenshots --theme dark --lang en
.\AISubGauge.exe --screenshot .\screenshots --theme light --lang zh-Hans
python3 ..\shared\i18n\check-keys.py
```

The shared checker scans Mac and Windows source references and rejects missing keys, mismatched key sets, empty values and placeholder differences. The Windows unit tests also verify embedded catalogs and source references. Running-visibility tests cover 29/31-second boundaries, reappearance, selection, Always show and idle state; mapping tests cover case-insensitive matching, exact image names and overrides. `tests/render-checks.ps1` checks both export commands across all four theme/language combinations, including 440×350 panels, the quota color and idle image.

## Theme and app icon

**Settings → Theme → Follow system / Light / Dark** takes effect immediately. `settings.json` stores `Theme` as `system`, `light` or `dark`; a missing or invalid value follows the system. The panel, settings menu, application prompts and diagnostics use the single shared `../shared/theme.json`. Quota colors preserve the existing green/yellow/red interpolation.

System mode reads `AppsUseLightTheme`; the idle tray icon separately reads `SystemUsesLightTheme` under `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`. Changes are picked up by the existing two-second tray timer. The executable and windows use `../shared/brand/AISubGauge-light.ico`; the panel header uses the matching light/dark 1024px logo. Windows-owned window chrome and file dialogs follow Windows settings.

`--theme light|dark` overrides the theme for one invocation without saving it. Preview and screenshot commands use the system theme when the flag is absent.

## Build, test and install

Use Windows with the **.NET 8 SDK**. Building and rendering need Windows; the tray, screenshot and preview modes need an interactive desktop. A framework-dependent build also needs the .NET 8 Desktop Runtime.

Keep `windows/` and `shared/` as sibling directories. Logos, the process map and both language catalogs are embedded from `../shared`; relative to the project file this is `../../../shared`. The application has no third-party NuGet dependencies. Tests use xUnit and the Microsoft test SDK.

All three projects include Windows-generated `packages.lock.json` files. `Directory.Build.props` enables `RestorePackagesWithLockFile` and defaults `RestoreLockedMode` to `true`, so local and CI restores fail if dependencies differ from the locks. To update dependencies deliberately, run `dotnet restore .\AISubGauge.sln -p:RestoreLockedMode=false --force-evaluate` and review all lock-file changes. Keep locked mode enabled for normal builds and CI. See [SECURITY.md](docs/SECURITY.md).

From `windows/`, run:

```powershell
dotnet restore .\AISubGauge.sln --locked-mode
dotnet build .\AISubGauge.sln -c Release --no-restore
dotnet test .\tests\AISubGauge.Tests\AISubGauge.Tests.csproj -c Release --no-build
pwsh -File .\tests\security-checks.ps1 -AssemblyPath .\src\AISubGauge\bin\Release\net8.0-windows\AISubGauge.dll
pwsh -File .\tests\render-checks.ps1
dotnet publish .\src\AISubGauge\AISubGauge.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o .\publish\win-x64
```

Copy all published files to the Windows installation directory below, including the licenses. Start `AISubGauge.exe`. No administrator privileges are required.

| Platform | Version | Installation location |
| --- | --- | --- |
| Windows | 1.2.0 | `%LOCALAPPDATA%\Programs\AISubGauge\AISubGauge.exe` |
| Mac | 1.2.0 | `/Applications/AI SubGauge.app` |

This change was authored on macOS without compiling or executing .NET. Windows build, test and visual acceptance remain to be run. Tests use synthetic credentials and isolated registry subkeys, never the real `AISubGauge` Run value. The test project publishes the fake Grok CLI and the `AppHost/AISubGauge.exe` self-test host as complete `win-x64` self-contained directories. Both include their own runtime, so a user-local .NET installation and missing `DOTNET_ROOT` do not break direct subprocess launches. The production environment allowlist is unchanged.

## Migration from WindowsQuotaTray

The solution, project, assembly, executable, root namespace and single-instance mutex are now `AISubGauge`. The display name is `AI SubGauge`.

On first load, if `%LOCALAPPDATA%\AISubGauge\settings.json` is absent and `%LOCALAPPDATA%\WindowsQuotaTray\settings.json` exists, the app copies the old settings. The old file remains unchanged. `ProviderVisibility` still works: missing or `null` means automatic, `true` selects the provider, and `false` deselects it. The running filter is applied after selection. Existing new settings take precedence.

Migration preserves visibility without granting access to local login information. A missing `ProviderConsent` entry means access is not authorized and remains pending for the existing per-provider prompt. Existing `true/false` entries in current settings are preserved. Both migrated users and new installations are prompted for each detected provider:

> Allow AI SubGauge to read &lt;provider&gt;'s local login information?

`ProviderConsent` records each answer. Use **Local login consent** in the tray menu to allow a provider or revoke its permission. No credential contents are read before permission; detection checks file availability or the presence of a supported environment variable. `--status`, `--screenshot` and `--preview-icons` never prompt. Unpermitted providers have `consent: false` in status reports.

Credentials stay in each provider's original location. The app does not migrate or copy real credential files.

For tests and checks, `AISUBGAUGE_SETTINGS_DIR` overrides the entire settings directory and must be an absolute local path. Relative paths, UNC paths and network drives are refused. Both PowerShell check scripts and AppHost tests inject temporary directories. Normal `--status` reads settings without migrating them. `--demo` never loads, migrates or saves user settings; `--demo --status` also skips login detection.

## Launch at login

Normal first launch treats `LaunchAtLogin: null` as enabled, writes the preference and registers:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
AISubGauge = "<absolute current executable path>"
```

Toggle **Launch at login** in the right-click menu, or use the headless commands:

```powershell
.\AISubGauge.exe --autostart on
.\AISubGauge.exe --autostart off
.\AISubGauge.exe --autostart status
```

A successful command exits with `0` and prints JSON, for example:

```json
{"enabled":true,"command":"\"C:\\Users\\Example\\AppData\\Local\\Programs\\AISubGauge\\AISubGauge.exe\"","legacyRemoved":false}
```

Normal startup and explicit `on` migrate a `WindowsQuotaTray` value only when it names an absolute `WindowsQuotaTray.exe` command without extra arguments. Registration requires a protected installation in `%LOCALAPPDATA%\Programs\AISubGauge`; the executable and every ancestor are checked. If registration fails, recognized old startup commands are removed so an unprotected copy cannot remain active at login. Cleanup checks only the `AISubGauge` and `WindowsQuotaTray` value names and matching application executable commands; unrelated values and commands are preserved. `legacyRemoved` reports removal during this invocation. `status` only reads the current state. Explicit `on` and `off` also save `LaunchAtLogin`. Normal launches reapply that preference using the current executable path.

## Local logins and quota sources

| Provider | Credential source | Quota source |
| --- | --- | --- |
| Codex | Existing `%CODEX_HOME%\auth.json`, otherwise `%USERPROFILE%\.codex\auth.json`; `OPENAI_API_KEY` cannot replace a missing file | Official Codex CLI App Server, ChatGPT subscription login required |
| Claude | `CLAUDE_CODE_OAUTH_TOKEN`, otherwise `%USERPROFILE%\.claude\.credentials.json` | `api.anthropic.com/api/oauth/usage` |
| Grok Bot | `GROK_AUTH_PATH`, then `%GROK_HOME%\auth.json`, then `%USERPROFILE%\.grok\auth.json` | `cli-chat-proxy.grok.com/v1/billing?format=credits`; same-account Grok Bot usage cache when official credentials are absent or have no matching scope |
| Gemini | `%USERPROFILE%\.gemini\oauth_creds.json` | Google Code Assist load/quota endpoints |
| GitHub Copilot | `COPILOT_GITHUB_TOKEN`, otherwise `%LOCALAPPDATA%\github-copilot\apps.json` / `hosts.json` | GitHub Copilot account quota |
| Kimi Code | `KIMI_CODE_API_KEY`, otherwise `%USERPROFILE%\.kimi-code\credentials\kimi-code.json` | `api.kimi.com/coding/v1/usages` |
| GLM / z.ai | `Z_AI_API_KEY` or the supported GLM/Zhipu environment variables | Region-specific official quota endpoint; keys are never retried in another region |

Provider endpoints and their schemas can change. API keys do not necessarily provide subscription quota. Other than Grok renewal described below, the app does not refresh credentials.

## Codex executable verification

Codex reuses only an existing `auth.json` that passes validation. If the file or credential directory is missing, the app treats Codex as not signed in locally, even when `OPENAI_API_KEY` is set. It does not start the CLI or create credentials or directories. Run `codex login` in the official Codex CLI and sign in with a ChatGPT account first.

The app creates the CLI suspended and resumes it only after assigning it to a Windows Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` enabled. Credential and directory handles remain locked until cleanup terminates the job and `QueryInformationJobObject` confirms zero active processes, including children whose parent has exited. If the foreground wait times out or fails, background cleanup retains the job and all locks until that confirmation. See [SECURITY.md](docs/SECURITY.md).

Codex discovery checks only `%LOCALAPPDATA%\OpenAI\Codex\bin\**\codex.exe` (including hash subdirectories) and codex.exe files under `%APPDATA%\npm\node_modules\@openai\codex`. It does not search PATH. `CODEX_EXE` may specify an absolute local .exe, but it must pass the same Authenticode, Code Signing EKU, Online revocation chain and exact publisher checks. O and CN must both equal the same allowed name. The current names are `OpenAI, L.L.C.` and `OpenAI OpCo, LLC`, centralized in `Providers/Authenticode.cs`. Unsigned local builds are refused. `--codex-signer` prints only the discovered candidates' signature status and Subject; it does not execute them or read credentials. Use the output from a Windows machine to review and adjust the constants.

```powershell
.\AISubGauge.exe --codex-signer
```

## Grok token renewal and executable verification

An expiring Grok OIDC credential with a refresh token uses the official CLI's ACP flow: `grok.exe agent stdio`, `initialize`, then `_x.ai/auth/getBearerToken`. The returned bearer is discarded. Only the official CLI writes `auth.json`; AI SubGauge rereads the store and checks the user ID, client ID, issuer, scope and expiry again.

The CLI must be `%USERPROFILE%\.grok\bin\grok.exe`, or an absolute local `.exe` specified by `GROK_CLI_PATH`. There is no PATH search or shell fallback. Relative paths, UNC/device paths, network drives, `.cmd` files and reparse points in any component are rejected. The executable is held open against replacement during verification and execution.

Before execution, [WinVerifyTrust](https://learn.microsoft.com/en-us/windows/win32/api/wintrust/nf-wintrust-winverifytrust) must accept the Authenticode signature. AI SubGauge parses the Subject of the signer certificate verified by WinVerifyTrust; both O and CN must equal `X.AI LLC` using case-sensitive exact comparisons. Allowed publishers are centralized in `Providers/Authenticode.cs`. The certificate must explicitly include the Code Signing EKU and pass X509Chain building with Online revocation checks, excluding the root. Verification may contact certificate-authority servers. Failed verification prevents execution.

To check a newly downloaded official CLI independently, use:

```powershell
Get-AuthenticodeSignature -LiteralPath "$env:USERPROFILE\.grok\bin\grok.exe" | Format-List Status,StatusMessage,SignerCertificate
```

Confirm `Status` is `Valid`, inspect `SignerCertificate.Subject` and verify the publisher through the official distributor. If the actual publisher differs, maintainers must review that evidence and change the central constants before rebuilding. Production has no signature bypass switch.

The child environment is cleared and contains only these names when present: `SystemRoot`, `windir`, `TEMP`, `TMP`, `USERPROFILE`, `HOME`, `LOCALAPPDATA`, `APPDATA`, `PATH`, `GROK_HOME`, `GROK_AUTH_PATH`, `ComSpec`, `PATHEXT`, `PROCESSOR_ARCHITECTURE`. `GROK_HOME` points to a private temporary working directory and `GROK_AUTH_PATH` to the selected official store. `GROK_LOG_FILE=NUL` and `RUST_LOG=off` are always set, overriding inherited values. Other providers' tokens and all test-control variables are excluded. Both renewal and self-test working directories are created with a protected owner-only DACL so they do not inherit other users' Modify permissions from `%TEMP%`.

Stdout is capped at 1 MiB in total, stderr is drained without retention, and the protocol has a 20-second timeout. The process tree is killed after use, with at most two seconds for exit and one second for stderr cleanup. A renewed credential must belong to the same user and client. Before rereading, the app checks that only the current user, SYSTEM and Administrators have sensitive access. If the CLI widened access, AI SubGauge restricts the DACL to the current user. **This DACL repair is the only modification AI SubGauge may make to an actual credential file.** It never changes its contents or owner.

Failure appears as `Grok token renewal failed: <reason>` in the panel and tooltip, with labelled demo data. No bearer, refresh token, raw CLI message or raw exception is included in application logs, status or UI. The app does not write runtime logs. Private CLI working directories and synthetic test fixtures are retained under the Windows temporary directory; no real auth store is copied there.

To run the isolated test hook after building:

```powershell
$env:AISUBGAUGE_TEST_GROK_CLI = (Resolve-Path .\tests\AISubGauge.Tests\bin\Release\net8.0-windows\FakeGrokCli\FakeGrokCli.exe).Path
.\src\AISubGauge\bin\Release\net8.0-windows\AISubGauge.exe --selftest-grok-refresh
```

This mode alone accepts the test override and bypasses signature checks. It creates a private temporary `GROK_HOME` with synthetic expired credentials and outputs only `{success,error}`. It never uses real credentials. Optional `AISUBGAUGE_TEST_GROK_MODE` selects fixture cases such as `failure`, `wrong-user`, `wrong-client`, `still-expired`, `wide-acl`, `oversize`, `early-exit` or `timeout`. These variables have no effect in normal, status or screenshot modes.

Locations selected by `GROK_HOME`/`GROK_AUTH_PATH` must also pass the ACL checks. Leftover test variables may redirect reads to a test directory under `%TEMP%`.

## Privacy and diagnostics

Each permitted provider reads only its supported credential source. File access accepts bounded local ordinary files, rejects links and checks the opened handle. Every provider requires current-user ownership and a restricted DACL; NULL DACLs and unexpected principals with data read, write, delete or permission/ownership-change access are refused before any contents are read. SYSTEM and Administrators are trusted management principals. For example, sensitive access granted to Everyone, Users or Authenticated Users is refused:

> Other users can read the credential file. Reading refused; restrict permissions.

Only Codex credential validation for the default `%USERPROFILE%\.codex\auth.json` can enable the sandbox-group exception. The call site explicitly passes `CredentialKind.Codex` and the same resolved `CredentialFiles.CodexPath` used to open the file. After strict local absolute-path validation, normalization and removal of trailing separators, the path must match the default path exactly, ignoring case. Files under a different `CODEX_HOME` retain strict validation. The app checks the machine role before querying the account-domain SID. It refuses the exception on BackupDC or PrimaryDC, for unknown roles, or if the role query fails. The group ACE's SID domain must equal the local machine account-domain SID, and `LookupAccountSidW` must resolve it to a local Alias or Group named `CodexSandboxUsers`. The complete member list, enumerated by SID, must resolve to exactly `CodexSandboxOffline` and `CodexSandboxOnline`, both User accounts in that same local account domain.

The only permitted access bits are `ReadData`, `ReadExtendedAttributes`, `ReadAttributes`, `ReadPermissions`, `ExecuteFile`, `Synchronize` and `GENERIC_READ`/`GENERIC_EXECUTE`. Inherited read-only ACEs are also accepted. Any additional bit (including write, delete, permission/ownership changes, `GENERIC_WRITE` and `GENERIC_ALL`), identity mismatch or query failure is rejected. Other providers, including Grok, retain their existing checks. This exception never modifies Codex file permissions. Residual risk: these two sandbox accounts can read Codex tokens as part of Codex's own Windows sandbox design. See [SECURITY.md](docs/SECURITY.md) for the conditions and test details.

Only Grok's post-renewal DACL repair may modify credential permissions; other providers' ACLs are never modified. HTTP readers use fixed official HTTPS endpoints, disable cookies and redirects, and bound response sizes and timeouts. The app does not read browser cookies, localStorage or chat history. CLI internals remain controlled by their official vendors.

**Export diagnostics…** builds text containing version, OS and current provider states/errors. Before display, it redacts token-shaped strings, email addresses, `C:\Users\<name>` and the machine name. Review the preview, then click **Save** to write a new file. Closing the preview writes nothing. Existing files, credential targets and linked paths are refused. Settings store visibility, Always show, language, theme, permission and autostart preferences, never tokens.

## Status and image exports

```powershell
.\AISubGauge.exe --status
.\AISubGauge.exe --status .\status.json
.\AISubGauge.exe --demo
.\AISubGauge.exe --screenshot .\screenshots
.\AISubGauge.exe --demo --screenshot .\demo-screenshots
.\AISubGauge.exe --preview-icons .\icon-previews
.\AISubGauge.exe --render-preview .\comparison
```

`--status` is headless. It reports all seven providers, including consent and demo/stale/error state. Demo values are never reported as real remaining quota. A new output file is required; existing files are preserved.

`--screenshot` and `--render-preview` both render fixed offline data: Codex **72%** (3h 20m), Grok **45%** (1d 0h), Claude **88%** (5d 0h), in the same order and dimensions as the Mac preview. Neither mode loads user settings, detects logins, reads credentials, calls providers, creates tray icons or captures other applications. `--demo` is optional for screenshots.

Use `--theme light|dark` with `--lang en|zh-Hans`. The panel is written to the requested directory as **`win-panel-{light|dark}-{en|zh-Hans}.png`**, at 440×350 pixels with transparent rounded corners. Companion files use the same suffix: `win-error-…` (a synthetic Grok renewal failure), `win-tray-…` (three 24px icons enlarged 4×) and `win-idle-…` (24px enlarged 8×). `--screenshot` also exports the three providers' individual icons at 16/20/24/32px. Both commands use the fixed Mac preview clock so the reset countdowns are reproducible.

`--preview-icons` remains offline and preserves the detailed liquid-icon size grid. Image exports replace same-named images in the requested directory.

Export/test modes are mutually exclusive and bypass the single-instance mutex. Invalid arguments return `2`; command/output failures return `1`; successful reports return `0` even if a provider failed. The self-test also returns `0` for a completed test with `success: false`; inspect its JSON result.

## License and trademarks

Application code is licensed under the [MIT License](LICENSE). Distribution includes that license and the Lobe Icons license.

Shared brand assets are documented in [shared/README.md](../shared/README.md). Lobe Icons are MIT-licensed. Public builds use the Lobe Icons Grok logo with the standard liquid gauge. The Grok Bot app extractions `grokbot.png` and `grokbot-head.png` are excluded from the open-source distribution and moved to `shared/private-logos/`, which is ignored by .gitignore; the old Windows copies are in its `windows/` subdirectory. Public builds exclude private artwork even when it exists locally. For a local private build, provide `shared/private-logos/grokbot-head.png` and explicitly add `-p:IncludePrivateLogos=true` to `dotnet build` or `dotnet publish` (for example, `dotnet build .\src\AISubGauge\AISubGauge.csproj -c Release -p:IncludePrivateLogos=true` from `windows/`). Only when the property is `true` and the file exists does the csproj embed it and define `PRIVATE_GROK_LOGO` to retain the head-mask gauge. Otherwise it uses `shared/logos/grok.png`. Tests support both builds. Redistribution permission for the private artwork has not been confirmed. Brand names and logos belong to their respective owners; their use identifies services and does not imply endorsement, sponsorship or affiliation.

The remaining `windows/assets/logos` files are historical copies; public provider icons are embedded from `shared/logos`. `PROMPT.md` and `PROMPT2.md` are historical development notes, not current requirements.

If AI SubGauge is useful to you, please consider giving the repository a star. Thank you.

# 简体中文

AI SubGauge 在 Windows 通知区域显示主流 AI 订阅的剩余额度，每家服务商使用一个托盘图标。当前版本为 **1.2.0**，基于 C# / .NET 8 WinForms。

## 功能

- 支持 Codex、Claude、Grok Bot、Gemini、GitHub Copilot、Kimi Code 和 GLM / z.ai。能否读取额度取决于登录状态、套餐和服务商接口。
- 每家一个图标，品牌标志占满图标，液面按 10% 一档取整。公开版使用 Lobe Icons 的 Grok 图标与普通液位；本地显式启用私有素材时使用头像蒙版。所有图标均不带角标。
- 紧凑圆角面板与 Mac 一致：先显示 Codex、Grok、Claude，再显示 Windows 专属服务商。每行显示官方 logo、剩余进度条、百分比和重置倒计时；底部为等宽的“设置”和“刷新”按钮。
- 额度每五分钟刷新。默认只显示已选且正在运行的服务商，进程消失后保留 30 秒；也可开启“始终显示”。
- 提供英文、简体中文界面、浅色／深色主题、逐家登录授权、开机自启和诊断预览。
- 读取额度失败时，显示明确标注的**演示数据**，并在面板和提示中说明原因。未经授权不会查询该服务商；本机未登录时显示不可用值。

Cursor 和 Mistral 仍为未注册的占位实现。应用不收集浏览器 Cookie，也不发送模型提示词。

## 只显示正在运行的 AI

`AlwaysShowAll` 默认为 `false`。应用每 **5 秒**调用一次 `Process.GetProcesses()`，只读取 `ProcessName`，即不带 `.exe` 的映像名。匹配要求全名相同，不区分大小写。运行检测不读取命令行、可执行文件路径或进程内存。

某家任意一个映射进程正在运行，即可显示该家。全部匹配进程消失后，从首次检测到全部消失的时刻起再保留 **30 秒**。进程重新出现时，在下一次采样中恢复显示。额度刷新仍保持五分钟一次。

最终可见集合为：**已选服务商 ∩（开启始终显示，或正在运行／仍在宽限期内）**。“显示哪几家”中，未设置或为 `null` 时沿用本机登录的自动规则，明确的 `true`／`false` 覆盖该默认选择。即使进程未运行，勾选状态仍反映用户选择。“始终显示所有已选服务商”只跳过运行状态筛选，仍保留服务商勾选限制。

一家都不可见时，保留一个单色的 **AI SubGauge** 空闲图标，不显示额度。左键或右键点击都可打开菜单，设置服务商、始终显示、语言、主题和开机自启，也可导出诊断或退出。空闲图标使用仪表弧与星形素材，深色任务栏用白色，浅色任务栏用黑色，与面板主题独立。离线演示模式继续显示全部七家，便于复现示例。

构建时嵌入 `../shared/running-processes.json`，默认映射如下：

| 服务商 | 进程别名 |
| --- | --- |
| codex | `codex`、`Codex`、`ChatGPT` |
| grok | `grok`、`Grok Bot`、`Grok` |
| claude | `claude`、`Claude` |
| gemini | `gemini` |
| copilot | `copilot`、`GitHub Copilot` |
| kimi | `kimi`、`Kimi` |
| glm | `glm`、`zai` |

如需覆盖，在 `%LOCALAPPDATA%\AISubGauge` 中、`settings.json` 旁边放置 UTF-8 编码的 `running-processes.json`，然后重启。两端格式相同：以服务商 ID 为键、字符串数组为值的扁平 JSON 对象。有效覆盖文件替换整份映射，省略的服务商不会匹配。文件不可读、格式无效或超过 1 MiB 时，回退到内嵌映射。

以下验收命令不读取凭据、不发网络请求，也不开界面：

```powershell
.\AISubGauge.exe --running-status
```

命令输出一个 JSON 对象，用布尔值表示七家当前是否匹配到运行进程，例如：

```json
{"codex":true,"claude":false,"grok":false,"gemini":false,"copilot":false,"kimi":false,"glm":false}
```

该结果只反映当前进程名匹配，不受勾选、授权、宽限期或始终显示设置影响。输出不含 PID、进程名、路径、参数或内存内容。

## 界面语言

应用自带的界面文案、服务商错误、演示标签和诊断预览都引用共享扁平语言文件 `../shared/i18n/en.json`、`zh-Hans.json`，并嵌入 Windows 程序集。两端共用键名；扩展时须保留已有键。

默认跟随系统界面语言：`zh*` 使用简体中文，其余使用英文。可在任一托盘菜单的“语言”中选择“跟随系统／English／简体中文”。`settings.json` 的 `Language` 值为 `system`、`en` 或 `zh-Hans`。旧设置缺少 `Language` 时按跟随系统处理。**修改语言后需重启 AI SubGauge。**

`--lang en|zh-Hans` 仅覆盖本次运行的语言，不保存设置，可用于 `--screenshot`、`--render-preview` 及其他命令模式。离线预览不加载用户设置。文件名带主题和语言后缀，四种组合可输出到同一目录：

```powershell
.\AISubGauge.exe --render-preview .\comparison --theme light --lang en
.\AISubGauge.exe --render-preview .\comparison --theme dark --lang zh-Hans
.\AISubGauge.exe --screenshot .\screenshots --theme dark --lang en
.\AISubGauge.exe --screenshot .\screenshots --theme light --lang zh-Hans
python3 ..\shared\i18n\check-keys.py
```

共享检查脚本扫描 Mac 和 Windows 的源码引用，检查引用键存在、两份文件键集合相同、值非空、占位符一致。Windows 单元测试也检查内嵌语言文件和源码引用。运行可见性测试覆盖 29／31 秒边界、重新出现、勾选叠加、始终显示和空闲状态；映射测试覆盖大小写、映像名全匹配及覆盖文件。`tests/render-checks.ps1` 检查两个导出命令的四种主题／语言组合，包括 440×350 面板、额度颜色和空闲图标。

## 主题与应用图标

在“设置 → 主题”中选择“跟随系统／浅色／深色”，即时生效。`settings.json` 的 `Theme` 值为 `system`、`light` 或 `dark`；缺少字段或值无效时跟随系统。面板、设置菜单、应用提示和诊断预览共用 `../shared/theme.json`；额度颜色保留现有绿黄红插值规则。

跟随系统读取 `AppsUseLightTheme`，空闲托盘图标独立读取 `SystemUsesLightTheme`，位置为 `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`。沿用现有两秒托盘计时器响应变化。exe 和窗口使用 `../shared/brand/AISubGauge-light.ico`，面板标题栏按主题使用对应的 1024px logo。Windows 自带窗口边框和文件选择器跟随 Windows 设置。

`--theme light|dark` 只覆盖本次运行，不保存设置。预览和截图未指定该参数时使用系统主题。

## 构建、测试与安装

请在 Windows 上使用 **.NET 8 SDK**。编译和渲染需要 Windows，托盘、截图及预览还需要交互式桌面。依赖框架的构建另需 .NET 8 Desktop Runtime。

`windows/` 与 `shared/` 须位于同一父目录。品牌图标、进程映射及两份语言文件均从 `../shared` 嵌入；相对项目文件的路径为 `../../../shared`。应用无第三方 NuGet 依赖，测试使用 xUnit 和 Microsoft 测试 SDK。

三个项目均包含 Windows 生成的 `packages.lock.json`。`Directory.Build.props` 启用 `RestorePackagesWithLockFile`，并将 `RestoreLockedMode` 默认设为 `true`；本地和 CI 恢复时，依赖与锁文件不一致即失败。只有有意更新依赖时才执行 `dotnet restore .\AISubGauge.sln -p:RestoreLockedMode=false --force-evaluate`，并审阅全部锁文件差异。正常构建和 CI 保持锁定模式，详见 [SECURITY.md](docs/SECURITY.md)。

在 `windows/` 中执行：

```powershell
dotnet restore .\AISubGauge.sln --locked-mode
dotnet build .\AISubGauge.sln -c Release --no-restore
dotnet test .\tests\AISubGauge.Tests\AISubGauge.Tests.csproj -c Release --no-build
pwsh -File .\tests\security-checks.ps1 -AssemblyPath .\src\AISubGauge\bin\Release\net8.0-windows\AISubGauge.dll
pwsh -File .\tests\render-checks.ps1
dotnet publish .\src\AISubGauge\AISubGauge.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o .\publish\win-x64
```

将全部发布文件及许可证复制到下方 Windows 安装目录，启动 `AISubGauge.exe`。无需管理员权限。

| 平台 | 版本 | 安装位置 |
| --- | --- | --- |
| Windows | 1.2.0 | `%LOCALAPPDATA%\Programs\AISubGauge\AISubGauge.exe` |
| Mac | 1.2.0 | `/Applications/AI SubGauge.app` |

本次改动在 macOS 上编写，未编译或执行 .NET。Windows 编译、测试和视觉验收仍需执行。测试使用合成凭据及独立注册表子键，不操作真实的 `AISubGauge` Run 值。测试项目将假 Grok CLI 与 `AppHost/AISubGauge.exe` 自测宿主发布成完整的 `win-x64` 自包含目录。两者均自带运行时，用户本地安装 .NET 且缺少 `DOTNET_ROOT` 时，也能直接作为子进程运行。生产环境白名单保持不变。

## 从 WindowsQuotaTray 迁移

解决方案、项目、程序集、可执行文件、根命名空间和单实例互斥体均已更名为 `AISubGauge`，显示名称为 `AI SubGauge`。

首次加载时，若 `%LOCALAPPDATA%\AISubGauge\settings.json` 不存在而 `%LOCALAPPDATA%\WindowsQuotaTray\settings.json` 存在，则复制旧设置，保留旧文件。`ProviderVisibility` 继续生效：未设置或为 `null` 表示自动，`true` 表示选中，`false` 表示取消选中，然后叠加运行状态筛选。已有新设置优先。

迁移保留可见性，但不会据此授予读取登录信息的权限。缺少 `ProviderConsent` 记录表示未授权，仍由现有逐家询问流程处理；新版设置中已有的 `true／false` 原样保留。迁移用户与新安装用户都会逐家询问检测到的服务商：

> 是否允许 AI SubGauge 读取 &lt;家&gt; 的本机登录信息？

`ProviderConsent` 记录各家选择，可通过“本机登录授权”允许或撤销读取。授权前不读取凭据内容；登录检测仅检查文件可用性或受支持环境变量是否存在。`--status`、`--screenshot`、`--preview-icons` 不弹出授权询问。未授权的服务商在状态报告中为 `consent: false`。

凭据保留在各服务商原来的位置，应用不迁移或复制真实凭据文件。

测试／检查可通过 `AISUBGAUGE_SETTINGS_DIR` 覆盖整个设置目录，值必须为本机绝对路径；相对路径、UNC 与网络盘均被拒绝。两个 PowerShell 检查脚本及 AppHost 测试均注入临时目录。普通 `--status` 只读设置且不迁移；`--demo` 完全不加载、迁移或保存用户设置，`--demo --status` 也不检测登录。

## 开机自启动

正常首次启动将 `LaunchAtLogin: null` 视为启用，保存偏好并注册：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
AISubGauge = "<absolute current executable path>"
```

可在右键菜单切换开机自启，或执行无界面命令：

```powershell
.\AISubGauge.exe --autostart on
.\AISubGauge.exe --autostart off
.\AISubGauge.exe --autostart status
```

成功时退出码为 `0`，输出示例：

```json
{"enabled":true,"command":"\"C:\\Users\\Example\\AppData\\Local\\Programs\\AISubGauge\\AISubGauge.exe\"","legacyRemoved":false}
```

正常启动和明确的 `on` 会迁移旧 `WindowsQuotaTray` 值，前提是其命令为绝对路径的 `WindowsQuotaTray.exe`，且没有附加参数。登记要求程序位于受保护的 `%LOCALAPPDATA%\Programs\AISubGauge`，并检查可执行文件及全部祖先。登记失败时仍移除本程序认得的旧启动命令，防止不受保护的副本继续开机运行；只检查 `AISubGauge`、`WindowsQuotaTray` 两个值名及匹配的本程序 exe 命令，无关值和命令保持原样。`legacyRemoved` 表示本次是否移除了旧值。`status` 只读取当前状态；明确的 `on`／`off` 同时保存 `LaunchAtLogin`。正常启动会以当前程序路径重新应用该偏好。

## 本机登录与额度来源

| 服务商 | 凭据来源 | 额度来源 |
| --- | --- | --- |
| Codex | 已存在的 `%CODEX_HOME%\auth.json`，否则 `%USERPROFILE%\.codex\auth.json`；`OPENAI_API_KEY` 不能替代缺失的文件 | 官方 Codex CLI App Server，须使用 ChatGPT 订阅账号登录 |
| Claude | `CLAUDE_CODE_OAUTH_TOKEN`，否则 `%USERPROFILE%\.claude\.credentials.json` | `api.anthropic.com/api/oauth/usage` |
| Grok Bot | 依次检查 `GROK_AUTH_PATH`、`%GROK_HOME%\auth.json`、`%USERPROFILE%\.grok\auth.json` | `cli-chat-proxy.grok.com/v1/billing?format=credits`；无官方凭据或 scope 不匹配时使用同账户 Grok Bot 用量缓存 |
| Gemini | `%USERPROFILE%\.gemini\oauth_creds.json` | Google Code Assist 加载／额度接口 |
| GitHub Copilot | `COPILOT_GITHUB_TOKEN`，否则 `%LOCALAPPDATA%\github-copilot\apps.json`／`hosts.json` | GitHub Copilot 账号额度 |
| Kimi Code | `KIMI_CODE_API_KEY`，否则 `%USERPROFILE%\.kimi-code\credentials\kimi-code.json` | `api.kimi.com/coding/v1/usages` |
| GLM / z.ai | `Z_AI_API_KEY` 或支持的 GLM／智谱环境变量 | 对应地区的官方额度接口；不会拿同一密钥重试另一区域 |

服务商接口及数据格式可能变化。API Key 不一定能读取订阅额度。除下述 Grok 续期外，应用不刷新凭据。

## Codex 可执行文件验证

Codex 仅复用已存在并通过校验的 `auth.json`。文件或凭据目录缺失时，即使设置 `OPENAI_API_KEY`，也视为本机未登录，不启动 CLI、不创建凭据或目录。请先使用官方 `codex login`，并选择 ChatGPT 账号登录。

应用以挂起状态创建 CLI，加入启用 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Windows Job Object 后才恢复执行。清理时终止整个作业，只有 `QueryInformationJobObject` 确认活动进程数为 0 后，才释放凭据及目录句柄；父进程先退出的子进程也必须退出。前台等待超时或失败时，后台清理继续持有作业及所有锁，直到确认清空。详见 [SECURITY.md](docs/SECURITY.md)。

Codex 只从 `%LOCALAPPDATA%\OpenAI\Codex\bin\**\codex.exe`（包括哈希子目录）与 `%APPDATA%\npm\node_modules\@openai\codex` 下的 codex.exe 查找，不搜索 PATH。`CODEX_EXE` 可指定本机绝对 .exe 路径，但同样必须通过 Authenticode、Code Signing EKU、Online 吊销证书链及发布者精确检查；O 与 CN 须同时等于同一允许名称。当前允许名称为 `OpenAI, L.L.C.` 和 `OpenAI OpCo, LLC`，集中定义于 `Providers/Authenticode.cs`。未签名的本地版本会被拒绝。`--codex-signer` 只输出所找到候选程序的签名状态和 Subject，不执行程序或读取凭据；可在真机核对后审阅并调整常量。

```powershell
.\AISubGauge.exe --codex-signer
```

## Grok 令牌续期与可执行文件验证

即将过期且包含 refresh token 的 Grok OIDC 凭据使用官方 CLI 的 ACP 流程：执行 `grok.exe agent stdio`，依次调用 `initialize` 和 `_x.ai/auth/getBearerToken`。返回的 bearer 会被丢弃。仅官方 CLI 写入 `auth.json`，AI SubGauge 重新读取后再次检查用户 ID、客户端 ID、issuer、scope 和有效期。

CLI 必须为 `%USERPROFILE%\.grok\bin\grok.exe`，或由 `GROK_CLI_PATH` 指定的本机绝对 `.exe` 路径。不会搜索 PATH，也没有 shell 回退。相对路径、UNC／设备路径、网络盘、`.cmd` 及任一路径组件中的重解析点均被拒绝。验证和运行期间保持文件打开，防止替换。

运行前须通过 [WinVerifyTrust](https://learn.microsoft.com/en-us/windows/win32/api/wintrust/nf-wintrust-winverifytrust) 的 Authenticode 验证，并从其实际验证的签名者证书解析 Subject；O 与 CN 均须按大小写敏感的精确比较等于 `X.AI LLC`。允许的发布者集中定义于 `Providers/Authenticode.cs`。证书必须包含 Code Signing EKU，且通过 X509Chain 的 Online 吊销检查与证书链构建；根证书不做吊销检查。验证可能连接证书机构的服务器，验证失败即拒绝运行。

可独立检查新下载的官方 CLI：

```powershell
Get-AuthenticodeSignature -LiteralPath "$env:USERPROFILE\.grok\bin\grok.exe" | Format-List Status,StatusMessage,SignerCertificate
```

确认 `Status` 为 `Valid`，检查 `SignerCertificate.Subject`，并通过官方分发渠道核实发布者。实际发布者不匹配时，维护者须审核证据、修改集中常量后重新构建。正式模式没有跳过签名的开关。

子进程环境清空后，仅在原来存在时保留这些名称：`SystemRoot`、`windir`、`TEMP`、`TMP`、`USERPROFILE`、`HOME`、`LOCALAPPDATA`、`APPDATA`、`PATH`、`GROK_HOME`、`GROK_AUTH_PATH`、`ComSpec`、`PATHEXT`、`PROCESSOR_ARCHITECTURE`。`GROK_HOME` 指向私有临时工作目录，`GROK_AUTH_PATH` 指向选定的官方凭据存储。始终强制 `GROK_LOG_FILE=NUL`、`RUST_LOG=off`，覆盖继承值。其他服务商的令牌及全部测试控制变量均不传递。续期及自检的工作目录都以受保护的 owner-only DACL 创建，避免继承 `%TEMP%` 中其他用户的 Modify 权限。

标准输出总量上限为 1 MiB；标准错误会被读出但不保留。协议超时为 20 秒，用后结束整个进程树，最多等待退出两秒、清理标准错误一秒。续期凭据须属于原用户和客户端。重新读取前检查敏感访问权限仅授予当前用户、SYSTEM 和 Administrators。若 CLI 放宽了权限，应用将 DACL 收紧至当前用户。**修复该 DACL 是 AI SubGauge 对真实凭据文件唯一可能的修改**，不会修改内容或所有者。

失败时，面板和提示显示 `Grok 令牌续期失败：<原因>`，并明确标注演示数据。应用日志、状态和界面均不包含 bearer、refresh token、CLI 原始消息或原始异常。应用不写运行日志。私有 CLI 工作目录和合成测试文件保留在 Windows 临时目录，不会将真实凭据存储复制进去。

构建后可执行隔离测试入口：

```powershell
$env:AISUBGAUGE_TEST_GROK_CLI = (Resolve-Path .\tests\AISubGauge.Tests\bin\Release\net8.0-windows\FakeGrokCli\FakeGrokCli.exe).Path
.\src\AISubGauge\bin\Release\net8.0-windows\AISubGauge.exe --selftest-grok-refresh
```

只有该模式接受测试覆盖并跳过签名检查。它使用合成过期凭据创建私有临时 `GROK_HOME`，仅输出 `{success,error}`，不使用真实凭据。可用 `AISUBGAUGE_TEST_GROK_MODE` 选择 `failure`、`wrong-user`、`wrong-client`、`still-expired`、`wide-acl`、`oversize`、`early-exit` 或 `timeout` 等用例。这些变量在正常、状态和截图模式中无效。

`GROK_HOME`/`GROK_AUTH_PATH` 指向的位置也须通过 ACL 检查；残留测试变量可能使读取转向 `%TEMP%` 下的测试目录。

## 隐私与诊断

每家获准的服务商仅读取其支持的凭据来源。文件读取限制为有大小上限的本机普通文件，拒绝链接，并检查打开后的句柄。所有服务均要求当前用户拥有文件且 DACL 受限；NULL DACL，以及非预期主体获得数据读取、写入、删除、权限／所有者修改能力的情况，都会在读取内容前拒绝。SYSTEM 和 Administrators 是预期管理主体。例如，Everyone、Users 或 Authenticated Users 获得敏感访问权限时会被拒绝：

> 凭据文件对其他用户可读，已拒绝读取；请收紧权限

仅默认 `%USERPROFILE%\.codex\auth.json` 的 Codex 凭据校验可启用沙箱组例外。调用点显式传入 `CredentialKind.Codex` 和打开文件时使用的同一个 `CredentialFiles.CodexPath`。路径须经严格本地绝对路径校验、规范化、去尾斜杠后，与默认路径大小写不敏感地完全相等；`CODEX_HOME` 指向其他目录时仍执行严格校验。本机角色须先确认为非域控制器；BackupDC、PrimaryDC、未知角色或角色查询失败均拒绝例外。组 ACE 的 SID 域部分必须等于本机账户域 SID，`LookupAccountSidW` 须将其解析为名为 `CodexSandboxUsers` 的本机 Alias/Group。按 SID 完整枚举的成员必须恰好是 `CodexSandboxOffline` 和 `CodexSandboxOnline`，二者均须为同一本机账户域的 User。

允许的权限位仅为 `ReadData`、`ReadExtendedAttributes`、`ReadAttributes`、`ReadPermissions`、`ExecuteFile`、`Synchronize`，以及 `GENERIC_READ`/`GENERIC_EXECUTE`；继承的只读 ACE 同样适用。任何额外位（包括写入、删除、权限/所有者修改、`GENERIC_WRITE` 和 `GENERIC_ALL`）、身份不符或查询失败都会拒绝。Grok 等其他服务保持原有检查；此例外不修改任何 Codex 文件权限。残余风险：这两个沙箱账号可读取 Codex 令牌，这是 Codex 自身的 Windows 沙箱设计。条件与测试说明见 [SECURITY.md](docs/SECURITY.md)。

只有 Grok 续期后的 DACL 修复可能修改凭据权限；其他服务商的 ACL 不会被修改。HTTP 读取使用固定官方 HTTPS 地址，禁用 Cookie 和重定向，限制响应大小与超时。应用不读取浏览器 Cookie、localStorage 或聊天历史；官方 CLI 内部行为由其厂商控制。

“导出诊断…”生成版本、操作系统及服务商当前状态／错误。预览前会遮盖疑似令牌、邮箱、`C:\Users\<name>` 路径和机器名。审核预览后，点击“保存”写入新文件；关闭预览不会写入。已有文件、凭据目标及链接路径均被拒绝。设置仅存储可见性、始终显示、语言、主题、授权和开机自启偏好，不存储令牌。

## 状态与图片导出

```powershell
.\AISubGauge.exe --status
.\AISubGauge.exe --status .\status.json
.\AISubGauge.exe --demo
.\AISubGauge.exe --screenshot .\screenshots
.\AISubGauge.exe --demo --screenshot .\demo-screenshots
.\AISubGauge.exe --preview-icons .\icon-previews
.\AISubGauge.exe --render-preview .\comparison
```

`--status` 无界面输出全部七家的授权、演示／缓存过期／错误状态。演示值不会作为真实剩余额度报告。输出目标必须是新文件，已有文件会保留。

`--screenshot` 与 `--render-preview` 都使用固定离线数据：Codex **72%**（3小时20分）、Grok **45%**（1天0小时）、Claude **88%**（5天0小时），顺序和尺寸与 Mac 预览一致。两个模式都不加载用户设置、不检测登录、不读取凭据、不查询服务商、不创建托盘图标，也不截图其他应用。截图无需额外指定 `--demo`。

`--theme light|dark` 可与 `--lang en|zh-Hans` 组合。面板输出到指定目录，文件名为 **`win-panel-{light|dark}-{en|zh-Hans}.png`**，尺寸为 440×350 像素，圆角外透明。附图使用相同后缀：`win-error-…`（合成 Grok 续期错误）、`win-tray-…`（三个 24px 图标放大四倍）、`win-idle-…`（24px 放大八倍）。`--screenshot` 另输出三家各自的 16／20／24／32px 图标。两个命令均采用 Mac 预览的固定时钟，确保重置倒计时可复现。

`--preview-icons` 保持离线，并保留详细的液位图标尺寸预览网格。图片导出会覆盖目标目录中的同名图片。

导出／测试模式互斥，并跳过单实例互斥体。参数错误返回 `2`，命令或输出失败返回 `1`；报告成功时即使某家读取失败也返回 `0`。自测执行完成也返回 `0`，即使结果为 `success: false`，须检查 JSON 内容。

## 许可证与商标

应用代码采用 [MIT License](LICENSE)，原作者版权声明保留于 LICENSE。分发包含该许可证与 Lobe Icons 许可证。

共享品牌素材说明见 [shared/README.md](../shared/README.md)。Lobe Icons 采用 MIT 许可。公开版使用 Lobe Icons 的 Grok 图标，按普通液位渲染。Grok Bot app 提取的 `grokbot.png` 与 `grokbot-head.png` 不随开源仓库分发，已移入被 .gitignore 忽略的 `shared/private-logos/`；旧 Windows 副本位于其 `windows/` 子目录。公开构建即使在本地发现私有素材也不会打包。本地私用构建须准备 `shared/private-logos/grokbot-head.png`，并为 `dotnet build` 或 `dotnet publish` 显式添加 `-p:IncludePrivateLogos=true`（例如从 `windows/` 运行 `dotnet build .\src\AISubGauge\AISubGauge.csproj -c Release -p:IncludePrivateLogos=true`）。只有属性为 `true` 且文件存在时，csproj 才会嵌入并定义 `PRIVATE_GROK_LOGO`，继续使用头像蒙版液位；否则回退到 `shared/logos/grok.png`。测试兼容两种构建。私有素材的再分发许可未确认。品牌名和标志归各自所有者所有，仅用于识别服务，不表示背书、赞助或关联。

`windows/assets/logos` 剩余文件为历史副本；公开服务商图标从 `shared/logos` 嵌入。`PROMPT.md`、`PROMPT2.md` 是历史开发记录，不是当前需求。

如果 AI SubGauge 对你有用，欢迎给仓库点一颗星。谢谢。

---

If AI SubGauge is useful to you, a ⭐ on GitHub would be very much appreciated — thank you!

如果 AI SubGauge 对你有帮助，欢迎在 GitHub 上点个 ⭐，谢谢！
