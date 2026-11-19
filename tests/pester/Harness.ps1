<#
  Windows stand-ins for running the Domain OS scripts on Linux PowerShell 7 (Pester tests in this folder).

  What is real: the scripts themselves, their logic, the file system (a temporary folder per test), JSON, .NET.
  What is faked: the registry (an in-memory tree, $global:DosReg), scheduled tasks, services, appx packages, ACL owners
  (DomainOS-Common's Get-DomainOSOwner reads $global:DosOwners, default SYSTEM), elevation, Start-Process, Start-Sleep.

  New-DosSandbox copies the playbook (without the 70 MB DomainScheduler.exe) into a temporary folder and appends a
  small "shim" to the sandbox copy of DomainOS-Common.ps1 that replaces only the Windows-only primitives (owner,
  takeown, ACL writes, administrator check). Everything above those primitives runs unchanged.
  Save-State.ps1 reads the registry through [Microsoft.Win32.Registry]::LocalMachine/CurrentUser, which cannot be
  faked from outside; those two expressions are rewritten to the fake registry in the sandbox copy (the test fails
  if they are not found, so a change in the script cannot silently bypass the fake).
#>
$ErrorActionPreference = 'Stop'
$global:DosRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$global:DosPlaybook = Join-Path $global:DosRepo 'playbook'
# The PowerShell that runs these tests, for child processes: pwsh (Linux / Windows) or Windows PowerShell 5.1 (CI on Windows).
$global:DosPsExe = if ($PSVersionTable.PSEdition -eq 'Desktop') { Join-Path $PSHOME 'powershell.exe' } elseif ($IsWindows) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }

