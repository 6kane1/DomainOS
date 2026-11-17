<#
  Domain OS — runs FIRST, before anything is changed. It reads the playbook's own task files, finds every registry
  value, service and scheduled task the playbook may touch, and writes down what they are now.
  "Undo Domain OS" (Undo-DomainOS.ps1) puts exactly this state back. The first saved state is kept: applying the
  playbook a second time does not overwrite the original.
  File: %ProgramData%\Domain OS\Undo\state.json
#>
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir = Join-Path $env:ProgramData 'Domain OS\Undo'
$file = Join-Path $dir 'state.json'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
# The version being applied (from playbook.conf) and the history of what was applied and undone on this PC.
$version = ''
$conf = Get-Content -Raw -Encoding UTF8 (Join-Path $here '..\playbook.conf')
if ($conf -match '<Version>([^<]+)</Version>') { $version = $Matches[1] }
$history = Join-Path $env:ProgramData 'Domain OS\history.log'
Add-Content -Path $history -Value ('{0:yyyy-MM-dd HH:mm:ss}  applied  {1}' -f (Get-Date), $version) -Encoding UTF8

# A state that is already there is the ORIGINAL one (an earlier version was applied and not undone). It is kept;
# only things this version touches and the earlier one did not are added, with the values they have now.
$old = $null
if (Test-Path $file) { $old = Get-Content -Raw -Encoding UTF8 $file | ConvertFrom-Json }

function PsPath([string]$p) { $p -replace '^HKLM\\', 'Registry::HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'Registry::HKEY_CURRENT_USER\' }

$registry = @(); $services = @(); $tasks = @()
$seen = @{}
if ($old) {
    foreach ($r in $old.registry) { $seen["R|$($r.path)|$($r.name)"] = $true; $registry += $r }
    foreach ($x in $old.services) { $seen["S|$($x.name)"] = $true; $services += $x }
    foreach ($t in $old.tasks) { $seen["T|$($t.path)"] = $true; $tasks += $t }
}
$before = $registry.Count + $services.Count + $tasks.Count
foreach ($yml in Get-ChildItem (Join-Path $here '..\Configuration\Tasks') -Filter '*.yml') {
    foreach ($line in Get-Content $yml.FullName -Encoding UTF8) {
        if ($line -match "!registryValue:\s*\{path:\s*'([^']+)',\s*value:\s*'([^']+)'") {
            $path = $Matches[1]; $name = $Matches[2]; $key = "R|$path|$name"
            if ($seen[$key]) { continue }; $seen[$key] = $true
            $item = Get-Item -LiteralPath (PsPath $path)
            $exists = $item -and ($item.GetValueNames() -contains $name)
            $entry = [ordered]@{ path = $path; name = $name; exists = [bool]$exists; kind = ''; data = $null }
            if ($exists) {
                $entry.kind = $item.GetValueKind($name).ToString()
                $entry.data = $item.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            }
            $registry += $entry
        }
        elseif ($line -match "!service:\s*\{name:\s*'([^']+)'") {
            $name = $Matches[1]; $key = "S|$name"
            if ($seen[$key]) { continue }; $seen[$key] = $true
            $start = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$name").Start
            if ($null -ne $start) { $services += [ordered]@{ name = $name; start = [int]$start; running = ((Get-Service $name).Status -eq 'Running') } }
        }
        elseif ($line -match "!scheduledTask:\s*\{path:\s*'([^']+)'") {
            $full = $Matches[1]; $key = "T|$full"
            if ($seen[$key]) { continue }; $seen[$key] = $true
            $i = $full.LastIndexOf('\')
            $task = Get-ScheduledTask -TaskPath ($full.Substring(0, $i + 1)) -TaskName ($full.Substring($i + 1))
            if ($task) { $tasks += [ordered]@{ path = $full; enabled = ($task.State -ne 'Disabled') } }
        }
    }
}

if ($old) {
    # Hibernation, OneDrive and the app list stay as first recorded.
    $state = [ordered]@{
        saved = $old.saved; user = $old.user; build = $old.build; hibernate = $old.hibernate; oneDrive = $old.oneDrive; apps = $old.apps
        versions = @($old.versions) + $version
        registry = $registry; services = $services; tasks = $tasks
    }
} else {
    $state = [ordered]@{
        saved     = (Get-Date).ToString('o')
        user      = "$env:USERDOMAIN\$env:USERNAME"
        build     = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
        hibernate = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power').HibernateEnabled
        oneDrive  = [bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').OneDrive -or (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'))
        apps      = @(Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name -Unique | Sort-Object)
        versions  = @($version)
        registry  = $registry
        services  = $services
        tasks     = $tasks
    }
}
$state | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
if ($old) { Write-Host ("The original state was kept; {0} items new in version {1} were added to it." -f ($registry.Count + $services.Count + $tasks.Count - $before), $version) }
else { Write-Host ("Original state saved: {0} registry values, {1} services, {2} scheduled tasks." -f $registry.Count, $services.Count, $tasks.Count) }
exit 0
