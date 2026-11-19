# Unit tests of DomainOS-Common.ps1 (the real file, dot-sourced), Windows primitives replaced by Pester mocks.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Harness.ps1')
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('dos-common-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:tmp | Out-Null
    $env:ProgramData = Join-Path $script:tmp 'ProgramData'
    . (Join-Path $global:DosPlaybook 'Executables\DomainOS-Common.ps1')
    $script:Tasks = Join-Path $global:DosPlaybook 'Configuration\Tasks'
    function Write-Log([string]$t) { $script:logged += , $t }
}
AfterAll { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
Describe 'DomainOS-Common.ps1' {
BeforeEach { $script:logged = @(); Reset-DosWorld }

Describe 'Get-DomainOSAdminSids' {
    BeforeEach { $script:DomainOSAdminSids = $null }
    It 'adds SYSTEM, Administrators, TrustedInstaller and every member of the local Administrators group' {
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } }, [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }, [pscustomobject]@{ SID = $null }) }
        $s = Get-DomainOSAdminSids
        foreach ($x in 'S-1-5-18', 'S-1-5-32-544', $DomainOSSidTrustedInstaller, 'S-1-5-21-1-2-3-500', 'S-1-5-21-1-2-3-1001') { $s.Contains($x) | Should -BeTrue -Because $x }
        $s.Contains('S-1-5-32-545') | Should -BeFalse -Because 'Users is never trusted'
        Should -Invoke Get-LocalGroupMember -Times 1 -ParameterFilter { $SID -eq 'S-1-5-32-544' }
    }
    It 'is case-insensitive and read once per script (cached)' {
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-9-9-9-1001' } }) }
        (Get-DomainOSAdminSids) -contains 's-1-5-21-9-9-9-1001' | Should -BeTrue
        (Get-DomainOSAdminSids).Contains('S-1-5-21-9-9-9-1001') | Should -BeTrue -Because 'callers use .Contains() with the canonical SID text'
        $null = Get-DomainOSAdminSids
        Should -Invoke Get-LocalGroupMember -Times 1 -Exactly
    }
    It 'keeps only the built-in trusted owners when the group cannot be listed (no crash, no standard account)' {
        Mock Get-LocalGroupMember { throw 'An unspecified error occurred: 1789' }
        $s = Get-DomainOSAdminSids
        $s.Contains('S-1-5-18') | Should -BeTrue
        $s.Contains('S-1-5-32-544') | Should -BeTrue
        $s.Contains('S-1-5-21-1-2-3-1001') | Should -BeFalse
    }
}

Describe 'Test-DomainOSFile' {
    BeforeAll {
        $script:f = Join-Path $script:tmp 'state.json'; Set-Content -LiteralPath $script:f -Value '{}'
        $script:DomainOSAdminSids = $null
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }) }
    }
    It 'accepts a file owned by <owner>' -TestCases @(@{ owner = 'S-1-5-18' }, @{ owner = 'S-1-5-32-544' }, @{ owner = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' }, @{ owner = 'S-1-5-21-1-2-3-1001' }) {
        Mock Get-DomainOSOwner { $owner }
        Test-DomainOSFile $script:f | Should -BeTrue
    }
    It 'refuses a file owned by a standard account and says why' {
        Mock Get-DomainOSOwner { 'S-1-5-21-1-2-3-1002' }
        Test-DomainOSFile $script:f | Should -BeFalse
        ($script:logged -join ' ') | Should -Match 'S-1-5-21-1-2-3-1002.*not written by Domain OS'
    }
    It 'refuses a file whose owner cannot be read' {
        Mock Get-DomainOSOwner { $null }
        Test-DomainOSFile $script:f | Should -BeFalse
    }
    It 'refuses a missing file without logging an owner' {
        Mock Get-DomainOSOwner { 'S-1-5-18' }
        Test-DomainOSFile (Join-Path $script:tmp 'nope.json') | Should -BeFalse
        Should -Invoke Get-DomainOSOwner -Times 0
    }
    It 'refuses a symbolic link even when its owner is SYSTEM' {
        Mock Get-DomainOSOwner { 'S-1-5-18' }
        $l = Join-Path $script:tmp 'link.json'
        [IO.File]::CreateSymbolicLink($l, $script:f) | Out-Null
        Test-DomainOSFile $l | Should -BeFalse
        ($script:logged -join ' ') | Should -Match 'link'
    }
}

