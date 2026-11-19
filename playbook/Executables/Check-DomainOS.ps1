<#
  Domain OS - "Check Domain OS": compares this PC with what the playbook set, and (by hand) checks Windows' health.
  READ-ONLY: it never changes a setting, a service, a task, an app or a file of Windows or Domain OS. The only files it
  writes are its own reports (below).

  Modes
    -AfterInstall   the LAST step of the playbook (main.yml, as the signed-in user, elevated). Checks expected.json
                    (written at build time by tools/gen-expected.py from the task files) against the system, for the
                    options recorded in HKLM\SOFTWARE\Domain OS\Options (Tasks\options.yml), plus the results of the
                    scripts that have one to check (power plan, hibernation, Toolbox autostart). A service, task or app
                    this Windows build does not have = SKIP; a value or state that differs = FAIL. Each FAIL is printed
                    as one line (what, expected, found, task file:line). Report: %ProgramData%\Domain OS\Logs\check.log.
                    Exit code 1 when anything FAILED (the install stops: main.yml handleExitCodes), 0 otherwise.
                    No health checks here (they are slow and not about the playbook).
    (no switch)     Start > Domain OS > Check Domain OS. Asks for administrator rights. The same checks, plus: the data
                    folder's protection, the saved state for Undo, Undo's allow-list and tools, a dry run of
                    "Undo Domain OS -WhatIf", the \Domain OS\ scheduled tasks, the Toolbox autostart and version, the
                    installed version, FAILED lines of the last install, Domain OS errors in the event logs, and a
                    "Windows health" section (DISM CheckHealth, sfc /verifyonly, devices with a driver problem, pending
                    restart, Windows Update, disks, unexpected shutdowns, recent errors, free space).
                    Report on screen and as a text file on the desktop ("Domain OS check <date>.txt").
    -Quick          (with no mode switch) leaves out the two slow health checks, DISM and sfc.
    -NoPause        does not wait for Enter at the end.

  Statuses: PASS (as expected), INFO (for your information), SKIP (not on this PC / not chosen / cannot be decided),
  WARN (worth a look, not a Domain OS failure), FAIL (differs from what Domain OS set, or broken).
  Per-user (HKCU) values are read from the signed-in user's own registry: AME Wizard writes them into every account,
  this check looks at the account that is signed in (when run as SYSTEM, the account at the console).
  Windows PowerShell 5.1 syntax only.
#>
[CmdletBinding()]
param([switch]$AfterInstall, [switch]$Quick, [switch]$NoPause)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$common = Join-Path $here 'DomainOS-Common.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    Write-Host 'FAIL  DomainOS-Common.ps1 is missing next to Check-DomainOS.ps1: nothing can be checked. Apply the playbook again to reinstall the tools.'
    if (-not $AfterInstall -and -not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit 1
}
. $common
if (-not $AfterInstall) {
    # Not elevated: start again as administrator with the same switches.
    if (Start-DomainOSElevated $MyInvocation.MyCommand.Path $PSBoundParameters) { exit 0 }
}

# ---- results -------------------------------------------------------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Notes = New-Object System.Collections.Generic.List[string]
# DomainOS-Common.ps1 writes its notes (e.g. "Refused <file>: its owner ...") through Write-Log when it exists.
function Write-Log([string]$text) { $script:Notes.Add($text) }
function Add-Result([string]$Status, [string]$Area, [string]$What, [string]$Expected = '', [string]$Actual = '', [string]$Source = '', [string]$Advice = '') {
    $script:Results.Add([pscustomobject]@{ Status = $Status; Area = $Area; What = $What; Expected = $Expected; Actual = $Actual; Source = $Source; Advice = $Advice })
    if (-not $AfterInstall) {
        # A live line for the slow sections, so the window does not look frozen.
        if ($Status -eq 'FAIL' -or $Status -eq 'WARN') { Write-Host ('  ' + $Status + '  ' + $What) -ForegroundColor $(if ($Status -eq 'FAIL') { 'Red' } else { 'Yellow' }) }
    }
}
function Write-Section([string]$Name) { if (-not $AfterInstall) { Write-Host ''; Write-Host "== $Name" -ForegroundColor Cyan } }

# Runs a program with a time limit and returns its output (read-only programs only).
function Invoke-Tool([string]$File, [string]$Arguments, [int]$TimeoutSec, $Encoding) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File; $psi.Arguments = $Arguments; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    if ($Encoding) { $psi.StandardOutputEncoding = $Encoding; $psi.StandardErrorEncoding = $Encoding }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ TimedOut = $true; ExitCode = $null; Output = '' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ TimedOut = $false; ExitCode = $p.ExitCode; Output = ($out.Result + "`n" + $err.Result) }
}

# Runs a script block in a background job with a time limit: @{ Ok; TimedOut; Data; Error }.
function Invoke-WithTimeout([scriptblock]$Block, [int]$TimeoutSec, [object[]]$Arguments = @()) {
    $job = $null
    try {
        $job = Start-Job -ScriptBlock $Block -ArgumentList $Arguments
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSec)) { Stop-Job -Job $job; return @{ Ok = $false; TimedOut = $true; Data = $null; Error = "no answer within $TimeoutSec s" } }
        $data = Receive-Job -Job $job -ErrorAction Stop
        return @{ Ok = $true; TimedOut = $false; Data = $data; Error = '' }
    } catch { return @{ Ok = $false; TimedOut = $false; Data = $null; Error = $_.Exception.Message }
    } finally { if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } }
}

# ---- where things are -----------------------------------------------------------------------------------------------
$toolsDir = Join-Path $env:ProgramFiles 'Domain OS\Tools'
$manifestPath = Join-Path $here 'expected.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $toolsDir 'expected.json' }
$logDir = Join-Path $DomainOSData 'Logs'
$isAdmin = Test-DomainOSAdmin
$build = ''; $ubr = ''; $displayVersion = ''; $edition = ''
try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [string]$cv.CurrentBuild; $ubr = [string]$cv.UBR; $displayVersion = [string]$cv.DisplayVersion; $edition = [string]$cv.EditionID
} catch { }

# The signed-in user's registry (HKCU): this account, or - when running as SYSTEM - the account at the console.
$script:UserHive = $null; $userHiveName = ''
try {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($me.User.Value -like 'S-1-5-21-*' -or $me.User.Value -like 'S-1-12-1-*') {
        $script:UserHive = [Microsoft.Win32.Registry]::CurrentUser; $userHiveName = $me.Name
    } else {
        $console = (Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 30).UserName
        if ($console) {
            $sid = (New-Object Security.Principal.NTAccount($console)).Translate([Security.Principal.SecurityIdentifier]).Value
            $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($sid, $false)
            if ($k) { $script:UserHive = $k; $userHiveName = $console }
        }
    }
} catch { }
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)

# history.log: the version applied last, or "undone".
$history = [pscustomobject]@{ State = 'none'; Version = ''; When = '' }
$historyFile = Join-Path $DomainOSData 'history.log'
if (Test-Path -LiteralPath $historyFile) {
    foreach ($l in @(Get-Content -LiteralPath $historyFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $t = @($l -split '\s+' | Where-Object { $_ })
        if ($t.Count -ge 3 -and $t[2] -eq 'applied') { $history = [pscustomobject]@{ State = 'applied'; Version = $(if ($t.Count -ge 4) { $t[3] } else { '' }); When = "$($t[0]) $($t[1])" } }
        elseif ($t.Count -ge 3 -and $t[2] -like 'undo*') { $history = [pscustomobject]@{ State = 'undone'; Version = (($t | Select-Object -Skip 3) -join ' '); When = "$($t[0]) $($t[1])" } }
    }
}

# The recorded options.
$script:OptionsKnown = $false
$script:Selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
try {
    $ok = $hklm.OpenSubKey('SOFTWARE\Domain OS\Options', $false)
    if ($ok) {
        try {
            $script:OptionsKnown = $true
            foreach ($n in $ok.GetValueNames()) { if ([string]$ok.GetValue($n) -eq '1') { [void]$script:Selected.Add($n) } }
        } finally { $ok.Close() }
    }
} catch { }

# ---- expected.json ----------------------------------------------------------------------------------------------------
$manifest = $null
try {
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "expected.json is not there ($manifestPath)" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.items) { throw 'expected.json holds no items' }
} catch {
    $manifest = $null
    Add-Result 'FAIL' 'Domain OS' 'The list of expected changes (expected.json) cannot be read' '' $_.Exception.Message '' 'Apply the playbook again: it installs the check with its list.'
}

