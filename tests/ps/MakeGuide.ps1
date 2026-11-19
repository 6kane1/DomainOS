<#
  For tests/run-all.py (area F): runs Guide\New-DriverGuide.ps1 with fake hardware (Get-CimInstance, Test-Connection,
  Get-UICulture replaced) and prints the path of the guide.html it wrote. Profiles: amd-nvidia, intel-amd-ru, basic.
      pwsh -NoProfile -File MakeGuide.ps1 <Guide dir> <profile> <output dir>
#>
param([string]$Guide, [string]$Profile, [string]$OutDir)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $OutDir
$env:ProgramFiles = Join-Path $OutDir 'pf'
$p = @{
    'amd-nvidia'   = @{ cpu = @{ Name = 'AMD Ryzen 7 7800X3D 8-Core Processor   '; Manufacturer = 'AuthenticAMD' }; sys = @{ Manufacturer = 'System manufacturer'; Model = 'System Product Name' }; board = @{ Manufacturer = 'ASUSTeK COMPUTER INC.'; Product = 'ROG STRIX B650-A' }
                       gpu = @(@{ Name = 'NVIDIA GeForce RTX 5060'; AdapterCompatibility = 'NVIDIA'; PNPDeviceID = 'PCI\VEN_10DE&DEV_2D05'; DriverVersion = '32.0.15.8180'; DriverDate = [datetime]'2026-10-01'; CurrentRefreshRate = 240 }); lang = 'en'
                       net = @('Realtek Gaming 2.5GbE'); audio = @('Realtek USB Audio'); problems = @(); online = $true; ram = @(@{ Speed = 6000; ConfiguredClockSpeed = 4800 }) }
    'intel-amd-ru' = @{ cpu = @{ Name = 'Intel(R) Core(TM) i5-13600KF'; Manufacturer = 'GenuineIntel' }; sys = @{ Manufacturer = 'Micro-Star International Co., Ltd.'; Model = 'MS-7D25' }; board = @{ Manufacturer = 'Micro-Star International Co., Ltd.'; Product = 'PRO Z690-A' }
                       gpu = @(@{ Name = 'AMD Radeon RX 7800 XT'; AdapterCompatibility = 'Advanced Micro Devices, Inc.'; PNPDeviceID = 'PCI\VEN_1002&DEV_747E'; DriverVersion = '32.0.21001.9024'; DriverDate = [datetime]'2026-09-01'; CurrentRefreshRate = 60 }); lang = 'ru'
                       net = @(); audio = @(); problems = @('PCI Device', 'SM Bus Controller', '<script>alert(1)</script>'); online = $false; ram = @(@{ Speed = 3200; ConfiguredClockSpeed = 3200 }) }
    'basic'        = @{ cpu = @{ Name = 'Some CPU'; Manufacturer = 'Other' }; sys = @{ Manufacturer = 'To be filled by O.E.M.'; Model = 'x' }; board = @{ Manufacturer = 'Unknown Board Maker'; Product = 'B1' }
                       gpu = @(@{ Name = 'Microsoft Basic Display Adapter'; AdapterCompatibility = '(Standard display types)'; PNPDeviceID = 'PCI\VEN_8086&DEV_A780'; DriverVersion = '10.0.26100.1'; DriverDate = $null; CurrentRefreshRate = 0 }); lang = 'en'
                       net = @('Intel(R) Wi-Fi 6E AX211'); audio = @('High Definition Audio Device'); problems = @(); online = $true; ram = @() }
}[$Profile]
if (-not $p) { throw "unknown profile $Profile" }
$global:P = $p
function global:Get-CimInstance([string]$ClassName) {
    switch ($ClassName) {
        'Win32_Processor' { [pscustomobject]$P.cpu }
        'Win32_BaseBoard' { [pscustomobject]$P.board }
        'Win32_ComputerSystem' { [pscustomobject]$P.sys }
        'Win32_VideoController' { $P.gpu | ForEach-Object { [pscustomobject]$_ } }
        'Win32_PhysicalMemory' { $P.ram | ForEach-Object { [pscustomobject]$_ } }
        'Win32_NetworkAdapter' { $P.net | ForEach-Object { [pscustomobject]@{ Name = $_; PhysicalAdapter = $true } }; [pscustomobject]@{ Name = 'Hyper-V Virtual Ethernet'; PhysicalAdapter = $true } }
        'Win32_SoundDevice' { $P.audio | ForEach-Object { [pscustomobject]@{ Name = $_ } } }
        'Win32_PnPEntity' { $P.problems | ForEach-Object { [pscustomobject]@{ Name = $_; DeviceID = 'X'; ConfigManagerErrorCode = 28 } }; [pscustomobject]@{ Name = 'Disabled on purpose'; ConfigManagerErrorCode = 22 } }
        default { throw "unexpected CIM class $ClassName" }
    }
}
function global:Test-Connection { $P.online }
function global:Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = $P.lang } }
function global:Start-Process { throw 'the guide must not be opened with -NoOpen' }
& (Join-Path $Guide 'New-DriverGuide.ps1') -NoOpen
if ($LASTEXITCODE) { throw "New-DriverGuide.ps1 exit code $LASTEXITCODE" }
Join-Path $OutDir 'Domain OS/Guide/guide.html'
