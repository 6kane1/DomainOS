<#
  Domain OS — puts back items that earlier versions (1.5.0–1.6.6) changed and this version no longer touches.

  The values come from %ProgramData%\Domain OS\Undo\state.json, written before the very first install: every
  service gets the start-up type it had, every task its enabled state, every registry value its data (or is
  removed if it did not exist). An item that is not in state.json was never changed on this PC and is skipped,
  so on a fresh install this script does nothing. The lists of these items are in DomainOS-Common.ps1 (also used by
  Undo). state.json is used only when Domain OS wrote it (owner SYSTEM / Administrators / TrustedInstaller); a value
  that could not be read when it was saved is left alone.

  Runs with the playbook's TrustedInstaller rights (main.yml, no runas): it touches only HKLM, and some of these
  services do not let administrators change their start type. Every change is read back.
  Exit code: 0 = everything put back or nothing to do; 1 = at least one item could not be put back (FAILED lines in the
  log), and the install stops (main.yml, handleExitCodes). A saved state that cannot be used is not "nothing to do"
  in theory, but Save-State.ps1 runs first and already stops the install in that case.
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'DomainOS-Common.ps1')
$data = $DomainOSData
$file = Join-Path $data 'Undo\state.json'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Defaults] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }
function PsPath([string]$p) { $p -replace '^HKLM\\', 'Registry::HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'Registry::HKEY_CURRENT_USER\' }

$services = $DomainOSLegacyServices | Where-Object { $_ -ne 'TrkWks' }   # TrkWks: Set-TrkWks.ps1
$tasks = $DomainOSLegacyTasks
# Game Mode is no longer here: since 2.1.0 gaming.yml switches it on explicitly. Putting back the value saved before
# the first install switched it off again on PCs where it had been off then. The wallpaper values of 1.4.0-2.1.0 are
# left to Set-Wallpapers.ps1 and Undo.
$values = @($DomainOSLegacyRegistry | Where-Object { $_[0] -like 'HKLM\*' })

if (-not (Test-Path $file)) { Write-Log 'No saved state: nothing was changed by an earlier version'; exit 0 }
if (-not (Test-DomainOSFile $file)) { Write-Log 'The saved state was not written by Domain OS: nothing put back'; exit 0 }
$state = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $state) { Write-Log 'The saved state cannot be read: nothing put back'; exit 0 }
$done = 0; $failed = 0
$kinds = @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')

foreach ($s in $state.services | Where-Object { $services -contains $_.name -and -not $_.unreadable -and $null -ne $_.start }) {
    $key = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($s.name)"
    $now = (Get-ItemProperty -LiteralPath $key).Start
    if ($null -eq $now -or [int]$now -eq [int]$s.start) { continue }
    $why = ''
    try { Set-ItemProperty -LiteralPath $key -Name 'Start' -Value ([int]$s.start) -Type DWord -ErrorAction Stop } catch { $why = $_.Exception.Message }
    if ((Get-ItemProperty -LiteralPath $key).Start -eq [int]$s.start) { $done++; Write-Log "service $($s.name): start type $now -> $($s.start)" }
    else { $failed++; Write-Log "FAILED service $($s.name): start type is still $now, not $($s.start) $why" }
}

foreach ($t in $state.tasks | Where-Object { $tasks -contains $_.path }) {
    $i = $t.path.LastIndexOf('\')
    $task = Get-ScheduledTask -TaskPath ($t.path.Substring(0, $i + 1)) -TaskName ($t.path.Substring($i + 1))
    if (-not $task -or (($task.State -ne 'Disabled') -eq [bool]$t.enabled)) { continue }
    $why = ''
    try { if ($t.enabled) { $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null } else { $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null } } catch { $why = $_.Exception.Message }
    $after = Get-ScheduledTask -TaskPath ($t.path.Substring(0, $i + 1)) -TaskName ($t.path.Substring($i + 1))
    if ($after -and (($after.State -ne 'Disabled') -eq [bool]$t.enabled)) { $done++; Write-Log "task $($t.path): $(if ($t.enabled) { 'enabled' } else { 'disabled' })" }
    else { $failed++; Write-Log "FAILED task $($t.path): could not be $(if ($t.enabled) { 'enabled' } else { 'disabled' }) $why" }
}

foreach ($v in $values) {
    $r = $state.registry | Where-Object { $_.path -eq $v[0] -and $_.name -eq $v[1] } | Select-Object -First 1
    if (-not $r -or $r.unreadable) { continue }
    $path = PsPath $r.path
    try {
        if ($r.exists) {
            if ($kinds -notcontains $r.kind) { throw "unexpected value type '$($r.kind)'" }
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
            $data = switch ($r.kind) { 'MultiString' { [string[]]@($r.data) } 'Binary' { [byte[]]@($r.data) } 'DWord' { [int]$r.data } 'QWord' { [long]$r.data } default { [string]$r.data } }
            New-ItemProperty -LiteralPath $path -Name $r.name -Value $data -PropertyType $r.kind -Force -ErrorAction Stop | Out-Null
            $done++; Write-Log "registry $($r.path)\$($r.name) = $($r.data)"
        } elseif ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).GetValueNames() -contains $r.name)) {
            # (a key that is not there holds no value: nothing to remove)
            Remove-ItemProperty -LiteralPath $path -Name $r.name -Force -ErrorAction Stop
            $done++; Write-Log "registry $($r.path)\$($r.name) removed (it did not exist)"
        }
    } catch { $failed++; Write-Log "FAILED registry $($r.path)\$($r.name): $($_.Exception.Message)" }
}

Write-Log "Items no longer changed by Domain OS put back as they were: $done"
if ($failed -gt 0) { Write-Log "FAILED: $failed item(s) could not be put back (see above): the install stops here"; exit 1 }
exit 0
