<#
  Domain OS — shared helpers, dot-sourced by the scripts that write or read %ProgramData%\Domain OS:
      . (Join-Path $PSScriptRoot 'DomainOS-Common.ps1')
  Copied next to the tools in Program Files\Domain OS\Tools by Install-DomainOS.ps1 -Part Tools.

  Why: the folder holds the saved state that "Undo Domain OS" and the installer later use with administrator
  (or TrustedInstaller) rights. Under ProgramData every user could create files there, so a standard account
  could plant an "original state" that an administrator would then write back. So:
    - Protect-DomainOSData gives the folder its own access list: inheritance off, SYSTEM and Administrators full
      control, Users read & execute only. Accounts are named by their SIDs (works on every display language).
      On an existing folder (an upgrade) a foreign owner or extra write rights are reset, links inside are removed.
    - Test-DomainOSFile accepts a saved file only when its owner is SYSTEM, Administrators, TrustedInstaller or an
      account in the local Administrators group (steps run "as the current user, elevated" give files the user's
      own account as owner). Files a standard account created keep that account as owner, so they are refused (and
      the refusal logged). Protect-DomainOSData gives files of administrator accounts to the Administrators group.
    - Get-DomainOSAllowList: the registry values, services and scheduled tasks Undo may restore are the ones the
      playbook's own task files can touch (plus what earlier versions touched), nothing else.
    - Import-DomainOSRegFile reads a saved .reg export value by value and writes only under the expected key,
      instead of handing the file to reg.exe import.
  Windows PowerShell 5.1 syntax only.
#>

$DomainOSData = Join-Path $env:ProgramData 'Domain OS'
$DomainOSSidSystem = 'S-1-5-18'
$DomainOSSidAdmins = 'S-1-5-32-544'
$DomainOSSidUsers = 'S-1-5-32-545'
$DomainOSSidTrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
$DomainOSTrustedOwners = @($DomainOSSidSystem, $DomainOSSidAdmins, $DomainOSSidTrustedInstaller)
# Rights that let someone change a file or folder: write/append data, create files/folders, extended attributes,
# delete children, attributes, delete, change permissions, take ownership, plus GENERIC_WRITE / GENERIC_ALL.
$DomainOSWriteRights = [long]0x500D0156

# Items earlier versions of the playbook changed and this one no longer touches (checked against every released
# .apbx). Restore-Defaults.ps1 puts them back on install; Undo may restore them from a state saved by such a version.
$DomainOSLegacyServices = @(
    'DPS', 'WdiSystemHost', 'WdiServiceHost', 'TroubleshootingSvc', 'diagsvc', 'diagnosticshub.standardcollector.service',
    'wercplsupport', 'pla', 'Wecsvc',
    'OneSyncSvc', 'CloudIdSvc', 'CloudBackupRestoreSvc', 'CldFlt', 'fhsvc', 'DusmSvc', 'DSSvc', 'ShellHWDetection', 'svsvc', 'SEMgrSvc',
    'Ndu', 'bam', 'dam', 'AcpiPmi', 'acpipagr', 'acpitime', 'PRM', 'kdnic', 'intelpmt', 'Beep',
    'RetailDemo', 'Fax', 'WMPNetworkSvc', 'wisvc', 'WpcMonSvc', 'PhoneSvc', 'RemoteRegistry',
    'Spooler', 'PrintNotify', 'PrintWorkflowUserSvc', 'stisvc', 'usbprint', 'McpManagementService', 'PrintScanBrokerService',
    'PrintDeviceConfigurationService', 'bthserv', 'BTAGService', 'BthAvctpSvc',
    'TrkWks'
)
$DomainOSLegacyTasks = @(
    '\Microsoft\Windows\Flighting\OneSettings\RefreshCache',
    '\Microsoft\Windows\Sustainability\PowerGridForecastTask',
    '\Microsoft\Windows\ConsentUX\UnifiedConsent\UnifiedConsentSyncTask',
    '\Microsoft\Windows\DeviceDirectoryClient\IntegrityCheck',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceAccountChange',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDevicePolicyChange',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceProtectionStateChanged',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterDeviceSettingChange',
    '\Microsoft\Windows\DeviceDirectoryClient\RegisterUserDevice',
    '\Microsoft\Windows\Diagnosis\UnexpectedCodepath',
    '\Microsoft\Windows\Hotpatch\Monitoring',
    '\Microsoft\Windows\Work Folders\Work Folders Logon Synchronization',
    '\Microsoft\Windows\Work Folders\Work Folders Maintenance Work',
    '\Microsoft\Windows\NetTrace\GatherNetworkInfo'
)
$DomainOSLegacyRegistry = @(
    @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'NoAutoRebootWithLoggedOnUsers'),
    @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'AUPowerManagement'),
    # Versions 1.4.0-2.1.0 set the Domain OS wallpaper through these values.
    @('HKCU\Control Panel\Desktop', 'Wallpaper'),
    @('HKCU\Control Panel\Desktop', 'WallpaperStyle'),
    @('HKCU\Control Panel\Desktop', 'TileWallpaper')
)

