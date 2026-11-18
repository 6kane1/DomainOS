<#
  Domain OS — copies the tools to the computer.
    -Part Tools      scripts and the driver guide, Start menu folder "Domain OS"
    -Part Scheduler  DomainScheduler.exe + a logon task for every user (highest rights the user has),
                     shortcut "Domain OS Toolbox" in the Start menu and on the desktop
    -Part Guide      the driver guide opens once after the next sign-in
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Tools', 'Scheduler', 'Guide')][string]$Part)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Join-Path $env:ProgramFiles 'Domain OS'
$data = Join-Path $env:ProgramData 'Domain OS'
$menu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Domain OS'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -ItemType Directory -Force -Path $app, $data, (Join-Path $data 'Logs'), $menu | Out-Null
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}' -f (Get-Date), $Part, $text) -Encoding UTF8; Write-Host $text }

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
    switch ($Part) {
        'Tools' {
            $tools = Join-Path $app 'Tools'
            New-Item -ItemType Directory -Force -Path $tools | Out-Null
            Copy-Item -Path (Join-Path $here 'Install-Runtimes.ps1'), (Join-Path $here 'Restore-Updates.ps1'), (Join-Path $here 'Undo-DomainOS.ps1'), (Join-Path $here 'Set-PowerPlan.ps1'), (Join-Path $here 'Set-StartPins.ps1'), (Join-Path $here 'Set-Hypervisor.ps1'), (Join-Path $here 'Set-Wallpapers.ps1'), (Join-Path $here 'Remove-AppLeftovers.ps1') -Destination $tools -Force
            Copy-Item -Path (Join-Path $here 'Guide') -Destination $app -Recurse -Force
            $guide = Join-Path $app 'Guide\New-DriverGuide.ps1'
            New-Shortcut 'First steps (drivers)' $ps "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guide`"" 'What to install on this PC, step by step'
            New-Shortcut 'Install runtimes' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Install-Runtimes.ps1')`"" 'Visual C++, DirectX runtime, 7-Zip'
            New-Shortcut 'Give Windows Update back its defaults' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Restore-Updates.ps1')`"" 'Feature updates, drivers and restarts as in stock Windows'
            New-Shortcut 'Undo Domain OS' $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $tools 'Undo-DomainOS.ps1')`"" 'Put Windows back to what it was before the playbook'
            Write-Log "Tools copied to $app"
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
            # Once, after the next sign-in.
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DomainOSGuide' -Value "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$guide`""
            Write-Log 'The driver guide will open after the next sign-in'
        }
    }
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
