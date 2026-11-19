<#
  Domain OS — clears the taskbar: every pinned program is unpinned, so only the Start button (and the programs
  that are running) stay. Search, Task view and Chat buttons are hidden by registry values in interface.yml.
  Runs as the signed-in user (elevated). Only the first run changes anything: it keeps a copy of the original pins
  for "Undo Domain OS". When a newer version of the playbook is applied over an older one, the programs the user
  has pinned since then stay pinned. After "Undo Domain OS" the next install clears the taskbar again.
  Explorer is ended in this session only and Windows starts it again as the user; it is never started from this
  elevated script (DomainOS-Common.ps1, Restart-DomainOSExplorer).
  Exit code: 0 = done (or cleared by an earlier version); 1 = a failure, the install stops (software.yml). The
  original pins must be saved completely (the Taskband export and every pin shortcut), else nothing is removed.
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'DomainOS-Common.ps1')
$data = $DomainOSData
$backup = Get-DomainOSUserDir 'Taskbar'
$key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
$pins = Join-Path (Get-DomainOSUserFolder 'ApplicationData') 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) { try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Taskbar] {1}' -f (Get-Date), $text) -Encoding UTF8 } catch { }; Write-Host $text }

try {
    Protect-DomainOSData
    New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
    # An earlier version already cleared this taskbar: this is an upgrade, the user's current pins stay.
    if (Test-DomainOSFile (Join-Path $backup 'saved.txt')) {
        Write-Log 'Taskbar was cleared by an earlier version: the current pins are kept'
        exit 0
    }
    # The original pins are saved once, before the first clearing.
    New-Item -ItemType Directory -Force -Path (Join-Path $backup 'pins') | Out-Null
    & cmd.exe /c "reg.exe export `"$key`" `"$(Join-Path $backup 'Taskband.reg')`" /y >nul 2>&1"
    # No Taskband key (an account that never pinned anything) is fine; a key that is there and was not exported is not.
    if ((Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband') -and -not (Test-Path -LiteralPath (Join-Path $backup 'Taskband.reg'))) { throw 'the taskbar pin order could not be saved (reg export): nothing was removed' }
    if (Test-Path $pins) { Copy-Item -Path (Join-Path $pins '*') -Destination (Join-Path $backup 'pins') -Force -ErrorAction Stop }
    Set-Content -Path (Join-Path $backup 'saved.txt') -Value (Get-Date -Format s) -Encoding UTF8
    Write-Log "Original taskbar pins saved to $backup"
    # The pin list lives in the Taskband key and in the shortcut folder.
    & cmd.exe /c "reg.exe delete `"$key`" /f >nul 2>&1"
    if (Test-Path $pins) { Get-ChildItem -Path $pins -Filter '*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    # Explorer keeps the list in memory: it is ended without saving (this session only) and Windows starts it again
    # by itself, as the user, not elevated. If it has not come back after 10 seconds a one-time task starts it as the user.
    Restart-DomainOSExplorer
    Write-Log 'Taskbar pins removed'
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    $session = (Get-Process -Id $PID).SessionId
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })) { Restart-DomainOSExplorer }
    exit 1
}