# A message goes to the calling script's log when it has one (every Domain OS script defines Write-Log).
function Write-DomainOSNote([string]$Text) {
    if (Get-Command -Name 'Write-Log' -CommandType Function -ErrorAction SilentlyContinue) { Write-Log $Text } else { Write-Host $Text }
}

function Test-DomainOSAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Starts the script again with administrator rights (UAC) and the same switches and values, -WhatIf included.
# Returns $true when the caller must exit (a new elevated copy was started, or the user declined).
function Start-DomainOSElevated([string]$Script, $Bound) {
    if (Test-DomainOSAdmin) { return $false }
    $line = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`""
    if ($Bound) {
        foreach ($k in @($Bound.Keys)) {
            $v = $Bound[$k]
            if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $line += " -$k" } }
            elseif ($v -is [bool]) { if ($v) { $line += " -$k" } }
            elseif ($null -ne $v) { $line += " -$k `"$v`"" }
        }
    }
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $line -Verb RunAs | Out-Null }
    catch { Write-Host "Administrator rights are needed and were not given: nothing was changed. ($($_.Exception.Message))" }
    return $true
}

function Get-DomainOSOwner([string]$Path) {
    try { return (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
}

# The owners whose files count as written by Domain OS: SYSTEM, Administrators, TrustedInstaller, and every account
# that is a member of the local Administrators group. Why the accounts: the playbook runs some steps "as the current
# user, elevated", and Windows gives files made that way the user's own account as owner (versions up to 2.1.2
# saved the whole state like that). Such an account can change anything on the PC anyway; the protection is against
# STANDARD accounts planting files, and those are never in this list. Read once per script.
$script:DomainOSAdminSids = $null
function Get-DomainOSAdminSids {
    if ($null -ne $script:DomainOSAdminSids) { return $script:DomainOSAdminSids }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in $DomainOSTrustedOwners) { [void]$set.Add($x) }
    $listed = $false
    try {
        foreach ($m in @(Get-LocalGroupMember -SID $DomainOSSidAdmins -ErrorAction Stop)) { if ($m.SID) { [void]$set.Add($m.SID.Value) } }
        $listed = $true
    } catch { }
    if (-not $listed) {
        # Get-LocalGroupMember fails when the group holds an account it cannot resolve (e.g. a removed or Entra ID
        # account): the older WinNT interface lists the members' SIDs directly.
        try {
            $name = (New-Object Security.Principal.SecurityIdentifier($DomainOSSidAdmins)).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
            $group = [ADSI]"WinNT://$env:COMPUTERNAME/$name,group"
            foreach ($m in @($group.Invoke('Members'))) {
                $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
                if ($bytes) { [void]$set.Add((New-Object Security.Principal.SecurityIdentifier([byte[]]$bytes, 0)).Value) }
            }
        } catch { }
    }
    # The account running this script, when it runs as administrator (covers members through a domain group).
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ((New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { [void]$set.Add($me.User.Value) }
    } catch { }
    $script:DomainOSAdminSids = $set
    return $set
}

# True when the file is there, is not a link and belongs to SYSTEM, Administrators, TrustedInstaller or an
# administrator account (Get-DomainOSAdminSids).
function Test-DomainOSFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { Write-DomainOSNote "Refused $Path ($($_.Exception.Message))"; return $false }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Write-DomainOSNote "Refused $Path`: it is a link, not a saved file"; return $false }
    $owner = Get-DomainOSOwner $Path
    if (-not $owner -or -not (Get-DomainOSAdminSids).Contains($owner)) {
        Write-DomainOSNote "Refused $Path`: its owner ($owner) is not SYSTEM, Administrators, TrustedInstaller or an administrator account, so it was not written by Domain OS. It is left as it is and not used."
        return $false
    }
    return $true
}

