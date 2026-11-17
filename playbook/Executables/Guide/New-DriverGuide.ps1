<#
  Domain OS — builds the "First steps" page for THIS computer and opens it.
  It reads what Windows knows about the hardware (nothing is changed, nothing is sent anywhere),
  writes the facts into guide.html and shows the page in the default browser.
#>
[CmdletBinding()]
param([switch]$NoOpen)

$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $env:ProgramData 'Domain OS\Guide'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Vendor([string]$text, [hashtable]$map) {
    foreach ($k in $map.Keys) { if ($text -match $k) { return $map[$k] } }
    return ''
}

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
$system = Get-CimInstance Win32_ComputerSystem | Select-Object -First 1
# Laptops and branded PCs: the maker of the computer knows the drivers, not the maker of the board inside.
$maker = if ($system.Manufacturer -and $system.Manufacturer -notmatch 'System manufacturer|To be filled|Default string|^$') { "$($system.Manufacturer) $($system.Model)" } else { "$($board.Manufacturer) $($board.Product)" }
$boardVendor = Vendor "$($system.Manufacturer) $($board.Manufacturer)" ([ordered]@{
    'ASUS' = 'asus'; 'Micro-Star|MSI' = 'msi'; 'Gigabyte|GIGA-BYTE' = 'gigabyte'; 'ASRock' = 'asrock'; 'BIOSTAR' = 'biostar'; 'LENOVO' = 'lenovo';
    'HP|Hewlett' = 'hp'; 'Dell|Alienware' = 'dell'; 'Acer|Gateway' = 'acer'; 'HUAWEI|HONOR' = 'huawei'; 'SAMSUNG' = 'samsung'; 'Razer' = 'razer'; 'Microsoft' = 'microsoft' })

$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -and $_.Name -notmatch 'Remote|Virtual|Parsec|Citrix|Meta' } | ForEach-Object {
    $basic = $_.Name -match 'Basic Display|Basic Render'
    # A basic adapter does not say whose card it is: the hardware ID does (VEN_10DE NVIDIA, VEN_1002 AMD, VEN_8086 Intel).
    $vendor = Vendor "$($_.Name) $($_.AdapterCompatibility) $($_.PNPDeviceID)" ([ordered]@{ 'NVIDIA|VEN_10DE' = 'nvidia'; 'AMD|Radeon|ATI|VEN_1002' = 'amd'; 'Intel|VEN_8086' = 'intel' })
    [ordered]@{ name = $_.Name; vendor = $vendor; version = $_.DriverVersion; date = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' }; basic = [bool]$basic }
})

$refresh = (Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentRefreshRate -gt 0 } | Measure-Object CurrentRefreshRate -Maximum).Maximum
$ram = @(Get-CimInstance Win32_PhysicalMemory)
$ramRated = ($ram | Measure-Object Speed -Maximum).Maximum
$ramNow = ($ram | Measure-Object ConfiguredClockSpeed -Minimum).Minimum

$net = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -and $_.Name -notmatch 'Virtual|VPN|TAP|Hyper-V|Bluetooth' } | ForEach-Object { $_.Name })
$audio = @(Get-CimInstance Win32_SoundDevice | Where-Object { $_.Name -notmatch 'Virtual|Steam|NVIDIA Broadcast' } | ForEach-Object { $_.Name })
$problems = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 } | ForEach-Object { if ($_.Name) { $_.Name } else { $_.DeviceID } })

$online = $false
try { $online = [bool](Test-Connection -ComputerName 'www.microsoft.com' -Count 1 -Quiet) } catch { }

$data = [ordered]@{
    lang        = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'ru') { 'ru' } else { 'en' }
    cpu         = "$($cpu.Name)".Trim()
    cpuVendor   = if ($cpu.Manufacturer -match 'AMD') { 'amd' } elseif ($cpu.Manufacturer -match 'Intel') { 'intel' } else { '' }
    board       = $maker.Trim()
    boardVendor = $boardVendor
    gpus        = $gpus
    audio       = $audio
    net         = $net
    problems    = $problems
    refresh     = [int]$refresh
    ramRated    = [int]$ramRated
    ramNow      = [int]$ramNow
    online      = $online
    scheduler   = Test-Path (Join-Path $env:ProgramFiles 'Domain OS\DomainScheduler.exe')
}

$json = ($data | ConvertTo-Json -Depth 5 -Compress) -replace '</', '<\/'
$html = Get-Content -Raw -Encoding UTF8 (Join-Path $here 'guide.html')
$start = $html.IndexOf('/*DATA*/')
$end = $html.IndexOf('/*END*/')
if ($start -lt 0 -or $end -lt $start) { Write-Error 'guide.html has no data block'; exit 1 }
$html = $html.Substring(0, $start) + '/*DATA*/' + $json + $html.Substring($end)
$out = Join-Path $outDir 'guide.html'
[IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding($false)))
if (-not $NoOpen) { Start-Process $out }
exit 0
