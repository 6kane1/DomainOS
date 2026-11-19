<#
  Domain OS — removes OneDrive for the signed-in user with OneDrive's own uninstaller and stops Windows from
  installing it for new accounts. Files in the OneDrive folder are not deleted.
  Exit code: 0 = done, or OneDrive is not on this PC; 1 = the uninstaller is there but could not be started (the install
  stops, main.yml handleExitCodes). The uninstaller's own exit code is only logged: OneDrive does not document it.
  The default profile's entry is removed when its registry file can be opened; when it is in use (loaded by another
  program) that is logged and the step still counts as done, as OneDrive itself is removed.
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $env:ProgramData 'Domain OS\Logs\install.log'
function Write-Log([string]$text) { try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [OneDrive] {1}' -f (Get-Date), $text) -Encoding UTF8 -ErrorAction Stop } catch { }; Write-Host $text }
Get-Process -Name 'OneDrive' | Stop-Process -Force
Start-Sleep -Seconds 1
$found = $false
foreach ($setup in (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')) {
    if (Test-Path $setup) {
        $found = $true
        try { $p = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru -ErrorAction Stop }
        catch { Write-Log "FAILED: the OneDrive uninstaller could not be started: $($_.Exception.Message)"; exit 1 }
        Write-Log "OneDrive uninstaller finished (exit code $($p.ExitCode))"
        break
    }
}
if (-not $found) { Write-Log 'OneDrive setup is not on this PC: nothing to uninstall' }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive'
# New accounts get OneDrive from a "run once at first sign-in" entry in the default profile: removed.
$hive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (Test-Path $hive) {
    & reg.exe load 'HKU\DomainOS_Default' $hive 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & cmd.exe /c 'reg.exe delete "HKU\DomainOS_Default\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f >nul 2>&1'   # absent when OneDrive is already gone: not an error
        [gc]::Collect()
        & reg.exe unload 'HKU\DomainOS_Default' 2>&1 | Out-Null
    } else { Write-Log "The default profile could not be opened (reg load exit code $LASTEXITCODE, it may be in use): new accounts may still get OneDrive" }
}
exit 0
