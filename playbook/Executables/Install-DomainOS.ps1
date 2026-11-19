<#
  Domain OS — copies the tools to the computer.
    -Part Tools      scripts and the driver guide, Start menu folder "Domain OS", and the list of what Undo may
                     restore (undo-allowlist.txt, built from the playbook's task files). Runs right after
                     Save-State, before any change, so "Undo Domain OS" is on the PC even if the install stops.
                     Also "Check Domain OS" (Check-DomainOS.ps1 + expected.json, read-only: compares the PC with what
                     the playbook set and reports PASS / WARN / FAIL). A playbook without expected.json is a broken
                     build: the install stops here, before any change.
    -Part Scheduler  DomainScheduler.exe + a logon task for every user (highest rights the user has),
                     shortcut "Domain OS Toolbox" in the Start menu and on the desktop
    -Part Guide      the driver guide opens once after the next sign-in, without administrator rights (a scheduled
                     task for the group Users, see Register-DomainOSOpenAtLogon in DomainOS-Common.ps1)
    -Part WhatsNew   the page "What's new in Domain OS" (Guide\whats-new.html) opens once after the next sign-in,
                     the same way; once per version, so an update shows what changed
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Tools', 'Scheduler', 'Guide', 'WhatsNew')][string]$Part)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path $env:ProgramFiles 'Domain OS'
$menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Domain OS'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $here 'DomainOS-Common.ps1')
$data = $DomainOSData
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}' -f (Get-Date), $Part, $text) -Encoding UTF8 } catch { }; Write-Host $text }

function New-Shortcut([string]$name, [string]$target, [string]$arguments, [string]$description, [string]$folder = $menu) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $folder "$name.lnk"))
    $link.TargetPath = $target
    $link.Arguments = $arguments
    $link.Description = $description
    $link.WorkingDirectory = $app
    $link.Save()
}

