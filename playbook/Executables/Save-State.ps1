<#
  Domain OS — runs FIRST, before anything is changed. It reads the playbook's own task files, finds every registry
  value, service and scheduled task the playbook may touch, and writes down what they are now.
  "Undo Domain OS" (Undo-DomainOS.ps1) puts exactly this state back. The first saved state is kept: applying the
  playbook a second time does not overwrite the original.

  Files (in %ProgramData%\Domain OS\Undo, a folder only administrators can change, see DomainOS-Common.ps1):
    state.json           the state Undo uses: the original, plus items newer versions touch for the first time
    state.original.json  a second copy of the original, written once and never changed afterwards

  It fails loudly: any error ends it with exit code 1, and main.yml stops the install then, before any change.
    - state.json is there but cannot be read, or was not written by Domain OS (foreign owner): stop, file untouched.
    - state.json is missing but state.original.json is there (deleted by hand, lost): the original is taken from it.
    - Writing: state.json.tmp first, read back and checked, then it replaces state.json in one step.
    - A registry value that cannot be read is recorded as "unreadable", not as "did not exist": Undo skips it
      instead of deleting it.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'DomainOS-Common.ps1')
$dir = Join-Path $DomainOSData 'Undo'
$file = Join-Path $dir 'state.json'
$tmp = Join-Path $dir 'state.json.tmp'
$original = Join-Path $dir 'state.original.json'
$log = Join-Path $DomainOSData 'Logs\install.log'
function Write-Log([string]$text) {
    try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [State] {1}' -f (Get-Date), $text) -Encoding UTF8 } catch { }
    Write-Host $text
}

# Reads a saved state; anything wrong with it is an error, never "no state".
function Read-State([string]$path) {
    if (-not (Test-DomainOSFile $path)) { throw "$path was not written by Domain OS (see the log line above). It was left untouched. Check it, delete it if it is not yours, and run the playbook again." }
    $raw = [System.IO.File]::ReadAllText($path)
    try { $s = $raw | ConvertFrom-Json } catch { $s = $null }
    if (-not $s -or -not ($s.PSObject.Properties.Name -contains 'registry') -or -not $s.saved) {
        throw "$path is there but cannot be read (damaged or cut short). It was left untouched so the original state is not lost. Restore it from state.original.json in the same folder, or delete it to save a new state, and run the playbook again."
    }
    return $s
}

