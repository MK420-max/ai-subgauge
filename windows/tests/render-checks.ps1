# Run on an interactive Windows desktop after a Release build. All rendering is offline.
param([string]$Executable = "$PSScriptRoot/../src/AISubGauge/bin/Release/net8.0-windows/AISubGauge.exe")
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Requires Windows and PowerShell 7.' }
Add-Type -AssemblyName System.Drawing
$root = Join-Path $PSScriptRoot ('artifacts/render-' + [Guid]::NewGuid().ToString('N'))
function Render([string]$Mode, [string]$Directory, [string]$Theme, [string]$Language) {
    $info = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $Executable).Path)
    $info.UseShellExecute = $false
    $info.Environment['AISUBGAUGE_SETTINGS_DIR'] = Join-Path $root 'settings'
    foreach ($argument in @($Mode, $Directory, '--theme', $Theme, '--lang', $Language)) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(15000)) { $process.Kill($true); $null = $process.WaitForExit(2000); throw 'Render timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Render failed.' }
    } finally { $process.Dispose() }
}
function Compare-Pixels([string]$First, [string]$Second) {
    $a = [Drawing.Bitmap]::new($First); $b = [Drawing.Bitmap]::new($Second)
    try {
        if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) { return [int]::MaxValue }
        $count = 0
        for ($y = 0; $y -lt $a.Height; $y++) { for ($x = 0; $x -lt $a.Width; $x++) {
            if ($a.GetPixel($x, $y).ToArgb() -ne $b.GetPixel($x, $y).ToArgb()) { $count++ } } }
        return $count
    } finally { $a.Dispose(); $b.Dispose() }
}
$previews = Join-Path $root 'previews'
$screenshots = Join-Path $root 'screenshots'
foreach ($theme in @('light', 'dark')) {
    foreach ($language in @('en', 'zh-Hans')) {
        $suffix = "$theme-$language"
        Render '--render-preview' $previews $theme $language
        Render '--screenshot' $screenshots $theme $language
        foreach ($kind in @('panel', 'error', 'tray', 'idle')) {
            $name = "win-$kind-$suffix.png"
            $path = Join-Path $previews $name
            if (-not (Test-Path -LiteralPath $path)) { throw "Missing $name" }
            $image = [Drawing.Bitmap]::new($path)
            try {
                switch ($kind) {
                    'tray' { if ($image.Width -ne 288 -or $image.Height -ne 96) { throw 'Expected three 24px icons at 4x.' } }
                    'idle' { if ($image.Width -ne 192 -or $image.Height -ne 192) { throw 'Expected a 24px idle icon at 8x.' } }
                    default {
                        if ($image.Width -ne 440 -or $image.Height -ne 350) { throw 'Expected the Mac 440x350 panel dimensions.' }
                        if ($image.GetPixel(0, 0).A -ne 0) { throw 'Panel corners should be transparent.' }
                        $fill = $image.GetPixel(100, 95)
                        if ($fill.R -ne 44 -or $fill.G -ne 172 -or $fill.B -ne 109) { throw 'Codex bar must preserve the existing green quota color.' }
                    }
                }
            } finally { $image.Dispose() }
            # GDI+ text anti-aliasing can differ by a handful of pixels between processes; allow <= 16.
            if ((Compare-Pixels $path (Join-Path $screenshots $name)) -gt 16) {
                throw "Screenshot and preview differ: $name"
            }
        }
        if ((Get-FileHash (Join-Path $previews "win-panel-$suffix.png")).Hash -eq
            (Get-FileHash (Join-Path $previews "win-error-$suffix.png")).Hash) { throw 'Error example must differ from the panel.' }
    }
    if ((Get-FileHash (Join-Path $previews "win-panel-$theme-en.png")).Hash -eq
        (Get-FileHash (Join-Path $previews "win-panel-$theme-zh-Hans.png")).Hash) { throw 'Language previews must differ.' }
}
if ((Get-FileHash (Join-Path $previews 'win-panel-light-en.png')).Hash -eq
    (Get-FileHash (Join-Path $previews 'win-panel-dark-en.png')).Hash) { throw 'Theme previews must differ.' }
if (Test-Path -LiteralPath (Join-Path $root 'settings/settings.json')) { throw 'Offline rendering must not create settings.' }
Write-Host "PASS: four theme/language combinations, both offline export commands, artifacts at $root"
