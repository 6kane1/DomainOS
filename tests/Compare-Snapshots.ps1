<#
  Domain OS — puts the snapshots of two measurement folders side by side.
      .\Compare-Snapshots.ps1 .\results\stock-Idle-...  .\results\domainos-Idle-...
#>
param([Parameter(Mandatory)][string]$Before, [Parameter(Mandatory)][string]$After)
$a = Get-Content -Raw (Join-Path $Before 'snapshot.json') | ConvertFrom-Json
$b = Get-Content -Raw (Join-Path $After 'snapshot.json') | ConvertFrom-Json
'processes', 'threads', 'handles', 'servicesRunning', 'memoryUsedMB', 'commitMB', 'scheduledTasksReady', 'startupEntries' | ForEach-Object {
    $x = [double]$a.$_; $y = [double]$b.$_
    [pscustomobject]@{
        Metric = $_
        ($a.label) = $x
        ($b.label + ' ') = $y
        Change = if ($x -ne 0) { '{0:+0.0;-0.0;0}%' -f (($y - $x) / $x * 100) } else { '' }
    }
} | Format-Table -AutoSize
Write-Host "Builds: $($a.windowsBuild)  |  $($b.windowsBuild)"
if ($a.windowsBuild -ne $b.windowsBuild) { Write-Warning 'The two runs are on different Windows builds: the comparison is not like for like.' }