Describe 'Get-DomainOSPlaybookItems and the Undo allow-list' {
    It 'reads registry values, services and tasks of the real task files' {
        $items = @(Get-DomainOSPlaybookItems $script:Tasks)
        @($items | Where-Object kind -eq 'R').Count | Should -BeGreaterThan 50
        @($items | Where-Object kind -eq 'S').Count | Should -BeGreaterThan 3
        @($items | Where-Object kind -eq 'T').Count | Should -BeGreaterThan 10
        $items | Where-Object { $_.kind -eq 'R' -and $_.name -eq 'Win32PrioritySeparation' } | Should -Not -BeNullOrEmpty
        $items | Where-Object { $_.kind -eq 'S' -and $_.name -eq 'SysMain' } | Should -Not -BeNullOrEmpty
    }
    It 'skips commented-out actions and reads only the single-line flow style' {
        $d = Join-Path $script:tmp 'tasks1'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'a.yml') -Encoding UTF8 -Value @(
            "actions:",
            "  # - !registryValue: {path: 'HKLM\SOFTWARE\Commented', value: 'X', data: '1', type: REG_DWORD}",
            "  - !registryValue: {path: 'HKCU\Software\Ä', value: 'Wert', data: '1', type: REG_DWORD}",
            "  - !service: {name: 'Foo', operation: change, startup: 4}",
            "  - !scheduledTask: {path: '\Microsoft\Windows\X\Y', operation: disable}")
        $items = @(Get-DomainOSPlaybookItems $d)
        $items.Count | Should -Be 3
        $items[0].path | Should -Be 'HKCU\Software\Ä' -Because 'task files are read as UTF-8'
        $items[0].name | Should -Be 'Wert'
        ($items | Where-Object path -eq 'HKLM\SOFTWARE\Commented') | Should -BeNullOrEmpty
    }
    It 'builds unique allow-list lines R|path|value, S|name, T|path including the legacy lists' {
        $lines = @(New-DomainOSAllowListLines $script:Tasks)
        $lines.Count | Should -Be (@($lines | Select-Object -Unique).Count)
        $lines | Should -Contain 'S|SysMain'
        $lines | Should -Contain 'R|HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl|Win32PrioritySeparation'
        foreach ($s in $DomainOSLegacyServices) { $lines | Should -Contain "S|$s" }
        foreach ($t in $DomainOSLegacyTasks) { $lines | Should -Contain "T|$t" }
        foreach ($l in $lines) { $l | Should -Match '^(R\|HK(LM|CU)\\[^|]+\|[^|]+|S\|[\w.\-]+|T\|\\.+)$' }
        $lines.Count | Should -BeGreaterOrEqual 50 -Because 'Install-DomainOS -Part Tools refuses fewer than 50 entries'
    }
    It 'Get-DomainOSAllowList: a trusted undo-allowlist.txt is used, nothing else' {
        $d = Join-Path $script:tmp 'tools1'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'undo-allowlist.txt') -Value 'S|Foo', 'T|\X\Y', '' -Encoding UTF8
        Mock Get-DomainOSOwner { 'S-1-5-18' }
        $a = Get-DomainOSAllowList $d
        $a.Keys.Count | Should -Be 2
        $a['S|Foo'] | Should -BeTrue
        $a['S|SysMain'] | Should -BeNullOrEmpty
    }
    It 'Get-DomainOSAllowList: an untrusted undo-allowlist.txt gives $null (Undo then restores nothing)' {
        $d = Join-Path $script:tmp 'tools2'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'undo-allowlist.txt') -Value 'S|WinDefend' -Encoding UTF8
        Mock Get-DomainOSOwner { 'S-1-5-21-1-2-3-1002' }
        Get-DomainOSAllowList $d | Should -BeNullOrEmpty
    }
    It 'Get-DomainOSAllowList: falls back to ..\Configuration\Tasks next to the script, else $null' {
        $root = Join-Path $script:tmp 'pbx'; $x = Join-Path $root 'Executables'
        New-Item -ItemType Directory -Path $x, (Join-Path $root 'Configuration') -Force | Out-Null
        Get-DomainOSAllowList $x | Should -BeNullOrEmpty
        Copy-Item -LiteralPath $script:Tasks -Destination (Join-Path $root 'Configuration') -Recurse
        $a = Get-DomainOSAllowList $x
        $a['S|SysMain'] | Should -BeTrue
    }
}

