param()
$ErrorActionPreference = 'Stop'
# Parse only. Never dot-source or execute the installer, or access the registry.
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$parseErrors)
$script:passed = 0
$script:failed = 0
function Assert([bool]$Condition) { if (-not $Condition) { throw 'Assertion failed.' } }
function Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name" }
}
function ParameterValue($Command, [string]$Name) {
    $elements = $Command.CommandElements
    for ($i = 0; $i -lt $elements.Count - 1; $i++) {
        if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq $Name) {
            return $elements[$i + 1].Extent.Text
        }
    }
    return $null
}
Test 'installer PowerShell syntax' { Assert ($parseErrors.Count -eq 0) }
Test 'installer registry write is exclusively AISubGauge2 (static AST audit)' {
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    # Reject added indirect execution, registry tools or alternative mutation cmdlets.
    $allowed = @('Add-Content','Join-Path','Test-Path','Get-Item','New-Item','Set-Content','Write-InstallLog','New-Object','New-ItemProperty','Write-Output','Write-Error','Assert-SafePath','New-SafeDirectory','Stop-Version2Process','Assert-Version2Package','Copy-Version2Package','Start-Version2Application','Get-InstallFailure','Resume-Version2AfterFailure','Assert-InstallPath','Clear-Version2InstallLeftovers','Clear-Version2CompletedBackup','Write-InstallCleanupLog')
    foreach ($command in $commands) {
        if ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
            Assert ($command.Extent.Text -cin @('. (Join-Path $PSScriptRoot ''InstallSafety.ps1'')', '. (Join-Path $PSScriptRoot ''InstallFiles.ps1'')'))
        } else { Assert ($command.GetCommandName() -in $allowed) }
    }
    $methods = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
    foreach ($method in $methods) { Assert ($method.Member.Value -in @('ToString','GetFullPath','GetFolderPath','CreateShortcut','Save','TrimEnd','Equals','StartsWith','Exists')) }
    $writes = @($commands | Where-Object { $_.GetCommandName() -eq 'New-ItemProperty' })
    Assert ($writes.Count -eq 1)
    Assert ((ParameterValue $writes[0] 'Name') -ceq 'AISubGauge2')
    Assert ((ParameterValue $writes[0] 'Path') -ceq '$run')
    Assert ((ParameterValue $writes[0] 'PropertyType') -ceq 'String')
    $registryAssignments = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$run'
    }, $true))
    Assert ($registryAssignments.Count -eq 1)
    Assert ($registryAssignments[0].Right.Extent.Text -ceq "'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'")
    $runUses = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'run'
    }, $true))
    Assert ($runUses.Count -eq 4)
    $runCommands = @($commands | Where-Object { $_.GetCommandName() -in @('Test-Path','New-Item') -and $_.Extent.Text -match '\$run\b' })
    Assert ($runCommands.Count -eq 2)
    foreach ($command in $runCommands) { Assert ($command.Extent.Text -notmatch '-Force') }
    $strings = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
    Assert (@($strings | Where-Object { $_.Value -match '(?i)HKCU:|HKLM:|Registry::' }).Count -eq 1)
    Assert ($ast.Extent.Text -notmatch '\bAISubGauge\b')
}
Test 'installer explicitly returns success and failure without terminating Write-Error' {
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
    Assert ($main.Count -eq 1)
    Assert ($main[0].Body.Statements[-1].Extent.Text -ceq 'exit 0')
    $failure = $main[0].CatchClauses[0].Body
    Assert ($failure.Statements[-1].Extent.Text -ceq 'exit 1')
    $errorCommand = @($failure.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Error'
    }, $true))
    Assert ($errorCommand.Count -eq 1)
    Assert ((ParameterValue $errorCommand[0] 'ErrorAction') -ceq 'Continue')
}
Test 'installer log accepts only fixed status and stage fields' {
    $logger = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-InstallLog'
    }, $true))
    Assert ($logger.Count -eq 1)
    $parameters = $logger[0].Body.ParamBlock.Parameters
    Assert ($parameters.Count -eq 4)
    $expected = @('Started,Succeeded,Failed', 'Initialize,ValidatePackage,CopyFiles,Shortcuts,Autostart,Launch,Recovery,Completed', 'None,SharingViolation,SafetyRejected,Other')
    for ($i = 0; $i -lt 3; $i++) {
        $validation = @($parameters[$i].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        Assert ($validation.Count -eq 1)
        Assert (($validation[0].PositionalArguments.Value -join ',') -ceq $expected[$i])
    }
    Assert ($parameters[3].StaticType -eq [int])
    $variables = @($logger[0].Body.EndBlock.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true))
    foreach ($variable in $variables) { Assert ($variable.VariablePath.UserPath -in @('line','Status','Stage','Category','HResult','logPath','logDirectory')) }
    Assert ($ast.Extent.Text.Contains("`$logDirectory = Join-Path `$local 'AISubGauge2'"))
    Assert ($ast.Extent.Text.Contains("`$logPath = Join-Path `$logDirectory 'install.log'"))
    Assert ($ast.Extent.Text.Contains('Write-InstallLog -Status Started -Stage $stage'))
    Assert ($ast.Extent.Text.Contains('Write-InstallLog -Status Succeeded -Stage Completed'))
    Assert ($ast.Extent.Text.Contains('Write-InstallLog -Status Failed -Stage $stage -Category $failure.Category -HResult $failure.HResult'))
}
Test 'package guard precedes helper loading; validation precedes process stop; catch recovers' {
    $text = $ast.Extent.Text
    Assert ($text.IndexOf('Run the installer from a separate extracted package.') -lt $text.IndexOf('. (Join-Path $PSScriptRoot'))
    Assert ($text.IndexOf('Assert-Version2Package $PSScriptRoot $programs') -lt $text.IndexOf('Stop-Version2Process ('))
    Assert ($text.IndexOf('Stop-Version2Process (') -lt $text.IndexOf('Copy-Version2Package $PSScriptRoot $programs'))
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[0]
    Assert ($main.CatchClauses[0].Body.Extent.Text.Contains('Resume-Version2AfterFailure $recoverPrevious $programs'))
}
Test 'cleanup runs after target validation and backup cleanup only after Completed' {
    $text = $ast.Extent.Text
    Assert ($text.IndexOf('$target = Assert-InstallPath $target $programs') -lt $text.IndexOf('Clear-Version2InstallLeftovers $programs'))
    Assert ($text.IndexOf('Clear-Version2InstallLeftovers $programs') -lt $text.IndexOf('Copy-Version2Package $PSScriptRoot'))
    Assert ($text.IndexOf('Write-InstallLog -Status Succeeded -Stage Completed') -lt $text.IndexOf('Clear-Version2CompletedBackup $programs'))
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[0]
    Assert (-not $main.CatchClauses[0].Body.Extent.Text.Contains('Clear-Version2'))
}
Write-Output "Installer checks: $script:passed PASS, $script:failed FAIL"
if ($script:failed -gt 0) { exit 1 }
exit 0
