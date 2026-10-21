修改当前目录的 Windows 托盘原型 (C# .NET 8 WinForms)。当前机器 macOS 无 dotnet，不要编译；代码要严谨一次编译通过。只改当前目录。不要用 rm（需要删除文件就 mv 到 ~/.Trash）。

需求变更：
1. 托盘从一个 NotifyIcon 改为两个：Codex 一个、Grok 一个。每个图标把该家 logo 和剩余百分比数字一起画进图标（如左上小 logo + 大号数字，或数字为主、logo 做背景/小角标），必须在 16/20/24/32px 下清晰可读：按 SystemInformation.SmallIconSize 和当前 DPI 选尺寸生成，数字用粗体紧凑字体、高对比描边，100% 显示 "99+" 或"满"之类合理处理，数字颜色绿→黄→红。演示数据时角标标记。悬停提示显示该家百分比、重置时间（演示时注明「演示数据」）；左键弹出明细面板（只显示 Codex 和 Grok）；右键菜单同前。
2. 左下角窄条改为「[logo] Codex xx% · [logo] Grok xx%」，演示时尾部仍标「演示数据」。
3. 启用 Grok，取额度照 Mac 版：阅读 ~/oss-prep/mac-menu-bar-tidy/Sources/TidyBar/GrokBuildUsageSource.swift、GrokBuildConnection.swift、GrokUsageSource.swift、AIUsage.swift（只读，绝不修改那个目录）。Windows 等价实现：凭据 %GROK_AUTH_PATH% / %GROK_HOME%\auth.json / %USERPROFILE%\.grok\auth.json，按 Mac 版同样的校验规则挑选凭据，GET https://cli-chat-proxy.grok.com/v1/billing?format=credits 带 Bearer，解析同 Mac 版；令牌过期时如 Mac 版那样调用官方 grok CLI（%USERPROFILE%\.grok\bin\grok.exe 或 PATH）的 ACP 刷新流程，只读 auth.json，不自己写凭据文件（若 Mac 版刷新需要临时目录，同样处理）。若 Mac 版有 Grok Bot 本地缓存回退，可在 Windows 上找类似位置（找不到就跳过）。禁止重定向、cookies；token 绝不打印、记录或显示。失败时该家回退演示数据并标注。图标 logo 用 assets/logos/xai.png（深色背景下可反色或加浅底保证可见）。
4. Claude 从 UI 和默认注册中去掉，代码保留，ProviderRegistry 注释说明如何重新启用。演示数据改为 Codex 72%、Grok 55%。
5. --screenshot <dir> 输出：tray-codex-{16,20,24,32}.png、tray-grok-{16,20,24,32}.png（原尺寸）、tray-icons-zoom.png（全部尺寸放大 8 倍最近邻拼图）、tooltip-codex.png、tooltip-grok.png、strip.png、panel.png。不要做任何整屏截图（删除 CopyFromScreen 的 desktop.png 逻辑）。
6. 更新 README（简体中文），包括 Grok 取数方式与安全说明、商标说明保留。
完成后自检编译风险并列出改动文件。
