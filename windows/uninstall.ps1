param([switch]$KeepSettings)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'InstallSafety.ps1')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $programs = Join-Path $local 'Programs'
    $settings = Join-Path $local 'AISubGauge2'
    # Shortcuts have a separate, exact per-user Start Menu root; nothing else there is owned.
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'AISubGauge2'
    $targets = @(
        @{ Path = Join-Path $programs 'AISubGauge2'; Root = $programs },
        @{ Path = $menu; Root = $menu }
    )
    if (-not $KeepSettings) { $targets += @{ Path = $settings; Root = $settings } }
    foreach ($target in $targets) { Assert-SafeTree $target.Path $target.Root }
    $installedExe = Join-Path $targets[0].Path 'AISubGauge2.exe'
    Stop-Version2Process $installedExe $programs
    Clear-Version2Autostart
    foreach ($target in $targets) { Clear-SafeTree $target.Path $target.Root }
    Write-Output 'AI SubGauge 2 uninstalled successfully.'
    exit 0
} catch {
    Write-Error 'AI SubGauge 2 could not be fully removed. Check directory and registry permissions.' -ErrorAction Continue
    exit 1
}
