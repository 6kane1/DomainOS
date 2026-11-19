<#
  Domain OS — the Distributed Link Tracking Client service (TrkWks) is left as Windows has it: Automatic (2).

  Since 2.1.1 the playbook no longer switches this service off. Versions 1.6.7–2.1.0 deleted it after saving its
  registration to %ProgramData%\Domain OS\Undo\TrkWks.reg: on such PCs the saved registration (the PC's own original)
  is written back first. The file is used only when Domain OS wrote it (owner SYSTEM / Administrators /
  TrustedInstaller), and it is read value by value: only the TrkWks key, and only Windows' own svchost.exe /
  trkwks.dll as its program (DomainOS-Common.ps1, Import-DomainOSRegFile). Then the service is set to Automatic
  and started.
  A registration written back from the copy is known to Windows' service manager only after the next start, so then
  the start type is written to the registry directly (sc.exe would answer "service does not exist") and the service
  starts after the restart.
  Exit code: 0 = done or nothing to do (not present and no saved copy); 1 = the saved copy was refused or the start
  type could not be set (the install stops, main.yml handleExitCodes).

  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'DomainOS-Common.ps1')
$data = $DomainOSData
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
$backup = Join-Path $data 'Undo\TrkWks.reg'
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\TrkWks'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [TrkWks] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

$imported = $false
if (-not (Test-Path $key)) {
    if (Test-Path $backup) {
        try {
            $n = Import-DomainOSRegFile $backup $DomainOSTrkWksKey $DomainOSTrkWksCheck
            $imported = $true
            Write-Log "Registration put back from the saved copy, $n values (an earlier version had deleted the service)"
        } catch {
            Write-Log "FAILED: the saved registration $backup was not used ($($_.Exception.Message)): the service stays absent. If that file is not from Domain OS, delete it and apply the playbook again."
            exit 1
        }
    } else { Write-Log 'Not present and no saved copy: nothing to do'; exit 0 }
}
if (-not $imported) {
    & sc.exe config TrkWks start= auto | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "sc config returned ${LASTEXITCODE}: the start type is written to the registry instead" }
}
if ([int](Get-ItemProperty -Path $key).Start -ne 2) { Set-ItemProperty -Path $key -Name 'Start' -Value 2 -Type DWord }
$now = (Get-ItemProperty -Path $key).Start
if ([int]$now -ne 2) { Write-Log "FAILED: the start type is $now, not Automatic (2)"; exit 1 }
Write-Log 'Service set to Automatic (Windows default)'
if (-not $imported) { Start-Service -Name 'TrkWks' -ErrorAction SilentlyContinue }   # not started yet: after the restart at the latest
exit 0