# ---- fake registry -----------------------------------------------------------------------------------------------
class DosRegKey {
    [string]$Path
    DosRegKey([string]$p) { $this.Path = $p }
    [object] OpenSubKey([string]$sub, [bool]$w) {
        $p = $this.Path + '\' + $sub
        if ($global:DosRegDenied -contains $p.ToLower()) { throw [System.Security.SecurityException]::new("Requested registry access is not allowed. ($p)") }
        if (Test-DosRegKey $p) { return [DosRegKey]::new($p) } else { return $null }
    }
    [string[]] GetValueNames() {
        if ($global:DosRegDenied -contains $this.Path.ToLower()) { throw [System.Security.SecurityException]::new('denied') }
        return @((Get-DosRegValues $this.Path).Keys)
    }
    [object] GetValueKind([string]$n) { return [Microsoft.Win32.RegistryValueKind](Get-DosRegValues $this.Path)[$n].kind }
    [object] GetValue([string]$n, $d, $o) { $v = (Get-DosRegValues $this.Path)[$n]; if ($v) { return $v.data } else { return $d } }
    [object] GetValue([string]$n) { return $this.GetValue($n, $null, $null) }
    [void] SetValue([string]$n, $d, $k) { Set-DosRegValue $this.Path $n "$k" $d }
    [object] CreateSubKey([string]$sub) { $p = $this.Path + '\' + $sub; New-DosRegKey $p; return [DosRegKey]::new($p) }
    [void] Close() { }
}
class DosRegRoot { [object] Hive([string]$h) { return [DosRegKey]::new($h) } }
$global:DosRegRoot = [DosRegRoot]::new()

function global:Reset-DosWorld {
    $global:DosReg = @{}              # lower-case key path -> @{ path; values = ordered name -> @{ kind; data } }
    $global:DosRegDenied = @()        # lower-case key paths whose reading throws
    $global:DosRegProtected = @()     # lower-case key paths administrators may not write (SYSTEM may)
    $global:DosAsSystem = $false
    $global:DosOwners = @{}           # full path -> owner SID (default S-1-5-18)
    $global:DosAdmin = $true
    $global:DosTasks = @{}            # '\path\name' -> @{ State = 'Ready'|'Disabled'; Protected = $bool }
    $global:DosRegisteredTasks = New-Object System.Collections.Generic.List[object]
    $global:DosStarted = New-Object System.Collections.Generic.List[object]
    $global:DosServices = @{}         # name -> 'Running' / 'Stopped'
    $global:DosAppx = @()
    $global:DosCalls = New-Object System.Collections.Generic.List[string]
    $global:DosOnStartTask = $null   # scriptblock run by Start-ScheduledTask (the SYSTEM step)
    if ($global:DosActions) { $global:DosActions.Clear() }
}
Reset-DosWorld

function global:ConvertTo-DosRegPath([string]$p) {
    $p = $p -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_CURRENT_USER', 'HKCU' -replace '^(HKLM|HKCU):\\?', '$1\'
    return $p.TrimEnd('\') -replace '/', '\'
}
function global:Test-DosRegPath([string]$p) { return $p -match '^(Registry::|Microsoft\.PowerShell\.Core\\Registry::|HKLM:|HKCU:|HKEY_)' }
function global:Test-DosRegKey([string]$p) { return $global:DosReg.ContainsKey((ConvertTo-DosRegPath $p).ToLower()) }
function global:New-DosRegKey([string]$p) {
    $p = ConvertTo-DosRegPath $p
    $parts = $p.Split('\')
    for ($i = 1; $i -le $parts.Count; $i++) {
        $k = ($parts[0..($i - 1)] -join '\')
        if (-not $global:DosReg.ContainsKey($k.ToLower())) { $global:DosReg[$k.ToLower()] = @{ path = $k; values = [ordered]@{} } }
    }
}
function global:Get-DosRegValues([string]$p) { $k = $global:DosReg[(ConvertTo-DosRegPath $p).ToLower()]; if ($k) { return $k.values } else { return [ordered]@{} } }
function global:Set-DosRegValue([string]$p, [string]$name, [string]$kind, $data) {
    $p = ConvertTo-DosRegPath $p
    if ($global:DosRegProtected -contains $p.ToLower() -and -not $global:DosAsSystem) { throw [System.UnauthorizedAccessException]::new("Requested registry access is not allowed. ($p)") }
    New-DosRegKey $p
    $global:DosReg[$p.ToLower()].values[$name] = @{ kind = $kind; data = $data }
}
function global:Get-DosRegValue([string]$p, [string]$name) { $v = (Get-DosRegValues $p)[$name]; if ($v) { return $v.data } }
function global:Get-DosRegSnapshot { return ($global:DosReg.Values | Sort-Object path | ForEach-Object { $k = $_; "$($k.path)=" + (($k.values.Keys | ForEach-Object { "${_}:$($k.values[$_].kind)=$($k.values[$_].data -join ',')" }) -join '|') }) -join "`n" }

# ---- cmdlets that also take registry paths: registry -> fake, anything else -> the real cmdlet ------------------------
function global:Test-Path {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Microsoft.PowerShell.Commands.TestPathType]$PathType, [switch]$IsValid)
    $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
    if ($p -and (Test-DosRegPath $p)) { return (Test-DosRegKey $p) }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function global:Get-ItemProperty {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string[]]$Name)
    $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
    if (-not (Test-DosRegPath $p)) { return Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters }
    if (-not (Test-DosRegKey $p)) { Write-Error "Cannot find path '$p' because it does not exist." -Category ObjectNotFound; return }
    if ($global:DosRegDenied -contains (ConvertTo-DosRegPath $p).ToLower()) { Write-Error "Requested registry access is not allowed. ($p)" -Category PermissionDenied; return }
    $vals = Get-DosRegValues $p
    $o = [ordered]@{}
    foreach ($k in $vals.Keys) { if (-not $Name -or $Name -contains $k) { $o[$k] = $vals[$k].data } }
    if ($Name -and $o.Count -eq 0) { Write-Error "Property $Name does not exist at path $p." -Category InvalidArgument; return }
    return [pscustomobject]$o
}
function global:Set-ItemProperty {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string]$Name, [Parameter(Position = 2)]$Value, [string]$Type, [switch]$Force)
    $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
    if (-not (Test-DosRegPath $p)) { return Microsoft.PowerShell.Management\Set-ItemProperty @PSBoundParameters }
    $global:DosCalls.Add("Set-ItemProperty $p $Name $Value")
    if (-not (Test-DosRegKey $p)) { Write-Error "Cannot find path '$p'" -Category ObjectNotFound; return }
    try { Set-DosRegValue $p $Name $(if ($Type) { $Type } else { 'DWord' }) $Value } catch { Write-Error $_.Exception.Message -Category PermissionDenied }
}
function global:New-ItemProperty {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string]$Name, $Value, [string]$PropertyType, [switch]$Force)
    $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
    $global:DosCalls.Add("New-ItemProperty $p $Name $PropertyType $Value")
    try { Set-DosRegValue $p $Name $PropertyType $Value } catch { Write-Error $_.Exception.Message -Category PermissionDenied }
}
function global:Remove-ItemProperty {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [Parameter(Position = 1)][string[]]$Name, [switch]$Force)
    $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
    $global:DosCalls.Add("Remove-ItemProperty $p $Name")
    $vals = Get-DosRegValues $p
    foreach ($n in $Name) { if ($vals.Contains($n)) { $vals.Remove($n) } else { Write-Error "Property $n does not exist" -Category InvalidArgument } }
}
function global:Get-Item {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string[]]$LiteralPath, [switch]$Force)
    $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
    if (-not (Test-DosRegPath $p)) { return Microsoft.PowerShell.Management\Get-Item @PSBoundParameters }
    if (-not (Test-DosRegKey $p)) { Write-Error "Cannot find path '$p'" -Category ObjectNotFound; return }
    $o = [pscustomobject]@{ PSPath = $p }
    $o | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value ([scriptblock]::Create("@((Get-DosRegValues '$($p.Replace("'", "''"))').Keys)"))
    return $o
}
function global:New-Item {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [string]$ItemType, [string]$Name, $Value, [switch]$Force)
    if ($Path -and (Test-DosRegPath $Path[0])) { foreach ($x in $Path) { New-DosRegKey $x }; return [pscustomobject]@{ PSPath = $Path[0] } }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function global:Remove-Item {
    [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Path, [Parameter(ValueFromPipelineByPropertyName)][Alias('PSPath')][string[]]$LiteralPath, [switch]$Recurse, [switch]$Force, [string]$Filter)
    process {
        $p = @($LiteralPath) + @($Path) | Where-Object { $_ } | Select-Object -First 1
        if ($p -and (Test-DosRegPath $p)) {
            $global:DosCalls.Add("Remove-Item $p")
            $k = (ConvertTo-DosRegPath $p).ToLower()
            if (-not $global:DosReg.ContainsKey($k)) { Write-Error "Cannot find path '$p'" -Category ObjectNotFound; return }
            foreach ($x in @($global:DosReg.Keys)) { if ($x -eq $k -or $x.StartsWith($k + '\')) { $global:DosReg.Remove($x) } }
            return
        }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
}

# ---- scheduled tasks, services, apps, processes ------------------------------------------------------------------
function global:Get-ScheduledTask {
    [CmdletBinding()] param([string]$TaskPath, [Parameter(Position = 0)][string]$TaskName)
    $full = if ($TaskPath) { $TaskPath + $TaskName } else { @($global:DosTasks.Keys | Where-Object { $_ -like "*\$TaskName" })[0] }
    if ($full -and $global:DosTasks.ContainsKey($full)) {
        $t = $global:DosTasks[$full]
        return [pscustomobject]@{ TaskPath = $full.Substring(0, $full.LastIndexOf('\') + 1); TaskName = $full.Substring($full.LastIndexOf('\') + 1); State = $t.State; Actions = $t.Actions; FullName = $full }
    }
    Write-Error "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'." -Category ObjectNotFound
}
function global:Set-DosTaskState([Parameter(ValueFromPipeline)]$InputObject, [string]$State) {
    $full = $InputObject.FullName
    if ($global:DosTasks[$full].Protected -and -not $global:DosAsSystem) { throw [System.UnauthorizedAccessException]::new("Access is denied. ($full)") }
    $global:DosTasks[$full].State = $State
    $global:DosCalls.Add("Task $full $State")
}
function global:Enable-ScheduledTask { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) process { try { Set-DosTaskState $InputObject 'Ready' } catch { Write-Error $_.Exception.Message } } }
function global:Disable-ScheduledTask { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject) process { try { Set-DosTaskState $InputObject 'Disabled' } catch { Write-Error $_.Exception.Message } } }
$global:DosActions = New-Object System.Collections.Generic.List[object]
function global:New-ScheduledTaskAction { param([string]$Execute, [string]$Argument, [string]$WorkingDirectory) $a = [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }; $global:DosActions.Add($a); $a }
function global:New-ScheduledTaskTrigger { param([switch]$AtLogOn, [switch]$Once, $At) [pscustomobject]@{ AtLogOn = [bool]$AtLogOn; Delay = $null; EndBoundary = $null } }
function global:New-ScheduledTaskPrincipal { param([string]$UserId, [string]$GroupId, [string]$LogonType, [string]$RunLevel) [pscustomobject]@{ UserId = $UserId; GroupId = $GroupId; LogonType = $LogonType; RunLevel = $RunLevel } }
function global:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $DeleteExpiredTaskAfter, $ExecutionTimeLimit) [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit } }
function global:Register-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath = '\', $Action, $Trigger, $Principal, $Settings, [string]$Xml, [switch]$Force)
    $acts = @($Action)
    if ($Xml) {
        $doc = [xml]$Xml       # throws on a malformed task XML
        $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $acts = @($doc.SelectNodes('//t:Exec', $ns) | ForEach-Object { [pscustomobject]@{ Execute = $_.Command; Arguments = $_.Arguments } })
    }
    $full = $TaskPath + $TaskName
    $global:DosRegisteredTasks.Add([pscustomobject]@{ Name = $TaskName; Path = $TaskPath; Action = $Action; Trigger = $Trigger; Principal = $Principal; Settings = $Settings; Xml = $Xml })
    $global:DosTasks[$full] = @{ State = 'Ready'; Protected = $false; Actions = $acts }
    return [pscustomobject]@{ TaskName = $TaskName }
}
function global:Unregister-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath = '\', [switch]$Confirm) $global:DosCalls.Add("Unregister $TaskPath$TaskName"); [void]$global:DosTasks.Remove($TaskPath + $TaskName) }
function global:Start-ScheduledTask {
    [CmdletBinding()] param([string]$TaskName, [string]$TaskPath = '\')
    $global:DosCalls.Add("Start-ScheduledTask $TaskName")
    if ($global:DosOnStartTask) { & $global:DosOnStartTask $TaskName }
}
function global:Stop-ScheduledTask { [CmdletBinding()] param([string]$TaskName) }
function global:Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name) foreach ($n in $Name) { if ($global:DosServices.ContainsKey($n)) { [pscustomobject]@{ Name = $n; Status = $global:DosServices[$n] } } else { Write-Error "Cannot find any service with service name '$n'." -Category ObjectNotFound } } }
function global:Start-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name) $global:DosCalls.Add("Start-Service $Name"); $global:DosServices[$Name] = 'Running' }
function global:Get-AppxPackage { [CmdletBinding()] param([switch]$AllUsers, [string]$Name) $global:DosAppx | ForEach-Object { [pscustomobject]@{ Name = $_; PackageFullName = "${_}_1.0_x64__8wekyb3d8bbwe" } } }
function global:Start-Process { [CmdletBinding()] param([Parameter(Position = 0)][string]$FilePath, [Parameter(Position = 1)]$ArgumentList, [string]$Verb, [switch]$PassThru, [switch]$Wait, [string]$WindowStyle)
    $global:DosStarted.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList; Verb = $Verb }) }
