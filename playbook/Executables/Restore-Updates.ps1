<#
  Domain OS — gives Windows Update back its stock behaviour: feature updates, drivers from Windows Update and
  automatic restarts. Run as administrator. Security updates were never switched off.
#>
$ErrorActionPreference = 'SilentlyContinue'
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    exit 0
}
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
'TargetReleaseVersion', 'ProductVersion', 'TargetReleaseVersionInfo', 'ExcludeWUDriversInQualityUpdate' | ForEach-Object { Remove-ItemProperty -Path $wu -Name $_ }
'NoAutoRebootWithLoggedOnUsers', 'AUPowerManagement' | ForEach-Object { Remove-ItemProperty -Path "$wu\AU" -Name $_ }
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name 'SearchOrderConfig' -Value 1 -Type DWord
Write-Host 'Windows Update is back to its defaults. Open Settings > Windows Update and press "Check for updates".'
Start-Sleep -Seconds 6
exit 0
