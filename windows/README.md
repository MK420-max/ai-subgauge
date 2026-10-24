# AI SubGauge 2.0（Windows）

C# / .NET 8 WinForms 的 AI 订阅额度托盘工具。支持 Codex、Claude、Grok Bot；每家一枚圆环品牌图标，单击打开额度面板，右键刷新、设置或退出。默认每 5 分钟刷新，进程退出后保留约 30 秒（检测间隔 2 秒）。没有对应进程时不显示该家；设置中可开启“始终显示”。

## 构建与测试

在 Windows 上准备 .NET 8 SDK（含 Windows Desktop 构建支持）及 PowerShell。`global.json` 以 8.0.100 为基线，使用 `latestFeature` 选择已安装的 .NET 8 SDK，支持 8.0.426。没有第三方 NuGet 包；脚本不会安装 SDK 或其他软件。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# SDK 不在 PATH 时，传入实际 dotnet.exe 路径：
.\build.ps1 -Dotnet '<SDK目录>\dotnet.exe'
```

SDK 按 `-Dotnet` 参数、`AISUBGAUGE_DOTNET` 环境变量、`DOTNET_ROOT\dotnet.exe`、PATH 中的 `dotnet` 的顺序选择。显式指定的 SDK 不存在时直接报错。

脚本将 `assets/brand/app-light-win-{size}.png` 的八档原图封装为 `assets/app.ico`，再构建 Release、发布自包含单文件 win-x64、生成 ZIP 和 SED、运行 console 测试及安装脚本静态检查，并调用 Windows 自带 IExpress 生成安装包。构建缓存与临时文件放在仓库内。用户标准 NuGet 缓存中的 Microsoft .NET 运行时包可作为只读回退源；离线构建需要提前缓存所选 SDK 对应的 win-x64 运行时包。NuGetAudit 已启用，无法获取漏洞数据的 NU1900 仅警告，不会让离线还原失败；缺少实际构建依赖仍会失败。

单元测试可直接从全新源码运行，不要求已有发布或打包产物。打包测试由构建脚本在 publish、ZIP 和 SED 生成后单独运行：

```powershell
dotnet run --project .\tests\AISubGauge.Tests -c Release
# 完整构建后可单独复查打包产物：
dotnet run --project .\tests\AISubGauge.Tests -c Release -- --packaging
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Installer.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\InstallSafety.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\InstallFiles.Tests.ps1
```

每个测试输出 PASS / FAIL，最后输出汇总；失败退出码为 1。测试使用 mock HTTP、RPC、注册表与时钟，不读取真实凭据，不访问真实额度服务，不更改自启动。构建的测试记录在 `artifacts\test-results.txt`。

产物：

- `artifacts\AISubGauge2-Setup-2.0.0.exe`：IExpress 安装包。
- `artifacts\AISubGauge2-2.0.0-win-x64.zip`：便携安装文件，包括 `install.ps1`。
- `artifacts\publish\AISubGauge2.exe`：自包含程序，不需要另装 .NET。

如果系统缺少 IExpress，脚本成功生成 ZIP 并在 `artifacts\packaging-status.txt` 记录回退原因。解压 ZIP 后运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`。安装包构建不会执行安装。

## 与 1.x 并行

安装包的交互模式和静默模式（`AISubGauge2-Setup-2.0.0.exe /Q`）均调用 `cmd.exe /c install.cmd`。安装脚本成功退出 0，失败退出 1，批处理透传退出码。安装日志写入 `%LOCALAPPDATA%\AISubGauge2\install.log`，只保留最近一次尝试的 UTC 时间、固定状态和步骤名称；失败增加固定类别（`SharingViolation`、`SafetyRejected`、`Other`）及数值 HRESULT，例如 `Failed CopyFiles:SharingViolation HResult=-2147024864`。不记录异常原文、路径或凭据；若日志目录不可写，则安装失败，日志可能无法生成。构建和测试不执行安装器，静默安装的真机结果仍需人工验收。