function global:Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
function global:Get-Acl { [CmdletBinding()] param([string]$LiteralPath, [string]$Path) throw 'Get-Acl: replace with a Pester Mock' }
function global:Get-LocalGroupMember { [CmdletBinding()] param([string]$SID, [string]$Group) throw 'Get-LocalGroupMember: replace with a Pester Mock' }

# ---- sandbox ---------------------------------------------------------------------------------------------------------
# Appended to the sandbox copy of DomainOS-Common.ps1: only the Windows-only primitives are replaced.
$global:DosShim = @'

# ===== test shim (tests/pester/Harness.ps1): Windows-only primitives replaced, everything above runs unchanged =====
function Test-DomainOSAdmin { return [bool]$global:DosAdmin }
function Get-DomainOSOwner([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($global:DosOwners.ContainsKey($full)) { return $global:DosOwners[$full] }
    return 'S-1-5-18'
}
function Set-DomainOSOwner([string]$Path) { $global:DosOwners[[IO.Path]::GetFullPath($Path)] = 'S-1-5-32-544'; $global:DosCalls.Add("takeown $Path") }
function Set-DomainOSFolderAcl([string]$Path, [string[]]$Readers) { $global:DosCalls.Add("acl $Path " + ($Readers -join ',')) }
function Remove-DomainOSWriteAces($Item) { }
$script:DomainOSAdminSids = $null
# the account comes from the process token on Windows; here from the sandbox's variables
function Get-DomainOSUser { return [pscustomobject]@{ Name = $env:USERNAME; Full = "$env:USERDOMAIN\$env:USERNAME"; Sid = 'S-1-5-21-1-2-3-1001' } }
function Get-DomainOSUserFolder([string]$Which) { switch ($Which) { 'ApplicationData' { return $env:APPDATA } 'LocalApplicationData' { return $env:LOCALAPPDATA } default { throw "the folder $Which is not faked" } } }
function Get-DomainOSAdminSids { $s = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); foreach ($x in @($DomainOSTrustedOwners) + @($global:DosAdminAccounts)) { if ($x) { [void]$s.Add($x) } }; return ,$s }
'@
$global:DosAdminAccounts = @('S-1-5-21-1-2-3-1001')   # the administrator account that installs