function New-DomainOSRule([string]$Sid, [System.Security.AccessControl.FileSystemRights]$Rights, [bool]$Container) {
    $id = New-Object Security.Principal.SecurityIdentifier($Sid)
    $inherit = if ($Container) { [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [System.Security.AccessControl.InheritanceFlags]::None }
    return New-Object System.Security.AccessControl.FileSystemAccessRule($id, $Rights, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
}

# Ownership to Administrators. takeown.exe enables the privilege it needs; /A = the Administrators group.
function Set-DomainOSOwner([string]$Path) {
    & (Join-Path $env:SystemRoot 'System32\takeown.exe') /F $Path /A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not take ownership of $Path (takeown exit code $LASTEXITCODE)" }
}

# A folder's own access list: inheritance off, SYSTEM and Administrators full control, plus $Readers with read &
# execute. Only the access list is written (the owner is not part of the object, so it is not touched).
function Set-DomainOSFolderAcl([string]$Path, [string[]]$Readers) {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-DomainOSRule $DomainOSSidSystem 'FullControl' $true))
    $acl.AddAccessRule((New-DomainOSRule $DomainOSSidAdmins 'FullControl' $true))
    foreach ($r in $Readers) { $acl.AddAccessRule((New-DomainOSRule $r 'ReadAndExecute, Synchronize' $true)) }
    [System.IO.Directory]::SetAccessControl($Path, $acl)
}

# Explicit entries that give anyone but SYSTEM / Administrators / TrustedInstaller write rights are removed.
function Remove-DomainOSWriteAces($Item) {
    $acl = Get-Acl -LiteralPath $Item.FullName -ErrorAction Stop
    $bad = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.AccessControlType -eq 'Allow' -and
        ($DomainOSTrustedOwners -notcontains $_.IdentityReference.Value) -and
        (([long]$_.FileSystemRights -band $DomainOSWriteRights) -ne 0)
    })
    if ($bad.Count -eq 0) { return }
    foreach ($r in $bad) { [void]$acl.RemoveAccessRuleSpecific($r) }
    if ($Item.PSIsContainer) { [System.IO.Directory]::SetAccessControl($Item.FullName, $acl) } else { [System.IO.File]::SetAccessControl($Item.FullName, $acl) }
    Write-DomainOSNote "Write rights of other accounts removed from $($Item.FullName)"
}

# Walks the folder without following links: links are deleted, folders with a foreign owner are taken over by
# Administrators, files of an administrator account are given to the Administrators group, extra write entries are
# removed. Files of any other (standard) account are left alone: Test-DomainOSFile refuses them.
function Repair-DomainOSTree([string]$Dir) {
    foreach ($child in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        $p = $child.FullName
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($child.PSIsContainer) { [System.IO.Directory]::Delete($p) } else { [System.IO.File]::Delete($p) }
            Write-DomainOSNote "A link inside the Domain OS data folder was removed: $p"
            continue
        }
        $owner = Get-DomainOSOwner $p
        if ($DomainOSTrustedOwners -notcontains $owner) {
            if ($child.PSIsContainer) {
                Set-DomainOSOwner $p
                $acl = Get-Acl -LiteralPath $p -ErrorAction Stop
                foreach ($r in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($r) }
                $acl.SetAccessRuleProtection($false, $false)
                [System.IO.Directory]::SetAccessControl($p, $acl)
                Write-DomainOSNote "Folder $p had the owner $owner`: ownership given to Administrators, permissions inherited again"
            } elseif ($owner -and (Get-DomainOSAdminSids).Contains($owner)) {
                # Written by an administrator account (older versions saved the state as the user, elevated):
                # the owner becomes the Administrators group and other accounts' write rights go.
                try {
                    Set-DomainOSOwner $p
                    Remove-DomainOSWriteAces (Get-Item -LiteralPath $p -Force)
                } catch { Write-DomainOSNote "File $p (owner: the administrator account $owner) could not be given to Administrators: $($_.Exception.Message); it is still used" }
            } else {
                Write-DomainOSNote "File $p has the owner $owner (not an administrator account): left as it is, never used by Domain OS"
                continue
            }
        } else {
            try { Remove-DomainOSWriteAces $child } catch { Write-DomainOSNote "Permissions of $p could not be checked: $($_.Exception.Message)" }
        }
        if ($child.PSIsContainer) { Repair-DomainOSTree $p }
    }
}