# A registry value now: exists / does not exist / cannot be read (access denied on the key or the value).
function Get-RegistryEntry([string]$path, [string]$name) {
    $entry = [ordered]@{ path = $path; name = $name; exists = $false; kind = ''; data = $null }
    $hive = $path.Split('\')[0]
    $sub = $path.Substring($hive.Length + 1)
    $base = switch ($hive) { 'HKLM' { [Microsoft.Win32.Registry]::LocalMachine } 'HKCU' { [Microsoft.Win32.Registry]::CurrentUser } default { $null } }
    if (-not $base) { $entry['unreadable'] = $true; return $entry }
    try {
        $key = $base.OpenSubKey($sub, $false)
        if ($key) {
            try {
                if ($key.GetValueNames() -contains $name) {
                    $entry.exists = $true
                    $entry.kind = $key.GetValueKind($name).ToString()
                    $entry.data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                }
            } finally { $key.Close() }
        }
    } catch {
        $entry.exists = $null
        $entry['unreadable'] = $true
        Write-Log "Could not read $path\$name ($($_.Exception.Message)): recorded as unreadable, Undo leaves it alone"
    }
    return $entry
}

try {
    Protect-DomainOSData
    New-Item -ItemType Directory -Force -Path $dir, (Join-Path $DomainOSData 'Logs') | Out-Null

    # The version being applied (from playbook.conf).
    $version = ''
    $conf = Get-Content -Raw -Encoding UTF8 (Join-Path $here '..\playbook.conf')
    if ($conf -match '<Version>([^<]+)</Version>') { $version = $Matches[1] }

    # A state that is already there is the ORIGINAL one (an earlier version was applied and not undone). It is kept;
    # only things this version touches and the earlier one did not are added, with the values they have now.
    $old = $null
    if (Test-Path -LiteralPath $file) {
        $old = Read-State $file
        # Installs from before state.original.json existed: the state kept until now is the original.
        if (-not (Test-Path -LiteralPath $original)) { Copy-Item -LiteralPath $file -Destination $original; Write-Log 'Second copy of the original state written (state.original.json)' }
    } elseif (Test-Path -LiteralPath $original) {
        $old = Read-State $original
        Write-Log 'state.json was missing: the original state is taken from state.original.json'
    }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }   # left by an interrupted run; never used

    $registry = @(); $services = @(); $tasks = @()
    $seen = @{}
    if ($old) {
        foreach ($r in $old.registry) { $seen["R|$($r.path)|$($r.name)"] = $true; $registry += $r }
        foreach ($x in $old.services) { $seen["S|$($x.name)"] = $true; $services += $x }
        foreach ($t in $old.tasks) { $seen["T|$($t.path)"] = $true; $tasks += $t }
    }
    $before = $registry.Count + $services.Count + $tasks.Count
    foreach ($i in Get-DomainOSPlaybookItems (Join-Path $here '..\Configuration\Tasks')) {
        $key = "$($i.kind)|$($i.path)|$($i.name)"
        if ($i.kind -eq 'S') { $key = "S|$($i.name)" } elseif ($i.kind -eq 'T') { $key = "T|$($i.path)" }
        if ($seen[$key]) { continue }; $seen[$key] = $true
        switch ($i.kind) {
            'R' { $registry += (Get-RegistryEntry $i.path $i.name) }
            'S' {
                $svc = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($i.name)"
                if (-not (Test-Path -LiteralPath $svc)) { continue }   # not on this Windows
                try { $start = (Get-ItemProperty -LiteralPath $svc -Name 'Start' -ErrorAction Stop).Start }
                catch { $services += [ordered]@{ name = $i.name; unreadable = $true }; Write-Log "Service $($i.name): start type unreadable, Undo leaves it alone"; continue }
                $running = $false
                try { $running = ((Get-Service -Name $i.name -ErrorAction Stop).Status -eq 'Running') } catch { }   # drivers are not listed by Get-Service
                $services += [ordered]@{ name = $i.name; start = [int]$start; running = $running }
            }
            'T' {
                $full = $i.path; $n = $full.LastIndexOf('\')
                $task = Get-ScheduledTask -TaskPath ($full.Substring(0, $n + 1)) -TaskName ($full.Substring($n + 1)) -ErrorAction SilentlyContinue
                if ($task) { $tasks += [ordered]@{ path = $full; enabled = ($task.State -ne 'Disabled') } }
            }
        }
    }

    if ($old) {
        # Hibernation, OneDrive and the app list stay as first recorded.
        $state = [ordered]@{
            saved = $old.saved; user = $old.user; build = $old.build; hibernate = $old.hibernate; oneDrive = $old.oneDrive; apps = $old.apps
            versions = @($old.versions) + $version
            registry = $registry; services = $services; tasks = $tasks
        }
    } else {
        $apps = @()
        try { $apps = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name -Unique | Sort-Object) }
        catch { Write-Log "The list of installed apps could not be read ($($_.Exception.Message)): Undo will not list removed apps" }
        $state = [ordered]@{
            saved     = (Get-Date).ToString('o')
            user      = (Get-DomainOSUser).Full
            build     = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
            hibernate = [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled
            oneDrive  = [bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).OneDrive -or (Test-Path (Join-Path (Get-DomainOSUserFolder 'LocalApplicationData') 'Microsoft\OneDrive\OneDrive.exe'))
            apps      = $apps
            versions  = @($version)
            registry  = $registry
            services  = $services
            tasks     = $tasks
        }
    }
    # Classic right-click menu (interface.yml): whether the switch key existed before Domain OS first set it.
    $state['classicMenu'] = if ($old -and $null -ne $old.classicMenu) { [bool]$old.classicMenu } else { Test-Path -LiteralPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' }

    # Written to a temporary file, read back and compared, then put in place in one step. (File.Replace without a
    # backup file: PowerShell turns a plain $null into "" for a string argument, which .NET refuses, so [NullString].)
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
    $check = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($check.registry).Count -ne $registry.Count -or @($check.services).Count -ne $services.Count -or @($check.tasks).Count -ne $tasks.Count -or $check.saved -ne $state.saved) {
        throw 'the state read back from state.json.tmp differs from what was written'
    }
    if (Test-Path -LiteralPath $file) { [System.IO.File]::Replace($tmp, $file, [NullString]::Value) } else { Move-Item -LiteralPath $tmp -Destination $file -Force }
    if (-not (Test-Path -LiteralPath $original)) { Copy-Item -LiteralPath $file -Destination $original }
    # The history of what was applied and undone on this PC (read by Toolbox for the playbook version).
    Add-Content -Path (Join-Path $DomainOSData 'history.log') -Value ('{0:yyyy-MM-dd HH:mm:ss}  applied  {1}' -f (Get-Date), $version) -Encoding UTF8

    if ($old) { Write-Log ("The original state was kept; {0} items new in version {1} were added to it." -f ($registry.Count + $services.Count + $tasks.Count - $before), $version) }
    else { Write-Log ("Original state saved: {0} registry values, {1} services, {2} scheduled tasks." -f $registry.Count, $services.Count, $tasks.Count) }
    exit 0
} catch {
    Write-Log "FAILED, the install stops before any change: $($_.Exception.Message)"
    exit 1
}