function global:New-DosSandbox {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('dos-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
    $pb = Join-Path $root 'pb'
    New-Item -ItemType Directory -Force -Path (Join-Path $pb 'Executables'), (Join-Path $root 'ProgramData'), (Join-Path $root 'ProgramFiles'), (Join-Path $root 'Windows\System32\WindowsPowerShell\v1.0'), (Join-Path $root 'LocalAppData'), (Join-Path $root 'AppData') | Out-Null
    Copy-Item -Path (Join-Path $global:DosPlaybook 'Configuration') -Destination $pb -Recurse
    Copy-Item -Path (Join-Path $global:DosPlaybook 'playbook.conf') -Destination $pb
    Get-ChildItem -LiteralPath (Join-Path $global:DosPlaybook 'Executables') | Where-Object { $_.Name -ne 'DomainScheduler.exe' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $pb 'Executables') -Recurse }
    Set-Content -LiteralPath (Join-Path $pb 'Executables\DomainScheduler.exe') -Value 'fake exe'
    $exe = Join-Path $pb 'Executables'
    Add-Content -LiteralPath (Join-Path $exe 'DomainOS-Common.ps1') -Value $global:DosShim -Encoding UTF8
    # Save-State: its two registry roots go to the fake registry
    $ss = Join-Path $exe 'Save-State.ps1'
    $text = [IO.File]::ReadAllText($ss)
    $n = ([regex]::Matches($text, '\[Microsoft\.Win32\.Registry\]::(LocalMachine|CurrentUser)')).Count
    if ($n -ne 2) { throw "Save-State.ps1: expected the 2 registry roots [Microsoft.Win32.Registry]::LocalMachine/CurrentUser, found ${n}: update tests/pester/Harness.ps1" }
    $text = $text.Replace('[Microsoft.Win32.Registry]::LocalMachine', '$global:DosRegRoot.Hive(''HKLM'')').Replace('[Microsoft.Win32.Registry]::CurrentUser', '$global:DosRegRoot.Hive(''HKCU'')')
    [IO.File]::WriteAllText($ss, $text, (New-Object Text.UTF8Encoding($true)))
    # [Environment]::GetFolderPath('CommonDesktopDirectory') is empty on Linux: the Public Desktop goes to the sandbox
    foreach ($f in 'Install-DomainOS.ps1', 'Undo-DomainOS.ps1') {
        $p = Join-Path $exe $f; $t = [IO.File]::ReadAllText($p)
        if ($f -eq 'Install-DomainOS.ps1' -and -not $t.Contains("[Environment]::GetFolderPath('CommonDesktopDirectory')")) { throw "Install-DomainOS.ps1 no longer uses GetFolderPath('CommonDesktopDirectory'): update tests/pester/Harness.ps1" }
        [IO.File]::WriteAllText($p, $t.Replace("[Environment]::GetFolderPath('CommonDesktopDirectory')", '$env:DosPublicDesktop'), (New-Object Text.UTF8Encoding($true)))
    }
    $env:DosPublicDesktop = Join-Path $root 'PublicDesktop'
    New-Item -ItemType Directory -Force -Path $env:DosPublicDesktop | Out-Null
    $env:ProgramData = Join-Path $root 'ProgramData'
    $env:ProgramFiles = Join-Path $root 'ProgramFiles'
    $env:SystemRoot = Join-Path $root 'Windows'
    $env:LOCALAPPDATA = Join-Path $root 'LocalAppData'
    $env:APPDATA = Join-Path $root 'AppData'
    $env:USERNAME = 'tester'; $env:USERDOMAIN = 'PC'; $env:COMPUTERNAME = 'PC'
    return [pscustomobject]@{ Root = $root; Playbook = $pb; Exe = $exe; Data = (Join-Path $env:ProgramData 'Domain OS'); Undo = (Join-Path $env:ProgramData 'Domain OS\Undo'); Tasks = (Join-Path $pb 'Configuration\Tasks') }
}
function global:Remove-DosSandbox($sb) { if ($sb -and $sb.Root -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $sb.Root)) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $sb.Root -Recurse -Force } }

