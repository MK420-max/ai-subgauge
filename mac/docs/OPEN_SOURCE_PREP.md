# 开源前准备记录

本文为改名前 1.1.1 的历史验收记录；其中名称、标识、许可证版权人与凭据权限策略已由 [AI SubGauge 初始开源版历史统一报告](UNIFICATION_REPORT.md) 和 [迁移方案](MIGRATION.md) 中的新实现替代。

日期：2026-10-20。本轮复审已完成。全部测试已迁移到 Swift Testing；使用本机 macOS 26.5 SDK 构建成功，196 个测试全部通过，0 失败、0 跳过。未改变用户可见功能。

## 实施范围

- 提取 CLI 环境白名单、重定向阻断器和私有文件写入辅助代码，保留现有界面与业务流程。
- Claude OAuth 使用 ephemeral 会话，禁用 Cookie、缓存和凭据存储，阻断重定向并核对最终响应的 host 与完整 URL。
- Codex 仅传递本机运行变量与 `CODEX_HOME`；Grok 登录和续期共用环境白名单，仅保留必要的本机凭据位置，固定官方 issuer，关闭遥测和日志。续期仍使用经验证的同一账户和客户端标识。
- 私有目录为 0700，设置、诊断、布局事务、拖动记录、位置备份及导出文件写入为 0600。写入先建立 0600 临时文件，再同目录原子替换；用户选择的导出目录权限保持不变。加载已有 settings.json 时收紧宽于 0600 的权限，并将其目录设为 0700；已为 0400 的设置文件不放宽。加载期间抑制自动保存，保留原文件内容及修改时间，损坏文件也先收紧权限并保留。
- 位置访问诊断以及 App.swift 总诊断中的错误文本用 `~` 替换当前家目录；总诊断在序列化前递归处理字符串，覆盖 lastError、AI 用量及嵌套诊断错误。Claude 凭据打开后检查普通文件类型、当前用户所有、组/其他用户不可写，以及 1 MiB 上限；拒绝符号链接并限制实际读取大小。不存在的凭据文件（ENOENT）才静默返回空值；已有文件的读取或安全检查错误向上传递，保留具体提示。原有权限阈值不变，仍允许 0644。
- 重写中英文 README，去掉个人发布账号、旧发布链接和未经本次验证的验收声明；测试中的 Wi-Fi 名称改为中性示例。构建、测试、打包及手工测试图标产物均放在仓库内。
- 添加 MIT LICENSE，版权人为 The mac-menu-bar-tidy contributors；应用打包时一并附带。原有桥接和 Logo 第三方许可证及 THIRD_PARTY_NOTICES.md 内容保持不变，已核对 SHA-256。
- `.gitignore` 已覆盖全部指定凭据、诊断、密钥、Cookie、证书和构建目录规则。
- Tests/TidyBarTests 全部改为 import Testing、@Suite、@Test、#expect 和 #require，移除 XCTest 依赖。用一个串行父套件维持涉及全局状态测试的隔离；异步信号保留原有超时，通知测试保留次数与失败时不发通知的断言。
- test.sh 透传参数；中英文 README 与脚本注释将 `--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 列为默认 27.0 SDK 缺 SwiftUIMacros 时的可选变通，不降低最低系统要求。移除 DMG 安装说明中未经验证的 macOS 27 实测声明。

## 依赖结论

`Package.swift` 无外部包依赖，保持现状。保留 `MenuBarShim` 的 `unsafeFlags(["-fobjc-arc"])`：桥接使用 Objective-C 对象与复制的回调，没有手动 release；直接去掉 ARC 会改变内存管理行为，不能作为无功能变化的清理。未为规避 unsafeFlags 引入额外构建层。本机 CLT 的默认 Swift Build 后端未自动发现已安装的 TestingMacros；Package.swift 仅在该插件存在时为测试目标添加 `-plugin-path`，不影响应用目标。

## 验证结果

- 原有 189 个测试方法全部保留并逐一核对 @Test 标记。SecurityTests 从 21 个增加到 28 个，新增 7 个回归测试：总诊断嵌套脱敏、已有设置权限与内容/时间保持、更严格权限保持、损坏设置保留、Claude 缺失文件提示、不安全文件具体提示，以及 0644 与环境变量优先级。
- `swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`：通过。目标仍为 arm64、macOS 27.0；Swift 6.4，默认 Swift Build 后端。未修改最低系统要求。
- `swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`：196 个测试、16 个套件全部通过，0 失败、0 跳过；最终执行耗时 6.081 秒。Testing Library Version 2084。此前 XCTest 缺失造成的编译阻塞已解除。
- 音乐曲目快照测试保留单次读取、同一快照取名称/艺人及系统编译检查，并增加原脚本目标为 com.apple.Music 的断言。沙盒内 LaunchServices 按 bundle ID 查找失败（-1728），编译检查显式绑定同一台 Mac 的 `/System/Applications/Music.app`；不改应用脚本，不启动 Music 或执行 Apple events。
- 测试链接仍有两条 CLT 搜索目录不存在的警告（Developer/usr/lib、Developer/Library/Frameworks），未影响构建或测试通过。
- 构建、测试、DMG 与手工测试脚本通过 `zsh -n`；本地文档链接有效。未连接真实账户或网络，未下载依赖。
- 上一轮独立安全校验的 32 项通过记录保留在 `.build/prep-audit/`；本轮以完整 Swift Testing 套件为验证依据。

受当前执行沙盒限制，验证时将缓存及临时文件放到仓库内，并关闭 SwiftPM 子进程沙盒；未改变主机权限。实际成功命令如下：

```sh
mkdir -p .build/ModuleCache .build/tmp
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
TMPDIR="$PWD/.build/tmp" \
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security

CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
TMPDIR="$PWD/.build/tmp" \
swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security
```

本轮日志：`.build/review-logs/build-final.log`、`.build/review-logs/test-final.log`。原文件快照及中英文说明的翻译/审阅材料也只保留在被忽略的 `.build/` 内；这些材料含本机路径，不应发布。

## 累计改动文件清单

| File | Change |
| --- | --- |
| [.gitignore](../.gitignore) | Modified |
| [Fixtures/fixture.sh](../Fixtures/fixture.sh) | Modified |
| [LICENSE](../LICENSE) | Added |
| [PRIVACY.md](../PRIVACY.md) | Modified |
| [Package.swift](../Package.swift) | Modified |
| [README.en.md](../README.en.md) | Modified |
| [README.md](../README.md) | Modified |
| [Sources/TidyBar/AIUsage.swift](../Sources/TidyBar/AIUsage.swift) | Modified |
| [Sources/TidyBar/APIUsageSource.swift](../Sources/TidyBar/APIUsageSource.swift) | Modified |
| [Sources/TidyBar/App.swift](../Sources/TidyBar/App.swift) | Modified |
| [Sources/TidyBar/CLIEnvironment.swift](../Sources/TidyBar/CLIEnvironment.swift) | Added |
| [Sources/TidyBar/GrokBuildConnection.swift](../Sources/TidyBar/GrokBuildConnection.swift) | Modified |
| [Sources/TidyBar/GrokBuildUsageSource.swift](../Sources/TidyBar/GrokBuildUsageSource.swift) | Modified |
| [Sources/TidyBar/MenuEngine.swift](../Sources/TidyBar/MenuEngine.swift) | Modified |
| [Sources/TidyBar/Models.swift](../Sources/TidyBar/Models.swift) | Modified |
| [Sources/TidyBar/NoUsageRedirects.swift](../Sources/TidyBar/NoUsageRedirects.swift) | Added |
| [Sources/TidyBar/PrivateFiles.swift](../Sources/TidyBar/PrivateFiles.swift) | Added |
| [Tests/TidyBarTests/AutomationTests.swift](../Tests/TidyBarTests/AutomationTests.swift) | Modified |
| [Tests/TidyBarTests/GrokBuildUsageTests.swift](../Tests/TidyBarTests/GrokBuildUsageTests.swift) | Modified |
| [Tests/TidyBarTests/AIUsageTests.swift](../Tests/TidyBarTests/AIUsageTests.swift) | Modified |
| [Tests/TidyBarTests/APIAccountIntegrationTests.swift](../Tests/TidyBarTests/APIAccountIntegrationTests.swift) | Modified |
| [Tests/TidyBarTests/APIUsageTests.swift](../Tests/TidyBarTests/APIUsageTests.swift) | Modified |
| [Tests/TidyBarTests/AppearanceTests.swift](../Tests/TidyBarTests/AppearanceTests.swift) | Modified |
| [Tests/TidyBarTests/ClaudeWebConnectionTests.swift](../Tests/TidyBarTests/ClaudeWebConnectionTests.swift) | Modified |
| [Tests/TidyBarTests/EngineTests.swift](../Tests/TidyBarTests/EngineTests.swift) | Modified |
| [Tests/TidyBarTests/GrokBillingRetryTests.swift](../Tests/TidyBarTests/GrokBillingRetryTests.swift) | Modified |
| [Tests/TidyBarTests/GrokBuildConnectionTests.swift](../Tests/TidyBarTests/GrokBuildConnectionTests.swift) | Modified |
| [Tests/TidyBarTests/GrokUsageTests.swift](../Tests/TidyBarTests/GrokUsageTests.swift) | Modified |
| [Tests/TidyBarTests/MenuScannerRegressionTests.swift](../Tests/TidyBarTests/MenuScannerRegressionTests.swift) | Modified |
| [Tests/TidyBarTests/SettingsTests.swift](../Tests/TidyBarTests/SettingsTests.swift) | Modified |
| [Tests/TidyBarTests/WidgetTests.swift](../Tests/TidyBarTests/WidgetTests.swift) | Modified |
| [Tests/TidyBarTests/SecurityTests.swift](../Tests/TidyBarTests/SecurityTests.swift) | Added |
| [Tests/TidyBarTests/TestSupport.swift](../Tests/TidyBarTests/TestSupport.swift) | Added |
| [build.sh](../build.sh) | Modified |
| [package-dmg.sh](../package-dmg.sh) | Modified |
| [test.sh](../test.sh) | Modified |
| [docs/OPEN_SOURCE_PREP.md](OPEN_SOURCE_PREP.md) | Added |

## 保留标识符位置

按要求未改 `com.mike.menubartidy`、钥匙串服务名 `com.mike.menubartidy.api` 及其相关兼容标识符。以下列出源码、测试、资源和脚本的全部直接出现位置，不含构建缓存及本报告的说明文字。

| File | Lines |
| --- | --- |
| [Fixtures/fixture.sh](../Fixtures/fixture.sh) | 13 |
| [Resources/Info.plist](../Resources/Info.plist) | 6 |
| [Sources/TidyBar/AIUsageMenuBar.swift](../Sources/TidyBar/AIUsageMenuBar.swift) | 126, 131, 132 |
| [Sources/TidyBar/APIAccountConnection.swift](../Sources/TidyBar/APIAccountConnection.swift) | 7 |
| [Sources/TidyBar/App.swift](../Sources/TidyBar/App.swift) | 197, 200, 312, 313, 320, 321 |
| [Sources/TidyBar/GrokBuildConnection.swift](../Sources/TidyBar/GrokBuildConnection.swift) | 96 |
| [Sources/TidyBar/GrokBuildUsageSource.swift](../Sources/TidyBar/GrokBuildUsageSource.swift) | 211 |
| [Sources/TidyBar/MenuEngine.swift](../Sources/TidyBar/MenuEngine.swift) | 47, 262, 293, 299, 963 |
| [Sources/TidyBar/Models.swift](../Sources/TidyBar/Models.swift) | 7, 214 |
| [Sources/TidyBar/SettingsView.swift](../Sources/TidyBar/SettingsView.swift) | 238, 325 |
| [Sources/TidyBar/Widgets.swift](../Sources/TidyBar/Widgets.swift) | 345, 346 |
| [Tests/TidyBarTests/EngineTests.swift](../Tests/TidyBarTests/EngineTests.swift) | 74, 75, 79, 80, 81 (x2), 82 (x4) |
| [build.sh](../build.sh) | 35 (x2) |

钥匙串服务常量位于 `Sources/TidyBar/APIAccountConnection.swift:7`，用于该文件第 71、86 行的查询属性。迁移时需同时考虑已有钥匙串项目、Application Support 设置/工具/备份目录、菜单栏 autosave 名称、可访问性标识符、内部通知及测试 fixture 标识。

## 未完成与需拍板事项

- 本机 CLT 与 26.5 SDK 的构建及完整测试已通过；默认 27.0 SDK 的 SwiftUIMacros 缺失仍需匹配工具链解决，26.5 SDK 仅作为可选变通。未下载工具或安装 Xcode。
- bundle id、钥匙串服务名及相关兼容标识符是否统一改名，需另行确定，并制定已有配置与凭据的迁移方式。
- 未运行真实账户登录/用量查询、真实菜单栏移动或辅助功能操作；未运行手工 fixture，未生成或安装 DMG，未执行 Developer ID 签名、公证或发布。
- 未执行 git init、push 或 rm；所有项目改动限于本目录。
