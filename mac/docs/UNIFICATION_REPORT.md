# AI SubGauge Mac 历史统一报告（初始开源版）

本文保留初始开源版的历史验收结果；当前 Mac 版本为 2.0.0（build 200），本报告的旧测试和打包结果不代表 2.0 验收。当前行为参见 [Mac README](../README.md)。

本轮只修改 `mac/`，分支 `ai-subgauge-unify`。Windows 目录仅作只读参考。未执行 git commit / push，未使用 rm，未安装到 /Applications，未启动或修改正在使用的正式版，未连接真实账户或读取真实钥匙串凭据。验收只运行测试替身和开发预览。旧缓存、旧安装包和新增临时验收材料保留在仓库内的 `.build/`、`dist/`，未尝试移动到沙箱外的系统废纸篓。

## 结果

显示名称、bundle 名称、本地化名称统一为 **AI SubGauge**；版本为初始开源版，内部 build 号 **4**。SwiftPM product / 可执行文件为 **AISubGauge**，Swift module / target 保留 TidyBar。正常界面保留现有布局，仅新增逐家登录复用选择和诊断预览入口。

## 8 项开源决定及 Mac 实现

| 决定 | Mac 实现 |
| --- | --- |
| 1. MIT 许可证 | LICENSE 为 MIT，保留原作者版权行；原桥接及离线 logo 的第三方许可证保留，应用包内附带 LICENSE 与 THIRD_PARTY_NOTICES.md。 |
| 2. ad hoc 分发签名 | build.sh 用 `codesign --sign -`、identifier `com.mike.aisubgauge` 和绑定 cdhash 的默认 designated requirement；不使用真实签名私钥、不做 Developer ID 公证。Release 不生成调试信息，继续检查产物不含本机用户路径。 |
| 3. 新身份与兼容迁移 | 新 bundle ID / defaults 域 `com.mike.aisubgauge`，新 API 服务 `com.mike.aisubgauge.api`。启动前分阶段复制旧 defaults、Application Support、应用自己的 API key，不覆盖、不删除；成功阶段标记一次，失败阶段下次重试。旧 runtime ID 集中在 LegacyIdentifiers.swift。 |
| 4. 用户控制开机自启 | 保留 SMAppService.mainApp 注册 / 注销开关，读取系统状态并提示等待批准。迁移不自动注册新登录项或注销旧项。未修改用户当前登录项；仅确认源码与构建，不声称实际开机验收。 |
| 5. Grok 官方续期与执行校验 | 保留官方 CLI OAuth / ACP 同账户续期。下载暂存文件在安装前校验，缓存和已安装工具在执行前校验 Apple Developer ID 链、固定 team `5Y6N3AJ54S`、identifier `xai-grok-pager`，并检查路径、owner、权限。失败不执行。UI 保留续期失败原因，CLI 输出与令牌不写日志。真实官方二进制签名及真实续期未验收，团队变更需代码审阅。 |
| 6. 凭据私有权限 | Claude、Grok、Codex 凭据共用打开句柄后检查；`mode & 0o044 != 0` 拒读，提示“请将该文件权限改为 600”；拒绝符号链接、不安全 owner / 类型 / 写权限及大文件。首次读取失败也在 UI 中保留提示。 |
| 7. 本机登录逐家同意 | Codex / ChatGPT、Claude Code、Grok CLI / Bot 独立开关、独立 UserDefaults key，默认关闭；未同意不读取该家的其他应用登录。Claude 独立官方网页会话仍由用户主动连接。 |
| 8. 诊断先预览再导出 | 设置 → 通用 → 导出诊断…，先展示脱敏文本，用户确认才复制或保存。旧 --diagnostics 和自动化入口也走预览。报告仅含名称 / 版本、OS、固定 provider 状态；脱敏函数额外覆盖 token、邮箱、用户主目录、主机名及嵌套字段。 |

## 迁移细节

详见 [MIGRATION.md](MIGRATION.md)。旧域所有键原样复制，AppKit autosave 键再增加新前缀别名；已有新数据优先。目录递归合并缺失普通文件，不跟随符号链接。钥匙串只查询本应用已知 API provider 项；使用注入协议测试，真实实现禁止交互式认证，失败不阻塞启动。旧服务与旧目录均保留。settings.json 中 rules / order / presets 的旧身份在读取时兼容映射，先验证原配置，继续拒绝原本非法的重复顺序。

## 验证

