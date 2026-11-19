<#
  Domain OS — puts Windows back to what it was before the playbook, without reinstalling.

  Restored from the state saved before the first change: every registry value, service start-up type and
  scheduled task the playbook touched, hibernation, and OneDrive. Removed apps are NOT part of Windows any more:
  the script lists them for you to install from the Microsoft Store, and installs the Store itself again if it
  was removed.

      -RemoveTools   also removes the Domain OS app (its own full reset runs first), its autostart task and its
                     Start menu folder
      -WhatIf        shows what would be done, changes nothing (also when the script asks for administrator rights;
                     "Check Domain OS" runs it this way as a dry run)

  Safety: the saved files are used only when SYSTEM, Administrators or TrustedInstaller own them (a standard
  account cannot plant an "original state"), and only registry values, services and tasks the playbook's task files
  can touch are restored (undo-allowlist.txt next to this script). Saved .reg exports are read value by value and
  written only under the key they came from.
  Services and tasks that administrators may not change back (they belong to TrustedInstaller or SYSTEM) are
  restored by Undo-AsSystem.ps1, started once as SYSTEM through a one-shot scheduled task that is removed again.
  When something fails, the saved state is kept: restart and run Undo again.

  Per-user settings (HKCU) are restored for the account that runs this script only. AME Wizard writes the playbook's
  per-user settings into every account on the PC and into the default profile for new accounts; other accounts keep
  them (see README, "Undo").
  Not restored: OneDrive for accounts created later, Windows Update's to-do entries for Dev Home / Outlook /
  Cross Device (they come back with the next feature update), installed runtimes (uninstall them in Settings > Apps
  if you want), the Domain OS pictures in C:\Windows\Web\Wallpaper\Domain OS.
  Log: %ProgramData%\Domain OS\Logs\undo.log
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$RemoveTools)

$ErrorActionPreference = 'SilentlyContinue'
$common = Join-Path $PSScriptRoot 'DomainOS-Common.ps1'
if (-not (Test-Path -LiteralPath $common)) { Write-Host "DomainOS-Common.ps1 is missing next to this script: nothing was changed. Apply the playbook again to reinstall the tools."; Start-Sleep -Seconds 8; exit 1 }
. $common
# Not elevated: start again as administrator with the same switches (-WhatIf and -RemoveTools included).
if (Start-DomainOSElevated $MyInvocation.MyCommand.Path $PSBoundParameters) { exit 0 }

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$undoDir = Join-Path $DomainOSData 'Undo'
$file = Join-Path $undoDir 'state.json'
$log = Join-Path $DomainOSData 'Logs\undo.log'
function Write-Log([string]$text) { try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $text) -Encoding UTF8 } catch { }; Write-Host $text }
# (Skipped with -WhatIf, which changes nothing.)
if (-not $WhatIfPreference) {
    try { Protect-DomainOSData; New-Item -ItemType Directory -Force -Path (Join-Path $DomainOSData 'Logs') | Out-Null }
    catch { Write-Host "The permissions of $DomainOSData could not be checked ($($_.Exception.Message)); saved files are still checked one by one." }
}

if (-not (Test-Path -LiteralPath $file)) {
    Write-Log 'No saved state was found (%ProgramData%\Domain OS\Undo\state.json). The playbook was applied without it, or the file was deleted: nothing can be restored automatically.'
    Start-Sleep -Seconds 8
    exit 1
}
$state = $null
if (Test-DomainOSFile $file) { try { $state = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $state = $null } }
if (-not $state -or -not $state.saved) {
    Write-Log 'The saved state cannot be used (see the line above, or the file is damaged): nothing was changed. state.original.json in the same folder is a second copy of the original.'
    Start-Sleep -Seconds 10
    exit 1
}
Write-Log "--- Undo Domain OS $(@($state.versions) -join ', ') (state saved $($state.saved) by $($state.user)) ---"
if ($state.user -ne (Get-DomainOSUser).Full -and $state.user -ne "$env:USERDOMAIN\$env:COMPUTERNAME`$") { Write-Log "Note: the state was saved for $($state.user). Per-user settings are restored for $env:USERDOMAIN\$env:USERNAME." }

