<#
  Domain OS — the "Domain OS" power plan.

  What it is: a copy of Windows' own Balanced plan with four plugged-in (AC) settings changed and nothing else:
    - USB selective suspend off: USB hubs, mouse, keyboard, headset and USB audio never go to sleep;
    - PCI Express link state power management (ASPM) off: the graphics card, NVMe drive and network card stay
      fully awake on their PCIe link;
    - the display is never turned off (a convenience, not a performance setting: no screen saver timeout in long
      loading screens or while watching; on an OLED monitor set a timeout in Settings > System > Power if you want);
    - the disk is never turned off.
  Processor settings, core parking, boost and every other value stay exactly as in Balanced, which is what AMD and
  Intel tune their processors for. On battery a laptop behaves as with Balanced.

  Usage (asks for administrator rights when needed):
    .\Set-PowerPlan.ps1            create or refresh the plan and make it active
    .\Set-PowerPlan.ps1 -Restore   make the previously active plan active again and delete this one
  Log: %ProgramData%\Domain OS\Logs\power.log
#>
[CmdletBinding()]
param([switch]$Restore)

$ErrorActionPreference = 'Stop'
$Plan = 'beff29ce-3f07-4f91-88d1-8ca5023c6112'          # fixed, so a newer version updates the same plan
$Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$Name = 'Domain OS'
$About = 'Balanced with USB selective suspend and PCIe link power saving off, display and disk never turned off. Plugged-in values only.'

. (Join-Path $PSScriptRoot 'DomainOS-Common.ps1')
if (Start-DomainOSElevated $MyInvocation.MyCommand.Path $PSBoundParameters) { exit 0 }
$data = $DomainOSData
$log = Join-Path $data 'Logs\power.log'
$prevFile = Join-Path $data 'Undo\power-plan-before.txt'
function Write-Log([string]$text) { try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $text) -Encoding UTF8 } catch { }; Write-Host $text }
try { Protect-DomainOSData; New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs'), (Join-Path $data 'Undo') | Out-Null }
catch { Write-Host "FAILED: the Domain OS data folder could not be prepared ($($_.Exception.Message))"; exit 1 }
function Active { if ((& powercfg.exe /getactivescheme) -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $Matches[1] } }
function Exists([string]$guid) { [bool]((& powercfg.exe /list) -match $guid) }

if ($Restore) {
    # The saved plan only when Domain OS wrote the file and it holds a plan GUID; Balanced otherwise.
    $back = $Balanced
    if ((Test-Path $prevFile) -and (Test-DomainOSFile $prevFile)) {
        $saved = ([string](Get-Content $prevFile -Raw)).Trim()
        if ($saved -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { $back = $saved }
        else { Write-Log "power-plan-before.txt holds no plan GUID: Balanced is made active" }
    }
    if (-not (Exists $back)) { $back = $Balanced }
    & powercfg.exe /setactive $back
    if (Exists $Plan) { & powercfg.exe /delete $Plan | Out-Null }
    Remove-Item -Force -ErrorAction SilentlyContinue $prevFile
    Write-Log "Power plan: $back is active again, '$Name' deleted"
    exit 0
}

try {
    # The plan that was active before the first run is remembered once, for -Restore and "Undo Domain OS".
    $now = Active
    if (-not (Test-Path $prevFile) -and $now -and $now -ne $Plan) { Set-Content -Path $prevFile -Value $now -Encoding ASCII }

    # A fresh copy of Balanced every time, so values from an older version never linger.
    if ((Active) -eq $Plan) { & powercfg.exe /setactive $Balanced }
    if (Exists $Plan) { & powercfg.exe /delete $Plan | Out-Null }
    & powercfg.exe /duplicatescheme $Balanced $Plan | Out-Null
    & powercfg.exe /changename $Plan $Name $About

    Write-Log "--- ${Name}: a fresh copy of Balanced"

    $settings = @(
        # USB selective suspend off: hubs and devices on them (mouse, keyboard, headset, USB audio) never sleep.
        @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0, 'USB selective suspend: off'),
        # PCI Express link state power management (ASPM) off: graphics card, NVMe and network card stay in L0.
        @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5', 0, 'PCI Express link state power management: off'),
        # The display is never turned off.
        @('7516b95f-f776-4464-8c53-06167f40cc99', '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e', 0, 'Turn off display: never'),
        # The disk is never turned off.
        @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e', 0, 'Turn off hard disk: never')
    )

    $ok = 0; $skipped = 0
    foreach ($s in $settings) {
        # Through cmd: a setting this PC does not have makes powercfg write to stderr, which must not stop the script.
        & cmd.exe /c "powercfg.exe /setacvalueindex $Plan $($s[0]) $($s[1]) $($s[2]) >nul 2>&1"
        if ($LASTEXITCODE -eq 0) { $ok++; Write-Log "  $($s[3])" }
        else { $skipped++; Write-Log "  skipped (not on this PC): $($s[3])" }
    }
    & powercfg.exe /setactive $Plan
    if ((Active) -ne $Plan) { throw 'the plan was created but could not be made active' }
    Write-Log "'$Name' is active: $ok settings applied, $skipped not present on this PC"
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}
