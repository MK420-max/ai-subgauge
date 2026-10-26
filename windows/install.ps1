param()
$ErrorActionPreference = 'Stop'
# No elevation; this installer owns only the version 2 directory and Run value.
# Allowlisted fields only: never pass exception text, paths or environment values to the log.
function Write-InstallLog {
    param(
        [ValidateSet('Started','Succeeded','Failed')][string]$Status,
        [ValidateSet('Initialize','ValidatePackage','CopyFiles','Shortcuts','Autostart','Launch','Recovery','Completed')][string]$Stage,
        [ValidateSet('None','SharingViolation','SafetyRejected','Other')][string]$Category = 'None',
        [int]$HResult = 0
    )
    $line = '{0} {1} {2}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Status, $Stage
    if ($Category -ne 'None') { $line += ':{0} HResult={1}' -f $Category, $HResult }
    [void](Assert-SafePath $logPath $logDirectory)
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}
function Write-InstallCleanupLog {
    param(
        [ValidateSet('Leftovers','Backup')][string]$Phase,
        [ValidateRange(0,2147483647)][int]$Removed,
        [ValidateRange(0,2147483647)][int]$Failed
    )
    [void](Assert-SafePath $logPath $logDirectory)
    Add-Content -LiteralPath $logPath -Value ('Cleanup {0} Removed={1} Failed={2}' -f $Phase, $Removed, $Failed) -Encoding UTF8
}
$logReady = $false
$stage = 'Initialize'
$recoverPrevious = $false
$recovery = @{}
try {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $programs = Join-Path $local 'Programs'
    $target = Join-Path $programs 'AISubGauge2'
    # Reject running from the installation tree BEFORE loading either helper.
    $packageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if ($packageRoot.Equals($target, [StringComparison]::OrdinalIgnoreCase) -or
        $packageRoot.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run the installer from a separate extracted package.'
    }
    . (Join-Path $PSScriptRoot 'InstallSafety.ps1')
    [void](Assert-SafePath $PSScriptRoot $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'InstallFiles.ps1')
    $logDirectory = Join-Path $local 'AISubGauge2'
    $logPath = Join-Path $logDirectory 'install.log'
    New-SafeDirectory $logDirectory $logDirectory
    # Keep only the latest attempt so the installation log stays short.
    [void](Assert-SafePath $logPath $logDirectory)
    Set-Content -LiteralPath $logPath -Value '' -Encoding UTF8
    $logReady = $true
    Write-InstallLog -Status Started -Stage $stage
    $target = Assert-InstallPath $target $programs
    $cleanup = Clear-Version2InstallLeftovers $programs
    Write-InstallCleanupLog -Phase Leftovers -Removed $cleanup.Removed -Failed $cleanup.Failed
    $stage = 'ValidatePackage'
    Assert-Version2Package $PSScriptRoot $programs
    $stage = 'CopyFiles'
    $recoverPrevious = [IO.File]::Exists((Join-Path $target 'AISubGauge2.exe'))
    Stop-Version2Process (Join-Path $target 'AISubGauge2.exe') $programs
    Copy-Version2Package $PSScriptRoot $programs $recovery
    $stage = 'Shortcuts'
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'AISubGauge2'
    New-SafeDirectory $menu $menu
    $shell = New-Object -ComObject WScript.Shell
    $shortcutPath = Assert-SafePath (Join-Path $menu 'AI SubGauge 2.lnk') $menu
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $target 'AISubGauge2.exe'
    $shortcut.WorkingDirectory = $target
    $shortcut.Description = 'AI SubGauge 2'
    [void](Assert-SafePath $shortcutPath $menu)
    $shortcut.Save()
    $uninstallPath = Assert-SafePath (Join-Path $menu 'Uninstall AI SubGauge 2.lnk') $menu
    $uninstall = $shell.CreateShortcut($uninstallPath)
    $uninstall.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $uninstall.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $target 'uninstall.ps1') + '"'
    [void](Assert-SafePath $uninstallPath $menu)
    $uninstall.Save()
    $stage = 'Autostart'
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $run)) { [void](New-Item -Path $run) }
    [void](New-ItemProperty -Path $run -Name AISubGauge2 -Value ('"' + (Join-Path $target 'AISubGauge2.exe') + '" --autostart') -PropertyType String -Force)
    $stage = 'Launch'
    Start-Version2Application $programs
    Write-InstallLog -Status Succeeded -Stage Completed
    $stage = 'Completed'
    $cleanup = Clear-Version2CompletedBackup $programs $recovery
    # Completion is final. A cleanup/logging failure must not roll back a running installation.
    try { Write-InstallCleanupLog -Phase Backup -Removed $cleanup.Removed -Failed $cleanup.Failed } catch { }
    Write-Output 'AI SubGauge 2 installed successfully.'
    exit 0
} catch {
    $installError = $_.Exception
    # Logging failure must not hide the original failure or change the exit code.
    if ($logReady) {
        try {
            $failure = Get-InstallFailure $installError
            Write-InstallLog -Status Failed -Stage $stage -Category $failure.Category -HResult $failure.HResult
        } catch { }
    }
    # Recover even if logging failed. Only a pre-existing version 2 target is eligible.
    if ($recoverPrevious -and $stage -ne 'Completed') {
        try {
            if (Resume-Version2AfterFailure $recoverPrevious $programs $recovery) {
                if ($logReady) { try { Write-InstallLog -Status Succeeded -Stage Recovery } catch { } }
            }
        } catch {
            if ($logReady) {
                try {
                    $failure = Get-InstallFailure $_.Exception
                    Write-InstallLog -Status Failed -Stage Recovery -Category $failure.Category -HResult $failure.HResult
                } catch { }
            }
        }
    }
    Write-Error 'AI SubGauge 2 installation failed. Check package files and directory permissions. See %LOCALAPPDATA%\AISubGauge2\install.log if available.' -ErrorAction Continue
    exit 1
}