function PsPath([string]$p) { $p -replace '^HKLM\\', 'Registry::HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'Registry::HKEY_CURRENT_USER\' }
$done = 0; $failed = 0
$sysWork = New-Object System.Collections.Generic.List[object]

# Runs Undo-AsSystem.ps1 as SYSTEM for the given items; returns @{ Done; Failed } and logs every item.
function Invoke-DomainOSUndoAsSystem($items) {
    $res = @{ Done = 0; Failed = 0 }
    $script = Join-Path $PSScriptRoot 'Undo-AsSystem.ps1'
    $box = Join-Path $undoDir 'system'
    $taskName = 'Domain OS Undo (SYSTEM, one-shot)'
    try {
        if (-not (Test-DomainOSFile $script)) { throw 'Undo-AsSystem.ps1 is missing next to this script or not trusted (apply the playbook again to reinstall the tools)' }
        if (Test-Path -LiteralPath $box) { Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction Stop }
        New-Item -ItemType Directory -Path $box -Force -ErrorAction Stop | Out-Null
        Set-DomainOSFolderAcl $box @()                        # SYSTEM and Administrators only
        $work = Join-Path $box 'work.json'; $result = Join-Path $box 'result.json'
        ConvertTo-Json -InputObject @($items) -Depth 3 | Set-Content -LiteralPath $work -Encoding UTF8 -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Work `"$work`" -Result `"$result`""
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        try {
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $until = (Get-Date).AddMinutes(3)
            while (-not (Test-Path -LiteralPath $result) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 500 }
        } finally { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
        if (-not (Test-DomainOSFile $result)) { throw 'the SYSTEM step gave no answer within 3 minutes' }
        $answers = @(Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($i in $items) {
            $a = $answers | Where-Object { $_.kind -eq $i.kind -and $_.name -eq $i.name } | Select-Object -First 1
            $what = if ($i.kind -eq 'S') { 'service' } else { 'task' }
            if ($a -and $a.ok) { $res.Done++; Write-Log "$what $($i.name): restored as SYSTEM" }
            else {
                $why = if ($a) { $a.error } else { (@($answers | Where-Object { $_.kind -eq 'X' }) | ForEach-Object { $_.error }) -join '; ' }
                $res.Failed++; Write-Log "FAILED $what $($i.name) (also as SYSTEM): $why"
            }
        }
    } catch {
        $res.Failed += @($items).Count
        Write-Log "FAILED the SYSTEM step for $(@($items).Count) service(s)/task(s): $($_.Exception.Message)"
    } finally { Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue }
    return $res
}
$allowed = Get-DomainOSAllowList $PSScriptRoot
if (-not $allowed) {
    $failed++
    Write-Log 'FAILED: the list of what Undo may restore (undo-allowlist.txt next to this script) is missing or not trusted, so registry values, services and tasks are not restored. Apply the playbook again (it reinstalls the tools; the original state is kept) and run Undo again.'
}

# ---- Toolbox: with -RemoveTools its own full reset runs FIRST, so the playbook's values below are the last word --
$tbExe = Join-Path $env:ProgramFiles 'Domain OS\DomainScheduler.exe'
$toolboxReset = $false
if ($RemoveTools -and (Test-Path -LiteralPath $tbExe) -and $PSCmdlet.ShouldProcess('Domain OS app', 'full reset (priorities, power, overclocking, devices)')) {
    Get-Process -Name 'DomainScheduler' | Stop-Process -Force
    Start-Sleep -Seconds 1
    try {
        $p = Start-Process -FilePath $tbExe -ArgumentList '--uninstall' -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($p.WaitForExit(90000)) { $toolboxReset = $true; $done++; Write-Log 'Toolbox: full reset done.' }
        else { $failed++; Write-Log 'FAILED Toolbox full reset: no answer within 90 s' }
    } catch { $failed++; Write-Log "FAILED Toolbox full reset: $($_.Exception.Message)" }
}

# ---- registry: the value it had, or no value if it had none -------------------------------------------------
$kinds = @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')
foreach ($r in $state.registry) {
    if (-not $allowed) { break }
    if (-not $allowed["R|$($r.path)|$($r.name)"] -or $r.path -notmatch '^(HKLM|HKCU)\\') { Write-Log "Skipped $($r.path)\$($r.name): not a value Domain OS changes"; continue }
    if ($r.unreadable) { Write-Log "Skipped $($r.path)\$($r.name): it could not be read when the state was saved, so it is left as it is"; continue }
    $path = PsPath $r.path
    try {
        if ($r.exists) {
            if ($kinds -notcontains $r.kind) { throw "unexpected value type '$($r.kind)'" }
            if ($PSCmdlet.ShouldProcess("$($r.path)\$($r.name)", "restore $($r.data)")) {
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
                $data = switch ($r.kind) { 'MultiString' { [string[]]@($r.data) } 'Binary' { [byte[]]@($r.data) } 'DWord' { [int]$r.data } 'QWord' { [long]$r.data } default { [string]$r.data } }
                New-ItemProperty -LiteralPath $path -Name $r.name -Value $data -PropertyType $r.kind -Force -ErrorAction Stop | Out-Null
                $done++
            }
        } elseif ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).GetValueNames() -contains $r.name)) {
            # (a key that is not there holds no value; earlier versions failed on it here, e.g. on a policy key of an
            # option that was not ticked)
            if ($PSCmdlet.ShouldProcess("$($r.path)\$($r.name)", 'remove (it did not exist)')) {
                Remove-ItemProperty -LiteralPath $path -Name $r.name -Force -ErrorAction Stop
                $done++
            }
        }
    } catch { $failed++; Write-Log "FAILED registry $($r.path)\$($r.name): $($_.Exception.Message)" }
}

# ---- the link tracking service, deleted by versions 1.6.7-2.1.0: registered again from its backup --------------
$trk = Join-Path $undoDir 'TrkWks.reg'
if ((Test-Path -LiteralPath $trk) -and -not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\TrkWks') -and $PSCmdlet.ShouldProcess('TrkWks', 'register the service again')) {
    try {
        $n = Import-DomainOSRegFile $trk $DomainOSTrkWksKey $DomainOSTrkWksCheck
        $done++; Write-Log "service TrkWks registered again ($n values; it starts after the restart)"
    } catch { $failed++; Write-Log "FAILED service TrkWks: the backup was not used ($($_.Exception.Message))" }
}

# ---- services: the start-up type they had -------------------------------------------------------------------
foreach ($s in $state.services) {
    if (-not $allowed) { break }
    if (-not $allowed["S|$($s.name)"] -or $s.name -notmatch '^[\w\.\-]+$') { Write-Log "Skipped service $($s.name): not one Domain OS changes"; continue }
    if ($s.unreadable -or $null -eq $s.start -or [int]$s.start -lt 0 -or [int]$s.start -gt 4) { Write-Log "Skipped service $($s.name): no usable saved start type"; continue }
    $key = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($s.name)"
    $now = (Get-ItemProperty -LiteralPath $key).Start
    if ($null -eq $now -or [int]$now -eq [int]$s.start) { continue }
    try {
        if ($PSCmdlet.ShouldProcess($s.name, "start-up type $now -> $($s.start)")) {
            Set-ItemProperty -LiteralPath $key -Name 'Start' -Value ([int]$s.start) -Type DWord -ErrorAction Stop
            if ($s.running) { Start-Service -Name $s.name }
            $done++
        }
    } catch {
        # Most often: the key belongs to TrustedInstaller (the playbook is applied with its rights). Tried again as SYSTEM below.
        $sysWork.Add([pscustomobject]@{ kind = 'S'; name = $s.name; start = [int]$s.start; running = [bool]$s.running })
        Write-Log "service $($s.name): not allowed for administrators ($($_.Exception.Message)); tried again as SYSTEM"
    }
}

# ---- scheduled tasks ----------------------------------------------------------------------------------------
foreach ($t in $state.tasks) {
    if (-not $allowed) { break }
    if (-not $allowed["T|$($t.path)"]) { Write-Log "Skipped task $($t.path): not one Domain OS changes"; continue }
    $i = $t.path.LastIndexOf('\')
    $task = Get-ScheduledTask -TaskPath ($t.path.Substring(0, $i + 1)) -TaskName ($t.path.Substring($i + 1))
    if (-not $task) { continue }
    $enabled = $task.State -ne 'Disabled'
    if ($enabled -eq [bool]$t.enabled) { continue }
    try {
        if ($PSCmdlet.ShouldProcess($t.path, $(if ($t.enabled) { 'enable' } else { 'disable' }))) {
            if ($t.enabled) { $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null } else { $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null }
            $done++
        }
    } catch {
        $sysWork.Add([pscustomobject]@{ kind = 'T'; name = $t.path; enabled = [bool]$t.enabled })
        Write-Log "task $($t.path): not allowed for administrators ($($_.Exception.Message)); tried again as SYSTEM"
    }
}

# ---- what administrators may not change: once more as SYSTEM -------------------------------------------------
# A one-shot scheduled task runs Undo-AsSystem.ps1 (next to this script, in Program Files) as SYSTEM with the list
# of these items; it checks them against the same allow-list, writes a result file and the task is removed again.
if ($sysWork.Count -gt 0 -and -not $WhatIfPreference) {
    $r = Invoke-DomainOSUndoAsSystem $sysWork.ToArray()
    $done += $r.Done; $failed += $r.Failed
}

# ---- hibernation, OneDrive, Store ---------------------------------------------------------------------------
if ($state.hibernate -and -not [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power').HibernateEnabled) {
    if ($PSCmdlet.ShouldProcess('hibernation', 'switch on')) { & powercfg.exe /hibernate on; if ($LASTEXITCODE -eq 0) { $done++ } else { $failed++; Write-Log 'FAILED hibernation: powercfg could not switch it on' } }
}
if ($state.oneDrive -and -not (Test-Path (Join-Path (Get-DomainOSUserFolder 'LocalApplicationData') 'Microsoft\OneDrive\OneDrive.exe'))) {
    $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'
    if ((Test-Path $setup) -and $PSCmdlet.ShouldProcess('OneDrive', 'install again')) { Start-Process $setup; $done++; Write-Log 'OneDrive setup started.' }
}
# Classic right-click menu: the switch key goes away again if it was not there before Domain OS.
$classic = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
if (($state.classicMenu -eq $false) -and (Test-Path -LiteralPath $classic) -and $PSCmdlet.ShouldProcess('classic right-click menu', 'back to the Windows 11 menu')) {
    try { Remove-Item -LiteralPath $classic -Recurse -Force -ErrorAction Stop; $done++ } catch { $failed++; Write-Log "FAILED classic menu: $($_.Exception.Message)" }
}

# Removed apps were marked "do not provision again" (apps.yml, Deprovisioned): the marks go, so the Store and feature
# updates can bring the apps back.
$depro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
$ours = @('clipchamp.clipchamp_yxz26nhyzhsrt', 'Microsoft.BingNews_8wekyb3d8bbwe', 'Microsoft.BingWeather_8wekyb3d8bbwe', 'Microsoft.BingSearch_8wekyb3d8bbwe', 'Microsoft.MicrosoftSolitaireCollection_8wekyb3d8bbwe', 'MSTeams_8wekyb3d8bbwe', 'MicrosoftTeams_8wekyb3d8bbwe', 'Microsoft.Copilot_8wekyb3d8bbwe', 'Microsoft.OutlookForWindows_8wekyb3d8bbwe', 'Microsoft.Windows.DevHome_8wekyb3d8bbwe', 'Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe', 'Microsoft.GetHelp_8wekyb3d8bbwe', 'Microsoft.Getstarted_8wekyb3d8bbwe', 'Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe', 'Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe', 'Microsoft.Todos_8wekyb3d8bbwe', 'Microsoft.ZuneVideo_8wekyb3d8bbwe', 'Microsoft.549981C3F5F10_8wekyb3d8bbwe', 'Microsoft.WindowsMaps_8wekyb3d8bbwe', 'microsoft.windowscommunicationsapps_8wekyb3d8bbwe', 'MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe', 'Microsoft.YourPhone_8wekyb3d8bbwe', 'MicrosoftWindows.CrossDevice_cw5n1h2txyewy', 'MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy', 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0', 'Disney.37853FC22B2CE_6rarf9sa4v8jt', '7EE7776C.LinkedInforWindows_w1wdnht996qgy', 'Microsoft.Windows.AIHub_8wekyb3d8bbwe', 'Microsoft.PCManager_8wekyb3d8bbwe', 'Microsoft.MicrosoftPCManager_8wekyb3d8bbwe', 'Microsoft.M365Companions_8wekyb3d8bbwe')
foreach ($f in $ours) {
    $k = Join-Path $depro $f
    if ((Test-Path -LiteralPath $k) -and $PSCmdlet.ShouldProcess($k, 'delete')) {
        try { Remove-Item -LiteralPath $k -Force -ErrorAction Stop; $done++ } catch { $failed++; Write-Log "Could not delete $k ($($_.Exception.Message))" }
    }
}
$nowApps = @(Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name -Unique)
$missing = @($state.apps | Where-Object { $nowApps -notcontains $_ -and $_ -notmatch '^Microsoft\.(NET|VCLibs|UI\.Xaml|Services\.Store|WindowsAppRuntime)' })
if ($missing -contains 'Microsoft.WindowsStore') {
    if ($PSCmdlet.ShouldProcess('Microsoft Store', 'install again (wsreset -i)')) { Start-Process 'wsreset.exe' -ArgumentList '-i'; Write-Log 'Microsoft Store is being installed again (it takes a few minutes).' }
}

# Runs one of the tools with -Restore; a non-zero exit code counts as a failure.
function Invoke-Restore([string]$script, [string]$what) {
    & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Restore
    if ($LASTEXITCODE -eq 0) { $script:done++; Write-Log "$what put back." } else { $script:failed++; Write-Log "FAILED $what (exit code $LASTEXITCODE, see install.log / power.log)" }
}

# ---- power plan ------------------------------------------------------------------------------------------
$planScript = Join-Path $PSScriptRoot 'Set-PowerPlan.ps1'
if ((Test-Path (Join-Path $undoDir 'power-plan-before.txt')) -and (Test-Path $planScript) -and $PSCmdlet.ShouldProcess('power plan', 'put back the one active before Domain OS')) {
    Invoke-Restore $planScript 'Power plan'
}

# ---- a pending check of removed apps at the next sign-in (Remove-AppLeftovers.ps1) is cancelled ----------------
foreach ($v in 'DomainOS-AppLeftovers', 'DomainOS-AppLeftovers-Max') {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $v -ErrorAction SilentlyContinue
}

# ---- taskbar pins (saved by Set-Taskbar.ps1 for this user) -------------------------------------------------
$tb = Get-DomainOSUserDir 'Taskbar'
if ((Test-DomainOSFile (Join-Path $tb 'saved.txt')) -and $PSCmdlet.ShouldProcess('taskbar pins', 'put back')) {
    $tbFailed = $false
    $pins = Join-Path (Get-DomainOSUserFolder 'ApplicationData') 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    New-Item -ItemType Directory -Force -Path $pins | Out-Null
    foreach ($lnk in @(Get-ChildItem -LiteralPath (Join-Path $tb 'pins') -Filter '*.lnk' -Force)) {
        if (Test-DomainOSFile $lnk.FullName) { Copy-Item -LiteralPath $lnk.FullName -Destination $pins -Force }
    }
    # The saved pin order is checked completely before the current one is replaced.
    $bandKey = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    $band = Join-Path $tb 'Taskband.reg'
    try {
        if (Test-Path -LiteralPath $band) { [void](Import-DomainOSRegFile $band $bandKey -ValidateOnly) }
        Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Recurse -Force
        if (Test-Path -LiteralPath $band) { [void](Import-DomainOSRegFile $band $bandKey) }
    } catch { $tbFailed = $true; Write-Log "FAILED taskbar pin order: $($_.Exception.Message)" }
    Restart-DomainOSExplorer      # this session only; Windows starts Explorer again as the user, with the restored pins
    if ($tbFailed) { $failed++ } else { Remove-Item -Recurse -Force -LiteralPath $tb; $done++; Write-Log 'Taskbar pins put back.' }
}

# ---- wallpapers: desktop and lock screen (saved by Set-Wallpapers.ps1 for this user) ---------------------------
$wpScript = Join-Path $PSScriptRoot 'Set-Wallpapers.ps1'
if ((Test-Path (Join-Path (Get-DomainOSUserDir 'Wallpaper') 'state.json')) -and (Test-Path $wpScript) -and $PSCmdlet.ShouldProcess('wallpapers', 'put back the desktop and lock screen pictures')) {
    Invoke-Restore $wpScript 'Desktop and lock screen pictures'
}

# ---- Start menu pins (saved by Set-StartPins.ps1 for this user) ---------------------------------------------
$startScript = Join-Path $PSScriptRoot 'Set-StartPins.ps1'
if ((Test-Path (Join-Path (Get-DomainOSUserDir 'StartPins') 'saved.txt')) -and (Test-Path $startScript) -and $PSCmdlet.ShouldProcess('Start menu pins', 'put back')) {
    Invoke-Restore $startScript 'Start menu pins'
}

# ---- hypervisor launch type (changed by Set-Hypervisor.ps1 only when virtualization was off in firmware) ----
$hvScript = Join-Path $PSScriptRoot 'Set-Hypervisor.ps1'
if ((Test-Path (Join-Path $undoDir 'hypervisorlaunchtype.txt')) -and (Test-Path $hvScript) -and $PSCmdlet.ShouldProcess('hypervisorlaunchtype', 'put back')) {
    Invoke-Restore $hvScript 'Hypervisor launch type'
}

# ---- Toolbox: device changes (interrupt layout, MSI, power saving) go back to what they were --------------------
# Not needed after the full reset of -RemoveTools above, which includes them.
if (-not $toolboxReset -and (Test-Path -LiteralPath $tbExe) -and $PSCmdlet.ShouldProcess('Toolbox device changes', 'revert')) {
    try {
        $p = Start-Process -FilePath $tbExe -ArgumentList '--revert-devices' -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($p.WaitForExit(60000)) { $done++; Write-Log 'Toolbox: device changes reverted (they apply after the restart).' }
        else { $failed++; Write-Log 'FAILED Toolbox device revert: no answer within 60 s' }
    } catch { $failed++; Write-Log "FAILED Toolbox device revert: $($_.Exception.Message)" }
}

# ---- the tools ----------------------------------------------------------------------------------------------
if ($RemoveTools -and $PSCmdlet.ShouldProcess('Domain OS app', 'remove autostart, shortcuts and Start menu folder')) {
    Unregister-ScheduledTask -TaskName 'DomainScheduler' -Confirm:$false
    Remove-Item -Recurse -Force (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Domain OS')
    Remove-Item -Force (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Domain OS Toolbox.lnk')
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSGuide'
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSGuide'
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSWhatsNew'
    foreach ($t in 'Open the driver guide', "Open What's new") { Unregister-ScheduledTask -TaskPath '\Domain OS\' -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    Write-Log 'Domain OS app: autostart, desktop shortcut and Start menu folder removed. Delete "Program Files\Domain OS" after the restart.'
}

# ---- the record of the chosen options (Tasks\options.yml): gone after a complete undo, as Domain OS is no longer applied
# (only HKLM\SOFTWARE\Domain OS\Options; Toolbox keeps its own settings under HKLM\SOFTWARE\Domain OS\Toolbox) ------
$optKey = 'HKLM:\SOFTWARE\Domain OS\Options'
if ($failed -eq 0 -and (Test-Path -LiteralPath $optKey) -and $PSCmdlet.ShouldProcess('HKLM\SOFTWARE\Domain OS\Options', 'delete (the record of the chosen options)')) {
    try { Remove-Item -LiteralPath $optKey -Recurse -Force -ErrorAction Stop; $done++ } catch { $failed++; Write-Log "FAILED HKLM\SOFTWARE\Domain OS\Options: $($_.Exception.Message)" }
}

Write-Log ("Restored: {0} items. Failed: {1}." -f $done, $failed)
if ($missing.Count -gt 0) {
    Write-Log ("Apps that were removed and are not restored automatically ({0}); install the ones you want from the Microsoft Store:" -f $missing.Count)
    $missing | ForEach-Object { Write-Log "   $_" }
}
if (-not $WhatIfPreference) {
    if ($failed -eq 0) {
        # The saved state is used up: the next version of the playbook saves a fresh one when it is applied.
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Rename-Item -LiteralPath $file -NewName "state-restored-$stamp.json"
        $orig = Join-Path $undoDir 'state.original.json'
        if (Test-Path -LiteralPath $orig) { Rename-Item -LiteralPath $orig -NewName "state.original-restored-$stamp.json" }
        Add-Content -Path (Join-Path $DomainOSData 'history.log') -Value ('{0:yyyy-MM-dd HH:mm:ss}  undone   {1}' -f (Get-Date), (@($state.versions) -join ', ')) -Encoding UTF8
        Write-Log 'Restart the computer to finish. After the restart another version of the playbook can be applied like the first time.'
    } else {
        Write-Log "$failed item(s) could not be put back (see the FAILED lines above). The saved state is KEPT: restart the computer and run Undo Domain OS again."
    }
    Write-Log 'The log is in %ProgramData%\Domain OS\Logs\undo.log'
}
Start-Sleep -Seconds 10
if ($failed -eq 0) { exit 0 } else { exit 1 }
