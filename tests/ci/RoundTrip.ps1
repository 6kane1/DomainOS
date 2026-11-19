<#
  Domain OS CI (tests.yml, Windows job "round trip"): applies the playbook's registry values, services and scheduled
  tasks to a REAL Windows (a disposable GitHub runner), checks them with Check-DomainOS.ps1 -AfterInstall, runs
  "Undo Domain OS" and verifies that every item is back to what it was before.

      powershell.exe -File tests\ci\RoundTrip.ps1 -OptionSet defaults|all -IKnowThisChangesThisPC

  NEVER run it on your own PC: it changes services, tasks and policies of the machine it runs on. It refuses to start
  outside GitHub Actions (GITHUB_ACTIONS=true) and without -IKnowThisChangesThisPC.

  The steps, in the order main.yml uses on a real install (the scripts are the real ones, unchanged):
    1. snapshot   every registry value / service / task on Undo's allow-list, the keys of the task files, the classic
                  menu key, HKLM\SOFTWARE\Domain OS\Options, the power plans
    2. Save-State.ps1, Install-DomainOS.ps1 -Part Tools, the options record (Tasks\options.yml), Restore-Defaults.ps1
    3. the task files' actions as listed in expected.json, applied by this script (AME Wizard is not available here):
         registryValue add/delete, registryKey add (delete only when the key is not there anyway), service start type
         (registry, sc.exe as fallback) and stop/start, scheduledTask disable/enable, the runs Set-PowerPlan.ps1 and
         "powercfg /hibernate off" when their option is chosen
       NOT applied (listed in the report): appx removals, the other !run scripts (OneDrive, Toolbox, runtimes,
       wallpapers, Start/taskbar pins, app leftovers, TrkWks, hypervisor, guide pages), deleting keys that exist
       (Undo does not bring deleted keys back, by design), anything that fails as administrator (AME applies with
       TrustedInstaller rights; this script cannot)
    4. Check-DomainOS.ps1 -AfterInstall from the playbook folder: every FAIL / WARN must belong to an item that was
       not applied (listed); a FAIL of an applied item fails the test
    5. Program Files\Domain OS\Tools\Undo-DomainOS.ps1 (as from the Start menu): exit code 0
    6. snapshot again: must equal step 1 (service running states compared for the services that were stopped)
  Report: -Out (Markdown), also appended to GITHUB_STEP_SUMMARY. Exit code 1 when anything failed.
  Windows PowerShell 5.1 syntax.
#>
param(
    [ValidateSet('defaults', 'all')][string]$OptionSet = 'defaults',
    [string]$Out = (Join-Path ([IO.Path]::GetTempPath()) 'roundtrip.md'),
    [switch]$IKnowThisChangesThisPC
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $IKnowThisChangesThisPC) {
    Write-Host 'Refused: this test changes the Windows it runs on. It runs only on a disposable GitHub Actions runner (GITHUB_ACTIONS=true) with -IKnowThisChangesThisPC.'
    exit 2
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe = Join-Path $repo 'playbook\Executables'
$tasksDir = Join-Path $repo 'playbook\Configuration\Tasks'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tools = Join-Path $env:ProgramFiles 'Domain OS\Tools'
. (Join-Path $exe 'DomainOS-Common.ps1')
$data = $DomainOSData

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
$failures = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]
function Fail([string]$t) { $failures.Add($t); Write-Host "FAIL  $t" -ForegroundColor Red }
function Note([string]$t) { $notes.Add($t); Write-Host "NOTE  $t" }
function Step([string]$t) { Write-Host ''; Write-Host "==== $t" -ForegroundColor Cyan }

