param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'InstallSafety.ps1')
$script:passed = 0
$script:failed = 0
function Assert([bool]$Condition) { if (-not $Condition) { throw 'Assertion failed.' } }
function Expect-Failure([scriptblock]$Body) {
    $caught = $false
    try { $null = & $Body } catch { $caught = $true }
    Assert $caught
}
function Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name" }
}
# Synthetic fixtures remain in ignored artifacts. No installer/uninstaller execution or real deletion.
$fixture = Join-Path $root ('artifacts\safety-tests\' + [Guid]::NewGuid().ToString('N'))
$allowed = Join-Path $fixture 'allowed'
$tree = Join-Path $allowed 'AISubGauge2'
$child = Join-Path $tree 'nested'
[void][IO.Directory]::CreateDirectory($child)
$leaf = Join-Path $child 'fixture.txt'
[IO.File]::WriteAllText($leaf, 'synthetic fixture')
$outside = Join-Path $fixture 'outside'
[void][IO.Directory]::CreateDirectory($outside)
$script:attributeReader = ${function:Get-PathAttributes}
$script:blockedPath = $null
$script:deniedPath = $null
function Get-PathAttributes([string]$Path) {
    if ($Path -eq $script:blockedPath) { return [IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Directory }
    if ($Path -eq $script:deniedPath) { throw [UnauthorizedAccessException]::new('synthetic denial') }
    return & $script:attributeReader $Path
}
$script:deletions = [Collections.Generic.List[string]]::new()
function Invoke-LeafDelete([string]$Path, [bool]$Directory) { $script:deletions.Add($Path) }
Test 'installer, uninstaller and helper parse; no ignored errors or recursive deletion' {
    foreach ($file in @('install.ps1','uninstall.ps1','InstallSafety.ps1','InstallFiles.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0)
        Assert ($ast.Extent.Text -notmatch 'SilentlyContinue|Remove-Item\b|-Recurse|Move-Item')
    }
}
Test 'canonical paths reject sibling prefixes, traversal, relative paths, ADS and device aliases' {
    Assert ((Assert-SafePath $leaf $allowed) -eq $leaf)
    Assert ((Assert-SafePath (Join-Path $tree '.\nested\fixture.txt') $allowed) -eq $leaf)
    foreach ($path in @($outside, ($allowed + '-sibling\file'), (Join-Path $allowed '..\outside'), 'relative\file', ($leaf + ':stream'), (Join-Path $tree 'NUL'), (Join-Path $tree 'tail.'))) {
        Expect-Failure { Assert-SafePath $path $allowed }
    }
}
Test 'rejects reparse points at target and every ancestor, including above allowed root' {
    $node = $leaf
    try {
        while ($node) {
            $script:blockedPath = $node
            Expect-Failure { Assert-SafePath $leaf $allowed }
            $node = Split-Path $node -Parent
        }
    } finally { $script:blockedPath = $null }
}
Test 'actual junction and nonexistent leaf below it are rejected without following them' {
    $junction = Join-Path $tree 'junction'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop)
    Expect-Failure { Assert-SafePath $junction $allowed }
    Expect-Failure { Assert-SafePath (Join-Path $junction 'new.txt') $allowed }
    # No dangling link creation or cleanup is needed: missing-leaf validation must still inspect its junction ancestor.
}
Test 'access denial is never interpreted as a missing file' {
    try { $script:deniedPath = $leaf; Expect-Failure { Assert-SafePath $leaf $allowed } }
    finally { $script:deniedPath = $null }
}
Test 'directory creation rejects linked parents before writing' {
    $new = Join-Path $child 'new'
    try { $script:blockedPath = $child; Expect-Failure { New-SafeDirectory $new $allowed }; Assert (-not [IO.Directory]::Exists($new)) }
    finally { $script:blockedPath = $null }
}
# Use a separate clean tree: the intentionally retained junction above must remain rejected.
$cleanTree = Join-Path $allowed 'Clean'
$cleanChild = Join-Path $cleanTree 'nested'
[void][IO.Directory]::CreateDirectory($cleanChild)
$cleanLeaf = Join-Path $cleanChild 'fixture.txt'
[IO.File]::WriteAllText($cleanLeaf, 'synthetic fixture')
Test 'bottom-up removal checks each leaf and never deletes outside the allowed root' {
    $script:deletions.Clear()
    Clear-SafeTree $cleanTree $allowed
    Assert (($script:deletions -join '|') -eq (@($cleanLeaf, $cleanChild, $cleanTree) -join '|'))
    Expect-Failure { Clear-SafeTree $outside $allowed }
    Assert ($script:deletions.Count -eq 3)
}
Test 'tree preflight rejects links without entering them or deleting anything' {
    $script:deletions.Clear()
    Expect-Failure { Assert-SafeTree $tree $allowed }
    Assert ($script:deletions.Count -eq 0)
}
$script:childrenReader = ${function:Get-SafeChildren}
Test 'a parent swapped after enumeration is rechecked before any deletion' {
    function Get-SafeChildren([string]$Path, [string]$Root) {
        $children = & $script:childrenReader $Path $Root
        $script:blockedPath = $Path
        return $children
    }
    try {
        $script:deletions.Clear()
        Expect-Failure { Clear-SafeTree $cleanTree $allowed }
        Assert ($script:deletions.Count -eq 0)
    } finally { $script:blockedPath = $null }
}
function New-FakeKey {
    $key = [pscustomobject]@{ Names = [Collections.Generic.List[string]]::new(); Deleted = ''; FailDelete = $false; FailRead = $false; Retain = $false; Disposed = $false }
    $key.Names.Add('AISubGauge')
    $key | Add-Member ScriptMethod DeleteValue {
        param($name, $throwOnMissing)
        if ($this.FailDelete) { throw [UnauthorizedAccessException]::new('synthetic denial') }
        if ($name -cne 'AISubGauge2' -or $throwOnMissing) { throw 'Wrong value or missing-value policy.' }
        $this.Deleted = $name
        if (-not $this.Retain) { [void]$this.Names.Remove($name) }
    }
    $key | Add-Member ScriptMethod GetValueNames { if ($this.FailRead) { throw 'synthetic read failure' }; return $this.Names.ToArray() }
    $key | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    return $key
}
$script:key = $null
$script:openFails = $false
function Open-AutostartKey([bool]$Writable) { if ($script:openFails) { throw [UnauthorizedAccessException]::new('synthetic denial') }; return $script:key }
Test 'missing Run key or value is tolerated; legacy value is preserved' {
    Clear-Version2Autostart
    $script:key = New-FakeKey
    Clear-Version2Autostart
    Assert ($script:key.Names.Count -eq 1 -and $script:key.Names[0] -ceq 'AISubGauge')
}
Test 'only version 2 Run value is removed and read back' {
    $script:key = New-FakeKey; $script:key.Names.Add('AISubGauge2')
    Clear-Version2Autostart
    Assert ($script:key.Deleted -ceq 'AISubGauge2')
    Assert ($script:key.Names.Count -eq 1 -and $script:key.Names[0] -ceq 'AISubGauge')
    Assert $script:key.Disposed
}
Test 'registry access, deletion and readback errors all fail' {
    try { $script:openFails = $true; Expect-Failure { Clear-Version2Autostart } }
    finally { $script:openFails = $false }
    foreach ($failure in @('FailDelete','FailRead','Retain')) {
        $script:key = New-FakeKey; $script:key.Names.Add('AISubGauge2'); $script:key.$failure = $true
        Expect-Failure { Clear-Version2Autostart }
        Assert $script:key.Disposed
    }
}
Write-Output "Path/registry checks: $script:passed PASS, $script:failed FAIL"
if ($script:failed -gt 0) { exit 1 }
exit 0
