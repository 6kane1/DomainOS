<#
  Domain OS — the Distributed Link Tracking Client service (TrkWks) is switched off (start type Disabled), not deleted.

  What the service does: keeps shortcuts and OLE links working when the file they point to is moved between
  NTFS volumes of different computers in a network. A gaming PC does not use this.

  Why disabled and not deleted (since 2.1.1): a disabled service costs nothing either, and Windows updates and
  "sfc /scannow" find the service where they expect it. Versions 1.6.7–2.1.0 deleted it after saving its registration
  to %ProgramData%\Domain OS\Undo\TrkWks.reg: on such PCs the saved registration is imported again first (it is the
  PC's own original), then the service is set to Disabled. "Undo Domain OS" puts back the start type it had.

  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
$data = Join-Path $env:ProgramData 'Domain OS'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
$backup = Join-Path $data 'Undo\TrkWks.reg'
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\TrkWks'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [TrkWks] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

if (-not (Test-Path $key)) {
    if (Test-Path $backup) {
        & reg.exe import $backup 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $key)) { Write-Log 'Registration put back from the saved copy (an earlier version had deleted the service)' }
        else { Write-Log 'The saved registration could not be imported: the service stays absent'; exit 0 }
    } else { Write-Log 'Not present and no saved copy: nothing to do'; exit 0 }
}
Stop-Service -Name 'TrkWks' -Force -ErrorAction SilentlyContinue
& sc.exe config TrkWks start= disabled | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Log 'Service set to Disabled' } else { Write-Log "sc config returned ${LASTEXITCODE}" }
exit 0