if ($PSVersionTable.PSEdition -ne 'Desktop') { Write-Host 'FAIL not Windows PowerShell 5.1: the playbook runs under powershell.exe'; exit 1 }
if (-not (Test-DomainOSAdmin)) { Write-Host 'FAIL  not elevated'; exit 1 }
if (Test-Path -LiteralPath $data) { Write-Host "FAIL  $data already exists: the runner is not fresh"; exit 1 }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [string]$cv.CurrentBuild
Write-Host "Windows: $($cv.ProductName) $($cv.EditionID) build $build.$($cv.UBR); PowerShell $($PSVersionTable.PSVersion); option set: $OptionSet"
$manifest = Get-Content -LiteralPath (Join-Path $exe 'expected.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# ---- the options -----------------------------------------------------------------------------------------------------
# install-scheduler is never chosen: DomainScheduler.exe (the Toolbox) is not built in this job.
$selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($o in $manifest.options) {
    if ($o.name -eq 'install-scheduler') { continue }
    if ($OptionSet -eq 'all' -or $o.default) { [void]$selected.Add([string]$o.name) }
}
Write-Host ('Options: ' + ((@($selected) | Sort-Object) -join ', '))
function Test-Option([string]$Opt) {
    if (-not $Opt) { return $true }
    if ($Opt.StartsWith('!')) { return (-not $selected.Contains($Opt.Substring(1))) }
    return $selected.Contains($Opt)
}
# Same rules as Check-DomainOS.ps1 (Test-Builds).
function Test-Builds($List) {
    $list = @($List | Where-Object { $_ })
    if ($list.Count -eq 0 -or -not $build) { return $true }
    $b = [int]$build; $positive = $false; $hit = $false
    foreach ($e in $list) {
        $e = [string]$e
        $neg = $e.StartsWith('!'); if ($neg) { $e = $e.Substring(1) }
        $m = [regex]::Match($e, '^(>=|<=|>|<)?\s*(\d+)$')
        if (-not $m.Success) { continue }
        $n = [int]$m.Groups[2].Value
        $match = switch ($m.Groups[1].Value) { '>=' { $b -ge $n } '<=' { $b -le $n } '>' { $b -gt $n } '<' { $b -lt $n } default { $b -eq $n } }
        if ($neg) { if ($match) { return $false } } else { $positive = $true; if ($match) { $hit = $true } }
    }
    return ((-not $positive) -or $hit)
}

# ---- registry helpers (64-bit view, as Save-State / Check / Undo) -------------------------------------------------
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$hkcu = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
function Split-Reg([string]$Path) {
    $hive = $Path.Split('\')[0]
    $base = switch ($hive) { 'HKLM' { $hklm } 'HKCU' { $hkcu } default { throw "unknown hive in $Path" } }
    return @{ Base = $base; Sub = $Path.Substring($hive.Length + 1) }
}
function Format-Data([string]$Kind, $Data) {
    switch ($Kind) {
        'MultiString' { return ((@($Data) | ForEach-Object { [string]$_ }) -join '\0') }
        'Binary' { return ((@($Data) | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join '') }
        default { return [string]$Data }
    }
}
function Read-Value([string]$Path, [string]$Name) {
    $r = Split-Reg $Path
    try {
        $k = $r.Base.OpenSubKey($r.Sub, $false)
        if (-not $k) { return 'absent' }
        try {
            if ($k.GetValueNames() -notcontains $Name) { return 'absent' }
            $kind = $k.GetValueKind($Name).ToString()
            return "$kind " + (Format-Data $kind $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
        } finally { $k.Close() }
    } catch { return "unreadable ($($_.Exception.GetType().Name))" }
}
function Test-Key([string]$Path) {
    $r = Split-Reg $Path
    try { $k = $r.Base.OpenSubKey($r.Sub, $false); if ($k) { $k.Close(); return 'present' } return 'absent' } catch { return 'unreadable' }
}
function Get-ServiceState([string]$Name) {
    $start = Read-Value "HKLM\SYSTEM\CurrentControlSet\Services\$Name" 'Start'
    $status = ''
    try { $status = [string](Get-Service -Name $Name -ErrorAction Stop).Status } catch { $status = 'n/a' }
    return @{ Start = $start; Status = $status }
}
function Get-TaskState([string]$Full) {
    $n = $Full.LastIndexOf('\')
    # Enabled or disabled is what Domain OS changes; Ready / Running / Queued are all "enabled" (a task may start by itself).
    try { $s = [string](Get-ScheduledTask -TaskPath ($Full.Substring(0, $n + 1)) -TaskName ($Full.Substring($n + 1)) -ErrorAction Stop).State } catch { return 'absent' }
    if ($s -eq 'Disabled') { return 'Disabled' } return 'enabled'
}
function Get-ActivePlan { if ((& powercfg.exe /getactivescheme) -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] } return '' }
function Get-Plans { return ((@(& powercfg.exe /list) | ForEach-Object { if ($_ -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $Matches[1] } }) | Sort-Object) -join ',' }

# What is compared: Undo's allow-list (task files + legacy lists), the keys of the task files, the classic menu key,
# the options record, the power plans.
$allow = @(New-DomainOSAllowListLines $tasksDir)
$keyPaths = @($manifest.items | Where-Object { $_.kind -eq 'registryKey' } | ForEach-Object { [string]$_.path }) +
    @('HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}', 'HKLM\SOFTWARE\Domain OS\Options') | Select-Object -Unique
function Get-Snapshot {
    $s = [ordered]@{}
    foreach ($l in $allow) {
        $p = $l.Split('|')
        switch ($p[0]) {
            'R' { $s[$l] = Read-Value $p[1] $p[2] }
            'S' { $st = Get-ServiceState $p[1]; $s[$l] = "start=$($st.Start)"; $s["$l|status"] = $st.Status }
            'T' { $s[$l] = Get-TaskState $p[1] }
        }
    }
    foreach ($k in $keyPaths) { $s["K|$k"] = Test-Key $k }
    $s['P|active'] = Get-ActivePlan
    $s['P|list'] = Get-Plans
    return $s
}
# Native programs: stderr lines must not become terminating errors (Windows PowerShell 5.1 with 2>&1 and 'Stop').
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $o = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ Code = $LASTEXITCODE; Out = ($o -join ' ') }
}
function Invoke-Ps([string]$Script, [string[]]$Arguments = @(), [string]$Dir) {
    $ErrorActionPreference = 'Continue'
    Write-Host "> $Script $($Arguments -join ' ')"
    Push-Location $(if ($Dir) { $Dir } else { Split-Path -Parent $Script })
    try {
        $o = & $ps -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    $o | ForEach-Object { Write-Host "    $_" }
    return @{ Code = $code; Out = ($o -join "`n") }
}

# ======================================================================================================================
Step '1. Snapshot before'
$before = Get-Snapshot
Write-Host "$($before.Count) entries"

Step '2. Save-State, tools, options record, Restore-Defaults (as main.yml)'
$r = Invoke-Ps (Join-Path $exe 'Save-State.ps1') @() $exe
if ($r.Code -ne 0) { Fail "Save-State.ps1 exit code $($r.Code)" }
if (-not (Test-Path -LiteralPath (Join-Path $data 'Undo\state.json'))) { Fail 'Save-State.ps1 wrote no state.json' }
$r = Invoke-Ps (Join-Path $exe 'Install-DomainOS.ps1') @('-Part', 'Tools') $exe
if ($r.Code -ne 0) { Fail "Install-DomainOS.ps1 -Part Tools exit code $($r.Code)" }
foreach ($f in 'Undo-DomainOS.ps1', 'Undo-AsSystem.ps1', 'Check-DomainOS.ps1', 'DomainOS-Common.ps1', 'expected.json', 'undo-allowlist.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $tools $f))) { Fail "Install-DomainOS.ps1 -Part Tools did not install $f" }
}
# Tasks\options.yml: the key emptied, one value per ticked option (= 1).
$optSub = 'SOFTWARE\Domain OS\Options'
try { $hklm.DeleteSubKeyTree($optSub, $false) } catch { }
$ok = $hklm.CreateSubKey($optSub)
foreach ($o in $selected) { $ok.SetValue($o, 1, [Microsoft.Win32.RegistryValueKind]::DWord) }
$ok.Close()
$r = Invoke-Ps (Join-Path $exe 'Restore-Defaults.ps1') @() $exe
if ($r.Code -ne 0) { Fail "Restore-Defaults.ps1 exit code $($r.Code)" }

Step '3. The task files (expected.json, in order)'
$status = @{}     # source "Tasks\x.yml:N" -> 'applied' | 'not applied: why'
$applied = 0; $notApplied = 0; $stopped = New-Object System.Collections.Generic.List[string]
function Set-Status($It, [string]$S) {
    $src = ('{0}:{1}' -f ([string]$It.file -replace '/', '\'), $It.line)
    $status[$src] = $S
    if ($S -eq 'applied') { $script:applied++ } else { $script:notApplied++; Write-Host "  not applied  $src  $($It.kind) $($It.path)$($It.name)$($It.script)  ($S)" }
}
$sc = Join-Path $env:SystemRoot 'System32\sc.exe'
foreach ($it in $manifest.items) {
    if (-not (Test-Builds $it.builds) -or -not (Test-Option ([string]$it.option))) { continue }
    try {
        switch ([string]$it.kind) {
            'registryValue' {
                $r = Split-Reg ([string]$it.path)
                if ($it.operation -eq 'delete') {
                    $k = $r.Base.OpenSubKey($r.Sub, $true)
                    if ($k) { try { $k.DeleteValue([string]$it.value, $false) } finally { $k.Close() } }
                } else {
                    $k = $r.Base.CreateSubKey($r.Sub)
                    try {
                        switch ([string]$it.type) {
                            'REG_DWORD' { $k.SetValue([string]$it.value, [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$it.data), 0), [Microsoft.Win32.RegistryValueKind]::DWord) }
                            'REG_QWORD' { $k.SetValue([string]$it.value, [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$it.data), 0), [Microsoft.Win32.RegistryValueKind]::QWord) }
                            'REG_SZ' { $k.SetValue([string]$it.value, [string]$it.data, [Microsoft.Win32.RegistryValueKind]::String) }
                            'REG_EXPAND_SZ' { $k.SetValue([string]$it.value, [string]$it.data, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
                            'REG_MULTI_SZ' { $k.SetValue([string]$it.value, [string[]]@($it.data), [Microsoft.Win32.RegistryValueKind]::MultiString) }
                            'REG_BINARY' { $h = [string]$it.data; $b = New-Object byte[] ($h.Length / 2); for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring(2 * $i, 2), 16) }; $k.SetValue([string]$it.value, $b, [Microsoft.Win32.RegistryValueKind]::Binary) }
                            default { throw "type $($it.type) not handled" }
                        }
                    } finally { $k.Close() }
                }
                Set-Status $it 'applied'
            }
            'registryKey' {
                $r = Split-Reg ([string]$it.path)
                if ($it.operation -eq 'add') { $r.Base.CreateSubKey($r.Sub).Close(); Set-Status $it 'applied' }
                elseif ((Test-Key ([string]$it.path)) -eq 'absent') { Set-Status $it 'applied' }   # nothing to delete
                else { Set-Status $it 'not applied: deleting a key that exists (Undo does not restore deleted keys, by design)' }
            }
            'service' {
                $name = [string]$it.name
                if ((Test-Key "HKLM\SYSTEM\CurrentControlSet\Services\$name") -ne 'present') { Set-Status $it 'applied'; continue }   # not on this Windows: Check says SKIP
                switch ([string]$it.operation) {
                    'change' {
                        try {
                            $k = $hklm.OpenSubKey("SYSTEM\CurrentControlSet\Services\$name", $true)
                            try { $k.SetValue('Start', [int]$it.startup, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
                        } catch {
                            $mode = @('boot', 'system', 'auto', 'demand', 'disabled')[[int]$it.startup]
                            $n2 = Invoke-Native $sc @('config', $name, 'start=', $mode)
                            if ($n2.Code -ne 0) { throw "registry: $($_.Exception.Message); sc.exe: $($n2.Out)" }
                        }
                        Set-Status $it 'applied'
                    }
                    'stop' {
                        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                        if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction Stop; $stopped.Add($name) }
                        Set-Status $it 'applied'
                    }
                    'start' { Start-Service -Name $name -ErrorAction Stop; Set-Status $it 'applied' }
                    default { Set-Status $it "not applied: service operation $($it.operation)" }
                }
            }
            'scheduledTask' {
                $full = [string]$it.path; $n = $full.LastIndexOf('\')
                $t = Get-ScheduledTask -TaskPath ($full.Substring(0, $n + 1)) -TaskName ($full.Substring($n + 1)) -ErrorAction SilentlyContinue
                if (-not $t) { Set-Status $it 'applied'; continue }   # not on this Windows: Check says SKIP
                switch ([string]$it.operation) {
                    'disable' { $t | Disable-ScheduledTask -ErrorAction Stop | Out-Null; Set-Status $it 'applied' }
                    'enable' { $t | Enable-ScheduledTask -ErrorAction Stop | Out-Null; Set-Status $it 'applied' }
                    default { Set-Status $it "not applied: task operation $($it.operation)" }
                }
            }
            'run' {
                if ($it.script -eq 'Set-PowerPlan.ps1') {
                    $r = Invoke-Ps (Join-Path $exe 'Set-PowerPlan.ps1') @() $exe
                    if ($r.Code -ne 0) { throw "Set-PowerPlan.ps1 exit code $($r.Code)" }
                    Set-Status $it 'applied'
                } elseif ([string]$it.exe -like '*powercfg.exe' -and [string]$it.args -match '/hibernate off') {
                    $n2 = Invoke-Native 'powercfg.exe' @('/hibernate', 'off')
                    if ($n2.Code -ne 0) { Set-Status $it "not applied: powercfg /hibernate off failed on this machine ($($n2.Out))" } else { Set-Status $it 'applied' }
                } else { Set-Status $it 'not applied: script not run in CI' }
            }
            'appx' { Set-Status $it 'not applied: app removal is not done in CI' }
            default { Set-Status $it "not applied: kind $($it.kind)" }
        }
    } catch { Set-Status $it "not applied: failed as administrator ($($_.Exception.Message))" }
}
Write-Host "applied: $applied, not applied: $notApplied"
# Who may write the keys that refused administrators (AME applies with TrustedInstaller rights; Undo runs as administrator,
# and as SYSTEM only for services and tasks): listed in the report.
$aclNotes = New-Object System.Collections.Generic.List[string]
foreach ($it in $manifest.items) {
    $src = ('{0}:{1}' -f ([string]$it.file -replace '/', '\'), $it.line)
    if ($it.kind -ne 'registryValue' -or -not $status.ContainsKey($src) -or $status[$src] -notlike '*failed as administrator*') { continue }
    # The key itself, or the nearest parent that exists (a missing key is created under it).
    $p = [string]$it.path
    while ($p.Contains('\') -and (Test-Key $p) -ne 'present') { $p = $p.Substring(0, $p.LastIndexOf('\')) }
    try {
        $r = Split-Reg $p
        $k = $r.Base.OpenSubKey($r.Sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        try { $acl = $k.GetAccessControl() } finally { $k.Close() }
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.NTAccount]) | ForEach-Object { "$($_.IdentityReference): $($_.RegistryRights)" + $(if ($_.IsInherited) { ' (inherited)' } else { '' }) }) -join '; '
        $aclNotes.Add("$($it.path) (ACL of $p) - owner $($acl.GetOwner([Security.Principal.NTAccount])); $rules")
    } catch { $aclNotes.Add("$($it.path) (ACL of $p) - unreadable: $($_.Exception.Message)") }
}
foreach ($a in $aclNotes) { Write-Host "  ACL  $a" }

Step '4. Check-DomainOS.ps1 -AfterInstall'
$checkLog = Join-Path $data 'Logs\check.log'
Remove-Item -LiteralPath $checkLog -ErrorAction SilentlyContinue
$r = Invoke-Ps (Join-Path $exe 'Check-DomainOS.ps1') @('-AfterInstall') $exe
Write-Host "Check-DomainOS exit code $($r.Code)"
$checkCount = @{ PASS = 0; FAIL = 0; WARN = 0; SKIP = 0; INFO = 0 }
$expectedFails = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath $checkLog)) { Fail 'Check-DomainOS.ps1 wrote no check.log' }
else {
    foreach ($l in Get-Content -LiteralPath $checkLog -Encoding UTF8) {
        if ($l -notmatch '^(PASS|FAIL|WARN|SKIP|INFO)  ') { continue }
        $st = $Matches[1]; $checkCount[$st]++
        if ($st -ne 'FAIL' -and $st -ne 'WARN') { continue }
        $src = if ($l -match '\| (Tasks\\[^|]+?:\d+)\s*$') { $Matches[1] } else { '' }
        if ($src -and $status.ContainsKey($src) -and $status[$src] -ne 'applied') { $expectedFails.Add("$l  [$($status[$src])]") }
        elseif ($st -eq 'WARN' -and $l -match '^WARN  service \S+ running \| expected: stopped') { Note "Check: $l (a stopped manual service was started again by Windows)" }
        else { Fail "Check-DomainOS: $l" }
    }
}
if ($checkCount.PASS -lt 50) { Fail "Check-DomainOS: only $($checkCount.PASS) PASS lines (expected the applied items)" }
Write-Host ("Check: {0} PASS, {1} FAIL, {2} WARN, {3} SKIP; {4} FAIL/WARN belong to items not applied here" -f $checkCount.PASS, $checkCount.FAIL, $checkCount.WARN, $checkCount.SKIP, $expectedFails.Count)

Step '5. Undo Domain OS (Program Files\Domain OS\Tools\Undo-DomainOS.ps1)'
$r = Invoke-Ps (Join-Path $tools 'Undo-DomainOS.ps1') @() $tools
if ($r.Code -ne 0) { Fail "Undo-DomainOS.ps1 exit code $($r.Code)" }
if (Test-Path -LiteralPath (Join-Path $data 'Undo\state.json')) { Fail 'Undo kept state.json (it renames it after a complete undo)' }
$hist = Get-Content -LiteralPath (Join-Path $data 'history.log') -Encoding UTF8 -ErrorAction SilentlyContinue
if (-not ($hist | Where-Object { $_ -match '\sundone\s' })) { Fail 'history.log has no "undone" line' }

Step '6. Snapshot after Undo, compared with before'
Start-Sleep -Seconds 5
$after = Get-Snapshot
$same = 0
foreach ($k in $before.Keys) {
    $a = $before[$k]; $b = $after[$k]
    if ($a -eq $b) { $same++; continue }
    if ($k.EndsWith('|status')) {
        $svc = $k.Split('|')[1]
        if ($stopped -contains $svc) { Fail "service $svc running state: before '$a', after Undo '$b'" }
        else { Note "service $svc running state changed by Windows (not touched by the test): '$a' -> '$b'" }
        continue
    }
    Fail "$k`: before '$a', after Undo '$b'"
}
Write-Host "$same of $($before.Count) entries identical"

# ---- report ------------------------------------------------------------------------------------------------------------
$report.Add("## Windows round trip ($OptionSet options)")
$report.Add('')
$report.Add("Windows $($cv.ProductName) build $build.$($cv.UBR), Windows PowerShell $($PSVersionTable.PSVersion). Options: $((@($selected) | Sort-Object) -join ', ')")
$report.Add('')
$report.Add("- task-file actions applied: **$applied**, not applied: **$notApplied** (list below)")
$report.Add("- Check-DomainOS -AfterInstall: $($checkCount.PASS) PASS, $($checkCount.FAIL) FAIL, $($checkCount.WARN) WARN, $($checkCount.SKIP) SKIP; FAIL/WARN of items not applied: $($expectedFails.Count)")
$report.Add("- after Undo: $same of $($before.Count) snapshot entries identical")
$report.Add("- **result: $(if ($failures.Count) { "FAILED ($($failures.Count))" } else { 'PASS' })**")
if ($failures.Count) { $report.Add(''); $report.Add('### Failures'); foreach ($f in $failures) { $report.Add("- $f") } }
if ($notes.Count) { $report.Add(''); $report.Add('### Notes'); foreach ($n in $notes) { $report.Add("- $n") } }
if ($aclNotes.Count) { $report.Add(''); $report.Add('### Keys administrators may not write (Undo restores registry values as administrator only)'); foreach ($a in $aclNotes) { $report.Add("- $a") } }
$report.Add(''); $report.Add('<details><summary>Not applied here</summary>'); $report.Add('')
foreach ($k in ($status.Keys | Sort-Object)) { if ($status[$k] -ne 'applied') { $report.Add("- $k : $($status[$k])") } }
$report.Add(''); $report.Add('</details>')
if ($expectedFails.Count) {
    $report.Add(''); $report.Add('<details><summary>Check FAIL/WARN lines of items not applied (expected)</summary>'); $report.Add('')
    foreach ($e in $expectedFails) { $report.Add("- ``$e``") }
    $report.Add(''); $report.Add('</details>')
}
Set-Content -LiteralPath $Out -Value $report -Encoding UTF8
try { Copy-Item -LiteralPath (Join-Path $data 'Logs') -Destination (Join-Path (Split-Path -Parent $Out) 'logs') -Recurse -Force } catch { }
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $report -Encoding UTF8 }
Write-Host ''
Write-Host ($report -join "`n")
if ($failures.Count) { exit 1 }
exit 0
