<#
  Static analysis of PowerShell scripts with PowerShell's own parser (AST), for tests/run-all.py.
  Prints one JSON document: per file the parse errors, the param block, Windows PowerShell 5.1 compatibility
  problems, .NET calls that receive $null where the method takes a string, and uses of per-user environment variables.
      pwsh -NoProfile -File Static.ps1 <file.ps1> ...
#>
param([Parameter(ValueFromRemainingArguments)][string[]]$Files)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

# Cmdlets and parameters that Windows PowerShell 5.1 does not have (added in PowerShell 6/7).
$ps7Commands = @('Join-String', 'Get-Error', 'Test-Json', 'Remove-Alias', 'Remove-Service', 'Get-Uptime', 'ConvertFrom-Markdown',
    'Show-Markdown', 'Get-MarkdownOption', 'Set-MarkdownOption', 'Clear-RecycleBin:never', 'ConvertTo-Csv:never', 'Update-List:never',
    'ForEach-Object:never', 'Start-ThreadJob', 'Get-PSSubsystem', 'Enable-ExperimentalFeature', 'Get-ExperimentalFeature')
$ps7Params = @{
    'ForEach-Object'    = @('Parallel', 'ThrottleLimit', 'TimeoutSeconds', 'AsJob')
    'ConvertFrom-Json'  = @('AsHashtable', 'Depth', 'NoEnumerate')
    'ConvertTo-Json'    = @('AsArray', 'EnumsAsStrings', 'EscapeHandling')
    'Sort-Object'       = @('Top', 'Bottom', 'Stable')
    'Select-String'     = @('Raw', 'NoEmphasis')
    'Get-Date'          = @('AsUTC', 'UnixTimeSeconds')
    'Out-String'        = @('NoNewline')
    'Split-Path'        = @('LeafBase', 'Extension')
    'Join-Path'         = @('AdditionalChildPath')
    'Test-Connection'   = @('TargetName', 'Ping', 'TcpPort', 'MtuSize', 'Traceroute', 'Repeat', 'IPv4', 'IPv6', 'ResolveDestination')
    'Invoke-WebRequest' = @('SkipCertificateCheck', 'SkipHttpErrorCheck', 'StatusCodeVariable', 'Resume', 'Authentication', 'Token', 'SslProtocol', 'MaximumRetryCount', 'RetryIntervalSec', 'ResponseHeadersVariable', 'Form')
    'Invoke-RestMethod' = @('SkipCertificateCheck', 'SkipHttpErrorCheck', 'StatusCodeVariable', 'Resume', 'Authentication', 'Token', 'SslProtocol', 'MaximumRetryCount', 'RetryIntervalSec', 'ResponseHeadersVariable', 'Form')
    'Get-Content'       = @('AsByteStream')
    'Set-Content'       = @('AsByteStream')
    'Add-Content'       = @('AsByteStream')
    'Import-Csv'        = @('UseCulture:never')
    'Select-Object'     = @('SkipIndex', 'CaseInsensitive')
    'Remove-Item'       = @('Stream:never')
    'Get-ChildItem'     = @('FollowSymlink')
    'Start-Process'     = @('Environment')
    'Wait-Process'      = @('Any', 'PassThru')
    'Get-Process'       = @('IncludeUserName:never')
    'New-Item'          = @('Target:never')
    'Test-Path'         = @('OlderThan:never')
    'Where-Object'      = @('Not:never')
    'Get-FileHash'      = @('Stream:never')
    'Out-File'          = @()
}
# .NET members that exist in .NET (Core) but not in .NET Framework 4.x, which Windows PowerShell 5.1 runs on.
$netCoreOnly = @(
    'System.IO.Path::GetRelativePath', 'System.IO.Path::Join', 'System.IO.Path::TrimEndingDirectorySeparator', 'System.IO.Path::EndsInDirectorySeparator',
    'System.Convert::ToHexString', 'System.Convert::FromHexString', 'System.Math::Clamp', 'System.Environment::ProcessPath',
    'System.Environment::ProcessId', 'System.IO.File::ReadAllTextAsync', 'System.IO.File::WriteAllTextAsync', 'System.IO.File::ReadAllBytesAsync',
    'System.IO.File::ReadAllLinesAsync', 'System.IO.File::WriteAllBytesAsync', 'System.IO.Directory::CreateSymbolicLink', 'System.IO.File::CreateSymbolicLink',
    'System.Security.Cryptography.SHA256::HashData', 'System.Security.Cryptography.SHA1::HashData', 'System.Security.Cryptography.MD5::HashData',
    'System.Random::Shared', 'System.OperatingSystem::IsWindows', 'System.String::Join:never', 'System.Text.Json.JsonSerializer::Serialize',
    'System.Text.Json.JsonSerializer::Deserialize', 'System.Text.Json.JsonDocument::Parse', 'System.IO.File::Move3', 'System.Net.Http.HttpClient::new:never')
