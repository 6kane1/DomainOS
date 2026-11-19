<#
  For tests/run-all.py (area C): what Save-State.ps1 records and what Undo may restore, computed by the playbook's own
  functions (DomainOS-Common.ps1: Get-DomainOSPlaybookItems, New-DomainOSAllowListLines) on the real task files.
      pwsh -NoProfile -File Items.ps1 <Executables dir> <Tasks dir>
#>
param([string]$Exe, [string]$Tasks)
$ErrorActionPreference = 'Stop'
if (-not $env:ProgramData) { $env:ProgramData = [IO.Path]::GetTempPath() }
. (Join-Path $Exe 'DomainOS-Common.ps1')
$items = @(Get-DomainOSPlaybookItems $Tasks | ForEach-Object { [pscustomobject]@{ kind = $_.kind; path = $_.path; name = $_.name } })
$allow = @(New-DomainOSAllowListLines $Tasks)
[ordered]@{
    items = $items
    allow = $allow
    legacyServices = @($DomainOSLegacyServices)
    legacyTasks = @($DomainOSLegacyTasks)
    legacyRegistry = @($DomainOSLegacyRegistry | ForEach-Object { , @($_[0], $_[1]) })
} | ConvertTo-Json -Depth 5 -Compress
