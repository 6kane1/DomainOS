<#
  Domain OS — clears the taskbar: every pinned program is unpinned, so only the Start button (and the programs
  that are running) stay. Search, Task view and Chat buttons are hidden by registry values in interface.yml.
  Runs as the signed-in user (elevated). Only the first run changes anything: it keeps a copy of the original pins
  for "Undo Domain OS". When a newer version of the playbook is applied over an older one, the programs the user
  has pinned since then stay pinned. After "Undo Domain OS" the next install clears the taskbar again.
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'Stop'
$data = Join-Path $env:ProgramData 'Domain OS'
$backup = Join-Path $data "Undo\Taskbar\$env:USERNAME"
$key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
$pins = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Taskbar] {1}' -f (Get-Date), $text) -Encoding UTF8; Write-Host $text }

try {
    # An earlier version already cleared this taskbar: this is an upgrade, the user's current pins stay.
    if (Test-Path (Join-Path $backup 'saved.txt')) {
        Write-Log 'Taskbar was cleared by an earlier version: the current pins are kept'
        exit 0
    }
    # The original pins are saved once, before the first clearing.
    New-Item -ItemType Directory -Force -Path (Join-Path $backup 'pins') | Out-Null
    & cmd.exe /c "reg.exe export `"$key`" `"$(Join-Path $backup 'Taskband.reg')`" /y >nul 2>&1"
    if (Test-Path $pins) { Copy-Item -Path (Join-Path $pins '*') -Destination (Join-Path $backup 'pins') -Force -ErrorAction SilentlyContinue }
    Set-Content -Path (Join-Path $backup 'saved.txt') -Value (Get-Date -Format s) -Encoding UTF8
    Write-Log "Original taskbar pins saved to $backup"
    # The pin list lives in the Taskband key and in the shortcut folder.
    & cmd.exe /c "reg.exe delete `"$key`" /f >nul 2>&1"
    if (Test-Path $pins) { Get-ChildItem -Path $pins -Filter '*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    # Explorer keeps the list in memory: it is ended without saving and Windows starts it again by itself
    # (as the user, not elevated). If it has not come back after 10 seconds it is started here.
    & taskkill.exe /f /im explorer.exe 2>&1 | Out-Null
    for ($i = 0; $i -lt 20 -and -not (Get-Process -Name explorer -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') }
    Write-Log 'Taskbar pins removed'
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') }
    exit 1
}
