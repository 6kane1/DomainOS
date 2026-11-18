<#
  Domain OS — puts Windows back to what it was before the playbook, without reinstalling.

  Restored from the state saved before the first change: every registry value, service start-up type and
  scheduled task the playbook touched, hibernation, and OneDrive. Removed apps are NOT part of Windows any more
  and are installed again from the Microsoft Store; the script lists them and reinstalls the Store itself if needed.

      -RemoveTools   also removes the Domain OS app, its autostart task and its Start menu folder
      -WhatIf        shows what would be done, changes nothing

  Registry values of the user account are restored for the account that runs this script.
  Log: %ProgramData%\Domain OS\Logs\undo.log
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$RemoveTools)

$ErrorActionPreference = 'SilentlyContinue'
$self = $MyInvocation.MyCommand.Path
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $extra = if ($RemoveTools) { ' -RemoveTools' } else { '' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`"$extra" -Verb RunAs
    exit 0
}

$file = Join-Path $env:ProgramData 'Domain OS\Undo\state.json'
$logDir = Join-Path $env:ProgramData 'Domain OS\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'undo.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

if (-not (Test-Path $file)) {
    Write-Log 'No saved state was found (%ProgramData%\Domain OS\Undo\state.json). The playbook was applied without it, or the file was deleted: nothing can be restored automatically.'
    Start-Sleep -Seconds 8
    exit 1
}
$state = Get-Content -Raw -Encoding UTF8 $file | ConvertFrom-Json
Write-Log "--- Undo Domain OS $(@($state.versions) -join ', ') (state saved $($state.saved) by $($state.user)) ---"
if ($state.user -ne "$env:USERDOMAIN\$env:USERNAME") { Write-Log "Note: the state was saved for $($state.user). Per-user settings are restored for $env:USERDOMAIN\$env:USERNAME." }

function PsPath([string]$p) { $p -replace '^HKLM\\', 'Registry::HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'Registry::HKEY_CURRENT_USER\' }
$done = 0; $failed = 0

# ---- registry: the value it had, or no value if it had none -------------------------------------------------
foreach ($r in $state.registry) {
    $path = PsPath $r.path
    try {
        if ($r.exists) {
            if ($PSCmdlet.ShouldProcess("$($r.path)\$($r.name)", "restore $($r.data)")) {
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
                $data = if ($r.kind -eq 'MultiString') { [string[]]$r.data } elseif ($r.kind -eq 'Binary') { [byte[]]$r.data } else { $r.data }
                New-ItemProperty -LiteralPath $path -Name $r.name -Value $data -PropertyType $r.kind -Force -ErrorAction Stop | Out-Null
                $done++
            }
        } elseif ((Get-Item -LiteralPath $path).GetValueNames() -contains $r.name) {
            if ($PSCmdlet.ShouldProcess("$($r.path)\$($r.name)", 'remove (it did not exist)')) {
                Remove-ItemProperty -LiteralPath $path -Name $r.name -Force -ErrorAction Stop
                $done++
            }
        }
    } catch { $failed++; Write-Log "FAILED registry $($r.path)\$($r.name): $($_.Exception.Message)" }
}

# ---- the link tracking service, deleted by Remove-TrkWks.ps1: registered again from its backup ----------------
$trk = Join-Path $env:ProgramData 'Domain OS\Undo\TrkWks.reg'
if ((Test-Path $trk) -and -not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\TrkWks') -and $PSCmdlet.ShouldProcess('TrkWks', 'register the service again')) {
    & reg.exe import $trk 2>$null
    if ($LASTEXITCODE -eq 0) { $done++; Write-Log 'service TrkWks registered again (it starts after the restart)' }
    else { $failed++; Write-Log 'FAILED service TrkWks: the backup could not be imported' }
}

# ---- services: the start-up type they had -------------------------------------------------------------------
foreach ($s in $state.services) {
    $key = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($s.name)"
    $now = (Get-ItemProperty -LiteralPath $key).Start
    if ($null -eq $now -or [int]$now -eq [int]$s.start) { continue }
    try {
        if ($PSCmdlet.ShouldProcess($s.name, "start-up type $now -> $($s.start)")) {
            Set-ItemProperty -LiteralPath $key -Name 'Start' -Value ([int]$s.start) -Type DWord -ErrorAction Stop
            if ($s.running) { Start-Service -Name $s.name }
            $done++
        }
    } catch { $failed++; Write-Log "FAILED service $($s.name): $($_.Exception.Message)" }
}

# ---- scheduled tasks ----------------------------------------------------------------------------------------
foreach ($t in $state.tasks) {
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
    } catch { $failed++; Write-Log "FAILED task $($t.path): $($_.Exception.Message)" }
}

# ---- hibernation, OneDrive, Store ---------------------------------------------------------------------------
if ($state.hibernate -and -not [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power').HibernateEnabled) {
    if ($PSCmdlet.ShouldProcess('hibernation', 'switch on')) { & powercfg.exe /hibernate on; $done++ }
}
if ($state.oneDrive -and -not (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'))) {
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

# ---- power plan ------------------------------------------------------------------------------------------
$planScript = Join-Path $PSScriptRoot 'Set-PowerPlan.ps1'
if ((Test-Path (Join-Path $env:ProgramData 'Domain OS\Undo\power-plan-before.txt')) -and (Test-Path $planScript) -and $PSCmdlet.ShouldProcess('power plan', 'put back the one active before Domain OS')) {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $planScript -Restore
    $done++
}

# ---- a pending check of removed apps at the next sign-in (Remove-AppLeftovers.ps1) is cancelled ----------------
foreach ($v in 'DomainOS-AppLeftovers', 'DomainOS-AppLeftovers-Max') {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $v -ErrorAction SilentlyContinue
}

# ---- taskbar pins (saved by Set-Taskbar.ps1 for this user) -------------------------------------------------
$tb = Join-Path $env:ProgramData "Domain OS\Undo\Taskbar\$env:USERNAME"
if ((Test-Path (Join-Path $tb 'saved.txt')) -and $PSCmdlet.ShouldProcess('taskbar pins', 'put back')) {
    $pins = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    New-Item -ItemType Directory -Force -Path $pins | Out-Null
    Copy-Item -Path (Join-Path $tb 'pins\*') -Destination $pins -Force
    & cmd.exe /c 'reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" /f >nul 2>&1'
    if (Test-Path (Join-Path $tb 'Taskband.reg')) { & cmd.exe /c "reg.exe import `"$(Join-Path $tb 'Taskband.reg')`" >nul 2>&1" }
    & taskkill.exe /f /im explorer.exe 2>&1 | Out-Null       # Windows starts it again by itself, with the restored pins
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer)) { Start-Process (Join-Path $env:SystemRoot 'explorer.exe') }
    Remove-Item -Recurse -Force $tb
    $done++; Write-Log 'Taskbar pins put back.'
}

