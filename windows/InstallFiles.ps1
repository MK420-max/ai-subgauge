# Function-only installer operations. Tests inject a Programs root inside the repository.
# Load this helper and InstallSafety.ps1 from the extracted package, never the install target.
function Get-Version2PackageFiles {
    # Publish the executable last so a supporting-file failure leaves the previous EXE intact.
    return @('uninstall.ps1','InstallSafety.ps1','README.md','LICENSE','THIRD_PARTY_NOTICES.md','DOTNET-NOTICES.txt','AISubGauge2.exe')
}
function Assert-InstallPath([string]$Path, [string]$Root) {
    try { return Assert-SafePath $Path $Root }
    catch {
        $_.Exception.Data['InstallCategory'] = 'SafetyRejected'
        throw
    }
}
function Test-InstallTemporaryName([string]$Name) {
    # Exactly the case-sensitive names generated below; never accept arbitrary .installing files.
    $payloadNames = ((Get-Version2PackageFiles) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    return ($Name -cmatch '\AAISubGauge2\.[0-9a-f]{32}\.(backup|failed)\.exe\z' -or
        $Name -cmatch ('\A\.(' + $payloadNames + ')\.[0-9a-f]{32}\.installing\z'))
}
function Clear-InstallTemporaryFile([string]$Path, [string]$ProgramsRoot) {
    $target = Assert-InstallPath (Join-Path $ProgramsRoot 'AISubGauge2') $ProgramsRoot
    if (-not [IO.Path]::GetDirectoryName($Path).Equals($target, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-InstallTemporaryName ([IO.Path]::GetFileName($Path)))) { throw 'Invalid temporary file.' }
    $attributes = Get-PathAttributes $Path
    if ($null -eq $attributes -or ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))) { return $false }
    $safe = Assert-InstallPath $Path $ProgramsRoot
    # Recheck the leaf immediately before deletion; no directory or link deletion is permitted.
    $attributes = Get-PathAttributes $safe
    if ($null -eq $attributes -or ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))) { return $false }
    [IO.File]::Delete($safe)
    return $true
}
function Clear-Version2InstallLeftovers([string]$ProgramsRoot) {
    $target = Assert-InstallPath (Join-Path $ProgramsRoot 'AISubGauge2') $ProgramsRoot
    $counts = @{ Removed = 0; Failed = 0 }
    if ([IO.Directory]::Exists($target)) {
        # Get-SafeChildren enumerates this directory only, including hidden staging files.
        foreach ($path in (Get-SafeChildren $target $ProgramsRoot)) {
            if (-not (Test-InstallTemporaryName ([IO.Path]::GetFileName($path)))) { continue }
            try { if (Clear-InstallTemporaryFile $path $ProgramsRoot) { $counts.Removed++ } }
            catch { $counts.Failed++ }
        }
    }
    return [pscustomobject]$counts
}
function Clear-Version2CompletedBackup([string]$ProgramsRoot, [hashtable]$Recovery) {
    $counts = @{ Removed = 0; Failed = 0 }
    if ($Recovery.ExeBackup) {
        try {
            if ([IO.Path]::GetFileName($Recovery.ExeBackup) -cnotmatch '\AAISubGauge2\.[0-9a-f]{32}\.backup\.exe\z') { throw 'Invalid recovery backup.' }
            if (Clear-InstallTemporaryFile $Recovery.ExeBackup $ProgramsRoot) { $counts.Removed++ }
        } catch { $counts.Failed++ }
    }
    return [pscustomobject]$counts
}
function Get-InstallFailure([Exception]$Exception) {
    $category = 'Other'
    $hresult = $Exception.HResult
    while ($null -ne $Exception) {
        if ($Exception.Data['InstallCategory'] -eq 'SafetyRejected') { $category = 'SafetyRejected' }
        $hresult = $Exception.HResult
        $Exception = $Exception.InnerException
    }
    if ($category -ne 'SafetyRejected' -and $hresult -in @(-2147024864, -2147024863)) {
        # HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION).
        $category = 'SharingViolation'
    }
    return [pscustomobject]@{ Category = $category; HResult = [int]$hresult }
}
function Invoke-InstallIoWithRetry {
    param([scriptblock]$Action, [int]$Attempts = 8, [int]$DelayMilliseconds = 150)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try { return & $Action }
        catch {
            $failure = Get-InstallFailure $_.Exception
            if ($failure.Category -ne 'SharingViolation' -or $attempt -eq $Attempts) { throw }
            Start-Sleep -Milliseconds ([Math]::Min($DelayMilliseconds * $attempt, 600))
        }
    }
}
function Assert-Version2Package([string]$Source, [string]$ProgramsRoot) {
    $target = Assert-InstallPath (Join-Path $ProgramsRoot 'AISubGauge2') $ProgramsRoot
    $sourcePath = Assert-InstallPath $Source $Source
    if ($sourcePath.Equals($target, [StringComparison]::OrdinalIgnoreCase) -or
        $sourcePath.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $error = [InvalidOperationException]::new('Package must be separate from the install target.')
        $error.Data['InstallCategory'] = 'SafetyRejected'
        throw $error
    }
    foreach ($file in (Get-Version2PackageFiles)) {
        $inputPath = Assert-InstallPath (Join-Path $sourcePath $file) $sourcePath
        if (-not [IO.File]::Exists($inputPath)) { throw [IO.FileNotFoundException]::new('Package file is missing.') }
        $destination = Assert-InstallPath (Join-Path $target $file) $ProgramsRoot
        if ([IO.Directory]::Exists($destination)) {
            $error = [InvalidOperationException]::new('Destination must be a file.')
            $error.Data['InstallCategory'] = 'SafetyRejected'
            throw $error
        }
    }
}
function Copy-Version2Package([string]$Source, [string]$ProgramsRoot, [hashtable]$Recovery = @{}) {
    Assert-Version2Package $Source $ProgramsRoot
    $target = Assert-InstallPath (Join-Path $ProgramsRoot 'AISubGauge2') $ProgramsRoot
    New-SafeDirectory $target $ProgramsRoot
    # Keep the previous EXE in the same directory, with a unique name, before replacing any payload.
    $oldExe = Assert-InstallPath (Join-Path $target 'AISubGauge2.exe') $ProgramsRoot
    if ([IO.File]::Exists($oldExe)) {
        $backup = Assert-InstallPath (Join-Path $target ('AISubGauge2.' + [Guid]::NewGuid().ToString('N') + '.backup.exe')) $ProgramsRoot
        Invoke-InstallIoWithRetry {
            [void](Assert-InstallPath $oldExe $ProgramsRoot)
            [void](Assert-InstallPath $backup $ProgramsRoot)
            [IO.File]::Copy($oldExe, $backup, $false)
        }
        $Recovery.ExeBackup = $backup
    }
    foreach ($file in (Get-Version2PackageFiles)) {
        # Stage in the same directory/volume; never truncate a live destination.
        $temporary = Invoke-InstallIoWithRetry {
            $inputPath = Assert-InstallPath (Join-Path $Source $file) $Source
            $stagingPath = Assert-InstallPath (Join-Path $target ('.' + $file + '.' + [Guid]::NewGuid().ToString('N') + '.installing')) $ProgramsRoot
            [IO.File]::Copy($inputPath, $stagingPath, $false)
            return $stagingPath
        }
        Invoke-InstallIoWithRetry {
            $temporary = Assert-InstallPath $temporary $ProgramsRoot
            $destination = Assert-InstallPath (Join-Path $target $file) $ProgramsRoot
            if ([IO.File]::Exists($destination)) {
                # Windows PowerShell coerces $null to an empty string for this overload.
                [IO.File]::Replace($temporary, $destination, [NullString]::Value)
            } else {
                [IO.File]::Move($temporary, $destination)
            }
        }
        # Successful replacement consumes the staging file. Failure retains it until a later install.
    }
}
function Start-Version2Application([string]$ProgramsRoot) {
    $target = Assert-InstallPath (Join-Path $ProgramsRoot 'AISubGauge2') $ProgramsRoot
    $executable = Assert-InstallPath (Join-Path $target 'AISubGauge2.exe') $ProgramsRoot
    if (-not [IO.File]::Exists($executable)) { throw [IO.FileNotFoundException]::new('Version 2 executable is missing.') }
    Start-Process -FilePath $executable -WorkingDirectory $target -WindowStyle Hidden
}
function Resume-Version2AfterFailure([bool]$HadPreviousExe, [string]$ProgramsRoot, [hashtable]$Recovery = @{}) {
    if (-not $HadPreviousExe) { return $false }
    $executable = Assert-InstallPath (Join-Path $ProgramsRoot 'AISubGauge2\AISubGauge2.exe') $ProgramsRoot
    if ($Recovery.ExeBackup) {
        $backup = Assert-InstallPath $Recovery.ExeBackup $ProgramsRoot
        if (-not [IO.Path]::GetDirectoryName($backup).Equals([IO.Path]::GetDirectoryName($executable), [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($backup) -cnotmatch '^AISubGauge2\.[a-f0-9]{32}\.backup\.exe$') { throw 'Invalid recovery backup.' }
        # A later launch/logging failure may have started the replacement already.
        Stop-Version2Process $executable $ProgramsRoot
        Invoke-InstallIoWithRetry {
            [void](Assert-InstallPath $backup $ProgramsRoot)
            [void](Assert-InstallPath $executable $ProgramsRoot)
            # Preserve the backup even after recovery; publish a copy through the same staging pattern.
            $temporary = Assert-InstallPath (Join-Path ([IO.Path]::GetDirectoryName($executable)) ('.AISubGauge2.exe.' + [Guid]::NewGuid().ToString('N') + '.installing')) $ProgramsRoot
            [IO.File]::Copy($backup, $temporary, $false)
            [void](Assert-InstallPath $temporary $ProgramsRoot)
            [void](Assert-InstallPath $executable $ProgramsRoot)
            if ([IO.File]::Exists($executable)) {
                $retained = Assert-InstallPath (Join-Path ([IO.Path]::GetDirectoryName($executable)) ('AISubGauge2.' + [Guid]::NewGuid().ToString('N') + '.failed.exe')) $ProgramsRoot
                [IO.File]::Replace($temporary, $executable, $retained)
            } else { [IO.File]::Move($temporary, $executable) }
        }
    }
    if (-not [IO.File]::Exists($executable)) { return $false }
    Start-Version2Application $ProgramsRoot
    return $true
}
