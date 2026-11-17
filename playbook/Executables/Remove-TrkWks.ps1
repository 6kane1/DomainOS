<#
  Domain OS — removes the Distributed Link Tracking Client service (TrkWks) from Windows.

  What the service does: keeps shortcuts and OLE links working when the file they point to is moved between
  NTFS volumes of different computers in a network. A gaming PC does not use this.

  What is done: before anything changes, the whole service registration (HKLM\SYSTEM\CurrentControlSet\Services\TrkWks)
  is exported to %ProgramData%\Domain OS\Undo\TrkWks.reg (only the first time, so the original is kept). Then the
  service is stopped and deleted with "sc delete". Its program file (trkwks.dll) stays in Windows, so
  "Undo Domain OS" can register the service again from the saved copy (it works after a restart).
  A later Windows feature update may register the service again; running the playbook again removes it again.

  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
$data = Join-Path $env:ProgramData 'Domain OS'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs'), (Join-Path $data 'Undo') | Out-Null
$log = Join-Path $data 'Logs\install.log'
$backup = Join-Path $data 'Undo\TrkWks.reg'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [TrkWks] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\TrkWks')) { Write-Log 'Not present: nothing to do'; exit 0 }

if (-not (Test-Path $backup)) {
    & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\TrkWks' $backup /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $backup)) { Write-Log 'Backup failed: the service is left as it is'; exit 0 }
    Write-Log "Backup saved: $backup"
}

Stop-Service -Name 'TrkWks' -Force -ErrorAction SilentlyContinue
& sc.exe delete TrkWks | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Log 'Service deleted (gone completely after the restart)' }
else { Write-Log "sc delete returned ${LASTEXITCODE}: the service is left as it is" }
exit 0
