param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'InstallSafety.ps1')
. (Join-Path $root 'InstallFiles.ps1')
$script:passed = 0
$script:failed = 0
function Assert([bool]$Condition) { if (-not $Condition) { throw 'Assertion failed.' } }
function Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name" }
}
function Capture-Failure([scriptblock]$Body) {
    try { $null = & $Body } catch { return Get-InstallFailure $_.Exception }
    throw 'Expected a failure.'
}
# All writes stay in unique repository fixtures. No installer, registry, real process
# enumeration/termination, application launch, or fixture deletion is performed.
$fixture = Join-Path $root ('artifacts\install-sim\' + [Guid]::NewGuid().ToString('N'))
function New-Fixture([bool]$Existing = $true) {
    $folder = Join-Path $fixture ([Guid]::NewGuid().ToString('N'))
    $source = Join-Path $folder 'package'
    $programs = Join-Path $folder 'Programs'
    $target = Join-Path $programs 'AISubGauge2'
    [void][IO.Directory]::CreateDirectory($source)
    [void][IO.Directory]::CreateDirectory($programs)
    if ($Existing) { [void][IO.Directory]::CreateDirectory($target) }
    foreach ($file in (Get-Version2PackageFiles)) {
        [IO.File]::WriteAllText((Join-Path $source $file), ('new ' + $file))
        if ($Existing) { [IO.File]::WriteAllText((Join-Path $target $file), ('old ' + $file)) }
    }
    return [pscustomobject]@{ Source = $source; Programs = $programs; Target = $target; Exe = Join-Path $target 'AISubGauge2.exe' }
}
function Assert-NewFiles($Fixture) {
    foreach ($file in (Get-Version2PackageFiles)) {
        Assert ([IO.File]::ReadAllText((Join-Path $Fixture.Target $file)) -ceq ('new ' + $file))
    }
    Assert (@(Get-ChildItem -LiteralPath $Fixture.Target -Force -Filter '*.installing').Count -eq 0)
}
# The lock is acquired synchronously; a CLR worker (no PowerShell runspace needed)
# releases this actual FileStream after 1 second while the copy runs on this thread.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public static class InstallCopyTestLock {
    public static Task ReleaseAfter(FileStream stream, int milliseconds) {
        return Task.Run(() => { try { Thread.Sleep(milliseconds); } finally { stream.Dispose(); } });
    }
}
'@
Test 'fresh installation copies all seven files in an injected repository root' {
    $f = New-Fixture $false
    Copy-Version2Package $f.Source $f.Programs
    Assert-NewFiles $f
}
Test 'overwrite of existing plain installation succeeds, including safety helper' {
    $f = New-Fixture
    Copy-Version2Package $f.Source $f.Programs
    Assert-NewFiles $f
}
Test 'atomic overwrite retries actual sharing violation until FileStream releases after 1s' {
    $f = New-Fixture
    $stream = [IO.File]::Open($f.Exe, 'Open', 'Read', 'None')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $release = [InstallCopyTestLock]::ReleaseAfter($stream, 1000)
    try {
        Copy-Version2Package $f.Source $f.Programs
        Assert-NewFiles $f
        Assert ($watch.ElapsedMilliseconds -ge 900 -and $watch.ElapsedMilliseconds -lt 8000)
    } finally { $release.Wait(); $stream.Dispose() }
}
$script:launches = [Collections.Generic.List[string]]::new()
function Start-Process([string]$FilePath, [string]$WorkingDirectory, [string]$WindowStyle) {
    Assert ($WindowStyle -ceq 'Hidden')
    Assert ($WorkingDirectory -eq (Split-Path $FilePath -Parent))
    $script:launches.Add($FilePath)
}
Test 'exhausted sharing retries retain old EXE and recovery launches only that exact target' {
    $f = New-Fixture
    $stream = [IO.File]::Open($f.Exe, 'Open', 'Read', 'None')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { $failure = Capture-Failure { Copy-Version2Package $f.Source $f.Programs } }
    finally { $stream.Dispose() }
    Assert ($failure.Category -ceq 'SharingViolation' -and $failure.HResult -eq -2147024864)
    Assert ($watch.ElapsedMilliseconds -lt 8000)
    Assert ([IO.File]::ReadAllText($f.Exe) -ceq 'old AISubGauge2.exe')
    $script:launches.Clear()
    Assert (Resume-Version2AfterFailure $true $f.Programs)
    Assert ($script:launches.Count -eq 1 -and $script:launches[0] -ceq $f.Exe)
}
Test 'missing payload fails preflight before any existing file is changed' {
    $f = New-Fixture
    [IO.File]::Move((Join-Path $f.Source 'LICENSE'), (Join-Path $f.Source 'LICENSE.retained'))
    $failure = Capture-Failure { Copy-Version2Package $f.Source $f.Programs }
    Assert ($failure.Category -ceq 'Other')
    foreach ($file in (Get-Version2PackageFiles)) {
        Assert ([IO.File]::ReadAllText((Join-Path $f.Target $file)) -ceq ('old ' + $file))
    }
}
Test 'linked target is rejected and recovery refuses to launch through it' {
    $f = New-Fixture $false
    $outside = Join-Path $fixture ('outside-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $outside 'AISubGauge2.exe'), 'outside sentinel')
    [void](New-Item -ItemType Junction -Path $f.Target -Target $outside)
    $failure = Capture-Failure { Copy-Version2Package $f.Source $f.Programs }
    Assert ($failure.Category -ceq 'SafetyRejected')
    Assert ([IO.File]::ReadAllText((Join-Path $outside 'AISubGauge2.exe')) -ceq 'outside sentinel')
    Assert (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 1)
    $script:launches.Clear()
    $failure = Capture-Failure { Resume-Version2AfterFailure $true $f.Programs }
    Assert ($failure.Category -ceq 'SafetyRejected' -and $script:launches.Count -eq 0)
}
Test 'package cannot be the installed target or its child' {
    $f = New-Fixture
    $failure = Capture-Failure { Copy-Version2Package $f.Target $f.Programs }
    Assert ($failure.Category -ceq 'SafetyRejected')
    $failure = Capture-Failure { Copy-Version2Package (Join-Path $f.Target 'package') $f.Programs }
    Assert ($failure.Category -ceq 'SafetyRejected')
}
Test 'recovery skips fresh installs and missing old executables' {
    $f = New-Fixture $false
    $script:launches.Clear()
    Assert (-not (Resume-Version2AfterFailure $false $f.Programs))
    Assert (-not (Resume-Version2AfterFailure $true $f.Programs))
    Assert ($script:launches.Count -eq 0)
}
Test 'only sharing violations retry; other and safety failures execute once' {
    foreach ($kind in @('Other','SafetyRejected')) {
        $script:attempts = 0
        $failure = Capture-Failure {
            Invoke-InstallIoWithRetry {
                $script:attempts++
                $error = [UnauthorizedAccessException]::new('synthetic private path must not be logged')
                if ($kind -eq 'SafetyRejected') { $error.Data['InstallCategory'] = $kind }
                throw $error
            }
        }
        Assert ($failure.Category -ceq $kind -and $script:attempts -eq 1)
        Assert ($failure.HResult -eq -2147024891)
    }
}
function New-FakeProcess([string]$Name, [string]$Path, [bool]$Exits = $true) {
    $process = [pscustomobject]@{ ProcessName = $Name; Path = $Path; HasExited = $false; Exits = $Exits; Killed = $false; Waited = 0; Disposed = $false }
    $process | Add-Member ScriptMethod Kill { $this.Killed = $true }
    $process | Add-Member ScriptMethod WaitForExit { param($timeout); Assert $this.Killed; $this.Waited = $timeout; return $this.Exits }
    $process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return $process
}
function Get-Process { return $script:processes }
Test 'later failure restores GUID backup before relaunch and retains replaced EXE' {
    $f = New-Fixture
    $recovery = @{}
    $script:processes = @()
    Copy-Version2Package $f.Source $f.Programs $recovery
    Assert-NewFiles $f
    Assert ((Split-Path $recovery.ExeBackup -Parent) -ceq $f.Target)
    Assert ((Split-Path $recovery.ExeBackup -Leaf) -cmatch '^AISubGauge2\.[a-f0-9]{32}\.backup\.exe$')
    Assert ([IO.File]::ReadAllText($recovery.ExeBackup) -ceq 'old AISubGauge2.exe')
    $script:launches.Clear()
    # Inspect the bytes at the exact moment recovery attempts its injected launch.
    function Start-Process([string]$FilePath, [string]$WorkingDirectory, [string]$WindowStyle) {
        Assert ([IO.File]::ReadAllText($FilePath) -ceq 'old AISubGauge2.exe')
        Assert ($WindowStyle -ceq 'Hidden')
        $script:launches.Add($FilePath)
    }
    Assert (Resume-Version2AfterFailure $true $f.Programs $recovery)
    Assert ([IO.File]::ReadAllText($recovery.ExeBackup) -ceq 'old AISubGauge2.exe')
    Assert ($script:launches.Count -eq 1 -and $script:launches[0] -ceq $f.Exe)
    $retained = @(Get-ChildItem -LiteralPath $f.Target -Filter '*.failed.exe')
    Assert ($retained.Count -eq 1)
    Assert ([IO.File]::ReadAllText($retained[0].FullName) -ceq 'new AISubGauge2.exe')
}
Test 'missing recovery backup prevents relaunch of the replacement' {
    $f = New-Fixture
    $recovery = @{}
    $script:processes = @()
    Copy-Version2Package $f.Source $f.Programs $recovery
    [IO.File]::Move($recovery.ExeBackup, ($recovery.ExeBackup + '.retained'))
    $script:launches.Clear()
    $failure = Capture-Failure { Resume-Version2AfterFailure $true $f.Programs $recovery }
    Assert ($script:launches.Count -eq 0)
}
Test 'stop waits only for the exact version 2 path; legacy and other paths are untouched' {
    $f = New-Fixture
    $legacy = New-FakeProcess 'AISubGauge' (Join-Path $f.Programs 'AISubGauge\AISubGauge.exe')
    $other = New-FakeProcess 'AISubGauge2' (Join-Path $f.Programs 'Other\AISubGauge2.exe')
    $unknown = New-FakeProcess 'AISubGauge2' ''
    $match = New-FakeProcess 'AISubGauge2' $f.Exe
    $script:processes = @($legacy, $other, $unknown, $match)
    Stop-Version2Process $f.Exe $f.Programs 750
    Assert ($match.Killed -and $match.Waited -eq 750 -and $match.Disposed)
    foreach ($process in @($legacy, $other, $unknown)) { Assert (-not $process.Killed -and $process.Waited -eq 0) }
}
Test 'exit timeout fails before copy and offers recovery of the existing executable' {
    $f = New-Fixture
    $match = New-FakeProcess 'AISubGauge2' $f.Exe $false
    $script:processes = @($match)
    $failure = Capture-Failure {
        Stop-Version2Process $f.Exe $f.Programs 250
        Copy-Version2Package $f.Source $f.Programs
    }
    Assert ($failure.Category -ceq 'Other')
    Assert ($match.Waited -eq 250 -and $match.Disposed)
    Assert ([IO.File]::ReadAllText($f.Exe) -ceq 'old AISubGauge2.exe')
    $script:launches.Clear()
    Assert (Resume-Version2AfterFailure $true $f.Programs)
    Assert ($script:launches.Count -eq 1)
}
Test 'logger emits only fixed category and numeric HRESULT without exception text or paths' {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$errors)
    $logger = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-InstallLog' }, $true)
    # Execute only the logger definition extracted from the AST, never the installer body.
    . ([scriptblock]::Create($logger.Extent.Text))
    $logDirectory = $fixture
    $logPath = Join-Path $fixture 'fixed.log'
    $failure = Get-InstallFailure ([IO.IOException]::new('synthetic private path', -2147024864))
    Write-InstallLog -Status Failed -Stage CopyFiles -Category $failure.Category -HResult $failure.HResult
    $line = [IO.File]::ReadAllText($logPath).Trim([char]0xFEFF).Trim()
    Assert ($line -cmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ Failed CopyFiles:SharingViolation HResult=-2147024864$')
}
Test 'completed installation removes only its exact backup after successful copy' {
    $f = New-Fixture
    $recovery = @{}
    Copy-Version2Package $f.Source $f.Programs $recovery
    Assert ([IO.File]::Exists($recovery.ExeBackup))
    $counts = Clear-Version2CompletedBackup $f.Programs $recovery
    Assert ($counts.Removed -eq 1 -and $counts.Failed -eq 0)
    Assert (-not [IO.File]::Exists($recovery.ExeBackup))
    Assert-NewFiles $f
    $counts = Clear-Version2CompletedBackup $f.Programs $recovery
    Assert ($counts.Removed -eq 0 -and $counts.Failed -eq 0)
}
Test 'leftover cleanup deletes exact own names only and never descends or follows junctions' {
    $f = New-Fixture
    $id = '0123456789abcdef0123456789abcdef'
    $names = @("AISubGauge2.$id.backup.exe", "AISubGauge2.$id.failed.exe")
    foreach ($file in (Get-Version2PackageFiles)) { $names += ".$file.$id.installing" }
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $f.Target $name), 'own temporary') }
    $lookalikes = @(
        "AISubGauge2.$($id.Substring(1)).backup.exe", "AISubGauge2.$($id)0.failed.exe",
        "AISubGauge2.$($id.ToUpperInvariant()).backup.exe", "AISubGauge2.$id.backup.exe.extra",
        "aisubgauge2.$id.backup.exe", ".AISubGauge2.exe.$($id.ToUpperInvariant()).installing",
        ".AISubGauge2.exe.$($id.Substring(1)).installing", ".AISubGauge2.exe.$($id)0.installing",
        ".AISubGauge2.exe.$id.installing.extra", ".other.exe.$id.installing", ".readme.md.$id.installing"
    )
    # Avoid Windows case-insensitive name collisions with the exact names above.
    $counts = Clear-Version2InstallLeftovers $f.Programs
    Assert ($counts.Removed -eq $names.Count -and $counts.Failed -eq 0)
    foreach ($name in $names) { Assert (-not [IO.File]::Exists((Join-Path $f.Target $name))) }
    foreach ($name in $lookalikes) { [IO.File]::WriteAllText((Join-Path $f.Target $name), 'look-alike') }
    $matchingDirectory = Join-Path $f.Target "AISubGauge2.$id.failed.exe"
    $nested = Join-Path $f.Target 'nested'
    $sibling = Join-Path $f.Programs 'sibling'
    foreach ($directory in @($matchingDirectory, $nested, $sibling)) {
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory "AISubGauge2.$id.backup.exe"), 'untouched')
    }
    $junction = Join-Path $f.Target ".LICENSE.$id.installing"
    [void](New-Item -ItemType Junction -Path $junction -Target $sibling)
    $counts = Clear-Version2InstallLeftovers $f.Programs
    Assert ($counts.Removed -eq 0 -and $counts.Failed -eq 0)
    foreach ($name in $lookalikes) { Assert ([IO.File]::ReadAllText((Join-Path $f.Target $name)) -ceq 'look-alike') }
    foreach ($directory in @($matchingDirectory, $nested, $sibling)) {
        Assert ([IO.File]::ReadAllText((Join-Path $directory "AISubGauge2.$id.backup.exe")) -ceq 'untouched')
    }
    Assert ((Get-PathAttributes $junction) -band [IO.FileAttributes]::ReparsePoint)
    foreach ($file in (Get-Version2PackageFiles)) { Assert ([IO.File]::ReadAllText((Join-Path $f.Target $file)) -ceq ('old ' + $file)) }
}
Test 'file reparse attributes are skipped and linked target root is rejected' {
    $f = New-Fixture
    $linkedFile = Join-Path $f.Target ('AISubGauge2.' + [Guid]::NewGuid().ToString('N') + '.backup.exe')
    [IO.File]::WriteAllText($linkedFile, 'reparse sentinel')
    $reader = ${function:Get-PathAttributes}
    function Get-PathAttributes([string]$Path) {
        if ($Path -eq $linkedFile) { return [IO.FileAttributes]::ReparsePoint }
        return & $reader $Path
    }
    $counts = Clear-Version2InstallLeftovers $f.Programs
    Assert ($counts.Removed -eq 0 -and $counts.Failed -eq 0)
    Assert ([IO.File]::ReadAllText($linkedFile) -ceq 'reparse sentinel')
    $linked = New-Fixture $false
    [void](New-Item -ItemType Junction -Path $linked.Target -Target $f.Target)
    $failure = Capture-Failure { Clear-Version2InstallLeftovers $linked.Programs }
    Assert ($failure.Category -ceq 'SafetyRejected')
}
Test 'completed backup cleanup rejects live file, sibling path and wrong backup name' {
    $f = New-Fixture
    $other = Join-Path $f.Programs ('AISubGauge2.' + [Guid]::NewGuid().ToString('N') + '.backup.exe')
    [IO.File]::WriteAllText($other, 'sibling sentinel')
    foreach ($path in @($f.Exe, $other)) {
        $counts = Clear-Version2CompletedBackup $f.Programs @{ ExeBackup = $path }
        Assert ($counts.Removed -eq 0 -and $counts.Failed -eq 1)
        Assert ([IO.File]::Exists($path))
    }
}
Test 'copy failure retains original backup and locked leftover reports counts without deleting' {
    $f = New-Fixture
    $recovery = @{}
    $stream = [IO.File]::Open((Join-Path $f.Target 'LICENSE'), 'Open', 'Read', 'None')
    try { $failure = Capture-Failure { Copy-Version2Package $f.Source $f.Programs $recovery } }
    finally { $stream.Dispose() }
    Assert ($failure.Category -ceq 'SharingViolation')
    Assert ([IO.File]::ReadAllText($recovery.ExeBackup) -ceq 'old AISubGauge2.exe')
    $stream = [IO.File]::Open($recovery.ExeBackup, 'Open', 'Read', 'None')
    try {
        $counts = Clear-Version2CompletedBackup $f.Programs $recovery
        Assert ($counts.Removed -eq 0 -and $counts.Failed -eq 1)
    } finally { $stream.Dispose() }
    Assert ([IO.File]::Exists($recovery.ExeBackup))
}
Test 'cleanup logger outputs fixed phases and counts only' {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$errors)
    $logger = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-InstallCleanupLog' }, $true)
    . ([scriptblock]::Create($logger.Extent.Text))
    $logDirectory = $fixture
    $logPath = Join-Path $fixture 'cleanup.log'
    Write-InstallCleanupLog -Phase Leftovers -Removed 7 -Failed 1
    Write-InstallCleanupLog -Phase Backup -Removed 1 -Failed 0
    $lines = [IO.File]::ReadAllLines($logPath)
    Assert ($lines.Count -eq 2)
    Assert ($lines[0] -ceq 'Cleanup Leftovers Removed=7 Failed=1')
    Assert ($lines[1] -ceq 'Cleanup Backup Removed=1 Failed=0')
}
Write-Output "Installer copy/recovery checks: $script:passed PASS, $script:failed FAIL"
if ($script:failed -gt 0) { exit 1 }
exit 0