function Get-Source($Item) { if ($Item) { return ('{0}:{1}' -f ([string]$Item.file -replace '/', '\'), $Item.line) } return '' }
function Get-RunItem([string]$Script, [string]$Exe) {
    if (-not $manifest) { return $null }
    foreach ($i in $manifest.items) { if ($i.kind -eq 'run' -and (($Script -and $i.script -eq $Script) -or ($Exe -and $i.exe -eq $Exe))) { return $i } }
    return $null
}

# True / False / $null (cannot be decided: the options are not recorded).
function Test-Option([string]$Opt) {
    if (-not $Opt) { return $true }
    if (-not $script:OptionsKnown) { return $null }
    if ($Opt.StartsWith('!')) { return (-not $script:Selected.Contains($Opt.Substring(1))) }
    return $script:Selected.Contains($Opt)
}
# builds: [] = every build; "26200" exact, "!26200" not, ">=26200" / "<=" / ">" / "<" ranges.
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

# ---- registry helpers -----------------------------------------------------------------------------------------------
function Get-HiveBase([string]$Hive) { if ($Hive -eq 'HKLM') { return $hklm } return $script:UserHive }
function Read-RegValue($Base, [string]$Sub, [string]$Name) {
    $r = @{ KeyExists = $false; Exists = $false; Kind = ''; Data = $null; Error = '' }
    try {
        $k = $Base.OpenSubKey($Sub, $false)
        if ($k) {
            try {
                $r.KeyExists = $true
                if ($k.GetValueNames() -contains $Name) {
                    $r.Exists = $true
                    $r.Kind = $k.GetValueKind($Name).ToString()
                    $r.Data = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            } finally { $k.Close() }
        }
    } catch { $r.Error = $_.Exception.Message }
    return $r
}
function Test-RegKey($Base, [string]$Sub) {
    try { $k = $Base.OpenSubKey($Sub, $false); if ($k) { $k.Close(); return $true } return $false } catch { return $null }
}
$kindOf = @{ 'REG_SZ' = 'String'; 'REG_EXPAND_SZ' = 'ExpandString'; 'REG_DWORD' = 'DWord'; 'REG_QWORD' = 'QWord'; 'REG_MULTI_SZ' = 'MultiString'; 'REG_BINARY' = 'Binary' }
function Format-RegData([string]$Kind, $Data) {
    switch ($Kind) {
        'DWord' { return [string][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Data), 0) }
        'QWord' { return [string][BitConverter]::ToUInt64([BitConverter]::GetBytes([long]$Data), 0) }
        'MultiString' { return ((@($Data) | ForEach-Object { [string]$_ }) -join '\0') }
        'Binary' { return ((@($Data) | ForEach-Object { '{0:X2}' -f [byte]$_ }) -join '') }
        default { return [string]$Data }
    }
}
function Format-Expected($Item) {
    $k = $kindOf[[string]$Item.type]
    if ($k -eq 'MultiString') { return ((@($Item.data) | ForEach-Object { [string]$_ }) -join '\0') }
    if ($null -eq $Item.data) { return '' }
    return [string]$Item.data
}
function Show([string]$Kind, [string]$Text) {
    if ($Kind -eq 'String' -or $Kind -eq 'ExpandString' -or $Kind -eq 'MultiString') { return '"' + $Text + '"' }
    return $Text
}

# ---- the expected state: which actions are in effect, then each one checked ----------------------------------------
function Test-ExpectedState {
    if (-not $manifest) { return }
    $area = 'Expected changes'
    $values = [ordered]@{}; $keys = [ordered]@{}; $services = [ordered]@{}; $tasks = [ordered]@{}; $apps = [ordered]@{}
    $notChosen = 0; $undecided = 0
    foreach ($it in $manifest.items) {
        if ($it.kind -eq 'run') { continue }
        if (-not (Test-Builds $it.builds)) { continue }   # another Windows build's line
        $cond = Test-Option ([string]$it.option)
        if ($cond -eq $false) { $notChosen++; continue }
        $unknown = ($null -eq $cond)
        switch ([string]$it.kind) {
            'registryValue' {
                $id = ('{0}|{1}|{2}' -f $it.hive, ([string]$it.sub).ToLowerInvariant(), ([string]$it.value).ToLowerInvariant())
                $values[$id] = @{ Item = $it; Unknown = $unknown }
                if ($it.operation -eq 'add') {
                    # A value written under a key that an earlier action deleted brings that key back.
                    foreach ($kid in @($keys.Keys)) {
                        $k = $keys[$kid].Item
                        if ($k.operation -eq 'delete' -and $k.hive -eq $it.hive -and (([string]$it.sub).ToLowerInvariant() -eq ([string]$k.sub).ToLowerInvariant() -or ([string]$it.sub).ToLowerInvariant().StartsWith(([string]$k.sub).ToLowerInvariant() + '\'))) { $keys.Remove($kid) }
                    }
                }
            }
            'registryKey' {
                $id = ('{0}|{1}' -f $it.hive, ([string]$it.sub).ToLowerInvariant())
                $keys[$id] = @{ Item = $it; Unknown = $unknown }
                if ($it.operation -eq 'delete') {
                    # Values written earlier under a key deleted later are gone with it.
                    $prefix = ([string]$it.sub).ToLowerInvariant()
                    foreach ($vid in @($values.Keys)) {
                        $v = $values[$vid].Item
                        $vs = ([string]$v.sub).ToLowerInvariant()
                        if ($v.hive -eq $it.hive -and ($vs -eq $prefix -or $vs.StartsWith($prefix + '\'))) { $values.Remove($vid) }
                    }
                }
            }
            'service' {
                $id = ([string]$it.name).ToLowerInvariant()
                if (-not $services.Contains($id)) { $services[$id] = @{ Name = [string]$it.name; Startup = $null; StartupItem = $null; Stopped = $null; StopItem = $null; Delete = $null; Unknown = $false } }
                $s = $services[$id]
                if ($unknown) { $s.Unknown = $true }
                switch ([string]$it.operation) {
                    'change' { if ($null -ne $it.startup) { $s.Startup = [int]$it.startup; $s.StartupItem = $it }; $s.Delete = $null }
                    'stop' { $s.Stopped = $true; $s.StopItem = $it }
                    'start' { $s.Stopped = $false; $s.StopItem = $it }
                    'delete' { $s.Delete = $it }
                }
            }
            'scheduledTask' { $tasks[([string]$it.path).ToLowerInvariant()] = @{ Item = $it; Unknown = $unknown } }
            'appx' { $apps[([string]$it.name).ToLowerInvariant()] = @{ Item = $it; Unknown = $unknown } }
        }
    }

    # Registry values
    foreach ($e in $values.Values) {
        $it = $e.Item; $src = Get-Source $it
        $name = if ([string]$it.value) { [string]$it.value } else { '(Default)' }
        $what = "$($it.path)\$name"
        $bad = if ($it.check -eq 'warn') { 'WARN' } else { 'FAIL' }
        if ($e.Unknown) { $undecided++; Add-Result 'SKIP' $area $what '' 'the options are not recorded on this PC' $src; continue }
        $base = Get-HiveBase $it.hive
        if (-not $base) { Add-Result 'SKIP' $area $what '' 'no signed-in user registry to read' $src; continue }
        $r = Read-RegValue $base ([string]$it.sub) ([string]$it.value)
        if ($r.Error) { Add-Result 'WARN' $area $what '' "cannot be read: $($r.Error)" $src; continue }
        $kind = $kindOf[[string]$it.type]
        if ($it.operation -eq 'delete') {
            if ($r.Exists) { Add-Result $bad $area $what 'not there' (Show $r.Kind (Format-RegData $r.Kind $r.Data)) $src }
            else { Add-Result 'PASS' $area $what 'not there' 'not there' $src }
            continue
        }
        $want = Format-Expected $it
        $expText = "$($it.type) " + (Show $kind $want)
        if (-not $r.Exists) { Add-Result $bad $area $what $expText 'not there' $src; continue }
        $have = Format-RegData $r.Kind $r.Data
        if ($r.Kind -ne $kind) { Add-Result $bad $area $what $expText ("$($r.Kind) " + (Show $r.Kind $have)) $src; continue }
        if ($have -cne $want) { Add-Result $bad $area $what $expText (Show $kind $have) $src; continue }
        Add-Result 'PASS' $area $what $expText (Show $kind $have) $src
    }
    # Registry keys
    foreach ($e in $keys.Values) {
        $it = $e.Item; $src = Get-Source $it
        $bad = if ($it.check -eq 'warn') { 'WARN' } else { 'FAIL' }
        if ($e.Unknown) { $undecided++; Add-Result 'SKIP' $area "$($it.path) (key)" '' 'the options are not recorded on this PC' $src; continue }
        $base = Get-HiveBase $it.hive
        if (-not $base) { Add-Result 'SKIP' $area "$($it.path) (key)" '' 'no signed-in user registry to read' $src; continue }
        $there = Test-RegKey $base ([string]$it.sub)
        if ($null -eq $there) { Add-Result 'WARN' $area "$($it.path) (key)" '' 'cannot be read' $src; continue }
        $want = ($it.operation -eq 'add')
        $wantText = if ($want) { 'there' } else { 'not there' }
        $haveText = if ($there) { 'there' } else { 'not there' }
        if ($there -eq $want) { Add-Result 'PASS' $area "$($it.path) (key)" $wantText $haveText $src } else { Add-Result $bad $area "$($it.path) (key)" $wantText $haveText $src }
    }
    # Services
    foreach ($s in $services.Values) {
        $what = "service $($s.Name)"
        $src = Get-Source $(if ($s.StartupItem) { $s.StartupItem } elseif ($s.StopItem) { $s.StopItem } else { $s.Delete })
        if ($s.Unknown) { $undecided++; Add-Result 'SKIP' $area $what '' 'the options are not recorded on this PC' $src; continue }
        $key = "SYSTEM\CurrentControlSet\Services\$($s.Name)"
        $there = Test-RegKey $hklm $key
        if ($s.Delete) {
            if ($there) { Add-Result 'FAIL' $area $what 'removed' 'still registered' (Get-Source $s.Delete) } else { Add-Result 'PASS' $area $what 'removed' 'not registered' (Get-Source $s.Delete) }
            continue
        }
        if (-not $there) { Add-Result 'SKIP' $area $what '' 'not on this Windows' $src; continue }
        if ($null -ne $s.Startup) {
            $r = Read-RegValue $hklm $key 'Start'
            $now = if ($r.Exists) { [int]$r.Data } else { $null }
            if ($now -eq $s.Startup) { Add-Result 'PASS' $area "$what start type" "$($s.Startup)" "$now" (Get-Source $s.StartupItem) }
            else { Add-Result 'FAIL' $area "$what start type" "$($s.Startup) (0 boot, 1 system, 2 automatic, 3 manual, 4 disabled)" "$now" (Get-Source $s.StartupItem) }
        }
        if ($null -ne $s.Stopped) {
            $status = ''
            try { $status = [string](Get-Service -Name $s.Name -ErrorAction Stop).Status } catch { }
            if (-not $status) { Add-Result 'SKIP' $area "$what running" '' 'state not readable' (Get-Source $s.StopItem) }
            elseif ($s.Stopped -and $status -eq 'Running') {
                # Only a disabled service must stay stopped; any other may be started again by Windows when needed.
                $st = if ($s.Startup -eq 4) { 'FAIL' } else { 'WARN' }
                Add-Result $st $area "$what running" 'stopped' $status (Get-Source $s.StopItem)
            } elseif (-not $s.Stopped -and $status -ne 'Running') { Add-Result 'WARN' $area "$what running" 'running' $status (Get-Source $s.StopItem) }
            else { Add-Result 'PASS' $area "$what running" $(if ($s.Stopped) { 'stopped' } else { 'running' }) $status (Get-Source $s.StopItem) }
        }
    }
    # Scheduled tasks
    foreach ($e in $tasks.Values) {
        $it = $e.Item; $src = Get-Source $it; $what = "task $($it.path)"
        if ($e.Unknown) { $undecided++; Add-Result 'SKIP' $area $what '' 'the options are not recorded on this PC' $src; continue }
        $full = [string]$it.path; $n = $full.LastIndexOf('\')
        $task = $null
        try { $task = Get-ScheduledTask -TaskPath ($full.Substring(0, $n + 1)) -TaskName ($full.Substring($n + 1)) -ErrorAction Stop } catch { $task = $null }
        switch ([string]$it.operation) {
            'delete' { if ($task) { Add-Result 'FAIL' $area $what 'removed' 'still there' $src } else { Add-Result 'PASS' $area $what 'removed' 'not there' $src } }
            'disable' {
                if (-not $task) { Add-Result 'SKIP' $area $what '' 'not on this Windows' $src }
                elseif ([string]$task.State -eq 'Disabled') { Add-Result 'PASS' $area $what 'Disabled' 'Disabled' $src }
                else { Add-Result 'FAIL' $area $what 'Disabled' ([string]$task.State) $src }
            }
            'enable' {
                if (-not $task) { Add-Result 'SKIP' $area $what '' 'not on this Windows' $src }
                elseif ([string]$task.State -ne 'Disabled') { Add-Result 'PASS' $area $what 'enabled' ([string]$task.State) $src }
                else { Add-Result 'FAIL' $area $what 'enabled' 'Disabled' $src }
            }
            default { Add-Result 'SKIP' $area $what '' "operation '$($it.operation)' is not checked" $src }
        }
    }
    # Apps
    if ($apps.Count -gt 0) {
        $all = $null; $prov = $null
        try { $all = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { Add-Result 'WARN' $area 'Installed apps' '' "the list cannot be read: $($_.Exception.Message)" }
        try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { Add-Result 'WARN' $area 'Apps for new accounts' '' "the list cannot be read: $($_.Exception.Message)" }
        foreach ($e in $apps.Values) {
            $it = $e.Item; $src = Get-Source $it; $pat = [string]$it.name; $what = "app $pat"
            if ($e.Unknown) { $undecided++; Add-Result 'SKIP' $area $what '' 'the options are not recorded on this PC' $src; continue }
            if ($it.operation -ne 'remove') { Add-Result 'SKIP' $area $what '' "operation '$($it.operation)' is not checked" $src; continue }
            if ($null -eq $all) { continue }
            $found = @($all | Where-Object { $_.Name -like $pat -or $_.PackageFamilyName -like $pat })
            $installed = @(); $staged = @(); $system = @()
            foreach ($p in $found) {
                $states = @($p.PackageUserInformation | ForEach-Object { [string]$_.InstallState })
                if ($p.NonRemovable) { $system += $p.PackageFullName }
                elseif ($states.Count -eq 0 -or ($states -contains 'Installed')) { $installed += $p.PackageFullName }
                else { $staged += $p.PackageFullName }
            }
            $provHit = @(); if ($prov) { $provHit = @($prov | Where-Object { $_.DisplayName -like $pat } | ForEach-Object { $_.PackageName }) }
            if ($installed.Count -gt 0) { Add-Result 'FAIL' $area $what 'removed' ('installed: ' + ($installed -join ', ')) $src }
            elseif ($provHit.Count -gt 0) { Add-Result 'FAIL' $area $what 'removed for new accounts' ('still provisioned: ' + ($provHit -join ', ')) $src }
            elseif ($staged.Count -gt 0) { Add-Result 'WARN' $area $what 'removed' ('staged, not installed for any account: ' + ($staged -join ', ')) $src 'Windows keeps a staged copy; it is removed by the check at the next sign-in or by the next install.' }
            elseif ($system.Count -gt 0) { Add-Result 'SKIP' $area $what 'removed' ('Windows marks it as part of the system: ' + ($system -join ', ')) $src }
            else { Add-Result 'PASS' $area $what 'removed' 'not installed' $src }
        }
    }

    # Results of our scripts that leave a state to check
    $sarea = 'Script results'
    if ($script:OptionsKnown) {
        if ($script:Selected.Contains('power-plan')) {
            $plan = 'beff29ce-3f07-4f91-88d1-8ca5023c6112'
            $r = Invoke-Tool (Join-Path $env:SystemRoot 'System32\powercfg.exe') '/getactivescheme' 30
            if ($r.TimedOut) { Add-Result 'WARN' $sarea 'Active power plan' $plan 'powercfg did not answer' (Get-Source (Get-RunItem 'Set-PowerPlan.ps1')) }
            elseif ($r.Output -match $plan) { Add-Result 'PASS' $sarea 'Active power plan' 'Domain OS' 'Domain OS' (Get-Source (Get-RunItem 'Set-PowerPlan.ps1')) }
            else { Add-Result 'FAIL' $sarea 'Active power plan' "Domain OS ($plan)" ($r.Output.Trim() -replace '\s+', ' ') (Get-Source (Get-RunItem 'Set-PowerPlan.ps1')) 'Settings > System > Power, or run the playbook again.' }
        }
        if ($script:Selected.Contains('hibernate-off')) {
            $r = Read-RegValue $hklm 'SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
            $now = if ($r.Exists) { [string]$r.Data } else { 'not there' }
            if ($r.Exists -and [int]$r.Data -eq 0) { Add-Result 'PASS' $sarea 'Hibernation (HibernateEnabled)' '0' $now (Get-Source (Get-RunItem '' 'powercfg.exe')) }
            elseif (-not $r.Exists) { Add-Result 'PASS' $sarea 'Hibernation (HibernateEnabled)' '0' 'not there (no hibernation on this PC)' (Get-Source (Get-RunItem '' 'powercfg.exe')) }
            else { Add-Result 'FAIL' $sarea 'Hibernation (HibernateEnabled)' '0' $now (Get-Source (Get-RunItem '' 'powercfg.exe')) 'Run "powercfg /hibernate off" as administrator.' }
        }
        if ($script:Selected.Contains('install-scheduler')) {
            $exe = Join-Path $env:ProgramFiles 'Domain OS\DomainScheduler.exe'
            $t = $null; try { $t = Get-ScheduledTask -TaskPath '\' -TaskName 'DomainScheduler' -ErrorAction Stop } catch { }
            $src = Get-Source (Get-RunItem 'Install-DomainOS.ps1')
            foreach ($i in $manifest.items) { if ($i.kind -eq 'run' -and $i.script -eq 'Install-DomainOS.ps1' -and $i.args -match 'Scheduler') { $src = Get-Source $i } }
            if (-not $t) { Add-Result 'FAIL' $sarea 'Toolbox autostart task \DomainScheduler' 'registered' 'not there' $src }
            elseif ([string]$t.Actions[0].Execute -ne $exe) { Add-Result 'FAIL' $sarea 'Toolbox autostart task \DomainScheduler' $exe ([string]$t.Actions[0].Execute) $src }
            elseif (-not (Test-Path -LiteralPath $exe)) { Add-Result 'FAIL' $sarea 'Toolbox program' $exe 'not there' $src }
            else { Add-Result 'PASS' $sarea 'Toolbox autostart task \DomainScheduler' $exe $exe $src }
        }
    }
    if ($notChosen -gt 0) { Add-Result 'INFO' $area "$notChosen action(s) belong to options that were not chosen (or to another Windows build): not expected" }
    if ($undecided -gt 0) { Add-Result 'WARN' $area "$undecided item(s) depend on options, and the chosen options are not recorded on this PC" '' '' '' 'Installed by a version before the options were recorded: apply the playbook again to check everything.' }
}

# ======================================================================================================================
# The extra checks of the interactive mode
# ======================================================================================================================
function Test-DataFolder {
    $area = 'Domain OS data folder'
    $d = $DomainOSData
    if (-not (Test-Path -LiteralPath $d)) { Add-Result 'FAIL' $area $d 'there' 'not there' '' 'Apply the playbook: it creates the folder with its protection.'; return }
    $root = Get-Item -LiteralPath $d -Force
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Add-Result 'FAIL' $area $d 'a folder' 'a link or a file' '' 'Remove it and apply the playbook again.'; return }
    $owner = Get-DomainOSOwner $d
    if ($DomainOSTrustedOwners -contains $owner) { Add-Result 'PASS' $area "$d owner" 'SYSTEM, Administrators or TrustedInstaller' $owner }
    else { Add-Result 'FAIL' $area "$d owner" 'SYSTEM, Administrators or TrustedInstaller' $owner '' 'Apply the playbook again (it repairs the folder), or run Undo Domain OS, which does the same.' }
    $acl = Get-Acl -LiteralPath $d
    if ($acl.AreAccessRulesProtected) { Add-Result 'PASS' $area "$d inheritance" 'off' 'off' } else { Add-Result 'FAIL' $area "$d inheritance" 'off' 'on' '' 'Apply the playbook again: it sets the folder''s own permissions.' }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    foreach ($need in @(@($DomainOSSidSystem, 'FullControl', 'SYSTEM'), @($DomainOSSidAdmins, 'FullControl', 'Administrators'), @($DomainOSSidUsers, 'ReadAndExecute', 'Users'))) {
        $r = @($rules | Where-Object { $_.IdentityReference.Value -eq $need[0] -and $_.AccessControlType -eq 'Allow' -and (([int]$_.FileSystemRights -band [int][System.Security.AccessControl.FileSystemRights]$need[1]) -eq [int][System.Security.AccessControl.FileSystemRights]$need[1]) })
        if ($r.Count -gt 0) { Add-Result 'PASS' $area "$($need[2]): $($need[1])" $need[1] 'set' } else { Add-Result 'FAIL' $area "$($need[2]): $($need[1])" $need[1] 'missing' '' 'Apply the playbook again.' }
    }
    $writers = @($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and ($DomainOSTrustedOwners -notcontains $_.IdentityReference.Value) -and (([long]$_.FileSystemRights -band $DomainOSWriteRights) -ne 0) })
    if ($writers.Count -gt 0) { Add-Result 'FAIL' $area "$d write rights" 'only SYSTEM, Administrators, TrustedInstaller' (($writers | ForEach-Object { $_.IdentityReference.Value + ' ' + $_.FileSystemRights }) -join '; ') '' 'Apply the playbook again: it removes them.' }
    else { Add-Result 'PASS' $area "$d write rights" 'only SYSTEM, Administrators, TrustedInstaller' 'as expected' }
    # Inside: no links, no write rights for other accounts, files of standard accounts are noted (Domain OS ignores them).
    $links = 0; $foreignWrite = 0; $foreignFiles = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($d)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($c in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { $links++; Add-Result 'FAIL' $area "link inside the data folder: $($c.FullName)" 'no links' 'a link' '' 'Apply the playbook again: it removes links there.'; continue }
            try {
                $a = Get-Acl -LiteralPath $c.FullName
                $w = @($a.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' -and ($DomainOSTrustedOwners -notcontains $_.IdentityReference.Value) -and (([long]$_.FileSystemRights -band $DomainOSWriteRights) -ne 0) })
                # The saved wallpaper folder is readable by its own account only; nobody else gets write rights anywhere.
                if ($w.Count -gt 0) { $foreignWrite++; Add-Result 'FAIL' $area "write rights on $($c.FullName)" 'none for other accounts' (($w | ForEach-Object { $_.IdentityReference.Value }) -join ', ') '' 'Apply the playbook again.' }
                $o = $a.GetOwner([Security.Principal.SecurityIdentifier]).Value
                if (-not (Get-DomainOSAdminSids).Contains($o)) { $foreignFiles++; Add-Result 'WARN' $area "$($c.FullName) belongs to $o" 'an administrator account or Windows' $o '' 'Not written by Domain OS, so it is never used. Delete it if you do not know it.' }
            } catch { Add-Result 'WARN' $area "$($c.FullName)" '' "permissions cannot be read: $($_.Exception.Message)" }
            if ($c.PSIsContainer) { $stack.Push($c.FullName) }
        }
    }
    if ($links -eq 0 -and $foreignWrite -eq 0 -and $foreignFiles -eq 0) { Add-Result 'PASS' $area 'Files and folders inside' 'no links, no foreign owners or write rights' 'as expected' }
}

function Test-UndoReadiness {
    $area = 'Undo Domain OS'
    $applied = ($history.State -eq 'applied')
    # Saved state
    $undo = Join-Path $DomainOSData 'Undo'
    foreach ($f in 'state.json', 'state.original.json') {
        $p = Join-Path $undo $f
        if (-not (Test-Path -LiteralPath $p)) {
            if ($applied) { Add-Result 'FAIL' $area "saved state $f" 'there' 'not there' '' 'Without it Undo cannot put Windows back. Apply the playbook again only if you are sure the PC is still as it was before Domain OS; otherwise ask for help.' }
            else { Add-Result 'INFO' $area "saved state $f" '' 'not there (Domain OS is not applied: a new install saves a fresh one)' }
            continue
        }
        if (-not (Test-DomainOSFile $p)) { Add-Result 'FAIL' $area "saved state $f" 'written by Domain OS (trusted owner, not a link)' 'refused (see the notes)' '' 'Undo will not use it. Apply the playbook again: it repairs the folder.'; continue }
        try {
            $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $s.saved -or -not ($s.PSObject.Properties.Name -contains 'registry')) { throw 'damaged or cut short' }
            Add-Result 'PASS' $area "saved state $f" 'readable' ("saved $($s.saved), $(@($s.registry).Count) values, $(@($s.services).Count) services, $(@($s.tasks).Count) tasks")
        } catch { Add-Result 'FAIL' $area "saved state $f" 'readable' $_.Exception.Message '' 'state.original.json is a second copy of the original: ask for help before deleting anything.' }
    }
    # Tools
    foreach ($f in 'Undo-DomainOS.ps1', 'Undo-AsSystem.ps1', 'DomainOS-Common.ps1', 'Check-DomainOS.ps1', 'expected.json', 'undo-allowlist.txt') {
        $p = Join-Path $toolsDir $f
        if (-not (Test-Path -LiteralPath $p)) { Add-Result 'FAIL' $area "tool $f" "in $toolsDir" 'not there' '' 'Apply the playbook again: it installs the tools first, before any change.' }
        elseif (-not (Test-DomainOSFile $p)) { Add-Result 'FAIL' $area "tool $f" 'trusted owner' 'refused (see the notes)' '' 'Apply the playbook again.' }
        else { Add-Result 'PASS' $area "tool $f" 'there, trusted owner' (Get-DomainOSOwner $p) }
    }
    # Allow-list covers every registry value, service and task of expected.json
    $list = Join-Path $toolsDir 'undo-allowlist.txt'
    if ((Test-Path -LiteralPath $list) -and (Test-DomainOSFile $list) -and $manifest) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($l in @(Get-Content -LiteralPath $list -Encoding UTF8)) { if ($l) { [void]$set.Add($l) } }
        $missing = New-Object System.Collections.Generic.List[string]; $n = 0
        foreach ($it in $manifest.items) {
            $line = $null
            if ($it.kind -eq 'registryValue' -and [string]$it.value -and [string]$it.path -notlike 'HKLM\SOFTWARE\Domain OS*') { $line = "R|$($it.path)|$($it.value)" }
            elseif ($it.kind -eq 'service') { $line = "S|$($it.name)" }
            elseif ($it.kind -eq 'scheduledTask') { $line = "T|$($it.path)" }
            if ($line) { $n++; if (-not $set.Contains($line)) { $missing.Add("$line ($(Get-Source $it))") } }
        }
        if ($missing.Count -eq 0) { Add-Result 'PASS' $area 'undo-allowlist.txt covers every value, service and task of the playbook' "$n items" "$($set.Count) lines" }
        else { Add-Result 'FAIL' $area 'undo-allowlist.txt does not cover everything the playbook changes' "$n items" ("missing: " + (($missing | Select-Object -First 10) -join '; ') + $(if ($missing.Count -gt 10) { " and $($missing.Count - 10) more" } else { '' })) '' 'Apply the playbook again: it writes the list from its task files.' }
        $own = @($set | Where-Object { $_ -like 'R|HKLM\SOFTWARE\Domain OS*' })
        if ($own.Count -gt 0) { Add-Result 'FAIL' $area 'undo-allowlist.txt lists Domain OS'' own record' 'nothing under HKLM\SOFTWARE\Domain OS' ($own -join '; ') }
    }
    # Dry run of Undo: shows what it would do and changes nothing (-WhatIf).
    $undoScript = Join-Path $toolsDir 'Undo-DomainOS.ps1'
    if (-not $applied) { Add-Result 'SKIP' $area 'Dry run of Undo (-WhatIf)' '' 'Domain OS is not applied: nothing to undo' }
    elseif (-not (Test-Path -LiteralPath $undoScript)) { Add-Result 'SKIP' $area 'Dry run of Undo (-WhatIf)' '' 'Undo-DomainOS.ps1 is not there (reported above)' }
    else {
        if (-not $AfterInstall) { Write-Host '  Dry run of Undo Domain OS (-WhatIf, changes nothing) ...' }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-Tool $ps "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$undoScript`" -WhatIf" 240
        if ($r.TimedOut) { Add-Result 'WARN' $area 'Dry run of Undo (-WhatIf)' 'finishes' 'no answer within 4 minutes' '' 'Run Undo Domain OS with -WhatIf by hand to see where it stops.' }
        else {
            $lines = @($r.Output -split "\r?\n")
            # case-sensitive (-cmatch): the summary line "Failed: 0" is not a failure
            $failedLines = @($lines | Where-Object { $_ -cmatch '\bFAILED\b' })
            $would = @($lines | Where-Object { $_ -match '^What if:' -and $_ -notmatch 'Add Content' }).Count
            $skipped = @($lines | Where-Object { $_ -match '^Skipped ' }).Count
            foreach ($l in $failedLines) { Add-Result 'FAIL' $area 'Undo dry run' 'no failure' $l.Trim() '' 'Undo would not put this back: run the check again after a restart; if it stays, apply the playbook again (the original state is kept) or ask for help.' }
            if ($r.ExitCode -ne 0 -and $failedLines.Count -eq 0) { Add-Result 'FAIL' $area 'Undo dry run' 'exit code 0' "exit code $($r.ExitCode): $((($lines | Where-Object { $_.Trim() }) | Select-Object -Last 2) -join ' ')" }
            if ($r.ExitCode -eq 0 -and $failedLines.Count -eq 0) { Add-Result 'PASS' $area 'Undo dry run (-WhatIf)' 'no failure' "$would change(s) it would make, $skipped saved item(s) it skips" }
        }
    }
}

function Test-DomainOSTasks {
    $area = 'Domain OS scheduled tasks'
    $usersSid = $DomainOSSidUsers
    $list = @()
    try { $list = @(Get-ScheduledTask -TaskPath '\Domain OS\' -ErrorAction Stop) } catch { $list = @() }
    if ($list.Count -eq 0) { Add-Result 'INFO' $area '\Domain OS\ holds no task' '' 'the one-time pages (driver guide, What''s new) were shown or expired after 14 days' }
    foreach ($t in $list) {
        $what = "\Domain OS\$($t.TaskName)"
        $gid = [string]$t.Principal.GroupId; $gsid = ''
        try { $gsid = (New-Object Security.Principal.NTAccount($gid)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { try { $gsid = (New-Object Security.Principal.SecurityIdentifier($gid)).Value } catch { } }
        $act = $t.Actions[0]
        $problems = @()
        if ($gsid -ne $usersSid) { $problems += "runs for '$gid' instead of the group Users" }
        if ([string]$t.Principal.RunLevel -ne 'Limited') { $problems += "run level $($t.Principal.RunLevel) instead of Limited (normal rights)" }
        if ([string]$act.Execute -notlike '*\conhost.exe' -or ([string]$act.Arguments) -notlike '--headless *') { $problems += "starts '$($act.Execute)' instead of conhost --headless" }
        if ($problems.Count -eq 0) { Add-Result 'PASS' $area $what 'Users, normal rights, conhost --headless' 'as expected' }
        else { Add-Result 'FAIL' $area $what 'Users, normal rights, conhost --headless' ($problems -join '; ') '' 'Apply the playbook again: it registers these tasks again.' }
    }
    foreach ($n in 'Domain OS Undo (SYSTEM, one-shot)', 'Domain OS start Explorer', 'Domain OS Start pins cleanup') {
        $t = $null; try { $t = Get-ScheduledTask -TaskPath '\' -TaskName $n -ErrorAction Stop } catch { }
        if ($t) { Add-Result 'WARN' $area "left-over task \$n" 'not there' 'there' '' 'A one-time helper that should have removed itself: delete it in Task Scheduler.' }
    }
    # Toolbox
    $exe = Join-Path $env:ProgramFiles 'Domain OS\DomainScheduler.exe'
    $chosen = Test-Option 'install-scheduler'
    $t = $null; try { $t = Get-ScheduledTask -TaskPath '\' -TaskName 'DomainScheduler' -ErrorAction Stop } catch { }
    if (Test-Path -LiteralPath $exe) {
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        Add-Result 'INFO' $area 'Domain OS Toolbox version' '' ("{0} (file {1})" -f $vi.ProductVersion, $vi.FileVersion)
        if ($t) {
            if ([string]$t.Actions[0].Execute -eq $exe) { Add-Result 'PASS' $area 'Toolbox autostart \DomainScheduler' $exe ("$($t.State)") }
            else { Add-Result 'FAIL' $area 'Toolbox autostart \DomainScheduler' $exe ([string]$t.Actions[0].Execute) '' 'Apply the playbook again with the Domain OS app ticked.' }
        } elseif ($chosen -eq $true) { Add-Result 'FAIL' $area 'Toolbox autostart \DomainScheduler' 'registered' 'not there' '' 'Apply the playbook again with the Domain OS app ticked.' }
        else { Add-Result 'INFO' $area 'Toolbox autostart \DomainScheduler' '' 'not registered (the app does not start with Windows)' }
    } elseif ($chosen -eq $true) { Add-Result 'FAIL' $area 'Domain OS Toolbox' $exe 'not there' '' 'Apply the playbook again with the Domain OS app ticked.' }
    else { Add-Result 'INFO' $area 'Domain OS Toolbox' '' 'not installed (option not chosen)' }
}

function Test-InstallRecord {
    $area = 'Installed version and logs'
    if ($manifest) { Add-Result 'INFO' $area 'Domain OS version of this check' '' ([string]$manifest.version) }
    switch ($history.State) {
        'applied' {
            if ($manifest -and $history.Version -eq [string]$manifest.version) { Add-Result 'PASS' $area 'Version applied last (history.log)' ([string]$manifest.version) "$($history.Version), $($history.When)" }
            elseif ($manifest) { Add-Result 'WARN' $area 'Version applied last (history.log)' ([string]$manifest.version) "$($history.Version), $($history.When)" '' 'The check and the applied playbook are different versions: apply the newest playbook again.' }
        }
        'undone' { Add-Result 'INFO' $area 'Domain OS was undone' '' "$($history.When): $($history.Version)" }
        default { Add-Result 'INFO' $area 'history.log' '' 'no install recorded' }
    }
    if ($script:OptionsKnown) { Add-Result 'INFO' $area 'Options chosen at the install' '' $(if ($script:Selected.Count) { (@($script:Selected) | Sort-Object) -join ', ' } else { 'none' }) }
    elseif ($history.State -eq 'applied') { Add-Result 'WARN' $area 'Options chosen at the install' 'recorded in HKLM\SOFTWARE\Domain OS\Options' 'not recorded' '' 'Installed by an earlier version: apply the playbook again so everything can be checked.' }
    # FAILED lines of the last install (install.log, from the last "[Edition]" line on)
    $log = Join-Path $logDir 'install.log'
    if (Test-Path -LiteralPath $log) {
        $lines = @(Get-Content -LiteralPath $log -Encoding UTF8 -ErrorAction SilentlyContinue)
        $start = 0
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '\[Edition\]') { $start = $i; break } }
        # case-sensitive (-cmatch): the summary line "Failed: 0" is not a failure
        $bad = @($lines[$start..($lines.Count - 1)] | Where-Object { $_ -cmatch '\bFAILED\b' })
        foreach ($l in ($bad | Select-Object -First 20)) { Add-Result 'FAIL' $area 'install.log (last install)' 'no FAILED line' $l.Trim() '' 'The install stopped or a step failed here: fix the cause named in the line and apply the playbook again.' }
        if ($bad.Count -eq 0) { Add-Result 'PASS' $area 'install.log (last install)' 'no FAILED line' 'none' }
    }
    $rlog = Join-Path $logDir 'runtimes.log'
    if (Test-Path -LiteralPath $rlog) {
        $lines = @(Get-Content -LiteralPath $rlog -Encoding UTF8 -ErrorAction SilentlyContinue)
        $start = 0
        for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '--- Domain OS runtimes ---') { $start = $i; break } }
        # case-sensitive (-cmatch): the summary line "Failed: 0" is not a failure
        $bad = @($lines[$start..($lines.Count - 1)] | Where-Object { $_ -cmatch '\bFAILED\b' })
        foreach ($l in $bad) { Add-Result 'WARN' $area 'runtimes.log (last run)' 'no FAILED line' $l.Trim() '' 'Start > Domain OS > Install runtimes tries again.' }
    }
    $clog = Join-Path $logDir 'check.log'
    if (Test-Path -LiteralPath $clog) {
        $last = @(Get-Content -LiteralPath $clog -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^Result:' } | Select-Object -Last 1)
        if ($last.Count) { Add-Result 'INFO' $area 'Check at the end of the last install (check.log)' '' $last[0] }
    }
    # Errors of Domain OS programs in the event logs (last 24 h): crashes of the Toolbox, PowerShell errors of our scripts.
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 3000 -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -like '*Domain*' -or $_.Message -match 'DomainScheduler|Domain OS' })
        foreach ($e in ($ev | Select-Object -First 10)) { Add-Result 'WARN' $area "Event $($e.ProviderName) $($e.Id) at $($e.TimeCreated)" '' ((([string]$e.Message) -split "`n")[0].Trim()) '' 'An error of a Domain OS program: send this report when you ask for help.' }
        if ($ev.Count -eq 0) { Add-Result 'PASS' $area 'Event logs: errors of Domain OS programs (24 h)' 'none' 'none' }
    } catch { Add-Result 'WARN' $area 'Event logs' '' "cannot be read: $($_.Exception.Message)" }
}

# ---- Windows health (interactive only; read-only, each with a time limit) -------------------------------------------
function Test-WindowsHealth {
    $area = 'Windows health'
    if (-not $Quick) {
        if (-not $AfterInstall) { Write-Host '  DISM CheckHealth (up to 5 minutes) ...' }
        $r = Invoke-WithTimeout { (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState.ToString() } 300
        if (-not $r.Ok) { Add-Result 'WARN' $area 'Component store (DISM CheckHealth)' '' "could not run: $($r.Error)" }
        else {
            $h = [string](@($r.Data)[-1])
            if ($h -eq 'Healthy') { Add-Result 'PASS' $area 'Component store (DISM CheckHealth)' 'Healthy' $h }
            elseif ($h -eq 'Repairable') { Add-Result 'FAIL' $area 'Component store (DISM CheckHealth)' 'Healthy' $h '' 'Run as administrator: DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow, then restart.' }
            else { Add-Result 'FAIL' $area 'Component store (DISM CheckHealth)' 'Healthy' $h '' 'Windows cannot repair itself: an in-place upgrade (Windows setup, "keep files and apps") fixes it.' }
        }
        if (-not $AfterInstall) { Write-Host '  sfc /verifyonly (can take several minutes) ...' }
        $since = Get-Date
        $r = Invoke-Tool (Join-Path $env:SystemRoot 'System32\sfc.exe') '/verifyonly' 1800 ([Text.Encoding]::Unicode)
        if ($r.TimedOut) { Add-Result 'WARN' $area 'System files (sfc /verifyonly)' '' 'no answer within 30 minutes' }
        else {
            $out = ($r.Output -replace "`0", '')
            # The result is in CBS.log in English whatever the display language: "[SR]" lines of this run.
            $sr = @()
            try {
                $fs = New-Object IO.FileStream((Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
                try {
                    if ($fs.Length -gt 8MB) { [void]$fs.Seek(-8MB, [IO.SeekOrigin]::End) }
                    $from = $since.AddSeconds(-5).ToString('yyyy-MM-dd HH:mm:ss')
                    # CBS.log lines start with "yyyy-MM-dd HH:mm:ss": compared as text, which sorts like the time.
                    $sr = @(((New-Object IO.StreamReader($fs)).ReadToEnd() -split "\r?\n") | Where-Object {
                        $_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[SR\]' -and [string]::CompareOrdinal($Matches[1], $from) -ge 0 })
                } finally { $fs.Dispose() }
            } catch { }
            $corrupt = @($sr | Where-Object { $_ -match 'corrupt|do not match|Cannot repair|could not' })
            if ($out -match 'did not find any integrity violations' -or ($sr.Count -gt 0 -and $corrupt.Count -eq 0 -and ($sr -match 'Verify complete'))) { Add-Result 'PASS' $area 'System files (sfc /verifyonly)' 'no integrity violations' 'none found' }
            elseif ($out -match 'found integrity violations' -or $corrupt.Count -gt 0) { Add-Result 'FAIL' $area 'System files (sfc /verifyonly)' 'no integrity violations' "violations found ($($corrupt.Count) lines in CBS.log)" '' 'Run as administrator: DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow, then restart.' }
            elseif ($out -match 'could not perform|could not start') { Add-Result 'WARN' $area 'System files (sfc /verifyonly)' '' (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) -join '') '' 'The Windows Modules Installer service (TrustedInstaller) must be able to start (Manual).' }
            else { Add-Result 'WARN' $area 'System files (sfc /verifyonly)' '' "result not recognised (exit code $($r.ExitCode)); see %WINDIR%\Logs\CBS\CBS.log" }
        }
    } else { Add-Result 'SKIP' $area 'DISM CheckHealth and sfc /verifyonly' '' 'left out (-Quick)' }

    # Devices with a driver problem
    try {
        $dev = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -OperationTimeoutSec 60 -ErrorAction Stop)
        foreach ($d in $dev) {
            $code = [int]$d.ConfigManagerErrorCode
            $name = if ($d.Name) { $d.Name } else { $d.DeviceID }
            if ($code -eq 22) { Add-Result 'INFO' $area "Device switched off: $name" '' 'code 22 (disabled in Device Manager)' }
            elseif ($code -eq 45) { Add-Result 'INFO' $area "Device not connected: $name" '' 'code 45' }
            elseif ($code -eq 28) { Add-Result 'WARN' $area "Device without a driver: $name" 'a driver' 'code 28' '' 'Install the driver from the maker of the device or the motherboard (see the driver guide).' }
            else { Add-Result 'WARN' $area "Device with a problem: $name" 'code 0' "code $code" '' 'Device Manager shows the reason; reinstalling the maker''s driver usually fixes it.' }
        }
        if ($dev.Count -eq 0) { Add-Result 'PASS' $area 'Devices with a driver problem' 'none' 'none' }
    } catch { Add-Result 'WARN' $area 'Devices' '' "cannot be listed: $($_.Exception.Message)" }

    # Pending restart
    $pending = @()
    if (Test-RegKey $hklm 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending += 'Windows components' }
    if (Test-RegKey $hklm 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending += 'Windows Update' }
    if ((Read-RegValue $hklm 'SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations').Exists) { $pending += 'files to replace at the next start' }
    if ($pending.Count -gt 0) { Add-Result 'WARN' $area 'Restart pending' 'none' ($pending -join ', ') '' 'Restart the computer (after an install of Domain OS this is expected).' }
    else { Add-Result 'PASS' $area 'Restart pending' 'none' 'none' }

    # Windows Update (no scan is started)
    try {
        $wu = Get-Service -Name 'wuauserv' -ErrorAction Stop
        $st = [string](Read-RegValue $hklm 'SYSTEM\CurrentControlSet\Services\wuauserv' 'Start').Data
        if ($st -eq '4') { Add-Result 'FAIL' $area 'Windows Update service' 'not disabled' 'disabled' '' 'Domain OS never switches it off: another tool did. Security updates do not arrive; set it back to Manual.' }
        else { Add-Result 'PASS' $area 'Windows Update service' 'not disabled' ("start type $st, $($wu.Status)") }
    } catch { Add-Result 'FAIL' $area 'Windows Update service' 'there' 'not there' '' 'Windows Update was removed by another tool: an in-place upgrade brings it back.' }
    try {
        $res = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results
        foreach ($p in @(@('LastSearchSuccessDate', 'Last successful search for updates'), @('LastInstallationSuccessDate', 'Last successful update install'))) {
            $d = $res.($p[0])
            if (-not $d -or ([datetime]$d).Year -lt 2000) { Add-Result 'WARN' $area $p[1] 'within 14 days' 'never' '' 'Settings > Windows Update > Check for updates.' }
            elseif (([datetime]$d) -lt (Get-Date).AddDays(-14)) { Add-Result 'WARN' $area $p[1] 'within 14 days' ([datetime]$d).ToString('yyyy-MM-dd') '' 'Settings > Windows Update > Check for updates.' }
            else { Add-Result 'PASS' $area $p[1] 'within 14 days' ([datetime]$d).ToString('yyyy-MM-dd') }
        }
    } catch { Add-Result 'WARN' $area 'Windows Update history' '' "cannot be read: $($_.Exception.Message)" }

    # Disks
    $r = Invoke-WithTimeout {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $c = $null; try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
            [pscustomobject]@{ Name = $d.FriendlyName; Health = [string]$d.HealthStatus; Status = (@($d.OperationalStatus) -join ','); Media = [string]$d.MediaType
                Wear = $(if ($c) { $c.Wear } else { $null }); Temp = $(if ($c) { $c.Temperature } else { $null }); ReadErr = $(if ($c) { $c.ReadErrorsUncorrected } else { $null }) }
        }
    } 90
    if (-not $r.Ok) { Add-Result 'WARN' $area 'Disks' '' "cannot be read: $($r.Error)" }
    else {
        foreach ($d in @($r.Data)) {
            $extra = @()
            if ($null -ne $d.Wear) { $extra += "wear $($d.Wear)%" }
            if ($null -ne $d.Temp -and [int]$d.Temp -gt 0) { $extra += "$($d.Temp) C" }
            if ($null -ne $d.ReadErr -and [long]$d.ReadErr -gt 0) { $extra += "$($d.ReadErr) uncorrected read errors" }
            $txt = "$($d.Health), $($d.Status)" + $(if ($extra.Count) { ', ' + ($extra -join ', ') } else { '' })
            if ($d.Health -ne 'Healthy') { Add-Result 'FAIL' $area "Disk $($d.Name)" 'Healthy' $txt '' 'Back up your files now and check the disk with its maker''s tool.' }
            elseif (($null -ne $d.Wear -and [int]$d.Wear -ge 90) -or ($null -ne $d.ReadErr -and [long]$d.ReadErr -gt 0)) { Add-Result 'WARN' $area "Disk $($d.Name)" 'Healthy, little wear' $txt '' 'Keep a backup; check the disk with its maker''s tool.' }
            else { Add-Result 'PASS' $area "Disk $($d.Name)" 'Healthy' $txt }
        }
    }

    # Free space on the system drive
    try {
        $ld = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -OperationTimeoutSec 30 -ErrorAction Stop
        $free = [math]::Round($ld.FreeSpace / 1GB, 1); $pct = [math]::Round(100 * $ld.FreeSpace / $ld.Size)
        $txt = "$free GB free ($pct %)"
        if ($free -lt 5) { Add-Result 'FAIL' $area "Free space on $($env:SystemDrive)" 'at least 20 GB' $txt '' 'Windows updates and games need room: empty the Recycle Bin, run Disk Cleanup, move or uninstall games.' }
        elseif ($free -lt 20 -or $pct -lt 10) { Add-Result 'WARN' $area "Free space on $($env:SystemDrive)" 'at least 20 GB' $txt '' 'Free some space: Settings > System > Storage.' }
        else { Add-Result 'PASS' $area "Free space on $($env:SystemDrive)" 'at least 20 GB' $txt }
    } catch { Add-Result 'WARN' $area 'Free space' '' "cannot be read: $($_.Exception.Message)" }

    # Unexpected shutdowns and blue screens (7 days)
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008, 1001; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue | Where-Object {
            ($_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power') -or ($_.Id -eq 6008 -and $_.ProviderName -eq 'EventLog') -or ($_.Id -eq 1001 -and $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck') })
        $bsod = @($ev | Where-Object { $_.Id -eq 1001 })
        $lost = @($ev | Where-Object { $_.Id -ne 1001 })
        if ($bsod.Count -gt 0) { Add-Result 'FAIL' $area 'Blue screens (7 days)' 'none' ("$($bsod.Count): " + (($bsod | Select-Object -First 5 | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') }) -join ', ')) '' 'The stop code is in the event (Event Viewer > System, ID 1001); a driver, overclock or memory (XMP/EXPO) is the usual cause.' }
        if ($lost.Count -gt 0) { Add-Result 'WARN' $area 'Unexpected shutdowns (7 days)' 'none' ("$($lost.Count): " + (($lost | Select-Object -First 5 | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') + " ID $($_.Id)" }) -join ', ')) '' 'Power loss, a hard reset, or a crash without a blue screen (power supply, overclock, overheating).' }
        if ($ev.Count -eq 0) { Add-Result 'PASS' $area 'Blue screens and unexpected shutdowns (7 days)' 'none' 'none' }
    } catch { Add-Result 'WARN' $area 'Shutdown history' '' "cannot be read: $($_.Exception.Message)" }

    # Critical and error events of 24 h, grouped by source and ID (top 20)
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 5000 -ErrorAction SilentlyContinue)
        $groups = @($ev | Group-Object -Property { "$($_.LogName) | $($_.ProviderName) | $($_.Id)" } | Sort-Object Count -Descending | Select-Object -First 20)
        foreach ($g in $groups) {
            $msg = (([string]$g.Group[0].Message) -split "`n")[0].Trim()
            if ($msg.Length -gt 140) { $msg = $msg.Substring(0, 140) + '...' }
            Add-Result 'INFO' 'Errors in the event logs (24 h)' "$($g.Count) x $($g.Name)" '' $msg
        }
        if ($ev.Count -eq 0) { Add-Result 'PASS' 'Errors in the event logs (24 h)' 'Critical and error events' '' 'none' }
        else { Add-Result 'INFO' 'Errors in the event logs (24 h)' "$($ev.Count) critical/error events in total" '' 'Many are harmless (services that time out at start, apps that close badly); look closer at ones that repeat or match a problem you see.' }
    } catch { Add-Result 'WARN' $area 'Event logs' '' "cannot be read: $($_.Exception.Message)" }
}

# ======================================================================================================================
# Run
# ======================================================================================================================
$started = Get-Date
if (-not $AfterInstall) {
    Write-Host 'Check Domain OS - reads only, changes nothing.' -ForegroundColor Cyan
}
if (-not $isAdmin) { Add-Result 'FAIL' 'Domain OS' 'Administrator rights' 'yes' 'no' '' 'Run the check as administrator (the Start menu shortcut asks for it).' }

if ($AfterInstall) {
    # The manifest must belong to these task files and this version (a stale expected.json would check the wrong things).
    if ($manifest) {
        $conf = Join-Path $here '..\playbook.conf'
        if (Test-Path -LiteralPath $conf) {
            $v = ''; if ((Get-Content -Raw -Encoding UTF8 -LiteralPath $conf) -match '<Version>([^<]+)</Version>') { $v = $Matches[1] }
            if ($v -ne [string]$manifest.version) { Add-Result 'FAIL' 'Domain OS' 'expected.json belongs to this playbook' $v ([string]$manifest.version) '' 'A broken build: expected.json was not generated (tools/gen-expected.py).' }
        }
        foreach ($p in $manifest.taskFiles.PSObject.Properties) {
            $f = Join-Path $here ('..\Configuration\' + ($p.Name -replace '/', '\'))
            if (-not (Test-Path -LiteralPath $f)) { continue }
            if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne [string]$p.Value) { Add-Result 'FAIL' 'Domain OS' "expected.json matches $($p.Name)" 'the same file' 'the task file was changed after expected.json was generated' '' 'A broken build: run tools/gen-expected.py (build.sh does) and build again.' }
        }
    }
    if (-not $script:OptionsKnown) { Add-Result 'FAIL' 'Domain OS' 'Chosen options recorded (HKLM\SOFTWARE\Domain OS\Options)' 'there' 'not there' '' 'Tasks\options.yml did not run.' }
    if (-not $script:UserHive) { Add-Result 'WARN' 'Domain OS' 'Signed-in user registry' 'readable' 'not found' '' 'Per-user values are not checked.' }
    Test-ExpectedState
} else {
    Write-Section 'Domain OS'
    Test-InstallRecord
    if ($history.State -eq 'applied') {
        Write-Section 'Expected changes'
        Test-ExpectedState
    } else { Add-Result 'SKIP' 'Expected changes' 'The changes of the playbook' '' 'Domain OS is not applied on this PC (or was undone): nothing to compare' }
    Write-Section 'Data folder and Undo'
    Test-DataFolder
    Test-UndoReadiness
    Test-DomainOSTasks
    Write-Section 'Windows health'
    Test-WindowsHealth
}

# ---- report ------------------------------------------------------------------------------------------------------------
$count = @{}
foreach ($s in 'PASS', 'INFO', 'SKIP', 'WARN', 'FAIL') { $count[$s] = @($script:Results | Where-Object { $_.Status -eq $s }).Count }
function Format-Result($r) {
    $t = '{0,-4}  {1}' -f $r.Status, $r.What
    if ($r.Expected -or $r.Actual) {
        if ($r.Expected) { $t += " | expected: $($r.Expected)" }
        $t += " | found: $($r.Actual)"
    }
    if ($r.Source) { $t += " | $($r.Source)" }
    return $t
}
$summary = "Result: $($count.FAIL) FAIL, $($count.WARN) WARN, $($count.PASS) PASS, $($count.SKIP) SKIP, $($count.INFO) INFO"
$head = @(
    "Domain OS check, $($started.ToString('yyyy-MM-dd HH:mm:ss'))$(if ($AfterInstall) { ' (after install)' } else { '' })",
    "Computer: $env:COMPUTERNAME, Windows $displayVersion build $build.$ubr, $edition",
    "Domain OS: $(if ($manifest) { $manifest.version } else { '?' }) (applied last: $($history.Version) $($history.When), state: $($history.State))",
    "Per-user values read from: $(if ($userHiveName) { $userHiveName } else { 'none' })",
    "Options: $(if ($script:OptionsKnown) { (@($script:Selected) | Sort-Object) -join ', ' } else { 'not recorded' })",
    $summary, '')
$body = New-Object System.Collections.Generic.List[string]
foreach ($area in @($script:Results | ForEach-Object { $_.Area } | Select-Object -Unique)) {
    $body.Add("== $area")
    # Problems first, then the rest.
    foreach ($s in 'FAIL', 'WARN', 'INFO', 'PASS', 'SKIP') {
        foreach ($r in @($script:Results | Where-Object { $_.Area -eq $area -and $_.Status -eq $s })) {
            $body.Add((Format-Result $r))
            if ($r.Advice -and ($s -eq 'FAIL' -or $s -eq 'WARN')) { $body.Add("      -> $($r.Advice)") }
        }
    }
    $body.Add('')
}
if ($script:Notes.Count -gt 0) { $body.Add('== Notes'); foreach ($n in $script:Notes) { $body.Add($n) }; $body.Add('') }

if ($AfterInstall) {
    # One line per problem on the console (AME Wizard keeps it in its log), the full list in check.log.
    foreach ($r in @($script:Results | Where-Object { $_.Status -eq 'FAIL' })) { Write-Host (Format-Result $r) }
    foreach ($r in @($script:Results | Where-Object { $_.Status -eq 'WARN' })) { Write-Host (Format-Result $r) }
    Write-Host $summary
    try {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        Add-Content -LiteralPath (Join-Path $logDir 'check.log') -Value (@('----------------------------------------------------------------') + $head + $body) -Encoding UTF8
        Write-Host "Report: $(Join-Path $logDir 'check.log')"
    } catch { Write-Host "check.log could not be written: $($_.Exception.Message)" }
    if ($count.FAIL -gt 0) { exit 1 }
    exit 0
}

Write-Host ''
Write-Host '================ Summary ================' -ForegroundColor Cyan
foreach ($r in @($script:Results | Where-Object { $_.Status -eq 'FAIL' })) { Write-Host (Format-Result $r) -ForegroundColor Red; if ($r.Advice) { Write-Host "      -> $($r.Advice)" } }
foreach ($r in @($script:Results | Where-Object { $_.Status -eq 'WARN' })) { Write-Host (Format-Result $r) -ForegroundColor Yellow; if ($r.Advice) { Write-Host "      -> $($r.Advice)" } }
$color = if ($count.FAIL -gt 0) { 'Red' } elseif ($count.WARN -gt 0) { 'Yellow' } else { 'Green' }
Write-Host $summary -ForegroundColor $color
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory') }
$reportFile = Join-Path $desktop ('Domain OS check {0}.txt' -f $started.ToString('yyyy-MM-dd HHmm'))
try {
    Set-Content -LiteralPath $reportFile -Value ($head + $body) -Encoding UTF8
    Write-Host "Full report (every PASS too): $reportFile"
} catch { Write-Host "The report file could not be written: $($_.Exception.Message)" }
if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
if ($count.FAIL -gt 0) { exit 1 }
exit 0
