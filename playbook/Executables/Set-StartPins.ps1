<#
  Domain OS — rebuilds the pinned list of the Start menu from programs that are installed.

  Why: Windows 11 keeps its default Start pins (Copilot, Teams, Outlook, Solitaire, the "Other" folder of sponsored
  apps) in a per-user file, start2.bin. Removing the apps does not touch that file, so their tiles stay in Start.

  How: the documented Start policy ConfigureStartPins is written with a short list (Settings, File Explorer, Edge,
  Domain OS Toolbox, plus the Store, Xbox, Terminal and Notepad if they are installed). On Windows 11 24H2 with
  KB5062660 and later (every 25H2) the list carries "applyOnce": Start applies it at the next sign-in, replacing the
  whole pinned list, and never again, so the policy stays and pins can be changed as usual. On older builds
  applyOnce is ignored and the list would come back at every sign-in, so there a one-time task removes the policy
  at the sign-in after the one that applied it.

  Runs as the signed-in user (elevated). Only the first run changes anything: when a newer version of the playbook
  is applied over an older one, the pins the user arranged since then stay as they are. (Version 1.5.4 deleted
  start2.bin while Start was restarting, which Start could write back; its run is not counted as done.)
  The original start2.bin is kept for "Undo Domain OS". Log: %ProgramData%\Domain OS\Logs\install.log
#>
[CmdletBinding()]
param([switch]$Restore)

$ErrorActionPreference = 'Stop'
$data = Join-Path $env:ProgramData 'Domain OS'
$backup = Join-Path $data "Undo\StartPins\$env:USERNAME"
$state = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'
$policy = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
$provider = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\providers\B5292708-1619-419B-9923-E5D9F3925E71\default\Device\Start'
$taskName = 'Domain OS Start pins cleanup'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Start] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

function Remove-Policy {
    foreach ($k in $policy, $provider) {
        foreach ($v in 'ConfigureStartPins', 'ConfigureStartPins_ProviderSet', 'ConfigureStartPins_WinningProvider', 'ConfigureStartPins_LastWrite') {
            Remove-ItemProperty -Path $k -Name $v -ErrorAction SilentlyContinue
        }
    }
}

function Restart-Start {
    Get-Process -Name 'StartMenuExperienceHost' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

try {
    if ($Restore) {
        Remove-Policy
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $backup 'saved.txt')) {
            Restart-Start
            Get-ChildItem -Path $backup -Filter 'start*.bin' | Copy-Item -Destination $state -Force
            Restart-Start
            Remove-Item -Recurse -Force $backup
            Write-Log 'Original Start pins put back'
        }
        exit 0
    }

    if (Test-Path (Join-Path $backup 'pins.txt')) {
        Write-Log 'Start pins were rebuilt by an earlier version: the current pins are kept'
        exit 0
    }

    # 1. The original pin files are kept once for Undo (an earlier run may have kept them already).
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    if (-not (Test-Path (Join-Path $backup 'saved.txt'))) {
        if (Test-Path $state) { Get-ChildItem -Path $state -Filter 'start*.bin' -ErrorAction SilentlyContinue | Copy-Item -Destination $backup -Force }
        Set-Content -Path (Join-Path $backup 'saved.txt') -Value (Get-Date -Format s) -Encoding UTF8
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    # applyOnce works from 24H2 build 26100.4770 (KB5062660); 25H2 is 26200.
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuildNumber; $ubr = [int]$cv.UBR
    $once = ($build -gt 26100) -or ($build -eq 26100 -and $ubr -ge 4770)

    # 2. The list: only what exists on this PC.
    $pins = New-Object System.Collections.Generic.List[object]
    $pins.Add(@{ packagedAppId = 'windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel' })
    $pins.Add(@{ desktopAppLink = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\File Explorer.lnk' })
    foreach ($l in @('Microsoft Edge.lnk', 'Domain OS\Domain OS Toolbox.lnk')) {
        if (Test-Path (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$l")) {
            $pins.Add(@{ desktopAppLink = "%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\$l" })
        }
    }
    $packaged = [ordered]@{
        'Microsoft.WindowsStore'    = 'Microsoft.WindowsStore_8wekyb3d8bbwe!App'
        'Microsoft.GamingApp'       = 'Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'
        'Microsoft.WindowsTerminal' = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App'
        'Microsoft.WindowsNotepad'  = 'Microsoft.WindowsNotepad_8wekyb3d8bbwe!App'
    }
    foreach ($name in $packaged.Keys) {
        if (Get-AppxPackage -Name $name -ErrorAction SilentlyContinue) { $pins.Add(@{ packagedAppId = $packaged[$name] }) }
    }
    $layout = [ordered]@{}
    if ($once) { $layout.applyOnce = $true }
    $layout.pinnedList = $pins
    $json = ($layout | ConvertTo-Json -Depth 4 -Compress)

    # 3. The policy, as the MDM provider writes it.
    foreach ($k in $policy, $provider) { New-Item -Path $k -Force | Out-Null }
    New-ItemProperty -Path $policy -Name 'ConfigureStartPins' -Value $json -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $policy -Name 'ConfigureStartPins_ProviderSet' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $policy -Name 'ConfigureStartPins_WinningProvider' -Value 'B5292708-1619-419B-9923-E5D9F3925E71' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $provider -Name 'ConfigureStartPins' -Value $json -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $provider -Name 'ConfigureStartPins_LastWrite' -Value 1 -PropertyType DWord -Force | Out-Null

    # 4. Start reads the policy at the next sign-in (the playbook ends with a restart).
    Restart-Start

    # 5. Older builds re-apply the list at every sign-in: remove the policy at the second sign-in, after it was applied.
    if (-not $once) {
        $flag = Join-Path $backup 'applied.txt'
        $cmd = "if(-not (Test-Path '$flag')){ Set-Content -Path '$flag' -Value 1; exit }; foreach(`$k in '$policy','$provider'){ foreach(`$v in 'ConfigureStartPins','ConfigureStartPins_ProviderSet','ConfigureStartPins_WinningProvider','ConfigureStartPins_LastWrite'){ Remove-ItemProperty -Path `$k -Name `$v -ErrorAction SilentlyContinue } }; Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$cmd`""
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    }
    Set-Content -Path (Join-Path $backup 'pins.txt') -Value $json -Encoding UTF8

    Write-Log ("Start pins set: {0} items, applied at the next sign-in ({1})" -f $pins.Count, $(if ($once) { 'applyOnce, build ' + $build + '.' + $ubr } else { 'policy removed at the second sign-in, build ' + $build + '.' + $ubr }))
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
