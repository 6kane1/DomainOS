<#
  Domain OS — removes OneDrive for the signed-in user with OneDrive's own uninstaller and stops Windows from
  installing it for new accounts. Files in the OneDrive folder are not deleted.
#>
$ErrorActionPreference = 'SilentlyContinue'
Get-Process -Name 'OneDrive' | Stop-Process -Force
Start-Sleep -Seconds 1
foreach ($setup in (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')) {
    if (Test-Path $setup) {
        Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait
        break
    }
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive'
# New accounts get OneDrive from a "run once at first sign-in" entry in the default profile: removed.
$hive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (Test-Path $hive) {
    & reg.exe load 'HKU\DomainOS_Default' $hive | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & cmd.exe /c 'reg.exe delete "HKU\DomainOS_Default\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f >nul 2>&1'   # absent when OneDrive is already gone: not an error
        [gc]::Collect()
        & reg.exe unload 'HKU\DomainOS_Default' | Out-Null
    }
}
exit 0