# Runs a script of the sandbox in a child scope and returns its exit code and output.
function global:Invoke-DosScript([string]$Path, [hashtable]$Params = @{}) {
    $global:LASTEXITCODE = 0
    $out = & $Path @Params *>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $global:LASTEXITCODE; Out = ($out -join "`n") }
}

# Every registry value / service / task the task files touch, set to a known "before" state in the fake world.
function global:Initialize-DosWorldFromTasks([string]$TasksDir) {
    foreach ($yml in Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $TasksDir -Filter *.yml) {
        foreach ($line in Microsoft.PowerShell.Management\Get-Content -LiteralPath $yml.FullName) {
            if ($line -match "!registryValue:\s*\{path:\s*'([^']+)',\s*value:\s*'([^']+)'") { Set-DosRegValue $Matches[1] $Matches[2] 'DWord' 7 }
            elseif ($line -match "!service:\s*\{name:\s*'([^']+)'") { Set-DosRegValue "HKLM\SYSTEM\CurrentControlSet\Services\$($Matches[1])" 'Start' 'DWord' 3; $global:DosServices[$Matches[1]] = 'Running' }
            elseif ($line -match "!scheduledTask:\s*\{path:\s*'([^']+)'") { $global:DosTasks[$Matches[1]] = @{ State = 'Ready'; Protected = $false } }
        }
    }
}