# Creates %ProgramData%\Domain OS (or repairs it) with the protected access list described at the top.
# Throws when the folder cannot be made safe; callers that change the system stop then.
function Protect-DomainOSData {
    if (-not (Test-DomainOSAdmin)) { throw 'administrator rights are needed to write the Domain OS data folder' }
    if (-not (Test-Path -LiteralPath $DomainOSData)) { New-Item -ItemType Directory -Path $DomainOSData -Force | Out-Null }
    $root = Get-Item -LiteralPath $DomainOSData -Force
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "$DomainOSData is a link or a file, not a folder: refused. Remove it and run again."
    }
    $owner = Get-DomainOSOwner $DomainOSData
    if ($DomainOSTrustedOwners -notcontains $owner) {
        Set-DomainOSOwner $DomainOSData
        Write-DomainOSNote "$DomainOSData had the owner $owner`: ownership given to Administrators"
    }
    # Sub-folders with a foreign owner first, so the new inherited permissions can reach them.
    Repair-DomainOSTree $DomainOSData
    try { Set-DomainOSFolderAcl $DomainOSData @($DomainOSSidUsers) }
    catch {
        # Passing the new inherited entries down can fail on a file another account owns; the folder itself counts.
        $check = Get-Acl -LiteralPath $DomainOSData
        if (-not $check.AreAccessRulesProtected) { throw "the permissions of $DomainOSData could not be set: $($_.Exception.Message)" }
        Write-DomainOSNote "Permissions set on $DomainOSData; some files inside could not take them: $($_.Exception.Message)"
    }
}

# A folder only one account (plus SYSTEM and Administrators) can read, for that account's personal files
# (the saved wallpaper). Created inside the protected data folder.
function New-DomainOSPrivateFolder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Path is a link: refused" }
    if ($DomainOSTrustedOwners -notcontains (Get-DomainOSOwner $Path)) { Set-DomainOSOwner $Path }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Set-DomainOSFolderAcl $Path @($user)
}

# ---- the items the playbook can touch -------------------------------------------------------------------------
# Reads the playbook's task files the same way Save-State.ps1 always did (single-line flow style of the actions).
# Values under HKLM\SOFTWARE\Domain OS are left out: that key is Domain OS' own record (Tasks\options.yml writes the
# chosen options there), not a Windows setting, so it is neither saved for Undo nor on Undo's allow-list.
function Get-DomainOSPlaybookItems([string]$TasksDir) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($yml in @(Get-ChildItem -LiteralPath $TasksDir -Filter '*.yml' -ErrorAction Stop | Sort-Object Name)) {
        foreach ($line in Get-Content -LiteralPath $yml.FullName -Encoding UTF8 -ErrorAction Stop) {
            if ($line.TrimStart().StartsWith('#')) { continue }
            if ($line -match "!registryValue:\s*\{path:\s*'([^']+)',\s*value:\s*'([^']+)'") {
                if ($Matches[1] -like 'HKLM\SOFTWARE\Domain OS*') { continue }
                $items.Add([pscustomobject]@{ kind = 'R'; path = $Matches[1]; name = $Matches[2] })
            } elseif ($line -match "!service:\s*\{name:\s*'([^']+)'") {
                $items.Add([pscustomobject]@{ kind = 'S'; path = ''; name = $Matches[1] })
            } elseif ($line -match "!scheduledTask:\s*\{path:\s*'([^']+)'") {
                $items.Add([pscustomobject]@{ kind = 'T'; path = $Matches[1]; name = '' })
            }
        }
    }
    return $items
}