使用用户指定的 macOS 26.5 SDK，不改变 macOS 27.0 最低系统要求。旧仓库复制来的模块缓存包含原路径，故保留并使用新的仓库内缓存。实际执行环境如下：

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/unify-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/unify-module-cache"
export TMPDIR="$PWD/.build/unify-tmp"
```

实际完整构建和测试命令：

```sh
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --disable-sandbox --disable-keychain --disable-netrc --cache-path .build/unify-cache --config-path .build/config --security-path .build/security
swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk --disable-sandbox --disable-keychain --disable-netrc --cache-path .build/unify-cache --config-path .build/config --security-path .build/security
```

- Debug 构建通过。
- 最终全量测试：**209 项 / 17 套件，通过 209、失败 0、跳过 0**。原 196 项测试全部保留；新增 13 项，覆盖迁移、幂等、冲突、钥匙串失败重试、旧身份、凭据权限 / 链接、独立授权、脱敏 / 诊断最小化、签名失败阻断、离线预览、首次凭据错误可见性。未使用测试筛选或跳过。
- 预览入口实际运行成功，输出 `mac-panel.png`（760×2000）、`mac-menubar.png`（409×56）、`mac-error.png`（760×700），已逐张检查画面。演示数据 Codex 72%、Grok Bot 55%、Claude 40% 和 DeepSeek 出错；不启动菜单栏、迁移或账户读取。ImageRenderer 不能渲染 ScrollView 内层时，开发预览直接渲染同一组卡片；正式界面滚动不变。
- `zsh -n`、Info.plist / 两个本地化 strings 的 plutil 检查、git diff --check 通过。
- CLT 链接仍提示两个不存在的 Developer 搜索目录，不影响测试通过。
- 构建与测试日志：`.build/review-logs/build-unify.log`、`test-unify.log`。打包日志：`package-unify.log`。预览输出：`.build/preview/`。

打包验收：`zsh build.sh --disable-sandbox --disable-keychain --disable-netrc --cache-path "$PWD/.build/unify-cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"` 通过；生成 `dist/AI SubGauge.app` 与 `dist/AI SubGauge.zip`。`codesign --verify --deep --strict` 通过，读回 `Signature=adhoc`、`Identifier=com.mike.aisubgauge`、`CFBundleExecutable=AISubGauge`、`CFBundleShortVersionString` 为当时的初始开源版本，ZIP 根目录为 AI SubGauge.app，内含 LICENSE 和第三方声明。

`zsh package-dmg.sh` 已实际运行，但 **DMG 生成失败 1 次**：hdiutil 返回“设备未配置”，当前受限环境不能创建磁盘映像；脚本的新文件名、版本、卷名和安装说明已更新，解压及签名检查已通过。未安装、挂载或要求提权。日志 `.build/review-logs/dmg-unify.log`。

第一次 Release 的 dSYM 生成受沙箱限制，分发脚本现使用 `-debug-info-format none`。随后路径检查拦下了开发预览源码绝对路径；已改用 bundle / 当前目录离线资源，不再把 #filePath 编入 Release。修复后重跑完整测试与 Release 打包通过；失败材料保留，不删除缓存。

## Mac 版相对 Windows 版不如之处（只对照，不改）

以 Windows 当前 `src/AISubGauge/` 源码与 README 最后的 0.6.x 更新说明为准，不采用 README 中更早已被后续记录替代的图标描述。

- Mac 将多家合并在一个 AI 用量状态项，Windows 每家独立 NotifyIcon，可分别安排位置和可见性。
- Mac 是图标加数字百分比，尚无 Windows 的裁去透明边缘、logo 零内边距占满图标的统一策略。
- Mac 尚无从下往上、10% 一档、随剩余量变色的液位图标。
- Mac 的 Grok Bot 使用已安装应用图标或离线 xAI logo，没有 Windows 的透明 Bot 头像自身作为液位蒙版、深色眼睛及无背板绘制。
- Mac 的订阅读取集中于 Codex、Grok、Claude；没有 Windows 的 Gemini CLI OAuth、GitHub Copilot、Kimi Code、GLM / z.ai Coding Plan 订阅配额。现有 Gemini API / Kimi API 不等同这些订阅接入。
- Mac 没有 Windows 的 `--status` 无界面 JSON / stdout 状态输出；本次只添加用户要求的 `--render-preview`。
- Mac 没有 Windows 面向各家、多档余量、多种像素尺寸的完整图标批量预览。

“图标不画演示角标”和“不显示‘真实数据’标签”两点，Mac 现有界面已经符合，不能列为劣势。Mac 保留官方接口 / 缓存 / 刷新失败等来源与状态说明。本轮不为对齐 Windows 改动这些 UI。

## 改动文件

共 40 个文件。

- `AI_SUPPORT.md`
- `Fixtures/fixture.sh`
- `LICENSE`
- `PRIVACY.md`
- `Package.swift`
- `README.en.md`
- `README.md`
- `Resources/Info.plist`
- `Resources/en.lproj/InfoPlist.strings`
- `Resources/zh-Hans.lproj/InfoPlist.strings`
- `Sources/TidyBar/AIUsage.swift`
- `Sources/TidyBar/AIUsageMenuBar.swift`
- `Sources/TidyBar/AIUsagePopover.swift`
- `Sources/TidyBar/APIAccountConnection.swift`
- `Sources/TidyBar/App.swift`
- `Sources/TidyBar/AppMigration.swift`
- `Sources/TidyBar/CredentialFiles.swift`
- `Sources/TidyBar/Diagnostics.swift`
- `Sources/TidyBar/GrokBuildConnection.swift`
- `Sources/TidyBar/GrokBuildUsageSource.swift`
- `Sources/TidyBar/GrokCLITrust.swift`
- `Sources/TidyBar/GrokUsageSource.swift`
- `Sources/TidyBar/LegacyIdentifiers.swift`
- `Sources/TidyBar/MenuEngine.swift`
- `Sources/TidyBar/Models.swift`
- `Sources/TidyBar/PreviewRenderer.swift`
- `Sources/TidyBar/ProviderLoginConsent.swift`
- `Sources/TidyBar/SettingsView.swift`
- `Sources/TidyBar/Widgets.swift`
- `THIRD_PARTY_NOTICES.md`
- `Tests/TidyBarTests/EngineTests.swift`
- `Tests/TidyBarTests/GrokBuildUsageTests.swift`
- `Tests/TidyBarTests/SecurityTests.swift`
- `Tests/TidyBarTests/UnificationTests.swift`
- `build.sh`
- `docs/MIGRATION.md`
- `docs/OPEN_SOURCE_PREP.md`
- `docs/UNIFICATION_REPORT.md`
- `package-dmg.sh`
- `render-preview.sh`