# ---- wallpapers: desktop and lock screen (saved by Set-Wallpapers.ps1 for this user) ---------------------------
$wpScript = Join-Path $PSScriptRoot 'Set-Wallpapers.ps1'
if ((Test-Path (Join-Path $env:ProgramData "Domain OS\Undo\Wallpaper\$env:USERNAME\state.json")) -and (Test-Path $wpScript) -and $PSCmdlet.ShouldProcess('wallpapers', 'put back the desktop and lock screen pictures')) {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $wpScript -Restore
    $done++; Write-Log 'Desktop and lock screen pictures put back.'
}

# ---- Start menu pins (saved by Set-StartPins.ps1 for this user) ---------------------------------------------
$startScript = Join-Path $PSScriptRoot 'Set-StartPins.ps1'
if ((Test-Path (Join-Path $env:ProgramData "Domain OS\Undo\StartPins\$env:USERNAME\saved.txt")) -and (Test-Path $startScript) -and $PSCmdlet.ShouldProcess('Start menu pins', 'put back')) {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $startScript -Restore
    $done++; Write-Log 'Start menu pins put back.'
}

# ---- hypervisor launch type (changed by Set-Hypervisor.ps1 only when virtualization was off in firmware) ----
$hvScript = Join-Path $PSScriptRoot 'Set-Hypervisor.ps1'
if ((Test-Path (Join-Path $env:ProgramData 'Domain OS\Undo\hypervisorlaunchtype.txt')) -and (Test-Path $hvScript) -and $PSCmdlet.ShouldProcess('hypervisorlaunchtype', 'put back')) {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $hvScript -Restore
    $done++; Write-Log 'Hypervisor launch type put back.'
}

# ---- Toolbox: device changes (interrupt layout, MSI, power saving) go back to what they were --------------------
$tbExe = Join-Path $env:ProgramFiles 'Domain OS\DomainScheduler.exe'
if ((Test-Path -LiteralPath $tbExe) -and $PSCmdlet.ShouldProcess('Toolbox device changes', 'revert')) {
    try {
        $p = Start-Process -FilePath $tbExe -ArgumentList '--revert-devices' -PassThru -WindowStyle Hidden
        if ($p.WaitForExit(60000)) { $done++; Write-Log 'Toolbox: device changes reverted (they apply after the restart).' }
        else { $failed++; Write-Log 'FAILED Toolbox device revert: no answer within 60 s' }
    } catch { $failed++; Write-Log "FAILED Toolbox device revert: $($_.Exception.Message)" }
}

# ---- the tools ----------------------------------------------------------------------------------------------
if ($RemoveTools -and $PSCmdlet.ShouldProcess('Domain OS app', 'remove')) {
    # The running copy is closed, then the program's own full reset puts back everything it changed (priorities,
    # power, overclocking, devices) before its files go.
    Get-Process -Name 'DomainScheduler' | Stop-Process -Force
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $tbExe) {
        try { $p = Start-Process -FilePath $tbExe -ArgumentList '--uninstall' -PassThru -WindowStyle Hidden; [void]$p.WaitForExit(90000); Write-Log 'Toolbox: full reset done.' }
        catch { Write-Log "Toolbox full reset: $($_.Exception.Message)" }
    }
    Unregister-ScheduledTask -TaskName 'DomainScheduler' -Confirm:$false
    Remove-Item -Recurse -Force (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Domain OS')
    Remove-Item -Force (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Domain OS Toolbox.lnk')
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSGuide'
    Write-Log 'Domain OS app: autostart, desktop shortcut and Start menu folder removed. Delete "Program Files\Domain OS" after the restart.'
}

Write-Log ("Restored: {0} items. Failed: {1}." -f $done, $failed)
if ($missing.Count -gt 0) {
    Write-Log ("Apps that were removed and are not restored automatically ({0}); install the ones you want from the Microsoft Store:" -f $missing.Count)
    $missing | ForEach-Object { Write-Log "   $_" }
}
if (-not $WhatIfPreference) {
    # The saved state is used up: the next version of the playbook saves a fresh one when it is applied.
    Rename-Item -Path $file -NewName ('state-restored-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
    Add-Content -Path (Join-Path $env:ProgramData 'Domain OS\history.log') -Value ('{0:yyyy-MM-dd HH:mm:ss}  undone   {1}' -f (Get-Date), (@($state.versions) -join ', ')) -Encoding UTF8
    Write-Log 'Restart the computer to finish. After the restart another version of the playbook can be applied like the first time.'
    Write-Log 'The log is in %ProgramData%\Domain OS\Logs\undo.log'
}
Start-Sleep -Seconds 10
exit 0