覆盖安装先校验全部包文件与目标路径，只停止名称为 `AISubGauge2` 且可执行文件路径精确匹配目标 EXE 的进程，并等待退出（每个进程最多 5 秒）。每个文件先复制到目标目录中的唯一临时文件，再通过 `File.Replace` 原子替换已有文件；新文件通过同目录重命名发布，EXE 最后更新。共享/锁冲突最多尝试 8 次，退避从 150ms 增至最多 600ms；其他错误立即失败。安装辅助脚本始终从独立解压包加载，拒绝从安装目录运行。失败时若停止进程前已有 EXE 且安全检查仍通过，则尝试重新启动该目标，并单独记录 `Recovery` 结果；重启失败不会掩盖原始错误。原子性以单个文件为单位，不是整个安装事务；失败可能保留已更新的辅助文件和 `.installing` 临时文件，替换前在同一目录创建 GUID 命名的旧 EXE 备份；后续快捷方式、自启动或启动等步骤失败时，先恢复旧 EXE，再重新启动。恢复失败则不启动替换文件；备份及失败的新 EXE 保留供检查。

安装开始时，目标目录通过安全检查后，仅清理该目录第一层的安装器临时普通文件：`AISubGauge2.<32 位小写十六进制 GUID>.backup.exe`、同格式的 `.failed.exe`，以及 `.<精确包文件名>.<32 位小写十六进制 GUID>.installing`。不遍历子目录，不处理目录、重解析点、相似名称或兄弟目录。安装达到 `Completed` 后才删除本次旧 EXE 备份；失败与恢复路径保留备份，下一次安装才清理遗留文件。清理只记录固定阶段和计数，例如 `Cleanup Leftovers Removed=2 Failed=0`、`Cleanup Backup Removed=1 Failed=0`，不记录文件名或路径。清理失败保留文件；完成后的清理或日志失败不会回滚安装。

`InstallFiles.Tests.ps1` 仅在仓库的 `artifacts\install-sim` 下模拟安装，覆盖已有文件、持有一秒后释放的真实 FileStream 锁、重试耗尽后旧 EXE 保留与恢复、路径安全拒绝及进程退出超时，并验证成功后备份删除、遗留临时文件清理与非匹配文件/目录/重解析点保留。进程与启动调用均使用替身，不运行安装器或真实应用，不改真实安装目录与注册表。

| 项目 | 2.0 使用的名称 |
|---|---|
| 程序 | `AISubGauge2.exe` |
| 安装目录 | `%LOCALAPPDATA%\Programs\AISubGauge2` |
| 设置 | `%LOCALAPPDATA%\AISubGauge2\settings.json` |
| 自启动 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下的 `AISubGauge2` |
| 单实例互斥体 | `Local\AISubGauge2.2.0` |
| 开始菜单 | 当前用户的 `Programs\AISubGauge2` |

默认开启自启动，值为 `"<exe 路径>" --autostart`。再次启动程序会唤起现有的设置窗口。设置中可以关闭自启动。安装及卸载脚本只处理 2.0 的进程、目录、快捷方式与注册表值；不会修改旧版 `AISubGauge`。

卸载可使用开始菜单的卸载快捷方式，或执行安装目录的 `uninstall.ps1`。默认同时移除 2.0 设置，传入 `-KeepSettings` 保留设置。脚本使用 Windows 已知文件夹确定安装、设置及版本 2 的开始菜单目录；检查目标及整条父目录链，拒绝所有重解析点。每次写入或自底向上删除前重新检查路径，不使用递归删除；安装中的重命名仅限同目录临时文件发布。路径复查缩小检查与操作之间的竞态窗口，但不等于原子文件系统事务。注册表权限、删除或读回失败时退出非零，只允许自启动值原本不存在。

## 已知问题 / Known issues

