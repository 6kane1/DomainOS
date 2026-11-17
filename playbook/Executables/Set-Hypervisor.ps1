<#
  Domain OS — stops Windows from trying to start its hypervisor when the processor's virtualization is switched
  off in the BIOS/UEFI (AMD SVM, Intel VT-x).

  Why: with virtualization off in firmware the hypervisor cannot run, yet Windows still tries to load it at every
  start while memory integrity / VBS or Hyper-V features are configured. The attempt fails, is logged as
  Hyper-V-Hypervisor 42 and Kernel-Boot 124/158, and costs part of every boot. Nothing that needs the hypervisor
  can work on such a PC anyway (memory integrity, VBS, WSL 2, Windows Sandbox, Hyper-V).

  What: `bcdedit /set {current} hypervisorlaunchtype off`, only when BOTH are true:
    - Win32_Processor.VirtualizationFirmwareEnabled is False, and
    - Win32_ComputerSystem.HypervisorPresent is False (with a running hypervisor the first value also reads
      False, so this check keeps a working Hyper-V/VBS setup untouched).
  On any other PC nothing changes. The previous value is saved; "Undo Domain OS" (or -Restore) puts it back.
  If virtualization is switched on in the BIOS later, run Undo or `bcdedit /set hypervisorlaunchtype auto`.

  Log: %ProgramData%\Domain OS\Logs\install.log
#>
[CmdletBinding()]
param([switch]$Restore)

$ErrorActionPreference = 'Stop'
$data = Join-Path $env:ProgramData 'Domain OS'
$saved = Join-Path $data 'Undo\hypervisorlaunchtype.txt'
$bcd = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs'), (Join-Path $data 'Undo') | Out-Null
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Hypervisor] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

# The current value of {current}: "Off", "Auto" or "" when it is not set (Windows then treats it as Auto).
function Get-LaunchType {
    $text = & $bcd /enum '{current}' 2>&1 | Out-String
    $m = [regex]::Match($text, '(?im)^hypervisorlaunchtype\s+(\S+)')
    if ($m.Success) { return $m.Groups[1].Value } else { return '' }
}

try {
    if ($Restore) {
        if (-not (Test-Path $saved)) { exit 0 }
        $old = (Get-Content -Path $saved -Raw).Trim()
        if ($old -eq '') { & $bcd /deletevalue '{current}' hypervisorlaunchtype | Out-Null }
        else { & $bcd /set '{current}' hypervisorlaunchtype $old | Out-Null }
        Remove-Item -Force $saved
        Write-Log "hypervisorlaunchtype put back to '$(if ($old) { $old } else { 'not set' })'"
        exit 0
    }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cpu.VirtualizationFirmwareEnabled -or $cs.HypervisorPresent) {
        Write-Log "Virtualization is on in firmware or a hypervisor runs: nothing changed (firmware $($cpu.VirtualizationFirmwareEnabled), hypervisor $($cs.HypervisorPresent))"
        exit 0
    }
    $current = Get-LaunchType
    if ($current -eq 'Off') { Write-Log 'hypervisorlaunchtype is already Off'; exit 0 }
    if (-not (Test-Path $saved)) { Set-Content -Path $saved -Value $current -Encoding ASCII }
    & $bcd /set '{current}' hypervisorlaunchtype off | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit exit code $LASTEXITCODE" }
    Write-Log "Virtualization is off in firmware: hypervisorlaunchtype '$(if ($current) { $current } else { 'not set' })' -> Off"
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
