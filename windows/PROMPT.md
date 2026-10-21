在当前目录 (windows-quota-tray) 实现一个 Windows 托盘应用原型，C# .NET 8 WinForms（net8.0-windows，UseWindowsForms），无第三方 NuGet 依赖。当前机器是 macOS，没有 dotnet，不要尝试编译；代码之后在 Windows 上用 `dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true` 构建，请务必写出能一次编译通过的严谨代码（注意 nullable、using、WinForms API 正确性）。不要改动当前目录以外任何文件。不要用 rm。

结构：
- WindowsQuotaTray.sln, src/WindowsQuotaTray/WindowsQuotaTray.csproj（OutputType WinExe, ApplicationHighDpiMode PerMonitorV2, assets/logos/*.png 作为 EmbeddedResource）
- Providers/IQuotaProvider.cs：interface { string Id; string DisplayName; string LogoResource; Task<QuotaSnapshot> FetchAsync(CancellationToken) }。QuotaSnapshot{Provider, Plan, List<QuotaWindow> Windows, bool IsDemo, string? Error, DateTime UpdatedAt}；QuotaWindow{Id, Title, double RemainingPercent(0-100), DateTimeOffset? ResetsAt}。主显示值=所有窗口中最小剩余百分比。
- Providers/CodexProvider.cs：照 Mac 版办法：查找 codex.exe（顺序：环境变量 CODEX_EXE；%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe 取最新修改；PATH 中 codex.exe/codex.cmd），启动 `codex app-server --listen stdio:// -c analytics.enabled=false`，CreateNoWindow，重定向 stdin/stdout，stderr 丢弃。按行 JSON-RPC：发 {"id":1,"method":"initialize","params":{"clientInfo":{"name":"windows_quota_tray","title":"Windows Quota Tray","version":"0.1"}}} 等 id=1；发 {"method":"initialized","params":{}}；发 {"id":2,"method":"account/read","params":{"refreshToken":false}}，result.account 为 null => 未登录；account.type 必须为 "chatgpt"，planType 为套餐；发 {"id":3,"method":"account/rateLimits/read"}。解析 result.rateLimitsByLimitId（字典）或 result.rateLimits（单个，key 记为 codex）。每个 bucket 的 primary/secondary：usedPercent、windowDurationMins(300=>"5 小时",10080=>"每周")、resetsAt（unix 秒或 ISO 字符串都兼容）。剩余=100-used，夹在0-100。20 秒超时，结束后 kill 进程树。忽略不匹配 id 的行。
- Providers/ClaudeProvider.cs：token 来源：环境变量 CLAUDE_CODE_OAUTH_TOKEN，否则 %USERPROFILE%\.claude\.credentials.json 的 claudeAiOauth.accessToken（文件 >1MB 拒绝）。GET https://api.anthropic.com/api/oauth/usage，头 Authorization: Bearer <token>，anthropic-beta: oauth-2025-04-20，Accept: application/json；HttpClientHandler AllowAutoRedirect=false, UseCookies=false；20 秒超时。解析 five_hour("5 小时"), seven_day("每周"), seven_day_opus, seven_day_sonnet 的 utilization(已用百分比) 与 resets_at(ISO)。401/403 给中文错误。
- Providers/GrokProvider.cs：占位类，实现接口但默认不注册（ProviderRegistry 中注释说明如何启用），返回 Error="尚未实现"。
- Providers/DemoProvider.cs：生成演示数据（Codex 72%、Claude 40%，重置时间为现在+若干小时），IsDemo=true。
- ProviderRegistry.cs：列出启用的 provider（Codex、Claude），预留 Grok。
- 安全：任何地方不得记录、打印、显示 token 或凭据内容；日志（若有，写 %LOCALAPPDATA%\WindowsQuotaTray\log.txt）只写错误类别。网络只访问 api.anthropic.com。
- 演示模式：命令行 `--demo` 强制演示；或者某家真实获取失败时，该家回退演示数据并 IsDemo=true。所有显示演示数据的地方（托盘提示、面板、窄条）都要明确标注「演示数据」。
- QuotaService：启动立即刷新，之后每 5 分钟；事件 Updated。
- TrayIconRenderer：动态绘制 32x32（按 DPI 也可 16）图标：透明背景，两根竖条（Codex 左、Claude 右），带浅灰底槽，高度=剩余比例，颜色按剩余从绿(>=50%)经黄到红(<=15%)平滑插值；演示模式在图标角落画一个小 "D" 或虚线边框。注意 Icon.FromHandle 之后 DestroyIcon 防泄漏。
- 托盘 NotifyIcon：Text（≤127 字符）例如 "Codex 72% 重置 10/21 03:00\nClaude 40% 重置 10/21 08:00"，演示时前面加 "[演示数据]"。单击左键弹出 DetailsPanel；右键菜单：刷新、显示/隐藏左下角小条（Checked）、退出。
- DetailsPanel：无边框浅色小窗，出现在托盘附近（工作区右下角），失焦自动隐藏；每家显示 logo、名称、套餐、每个窗口的标题、进度条（同配色）、剩余%、重置时间（本地时间 + 相对 "x 小时后"）、错误信息、数据来源（真实/演示数据，演示用醒目橙色标签）；底部显示更新时间。
- BottomStrip：窄条窗口（高约 28px），FormBorderStyle None, TopMost=true, ShowInTaskbar=false, CreateParams 加 WS_EX_TOOLWINDOW 与 WS_EX_NOACTIVATE；初始位置为 Screen.PrimaryScreen.WorkingArea 左下角（Left+8, Bottom-高度-4），即任务栏正上方；鼠标左键拖动（ReleaseCapture + SendMessage WM_NCLBUTTONDOWN HTCAPTION）；深色半透明背景圆角；内容自绘：「[logo] Codex 72% · [logo] Claude 40%」，logo 16px，百分比用配色；演示时尾部加橙色「演示数据」。可开关，状态保存到 %LOCALAPPDATA%\WindowsQuotaTray\settings.json（也存位置）。
- 截图支持（用于验收）：命令行 `--screenshot <dir>`：启动后加载数据，显示窄条和面板，把 tray 图标渲染为放大 PNG (tray-icon.png, 128px 放大 + 原尺寸)，把 tooltip 文本渲染成一张模拟提示框 PNG (tooltip.png)，用 Control.DrawToBitmap 存 panel.png 与 strip.png，然后另外用 Graphics.CopyFromScreen 截一张全屏 desktop.png，之后退出。
- 单实例（Mutex）。
- README.md（简体中文）：功能、构建命令、运行参数、额度获取方式、安全说明、如何添加 Grok、商标说明：「OpenAI、Codex 为 OpenAI 的商标；Anthropic、Claude 为 Anthropic PBC 的商标；xAI、Grok 为 xAI 的商标。图标来自 Lobe Icons（MIT，见 assets/logos/LICENSE-LobeHub.txt）的官方品牌标识重绘，仅用于标识，不代表认可或关联。」
- .gitignore（bin obj publish）。
完成后列出文件清单并自检一遍编译风险。