try {
    # The data folder gets its protected permissions (administrators only can change it) before anything is written.
    Protect-DomainOSData
    New-Item -ItemType Directory -Force -Path $app, (Join-Path $data 'Logs'), $menu | Out-Null
    switch ($Part) {
        'Tools' {
            $tools = Join-Path $app 'Tools'
            New-Item -ItemType Directory -Force -Path $tools | Out-Null
            Copy-Item -Path (Join-Path $here 'DomainOS-Common.ps1'), (Join-Path $here 'Install-Runtimes.ps1'), (Join-Path $here 'Restore-Updates.ps1'), (Join-Path $here 'Undo-DomainOS.ps1'), (Join-Path $here 'Undo-AsSystem.ps1'), (Join-Path $here 'Set-PowerPlan.ps1'), (Join-Path $here 'Set-StartPins.ps1'), (Join-Path $here 'Set-Hypervisor.ps1'), (Join-Path $here 'Set-Wallpapers.ps1'), (Join-Path $here 'Remove-AppLeftovers.ps1'), (Join-Path $here 'Check-DomainOS.ps1') -Destination $tools -Force
            if (-not (Test-Path -LiteralPath (Join-Path $here 'expected.json'))) { throw 'expected.json is not in the playbook (built without tools/gen-expected.py)' }
            Copy-Item -LiteralPath (Join-Path $here 'expected.json') -Destination $tools -Force
            # What Undo may restore: the registry values, services and tasks of the task files (and of earlier versions).
            $allow = New-DomainOSAllowListLines (Join-Path $here '..\Configuration\Tasks')
            # The task files alone must give the items (the legacy lists add ~70 more, so the total says nothing).
            $fromTasks = @(Get-DomainOSPlaybookItems (Join-Path $here '..\Configuration\Tasks')).Count
            if ($fromTasks -lt 50) { throw "the task files gave only $fromTasks items for the Undo allow-list: they were not read" }
            Set-Content -LiteralPath (Join-Path $tools 'undo-allowlist.txt') -Value $allow -Encoding UTF8
            Copy-Item -Path (Join-Path $here 'Guide') -Destination $app -Recurse -Force
            $guide = Join-Path $app 'Guide\New-DriverGuide.ps1'
            New-Shortcut 'First steps (drivers)' $ps "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guide`"" 'What to install on this PC, step by step'
            New-Shortcut "What's new in Domain OS" (Join-Path $app 'Guide\whats-new.html') '' 'What changed in this version of Domain OS'
            New-Shortcut 'Install runtimes' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Install-Runtimes.ps1')`"" 'Visual C++, DirectX runtime, 7-Zip'
            New-Shortcut 'Give Windows Update back its defaults' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Restore-Updates.ps1')`"" 'Feature updates, drivers and restarts as in stock Windows'
            New-Shortcut 'Check Domain OS' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Check-DomainOS.ps1')`"" 'Checks that the Domain OS changes are in place and that Windows is healthy; changes nothing'
            New-Shortcut 'Undo Domain OS' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Undo-DomainOS.ps1')`"" 'Put Windows back to what it was before the playbook'
            Write-Log "Tools copied to $app ($($allow.Count) items Undo may restore)"
        }
        'Scheduler' {
            $src = Join-Path $here 'DomainScheduler.exe'
            if (-not (Test-Path $src)) { throw 'DomainScheduler.exe is not in the playbook' }
            $exe = Join-Path $app 'DomainScheduler.exe'
            # An earlier version may be running. Stopping is not instant, so wait for the process to end; if the file
            # is still held, move the old one aside (Windows allows renaming a running program) and copy the new one.
            Stop-ScheduledTask -TaskName 'DomainScheduler' -ErrorAction SilentlyContinue
            $running = @(Get-Process -Name 'DomainScheduler' -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0) {
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                $running | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
                Write-Log "A running copy of the app was closed ($($running.Count))"
            }
            Get-ChildItem -Path $app -Filter 'DomainScheduler.exe.old*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            $copied = $false
            for ($try = 1; $try -le 5 -and -not $copied; $try++) {
                try { Copy-Item -Path $src -Destination $exe -Force; $copied = $true }
                catch { Start-Sleep -Seconds 2 }
            }
            if (-not $copied) {
                Rename-Item -Path $exe -NewName ('DomainScheduler.exe.old' + (Get-Date -Format 'HHmmss'))
                Copy-Item -Path $src -Destination $exe -Force
                Write-Log 'The old file was still in use: it was moved aside and is deleted by the next install'
            }
            # The task is registered for the group Users, so the program starts for whoever signs in.
            # A standard (non-administrator) account cannot elevate silently: there the task does nothing and the
            # program is started by hand. The task XML explains the rest.
            $xml = (Get-Content -Raw -Encoding UTF8 (Join-Path $here 'DomainScheduler-Task.xml')).Replace('{EXE}', [Security.SecurityElement]::Escape($exe))
            Register-ScheduledTask -TaskName 'DomainScheduler' -Xml $xml -Force | Out-Null
            $task = Get-ScheduledTask -TaskName 'DomainScheduler'
            if ($task.Actions[0].Execute -ne $exe) { throw 'the autostart task read back differs' }
            $about = 'Domain OS Toolbox: DomainScheduler, system changes, drivers, network, power, graphics card'
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $menu 'Domain OS.lnk')   # name used before 0.6.2
            New-Shortcut 'Domain OS Toolbox' $exe '' $about
            # The same shortcut on the desktop of every account (Public Desktop).
            New-Shortcut 'Domain OS Toolbox' $exe '' $about ([Environment]::GetFolderPath('CommonDesktopDirectory'))
            Write-Log "DomainScheduler installed, autostart task registered and read back ($exe)"
        }
        'Guide' {
            $guide = Join-Path $app 'Guide\New-DriverGuide.ps1'
            if (-not (Test-Path $guide)) { throw 'the guide was not copied' }
            # Entries of earlier versions (RunOnce) go: they did not reliably reach the account that signs in.
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSGuide' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSGuide' -ErrorAction SilentlyContinue
            # The guide page is built by a script (it reads this PC's hardware), so the task runs that script once.
            $ps1 = $guide.Replace("'", "''")
            $cmd = "`$d = Join-Path `$env:LOCALAPPDATA 'Domain OS'; `$m = Join-Path `$d 'shown-guide'; if (-not (Test-Path -LiteralPath `$m)) { New-Item -ItemType Directory -Force -Path `$d | Out-Null; Set-Content -LiteralPath `$m -Value (Get-Date -Format o); & '$ps1' }"
            # Through conhost --headless: no console window at all (-WindowStyle Hidden alone still flashes one at sign-in).
            $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ("--headless `"$ps`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"" + $cmd + "`"")
            $trigger = New-ScheduledTaskTrigger -AtLogOn; $trigger.Delay = 'PT25S'; $trigger.EndBoundary = (Get-Date).AddDays(14).ToString('s')
            $principal = New-ScheduledTaskPrincipal -GroupId ((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([Security.Principal.NTAccount]).Value) -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter (New-TimeSpan -Days 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName 'Open the driver guide' -TaskPath '\Domain OS\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Write-Log 'The driver guide opens once at the next sign-in (scheduled task \Domain OS\Open the driver guide)'
        }
        'WhatsNew' {
            $page = Join-Path $app 'Guide\whats-new.html'
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSWhatsNew' -ErrorAction SilentlyContinue
            $version = ''
            $conf = Join-Path $here '..\playbook.conf'
            if ((Test-Path -LiteralPath $conf) -and ((Get-Content -Raw -Encoding UTF8 $conf) -match '<Version>([^<]+)</Version>')) { $version = $Matches[1] }
            # Once per account and per version: an update shows the page again, a second sign-in does not.
            Register-DomainOSOpenAtLogon "Open What's new" $page ("whatsnew-" + $(if ($version) { $version } else { 'x' }))
            Write-Log "The page What's new opens once at the next sign-in (scheduled task \Domain OS\Open What's new)"
        }
    }
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
