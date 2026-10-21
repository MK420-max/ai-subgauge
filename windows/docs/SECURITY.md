# 本地文件与启动登记

Codex 启动 CLI 前还会通过打开的目录句柄校验凭据所在目录（`CODEX_HOME` 或默认 `%USERPROFILE%\.codex`）的 owner/DACL。owner 仅允许当前用户、SYSTEM、Administrators；作用于目录的非受信 allow ACE 不得包含任何文件/子目录创建、属性写入、删除、删除子项、修改权限、取得所有权、`GENERIC_WRITE` 或 `GENERIC_ALL` 位，继承 ACE 同样检查，不能以 deny ACE 抵消。NULL DACL、未知授权语义或查询失败均拒绝。目录只读/遍历权限不因此被拒绝，包括默认目录上的 `CodexSandboxUsers` `ReadAndExecute | Synchronize`；凭据文件仍单独执行下述严格组校验。即使文件不存在，已存在的目录也须先通过校验，API key 不绕过不安全目录。

从校验直到整个 CLI 作业清空，应用持续持有凭据文件以及从盘符根至凭据目录的全部目录句柄；逐级拒绝 reparse point/junction，并核对句柄实际路径。文件和目录仅共享 `FileShare.Read | FileShare.Write`，不含 `FileShare.Delete`，阻止删除/重命名替换，同时允许 CLI 原地刷新写回。已核对官方 [Codex 0.162.1 的 `FileAuthStorage::save`](https://github.com/openai/codex/blob/rust-v0.162.1/codex-rs/login/src/auth/storage.rs#L215)：使用 truncate/write/create 后 flush，不使用 rename 原子替换，因此保留文件锁；该判断来自源码检查，尚未在 Windows 实机验证官方 CLI 刷新。若将来 CLI 改为原子替换，须重新评估兼容性。ACL 校验仍不能隔离当前用户或管理员主动改权/原地写入。

`auth.json` 或凭据目录不存在时，一律视为本机未登录，即使设置了 `OPENAI_API_KEY` 也不启动 CLI、不创建文件或目录，并提示先用官方 `codex login` 选择 ChatGPT 账号登录。因此不存在由本应用启动 CLI 新建凭据、先暴露继承 ACL 再于退出后检查的窗口，也不再执行“退出后校验新建凭据”的逻辑；已有文件及目录仍须通过原有校验。

CLI 使用 `CreateProcessW(CREATE_SUSPENDED)` 创建，先加入设置了 `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` / `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的匿名 Windows Job Object，再 `ResumeThread`，避免加入作业前生成子进程。只允许继承三个标准流管道句柄，作业和凭据锁句柄均不继承，且不启用 breakaway。正常返回、取消、超时和清理错误都通过 `TerminateJobObject` 清理整个作业；只有 `QueryInformationJobObject(JobObjectBasicAccountingInformation)` 返回 `ActiveProcesses == 0`，且根进程句柄已发出退出信号后，才释放凭据与目录锁。即使根进程先退出，子进程仍由作业管理；`Process.Kill(entireProcessTree: true)` 与只等待根进程退出不能替代此确认。作业行为参照微软 [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)。

前台清理最多等待 2 秒。若终止、查询或等待失败/超时，返回固定失败信息（调用方取消仍传播取消），把作业、进程、标准流与凭据/目录句柄一起交给后台任务；后台先接管尚未完成的前台清理，再以每轮最多 2 秒、失败间隔 1 秒重试，直到确认空作业后释放。查询失败绝不视为空作业。加入作业失败时，CLI 尚未恢复执行，清理会终止该挂起根进程并确认退出。关闭最后一个作业句柄还会触发整组终止，作为应用意外退出时的兜底。上述新作业路径已做静态自查，仍须在 Windows 实机运行下述测试验证。

`CodexCredentialPathTests` 使用合成凭据与私有目录，覆盖成功、取消、超时、父进程先退出、等待异常，以及用屏障和可注入前台超时确定性触发后台移交；子进程独立保持存活，不依赖父进程标准输入。测试检查子进程存活时文件及目录仍无法重命名，清理完成时子进程必须已经退出，随后才允许重命名。缺少凭据的测试同时覆盖 API key 有/无，断言 CLI 未启动、文件未创建及服务层显示登录提示。

所有服务的凭据文件都要求当前用户拥有，拒绝 NULL DACL 和非预期主体的数据读取、写入、删除、权限/所有者修改 ACE。SYSTEM 和 Administrators 为预期管理主体；Codex 另有下述沙箱组只读例外。Grok 的续期修复仍只针对当前用户拥有的文件。

仅 Codex 专用打开流程显式传入 `CredentialKind.Codex` 和打开文件时使用的同一个 `CredentialFiles.CodexPath`，且该路径经严格本地绝对路径校验、规范化、去尾斜杠后，与默认 `%USERPROFILE%\.codex\auth.json` 大小写不敏感地完全相等，才启用 `CodexSandboxUsers` 例外。`CODEX_HOME` 指向其他目录、路径缺失或路径校验失败时，均保留严格校验。必须同时满足：

- 先用 [DsRoleGetPrimaryDomainInformation](https://learn.microsoft.com/en-us/windows/win32/api/dsrole/nf-dsrole-dsrolegetprimarydomaininformation) 查询本机角色；只有独立/成员工作站或独立/成员服务器可继续。BackupDC、PrimaryDC、未知角色或查询失败均拒绝例外。域控制器的 `PolicyAccountDomainInformation` 可能返回主域，不能作为本机账户域的证明。
- 排除域控制器后，ACE 的 SID 域部分须等于本机账户域 SID；后者通过本机 LSA 的 [PolicyAccountDomainInformation](https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/nf-ntsecapi-lsaqueryinformationpolicy) 获取，不使用当前登录用户的域 SID 或加入的域 SID。[LookupAccountSidW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupaccountsidw) 须将该 SID 解析为名为 `CodexSandboxUsers` 的本机组（`SidTypeAlias` 或同一本机账户域的 `SidTypeGroup`）。
- [NetLocalGroupGetMembers](https://learn.microsoft.com/en-us/windows/win32/api/lmaccess/nf-lmaccess-netlocalgroupgetmembers) 在本机以 level 0 完整枚举成员 SID，包括后续分页；成员必须恰好两个且 SID 不同，分别解析为 `CodexSandboxOffline` 和 `CodexSandboxOnline`。两者均须为 `SidTypeUser`，SID 域部分均等于本机账户域 SID。仅名称相同的域组、域账号或其他本机组不获放行。
- 作用于当前文件的组 allow ACE（包括继承 ACE）只能包含 `ReadData`、`ReadExtendedAttributes`、`ReadAttributes`、`ReadPermissions`、`ExecuteFile`、`Synchronize` 及 `GENERIC_READ`/`GENERIC_EXECUTE`。任何额外位均拒绝，包括 `WriteData`、`AppendData`、`WriteAttributes`、`WriteExtendedAttributes`、`Delete`、`DeleteSubdirectoriesAndFiles`、`ChangePermissions`、`TakeOwnership`、`GENERIC_WRITE` 和 `GENERIC_ALL`；不能靠另一个 deny ACE 抵消写权限来放行。

保留 `ExecuteFile` 和 `GENERIC_EXECUTE`，因为实机继承 ACE 为 `ReadAndExecute | Synchronize = 0x1200A9`，其中包含 `ExecuteFile = 0x20`。对普通凭据文件，该位不授予写入、删除或改权能力；[FILE_EXECUTE](https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants) 与文件写入权限是不同的权限位。去掉它会误拒绝现有沙箱 ACL。

所有服务均直接遍历 `RawSecurityDescriptor.DiscretionaryAcl` 中的每个 `GenericAce`，按 `QualifiedAce.AceQualifier == AccessAllowed` 检查继承自 `KnownAce` 的 SID 和 AccessMask，覆盖 `CommonAce`、`ObjectAce` 及其 callback 变体；不使用只投影部分 ACE 的 `GetAccessRules`。无法识别授权语义的 `CustomAce`、`CompoundAce` 等作用于当前文件时直接拒绝。已识别的 deny ACE 不作为抵消 allow 权限的依据；inherit-only ACE 不作用于当前文件。

任一身份、成员或权限条件不符，或任一步查询失败/返回不完整信息，即拒绝。每次校验重新查询，不缓存可信组结果。组检查通过可注入的 `ILocalGroupInspector` 执行；生产实现调用 Win32 API，测试只使用合成 `RawSecurityDescriptor`/`FileSecurity` 与假实现。

残余风险：`CodexSandboxOffline` 和 `CodexSandboxOnline` 可读取 Codex 令牌，这是 Codex 自身的 Windows 沙箱设计。此例外接受这两个账号的读取能力，不隔离其中已被控制的代码；组成员与 ACL 校验是当次快照，不能阻止之后的管理员修改。应用不修改 Codex 凭据内容、所有者或 ACL；`CheckAfterRefresh` 的 DACL 修复仍仅用于 Grok，其他服务保留原有检查。

Run 键只允许登记 `%LOCALAPPDATA%\Programs\AISubGauge` 内的 `AISubGauge.exe`。打开时拒绝链接/reparse point，并持有文件和全部父目录句柄直到登记完成。使用 [GetSecurityInfo](https://learn.microsoft.com/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo) 读取这些句柄的 owner/DACL；只信任当前用户、SYSTEM、Administrators 和 TrustedInstaller 的写权限。安装根目录及其内部拒绝非预期写入 ACE；安装根以上的祖先拒绝替换既有组件的能力（delete-child/delete、owner/DACL/属性修改及 generic write/all），允许只创建新兄弟文件/目录的权限。继承的 allow ACE 同样检查；inherit-only ACE 不作用于当前对象。

便携副本、共享可写安装、无法验证权限的文件不会登记；正常界面启动仍可继续。ACL 是登记时的校验，不能阻止当前用户之后主动放宽自己的目录权限，也不隔离已控制当前用户的恶意代码。

新安装校验失败时，清除本程序认得的旧启动命令，避免继续运行不受保护的旧副本。只检查 `AISubGauge`、`WindowsQuotaTray` 两个值名；命令须为没有附加参数的绝对路径。`AISubGauge` 值只识别本程序的 `AISubGauge.exe` 或 `WindowsQuotaTray.exe`，旧 `WindowsQuotaTray` 值只识别 `WindowsQuotaTray.exe`。其他值名或不匹配的命令保持原样。迁移失败仍移除匹配的旧值，不登记新命令。

测试可向内部 API 注入私有祖先截止点；该目录本身接受完整安装 ACL 校验，其下全部组件仍受检查，且截止点以上的路径仍逐级持有句柄并拒绝 reparse point。生产调用不提供截止点，始终从磁盘根开始验证全部祖先。测试覆盖 `C:\` 对 Authenticated Users 的 AppendData 与 inherit-only Modify 组合；它不授予修改既有根目录组件的权限。

Grok 子进程环境强制 `GROK_LOG_FILE=NUL`、`RUST_LOG=off`，不继承外部值。凭据、配置和共享资源边读边限额；诊断预览、导出及状态错误文本会脱敏 SSID、坐标和已有的凭据标识。Windows 设置模型目前不存储 SSID/坐标，也没有设置导出入口。

Grok 自检与正式续期都用 CreatePrivateDirectory 创建私有工作目录，创建时即设置受保护的 owner-only DACL，防止继承 `%TEMP%` 中其他用户或本机组的 Modify ACE；自检的合成文件在目录创建后才写入。FakeGrokCli 的白名单包含两个强制日志变量，并检查它们的固定值以及自检目录的 owner 和受保护 DACL；成功、宽 ACL、超时和取消模式保持各自的行为。

## Windows 验证与 NuGet 锁文件

三个项目均已有 Windows 生成的 `packages.lock.json`（应用、AISubGauge.Tests、FakeGrokCli）。`windows/Directory.Build.props` 同时启用 RestorePackagesWithLockFile 与默认值为 true 的 RestoreLockedMode；本地和 CI 的普通 restore 都按现有锁文件恢复，依赖不一致即失败。请在 Windows 仓库根目录执行：

```powershell
dotnet restore windows/AISubGauge.sln --locked-mode
dotnet build windows/AISubGauge.sln -c Release --no-restore
dotnet test windows/tests/AISubGauge.Tests/AISubGauge.Tests.csproj -c Release --no-build
```

只有有意更新依赖时才用 `dotnet restore windows/AISubGauge.sln -p:RestoreLockedMode=false --force-evaluate` 重新生成锁文件，并审阅三个项目的锁文件差异。普通构建和 CI 不禁用锁定模式。测试仅使用合成文件、隔离设置目录和临时 HKCU 子键，不访问真实凭据或 Run 键。本轮在 macOS 自查 Windows 源码，Windows 原生测试仍需实机复验。
