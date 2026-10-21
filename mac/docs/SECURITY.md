# 本地 CLI 与文件安全边界

防护目标是只执行 OpenAI 签名的 Codex CLI，并拒绝其他用户、路径搜索或非签名文件替换所选 CLI。以当前用户身份运行的恶意进程不在本应用能够提供的 macOS 用户隔离边界之内：同 UID 进程本就能直接读取 `~/.codex/auth.json`、修改该用户可写的任何文件，并向本用户的进程发送信号。本应用不使用特权辅助程序或额外 entitlement 建立新的隔离主体。

Codex 只从固定入口发现官方 Developer ID Mach-O。ChatGPT.app 内的 CodexCLI.app 必须整包复制到 mkdtemp 创建的 0700 私有根目录；校验注入只替换验签动作，不影响整包/单文件分支。副本内的符号链接必须解析在该根目录内。

复制完成后清除副本扩展 ACL，目录及可执行文件收紧为 0500，普通资源为 0400，再对副本执行一次 strict、all architectures、nested code 的完整签名校验。保留可执行文件 fd、设备号、inode、大小、修改/状态时间和 cdhash；默认 slice 的 cdhash 来自通过校验的同一 SecStaticCode 对象。多架构文件从 fd 中读取有上限的 slice 索引，通过 SecCodeCopySigningInformation 记录各 slice 的 cdhash，并在完整验签后再次比对。紧邻 posix_spawn 之前对持有 fd 和路径重新比较身份、大小、时间、模式及新的签名信息。

posix_spawn 执行的是上述 0500 目录中的已验证副本，并通过 POSIX_SPAWN_START_SUSPENDED 创建进程。再用 SecCodeCopyGuestWithAttributes 按仍未回收的子进程 PID 取得动态 SecCode，以静态校验所用的同一 OpenAI requirement 与已验证的 slice cdhash 集合共同约束映像，执行 SecCodeCheckValidity（kSecCSDefaultFlags）。通过后本应用才发送 SIGCONT；失败立即 SIGKILL 整个进程组并 waitpid。动态校验通过且 CLIProcess 初始化成功返回前，stdin 管道保持为空，不写入任何请求。PID 在检查期间由本父进程持有，不能被回收重用。测试注入只用于合成 fixture；生产入口始终同时启用静态和动态 OpenAI 校验。

残余风险：0500/0400 不能隔离同 UID 进程，文件所有者仍可恢复写权限并在路径检查与执行之间替换副本；外部同 UID 进程也能抢先发送 SIGCONT，因此不能保证动态校验前子进程绝无代码执行。签名、映像身份复核和空 stdin 门控缩小风险，不能全面抵御同 UID 的调试/注入、信号攻击、exec 映像切换，或稍后加载的动态库/资源被替换。即使不经过本应用，该恶意进程也已有上述凭据与文件访问能力。参见 [Apple 动态代码查询接口](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)) 与 [动态校验接口](https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:))。

清理时先恢复副本目录的 owner 写权限，不跟随符号链接；删除后用 lstat 确认整个临时根目录消失。删除失败或不能确认消失时写入 OSLog 错误，cleanup 返回 false，不静默报告成功。不会在日志输出凭据或 CLI 输出。

凭据读取在同一 fd 上检查普通文件、当前所有者、POSIX 权限和扩展 ACL。任何非 owner 的 allow ACE 授予数据读取、写入或权限/所有者修改能力都会拒绝（即使另有 deny ACE）。没有扩展 ACL 时继续检查 POSIX 权限。文件按块读取，最多读取上限加 1 字节；设置文件上限 5 MB，凭据及共享资源 1 MiB，Grok Bot 标记/缓存 256 KB。磁盘元数据检查不能替代读取过程中限额。

设置导出会清空天气城市、坐标及 Wi-Fi 条件，关闭对应天气组件和 Wi-Fi 自动化规则；本机保存仍保留原设置。诊断在预览和导出前递归脱敏 SSID/坐标键及文本中的相应字段。
