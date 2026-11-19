# Undo-DomainOS.ps1 and Undo-AsSystem.ps1 run end to end in a sandbox, plus Install-DomainOS.ps1 parts.
BeforeAll { . (Join-Path $PSScriptRoot 'Harness.ps1') }

Describe 'Install-DomainOS.ps1 -Part Tools / Scheduler / WhatsNew / Guide' {
    BeforeEach { Reset-DosWorld; $script:sb = New-DosSandbox; $script:inst = Join-Path $script:sb.Exe 'Install-DomainOS.ps1'; $global:DosShortcuts.Clear() }
    AfterEach { Remove-DosSandbox $script:sb }

    It 'Tools: copies every tool Undo needs, writes the allow-list and the Start menu shortcuts' {
        $r = Invoke-DosScript $script:inst @{ Part = 'Tools' }
        $r.Code | Should -Be 0 -Because $r.Out
        $tools = Join-Path $env:ProgramFiles 'Domain OS/Tools'
        foreach ($f in 'DomainOS-Common.ps1', 'Undo-DomainOS.ps1', 'Undo-AsSystem.ps1', 'Set-PowerPlan.ps1', 'Set-StartPins.ps1', 'Set-Hypervisor.ps1', 'Set-Wallpapers.ps1', 'Remove-AppLeftovers.ps1', 'Restore-Updates.ps1', 'Install-Runtimes.ps1') {
            Test-Path -LiteralPath (Join-Path $tools $f) | Should -BeTrue -Because "$f is used from Program Files\Domain OS\Tools"
        }
        # every script Undo-DomainOS.ps1 starts or dot-sources from $PSScriptRoot is copied
        $undoText = Get-Content -Raw (Join-Path $script:sb.Exe 'Undo-DomainOS.ps1')
        foreach ($m in [regex]::Matches($undoText, "Join-Path \`$PSScriptRoot '([^']+\.ps1)'")) { Test-Path -LiteralPath (Join-Path $tools $m.Groups[1].Value) | Should -BeTrue -Because "Undo uses $($m.Groups[1].Value)" }
        $allow = @(Get-Content -LiteralPath (Join-Path $tools 'undo-allowlist.txt') -Encoding UTF8)
        $allow | Should -Contain 'S|SysMain'
        $allow.Count | Should -BeGreaterOrEqual 50
        Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Domain OS/Guide/whats-new.html') | Should -BeTrue
        $names = $global:DosShortcuts | ForEach-Object { Split-Path -Leaf $_.Path }
        foreach ($n in 'Undo Domain OS.lnk', "What's new in Domain OS.lnk", 'First steps (drivers).lnk') { $names | Should -Contain $n }
        ($global:DosShortcuts | Where-Object { $_.Path -like '*Undo Domain OS.lnk' }).Arguments | Should -Match 'Undo-DomainOS\.ps1'
    }
    It 'Tools: refuses (exit 1) when the task files cannot be read (allow-list too short)' {
        Get-ChildItem -LiteralPath $script:sb.Tasks -Filter *.yml | Remove-Item
        $r = Invoke-DosScript $script:inst @{ Part = 'Tools' }
        $r.Code | Should -Be 1 -Because 'the guard must stop an install whose task files were not read (it counts only the task-file items, not the legacy lists)'
        $r.Out | Should -Match 'gave only \d+ items for the Undo allow-list'
    }
    It 'Scheduler: registers the logon task from DomainScheduler-Task.xml with the program path and reads it back' {
        $r = Invoke-DosScript $script:inst @{ Part = 'Scheduler' }
        $r.Code | Should -Be 0 -Because $r.Out
        $t = $global:DosRegisteredTasks | Where-Object Name -eq 'DomainScheduler'
        $t.Xml | Should -Not -Match '\{EXE\}'
        ([xml]$t.Xml).Task | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Domain OS/DomainScheduler.exe') | Should -BeTrue
    }
    It 'Scheduler: an ampersand in Program Files is escaped in the task XML' {
        $env:ProgramFiles = Join-Path $script:sb.Root 'Program & Files'
        New-Item -ItemType Directory -Force -Path $env:ProgramFiles | Out-Null
        $r = Invoke-DosScript $script:inst @{ Part = 'Scheduler' }
        $r.Code | Should -Be 0 -Because $r.Out
    }
    It 'Scheduler: refuses when DomainScheduler.exe is not in the playbook' {
        Remove-Item -LiteralPath (Join-Path $script:sb.Exe 'DomainScheduler.exe')
        (Invoke-DosScript $script:inst @{ Part = 'Scheduler' }).Code | Should -Be 1
    }
    It 'WhatsNew: the logon task opens whats-new.html once per account and version' {
        (Invoke-DosScript $script:inst @{ Part = 'Tools' }).Code | Should -Be 0
        $null = Invoke-DosScript $script:inst @{ Part = 'WhatsNew' }   # stops at the principal on Linux (SID translation); the action is built before
        $a = $global:DosActions | Select-Object -Last 1
        $a | Should -Not -BeNullOrEmpty
        $a.Execute | Should -Match 'conhost\.exe$'
        $ver = ([xml](Get-Content -Raw (Join-Path $script:sb.Playbook 'playbook.conf'))).Playbook.Version
        $a.Arguments | Should -Match ([regex]::Escape("shown-whatsnew-$ver"))
        $lad = Join-Path $script:sb.Root 'user1'; $rec = Join-Path $script:sb.Root 'opened.txt'
        @(Invoke-DosLogonCommand $a.Arguments $lad $rec) | Should -Be @((Join-Path $env:ProgramFiles 'Domain OS/Guide/whats-new.html'))
        @(Invoke-DosLogonCommand $a.Arguments $lad $rec).Count | Should -Be 1 -Because 'the second sign-in does not open it again'
        @(Invoke-DosLogonCommand $a.Arguments (Join-Path $script:sb.Root 'user2') $rec).Count | Should -Be 2 -Because 'another account sees it once too'
    }
    It 'Guide: the logon task runs New-DriverGuide.ps1 once per account' {
        (Invoke-DosScript $script:inst @{ Part = 'Tools' }).Code | Should -Be 0
        $rec = Join-Path $script:sb.Root 'guide-ran.txt'
        Set-Content -LiteralPath (Join-Path $env:ProgramFiles 'Domain OS/Guide/New-DriverGuide.ps1') -Value "Add-Content -LiteralPath '$rec' -Value ran"
        $null = Invoke-DosScript $script:inst @{ Part = 'Guide' }
        $a = $global:DosActions | Select-Object -Last 1
        $a.Arguments | Should -Match 'shown-guide'
        $lad = Join-Path $script:sb.Root 'user1'
        $null = Invoke-DosLogonCommand $a.Arguments $lad (Join-Path $script:sb.Root 'x.txt')
        $null = Invoke-DosLogonCommand $a.Arguments $lad (Join-Path $script:sb.Root 'x.txt')
        @(Get-Content -LiteralPath $rec).Count | Should -Be 1
    }
    It 'rejects an unknown -Part' {
        { & $script:inst -Part Everything } | Should -Throw
    }
}

