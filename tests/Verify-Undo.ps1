<#
  Domain OS — checks, after "Undo Domain OS" and a restart, that every registry value, service and scheduled task
  is back to what it was BEFORE the first Domain OS install. READ ONLY: it changes nothing.

  Run in PowerShell as administrator:
      powershell -ExecutionPolicy Bypass -File .\Verify-Undo.ps1

  It reads the saved original state (%ProgramData%\Domain OS\Undo\state.original-restored-*.json — the copy Undo keeps
  after it finished — or state.original.json if Undo has not finished) and compares each item with this PC now.
  The report is printed and saved on the desktop as DomainOS-Verify-Undo.txt.
#>
$ErrorActionPreference = 'Continue'
$undoDir = Join-Path $env:ProgramData 'Domain OS\Undo'
$file = Get-ChildItem -LiteralPath $undoDir -Filter 'state.original-restored-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$mode = 'after Undo'
if (-not $file) { $file = Get-Item -LiteralPath (Join-Path $undoDir 'state.original.json') -ErrorAction SilentlyContinue; $mode = 'Undo NOT finished yet (comparing with the saved original anyway)' }
if (-not $file) { Write-Host "No saved original state in $undoDir — nothing to compare." -ForegroundColor Red; Read-Host 'Press Enter to close' | Out-Null; exit 1 }

# Windows PowerShell 5.1 returns a JSON array as one object: enumerate.
$state = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$lines = New-Object System.Collections.Generic.List[string]
$ok = 0; $diff = 0; $skip = 0
function Out-Line([string]$s, [string]$color = 'Gray') { $lines.Add($s); Write-Host $s -ForegroundColor $color }

Out-Line "Domain OS — Undo check, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ($mode)"
Out-Line "Saved original: $($file.Name), saved $($state.saved), for user $($state.user), Windows build $($state.build)"
Out-Line "This PC now:    user $([Security.Principal.WindowsIdentity]::GetCurrent().Name), Windows build $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild)"
Out-Line ''

function Get-Now([string]$path, [string]$name) {
    $hive = $path.Split('\')[0]; $sub = $path.Substring($hive.Length + 1)
    $base = switch ($hive) { 'HKLM' { [Microsoft.Win32.Registry]::LocalMachine } 'HKCU' { [Microsoft.Win32.Registry]::CurrentUser } default { $null } }
    $k = $base.OpenSubKey($sub, $false)
    if (-not $k) { return @{ exists = $false } }
    try {
        if ($k.GetValueNames() -notcontains $name) { return @{ exists = $false } }
        return @{ exists = $true; kind = $k.GetValueKind($name).ToString(); data = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    } finally { $k.Close() }
}
function Show([object]$d) { if ($null -eq $d) { return '(empty)' }; if ($d -is [array]) { return ($d -join ',') }; return [string]$d }

Out-Line '== Registry values'
foreach ($r in @($state.registry | ForEach-Object { $_ })) {
    if ($r.unreadable) { $skip++; continue }
    $what = "$($r.path)\$($r.name)"
    try { $now = Get-Now $r.path $r.name } catch { $skip++; Out-Line "SKIP  $what | cannot read now: $($_.Exception.Message)" 'DarkYellow'; continue }
    if (-not $r.exists) {
        if (-not $now.exists) { $ok++ } else { $diff++; Out-Line "DIFF  $what | before: not there | now: $($now.kind) $(Show $now.data)" 'Yellow' }
    } else {
        if ($now.exists -and (Show $now.data) -eq (Show $r.data)) { $ok++ }
        else { $diff++; Out-Line "DIFF  $what | before: $($r.kind) $(Show $r.data) | now: $(if ($now.exists) { "$($now.kind) $(Show $now.data)" } else { 'not there' })" 'Yellow' }
    }
}
Out-Line '== Services (start type)'
foreach ($s in @($state.services | ForEach-Object { $_ })) {
    if ($s.unreadable) { $skip++; continue }
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.name)"
    if (-not (Test-Path -LiteralPath $p)) { $diff++; Out-Line "DIFF  service $($s.name) | before: start $($s.start) | now: service missing" 'Yellow'; continue }
    $start = (Get-ItemProperty -LiteralPath $p -Name Start -ErrorAction SilentlyContinue).Start
    if ([int]$start -eq [int]$s.start) { $ok++ } else { $diff++; Out-Line "DIFF  service $($s.name) | before: start $($s.start) | now: start $start" 'Yellow' }
}
Out-Line '== Scheduled tasks (enabled / disabled)'
foreach ($t in @($state.tasks | ForEach-Object { $_ })) {
    $folder = $t.path.Substring(0, $t.path.LastIndexOf('\') + 1); $name = $t.path.Substring($t.path.LastIndexOf('\') + 1)
    $task = Get-ScheduledTask -TaskPath $folder -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) { $skip++; Out-Line "SKIP  task $($t.path) | not on this Windows now" 'DarkYellow'; continue }
    $en = $task.State -ne 'Disabled'
    if ($en -eq [bool]$t.enabled) { $ok++ } else { $diff++; Out-Line "DIFF  task $($t.path) | before: $(if ($t.enabled) {'enabled'} else {'disabled'}) | now: $(if ($en) {'enabled'} else {'disabled'})" 'Yellow' }
}
Out-Line ''
Out-Line "Result: $ok back as before, $diff different, $skip skipped" $(if ($diff -eq 0) { 'Green' } else { 'Yellow' })
if ($diff -gt 0) { Out-Line 'A DIFF can be normal when you (or Windows itself, e.g. ContentDeliveryManager, after updates) changed that setting since the install. Send this file if unsure.' }
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DomainOS-Verify-Undo.txt'
$lines | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "Saved: $out"
if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host 'Press Enter to close' | Out-Null }