- 首次运行或离线时，如果本地没有可用的证书吊销缓存，Codex 可能显示固定提示“CLI 验证失败。”（English: “CLI verification failed.”）。签名校验仅使用本地吊销缓存，保持失败时拒绝执行的策略，不自动绕过校验或修改缓存。
  On first run or while offline, an unavailable local revocation cache can cause Codex to show the fixed verification failure above. Verification uses the local cache only and fails closed.
- 签名校验超时或上一轮校验仍占用校验器时，面板和设置显示“签名校验未响应，请重启 AI SubGauge”。请退出并重新启动应用。连续 3 次忙碌结果会写入一条固定诊断 `VerifierBusyRepeated`；同一连续忙碌期间不重复写入，后续非忙碌校验重置计数。不包含路径、证书内容或异常原文。
  A timed-out or still-busy signature check shows “Signature check is not responding. Please restart AI SubGauge.” in both the panel and settings. Exit and restart the app. Three consecutive busy results emit one fixed diagnostic per streak.

## 凭据与额度来源

- **Codex**：沿用 1.x 的官方 CLI `app-server` JSON-RPC，调用 `account/read` 和 `account/rateLimits/read`。只接受 ChatGPT 订阅登录，API key 账户不算订阅。自动查找仅限 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe` 和 `%APPDATA%\npm\node_modules\@openai` 下已知的 Windows 原生 CLI 包路径；不搜索 PATH，不执行 `.cmd`。这些目录均可由当前用户写入，目录位置本身不能证明文件可信。LocalAppData 下的 codex.exe 必须通过 Windows WinVerifyTrust 及下述 OpenAI 发布者和固定证书链校验。npm 路径同样默认要求签名；只有在通用设置开启默认关闭的 “Allow unsigned Codex CLI (npm)” / “允许未签名的 Codex CLI（npm）” 后才接受该位置的未签名文件，面板及订阅设置的 Codex 行显示 “Unsigned” / “未签名” 标识。开关不放宽无效签名、错误发布者、错误证书链或自定义路径的要求。`CODEX_EXE` 可指定其他本机绝对 `.exe` 路径，但必须通过相同的 OpenAI 发布者与证书链校验；使用后设置页显示自定义路径提示。`CODEX_HOME` 交给官方 CLI。当前不自动枚举 MSIX 安装，可用符合签名要求的显式路径。
- **Claude**：使用 `CLAUDE_CODE_OAUTH_TOKEN` 或 `%USERPROFILE%\.claude\.credentials.json` 的 OAuth 登录，读取官方 OAuth usage。套餐取本地订阅类型，不根据余额猜套餐。
- **Grok Bot**：优先读取官方 Grok CLI 登录元数据；可使用 `GROK_AUTH_PATH` 或 `GROK_HOME`，默认 `%USERPROFILE%\.grok\auth.json`。官方账单接口返回每周额度。没有官方 CLI 凭据时，可只读 Grok Bot 的当前账户用量缓存；缓存过期时明确显示过期，不把缓存当成当前数值。
- **Grok 自动续期**：遇到 401 或已过 `expires_at` 时，启动本机已有官方 CLI 的 `agent stdio`，通过 `_x.ai/auth/getBearerToken` 续期，并重新读取同一账户的有效凭据。仅接受 `%USERPROFILE%\.grok\bin\grok.exe`；`GROK_EXE` 也必须落在该已知位置，使用时显示自定义路径提示。签名可选，存在无效签名时拒绝。只有官方 CLI 更新其凭据文件；应用不复制或打印凭据。每轮最多续期一次，401 后成功续期最多重试一次。官方 CLI 缺失或续期失败时提示重新登录。临时工作目录属于 AISubGauge2，并在结束后清理；清理失败只记录固定的 `RefreshCleanupFailed` 诊断状态。

Codex 签名校验直接从成功的 WinVerifyTrust 状态读取签名者叶证书及其链（WTHelperProvDataFromStateData / WTHelperGetProvSignerFromChain），复制后在 finally 中关闭状态；不重新从文件读取证书，也不另建证书链。解析 X500DistinguishedName 的真实 O= RDN，要求组织名按 ordinal 精确等于 `OpenAI OpCo, LLC`，拒绝子串、仅 CN 匹配及歧义 RDN。链末端必须为 Microsoft Identity Verification Root Certificate Authority 2020（SHA-1 thumbprint `F40042E2E5F7E8EF8189FED15519AECE42C3BFA2`），且中间证书包含 Microsoft ID Verified Code Signing PCA 2021（`8E750F459DAF9A79D6370DB747AD2226866AD818`）。叶证书有效期约三天，会轮换，因此不固定叶证书指纹；颁发链更换时需审查并更新这些常量。

整个原生校验在 Task.Run 工作线程中运行，默认每个文件最多等待 5 秒，超时或任何错误均返回固定的 Invalid 状态并拒绝启动。设置 `WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT | WTD_CACHE_ONLY_URL_RETRIEVAL`（`0x1080`），仅使用缓存检查撤销状态；缓存不足也会拒绝。CLI 查找和等待不会阻塞 UI 线程。超时不能安全中断原生调用，后台调用返回后自行关闭信任状态，迟到的成功结果不会用于启动。进程级 SemaphoreSlim(1) 在原生调用真正返回前一直占用；忙时立即返回 Invalid / VerifierBusy，不创建新校验工作线程。
自启动写入失败不会停止额度刷新或计时器；通用设置中的开关显示红色错误状态及重试提示，诊断只记录 `AutostartFailed`，不包含异常内容。

两个窗口始终保留各自含义。真实服务未提供某个窗口、重置时间或套餐时显示“—”“重置时间未提供”“套餐未知”。尤其 Grok 当前账单/缓存可能只返回每周窗口；**不把每周额度、额外余额或每月额度伪装成 5 小时额度**。图标优先显示 5 小时余量，缺失时显示每周余量。API 没有 5 小时数据时无法凭空补齐。

读取错误使用中英文资源表里的固定安全文字。HTTP 禁止重定向和 Cookie；限制响应/本地 JSON 大小。外部套餐字段仅映射到允许的套餐枚举。生产日志只接受枚举事件，并统一经过 Redactor；异常原文、响应原文、RPC 标准错误、令牌和 Cookie 不会进入日志或 UI。凭据类型不会用自动生成 `ToString` 的 record。

## Codex 校验安全与已知问题

运行 `AISubGauge2.exe --verify-codex` 可无界面自检。它使用应用相同的候选顺序、`CODEX_EXE`、已保存 npm 开关及真实校验器，只检查文件，不启动 CLI、不读取登录凭据、不写设置或注册表。输出一行，接受退出 0，拒绝退出 4：

```text
codex-verify: Accepted location=LocalAppData signer=OpenAI OpCo, LLC
codex-verify: Rejected:Unsigned location=Npm signer=-
```

`location` 仅为 `LocalAppData`、`Npm`、`Override` 或 `None`；`signer` 为证书的 O 值或 `-`，不输出完整路径、用户名或异常。拒绝状态包括 `NotFound`、`Unsigned`、`PublisherMismatch`、`VerifierBusy`、`VerifierTimeout`、`RevocationFailure`、`RevocationOffline`、`NoRevocationCheck` 和 `Invalid`。PowerShell 中用 `& .\AISubGauge2.exe --verify-codex | Out-Host` 等待并显示 GUI 子系统程序的输出。

- **未签名 npm CLI 默认不可用**：升级后需要在通用设置明确选择是否允许。npm 和 LocalAppData 都是用户可写目录；npm 开关意味着接受无法认证发布者的本机程序。LocalAppData 与自定义路径不提供未签名例外。
- **离线或撤销缓存缺失**：缓存校验无法确认信任时拒绝启动；面板和设置始终显示相同的固定本地化文字 `CLI verification failed.` / `CLI 验证失败。`，不显示错误代码、路径或异常。不会因离线自动跳过校验，也不清理或修改系统 CRL / 证书缓存。
- **原生校验挂起**：调用超时后仍占用唯一校验槽；后续检查立即拒绝，直至原生调用返回。证书颁发链更换也需要更新固定值。

自动测试通过注入模拟离线、空 CRL 缓存、未签名与错误发布者、超时及忙状态，不断网、不更改系统证书缓存。安装恢复只在仓库临时目录测试，并替换进程启动调用。
## 外观与设置

面板使用圆角卡片与两条额度条。设置只包含“AI 订阅”和“通用”页。Windows 字体使用 Microsoft YaHei UI，保留可键盘操作的按钮、开关和下拉框。面板在鼠标所在屏幕的工作区右下角弹出，失焦或 Esc 隐藏。

- 窗口默认跟随 `AppsUseLightTheme`，支持浅色/深色手动覆盖。
- 托盘默认跟随 `SystemUsesLightTheme`，与窗口主题独立。
- 托盘默认仅显示圆环与品牌标志，不显示百分比数字；旧设置缺少 `ShowTrayPercentage` 字段时也默认关闭，明确保存的开启或关闭值仍保留。可在“AI 订阅”页开启“托盘显示百分比”。托盘 ICO 包含分别原生渲染的 16、20、24、32、40、48、64px 贴边图像。托盘按任务栏 DPI 的 `SM_CXSMICON` 选取匹配尺寸；无精确匹配时优先缩小下一档。额度刷新、主题变化或检测到 DPI 变化时重建，DPI 检测间隔 2 秒。EXE 的 `assets/app.ico` 使用 AI SubGauge 应用品牌图形，包含上述七档及 256px 原图，不包含账户数据。
- 监听 `UserPreferenceChanged`，刷新当前窗口、图标和菜单。
- 语言默认按系统 UI culture：`zh*` 使用简体中文，其余使用 English，可手动覆盖。
- 托盘、面板和设置的品牌标志来自 `assets/logos/{openai,claude,grok}-512.png`，嵌入程序，每个显示尺寸直接从原图高质量缩小，浅色主题染黑、深色主题染白。来源与许可见 `assets/logos/SOURCES.md` 和 `THIRD_PARTY_NOTICES.md`。
- 进程名称集中在 `RunningGate.ProcessNames`，可在编译前增补；读取额度的临时 Codex/Grok 子进程会被排除。
- 托盘图标是否折叠到溢出区由 Windows 管理；程序不会修改系统通知区域偏好。

## 离线 Mac 图标对照

```powershell
& .\AISubGauge2.exe --export-icons .\mac-compare | Out-Host
```

该命令在 GUI 初始化前运行，不读取设置或账户、不联网、不访问桌面。固定导出 Codex 72 / Claude 35 / Grok 8 的浅深主题七档原生 PNG、逐像素最近邻 8× PNG、七帧 ICO、原有 1×/4× contact sheets，以及 `mac-compare-{light|dark}-{percent|no-percent}.png`。这些文件是离屏绘制，不能作为真实任务栏截图。

托盘圆环外径为画布边长减 0.5px，线宽为外径的 6.5%，从右下 55.5° 反向扫过顶部 291°，底部保持开口。默认无数字；开启百分比时，数字使用 Segoe UI Black（不可用时 Segoe UI Bold），墨迹高度约为外径的 32%，位于顶部内侧 1px，保留原有圆角弧线切口和透明字形留白以增强与 Logo 的区分。

开启或关闭数字均使用同一套较大的居中 Logo：16、20、24、32、40、48、64px 图标分别使用 13、16、19、28、35、42、55px 的 Logo 绘制区域。数字叠加在 Logo 上方，不会缩小 Logo。绘制区域经整像素圆形蒙版裁剪，所有 Logo 墨迹与圆环内圆至少相距 0.5px。轨道为前景色的 30% alpha，浅色主题用黑色数字/Logo，深色用白色；额度配色保持不变。只使用现有审核资产，包括 Grok 标志。

离线导出的默认 `tray-icon-*.ico`、`tray-icon-sizes-*.png` 和 `mac-compare-overview.png` 均不含数字；名称含 `percent` / `no-percent` 的对照 PNG 继续展示两种模式。自动测试覆盖 16..64 每个整数尺寸的 Logo 尺寸一致性、墨迹边界、实际数字墨迹和圆环贴边，并检查字体墨迹高度、字重覆盖率、圆头端点和底部开口。`TrayRenderMode.Reference` 使用独立圆弧距离采样，与生产路径渲染比较。Windows 字体和 PNG 栅格化与 macOS 不同，不宣称逐像素相同。

## 真实截图与证据模式

在已解锁、可访问的交互式桌面运行：

```powershell
.\AISubGauge2.exe --screenshot .\evidence --theme light --lang zh --demo
.\AISubGauge2.exe --screenshot .\evidence --theme dark --lang zh --demo
.\AISubGauge2.exe --screenshot .\evidence --theme light --lang en --demo
.\AISubGauge2.exe --screenshot .\evidence --theme dark --lang en --demo
```

截图启动前检查 OpenInputDesktop / GetUserObjectInformation 的输入桌面名必须为 `Default`，并通过 WTSQuerySessionInformation(WTSSessionInfoEx) 确认当前会话已解锁且处于活动状态。锁定、非默认桌面或无法确认状态时，不启动截图流程，在 `capture-failed.txt` 写入 `Session is locked; no screenshots taken.` 并以 3 退出。每次屏幕复制前再次检查；若中途锁屏则停止后续截图，已完成的文件保留。
模式按顺序显示真实窗口，通过 `Graphics.CopyFromScreen` 截取窗口实际区域，再截取真实任务栏通知区域。生成：

```text
panel-{theme}-{lang}.png
settings-subs-{theme}-{lang}.png
settings-general-{theme}-{lang}.png
tray-area-{theme}-{lang}.png
tray-icon-{theme}-{lang}.png
tray-icon-{theme}-{lang}.ico
tray-icon-claude-{theme}-{lang}.ico
tray-icon-grok-{theme}-{lang}.ico
tray-icon-sizes-{theme}-{lang}.png
capture-{theme}-{lang}.json
```

默认 `tray-icon` 图标文件不含数字；额外的 `tray-icon-percent-*`、`tray-icon-claude-percent-*`、`tray-icon-grok-percent-*` 及 `tray-icon-sizes-percent-*` 文件展示开启数字的版本。`tray-icon` PNG 将当前 DPI 原生尺寸的三枚图标各放大到 160px；`tray-icon-sizes` PNG 展示三家全部七档尺寸的 1× 和最近邻 4× 对照。ICO 保存当前额度对应的七档原图，不带厂商后缀的 ICO 为 Codex。上述图标文件都是离屏渲染，其余 PNG 是屏幕像素。截图强制三家始终显示，窗口使用指定主题，托盘始终跟随任务栏实际主题（见 JSON 的 `trayTheme`）；忽略已保存设置，不修改设置及自启动项。完成后程序退出；失败退出码非 0，生成不含异常原文的安全故障记录。不要把离屏绘制图当作真实截图。若 Windows 将图标放入溢出区，`tray-area` 会忠实记录当时任务栏，而不是合成图标。

`--demo` 固定 Codex 72/58、Claude 35/61、Grok 8/22，不构建真实 provider、不读取凭据、不联网。去掉 `--demo` 才访问真实额度来源；官方 Grok CLI 可能为续期更新其登录文件。普通 `--demo` 运行也不会保存设置和自启动。

构建期间不运行安装器，不操作现有 1.2.0，也不使用真实账户做自动验收。自动测试结果见 `artifacts/test-results.txt`；截图与实际安装需单独人工验收。

## 许可证

本项目采用 MIT 许可证，完整条款见 [LICENSE](LICENSE)。第三方标志的 CC0 / MIT 许可及商标声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；该声明与项目许可证随分发包一起提供。
