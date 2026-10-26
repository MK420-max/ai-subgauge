# Shared by install/uninstall. Loading this file performs no filesystem or registry mutations.
function Get-NormalPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) { throw 'Only local absolute paths are supported.' }
    # Windows normalizes trailing dots/spaces away; reject those aliases before normalization.
    foreach ($part in $Path.Replace('/', '\').Substring(3).Split('\')) {
        if ($part -notin @('.', '..') -and ($part.EndsWith('.') -or $part.EndsWith(' '))) { throw 'Unsafe path component.' }
    }
    $full = [IO.Path]::GetFullPath($Path).Replace('/', '\')
    foreach ($part in $full.Substring(3).Split('\')) {
        if ($part.EndsWith('.') -or $part.EndsWith(' ') -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Unsafe path component.' }
    }
    return $full.TrimEnd('\')
}
function Get-PathAttributes([string]$Path) {
    try { return [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
}
function Assert-SafePath([string]$Path, [string]$Root) {
    $full = Get-NormalPath $Path
    $boundary = Get-NormalPath $Root
    if (-not ($full.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($boundary + '\', [StringComparison]::OrdinalIgnoreCase))) { throw 'Path is outside the allowed root.' }
    # Inspect from the volume root down, including ancestors above the allowlisted root.
    # Never resolve through an unchecked junction, including one pointing back inside the root.
    $current = [IO.Path]::GetPathRoot($full)
    $chain = @($current)
    foreach ($part in $full.Substring(3).Split('\')) { $current = Join-Path $current $part; $chain += $current }
    foreach ($item in $chain) {
        $attributes = Get-PathAttributes $item
        if ($null -eq $attributes) { continue }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported.' }
        if ($item -ne $full -and -not ($attributes -band [IO.FileAttributes]::Directory)) { throw 'Invalid parent directory.' }
        $resolved = (Get-Item -LiteralPath $item -Force -ErrorAction Stop).FullName.TrimEnd('\')
        if (-not $resolved.Equals($item.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected final path.' }
    }
    return $full
}
function New-SafeDirectory([string]$Path, [string]$Root) {
    $full = Assert-SafePath $Path $Root
    if ($null -eq (Get-PathAttributes $full)) {
        $parent = Split-Path $full -Parent
        if ($null -eq (Get-PathAttributes $parent)) {
            # Recursion may create the allowed root, but never an ancestor outside it.
            New-SafeDirectory $parent $Root
        }
        $full = Assert-SafePath $full $Root
        [void][IO.Directory]::CreateDirectory($full)
    }
    $full = Assert-SafePath $full $Root
    if (-not ((Get-PathAttributes $full) -band [IO.FileAttributes]::Directory)) { throw 'Expected a directory.' }
}
function Get-SafeChildren([string]$Path, [string]$Root) {
    $full = Assert-SafePath $Path $Root
    return @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop | Select-Object -ExpandProperty FullName)
}
function Assert-SafeTree([string]$Path, [string]$Root) {
    $full = Assert-SafePath $Path $Root
    $attributes = Get-PathAttributes $full
    if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::Directory)) {
        foreach ($child in (Get-SafeChildren $full $Root)) { Assert-SafeTree $child $Root }
    }
}
function Invoke-LeafDelete([string]$Path, [bool]$Directory) {
    # Never use recursive deletion: a newly appeared child makes directory removal fail.
    if ($Directory) { [IO.Directory]::Delete($Path, $false) } else { [IO.File]::Delete($Path) }
}
function Clear-SafeTree([string]$Path, [string]$Root) {
    $full = Assert-SafePath $Path $Root
    $attributes = Get-PathAttributes $full
    if ($null -eq $attributes) { return }
    $directory = [bool]($attributes -band [IO.FileAttributes]::Directory)
    if ($directory) {
        foreach ($child in (Get-SafeChildren $full $Root)) { Clear-SafeTree $child $Root }
    }
    # Recheck every ancestor and this item immediately before each bottom-up deletion.
    $full = Assert-SafePath $full $Root
    $attributes = Get-PathAttributes $full
    if ($null -eq $attributes) { return }
    if ([bool]($attributes -band [IO.FileAttributes]::Directory) -ne $directory) { throw 'Removal target changed.' }
    Invoke-LeafDelete $full $directory
}
function Open-AutostartKey([bool]$Writable) {
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $Writable)
}
function Clear-Version2Autostart {
    $key = Open-AutostartKey $true
    if ($null -ne $key) {
        try {
            # false tolerates only a missing value; access/I/O errors still throw.
            $key.DeleteValue('AISubGauge2', $false)
            if ($key.GetValueNames() -contains 'AISubGauge2') { throw 'Autostart removal failed.' }
        } finally { $key.Dispose() }
    }
    $check = Open-AutostartKey $false
    if ($null -ne $check) {
        try { if ($check.GetValueNames() -contains 'AISubGauge2') { throw 'Autostart removal failed.' } }
        finally { $check.Dispose() }
    }
}
function Stop-Version2Process([string]$Executable, [string]$Root, [int]$TimeoutMilliseconds = 5000) {
    $Executable = Assert-SafePath $Executable $Root
    foreach ($process in (Get-Process -ErrorAction Stop)) {
        try {
            if ($process.ProcessName -eq 'AISubGauge2' -and
                [string]::Equals($process.Path, $Executable, [StringComparison]::OrdinalIgnoreCase)) {
                [void](Assert-SafePath $Executable $Root)
                # Use the matched process object, not a fresh lookup by a possibly reused PID.
                if (-not $process.HasExited) { $process.Kill() }
                if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                    throw [TimeoutException]::new('Version 2 process exit timed out.')
                }
            }
        } finally { $process.Dispose() }
    }
}
