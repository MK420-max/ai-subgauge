# Windows 1.2.0 implementation record

This record groups the current request into eight open-source decisions. The Mac application is read-only reference material for this change.

| Decision | Windows implementation | Verification to run on Windows |
| --- | --- | --- |
| 1. Product identity and compatibility | AISubGauge solution/project/assembly/namespace/exe/mutex; AI SubGauge display name; 1.2.0; copy old settings and retain ProviderVisibility | Settings migration and project build |
| 2. Default launch at login | HKCU Run value, quoted current executable, nullable LaunchAtLogin, tray toggle, headless on/off/status and legacyRemoved | Isolated registry tests; inspect headless JSON |
| 3. Verified official Grok renewal | Absolute local exe, Authenticode and centralized signer fragments, ACP, exact environment allowlist, bounded output/time/kill, same-account reread | Fake CLI success/failure/timeout/oversize/account tests and unsigned-image rejection |
| 4. Credential file restrictions | Check opened-handle ACL before reading; reject broad readable groups; Grok ownership and strict ACL; post-CLI DACL repair only | Real temporary-file ACL tests |
| 5. Per-provider permission | Separate ProviderConsent entries; detection before consent; no fetch before approval; visibility-based migration | Consent gate and migration tests |
| 6. Preview before diagnostic export | Safe fields, redaction, preview dialog, explicit Save to new safe target | Redaction and token-free status tests; manually close/save preview |
| 7. Shared presentation and assets | Mac order/dark cards/provider colors/wording, shared logos with preserved manifest names, Windows liquid tray design, offline paired image exports | Resource checks, render-checks.ps1 and visual comparison |
| 8. Open-source distribution | English README, shared provenance/strings, MIT license and original author notice in LICENSE, bundled license notices, private-file ignore rules, xUnit and security scripts | Build/test/publish and review notices in output |

## Files

- `WindowsQuotaTray.sln` was moved to `AISubGauge.sln`; `src/WindowsQuotaTray/` was moved to `src/AISubGauge/`, and its csproj was renamed.
- Identity/behavior: `Program.cs`, `AppSettings.cs`, `AutoStart.cs`, `QuotaService.cs`, `StatusReport.cs`, `TrayApplicationContext.cs`, `ProviderRegistry.cs`, `AssemblyInfo.cs`, project metadata and all namespaces.
- Security: `LocalFiles.cs`, `Providers/CredentialAccess.cs`, `CredentialFiles.cs`, `Authenticode.cs`, `GrokCliRefresh.cs`, `GrokProvider.cs`, `CodexProvider.cs`, `GrokBotCache.cs`, `Diagnostics.cs`.
- Presentation: `UI/DetailsPanel.cs`, `DiagnosticsPreview.cs`, `QuotaText.cs`, `UiStyle.cs`, `ScreenshotCapture.cs`, `IconPreviewCapture.cs`. Existing full-logo/10% liquid/face-mask rendering is retained in `TrayIconRenderer.cs`.
- Tests: `tests/AISubGauge.Tests/` (project and four test files), `tests/FakeGrokCli/`, updated `tests/security-checks.ps1`, new `tests/render-checks.ps1`.
- Distribution: `README.md`, `LICENSE`, `.gitignore`, `shared/README.md`, `shared/strings.md`. Existing logo copies and historical prompt files are retained.

## Evidence and remaining acceptance

On macOS, project XML, project/content/resource references, C# lexical delimiter balance and diff whitespace were checked. Of the overlapping legacy/shared assets, 13 files have matching SHA-256 hashes; `kimi.png`, `gemini.png` and their dark variants differ. Shared assets remain the build source, and both copies are preserved. No dotnet command, C# compilation, Windows test execution, real credential query or Windows rendering was performed. These static checks do not establish a successful Windows build.

Run the build/test/security/render/publish commands in README on Windows. Then verify the visible consent question, grant/revoke menu, autostart checkbox, diagnostics close/save behavior and the exported panels. Real Grok renewal additionally requires an independently verified official signed CLI and a permitted user's real login; the test signature bypass never validates the production publisher.

No git commit or push was performed. No file was removed with rm or moved outside windows/shared. The legacy logo directory is retained. Private Windows runtime/test temporary directories are also retained; credential bytes are never copied there by the application outside the synthetic self-test fixture.
