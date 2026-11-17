<#
  Domain OS — puts back items that earlier versions (1.5.0–1.6.0) changed and this version no longer touches.

  The values come from %ProgramData%\Domain OS\Undo\state.json, written before the very first install: every
  service gets the start-up type it had, every task its enabled state, every registry value its data (or is
  removed if it did not exist). An item that is not in state.json was never changed on this PC and is skipped,
  so on a fresh install this script does nothing.

  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
$data = Join-Path $env:ProgramData 'Domain OS'
$file = Join-Path $data 'Undo\state.json'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Defaults] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }
function PsPath([string]$p) { $p -replace '^HKLM\\', 'Registry::HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'Registry::HKEY_CURRENT_USER\' }

$services = @(
    # diagnostics
    'DPS', 'WdiSystemHost', 'WdiServiceHost', 'TroubleshootingSvc', 'diagsvc', 'diagnosticshub.standardcollector.service',
    'wercplsupport', 'pla', 'Wecsvc',
    # sync, cloud, background
    'OneSyncSvc', 'CloudIdSvc', 'CloudBackupRestoreSvc', 'CldFlt', 'fhsvc', 'DusmSvc', 'DSSvc', 'ShellHWDetection', 'svsvc', 'SEMgrSvc',
    # small drivers
    'Ndu', 'bam', 'dam', 'AcpiPmi', 'acpipagr', 'acpitime', 'PRM', 'kdnic', 'intelpmt', 'Beep',
    # basic set
    'MapsBroker', 'RetailDemo', 'Fax', 'WMPNetworkSvc', 'wisvc', 'WpcMonSvc', 'PhoneSvc', 'RemoteRegistry',
    # printing and Bluetooth
    'Spooler', 'PrintNotify', 'PrintWorkflowUserSvc', 'stisvc', 'usbprint', 'McpManagementService', 'PrintScanBrokerService',
    'PrintDeviceConfigurationService', 'bthserv', 'BTAGService', 'BthAvctpSvc'
)
$tasks = @(
    '\Microsoft\Windows\Flighting\OneSettings\RefreshCache',
    '\Microsoft\Windows\Sustainability\PowerGridForecastTask',
    '\Microsoft\Windows\ConsentUX\UnifiedConsent\UnifiedConsentSyncTask',
    '\Microsoft\Windows\DeviceDirectoryClient\IntegrityCheck',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceAccountChange',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDevicePolicyChange',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceProtectionStateChanged',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceSettingChange',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterUserDevice',
    '\Microsoft\Windows\Diagnosis\UnexpectedCodepath',
    '\Microsoft\Windows\Hotpatch\Monitoring',
    '\Microsoft\Windows\Work Folders\Work Folders Logon Synchronization',
    '\Microsoft\Windows\Work Folders\Work Folders Maintenance Work',
    '\Microsoft\Windows\NetTrace\GatherNetworkInfo'
)
$values = @(
    @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'NoAutoRebootWithLoggedOnUsers'),
    @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'AUPowerManagement'),
    # Game Mode (switched off by 1.5.x)
    @('HKCU\Software\Microsoft\GameBar', 'AutoGameModeEnabled'),
    @('HKCU\Software\Microsoft\GameBar', 'AllowAutoGameMode')
)

if (-not (Test-Path $file)) { Write-Log 'No saved state: nothing was changed by an earlier version'; exit 0 }
$state = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
$done = 0

foreach ($s in $state.services | Where-Object { $services -contains $_.name }) {
    $key = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($s.name)"
    $now = (Get-ItemProperty -LiteralPath $key).Start
    if ($null -eq $now -or [int]$now -eq [int]$s.start) { continue }
    Set-ItemProperty -LiteralPath $key -Name 'Start' -Value ([int]$s.start) -Type DWord
    if ((Get-ItemProperty -LiteralPath $key).Start -eq [int]$s.start) { $done++; Write-Log "service $($s.name): start type $now -> $($s.start)" }
    else { Write-Log "FAILED service $($s.name)" }
}

foreach ($t in $state.tasks | Where-Object { $tasks -contains $_.path }) {
    $i = $t.path.LastIndexOf('\')
    $task = Get-ScheduledTask -TaskPath ($t.path.Substring(0, $i + 1)) -TaskName ($t.path.Substring($i + 1))
    if (-not $task -or (($task.State -ne 'Disabled') -eq [bool]$t.enabled)) { continue }
    if ($t.enabled) { $task | Enable-ScheduledTask | Out-Null } else { $task | Disable-ScheduledTask | Out-Null }
    $done++; Write-Log "task $($t.path): $(if ($t.enabled) { 'enabled' } else { 'disabled' })"
}

foreach ($v in $values) {
    $r = $state.registry | Where-Object { $_.path -eq $v[0] -and $_.name -eq $v[1] } | Select-Object -First 1
    if (-not $r) { continue }
    $path = PsPath $r.path
    if ($r.exists) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -LiteralPath $path -Name $r.name -Value $r.data -PropertyType $r.kind -Force | Out-Null
        $done++; Write-Log "registry $($r.path)\$($r.name) = $($r.data)"
    } elseif ((Get-Item -LiteralPath $path).GetValueNames() -contains $r.name) {
        Remove-ItemProperty -LiteralPath $path -Name $r.name -Force
        $done++; Write-Log "registry $($r.path)\$($r.name) removed (it did not exist)"
    }
}

Write-Log "Items no longer changed by Domain OS put back as they were: $done"
exit 0