# New-Object: COM objects (WScript.Shell shortcuts) are faked and recorded, everything else is the real cmdlet.
$global:DosShortcuts = New-Object System.Collections.Generic.List[object]
function global:New-Object {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$TypeName, [Parameter(Position = 1)][object[]]$ArgumentList, [string]$ComObject, [System.Collections.IDictionary]$Property)
    if ($ComObject) {
        if ($ComObject -ne 'WScript.Shell') { throw "COM object $ComObject is not faked" }
        $sh = [pscustomobject]@{}
        $sh | Add-Member ScriptMethod CreateShortcut {
            param($p)
            $l = [pscustomobject]@{ Path = $p; TargetPath = ''; Arguments = ''; Description = ''; WorkingDirectory = '' }
            $l | Add-Member ScriptMethod Save { $global:DosShortcuts.Add($this) }
            return $l
        }
        return $sh
    }
    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}

# The one-shot SYSTEM task of Undo: Start-ScheduledTask runs the registered command line's script as "SYSTEM".
function global:Enable-DosSystemRunner {
    $global:DosOnStartTask = {
        param($name)
        $t = $global:DosRegisteredTasks | Where-Object Name -eq $name | Select-Object -Last 1
        if (-not $t) { throw "task $name was not registered" }
        $arg = $t.Action.Arguments
        if ($arg -notmatch '-File "([^"]+)" -Work "([^"]+)" -Result "([^"]+)"') { throw "unexpected SYSTEM command line: $arg" }
        if ($t.Principal.UserId -ne 'S-1-5-18' -or $t.Principal.RunLevel -ne 'Highest') { throw "the one-shot task does not run as SYSTEM: $($t.Principal | Out-String)" }
        $global:DosAsSystem = $true
        try { $null = & $Matches[1] -Work $Matches[2] -Result $Matches[3] *>&1 } finally { $global:DosAsSystem = $false }
    }
}

# Runs the -Command of a logon task (conhost --headless powershell ... -Command "<cmd>") as the user would, in a child
# pwsh with its own LOCALAPPDATA; Start-Process is recorded instead of opening a browser. Returns what was opened.
function global:Invoke-DosLogonCommand([string]$Argument, [string]$LocalAppData, [string]$Record) {
    $i = $Argument.IndexOf('-Command "')
    if ($i -lt 0 -or -not $Argument.EndsWith('"')) { throw "no -Command `"...`" in: $Argument" }
    $cmd = $Argument.Substring($i + 10, $Argument.Length - $i - 11)
    if ($cmd.Contains('"')) { throw 'the command contains a double quote: it would end the -Command argument on the Windows command line' }
    $pre = "function Start-Process([string]`$FilePath) { Add-Content -LiteralPath '$Record' -Value `$FilePath }; `$env:LOCALAPPDATA = '$LocalAppData'; "
    & $global:DosPsExe -NoProfile -NonInteractive -Command ($pre + $cmd) | Out-Null
    if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Record) { return @(Microsoft.PowerShell.Management\Get-Content -LiteralPath $Record) } else { return @() }
}