Describe 'Import-DomainOSRegFile (saved .reg exports)' {
    BeforeAll {
        Mock Get-DomainOSOwner { 'S-1-5-18' }
        function New-Reg([string]$name, [string[]]$lines) {
            $p = Join-Path $script:tmp $name
            [IO.File]::WriteAllText($p, (@('Windows Registry Editor Version 5.00', '') + $lines + '') -join "`r`n", [Text.Encoding]::Unicode)
            return $p
        }
        $script:key = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    }
    It 'validates a normal export (strings, dword, wrapped hex, sub key) and counts its values' {
        $p = New-Reg 'ok.reg' @("[$script:key]", '"Favorites"=hex:00,01,02,\', '  03,04', '"FavoritesVersion"=dword:00000003', '@="default"', "[$script:key\Sub]", '"Name"="a \"quoted\" value"')
        Import-DomainOSRegFile $p $script:key -ValidateOnly | Should -Be 4
    }
    It 'refuses <why>' -TestCases @(
        @{ why = 'a key outside the allowed one'; lines = @('[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Evil]', '"ImagePath"="evil.exe"') },
        @{ why = 'a sibling key with the same prefix'; lines = @('[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\TaskbandEvil]', '"X"=dword:00000001') },
        @{ why = 'a key that is deleted'; lines = @('[-HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband]') },
        @{ why = 'a path with ..'; lines = @('[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\..\..\Run]', '"X"="evil.exe"') },
        @{ why = 'a value before any key'; lines = @('"X"=dword:00000001') },
        @{ why = 'an unknown value type'; lines = @('[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband]', '"X"=hex(5):00,00,00,00') },
        @{ why = 'a broken DWORD'; lines = @('[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband]', '"X"=hex(4):00,00') },
        @{ why = 'a line it does not understand'; lines = @('[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband]', 'garbage') }
    ) {
        $p = New-Reg 'bad.reg' $lines
        { Import-DomainOSRegFile $p $script:key -ValidateOnly } | Should -Throw '*refused*'
    }
    It 'refuses a file that is not a registry export' {
        $p = Join-Path $script:tmp 'not.reg'; Set-Content -LiteralPath $p -Value 'hello'
        { Import-DomainOSRegFile $p $script:key -ValidateOnly } | Should -Throw '*not a registry export*'
    }
    It 'refuses a file of an untrusted owner before reading it' {
        $p = New-Reg 'own.reg' @("[$script:key]", '"X"=dword:00000001')
        Mock Get-DomainOSOwner { 'S-1-5-21-1-2-3-1002' }
        { Import-DomainOSRegFile $p $script:key -ValidateOnly } | Should -Throw '*refused*'
    }
    It 'TrkWks check: accepts Windows'' own svchost / trkwks.dll, refuses another program' {
        $k = $DomainOSTrkWksKey
        $ok = New-Reg 'trk.reg' @("[$k]", '"ImagePath"=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,73,00,76,00,63,00,68,00,6f,00,73,00,74,00,2e,00,65,00,78,00,65,00,20,00,2d,00,6b,00,20,00,4c,00,6f,00,63,00,61,00,6c,00,53,00,79,00,73,00,74,00,65,00,6d,00,4e,00,65,00,74,00,77,00,6f,00,72,00,6b,00,52,00,65,00,73,00,74,00,72,00,69,00,63,00,74,00,65,00,64,00,20,00,2d,00,70,00,00,00', "[$k\Parameters]", '"ServiceDll"=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,74,00,72,00,6b,00,77,00,6b,00,73,00,2e,00,64,00,6c,00,6c,00,00,00')
        Import-DomainOSRegFile $ok $k $DomainOSTrkWksCheck -ValidateOnly | Should -Be 2
        $bad = New-Reg 'trk2.reg' @("[$k]", '"ImagePath"="C:\\Users\\Public\\evil.exe"')
        { Import-DomainOSRegFile $bad $k $DomainOSTrkWksCheck -ValidateOnly } | Should -Throw '*not expected*'
    }
}

Describe 'Repair-DomainOSTree / Protect-DomainOSData' {
    BeforeEach {
        $script:data = Join-Path $script:tmp ('pd-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:DomainOSAdminSids = $null
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }) }
        Mock Set-DomainOSOwner { }
        Mock Set-DomainOSFolderAcl { }
        Mock Remove-DomainOSWriteAces { }
        Mock Get-Acl { $o = [pscustomobject]@{ }; $o | Add-Member ScriptMethod GetAccessRules { @() }; $o | Add-Member ScriptMethod SetAccessRuleProtection { }; $o }
        Mock Test-DomainOSAdmin { $true }
    }
    It 'deletes links, takes over foreign folders, gives admin files to Administrators and leaves standard-user files alone' {
        New-Item -ItemType Directory -Path (Join-Path $script:data 'Undo') -Force | Out-Null
        $adminFile = Join-Path $script:data 'Undo\state.json'; Set-Content -LiteralPath $adminFile -Value '{}'
        $userFile = Join-Path $script:data 'Undo\planted.json'; Set-Content -LiteralPath $userFile -Value '{}'
        # (a sub-folder with a foreign owner needs [IO.Directory]::SetAccessControl, .NET Framework only: not testable here)
        $link = Join-Path $script:data 'Undo\link.json'; [IO.File]::CreateSymbolicLink($link, '/etc/hostname') | Out-Null
        $script:owners = @{ $adminFile = 'S-1-5-21-1-2-3-1001'; $userFile = 'S-1-5-21-1-2-3-1002' }
        Mock Get-DomainOSOwner { if ($script:owners.ContainsKey($Path)) { $script:owners[$Path] } else { 'S-1-5-32-544' } }
        Repair-DomainOSTree $script:data
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $link | Should -BeFalse -Because 'links inside the data folder are removed'
        Microsoft.PowerShell.Management\Test-Path -LiteralPath '/etc/hostname' | Should -BeTrue -Because 'the link target is not touched'
        Should -Invoke Set-DomainOSOwner -ParameterFilter { $Path -eq $adminFile } -Times 1 -Exactly
        Should -Invoke Set-DomainOSOwner -ParameterFilter { $Path -eq $userFile } -Times 0 -Exactly
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $userFile | Should -BeTrue -Because 'a planted file is left, Test-DomainOSFile refuses it later'
        ($script:logged -join "`n") | Should -Match 'planted.json has the owner S-1-5-21-1-2-3-1002'
    }
    It 'refuses when the data folder itself is a link' {
        $target = Join-Path $script:tmp 'elsewhere'; New-Item -ItemType Directory -Path $target -Force | Out-Null
        $DomainOSData = Join-Path $script:tmp ('dlink-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        [IO.Directory]::CreateSymbolicLink($DomainOSData, $target) | Out-Null
        { Protect-DomainOSData } | Should -Throw '*link*'
    }
    It 'refuses without administrator rights' {
        Mock Test-DomainOSAdmin { $false }
        { Protect-DomainOSData } | Should -Throw '*administrator*'
    }
}