$netCoreInstance = @('ReplaceLineEndings', 'GetValueOrDefault:never', 'AsSpan', 'Contains2', 'StartsWithChar', 'TryAdd', 'EnumerateRunes')
$autoVars7 = @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR', 'PSStyle', 'EnabledExperimentalFeatures')
$userEnv = @('USERNAME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'USERDOMAIN', 'HOMEPATH', 'TEMP', 'TMP', 'ONEDRIVE')

function Resolve-TypeName([string]$n) {
    $t = $null
    foreach ($c in @($n, "System.$n")) { try { $t = [type]$c; if ($t) { return $t } } catch { } }
    return $null
}

$out = [ordered]@{}
foreach ($file in $Files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $lines = [IO.File]::ReadAllLines($file)
    $r = [ordered]@{ errors = @(); params = @(); cmdletBinding = $false; hasParamBlock = $false; compat = @(); nullArgs = @(); env = @();
                     commands = @(); strings = @(); dotSourced = @(); functions = @() }
    foreach ($e in $errors) { $r.errors += "$($e.Extent.StartLineNumber): $($e.Message)" }

    $pb = $ast.ParamBlock
    if ($pb) {
        $r.hasParamBlock = $true
        $r.cmdletBinding = [bool]($pb.Attributes | Where-Object { $_.TypeName.Name -in 'CmdletBinding' })
        foreach ($p in $pb.Parameters) {
            $info = [ordered]@{ name = $p.Name.VariablePath.UserPath; type = $p.StaticType.Name; mandatory = $false; set = @() }
            foreach ($a in $p.Attributes) {
                if ($a -is [System.Management.Automation.Language.TypeConstraintAst]) { $info.type = $a.TypeName.Name }
                if ($a -is [System.Management.Automation.Language.AttributeAst]) {
                    if ($a.TypeName.Name -eq 'Parameter') {
                        foreach ($na in $a.NamedArguments) { if ($na.ArgumentName -eq 'Mandatory') { $info.mandatory = ($na.ExpressionOmitted -or "$($na.Argument)" -eq '$true') } }
                    }
                    if ($a.TypeName.Name -eq 'ValidateSet') { $info.set = @($a.PositionalArguments | ForEach-Object { $_.Value }) }
                }
            }
            $r.params += [pscustomobject]$info
        }
    }

    function Add-Compat($node, [string]$what) { $script:r.compat += "$($node.Extent.StartLineNumber): $what" }
    $all = $ast.FindAll({ $true }, $true)
    foreach ($n in $all) {
        $tn = $n.GetType().Name
        switch ($tn) {
            'TernaryExpressionAst' { Add-Compat $n 'ternary operator ?: (PowerShell 7 only)' }
            'PipelineChainAst' { Add-Compat $n 'pipeline chain && / || (PowerShell 7 only)' }
            'BinaryExpressionAst' { if ("$($n.Operator)" -eq 'QuestionQuestion') { Add-Compat $n 'null-coalescing ?? (PowerShell 7 only)' } }
            'AssignmentStatementAst' { if ("$($n.Operator)" -eq 'QuestionQuestionEquals') { Add-Compat $n 'null-coalescing assignment ??= (PowerShell 7 only)' } }
            'MemberExpressionAst' { if ($n.NullConditional) { Add-Compat $n 'null-conditional ?. (PowerShell 7 only)' } }
            'InvokeMemberExpressionAst' {
                if ($n.NullConditional) { Add-Compat $n 'null-conditional ?. (PowerShell 7 only)' }
            }
            'IndexExpressionAst' { if ($n.NullConditional) { Add-Compat $n 'null-conditional ?[] (PowerShell 7 only)' } }
            'VariableExpressionAst' {
                $vp = $n.VariablePath
                if (-not $vp.DriveName -and $autoVars7 -contains $vp.UserPath) { Add-Compat $n "automatic variable `$$($vp.UserPath) does not exist in 5.1" }
                if ($vp.DriveName -eq 'env' -and $userEnv -contains $vp.UserPath.Substring(4).ToUpper()) {
                    $ln = $n.Extent.StartLineNumber
                    $ctx = (($ln - 4)..($ln - 1) | Where-Object { $_ -ge 1 } | ForEach-Object { $lines[$_ - 1] }) -join "`n"
                    $explained = ($ctx + "`n" + $lines[$ln - 1]) -match '#[^\n]*(USERNAME|SYSTEM|environment|computer account|this account|the account)'
                    $r.env += [pscustomobject]@{ line = $ln; var = $vp.UserPath.Substring(4).ToUpper(); explained = [bool]$explained; text = $lines[$ln - 1].Trim() }
                }
            }
            'StringConstantExpressionAst' {
                if ($n.StringConstantType -ne 'BareWord') { $r.strings += [pscustomobject]@{ line = $n.Extent.StartLineNumber; text = $n.Value } }
            }
            'ExpandableStringExpressionAst' {
                $raw = $n.Extent.Text
                if ($raw -match '`e|`u\{') { Add-Compat $n 'escape `e or `u{} in a string (PowerShell 6+ only)' }
                $r.strings += [pscustomobject]@{ line = $n.Extent.StartLineNumber; text = $n.Value }
            }
            'CommandAst' {
                $name = $n.GetCommandName()
                if ($name) {
                    $r.commands += [pscustomobject]@{ line = $n.Extent.StartLineNumber; name = $name; text = $n.Extent.Text }
                    if ($ps7Commands -contains $name) { Add-Compat $n "$name does not exist in Windows PowerShell 5.1" }
                    $params = @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
                    foreach ($k in $ps7Params.Keys) {
                        if ($name -ieq $k) {
                            foreach ($pp in $params) {
                                foreach ($bad in $ps7Params[$k]) {
                                    if ($bad -notlike '*:never' -and $bad -ieq $pp) { Add-Compat $n "$name -$pp is PowerShell 6/7 only" }
                                }
                            }
                        }
                    }
                    if ($name -ieq 'Join-Path') {
                        $pos = @($n.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
                        $named = @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }).Count
                        if ($pos.Count - $named -gt 2) { Add-Compat $n 'Join-Path with more than two paths (PowerShell 6+ only)' }
                    }
                    foreach ($ce in $n.CommandElements) {
                        if ($ce -is [System.Management.Automation.Language.CommandParameterAst] -and $ce.ParameterName -ieq 'Encoding') {
                            $i = [array]::IndexOf($n.CommandElements, $ce)
                            $v = if ($ce.Argument) { "$($ce.Argument)" } elseif ($i + 1 -lt $n.CommandElements.Count) { "$($n.CommandElements[$i + 1])" } else { '' }
                            if ($v -match '^(utf8NoBOM|utf8BOM|ansi)$') { Add-Compat $n "-Encoding $v is PowerShell 6+ only" }
                        }
                    }
                    if ($n.InvocationOperator -eq 'Dot') { $r.dotSourced += $n.Extent.Text }
                }
            }
            'FunctionDefinitionAst' { $r.functions += $n.Name }
        }
        # .NET calls: [Type]::Member(...) and instance members that .NET Framework lacks; $null into a string parameter
        if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or ($tn -eq 'MemberExpressionAst' -and $n.Static)) {
            $member = "$($n.Member)"
            $argc = if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { @($n.Arguments).Count } else { 0 }
            if ($n.Static -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                $t = Resolve-TypeName $n.Expression.TypeName.FullName
                $full = if ($t) { $t.FullName } else { $n.Expression.TypeName.FullName }
                foreach ($x in $netCoreOnly) {
                    if ($x -like '*:never') { continue }
                    if ($x -eq "$full::$member" -or ($x -eq "$full::${member}$argc")) { Add-Compat $n "[$full]::$member is not in .NET Framework (Windows PowerShell 5.1)" }
                }
                if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                    $args_ = @($n.Arguments)
                    for ($i = 0; $i -lt $args_.Count; $i++) {
                        $a = $args_[$i]
                        if ($a -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.VariablePath.UserPath -eq 'null') {
                            $stringParam = $true    # type unknown here (Windows-only): assume the worst
                            if ($t) {
                                $ov = @($t.GetMethods() | Where-Object { $_.Name -eq $member -and $_.IsStatic -and $_.GetParameters().Count -eq $args_.Count })
                                if ($ov.Count) { $stringParam = [bool]($ov | Where-Object { $_.GetParameters()[$i].ParameterType -eq [string] }) }
                            }
                            if ($stringParam) { $r.nullArgs += "$($n.Extent.StartLineNumber): [$full]::$member gets `$null as argument $($i + 1), a string parameter: PowerShell passes """" (use [NullString]::Value)" }
                        }
                    }
                }
            } elseif ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $n.Static) {
                if ($member -eq 'ReplaceLineEndings') { Add-Compat $n '.ReplaceLineEndings() is not in .NET Framework' }
                if ($member -in 'Split' -and $argc -ge 1) {
                    $a0 = @($n.Arguments)[0]
                    if ($a0 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $a0.Value.Length -gt 1) {
                        Add-Compat $n ".Split('$($a0.Value)') with a multi-character string splits on EACH character in Windows PowerShell 5.1 (.NET Framework has no Split(string))"
                    }
                }
                if ($member -in 'Contains', 'StartsWith', 'EndsWith', 'IndexOf' -and $argc -eq 2) {
                    $a1 = "$(@($n.Arguments)[1])"
                    if ($member -eq 'Contains' -and $a1 -match 'StringComparison') { Add-Compat $n 'String.Contains(x, StringComparison) is not in .NET Framework' }
                }
            }
        }
    }
    # Instance calls on .NET objects that receive $null for a parameter, e.g. $key.SetValue($null, ...): reported for review
    $out[$file] = $r
}
$out | ConvertTo-Json -Depth 6 -Compress
