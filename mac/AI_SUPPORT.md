# AI 订阅与 API 支持

AI SubGauge 2.0.0。订阅配额与 API 计费分别显示；金额没有已知总额度时保留金额，不推算百分比。百分比只显示整数；接口未提供重置时间时显示“未提供”。

## 自动读取

| 服务 | 数据与凭据 | 边界与官方来源 |
| --- | --- | --- |
| Codex 订阅 | 已登录官方本机 app-server 的账户配额 | Codex 窗口并非 ChatGPT 对话额度；不发送模型请求。 |
| Claude 订阅 | 用户自行连接的 Claude 登录 | 沿用已支持的 OAuth / 独立网页会话；多组织明确选择。 |
| Grok 订阅 | 官方 Build / Bot 登录及只读 billing | 缓存沿用数据源原更新时间与失效时间；刷新不延长有效期。官方服务返回 502/503/504 时最多延迟重试一次，仍失败则保留连接并提示稍后刷新，不要求重新登录。 |
| DeepSeek API | 普通 API Key；账户总余额、币种 | [官方余额接口](https://api-docs.deepseek.com/api/get-user-balance/)。未提供总限额，不换算百分比。 |
| OpenRouter API | 普通 API Key；当前 Key 的 limit_remaining | [官方 Key 额度接口](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)。Key 限额与账户总余额独立；没有限额时不显示百分比，不用终身支出推算周期余额。 |
| Kimi API | 中国站 API Key；available_balance | [官方余额接口](https://platform.kimi.com/docs/api/balance)。人民币余额，允许按原值显示欠费；国际站、Kimi Code 订阅独立。 |
| MiniMax | 国际站 API / Token Plan Key | [官方 CLI 接口定义](https://github.com/MiniMax-AI/cli/blob/main/src/client/endpoints.ts)、[返回字段](https://github.com/MiniMax-AI/cli/blob/main/src/types/api.ts)。sk-api- 读取可用金额；币种未提供时不猜币种。Token Plan 仅信任明确的 remaining_percent 字段，旧 count 语义不明时不推算。中国站需官方账单。 |
| xAI API | 团队管理密钥及团队 ID | [官方团队 billing 接口](https://docs.x.ai/developers/rest-api-reference/management/billing)。需要相应只读管理权限，普通推理 Key 无法使用。 |

## 官方账单入口

| 服务 | 原因 |
| --- | --- |
| OpenAI API | [组织管理 API](https://developers.openai.com/api/docs/guides/admin-apis)提供组织用量与支出，需要管理员密钥。普通推理密钥无公开余额接口；本版提供官方账单入口。 |
| Anthropic API | [用量与费用 API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)属于组织管理员支出查询。普通推理密钥不提供预付余额；本版提供官方账单入口。 |
| Gemini | [Google 计费说明](https://ai.google.dev/gemini-api/docs/billing)。API 用量、项目预付余额与账单在 AI Studio 查看；本版尚未接入 Gemini 订阅或 Cloud Billing 身份验证。 |

## 安全与验证

- 可读取的 API 密钥仅在官方额度接口验证成功后保存至本机钥匙串。
- 不读取或扫描其他应用的 API 密钥；不把订阅 token 转发到 API 计费接口。
- 使用固定厂商 HTTPS 地址，禁止重定向，20 秒超时，最多读取 1 MB；不保存网络 Cookie 或响应缓存。
- 错误不包含密钥或服务器原始返回；移除连接会清空显示并取消请求。
- 新增解析、连接状态与安全边界已使用虚构数据测试。新增 API 厂商尚未使用用户真实密钥逐一验收，不能把自动测试等同于真实账户连通性。

## 2.0.0 登录复用与 Grok 执行校验

设置 → 通用提供 Codex、Claude Code、Grok 三个独立同意开关；默认关闭，未同意不读取该家的本机登录。Claude 独立官方网页登录由用户主动连接。任何凭据文件若 `mode & 0o044 != 0`，均拒绝读取并提示“请将该文件权限改为 600”。Codex 在调用官方 CLI 前检查其 auth.json；Claude 和 Grok 共用基于打开句柄的权限、类型、所有者、大小检查，拒绝符号链接。

Grok 保留官方 `login --oauth` 登录与 `agent stdio` 的 `initialize` / `_x.ai/auth/getBearerToken` 续期流程；只接受同一账户及 client ID 的续期结果。登录工具仅从官方 `https://x.ai/cli/` 下载，下载暂存文件先通过 `codesign --verify --strict -R`，再移入 Tools 目录；已安装及缓存工具在每次执行前同样校验。要求 Apple Developer ID 证书链、固定团队 `5Y6N3AJ54S` 与标识 `xai-grok-pager` 同时通过，路径限于指定安装位置或本应用 Tools，文件须由当前用户或 root 所有，组和其他用户不可写。签名校验失败不运行、不降级；团队或标识变更需审阅更新应用。官方安装入口参考 [xAI 官方源码说明](https://github.com/xai-org/grok-build/blob/main/README.md)；签名要求采用 [Apple Code Signing Requirement Language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)。本轮使用 mock 验证失败阻断；受终端网络限制，未下载官方二进制进行本机签名回验，也未测试真实续期。

续期失败经 AIUsageStore 进入 provider 错误状态，AI 用量卡片和弹出面板显示原因及重新连接提示。CLI stdout 的 bearer 返回值直接丢弃，stderr 不采集；令牌不进入诊断或日志。诊断入口位于设置 → 通用，必须先预览脱敏文本，确认后才允许复制或保存。
