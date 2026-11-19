# Save-State.ps1 run end to end in a sandbox (temporary ProgramData, fake registry / services / tasks).
BeforeAll { . (Join-Path $PSScriptRoot 'Harness.ps1') }

Describe 'Save-State.ps1' {
    BeforeEach {
        Reset-DosWorld
        $script:sb = New-DosSandbox
        Initialize-DosWorldFromTasks $script:sb.Tasks
        Set-DosRegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuild' 'String' '26300'
        Set-DosRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 1
        $global:DosAppx = @('Microsoft.WindowsStore', 'Microsoft.BingNews', 'Clipchamp.Clipchamp')
        $script:ss = Join-Path $script:sb.Exe 'Save-State.ps1'
        $script:state = Join-Path $script:sb.Undo 'state.json'
        $script:orig = Join-Path $script:sb.Undo 'state.original.json'
        $script:ver = ([xml](Get-Content -Raw (Join-Path $script:sb.Playbook 'playbook.conf'))).Playbook.Version
        $script:items = @(. { . (Join-Path $global:DosPlaybook 'Executables\DomainOS-Common.ps1'); Get-DomainOSPlaybookItems $script:sb.Tasks })
    }
    AfterEach { Remove-DosSandbox $script:sb }

    It 'fresh install: records every item, value kinds and data, absent values, services, tasks; writes both copies and history' {
        # one value absent, one key unreadable, one service and one task not on this Windows
        $absent = $script:items | Where-Object kind -eq 'R' | Select-Object -First 1
        (Get-DosRegValues $absent.path).Remove($absent.name)
        $denied = $script:items | Where-Object { $_.kind -eq 'R' -and $_.path -ne $absent.path } | Select-Object -Last 1
        $global:DosRegDenied = @($denied.path.ToLower())
        $svcGone = ($script:items | Where-Object kind -eq 'S' | Select-Object -First 1).name
        $global:DosReg.Remove("hklm\system\currentcontrolset\services\$($svcGone.ToLower())")
        $taskGone = ($script:items | Where-Object kind -eq 'T' | Select-Object -First 1).path
        $global:DosTasks.Remove($taskGone)
        $global:DosTasks[($script:items | Where-Object kind -eq 'T' | Select-Object -Last 1).path].State = 'Disabled'

        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 0 -Because $r.Out
        $s = Get-Content -Raw $script:state | ConvertFrom-Json
        $s.versions | Should -Be @($script:ver)
        $s.build | Should -Be '26300'
        $s.hibernate | Should -BeTrue
        $s.apps | Should -Be @('Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.WindowsStore')
        $s.user | Should -Be 'PC\tester'
        $uniqueR = @($script:items | Where-Object kind -eq 'R' | ForEach-Object { "$($_.path)|$($_.name)" } | Select-Object -Unique)
        @($s.registry).Count | Should -Be $uniqueR.Count -Because 'every registry value of the task files is recorded once'
        $a = $s.registry | Where-Object { $_.path -eq $absent.path -and $_.name -eq $absent.name }
        $a.exists | Should -BeFalse
        $d = @($s.registry | Where-Object { $_.path -eq $denied.path })
        $d | ForEach-Object { $_.unreadable | Should -BeTrue -Because 'an unreadable value must not be recorded as "did not exist"' }
        $e = $s.registry | Where-Object { $_.exists -eq $true } | Select-Object -First 1
        $e.kind | Should -Be 'DWord'; $e.data | Should -Be 7
        ($s.services | Where-Object name -eq $svcGone) | Should -BeNullOrEmpty
        $svc = $s.services | Where-Object name -eq 'SysMain'
        $svc.start | Should -Be 3; $svc.running | Should -BeTrue
        ($s.tasks | Where-Object path -eq $taskGone) | Should -BeNullOrEmpty
        @($s.tasks | Where-Object enabled -eq $false).Count | Should -Be 1
        Test-Path -LiteralPath $script:orig | Should -BeTrue
        (Get-Content -Raw $script:orig) | Should -Be (Get-Content -Raw $script:state)
        Test-Path -LiteralPath "$script:state.tmp" | Should -BeFalse
        Get-Content (Join-Path $script:sb.Data 'history.log') | Should -Match "applied\s+$([regex]::Escape($script:ver))$"
        $global:DosCalls | Where-Object { $_ -like 'acl *' } | Should -Not -BeNullOrEmpty -Because 'the data folder gets its protected access list first'
    }

    It 'second install: the original state is kept, only new items are added, versions appended (File.Replace with [NullString])' {
        New-Item -ItemType Directory -Force -Path $script:sb.Undo | Out-Null
        $first = $script:items | Where-Object kind -eq 'R' | Select-Object -First 1
        $old = [ordered]@{ saved = 'first-save-2026-01-01'; user = 'PC\first'; build = '26200'; hibernate = $false; oneDrive = $true; apps = @('Old.App')
            versions = @('2.0.0'); registry = @([ordered]@{ path = $first.path; name = $first.name; exists = $true; kind = 'DWord'; data = 99 }); services = @(); tasks = @() }
        $old | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:state -Encoding UTF8
        $before = Get-Content -Raw $script:state
        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 0 -Because $r.Out
        $s = Get-Content -Raw $script:state | ConvertFrom-Json
        $s.saved | Should -Be 'first-save-2026-01-01'
        $s.user | Should -Be 'PC\first'
        $s.apps | Should -Be @('Old.App')
        $s.versions | Should -Be @('2.0.0', $script:ver)
        ($s.registry | Where-Object { $_.path -eq $first.path -and $_.name -eq $first.name }).data | Should -Be 99 -Because 'the ORIGINAL value wins over the value now'
        @($s.registry).Count | Should -BeGreaterThan 50
        (Get-Content -Raw $script:orig) | Should -Be $before -Because 'state.original.json is the untouched first state'
        $r.Out | Should -Match 'original state was kept'
        # a third run leaves state.original.json alone
        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 0
        (Get-Content -Raw $script:orig) | Should -Be $before
        (Get-Content -Raw $script:state | ConvertFrom-Json).versions | Should -Be @('2.0.0', $script:ver, $script:ver)
    }

    It 'the 2.1.4 bug is caught: the same script with File.Replace(..., $null) fails on an existing state' {
        $text = [IO.File]::ReadAllText($script:ss)
        $text.Contains('[NullString]::Value') | Should -BeTrue
        [IO.File]::WriteAllText($script:ss, $text.Replace('[NullString]::Value', '$null'))
        New-Item -ItemType Directory -Force -Path $script:sb.Undo | Out-Null
        (Invoke-DosScript $script:ss).Code | Should -Be 0 -Because 'the first run moves the file into place'
        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 1 -Because 'PowerShell passes "" for $null, which File.Replace refuses'
        $r.Out | Should -Match 'empty|not of a legal form' -Because '.NET (pwsh) and .NET Framework (powershell.exe) word it differently'
    }

    It 'state.json missing but state.original.json there: the original is used' {
        New-Item -ItemType Directory -Force -Path $script:sb.Undo | Out-Null
        [ordered]@{ saved = 'orig-save-2025-05-05'; user = 'PC\x'; registry = @(); services = @(); tasks = @(); versions = @('1.0.0'); apps = @() } | ConvertTo-Json | Set-Content -LiteralPath $script:orig -Encoding UTF8
        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 0 -Because $r.Out
        (Get-Content -Raw $script:state | ConvertFrom-Json).saved | Should -Be 'orig-save-2025-05-05'
        $r.Out | Should -Match 'taken from state.original.json'
    }

    It 'refuses (exit 1, file untouched) a state.json <why>' -TestCases @(
        @{ why = 'owned by a standard account'; content = '{"saved":"x","registry":[]}'; owner = 'S-1-5-21-1-2-3-1002' },
        @{ why = 'that is damaged'; content = '{"saved": "2026-01-0'; owner = 'S-1-5-18' },
        @{ why = 'without a registry list'; content = '{"saved":"x"}'; owner = 'S-1-5-18' },
        @{ why = 'without a saved time'; content = '{"registry":[]}'; owner = 'S-1-5-18' }
    ) {
        New-Item -ItemType Directory -Force -Path $script:sb.Undo | Out-Null
        Set-Content -LiteralPath $script:state -Value $content -NoNewline
        $global:DosOwners[[IO.Path]::GetFullPath($script:state)] = $owner
        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'FAILED, the install stops before any change'
        Get-Content -Raw $script:state | Should -Be $content
        Test-Path -LiteralPath $script:orig | Should -BeFalse
    }

    It 'removes a state.json.tmp left by an interrupted run and never uses it' {
        New-Item -ItemType Directory -Force -Path $script:sb.Undo | Out-Null
        Set-Content -LiteralPath "$script:state.tmp" -Value '{"saved":"evil","registry":[]}'
        (Invoke-DosScript $script:ss).Code | Should -Be 0
        (Get-Content -Raw $script:state | ConvertFrom-Json).saved | Should -Not -Be 'evil'
    }

    It 'without administrator rights it stops with exit 1 before writing' {
        $global:DosAdmin = $false
        $r = Invoke-DosScript $script:ss
        $r.Code | Should -Be 1
        Test-Path -LiteralPath $script:state | Should -BeFalse
    }
}
