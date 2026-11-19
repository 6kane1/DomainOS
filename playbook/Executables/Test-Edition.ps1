<#
  Domain OS — runs first, before anything is changed: the playbook installs only on Windows 11 Pro.

  Allowed editions (EditionID): Professional, ProfessionalN, ProfessionalWorkstation, ProfessionalWorkstationN.
  Any other edition (Home, Education, Enterprise, ...) → exit code 2, and the playbook stops ("handleExitCodes: Halt"),
  so nothing on the PC has been changed yet.
  It is also the first script to create %ProgramData%\Domain OS: the folder gets its protected permissions here
  (DomainOS-Common.ps1, Protect-DomainOSData). If that fails, Save-State.ps1 tries again and stops the install.
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'DomainOS-Common.ps1')
$data = $DomainOSData
try { Protect-DomainOSData } catch { Write-Host "The Domain OS data folder could not be protected yet: $($_.Exception.Message)" }
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