# The allow-list as lines "R|<path>|<value>", "S|<service>", "T|<task path>": the task files plus the legacy lists.
function New-DomainOSAllowListLines([string]$TasksDir) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($i in Get-DomainOSPlaybookItems $TasksDir) {
        switch ($i.kind) { 'R' { $lines.Add("R|$($i.path)|$($i.name)") } 'S' { $lines.Add("S|$($i.name)") } 'T' { $lines.Add("T|$($i.path)") } }
    }
    foreach ($r in $DomainOSLegacyRegistry) { $lines.Add("R|$($r[0])|$($r[1])") }
    foreach ($s in $DomainOSLegacyServices) { $lines.Add("S|$s") }
    foreach ($t in $DomainOSLegacyTasks) { $lines.Add("T|$t") }
    return @($lines | Select-Object -Unique)
}

# Undo's allow-list: undo-allowlist.txt next to the script (written by Install-DomainOS.ps1 -Part Tools into
# Program Files, which only administrators can change), or built from ..\Configuration\Tasks when the script runs
# from the playbook itself. $null when neither is there.
function Get-DomainOSAllowList([string]$ScriptDir) {
    $set = @{}
    $file = Join-Path $ScriptDir 'undo-allowlist.txt'
    $tasks = Join-Path $ScriptDir '..\Configuration\Tasks'
    if (Test-Path -LiteralPath $file) {
        if (-not (Test-DomainOSFile $file)) { return $null }
        foreach ($l in Get-Content -LiteralPath $file -Encoding UTF8) { if ($l) { $set[$l] = $true } }
    } elseif (Test-Path -LiteralPath $tasks) {
        foreach ($l in New-DomainOSAllowListLines $tasks) { $set[$l] = $true }
    } else { return $null }
    return $set
}

