# AI SubGauge 2.0.0 迁移方案

## 标识与入口

显示名统一为 AI SubGauge，版本为 2.0.0；SwiftPM 产物和 bundle 内可执行文件为 AISubGauge，源代码模块保留 TidyBar。新 bundle ID 为 `com.mike.aisubgauge`，API 钥匙串服务为 `com.mike.aisubgauge.api`。

旧域为 `com.mike.menubartidy`，旧 API 服务为 `com.mike.menubartidy.api`。运行时代码的旧标识集中在 `Sources/TidyBar/LegacyIdentifiers.swift`，仅用于兼容读取。菜单栏主入口、AI 用量、留白、分组、小组件的 autosave 与可访问性标识均使用新前缀。

普通启动时，在 SettingsStore、菜单栏及用量刷新之前调用 AppMigration。DEBUG 构建中的 `--render-preview <dir>` 在创建 AppDelegate 之前分流，完全跳过迁移、真实 defaults、钥匙串和凭据读取。

## 三阶段复制

1. **UserDefaults**：读取旧域的持久化字典，所有键原样复制到新域；新域已有键优先。AppKit 的 `NSStatusItem Preferred Position …` / 可见性键中的旧前缀另复制一份新前缀键，旧键保留。已有新前缀键不覆盖。设置文件读取时将 rules、order、presets 中的旧身份映射为新身份，冲突时新规则优先，顺序去重；加载不改写旧文件或源文件。
2. **Application Support**：递归合并 `~/Library/Application Support/com.mike.menubartidy` 到 `~/Library/Application Support/com.mike.aisubgauge`。只复制缺失的普通文件、递归合并目录；已有目标文件或类型冲突保留目标。为避免越界读取，不跟随或复制符号链接。旧目录完整保留；新建私有目录为 0700，后续应用写入为 0600。原文件字节不改动。
3. **钥匙串**：只查询旧服务下本应用已知 API provider 的 generic-password 项，不枚举其他应用或订阅登录。新服务已存在的项优先；缺失项用 SecItemAdd 复制，重复项视为已存在，绝不更新或删除旧项。不允许弹出认证交互；锁定或权限不足等失败只显示不含密钥的提示，不阻塞应用启动。

各阶段成功后分别在新域写入 `migration.aisubgauge.v1.defaults/files/keychain` 标记。已成功阶段不再运行；失败阶段下次启动重试。文件复制中途失败后重试也不会覆盖已复制文件。钥匙串失败不会阻止设置或目录迁移。测试注入独立 defaults suite、临时目录及 MigrationKeychain mock，绝不访问真实凭据。

## 用户选择与系统权限

### ad hoc 签名与旧钥匙串授权

`build.sh` 保留 ad hoc 签名，但不再指定仅检查 identifier 的 designated requirement（DR）。codesign 自动生成绑定本次构建 cdhash 的默认 DR；同 identifier 的另一个二进制不能满足这个新 DR。后续二进制或密封资源改变时，cdhash 也会改变。

`APIAccountCredentials`（API 密钥存储）和 `SystemMigrationKeychain` 使用系统默认的 SecItem 权限，不创建或匹配自定义 DR，也不绕过钥匙串 ACL。新建项目由系统记录当前应用身份。升级后读取旧项目可能需要用户重新授权；非交互迁移遇到权限不足仍失败并保留旧项目。

已有项目的 trusted application ACL 不会因新版本改用 cdhash 自动收紧：若旧 ACL 仍只绑定 identifier，它可能继续允许访问而不弹窗。建议在“钥匙串访问”中只处理 AI SubGauge 自己的 API 项目，检查并移除旧的宽松应用授权后重新授权当前可信构建，或手动删除这些旧项目再在应用中重新连接。应用不会自动删除凭据或放宽访问权限。以后每次 ad hoc 构建的 cdhash 改变，都可能再次要求授权。

三家本机登录复用许可分别存为 `loginReuse.consent.codex`、`.claude`、`.grok`。旧版本没有这些授权，迁移不会把“已连接”当作同意，默认关闭。API key 迁移与自动复用其他应用登录是两个独立流程。

新 bundle ID 和签名身份可能使辅助功能授权、位置访问书签或登录项需要重新确认。程序不替用户修改系统权限，也不自动注册新登录项或注销旧登录项。现有“登录时启动”开关继续由 SMAppService 报告实际状态。升级前退出旧应用；如旧登录项仍存在，请在系统设置手动停用。

## 回退

退出 AI SubGauge 后，可重新使用原版本及原域、原目录、原 API 钥匙串项。新版本的后续更改不会反向同步到旧版本。本轮不安装、不启动旧版或正式版，也不调用真实账户来验收迁移。
