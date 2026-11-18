<#
  Domain OS — removes what is left of the apps the playbook removed, so they disappear from the Start menu.

  Why: the playbook removes apps for all users at once. Windows can still keep a registration of such an app for the
  signed-in account (its files are already gone), or register it again for that account at the next sign-in. Start
  then lists entries without an icon, named "ms-resource:AppName", "ms-resource:Clipchamp/AppName" and so on, or
  marked "New" (Teams, Outlook, Microsoft 365 Copilot).

  What it does, only with the standard Appx cmdlets and only for the apps in the lists below:
    1. removes the app for the signed-in account (this is what clears the "ms-resource" entries);
    2. removes it for every other account, including copies staged for accounts that have not signed in yet;
    3. removes it from the list of apps Windows installs for new accounts;
    4. empties the Start menu's own cache of the app list and restarts Start, so it builds the list again from
       the apps that are really installed (pinned items are kept).
  -UserOnly does steps 1 and 4 only: that is what runs once at the next sign-in (no administrator rights needed then), in
  case Windows registered something again during the first sign-in after the install.

  Nothing else is touched: apps outside the lists, the Store, Xbox services, Game Bar, WebView2 and Windows
  Security stay. Every failure is written to the log and skipped. Log: %ProgramData%\Domain OS\Logs\install.log
#>
[CmdletBinding()]
param([switch]$Max, [switch]$UserOnly)

$ErrorActionPreference = 'Continue'
$data = Join-Path $env:ProgramData 'Domain OS'
$log = Join-Path $data 'Logs\install.log'
function Write-Log([string]$text) {
    try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Apps] {1}' -f (Get-Date), $text) -Encoding UTF8 } catch { }
    Write-Host $text
}

# The same names as Configuration\Tasks\apps.yml (option apps-basic / apps-max).
$basic = @(
    'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
    'Microsoft.MicrosoftSolitaireCollection', 'MSTeams', 'MicrosoftTeams', 'Microsoft.Copilot',
    'Microsoft.OutlookForWindows', 'Microsoft.Windows.DevHome', 'Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp',
    'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Todos',
    'Microsoft.ZuneVideo', 'Microsoft.549981C3F5F10', 'Microsoft.WindowsMaps', 'microsoft.windowscommunicationsapps',
    'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice',
    'MicrosoftWindows.Client.WebExperience', 'Disney.37853FC22B2CE', '7EE7776C.LinkedInforWindows',
    'Microsoft.Windows.AIHub', 'Microsoft.PCManager', 'Microsoft.MicrosoftPCManager', 'Microsoft.M365Companions'
)
$maxList = @(
    'Microsoft.WindowsStore', 'Microsoft.GamingApp', 'Microsoft.Windows.Photos', 'Microsoft.WindowsCamera',
    'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsAlarms', 'Microsoft.MicrosoftStickyNotes'
)
$names = if ($Max) { $maxList } else { $basic }
$removed = 0

foreach ($n in $names) {
    $pattern = "$n*"
    # 1. the signed-in account
    foreach ($p in @(Get-AppxPackage -Name $pattern -ErrorAction SilentlyContinue)) {
        try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $removed++; Write-Log "removed for $env:USERNAME`: $($p.PackageFullName)" }
        catch { Write-Log "could not remove for $env:USERNAME`: $($p.PackageFullName) ($($_.Exception.Message))" }
    }
    if ($UserOnly) { continue }
    # 2. every account, staged copies included
    foreach ($p in @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)) {
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $removed++; Write-Log "removed for all accounts: $($p.PackageFullName)" }
        catch { Write-Log "could not remove for all accounts: $($p.PackageFullName) ($($_.Exception.Message))" }
    }
    # 3. new accounts
    foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pattern })) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -ErrorAction Stop | Out-Null; $removed++; Write-Log "removed for new accounts: $($p.PackageName)" }
        catch { Write-Log "could not remove for new accounts: $($p.PackageName) ($($_.Exception.Message))" }
    }
}

# 4. Start keeps its own cache of the app list (TempState of its package): entries of removed apps stay there even when
#    Windows no longer has them (Get-StartApps does not list them). The cache is emptied while Start is closed;
#    Start builds it again from the installed apps. Pinned items live in LocalState (start2.bin) and are not touched.
$startPkg = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\TempState'
Get-Process -Name 'StartMenuExperienceHost' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
if (Test-Path -LiteralPath $startPkg) {
    $files = @(Get-ChildItem -LiteralPath $startPkg -Force -ErrorAction SilentlyContinue)
    $files | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Start menu cache emptied ($($files.Count) items)"
}
Get-Process -Name 'StartMenuExperienceHost' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Log ("Leftovers of removed apps ({0}{1}): {2} removed" -f ($(if ($Max) { 'maximum list' } else { 'basic list' })), ($(if ($UserOnly) { ', at sign-in' } else { '' })), $removed)

# Once more at the next sign-in of this account (first sign-ins after the install can register apps again).
if (-not $UserOnly) {
    try {
        $tools = Join-Path $env:ProgramFiles 'Domain OS\Tools'
        New-Item -ItemType Directory -Force -Path $tools | Out-Null
        $target = Join-Path $tools 'Remove-AppLeftovers.ps1'
        if ($PSCommandPath -and ($PSCommandPath -ne $target)) { Copy-Item -Path $PSCommandPath -Destination $target -Force }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $cmd = "`"$ps`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target`" -UserOnly" + $(if ($Max) { ' -Max' } else { '' })
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name ('DomainOS-AppLeftovers' + $(if ($Max) { '-Max' } else { '' })) -Value $cmd
        Write-Log 'Check again at the next sign-in: scheduled'
    } catch { Write-Log "Check at the next sign-in not scheduled: $($_.Exception.Message)" }
}
exit 0
