<#
  Domain OS — the Distributed Link Tracking Client service (TrkWks) is left as Windows has it: Automatic (2).

  Since 2.1.1 the playbook no longer switches this service off. Versions 1.6.7–2.1.0 deleted it after saving its
  registration to %ProgramData%\Domain OS\Undo\TrkWks.reg: on such PCs the saved registration (the PC's own original)
  is imported again first. Then the service is set to Automatic and started.

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
& sc.exe config TrkWks start= auto | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Log 'Service set to Automatic (Windows default)' } else { Write-Log "sc config returned ${LASTEXITCODE}" }
Start-Service -Name 'TrkWks' -ErrorAction SilentlyContinue
exit 0