Describe 'Undo-DomainOS.ps1' {
    BeforeEach {
        Reset-DosWorld
        $script:sb = New-DosSandbox
        Initialize-DosWorldFromTasks $script:sb.Tasks
        $r = Invoke-DosScript (Join-Path $script:sb.Exe 'Install-DomainOS.ps1') @{ Part = 'Tools' }
        if ($r.Code -ne 0) { throw "Install -Part Tools failed: $($r.Out)" }
        $script:undo = Join-Path $env:ProgramFiles 'Domain OS/Tools/Undo-DomainOS.ps1'
        $script:state = Join-Path $script:sb.Undo 'state.json'
        $prio = 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'
        $hags = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $script:diagTask = '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        $script:protTask = '\Microsoft\Windows\Maps\MapsUpdateTask'
        Set-DosRegValue $prio 'Win32PrioritySeparation' 'DWord' 24
        Set-DosRegValue $hags 'HwSchMode' 'DWord' 2
        Set-DosRegValue 'HKLM\SOFTWARE\Evil' 'Run' 'String' 'now'
        Set-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\WinDefend' 'Start' 'DWord' 2
        Set-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\SysMain' 'Start' 'DWord' 3
        Set-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' 'DWord' 4
        Set-DosRegValue 'HKLM\SOFTWARE\Domain OS\Options' 'apps-basic' 'DWord' 1
        $global:DosRegProtected = @('hklm\system\currentcontrolset\services\diagtrack')
        $global:DosTasks[$script:diagTask].State = 'Disabled'
        $global:DosTasks[$script:protTask] = @{ State = 'Disabled'; Protected = $true }
        $global:DosTasks['\Microsoft\Windows\Windows Defender\Scan'] = @{ State = 'Disabled'; Protected = $false }
        $global:DosAppx = @('Microsoft.BingNews')
        $state = [ordered]@{
            saved = 'saved-1'; user = 'PC\tester'; build = '26300'; hibernate = $false; oneDrive = $false; versions = @('2.1.8'); classicMenu = $true
            apps = @('Microsoft.BingNews', 'Microsoft.WindowsStore', 'Microsoft.VCLibs.140.00')
            registry = @(
                [ordered]@{ path = $prio; name = 'Win32PrioritySeparation'; exists = $true; kind = 'DWord'; data = 38 },
                [ordered]@{ path = $hags; name = 'HwSchMode'; exists = $false; kind = ''; data = $null },
                [ordered]@{ path = 'HKLM\SOFTWARE\Evil'; name = 'Run'; exists = $true; kind = 'String'; data = 'planted' },
                [ordered]@{ path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; name = 'AllowTelemetry'; exists = $null; unreadable = $true },
                [ordered]@{ path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; name = 'LimitDumpCollection'; exists = $true; kind = 'Weird'; data = 1 })
            services = @(
                [ordered]@{ name = 'SysMain'; start = 2; running = $true },
                [ordered]@{ name = 'WinDefend'; start = 4; running = $false },
                [ordered]@{ name = 'DiagTrack'; start = 2; running = $true },
                [ordered]@{ name = 'WerSvc'; start = 9; running = $false })
            tasks = @(
                [ordered]@{ path = $script:diagTask; enabled = $true },
                [ordered]@{ path = $script:protTask; enabled = $true },
                [ordered]@{ path = '\Microsoft\Windows\Windows Defender\Scan'; enabled = $true })
        }
        New-Item -ItemType Directory -Force -Path $script:sb.Undo | Out-Null
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:state -Encoding UTF8
        Enable-DosSystemRunner
    }
    AfterEach { Remove-DosSandbox $script:sb }

    It 'restores only allow-listed items, sends what administrators may not change to the SYSTEM step, then retires the state' {
        $r = Invoke-DosScript $script:undo
        $prio = 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl'
        Get-DosRegValue $prio 'Win32PrioritySeparation' | Should -Be 38
        (Get-DosRegValues 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers').Contains('HwSchMode') | Should -BeFalse -Because 'a value that did not exist is removed'
        Get-DosRegValue 'HKLM\SOFTWARE\Evil' 'Run' | Should -Be 'now' -Because 'a value outside the allow-list is never written'
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\WinDefend' 'Start' | Should -Be 2 -Because 'a service outside the allow-list is never changed'
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\SysMain' 'Start' | Should -Be 2
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 2 -Because 'restored by the SYSTEM step'
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\WerSvc' 'Start' | Should -Be 3 -Because 'start type 9 is not usable'
        $global:DosTasks[$script:diagTask].State | Should -Be 'Ready'
        $global:DosTasks[$script:protTask].State | Should -Be 'Ready' -Because 'restored by the SYSTEM step'
        $global:DosTasks['\Microsoft\Windows\Windows Defender\Scan'].State | Should -Be 'Disabled'
        $sys = $global:DosRegisteredTasks | Where-Object Name -like '*one-shot*'
        @($sys).Count | Should -Be 1
        $global:DosTasks.Keys | Where-Object { $_ -like '*one-shot*' } | Should -BeNullOrEmpty -Because 'the one-shot task is removed again'
        Test-Path -LiteralPath (Join-Path $script:sb.Undo 'system') | Should -BeFalse -Because 'the work folder is removed'
        $r.Out | Should -Match 'Skipped HKLM\\SOFTWARE\\Evil\\Run'
        $r.Out | Should -Match 'Skipped .*AllowTelemetry: it could not be read'
        $r.Out | Should -Match "FAILED registry .*LimitDumpCollection: unexpected value type 'Weird'"
        $r.Out | Should -Match 'Microsoft.WindowsStore'
        $r.Out | Should -Not -Match 'Microsoft.VCLibs' -Because 'framework packages are not listed as removed apps'
        $global:DosStarted | Where-Object FilePath -eq 'wsreset.exe' | Should -Not -BeNullOrEmpty
        # LimitDumpCollection failed: the state is kept for the next try, exit 1
        $r.Code | Should -Be 1
        Test-Path -LiteralPath $script:state | Should -BeTrue
        Test-DosRegKey 'HKLM\SOFTWARE\Domain OS\Options' | Should -BeTrue -Because 'the options record goes only after a complete undo'
    }

    It 'a complete undo renames the state, writes history and removes the options record (exit 0)' {
        $s = Get-Content -Raw $script:state | ConvertFrom-Json
        $s.registry = @($s.registry | Where-Object { $_.kind -ne 'Weird' })
        $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:state -Encoding UTF8
        $r = Invoke-DosScript $script:undo
        $r.Code | Should -Be 0 -Because $r.Out
        Test-Path -LiteralPath $script:state | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:sb.Undo -Filter 'state-restored-*.json').Count | Should -Be 1
        Get-Content (Join-Path $script:sb.Data 'history.log') | Should -Match 'undone\s+2\.1\.8'
        Test-DosRegKey 'HKLM\SOFTWARE\Domain OS\Options' | Should -BeFalse
    }

    It '-WhatIf changes nothing: registry, services, tasks, files, no scheduled task' {
        $before = Get-DosRegSnapshot
        $tasksBefore = ($global:DosTasks.Keys | Sort-Object | ForEach-Object { "$_=$($global:DosTasks[$_].State)" }) -join ';'
        $files = (Get-ChildItem -LiteralPath $script:sb.Data -Recurse -File | ForEach-Object { $_.FullName + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';'
        $r = Invoke-DosScript $script:undo @{ WhatIf = $true }
        Get-DosRegSnapshot | Should -Be $before
        ($global:DosTasks.Keys | Sort-Object | ForEach-Object { "$_=$($global:DosTasks[$_].State)" }) -join ';' | Should -Be $tasksBefore
        $global:DosRegisteredTasks.Count | Should -Be 0
        $global:DosStarted.Count | Should -Be 0
        (Get-ChildItem -LiteralPath $script:sb.Data -Recurse -File | Where-Object Name -ne 'undo.log' | ForEach-Object { $_.FullName + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';' |
            Should -Be (($files -split ';' | Where-Object { $_ -notmatch 'undo\.log' }) -join ';')
        Test-Path -LiteralPath $script:state | Should -BeTrue
    }

    It 'a state.json of a standard account is not used: nothing is changed, exit 1' {
        $global:DosOwners[[IO.Path]::GetFullPath($script:state)] = 'S-1-5-21-1-2-3-1002'
        $before = Get-DosRegSnapshot
        $r = Invoke-DosScript $script:undo
        $r.Code | Should -Be 1
        Get-DosRegSnapshot | Should -Be $before
    }

    It 'an untrusted undo-allowlist.txt: no registry value, service or task is restored, the state is kept' {
        $global:DosOwners[[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Domain OS/Tools/undo-allowlist.txt'))] = 'S-1-5-21-1-2-3-1002'
        $r = Invoke-DosScript $script:undo
        $r.Code | Should -Be 1
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' | Should -Be 24
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\SysMain' 'Start' | Should -Be 3
        $r.Out | Should -Match 'FAILED: the list of what Undo may restore'
        Test-Path -LiteralPath $script:state | Should -BeTrue
    }

    It 'the SYSTEM step missing: the items count as failed and the state is kept' {
        Remove-Item -LiteralPath (Join-Path $env:ProgramFiles 'Domain OS/Tools/Undo-AsSystem.ps1')
        $r = Invoke-DosScript $script:undo
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'FAILED the SYSTEM step'
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 4
    }
}

Describe 'Undo-AsSystem.ps1' {
    BeforeEach {
        Reset-DosWorld
        $script:sb = New-DosSandbox
        $script:box = Join-Path $script:sb.Undo 'system'
        New-Item -ItemType Directory -Force -Path $script:box | Out-Null
        $script:work = Join-Path $script:box 'work.json'; $script:result = Join-Path $script:box 'result.json'
        $script:uas = Join-Path $script:sb.Exe 'Undo-AsSystem.ps1'
        Set-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' 'DWord' 4
        Set-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\WinDefend' 'Start' 'DWord' 2
        $global:DosTasks['\Microsoft\Windows\Maps\MapsUpdateTask'] = @{ State = 'Disabled'; Protected = $true }
        $global:DosAsSystem = $true
        function script:Run-Work($items, [string]$work = $script:work, [string]$result = $script:result) {
            ConvertTo-Json -InputObject @($items) -Depth 3 | Set-Content -LiteralPath $work -Encoding UTF8
            $r = Invoke-DosScript $script:uas @{ Work = $work; Result = $result }
            $ans = if (Test-Path -LiteralPath $result) { @(Get-Content -Raw -LiteralPath $result | ConvertFrom-Json) } else { @() }
            return [pscustomobject]@{ Code = $r.Code; Answers = $ans; Out = $r.Out }
        }
    }
    AfterEach { Remove-DosSandbox $script:sb }

    It 'restores an allowed service and task and answers ok for each' {
        $x = Run-Work @([pscustomobject]@{ kind = 'S'; name = 'DiagTrack'; start = 2; running = $true }, [pscustomobject]@{ kind = 'T'; name = '\Microsoft\Windows\Maps\MapsUpdateTask'; enabled = $true })
        $x.Code | Should -Be 0 -Because $x.Out
        @($x.Answers | Where-Object ok).Count | Should -Be 2
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 2
        $global:DosTasks['\Microsoft\Windows\Maps\MapsUpdateTask'].State | Should -Be 'Ready'
    }
    It 'refuses item <why>' -TestCases @(
        @{ why = 'a service outside the allow-list'; item = @{ kind = 'S'; name = 'WinDefend'; start = 4 }; msg = 'not a service Domain OS changes' },
        @{ why = 'a service name with a path'; item = @{ kind = 'S'; name = 'DiagTrack\..\WinDefend'; start = 4 }; msg = 'not a service' },
        @{ why = 'a start type out of range'; item = @{ kind = 'S'; name = 'DiagTrack'; start = 7 }; msg = 'not 0-4' },
        @{ why = 'a negative start type'; item = @{ kind = 'S'; name = 'DiagTrack'; start = -1 }; msg = 'not 0-4' },
        @{ why = 'a task outside the allow-list'; item = @{ kind = 'T'; name = '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan'; enabled = $false }; msg = 'not a task' },
        @{ why = 'an unknown kind'; item = @{ kind = 'Q'; name = 'HKLM\SOFTWARE\X' }; msg = 'unknown item kind' }
        @{ why = 'a registry value Domain OS does not change'; item = @{ kind = 'R'; name = 'HKLM\SOFTWARE\X\Y'; path = 'HKLM\SOFTWARE\X'; value = 'Y'; exists = $true; type = 'DWord'; data = 1 }; msg = 'not a value Domain OS changes' }
        @{ why = 'an HKCU value'; item = @{ kind = 'R'; name = 'HKCU\Software\X\Y'; path = 'HKCU\Software\X'; value = 'Y'; exists = $true; type = 'DWord'; data = 1 }; msg = 'not a value Domain OS changes' }
    ) {
        $x = Run-Work @([pscustomobject]$item)
        $x.Answers[0].ok | Should -BeFalse
        $x.Answers[0].error | Should -Match $msg
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\WinDefend' 'Start' | Should -Be 2
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 4
    }
    It 'refuses a work file outside %ProgramData%\Domain OS\Undo\system (exit 1, nothing done)' {
        $w = Join-Path $script:sb.Root 'work.json'
        $x = Run-Work @([pscustomobject]@{ kind = 'S'; name = 'DiagTrack'; start = 2 }) $w (Join-Path $script:sb.Root 'result.json')
        $x.Code | Should -Be 1
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 4
    }
    It 'refuses a work file a standard account owns (exit 1, answer X)' {
        ConvertTo-Json -InputObject @([pscustomobject]@{ kind = 'S'; name = 'DiagTrack'; start = 2 }) | Set-Content -LiteralPath $script:work
        $global:DosOwners[[IO.Path]::GetFullPath($script:work)] = 'S-1-5-21-1-2-3-1002'
        $r = Invoke-DosScript $script:uas @{ Work = $script:work; Result = $script:result }
        $r.Code | Should -Be 1
        $a = @(Get-Content -Raw $script:result | ConvertFrom-Json)
        $a[0].kind | Should -Be 'X'
        $a[0].error | Should -Match 'not trusted'
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 4
    }
    It 'refuses a work file that is a symbolic link' {
        $real = Join-Path $script:sb.Root 'real.json'
        ConvertTo-Json -InputObject @([pscustomobject]@{ kind = 'S'; name = 'DiagTrack'; start = 2 }) | Set-Content -LiteralPath $real
        New-DosSymlink $script:work $real
        (Invoke-DosScript $script:uas @{ Work = $script:work; Result = $script:result }).Code | Should -Be 1
        Get-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' | Should -Be 4
    }
}
