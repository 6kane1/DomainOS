<#
  Domain OS — runs first, before anything is changed: the playbook installs only on Windows 11 Pro.

  Allowed editions (EditionID): Professional, ProfessionalN, ProfessionalWorkstation, ProfessionalWorkstationN.
  Any other edition (Home, Education, Enterprise, ...) → exit code 2, and the playbook stops ("handleExitCodes: Halt"),
  so nothing on the PC has been changed yet.
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
$data = Join-Path $env:ProgramData 'Domain OS'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
$allowed = 'Professional', 'ProfessionalN', 'ProfessionalWorkstation', 'ProfessionalWorkstationN'
if ($allowed -contains $edition) {
    Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Edition] {1}: OK' -f (Get-Date), $edition) -Encoding UTF8
    exit 0
}
Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Edition] {1}: Domain OS installs only on Windows 11 Pro. Nothing was changed.' -f (Get-Date), $edition) -Encoding UTF8
Write-Host "Domain OS installs only on Windows 11 Pro (this PC: $edition). Nothing was changed."
exit 2
