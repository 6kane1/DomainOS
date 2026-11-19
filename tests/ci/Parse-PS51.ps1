<#
  Domain OS CI (tests.yml, Windows job): parses every PowerShell script of the playbook with the parser of the
  PowerShell that runs this file. The workflow runs it with powershell.exe, i.e. Windows PowerShell 5.1, the version
  AME Wizard and the playbook use; area D of run-all.py only has PowerShell 7's parser plus pattern checks.
  Exit code 1 when a script has a parse error.
#>
param([string]$Root = (Join-Path $PSScriptRoot '..\..\playbook'))
$ErrorActionPreference = 'Stop'
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
if ($files.Count -lt 10) { Write-Host "FAIL only $($files.Count) scripts found under $Root"; exit 1 }
$bad = 0
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $bad++
        foreach ($e in $errors) { Write-Host ("FAIL {0}:{1}:{2}  {3}" -f $f.FullName, $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) }
    } else { Write-Host "PASS $($f.FullName)" }
}
Write-Host "$($files.Count) scripts parsed, $bad with errors"
if ($bad) { exit 1 }
exit 0
