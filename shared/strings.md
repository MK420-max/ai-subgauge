# Shared UI strings

This table is the historical wording and formatting reference. The canonical runtime catalogs are now `i18n/en.json` and `i18n/zh-Hans.json`; Mac uses their shared flat keys and numbered placeholders. Windows can reuse the same catalogs in its next implementation pass. A failed request must retain its reason and a demo value must retain its demo label.

| Meaning | Chinese | English |
| --- | --- | --- |
| Panel title | 账户余量 | Account quota |
| Account count | 账户 {count} 项 | {count} accounts |
| Remaining quota | 剩余 {percent}% | Remaining {percent}% |
| Unknown value | — | — |
| Reset time | 重置：{yyyy年M月d日 HH:mm} | Resets: {local date and time} |
| Missing reset time | 重置：未提供 | Resets: Not provided |
| Updated time | 更新于：{yyyy年M月d日 HH:mm} | Updated: {local date and time} |
| Demo label | 演示数据 | Demo data |
| General error | 刷新失败：{原因} | Refresh failed: {reason} |
| Grok renewal error | Grok 令牌续期失败：{原因} | Grok token renewal failed: {reason} |
| Unsafe credential ACL | 凭据文件对其他用户可读，已拒绝读取；请收紧权限 | The credential file is readable by other users. Reading was refused; restrict its permissions. |
| Consent required | 尚未允许读取本机登录信息 | Local login access has not been allowed. |
| Permission question | 是否允许 AI SubGauge 读取 {家} 的本机登录信息？ | Allow AI SubGauge to read {provider}'s local login information? |
| Local login absent | 本机未登录 | Not signed in locally |
| Expired cache | 缓存已过期 | Cache expired |
| Refresh action | 刷新全部用量 | Refresh all usage |
| Time zone | 本机时区 | Local time zone |
| Autostart | 开机自启动 | Launch at login |
| Diagnostics | 导出诊断… | Export diagnostics… |
| Save preview | 保存 | Save |

Percentages show **remaining** quota, rounded to a whole number, with no space before `%`: `72%`, `55%`, `40%`. Unknown is `—`, never `0%`. Reset and update timestamps use the local time zone, a 24-hour clock and minute precision. Missing reset information is `未提供`; no date or relative duration is invented. Do not prepend `刷新失败：` to the already complete Grok renewal error.

The approved compact panel uses the order Codex, Grok, Claude, followed by API accounts. Its header uses the theme-specific app logo and a title the same size as provider names. Rows show a remaining-quota bar using shared `quota` colors and right-aligned percentage/reset text. Thin dividers separate rows; Settings and Refresh are equal-width rounded buttons in both themes. Demo/error text remains in each row's subtitle. `theme.json` supplies all colors, with matching light/dark keys. Existing provider tray gauges are unchanged. Windows runtime adoption is a later task.
