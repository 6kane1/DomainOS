# Runs the Pester tests of this folder with the Pester copy in tests/.vendor; writes NUnit XML for run-all.py.
param([string]$Out, [string[]]$Path = @($PSScriptRoot))
$ErrorActionPreference = 'Stop'
$vendor = Join-Path $PSScriptRoot '..\.vendor\Pester'
$mod = Get-ChildItem -LiteralPath $vendor -Filter Pester.psd1 -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mod) { Import-Module $mod.FullName -Force } else { Import-Module Pester -MinimumVersion 5.0 -Force }
$c = New-PesterConfiguration
$c.Run.Path = $Path
$c.Run.PassThru = $true
$c.Output.Verbosity = 'Normal'
if ($Out) { $c.TestResult.Enabled = $true; $c.TestResult.OutputFormat = 'NUnitXml'; $c.TestResult.OutputPath = $Out }
$r = Invoke-Pester -Configuration $c
exit $(if ($r.FailedCount -gt 0 -or $r.FailedBlocksCount -gt 0 -or $r.FailedContainersCount -gt 0) { 1 } else { 0 })
