<#
  DomainOS-Report.ps1: one command for a tester's report (Domain OS).
  Runs DomainSchedTest in the game (3 runs of 30 s by default), adds the Toolbox log, the last Check Domain OS report and
  the PC's basics (CPU, GPU, Windows build, Domain OS and Toolbox versions), and packs everything into ONE zip on the
  desktop. Only reads: nothing in Windows is changed.

  PowerShell as administrator, DomainSchedTest.exe next to this script (or in Downloads), the game running:
    powershell -ExecutionPolicy Bypass -File .\DomainOS-Report.ps1
    powershell -ExecutionPolicy Bypass -File .\DomainOS-Report.ps1 -Game cs2 -Runs 3 -Seconds 30 -Label "test6 dm"
  Then send the zip in Discord (help or results channel) or attach it to a GitHub issue "Test report".
#>
param([string]$Game = "cs2", [int]$Runs = 3, [int]$Seconds = 30, [string]$Label = "report")

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$st = @((Join-Path $here "DomainSchedTest.exe"), (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads\DomainSchedTest.exe")) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $st) { Write-Host "DomainSchedTest.exe not found next to the script or in Downloads (get it in Discord, 07 schedtest)."; Write-Host "DomainSchedTest.exe не найден рядом со скриптом или в Загрузках (он есть в Discord, канал 07 schedtest)."; exit 1 }
if (-not (Get-Process $Game -ErrorAction SilentlyContinue)) { Write-Host "Start the game first / Сначала запустите игру: $Game"; exit 1 }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$work = Join-Path $env:TEMP "DomainOS-Report-$stamp"
New-Item -ItemType Directory -Force $work | Out-Null

# 1. PC basics
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$gpu = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Basic|Remote" } | Select-Object -ExpandProperty Name) -join "; "
$os = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$hist = "$env:ProgramData\Domain OS\history.log"
$dos = if (Test-Path $hist) { (Get-Content $hist -Tail 1) } else { "not installed" }
$tb = Get-Process DomainScheduler -ErrorAction SilentlyContinue | Select-Object -First 1
$tbv = if ($tb) { (Get-Item $tb.Path).VersionInfo.ProductVersion } else { "not running" }
@(
  "Report: $stamp  label: $Label",
  "CPU: $cpu", "GPU: $gpu",
  "Windows: $($os.ProductName) $($os.DisplayVersion) build $($os.CurrentBuild).$($os.UBR)",
  "Domain OS: $dos", "Toolbox: $tbv",
  "Game: $Game, $Runs runs of $Seconds s"
) | Out-File (Join-Path $work "pc.txt") -Encoding utf8

# 2. Measurement
Write-Host "Measuring: $Runs x $Seconds s. Switch to the game within 10 s and play as usual."
Write-Host "Замер: $Runs x $Seconds с. Переключитесь в игру за 10 с и играйте как обычно."
Start-Sleep 10
& $st --mode game --process $Game --seconds $Seconds --runs $Runs --label $Label --yes --no-open --out $work | Out-Null

# 3. Logs (copies; the originals stay)
foreach ($f in @("$env:ProgramData\Domain OS Toolbox\log.txt", "$env:LOCALAPPDATA\DomainScheduler\log.txt", "$env:ProgramData\Domain OS\Logs\install.log")) {
  if (Test-Path $f) { Copy-Item $f (Join-Path $work ((Split-Path (Split-Path $f -Parent) -Leaf) + "-" + (Split-Path $f -Leaf))) -ErrorAction SilentlyContinue }
}
$check = Get-ChildItem ([Environment]::GetFolderPath("Desktop")) -Filter "Domain OS check*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($check) { Copy-Item $check.FullName $work }

# 4. One zip on the desktop
$zip = Join-Path ([Environment]::GetFolderPath("Desktop")) "DomainOS-Report-$stamp.zip"
Compress-Archive -Path (Join-Path $work "*") -DestinationPath $zip -Force
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
[console]::beep(880, 300)
Write-Host "Done: $zip"
Write-Host "Готово: $zip  Пришлите этот файл в Discord (канал help или results) или приложите к issue Test report на GitHub."
