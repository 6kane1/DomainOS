<#
  Domain OS — measurement kit for a before/after comparison (stock Windows vs Domain OS, or vs another build).

  It records the same things the same way every time, so two runs can be compared:
    1. A snapshot of the system at rest: processes, threads, handles, running services, memory in use.
    2. An ETW trace with the built-in Windows Performance Recorder (wpr.exe) for Windows Performance Analyzer:
         -Scenario Idle   the desktop left alone            (background CPU, DPC/ISR, disk)
         -Scenario Game   while you play                    (start it, switch to the game, play the same scene)
         -Scenario Boot   the next start-up of Windows      (restarts the PC)
    3. If the Windows Performance Toolkit is installed (xperf.exe), text summaries next to the trace:
       DPC/ISR by module and CPU time by process.

  Run as administrator. Example:
      .\Measure-DomainOS.ps1 -Label stock -Scenario Idle -Seconds 120
      .\Measure-DomainOS.ps1 -Label domainos -Scenario Idle -Seconds 120
  Results: .\results\<label>-<scenario>-<time>\
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [ValidateSet('Idle', 'Game', 'Boot')][string]$Scenario = 'Idle',
    [ValidateRange(20, 900)][int]$Seconds = 120,
    [int]$SettleSeconds = 180
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script as administrator.' }
if ($Label -notmatch '^[A-Za-z0-9_-]+$') { throw 'Label: letters, digits, - and _ only.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $PSScriptRoot "results\$Label-$Scenario-$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$etl = Join-Path $out 'trace.etl'

function Get-Snapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $procs = Get-Process
    [ordered]@{
        label           = $Label
        scenario        = $Scenario
        time            = (Get-Date).ToString('o')
        windowsBuild    = "$($os.Version) ($((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion), UBR $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR))"
        uptimeMinutes   = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
        processes       = $procs.Count
        threads         = ($procs | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
        handles         = ($procs | Measure-Object HandleCount -Sum).Sum
        servicesRunning = (Get-Service | Where-Object Status -eq 'Running').Count
        servicesTotal   = (Get-Service).Count
        memoryUsedMB    = [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024)
        memoryTotalMB   = [int]($os.TotalVisibleMemorySize / 1024)
        commitMB        = [int](($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1024)
        scheduledTasksReady = (Get-ScheduledTask | Where-Object State -eq 'Ready').Count
        startupEntries  = (Get-CimInstance Win32_StartupCommand).Count
    }
}

function Find-Xperf {
    $cmd = Get-Command xperf.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($root in ${env:ProgramFiles(x86)}, $env:ProgramFiles) {
        $p = Join-Path $root 'Windows Kits\10\Windows Performance Toolkit\xperf.exe'
        if (Test-Path $p) { return $p }
    }
    return $null
}

if ($Scenario -eq 'Boot') {
    # The trace of the next start-up. After the restart, sign in and wait: WPR stops by itself and writes the file.
    Get-Snapshot | ConvertTo-Json | Set-Content (Join-Path $out 'snapshot-before-restart.json') -Encoding UTF8
    & wpr.exe -cancel 2>$null | Out-Null
    & wpr.exe -start GeneralProfile -onoffscenario Boot -onoffresultspath $out -numiterations 1
    if ($LASTEXITCODE -ne 0) { throw "wpr could not arm the boot trace (code $LASTEXITCODE)" }
    Write-Host "Boot trace armed. The PC restarts in 15 seconds. After signing in, wait until the WPR window closes; the trace will be in:`n  $out"
    Start-Sleep -Seconds 15
    Restart-Computer -Force
    exit 0
}

# A fair idle measurement needs a settled system: no start-up work still running.
$uptime = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
if ($Scenario -eq 'Idle' -and $uptime -lt 600) {
    Write-Warning ("Windows started {0:0} minutes ago. For comparable numbers measure at least 10 minutes after start-up." -f ($uptime / 60))
}
if ($Scenario -eq 'Idle') {
    Write-Host "Idle: close every window, do not touch the mouse. Settling for $SettleSeconds s…"
    Start-Sleep -Seconds $SettleSeconds
} else {
    Write-Host "Game: recording starts in 20 s. Switch to the game now and play the SAME scene as in the other run."
    Start-Sleep -Seconds 20
}

Get-Snapshot | ConvertTo-Json | Set-Content (Join-Path $out 'snapshot.json') -Encoding UTF8

& wpr.exe -cancel 2>$null | Out-Null
# GeneralProfile: CPU sampling, context switches, DPC/ISR, disk and file I/O. Light verbosity keeps the recorder's own cost low.
& wpr.exe -start GeneralProfile.light -start CPU.light -filemode
if ($LASTEXITCODE -ne 0) { throw "wpr did not start (code $LASTEXITCODE). Another trace may be running: wpr -cancel" }
Write-Host "Recording $Seconds s…"
Start-Sleep -Seconds $Seconds
& wpr.exe -stop $etl "Domain OS measurement: $Label $Scenario"
if ($LASTEXITCODE -ne 0) { throw "wpr did not stop cleanly (code $LASTEXITCODE)" }

$xperf = Find-Xperf
if ($xperf) {
    # Text summaries, so two runs can be compared without opening the analyzer.
    & $xperf -i $etl -o (Join-Path $out 'dpcisr.txt') -a dpcisr 2>$null
    & $xperf -i $etl -o (Join-Path $out 'cpu-by-process.txt') -a profile -detail 2>$null
    Write-Host 'xperf summaries written: dpcisr.txt, cpu-by-process.txt'
} else {
    Write-Host 'xperf.exe (Windows Performance Toolkit) is not installed: only the trace was written. Install the toolkit from the Windows ADK to get text summaries and the analyzer.'
}

Write-Host "`nDone:`n  $out`nOpen trace.etl in Windows Performance Analyzer; README.md in this folder says what to compare."
