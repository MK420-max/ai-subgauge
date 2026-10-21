using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using AISubGauge.Providers;
using Xunit;
using Xunit.Abstractions;

namespace AISubGauge.Tests;

public sealed class CodexCredentialPathTests : IDisposable
{
    private readonly string? _home = Environment.GetEnvironmentVariable("CODEX_HOME");
    private readonly string? _key = Environment.GetEnvironmentVariable("OPENAI_API_KEY");
    private readonly string? _exe = Environment.GetEnvironmentVariable("CODEX_EXE");
    private readonly ITestOutputHelper _output;
    private readonly string _parent;
    private readonly string _root;
    private readonly CodexProvider _provider = new();
    private string AuthPath => Path.Combine(_root, "auth.json");
    private string StartedPath => Path.Combine(_parent, "cli-started");

    public CodexCredentialPathTests(ITestOutputHelper output)
    {
        CodexProvider.ResetCleanupFaultForTest();
        _output = output;
        // Use the user profile so shared %TEMP% ACLs do not weaken or invalidate ancestor checks.
        _parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "aisubgauge-codex-test space-" + Guid.NewGuid().ToString("N"));
        CredentialAccess.CreatePrivateDirectory(_parent);
        _root = Path.Combine(_parent, "home");
        CredentialAccess.CreatePrivateDirectory(_root);
        Environment.SetEnvironmentVariable("CODEX_HOME", _root);
        Environment.SetEnvironmentVariable("OPENAI_API_KEY", null);
        // Reaching CLI discovery returns a different fixed error; no executable can start.
        Environment.SetEnvironmentVariable("CODEX_EXE", @".\must-not-start.exe");
    }

    public void Dispose()
    {
        CodexProvider.ResetCleanupFaultForTest();
        Environment.SetEnvironmentVariable("CODEX_HOME", _home);
        Environment.SetEnvironmentVariable("OPENAI_API_KEY", _key);
        Environment.SetEnvironmentVariable("CODEX_EXE", _exe);
        // Keep the isolated synthetic fixture, like the other Windows security tests.
    }

    private void SetKey(bool present) => Environment.SetEnvironmentVariable("OPENAI_API_KEY", present ? "synthetic-key" : null);

    private async Task RejectBeforeCliAsync(string expected)
    {
        Assert.ThrowsAny<Exception>(() => _provider.IsSignedInLocally());
        Assert.False(ProviderRegistry.IsSignedInLocally(_provider));
        QuotaSnapshot result = await _provider.FetchAsync(CancellationToken.None);
        Assert.Equal(expected, result.Error);
        Assert.Empty(result.Windows);
        QuotaSnapshot service = await QuotaService.ReadProviderAsync(_provider, false, CancellationToken.None, consent: true);
        Assert.Equal(I18n.Get("windows.could.not.read.quota"), service.Error);
        Assert.DoesNotContain(_root, result.Error!);
        Assert.DoesNotContain("synthetic", result.Error!);
    }

    private Task RejectUnsafePathAsync() => RejectBeforeCliAsync(I18n.Get("windows.could.not.start.or.communicate.with.the.codex.cli"));

    [Fact]
    public async Task OnlyMissingFilesOrDirectoriesAreAbsent()
    {
        Assert.False(LocalFiles.Exists(AuthPath));
        Assert.False(_provider.IsSignedInLocally());
        Assert.Equal(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"), (await _provider.FetchAsync(CancellationToken.None)).Error);
        SetKey(true);
        Assert.False(_provider.IsSignedInLocally());
        Assert.Equal(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"), (await _provider.FetchAsync(CancellationToken.None)).Error);
        SetKey(false);
        Environment.SetEnvironmentVariable("CODEX_HOME", Path.Combine(_root, "missing-directory"));
        Assert.False(LocalFiles.Exists(CredentialFiles.CodexPath));
        Assert.False(_provider.IsSignedInLocally());
        Assert.Equal(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"), (await _provider.FetchAsync(CancellationToken.None)).Error);
        SetKey(true);
        Assert.False(_provider.IsSignedInLocally());
        Assert.Equal(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"), (await _provider.FetchAsync(CancellationToken.None)).Error);
    }

    private ProcessStartInfo CreateCliStartInfo()
    {
        string executable = Path.Combine(AppContext.BaseDirectory, "FakeGrokCli", "FakeGrokCli.exe");
        Assert.True(File.Exists(executable));
        var info = new ProcessStartInfo(executable)
        {
            WorkingDirectory = Path.GetDirectoryName(executable)!, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        info.Environment.Clear();
        info.Environment["SystemRoot"] = Path.GetDirectoryName(Environment.SystemDirectory)!;
        info.ArgumentList.Add("codex-test");
        info.ArgumentList.Add(StartedPath);
        return info;
    }

    private async Task<Process> WaitForCliAsync(Task fetch, string? startedPath = null)
    {
        startedPath ??= StartedPath;
        var timer = Stopwatch.StartNew();
        while (!File.Exists(startedPath))
        {
            Assert.False(fetch.IsCompleted, "Fetch completed before the fixture started.");
            Assert.True(timer.Elapsed < TimeSpan.FromSeconds(10), "The fixture did not start.");
            await Task.Delay(25);
        }
        Process process = Process.GetProcessById(int.Parse(File.ReadAllText(startedPath)));
        Assert.False(process.HasExited);
        return process;
    }

    private void AssertDirectoryLocksReleased()
    {
        Directory.Move(_root, _root + "-moved");
        Directory.Move(_root + "-moved", _root);
        Directory.Move(_parent, _parent + "-moved");
        Directory.Move(_parent + "-moved", _parent);
    }

    [Fact]
    public async Task MissingHomeWithApiKeyDoesNotStartCliOrCreateDirectory()
    {
        SetKey(true);
        string missing = Path.Combine(_root, "missing-home");
        Environment.SetEnvironmentVariable("CODEX_HOME", missing);
        QuotaSnapshot result = await _provider.FetchForTestAsync(CreateCliStartInfo(), CancellationToken.None);
        Assert.Equal(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"), result.Error);
        Assert.False(File.Exists(StartedPath));
        Assert.False(Directory.Exists(missing));
        AssertDirectoryLocksReleased();
    }

    [Theory]
    [InlineData("success")]
    [InlineData("cancel")]
    [InlineData("timeout")]
    public async Task HomeAndAncestorsStayLockedThroughCliExitAndReleaseOnEveryExit(string exit)
    {
        SetKey(true);
        File.WriteAllText(AuthPath, "{}");
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cancellation = new CancellationTokenSource();
        Task<QuotaSnapshot> fetch = _provider.FetchForTestAsync(info, cancellation.Token);
        try
        {
            using Process cli = await WaitForCliAsync(fetch);
            using Process child = await WaitForCliAsync(fetch, StartedPath + ".child");
            Assert.True(File.Exists(AuthPath));
            Assert.Throws<IOException>(() => Directory.Move(_root, _root + "-moved"));
            Assert.Throws<IOException>(() => Directory.Move(_parent, _parent + "-moved"));
            Assert.Throws<IOException>(() => File.Move(AuthPath, AuthPath + ".renamed"));
            if (exit == "success") File.WriteAllText(Path.Combine(_parent, "cli-continue"), "continue");
            if (exit == "cancel") cancellation.Cancel();
            if (exit == "cancel")
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fetch.WaitAsync(TimeSpan.FromSeconds(10)));
            else
            {
                QuotaSnapshot result = await fetch.WaitAsync(TimeSpan.FromSeconds(30));
                if (exit == "timeout")
                    Assert.Equal(I18n.Get("windows.reading.codex.quota.timed.out.20.seconds"), result.Error);
                else
                {
                    Assert.Null(result.Error);
                    Assert.NotEmpty(result.Windows);
                }
            }
            Assert.True(cli.HasExited);
            Assert.True(child.WaitForExit(2000));
            Assert.True(child.HasExited);
            AssertDirectoryLocksReleased();
            File.Move(AuthPath, AuthPath + ".renamed");
            File.Move(AuthPath + ".renamed", AuthPath);
        }
        finally
        {
            cancellation.Cancel();
            try { await fetch.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (OperationCanceledException) { }
        }
    }

    [Theory]
    [InlineData(false, (int)FileSystemRights.ReadData)]
    [InlineData(true, (int)FileSystemRights.ReadData)]
    [InlineData(false, (int)FileSystemRights.WriteData)]
    [InlineData(true, (int)FileSystemRights.WriteData)]
    public async Task MissingCredentialWithApiKeyRejectsUnsafeFileInheritanceBeforeCli(bool inheritOnly, int mask)
    {
        SetKey(true);
        var directory = new DirectoryInfo(_root);
        DirectorySecurity security = directory.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            (FileSystemRights)mask, InheritanceFlags.ObjectInherit,
            inheritOnly ? PropagationFlags.InheritOnly : PropagationFlags.None, AccessControlType.Allow));
        directory.SetAccessControl(security);
        string before = directory.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All);
        await RejectBeforeCliAsync(CredentialAccess.UnsafeMessage);
        QuotaSnapshot result = await _provider.FetchForTestAsync(CreateCliStartInfo(), CancellationToken.None);
        Assert.Equal(CredentialAccess.UnsafeMessage, result.Error);
        Assert.Empty(result.Windows);
        Assert.False(File.Exists(StartedPath));
        Assert.False(File.Exists(AuthPath));
        Assert.Equal(before, directory.GetAccessControl().GetSecurityDescriptorSddlForm(AccessControlSections.All));
        AssertDirectoryLocksReleased();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingCredentialNeverStartsCliEvenWithApiKey(bool hasKey)
    {
        SetKey(hasKey);
        Assert.False(_provider.IsSignedInLocally());
        Assert.False(ProviderRegistry.IsSignedInLocally(_provider));
        QuotaSnapshot result = await _provider.FetchForTestAsync(CreateCliStartInfo(), CancellationToken.None);
        Assert.Equal(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"), result.Error);
        Assert.Empty(result.Windows);
        Assert.False(File.Exists(StartedPath));
        Assert.False(File.Exists(AuthPath));
        QuotaSnapshot service = await QuotaService.ReadProviderAsync(_provider, false, CancellationToken.None, consent: true);
        Assert.Equal(result.Error, service.Error);
        Assert.Empty(service.Windows);
        Assert.False(service.IsDemo);
        AssertDirectoryLocksReleased();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task BackgroundCleanupRetainsLocksUntilExitEvenWhenWaitingThrows(bool waitFails)
    {
        File.WriteAllText(AuthPath, "{}");
        using LocalFiles.CodexCredentialLock credential = LocalFiles.OpenCodexCredential(AuthPath, 1_048_576);
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cli = new CodexCliProcess();
        cli.Start(info);
        SafeHandle[] handles = CaptureCliHandles(cli);
        using Process observer = Process.GetProcessById(cli.Id);
        using Process child = await WaitForCliAsync(observer.WaitForExitAsync(), StartedPath + ".child");
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task? cleanup = null;
        try
        {
            AssertJobProcesses(cli, observer.Id, child.Id);
            AssertCredentialLocksHeld();
            bool injectedFailure = false;
            cleanup = CodexProvider.ReleaseCredentialAfterExitAsync(cli, credential, waitForExit: async () =>
            {
                await release.Task;
                if (waitFails)
                {
                    injectedFailure = true;
                    throw new IOException("synthetic-wait-error-must-not-escape");
                }
            });
            Assert.False(cleanup.IsCompleted);
            // Reproduce the actual bug: the original parent exits while its child remains alive.
            observer.Kill();
            Assert.True(observer.WaitForExit(2000));
            Assert.False(child.HasExited);
            AssertJobProcesses(cli, child.Id);
            AssertCredentialLocksHeld();
            release.SetResult(true);
            await cleanup.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(waitFails, injectedFailure);
            Assert.True(observer.HasExited);
            Assert.True(child.WaitForExit(2000));
            Assert.True(child.HasExited);
            Assert.All(handles, handle => Assert.True(handle.IsClosed));
            AssertDirectoryLocksReleased();
            File.Move(AuthPath, AuthPath + ".renamed");
            File.Move(AuthPath + ".renamed", AuthPath);
        }
        finally
        {
            release.TrySetResult(true);
            if (cleanup is not null) await cleanup.WaitAsync(TimeSpan.FromSeconds(10));
            else await cli.TerminateAndWaitAsync(TimeSpan.FromSeconds(2));
        }
    }

    [Theory]
    [InlineData("en", "Codex cleanup failed. Restart AI SubGauge.", null, 300)]
    [InlineData("zh-Hans", "Codex 清理异常，请重启 AI SubGauge。", 2500, 3)]
    public async Task CleanupRetryCapRetainsLocksAndHandlesAndBlocksSubsequentReads(
        string language, string expected, int? retryMilliseconds, int expectedAttempts)
    {
        string previousLanguage = I18n.Language;
        File.WriteAllText(AuthPath, "{}");
        using LocalFiles.CodexCredentialLock credential = LocalFiles.OpenCodexCredential(AuthPath, 1_048_576);
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cli = new CodexCliProcess();
        cli.Start(info);
        SafeHandle[] handles = CaptureCliHandles(cli);
        using Process observer = Process.GetProcessById(cli.Id);
        using Process child = await WaitForCliAsync(observer.WaitForExitAsync(), StartedPath + ".child");
        try
        {
            I18n.Initialize(language);
            TimeSpan elapsed = TimeSpan.Zero;
            TimeSpan cap = retryMilliseconds is int milliseconds ? TimeSpan.FromMilliseconds(milliseconds) : TimeSpan.FromMinutes(5);
            int attempts = 0, delays = 0;
            await CodexProvider.ReleaseCredentialAfterExitAsync(cli, credential,
                retryTimeout: retryMilliseconds is null ? null : cap, clock: () => elapsed,
                delay: duration =>
                {
                    Assert.True(elapsed < cap, "Cleanup retried after the deadline.");
                    Assert.InRange(duration, TimeSpan.FromTicks(1), TimeSpan.FromSeconds(1));
                    elapsed += duration;
                    delays++;
                    return Task.CompletedTask;
                }, terminateAndWait: duration =>
                {
                    Assert.InRange(duration, TimeSpan.FromTicks(1), TimeSpan.FromSeconds(2));
                    Assert.True(duration <= cap - elapsed);
                    attempts++;
                    return Task.FromException(new IOException("synthetic-cleanup-failure"));
                });
            Assert.Equal(cap, elapsed);
            Assert.Equal(expectedAttempts, attempts);
            Assert.Equal(expectedAttempts, delays);
            Assert.True(CodexProvider.CodexCleanupFault);
            Assert.False(observer.HasExited);
            Assert.False(child.HasExited);
            Assert.All(handles, handle => Assert.False(handle.IsClosed));
            AssertCredentialLocksHeld();

            var subsequentProvider = new CodexProvider();
            ProcessStartInfo blockedInfo = CreateCliStartInfo();
            string blockedPath = StartedPath + ".blocked";
            blockedInfo.ArgumentList[1] = blockedPath;
            QuotaSnapshot blocked = await subsequentProvider.FetchForTestAsync(blockedInfo, CancellationToken.None)
                .WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(expected, blocked.Error);
            Assert.Empty(blocked.Windows);
            Assert.False(File.Exists(blockedPath));
            Assert.Equal(expected, (await subsequentProvider.FetchAsync(CancellationToken.None)).Error);
            QuotaSnapshot service = await QuotaService.ReadProviderAsync(subsequentProvider, false, CancellationToken.None, consent: true);
            Assert.Equal(expected, service.Error);
            Assert.Contains(expected, AISubGauge.UI.QuotaText.Tooltip(subsequentProvider.DisplayName, service));
            Assert.True(ProviderRegistry.IsSignedInLocally(subsequentProvider));
            AssertCredentialLocksHeld();
            Assert.All(handles, handle => Assert.False(handle.IsClosed));
        }
        finally
        {
            // Only the test may clean up the synthetic job after asserting fail-closed retention.
            try { await cli.TerminateAndWaitAsync(TimeSpan.FromSeconds(2)); }
            finally { I18n.Initialize(previousLanguage); }
        }
    }

    [Fact]
    public async Task CleanupSuccessBeforeCapReleasesLocksAndHandlesWithoutFault()
    {
        File.WriteAllText(AuthPath, "{}");
        using LocalFiles.CodexCredentialLock credential = LocalFiles.OpenCodexCredential(AuthPath, 1_048_576);
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cli = new CodexCliProcess();
        cli.Start(info);
        SafeHandle[] handles = CaptureCliHandles(cli);
        using Process observer = Process.GetProcessById(cli.Id);
        using Process child = await WaitForCliAsync(observer.WaitForExitAsync(), StartedPath + ".child");
        try
        {
            TimeSpan elapsed = TimeSpan.Zero;
            int attempts = 0, delays = 0;
            await CodexProvider.ReleaseCredentialAfterExitAsync(cli, credential, clock: () => elapsed,
                delay: duration =>
                {
                    elapsed += duration;
                    delays++;
                    return Task.CompletedTask;
                }, terminateAndWait: duration =>
                {
                    attempts++;
                    if (attempts < 3)
                    {
                        AssertCredentialLocksHeld();
                        return Task.FromException(new IOException("synthetic-cleanup-failure"));
                    }
                    return cli.TerminateAndWaitAsync(duration);
                });
            Assert.Equal(3, attempts);
            Assert.Equal(2, delays);
            Assert.Equal(TimeSpan.FromSeconds(2), elapsed);
            Assert.False(CodexProvider.CodexCleanupFault);
            Assert.True(observer.WaitForExit(2000));
            Assert.True(child.WaitForExit(2000));
            Assert.All(handles, handle => Assert.True(handle.IsClosed));
            AssertDirectoryLocksReleased();
            File.Move(AuthPath, AuthPath + ".renamed");
            File.Move(AuthPath + ".renamed", AuthPath);
        }
        finally
        {
            if (!handles[0].IsClosed) await cli.TerminateAndWaitAsync(TimeSpan.FromSeconds(2));
        }
    }

    [Fact]
    public async Task ForegroundCleanupTimeoutTransfersJobAndLocksUntilEveryProcessExits()
    {
        File.WriteAllText(AuthPath, "{}");
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cancellation = new CancellationTokenSource();
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var entered = new TaskCompletionSource<CodexCliProcess>(TaskCreationOptions.RunContinuationsAsynchronously);
        var deferred = new TaskCompletionSource<Task>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<QuotaSnapshot> fetch = _provider.FetchForTestAsync(info, cancellation.Token,
            cleanupTimeout: TimeSpan.FromMilliseconds(10), beforeCleanup: process =>
            {
                entered.SetResult(process);
                return release.Task; // Hold a live child across the foreground timeout deterministically.
            }, cleanupDeferred: cleanup => deferred.SetResult(cleanup));
        try
        {
            using Process observer = await WaitForCliAsync(fetch);
            using Process child = await WaitForCliAsync(fetch, StartedPath + ".child");
            AssertCredentialLocksHeld();
            File.WriteAllText(Path.Combine(_parent, "cli-continue"), "continue");
            CodexCliProcess job = await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            SafeHandle[] handles = CaptureCliHandles(job);
            QuotaSnapshot result = await fetch.WaitAsync(TimeSpan.FromSeconds(10));
            Task cleanup = await deferred.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(CredentialAccess.UnsafeMessage, result.Error);
            Assert.Empty(result.Windows);
            Assert.False(cleanup.IsCompleted);
            Assert.True(observer.WaitForExit(2000));
            Assert.False(child.HasExited);
            AssertJobProcesses(job, child.Id);
            AssertCredentialLocksHeld();
            release.SetResult(true);
            await cleanup.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.True(child.WaitForExit(2000));
            Assert.True(child.HasExited);
            Assert.All(handles, handle => Assert.True(handle.IsClosed));
            AssertDirectoryLocksReleased();
            File.Move(AuthPath, AuthPath + ".renamed");
            File.Move(AuthPath + ".renamed", AuthPath);
        }
        finally
        {
            release.TrySetResult(true);
            cancellation.Cancel();
            try { await fetch.WaitAsync(TimeSpan.FromSeconds(10)); }
            catch (OperationCanceledException) { }
            if (deferred.Task.IsCompletedSuccessfully)
                await (await deferred.Task).WaitAsync(TimeSpan.FromSeconds(10));
        }
    }

    private void AssertCredentialLocksHeld()
    {
        Assert.Throws<IOException>(() => File.Move(AuthPath, AuthPath + ".renamed"));
        Assert.Throws<IOException>(() => Directory.Move(_root, _root + "-moved"));
        Assert.Throws<IOException>(() => Directory.Move(_parent, _parent + "-moved"));
    }

    private static void AssertJobProcesses(CodexCliProcess job, params int[] expected)
    {
        int[] actual = job.GetProcessIds();
        foreach (int pid in expected) Assert.Contains(pid, actual);
        foreach (int pid in actual.Except(expected))
        {
            Process process;
            try { process = Process.GetProcessById(pid); }
            catch (ArgumentException) { continue; } // Already exited since the job snapshot.
            using (process)
            {
                if (process.HasExited) continue;
                string name;
                try { name = process.ProcessName; }
                catch (InvalidOperationException) when (process.HasExited) { continue; }
                Assert.Equal("conhost", name, ignoreCase: true); // ProcessName omits .exe.
            }
        }
    }

    private static SafeHandle[] CaptureCliHandles(CodexCliProcess cli)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        SafeHandle[] handles =
        {
            Assert.IsAssignableFrom<SafeHandle>(typeof(CodexCliProcess).GetField("_job", flags)!.GetValue(cli)),
            Assert.IsAssignableFrom<SafeHandle>(typeof(CodexCliProcess).GetField("_process", flags)!.GetValue(cli)),
            Assert.IsAssignableFrom<PipeStream>(cli.StandardInput.BaseStream).SafePipeHandle,
            Assert.IsAssignableFrom<PipeStream>(cli.StandardOutput).SafePipeHandle,
            Assert.IsAssignableFrom<PipeStream>(cli.StandardError).SafePipeHandle
        };
        Assert.All(handles, handle => Assert.False(handle.IsClosed));
        return handles;
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task DisposingTerminatedCliClosesAllHandles(bool terminateJob, bool closeInputBeforeDispose)
    {
        using var cli = new CodexCliProcess();
        cli.Start(CreateCliStartInfo());
        SafeHandle[] handles = CaptureCliHandles(cli);
        using Process observer = Process.GetProcessById(cli.Id);
        cli.StandardInput.Write("synthetic-pending-input");
        if (terminateJob) await cli.TerminateAndWaitAsync(TimeSpan.FromSeconds(2));
        else observer.Kill();
        Assert.True(observer.WaitForExit(2000));
        if (closeInputBeforeDispose)
        {
            cli.StandardInput.BaseStream.Dispose();
            Assert.Throws<ObjectDisposedException>(() => cli.StandardInput.Flush());
        }
        Assert.Null(Record.Exception(() => cli.Dispose()));
        Assert.All(handles, handle => Assert.True(handle.IsClosed));
        Assert.Null(Record.Exception(() => cli.Dispose()));
    }

    [Fact]
    public async Task ClosingJobTerminatesDescendantsAfterRootExit()
    {
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cli = new CodexCliProcess();
        cli.Start(info);
        SafeHandle[] handles = CaptureCliHandles(cli);
        using Process observer = Process.GetProcessById(cli.Id);
        using Process child = await WaitForCliAsync(observer.WaitForExitAsync(), StartedPath + ".child");
        AssertJobProcesses(cli, observer.Id, child.Id);
        observer.Kill();
        Assert.True(observer.WaitForExit(2000));
        Assert.False(child.HasExited);
        AssertJobProcesses(cli, child.Id);
        // Exercise JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE independently of TerminateJobObject.
        Assert.Null(Record.Exception(() => cli.Dispose()));
        Assert.All(handles, handle => Assert.True(handle.IsClosed));
        Assert.True(child.WaitForExit(2000));
    }

    [Fact]
    public async Task TerminatingJobLeavesNoActiveProcessesBeforeLocksAreReleased()
    {
        File.WriteAllText(AuthPath, "{}");
        using LocalFiles.CodexCredentialLock credential = LocalFiles.OpenCodexCredential(AuthPath, 1_048_576);
        ProcessStartInfo info = CreateCliStartInfo();
        info.ArgumentList[0] = "codex-tree-test";
        using var cli = new CodexCliProcess();
        cli.Start(info);
        SafeHandle[] handles = CaptureCliHandles(cli);
        using Process observer = Process.GetProcessById(cli.Id);
        using Process child = await WaitForCliAsync(observer.WaitForExitAsync(), StartedPath + ".child");
        AssertJobProcesses(cli, observer.Id, child.Id);
        AssertCredentialLocksHeld();
        await cli.TerminateAndWaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(0u, cli.ActiveProcesses);
        Assert.Empty(cli.GetProcessIds());
        Assert.True(observer.WaitForExit(2000));
        Assert.True(child.WaitForExit(2000));
        AssertCredentialLocksHeld();
        Assert.Null(Record.Exception(() => cli.Dispose()));
        Assert.All(handles, handle => Assert.True(handle.IsClosed));
        credential.Dispose();
        AssertDirectoryLocksReleased();
        File.Move(AuthPath, AuthPath + ".renamed");
        File.Move(AuthPath + ".renamed", AuthPath);
    }

    [Fact]
    public async Task CliStartupFailureReleasesCredentialAndDirectoryLocks()
    {
        File.WriteAllText(AuthPath, "{}");
        ProcessStartInfo info = CreateCliStartInfo();
        info.FileName = Path.Combine(_parent, "missing-cli.exe");
        QuotaSnapshot result = await _provider.FetchForTestAsync(info, CancellationToken.None);
        Assert.Equal(I18n.Get("windows.could.not.start.or.communicate.with.the.codex.cli"), result.Error);
        Assert.Empty(result.Windows);
        Assert.False(File.Exists(StartedPath));
        AssertDirectoryLocksReleased();
        File.Move(AuthPath, AuthPath + ".renamed");
        File.Move(AuthPath + ".renamed", AuthPath);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnsafeAncestorFailsBeforeCliEvenWithPrivateOrMissingFile(bool hasFile)
    {
        SetKey(true);
        if (hasFile) File.WriteAllText(AuthPath, "{}");
        var ancestor = new DirectoryInfo(_parent);
        DirectorySecurity security = ancestor.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            FileSystemRights.DeleteSubdirectoriesAndFiles, AccessControlType.Allow));
        ancestor.SetAccessControl(security);
        await RejectBeforeCliAsync(CredentialAccess.UnsafeMessage);
        AssertDirectoryLocksReleased();
    }

    [Fact]
    public void AncestorSiblingCreationRightsAreAllowedWhileMissingCredentialHomeStaysLocked()
    {
        var ancestor = new DirectoryInfo(_parent);
        DirectorySecurity security = ancestor.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            FileSystemRights.WriteData | FileSystemRights.AppendData, AccessControlType.Allow));
        ancestor.SetAccessControl(security);
        using (LocalFiles.CodexCredentialLock credential = LocalFiles.OpenCodexCredential(AuthPath, 1_048_576))
        {
            Assert.False(credential.HasCredential);
            Assert.Throws<IOException>(() => Directory.Move(_root, _root + "-moved"));
            Assert.Throws<IOException>(() => Directory.Move(_parent, _parent + "-moved"));
        }
        AssertDirectoryLocksReleased();
    }

    [Theory]
    [InlineData(2)]
    [InlineData(1_048_576)]
    public void PrivateCredentialsWithinLimitAreRecognized(int length)
    {
        using (FileStream file = File.Create(AuthPath)) file.SetLength(length);
        Assert.True(_provider.IsSignedInLocally());
        Assert.True(ProviderRegistry.IsSignedInLocally(_provider));
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task WritableCodexDirectoryFailsBeforeCliEvenWithPrivateOrMissingFile(bool hasKey, bool hasFile)
    {
        SetKey(hasKey);
        if (hasFile) File.WriteAllText(AuthPath, "{}");
        var directory = new DirectoryInfo(_root);
        DirectorySecurity security = directory.GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            FileSystemRights.WriteData | FileSystemRights.DeleteSubdirectoriesAndFiles, AccessControlType.Allow));
        directory.SetAccessControl(security);
        if (hasFile)
        {
            using FileStream file = LocalFiles.OpenRead(AuthPath, 1_048_576);
            CredentialAccess.Validate(file, kind: CredentialKind.Codex, credentialPath: AuthPath);
        }
        await RejectBeforeCliAsync(CredentialAccess.UnsafeMessage);
        // Rejected opens release every handle too.
        Directory.Move(_root, _root + "-moved");
        Directory.Move(_root + "-moved", _root);
    }

    [Fact]
    public void CredentialLockAllowsInPlaceRefreshButBlocksFileAndDirectoryRenameUntilDisposed()
    {
        File.WriteAllText(AuthPath, "{}");
        using (LocalFiles.OpenCodexCredential(AuthPath, 1_048_576))
        {
            // Match the official CLI's truncate/write/create save, with write sharing in both directions.
            using (var refresh = new FileStream(AuthPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
                refresh.WriteByte(123);
            Assert.Throws<IOException>(() => File.Move(AuthPath, AuthPath + ".renamed"));
            Assert.Throws<IOException>(() => Directory.Move(_root, _root + "-moved"));
        }
        File.Move(AuthPath, AuthPath + ".renamed");
        File.Move(AuthPath + ".renamed", AuthPath);
        Directory.Move(_root, _root + "-moved");
        Directory.Move(_root + "-moved", _root);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CliDiscoveryFailureReleasesCredentialAndDirectoryLocks(bool hasFile)
    {
        SetKey(true);
        if (hasFile) File.WriteAllText(AuthPath, "{}");
        QuotaSnapshot result = await _provider.FetchAsync(CancellationToken.None);
        Assert.Equal(I18n.Get(hasFile ? "windows.codex.trustedExeRequired" :
            "windows.codex.is.not.signed.in.sign.in.to.the.codex"), result.Error);
        if (hasFile)
        {
            File.Move(AuthPath, AuthPath + ".renamed");
            File.Move(AuthPath + ".renamed", AuthPath);
        }
        AssertDirectoryLocksReleased();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OversizedCredentialsFailBeforeCliEvenWithApiKey(bool hasKey)
    {
        SetKey(hasKey);
        using (FileStream file = File.Create(AuthPath)) file.SetLength(1_048_577);
        Assert.Throws<IOException>(() => LocalFiles.Exists(AuthPath));
        await RejectUnsafePathAsync();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnsafeAclIsValidatedEvenWithApiKey(bool hasKey)
    {
        SetKey(hasKey);
        File.WriteAllText(AuthPath, "{}");
        FileSecurity security = new FileInfo(AuthPath).GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null),
            FileSystemRights.ReadData, AccessControlType.Allow));
        new FileInfo(AuthPath).SetAccessControl(security);
        await RejectBeforeCliAsync(CredentialAccess.UnsafeMessage);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LeafSymlinkOrJunctionFailsBeforeCli(bool hasKey)
    {
        SetKey(hasKey);
        string target = Path.Combine(_root, "target.json");
        File.WriteAllText(target, "{}");
        try { File.CreateSymbolicLink(AuthPath, target); }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException)
        {
            _output.WriteLine("File symlink creation unavailable; using a directory junction reparse point at auth.json.");
            string directory = Path.Combine(_root, "target-directory");
            Directory.CreateDirectory(directory);
            CreateJunction(AuthPath, directory);
        }
        Assert.True((File.GetAttributes(AuthPath) & FileAttributes.ReparsePoint) != 0);
        Assert.Throws<IOException>(() => LocalFiles.Exists(AuthPath));
        await RejectUnsafePathAsync();
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task JunctionAncestorFailsBeforeCliEvenWithApiKey(bool hasKey, bool hasFile)
    {
        SetKey(hasKey);
        if (hasFile) File.WriteAllText(AuthPath, "{}");
        string junction = Path.Combine(_root, "linked-home");
        CreateJunction(junction, _root);
        Environment.SetEnvironmentVariable("CODEX_HOME", junction);
        Assert.Throws<IOException>(() => LocalFiles.Exists(CredentialFiles.CodexPath));
        Assert.Throws<IOException>(() => { using var credential = LocalFiles.OpenCodexCredential(CredentialFiles.CodexPath, 1_048_576); });
        await RejectUnsafePathAsync();
    }

    [Theory]
    [InlineData(@"\\server\share")]
    [InlineData(@".\relative-home")]
    public async Task NonLocalOrRelativeCredentialHomeCannotBeBypassedByApiKey(string home)
    {
        SetKey(true);
        Environment.SetEnvironmentVariable("CODEX_HOME", home);
        await RejectUnsafePathAsync();
    }

    private static void CreateJunction(string path, string target)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"))
        {
            Arguments = $"/d /c mklink /J \"{path}\" \"{target}\"",
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        using Process process = Process.Start(info)!;
        try
        {
            Assert.True(process.WaitForExit(5000));
            Assert.Equal(0, process.ExitCode);
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); process.WaitForExit(2000); } }
    }
}
