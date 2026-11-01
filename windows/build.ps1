param([string]$Dotnet)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not $Dotnet) { $Dotnet = $env:AISUBGAUGE_DOTNET }
if (-not $Dotnet -and $env:DOTNET_ROOT) { $Dotnet = Join-Path $env:DOTNET_ROOT 'dotnet.exe' }
if (-not $Dotnet) { $Dotnet = 'dotnet' }
try { $sdkCommand = Get-Command -Name $Dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
catch [System.Management.Automation.CommandNotFoundException] { $sdkCommand = $null }
if (-not $sdkCommand) {
    throw 'Required .NET SDK is unavailable. Set -Dotnet, AISUBGAUGE_DOTNET, DOTNET_ROOT, or PATH. No tools were installed.'
}
$Dotnet = $sdkCommand.Source
$env:DOTNET_CLI_HOME = Join-Path $PSScriptRoot '.dotnethome'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$env:NUGET_PACKAGES = Join-Path $PSScriptRoot '.nuget\packages'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $PSScriptRoot '.nuget\http-cache'
$env:NUGET_PLUGINS_CACHE_PATH = Join-Path $PSScriptRoot '.nuget\plugins-cache'
$env:TEMP = Join-Path $PSScriptRoot 'artifacts\temp'
$env:TMP = $env:TEMP
[void](New-Item -ItemType Directory -Path $env:TEMP -Force)
# Existing Microsoft runtime packages are a read-only fallback. No third-party packages.
$userProfile = $env:USERPROFILE
if (-not $userProfile) { $userProfile = [Environment]::GetFolderPath('UserProfile') }
$restoreArgs = @()
if ($userProfile) {
    $fallback = Join-Path $userProfile '.nuget\packages'
    if (Test-Path -LiteralPath $fallback) { $restoreArgs = @('-p:RestoreFallbackFolders=' + $fallback) }
}
function Invoke-Dotnet([string[]]$Arguments) {
    & $dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Build command failed. See the preceding compiler or test output.' }
}
Invoke-Dotnet @('--version') # SDK selection is controlled by global.json.
Invoke-Dotnet (@('run','--project','tools\GenerateAppIcon','-c','Release') + $restoreArgs + @('--','assets\app.ico'))
Invoke-Dotnet (@('build','src\AISubGauge2\AISubGauge2.csproj','-c','Release','--nologo') + $restoreArgs)
& $dotnet run --project tests\AISubGauge.Tests -c Release @restoreArgs 2>&1 | Tee-Object -FilePath artifacts\test-results.txt
if ($LASTEXITCODE -ne 0) { throw 'Unit tests failed.' }
Invoke-Dotnet (@('publish','src\AISubGauge2\AISubGauge2.csproj','-c','Release','-r','win-x64','--self-contained','true','-p:PublishSingleFile=true','-p:IncludeNativeLibrariesForSelfExtract=true','-p:DebugType=None','-p:DebugSymbols=false','-o','artifacts\publish','--nologo') + $restoreArgs)
$payload = Join-Path $PSScriptRoot 'artifacts\package'
[void](New-Item -ItemType Directory -Path $payload -Force)
Copy-Item -LiteralPath artifacts\publish\AISubGauge2.exe -Destination $payload -Force
foreach ($file in @('install.ps1','uninstall.ps1','InstallSafety.ps1','InstallFiles.ps1','README.md','LICENSE','THIRD_PARTY_NOTICES.md')) { Copy-Item -LiteralPath $file -Destination $payload -Force }
# Preserve notices from the exact Microsoft runtime packs selected by restore.
$assets = Get-Content -LiteralPath 'src\AISubGauge2\obj\project.assets.json' -Raw | ConvertFrom-Json
$runtimeNotices = @()
$runtimePacks = @($assets.project.frameworks.PSObject.Properties | ForEach-Object { $_.Value.downloadDependencies } | Where-Object { $_.name -match '^Microsoft\.(NETCore|WindowsDesktop)\.App\.Runtime\.win-x64$' })
if ($runtimePacks.Count -ne 2) { throw 'Expected both .NET and Windows Desktop runtime packs.' }
foreach ($library in $runtimePacks) {
    $runtimeVersion = $library.version.Trim('[',']').Split(',')[0].Trim()
    $packagePath = $library.name.ToLowerInvariant() + '/' + $runtimeVersion
    $packageDirectory = $null
    foreach ($folder in $assets.packageFolders.PSObject.Properties.Name) {
        $candidate = Join-Path $folder $packagePath
        if (Test-Path -LiteralPath $candidate) { $packageDirectory = $candidate; break }
    }
    if (-not $packageDirectory) { throw 'Runtime license package is unavailable.' }
    $licenseFound = $false
    foreach ($name in @('LICENSE','LICENSE.TXT','THIRD-PARTY-NOTICES.TXT')) {
        $notice = Join-Path $packageDirectory $name
        if (Test-Path -LiteralPath $notice) {
            $runtimeNotices += $library.name + '/' + $runtimeVersion + ' / ' + $name
            $runtimeNotices += Get-Content -LiteralPath $notice -Raw
            if ($name -like 'LICENSE*') { $licenseFound = $true }
        }
    }
    if (-not $licenseFound) { throw 'Runtime license text is missing.' }
}
if ($runtimeNotices.Count -eq 0) { throw 'No runtime notices were found.' }
$runtimeNotices | Set-Content -Encoding UTF8 (Join-Path $payload 'DOTNET-NOTICES.txt')
('@echo off', 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"', 'exit /b %errorlevel%') | Set-Content -Encoding ASCII (Join-Path $payload 'install.cmd')
$zip = Join-Path $PSScriptRoot 'artifacts\AISubGauge2-2.0.0-win-x64.zip'
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -Force
$iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
# Relative ASCII SED paths support a repository whose parent path contains Chinese.
$sed = @'
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=AISubGauge2-Setup-2.0.0.exe
FriendlyName=AI SubGauge 2.0.0
AppLaunched=cmd.exe /c install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=cmd.exe /c install.cmd
UserQuietInstCmd=cmd.exe /c install.cmd
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=AI SubGauge 2 installation completed.
FILE0="AISubGauge2.exe"
FILE1="install.ps1"
FILE2="uninstall.ps1"
FILE3="README.md"
FILE4="install.cmd"
FILE5="LICENSE"
FILE6="THIRD_PARTY_NOTICES.md"
FILE7="DOTNET-NOTICES.txt"
FILE8="InstallSafety.ps1"
FILE9="InstallFiles.ps1"
[SourceFiles]
SourceFiles0=package\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
%FILE3%=
%FILE4%=
%FILE5%=
%FILE6%=
%FILE7%=
%FILE8%=
%FILE9%=
'@
$sed | Set-Content -Encoding ASCII artifacts\package.sed
# Test the freshly generated SED, including when only ZIP packaging is available.
& $dotnet run --project tests\AISubGauge.Tests -c Release @restoreArgs -- --packaging 2>&1 | Tee-Object -FilePath artifacts\test-results.txt -Append
if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Installer.Tests.ps1 2>&1 | Tee-Object -FilePath artifacts\test-results.txt -Append
if ($LASTEXITCODE -ne 0) { throw 'Installer script checks failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\InstallSafety.Tests.ps1 2>&1 | Tee-Object -FilePath artifacts\test-results.txt -Append
if ($LASTEXITCODE -ne 0) { throw 'Installer safety tests failed.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\InstallFiles.Tests.ps1 2>&1 | Tee-Object -FilePath artifacts\test-results.txt -Append
if ($LASTEXITCODE -ne 0) { throw 'Installer copy/recovery tests failed.' }
if (-not (Test-Path -LiteralPath $iexpress)) {
    'IExpress is unavailable. Use the ZIP package and install.ps1 as documented in README.md.' | Set-Content -Encoding UTF8 artifacts\packaging-status.txt
    Write-Output 'ZIP package created; IExpress is unavailable.'
    exit 0
}
$process = Start-Process -FilePath $iexpress -ArgumentList '/N /Q package.sed' -WorkingDirectory (Join-Path $PSScriptRoot 'artifacts') -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(180000)) { $process.Kill(); throw 'IExpress timed out.' }
$setup = Join-Path $PSScriptRoot 'artifacts\AISubGauge2-Setup-2.0.0.exe'
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $setup)) { throw 'IExpress did not create the installer.' }
$stream = [IO.File]::OpenRead($setup)
try { if ($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) { throw 'Invalid installer executable.' } } finally { $stream.Dispose() }
'EXE and ZIP packages generated. The installer was not executed.' | Set-Content -Encoding UTF8 artifacts\packaging-status.txt
Get-Item -LiteralPath $setup,$zip | Select-Object Name,Length