Describe 'Register-DomainOSOpenAtLogon (open a page once per account)' {
    BeforeAll {
        $env:SystemRoot = '/win'
        function Get-Cmd([string]$arg) {
            # conhost --headless "powershell.exe" ... -Command "<cmd>": the command is everything inside the last quotes
            $i = $arg.IndexOf('-Command "'); $arg.Substring($i + 10, $arg.Length - $i - 11)
        }
        function Invoke-AtLogon([string]$cmd, [string]$lad) {
            $rec = Join-Path $script:tmp 'opened.txt'
            $pre = "function Start-Process([string]`$FilePath) { Add-Content -LiteralPath '$rec' -Value `$FilePath }; `$env:LOCALAPPDATA = '$lad'; "
            & $global:DosPsExe -NoProfile -NonInteractive -Command ($pre + $cmd) | Out-Null
            if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $rec) { return @(Microsoft.PowerShell.Management\Get-Content -LiteralPath $rec) } else { return @() }
        }
    }
    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $script:tmp 'opened.txt') -ErrorAction SilentlyContinue
        $script:page = Join-Path $script:tmp "What's new.html"; Set-Content -LiteralPath $script:page -Value '<html></html>'
    }
    It 'the generated command: opens once, not again, again for a new marker, quotes an apostrophe in the path' {
        Mock New-ScheduledTaskAction { $global:captured = $Argument; [pscustomobject]@{} }
        try { Register-DomainOSOpenAtLogon 'T' $script:page 'whatsnew-2.1.8' } catch { }
        $global:captured | Should -Match '^--headless "/win[\\/]System32[\\/]WindowsPowerShell[\\/]v1\.0[\\/]powershell\.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command "'
        $cmd = Get-Cmd $global:captured
        $cmd | Should -Not -Match '"' -Because 'a double quote would end the -Command argument on the Windows command line'
        $lad = Join-Path $script:tmp ('lad-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        @(Invoke-AtLogon $cmd $lad) | Should -Be @($script:page)
        @(Invoke-AtLogon $cmd $lad).Count | Should -Be 1 -Because 'the marker file stops a second opening'
        Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $lad 'Domain OS/shown-whatsnew-2.1.8') | Should -BeTrue
        try { Register-DomainOSOpenAtLogon 'T' $script:page 'whatsnew-2.1.9' } catch { }
        @(Invoke-AtLogon (Get-Cmd $global:captured) $lad).Count | Should -Be 2 -Because 'a new version opens the page again'
    }
    It 'refuses a missing page and bad marker names (<marker>)' -TestCases @(@{ marker = 'a b' }, @{ marker = '..\x' }, @{ marker = "x';evil" }, @{ marker = '' }) {
        { Register-DomainOSOpenAtLogon 'T' $script:page $marker } | Should -Throw '*bad marker*'
    }
    It 'refuses a page that is not there' {
        { Register-DomainOSOpenAtLogon 'T' (Join-Path $script:tmp 'none.html') 'm' } | Should -Throw '*not there*'
    }
}
}