# ---- saved .reg exports --------------------------------------------------------------------------------------
# Reads a file written by "reg.exe export" and writes its values, but only under $AllowedKey (the key it was
# exported from, e.g. 'HKEY_CURRENT_USER\Software\...\Taskband'). Anything unexpected (another key, a delete
# entry, an unknown value type, a line it does not understand) refuses the whole file before anything is written.
# $Check, if given, is called with (subKeyPath, valueName, kind, data) and returns $false to refuse the file.
# -ValidateOnly checks the file and writes nothing. Returns the number of values (written); throws when refused.
function Import-DomainOSRegFile([string]$Path, [string]$AllowedKey, [scriptblock]$Check, [switch]$ValidateOnly) {
    if (-not (Test-DomainOSFile $Path)) { throw "refused $Path" }
    $text = [System.IO.File]::ReadAllText($Path)   # reg.exe writes UTF-16 with a byte order mark
    $lines = $text -split "\r?\n"
    if ($lines.Count -lt 1 -or $lines[0].Trim() -ne 'Windows Registry Editor Version 5.00') { throw "$Path is not a registry export" }
    # Long hex values continue on the next line ("\" at the end; a string value always ends with its quote).
    $logical = New-Object System.Collections.Generic.List[string]
    $buf = ''
    for ($n = 1; $n -lt $lines.Count; $n++) {
        $l = $lines[$n]
        if ($buf) { $l = $l.TrimStart() }
        if ($l.EndsWith('\') -and -not $l.StartsWith('[')) { $buf += $l.Substring(0, $l.Length - 1); continue }
        $logical.Add($buf + $l); $buf = ''
    }
    if ($buf) { $logical.Add($buf) }

    $root = $AllowedKey.TrimEnd('\')
    $hive = $root.Split('\')[0]
    $base = switch ($hive) { 'HKEY_CURRENT_USER' { [Microsoft.Win32.Registry]::CurrentUser } 'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine } default { throw "hive $hive is not allowed" } }
    $ops = New-Object System.Collections.Generic.List[object]
    $section = $null
    foreach ($l in $logical) {
        if ($l.Trim() -eq '' -or $l.StartsWith(';')) { continue }
        if ($l -match '^\[(.+)\]\s*$') {
            $section = $Matches[1]
            if ($section.StartsWith('-')) { throw "$Path deletes a key: refused" }
            if (-not ($section -eq $root -or $section.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) -or $section -match '\\\.\.(\\|$)') { throw "$Path writes outside $root ($section): refused" }
            $ops.Add([pscustomobject]@{ key = $section.Substring($hive.Length + 1); name = $null; kind = $null; data = $null })
            continue
        }
        if (-not $section) { throw "$Path has a value outside any key: refused" }
        if ($l -match '^@=(.*)$') { $name = ''; $rest = $Matches[1] }
        elseif ($l -match '^"((?:[^"\\]|\\.)*)"=(.*)$') { $name = $Matches[1] -replace '\\(.)', '$1'; $rest = $Matches[2] }
        else { throw "$Path has a line that is not understood: refused" }
        $kind = $null; $data = $null
        if ($rest -match '^"((?:[^"\\]|\\.)*)"$') { $kind = 'String'; $data = $Matches[1] -replace '\\(.)', '$1' }
        elseif ($rest -match '^dword:([0-9a-fA-F]{8})$') { $kind = 'DWord'; $data = [BitConverter]::ToInt32([BitConverter]::GetBytes([Convert]::ToUInt32($Matches[1], 16)), 0) }
        elseif ($rest -match '^hex(\(([0-9a-fA-F]+)\))?:([0-9a-fA-F,\s]*)$') {
            $t = if ($Matches[2]) { [Convert]::ToInt32($Matches[2], 16) } else { 3 }
            $hexText = ($Matches[3] -replace '\s', '').Trim(',')
            $bytes = if ($hexText) { [byte[]]@($hexText.Split(',') | ForEach-Object { [Convert]::ToByte($_, 16) }) } else { [byte[]]@() }
            switch ($t) {
                3 { $kind = 'Binary'; $data = $bytes }
                2 { $kind = 'ExpandString'; $data = [Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) }
                7 { $kind = 'MultiString'; $data = [string[]]@([Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0).Split([char]0)) }
                11 { if ($bytes.Length -ne 8) { throw "$Path has a broken QWORD: refused" }; $kind = 'QWord'; $data = [BitConverter]::ToInt64($bytes, 0) }
                4 { if ($bytes.Length -ne 4) { throw "$Path has a broken DWORD: refused" }; $kind = 'DWord'; $data = [BitConverter]::ToInt32($bytes, 0) }
                default { throw "$Path has a value type $t that is not expected: refused" }
            }
        } else { throw "$Path has a value that is not understood ($rest): refused" }
        if ($Check -and -not (& $Check ($ops[$ops.Count - 1].key) $name $kind $data)) { throw "$Path has a value that is not expected ($name): refused" }
        $ops.Add([pscustomobject]@{ key = $ops[$ops.Count - 1].key; name = $name; kind = $kind; data = $data })
    }
    if ($ValidateOnly) { return @($ops | Where-Object { $null -ne $_.name }).Count }
    # Everything checked: now written.
    $count = 0
    foreach ($op in $ops) {
        $k = $base.CreateSubKey($op.key)
        try {
            if ($null -ne $op.name) { $k.SetValue($op.name, $op.data, [Microsoft.Win32.RegistryValueKind]$op.kind); $count++ }
        } finally { $k.Close() }
    }
    return $count
}

# The link tracking service's saved registration (TrkWks.reg, written by versions 1.6.7-2.1.0 before they deleted
# the service): only its own key, and its program must be Windows' own svchost / trkwks.dll.
$DomainOSTrkWksKey = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\TrkWks'
$DomainOSTrkWksCheck = {
    param($key, $name, $kind, $data)
    if ($name -eq 'ImagePath') { return ([string]$data -match '^%SystemRoot%\\System32\\svchost\.exe -k [A-Za-z]+( -p)?$') }
    if ($name -eq 'ServiceDll') { return ([string]$data -match '^%SystemRoot%\\System32\\trkwks\.dll$') }
    return $true
}

# ---- the account the playbook runs for -------------------------------------------------------------------------
# AME Wizard runs the "current user" steps with the user's TOKEN but SYSTEM's ENVIRONMENT: %USERNAME% is the computer
# account (e.g. DESKTOP-ABC$) and %APPDATA% / %LOCALAPPDATA% point into the system profile. So the account comes from
# the process token, and the user's folders from Windows' known-folder API (it follows the token, not the variables).
function Get-DomainOSUser {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $name = $id.Name.Split('\')[-1]
    return [pscustomobject]@{ Name = $name; Full = $id.Name; Sid = $id.User.Value }
}
# 'ApplicationData' (Roaming), 'LocalApplicationData', 'Desktop' …: the folder of the account in the token.
function Get-DomainOSUserFolder([string]$Which) {
    $p = [Environment]::GetFolderPath($Which)
    if (-not $p) { throw "the folder $Which of this account is unknown" }
    return $p
}
# Undo\<Kind>\<account>: the per-account backups (taskbar, Start pins, wallpapers). Versions up to 2.1.8 named the
# folder after %USERNAME%, i.e. the computer account under AME: such a folder is renamed to the account's name once,
# so Undo (which runs with the real name) finds it.
function Get-DomainOSUserDir([string]$Kind) {
    $base = Join-Path $DomainOSData "Undo\$Kind"
    $name = (Get-DomainOSUser).Name
    $dir = Join-Path $base $name
    $legacy = Join-Path $base ($env:COMPUTERNAME + '$')
    if (-not (Test-Path -LiteralPath $dir) -and ($name -ne ($env:COMPUTERNAME + '$')) -and (Test-Path -LiteralPath $legacy)) {
        try { Rename-Item -LiteralPath $legacy -NewName $name -ErrorAction Stop } catch { return $legacy }
    }
    return $dir
}

# ---- Explorer --------------------------------------------------------------------------------------------------
# Ends Explorer of THIS session only and lets Windows start it again as the user (AutoRestartShell). It is never
# started from an elevated process (that would give an elevated desktop): if it has not come back after 10 s, a
# one-time scheduled task starts it as the signed-in user, without administrator rights.
function Restart-DomainOSExplorer {
    $session = (Get-Process -Id $PID).SessionId
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) { return }
    }
    $name = 'Domain OS start Explorer'
    try {
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'explorer.exe')
        $principal = New-ScheduledTaskPrincipal -UserId (Get-DomainOSUser).Full -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        Start-Sleep -Seconds 3
    } catch {
        Write-DomainOSNote "Explorer did not come back by itself and could not be started: sign out and in again ($($_.Exception.Message))"
    } finally {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---- opening a page once after the next sign-in -----------------------------------------------------------------
# Why not HKCU RunOnce: AME Wizard runs the "current user" steps with the user's token but SYSTEM's environment
# (%USERNAME% = the computer account), so per-user RunOnce entries did not reliably reach the person who signs in.
# Instead: a scheduled task for every member of Users (S-1-5-32-545), started at sign-in with normal rights (never
# elevated), 20 s after the desktop appears. It opens the page in the default browser once per account: a marker
# file in that account's %LOCALAPPDATA%\Domain OS remembers it (per $Marker, e.g. the version). The task expires
# after 14 days and Windows deletes it by itself; Undo removes it at once.
function Register-DomainOSOpenAtLogon([string]$TaskName, [string]$Page, [string]$Marker) {
    if (-not (Test-Path -LiteralPath $Page)) { throw "$Page is not there" }
    if ($Marker -notmatch '^[\w\.\-]+$') { throw "bad marker name '$Marker'" }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $pageArg = $Page.Replace("'", "''")
    $cmd = "`$d = Join-Path `$env:LOCALAPPDATA 'Domain OS'; `$m = Join-Path `$d 'shown-$Marker'; " +
           "if (-not (Test-Path -LiteralPath `$m)) { New-Item -ItemType Directory -Force -Path `$d | Out-Null; " +
           "Set-Content -LiteralPath `$m -Value (Get-Date -Format o); Start-Process -FilePath '$pageArg' }"
    # Through conhost --headless: no console window at all (-WindowStyle Hidden alone still flashes one at sign-in).
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ("--headless `"$ps`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"" + $cmd + "`"")
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT20S'
    $trigger.EndBoundary = (Get-Date).AddDays(14).ToString('s')
    $principal = New-ScheduledTaskPrincipal -GroupId ((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([Security.Principal.NTAccount]).Value) -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter (New-TimeSpan -Days 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\Domain OS\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}
