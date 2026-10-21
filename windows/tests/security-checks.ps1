# Run after a Windows build with PowerShell 7.4+ (.NET 8); never starts a provider CLI or calls an API.
param([Parameter(Mandatory = $true)][string]$AssemblyPath)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Environment]::Version.Major -lt 8) { throw 'Requires Windows and PowerShell on .NET 8+.' }
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path)
$flags = [Reflection.BindingFlags]'Public, NonPublic, Static'
$local = 'AISubGauge.LocalFiles'
$codex = 'AISubGauge.Providers.CodexProvider'
$grok = 'AISubGauge.Providers.GrokCliRefresh'
$root = Join-Path $PSScriptRoot ('artifacts/security-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$passed = 0

function Invoke-Static([string]$Type, [string]$Method, [object[]]$Arguments) {
    $member = $assembly.GetType($Type, $true).GetMethod($Method, $flags)
    # Unwrap PSObject wrappers (e.g. from Join-Path) so reflection sees the real CLR types.
    $plain = [object[]]::new($Arguments.Count)
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $value = $Arguments[$i]
        $plain[$i] = if ($value -is [psobject]) { $value.psobject.BaseObject } else { $value }
    }
    return ,$member.Invoke($null, $plain)
}
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:passed++
}
function Reject([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try {
        $value = & $Action
        if ($value -is [IDisposable]) { $value.Dispose() }
    } catch { $rejected = $true }
    Check $rejected $Name
}
function New-Reader([byte[]]$Bytes) {
    $type = $assembly.GetType($codex, $true).GetNestedType('RpcOutput', [Reflection.BindingFlags]::NonPublic)
    $stream = [IO.MemoryStream]::new($Bytes, $false)
    $reader = $type.GetConstructor([Type[]]@([IO.Stream])).Invoke([object[]]@($stream))
    return @{ Stream = $stream; Reader = $reader; Method = $type.GetMethod('ReadLineAsync') }
}
function Read-Line($Fixture) {
    $task = $Fixture.Method.Invoke($Fixture.Reader, [object[]]@([Threading.CancellationToken]::None))
    return $task.GetAwaiter().GetResult()
}
function Run-DemoStatus([string]$Path) {
    $info = [Diagnostics.ProcessStartInfo]::new([IO.Path]::ChangeExtension($assembly.Location, '.exe'))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['AISUBGAUGE_SETTINGS_DIR'] = Join-Path $root 'settings'
    foreach ($argument in @('--demo', '--status', $Path)) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(10000)) {
            $process.Kill($true)
            $null = $process.WaitForExit(2000)
            throw 'Demo status process timed out.'
        }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

$saved = @{}
foreach ($name in @('PATH', 'CODEX_HOME', 'CODEX_EXE', 'GROK_AUTH_PATH', 'CLAUDE_CODE_OAUTH_TOKEN',
    'COPILOT_GITHUB_TOKEN', 'KIMI_CODE_API_KEY', 'Z_AI_API_KEY', 'OPENAI_API_KEY', 'QUOTA_TEST_SECRET', 'AISUBGAUGE_SETTINGS_DIR',
    'GROK_TELEMETRY_ENABLED', 'GROK_EXTERNAL_OTEL')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    [Environment]::SetEnvironmentVariable('AISUBGAUGE_SETTINGS_DIR', (Join-Path $root 'settings'))
    $file = Join-Path $root 'ordinary.json'
    [IO.File]::WriteAllText($file, '{}')
    $stream = Invoke-Static $local 'OpenRead' @($file, [long]1048576)
    try { Check ($stream.ReadByte() -eq 123) 'ordinary credential file can be read' } finally { $stream.Dispose() }
    foreach ($path in @('.\auth.json', 'C:auth.json', '\\server\share\auth.json', '\\?\C:\auth.json',
        '\\.\NUL', '\??\C:\auth.json', ($file + ':secret'), (Join-Path $root 'NUL.json'))) {
        Reject { Invoke-Static $local 'OpenRead' @($path, [long]1048576) } "unsafe path rejected: $path"
    }
    Reject { Invoke-Static $local 'OpenRead' @($root, [long]1048576) } 'directory cannot be read as a credential'
    $large = Join-Path $root 'large.json'
    [IO.File]::WriteAllBytes($large, [byte[]]::new(1048577))
    Reject { Invoke-Static $local 'OpenRead' @($large, [long]1048576) } 'oversized credential rejected before reading'
    Reject { Invoke-Static $local 'Exists' @($large) } 'oversized file is not treated as missing'
    Check (-not (Invoke-Static $local 'Exists' @((Join-Path $root 'missing.json')))) 'missing file is absent'
    Check (-not (Invoke-Static $local 'Exists' @((Join-Path $root 'missing/auth.json')))) 'missing directory is absent'
    $codexHome = Join-Path $root 'codex-oversized'
    [IO.Directory]::CreateDirectory($codexHome) | Out-Null
    [IO.File]::Copy($large, (Join-Path $codexHome 'auth.json'))
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexHome)
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', 'synthetic-key')
    Reject { Invoke-Static $codex 'ValidateLocalCredential' @() } 'Codex validates oversized credentials with an API key set'
    [Environment]::SetEnvironmentVariable('CODEX_HOME', (Join-Path $root 'missing'))
    Check (-not (Invoke-Static $codex 'ValidateLocalCredential' @())) 'Codex treats only a missing credential as absent'

    foreach ($length in @(1048576, 1048577)) {
        $source = [IO.MemoryStream]::new([byte[]]::new($length), $false)
        try {
            $read = {
                $task = Invoke-Static 'AISubGauge.Providers.GrokProvider' 'ReadBoundedAsync' @(
                    $source, 1048576, [Threading.CancellationToken]::None)
                $task.GetAwaiter().GetResult()
            }
            if ($length -eq 1048576) { Check ((& $read).Length -eq $length) '1 MiB actual stream read accepted' }
            else { Reject $read 'stream exceeding 1 MiB rejected, even without a Content-Length' }
        } finally { $source.Dispose() }
    }

    $exe = Join-Path $root 'codex.exe'
    $cmd = Join-Path $root 'codex.cmd'
    [IO.File]::WriteAllText($exe, 'fixture only; never executed')
    [IO.File]::WriteAllText($cmd, 'fixture only; never executed')
    Reject { Invoke-Static $codex 'TrustedExecutable' @($exe) } 'unsigned absolute local exe rejected'
    Check ($null -eq (Invoke-Static $codex 'TrustedExecutable' @($cmd))) 'cmd rejected'
    foreach ($value in @('.\codex.exe', $cmd, '\\server\share\codex.exe')) {
        [Environment]::SetEnvironmentVariable('CODEX_EXE', $value)
        Reject { Invoke-Static $codex 'FindExecutable' @() } 'invalid CODEX_EXE fails without falling back'
    }
    [Environment]::SetEnvironmentVariable('CODEX_EXE', $exe)
    Reject { Invoke-Static $codex 'FindExecutable' @() } 'explicit unsigned exe rejected without fallback'
    [Environment]::SetEnvironmentVariable('PATH', ".;relative;;$root;\\server\share")
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $root)
    foreach ($name in @('CLAUDE_CODE_OAUTH_TOKEN', 'COPILOT_GITHUB_TOKEN', 'KIMI_CODE_API_KEY',
        'Z_AI_API_KEY', 'OPENAI_API_KEY', 'QUOTA_TEST_SECRET')) { [Environment]::SetEnvironmentVariable($name, 'sentinel') }
    $info = Invoke-Static $codex 'CreateStartInfo' @($exe)
    $allowed = @('SystemRoot', 'windir', 'TEMP', 'TMP', 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA',
        'PATH', 'CODEX_HOME', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432', 'ComSpec', 'PATHEXT')
    Check (@($info.Environment.Keys | Where-Object { $_ -notin $allowed }).Count -eq 0) 'child environment contains only whitelist names'
    Check ($info.Environment['PATH'] -eq $root) 'child PATH drops empty, relative and network directories'
    Check (-not $info.UseShellExecute -and $info.FileName -eq $exe) 'exe launched directly without a shell'
    [Environment]::SetEnvironmentVariable('GROK_TELEMETRY_ENABLED', '1')
    [Environment]::SetEnvironmentVariable('GROK_EXTERNAL_OTEL', '1')
    $grokInfo = Invoke-Static $grok 'CreateStartInfo' @($exe, $root, (Join-Path $root 'fixture-auth.json'))
    $grokAllowed = @('SystemRoot', 'windir', 'TEMP', 'TMP', 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA',
        'PATH', 'GROK_HOME', 'GROK_AUTH_PATH', 'GROK_LOG_FILE', 'RUST_LOG', 'GROK_TELEMETRY_ENABLED', 'GROK_EXTERNAL_OTEL',
        'ComSpec', 'PATHEXT', 'PROCESSOR_ARCHITECTURE')
    Check (@($grokInfo.Environment.Keys | Where-Object { $_ -notin $grokAllowed }).Count -eq 0) 'Grok child environment uses its exact allowlist'
    Check ($grokInfo.Environment['GROK_LOG_FILE'] -ceq 'NUL') 'Grok child log file is forced to NUL'
    Check ($grokInfo.Environment['RUST_LOG'] -ceq 'off') 'Grok child Rust logging is forced off'
    Check ($grokInfo.Environment['GROK_TELEMETRY_ENABLED'] -ceq '0') 'Grok child telemetry is forced off'
    Check ($grokInfo.Environment['GROK_EXTERNAL_OTEL'] -ceq '0') 'Grok child external OTEL is forced off'
    Check (-not $grokInfo.UseShellExecute) 'Grok starts without a shell'
    Reject { Invoke-Static $grok 'OpenExecutable' @($cmd) } 'Grok rejects CMD'
    Reject { Invoke-Static $grok 'OpenExecutable' @('.\grok.exe') } 'Grok rejects relative executable'
    Check ($assembly.GetName().Name -eq 'AISubGauge' -and $assembly.GetName().Version.ToString() -eq '1.2.0.0') 'assembly name and version'
    Check ($assembly.GetManifestResourceNames() -contains 'WindowsQuotaTray.assets.logos.grok.png') 'public Lobe Grok logo is embedded'
    $grokProvider = [Activator]::CreateInstance($assembly.GetType('AISubGauge.Providers.GrokProvider', $true))
    Check ($assembly.GetManifestResourceNames() -contains $grokProvider.LogoResource) 'selected Grok logo is embedded with or without private artwork'

    $aclFile = Join-Path $root 'broad-readable.json'
    [IO.File]::WriteAllText($aclFile, '{}')
    $acl = Get-Acl -LiteralPath $aclFile
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-1-0'), [Security.AccessControl.FileSystemRights]::Read,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $aclFile -AclObject $acl
    $aclStream = Invoke-Static $local 'OpenRead' @($aclFile, [long]1048576)
    $credentialKind = [Enum]::Parse($assembly.GetType('AISubGauge.Providers.CredentialKind', $true), 'Default')
    try { Reject { Invoke-Static 'AISubGauge.Providers.CredentialAccess' 'Validate' @($aclStream, $false, $credentialKind, $null) } 'Everyone-readable credential rejected' }
    finally { $aclStream.Dispose() }

    foreach ($extra in @(0, 1)) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(('é' * (524288 + $extra)) + "`n")
        $fixture = New-Reader $bytes
        try {
            if ($extra -eq 0) { Check ((Read-Line $fixture).Length -eq 524288) 'single line limit counts UTF-8 bytes'
                Check ($null -eq (Read-Line $fixture)) 'EOF after a complete line' }
            else { Reject { Read-Line $fixture } 'line over 1 MiB rejected' }
        } finally { $fixture.Stream.Dispose() }
    }
    $fixture = New-Reader ([Text.Encoding]::UTF8.GetBytes('x' * 1048577))
    try { Reject { Read-Line $fixture } 'unterminated oversized line rejected' } finally { $fixture.Stream.Dispose() }
    $fixture = New-Reader ([Text.Encoding]::UTF8.GetBytes("one`r`ntwo"))
    try {
        Check ((Read-Line $fixture) -eq 'one') 'CRLF supported'
        Check ((Read-Line $fixture) -eq 'two') 'EOF without trailing newline supported'
    } finally { $fixture.Stream.Dispose() }
    foreach ($lines in @(4096, 4097)) {
        $fixture = New-Reader ([Text.Encoding]::UTF8.GetBytes((('x' * 1023) + "`n") * $lines))
        try {
            $readAll = { while ($null -ne (Read-Line $fixture)) { } }
            if ($lines -eq 4096) { & $readAll; Check $true '4 MiB total accepted across many lines' }
            else { Reject $readAll 'cumulative stdout over 4 MiB rejected' }
        } finally { $fixture.Stream.Dispose() }
    }

    Reject { Invoke-Static $local 'CreateStatusFile' @($file) } 'existing status target rejected'
    Check ([IO.File]::ReadAllText($file) -eq '{}') 'existing content unchanged'
    [Environment]::SetEnvironmentVariable('GROK_AUTH_PATH', (Join-Path $root 'new-credential.json'))
    Reject { Invoke-Static $local 'CreateStatusFile' @($env:GROK_AUTH_PATH) } 'nonexistent configured credential target rejected'
    Check (-not [IO.File]::Exists($env:GROK_AUTH_PATH)) 'credential target never created'
    Reject { Invoke-Static $local 'CreateStatusFile' @((Join-Path $root 'auth.json')) } 'CODEX_HOME auth target rejected'
    $output = Join-Path $root 'nested/status.json'
    $stream = Invoke-Static $local 'CreateStatusFile' @($output)
    try { $stream.WriteByte(123) } finally { $stream.Dispose() }
    Check ([IO.File]::ReadAllText($output) -eq '{') 'new status file and safe parent directories created'
    $target = Join-Path $root 'junction-target'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'ordinary.json'), '{}')
    $junction = Join-Path $root 'junction'
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    Reject { Invoke-Static $local 'OpenRead' @((Join-Path $junction 'ordinary.json'), [long]1048576) } 'credential parent junction rejected'
    Reject { Invoke-Static $local 'Exists' @((Join-Path $junction 'ordinary.json')) } 'credential parent junction is not treated as missing'
    Reject { Invoke-Static $local 'CreateStatusFile' @((Join-Path $junction 'through-link.json')) } 'status parent junction rejected'
    Check (-not [IO.File]::Exists((Join-Path $target 'through-link.json'))) 'no output created through junction'
    $hardlink = Join-Path $root 'credential-hardlink.json'
    New-Item -ItemType HardLink -Path $hardlink -Target $file | Out-Null
    Reject { Invoke-Static $local 'CreateStatusFile' @($hardlink) } 'existing hard link target rejected'
    try { $link = [IO.File]::CreateSymbolicLink((Join-Path $root 'file-link.json'), $file) }
    catch { Write-Host 'SKIP: file symbolic link creation needs Developer Mode or appropriate rights.'; $link = $null }
    if ($null -ne $link) {
        Reject { Invoke-Static $local 'OpenRead' @($link.FullName, [long]1048576) } 'credential leaf symbolic link rejected'
        Reject { Invoke-Static $local 'Exists' @($link.FullName) } 'credential leaf symbolic link is not treated as missing'
        Reject { Invoke-Static $local 'CreateStatusFile' @($link.FullName) } 'status leaf symbolic link rejected'
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $readAt = $now - 120000
    foreach ($expiresAt in @(($now - 60000), ($now + 60000))) {
        $json = @{ schemaVersion = 2; value = @{ kind = 'present'; expiresAtMs = $expiresAt
            reading = @{ readAtMs = $readAt; usage = @{ percentUsed = 25; hasNonZeroIncludedLimit = $true } } } } |
            ConvertTo-Json -Depth 8 -Compress
        $document = [Text.Json.JsonDocument]::Parse([string]$json)
        try {
            $provider = [Activator]::CreateInstance($assembly.GetType('AISubGauge.Providers.GrokProvider', $true))
            $snapshot = Invoke-Static 'AISubGauge.Providers.GrokBotCache' 'Parse' @($provider, $document.RootElement)
            Check ($snapshot.IsStale -eq ($expiresAt -lt $now)) 'cache expiration is exposed as structured data'
            Check (([DateTimeOffset]$snapshot.UpdatedAt).ToUnixTimeMilliseconds() -eq $readAt) 'cache timestamp preserves the original reading time'
        } finally { $document.Dispose() }
    }
    $demoFile = Join-Path $root 'demo-status.json'
    $legacy = Join-Path $env:AISUBGAUGE_SETTINGS_DIR 'WindowsQuotaTray/settings.json'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($legacy)) | Out-Null
    [IO.File]::WriteAllText($legacy, '{"ProviderVisibility":{"codex":true}}')
    Check ((Run-DemoStatus $demoFile) -eq 0) 'demo status command succeeds without provider requests'
    Check (-not [IO.File]::Exists((Join-Path $env:AISUBGAUGE_SETTINGS_DIR 'settings.json'))) 'demo status never creates or migrates settings in the isolated root'
    Check ([IO.File]::ReadAllText($legacy) -eq '{"ProviderVisibility":{"codex":true}}') 'demo status leaves legacy settings unchanged'
    $demoJson = [IO.File]::ReadAllText($demoFile)
    $entries = $demoJson | ConvertFrom-Json
    Check ($entries.Count -eq 7) 'status contains all seven providers'
    foreach ($entry in $entries) {
        Check (-not $entry.isRealData -and $entry.isDemo -and -not $entry.isStale -and
            $null -eq $entry.remainingPercent -and $null -eq $entry.updatedAt -and
            @('consent', 'isDemo', 'isStale', 'updatedAt' | Where-Object { $_ -notin $entry.PSObject.Properties.Name }).Count -eq 0
        ) 'demo status cannot be mistaken for real quota'
    }
    Check ((Run-DemoStatus $demoFile) -eq 1) 'status command refuses an existing file'
    Check ([IO.File]::ReadAllText($demoFile) -eq $demoJson) 'status command preserves an existing report'
    Check ((Run-DemoStatus $env:GROK_AUTH_PATH) -eq 1) 'status command refuses a configured credential path'
    Check (-not [IO.File]::Exists($env:GROK_AUTH_PATH)) 'status command never creates a credential file'
    Write-Host "PASS: $passed security checks. Fixtures retained at $root"
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
