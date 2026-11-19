<#
  Domain OS — the SYSTEM part of "Undo Domain OS" (since 2.1.4).
  Undo-DomainOS.ps1 runs as administrator. Some services and scheduled tasks the playbook changed (it is applied
  with TrustedInstaller rights) do not let administrators change them back: their registry key or their task belongs
  to TrustedInstaller or SYSTEM. For exactly those items Undo starts this script once as SYSTEM through a one-shot
  scheduled task, waits for it and removes the task again.

      Undo-AsSystem.ps1 -Work <work.json> -Result <result.json>

  Safety:
    - this script is run from Program Files\Domain OS\Tools (only administrators can change it);
    - the work file must lie in %ProgramData%\Domain OS\Undo\system, be owned by SYSTEM, Administrators or
      TrustedInstaller and not be a link (Test-DomainOSFile);
    - every item is checked again against the same allow-list Undo uses (the playbook's own task files): only
      services and tasks Domain OS changes, start types 0-4, nothing else is touched;
    - a service's start type that even SYSTEM may not write is written with the backup/restore privilege
      (SeRestorePrivilege, REG_OPTION_BACKUP_RESTORE): the key's permissions and owner stay as they are.
  Windows PowerShell 5.1 syntax only.
#>
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Result)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DomainOS-Common.ps1')
$out = New-Object System.Collections.Generic.List[object]
function Done($kind, $name, $ok, $msg) { $out.Add([pscustomobject]@{ kind = $kind; name = $name; ok = [bool]$ok; error = [string]$msg }) }
function Save-Result {
    $tmp = "$Result.tmp"
    ConvertTo-Json -InputObject @($out.ToArray()) -Depth 3 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Result -Force
}

$box = [IO.Path]::GetFullPath((Join-Path $DomainOSData 'Undo\system'))
try {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Work)) -ne $box -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Result)) -ne $box) { throw 'work and result files must be in %ProgramData%\Domain OS\Undo\system' }
    if (-not (Test-DomainOSFile $Work)) { throw 'the work file is not trusted' }
    $allowed = Get-DomainOSAllowList $PSScriptRoot
    if (-not $allowed) { throw 'the allow-list is missing or not trusted' }
    $items = @(Get-Content -LiteralPath $Work -Raw -Encoding UTF8 | ConvertFrom-Json)
} catch {
    Done 'X' '' $false $_.Exception.Message
    Save-Result
    exit 1
}

Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DosRestoreReg {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Lo; public int Hi; }
    [StructLayout(LayoutKind.Sequential)] struct TP { public int Count; public LUID Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, int access, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string s, string n, out LUID l);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr t, bool all, ref TP n, int len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegCreateKeyEx(UIntPtr root, string sub, int res, string cls, int opt, int sam, IntPtr sa, out UIntPtr key, out int disp);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegSetValueEx(UIntPtr key, string name, int res, int type, ref int data, int size);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(UIntPtr key);
    static readonly UIntPtr HKLM = new UIntPtr(0x80000002u);
    static void Enable(string name) {
        IntPtr t;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out t)) throw new System.ComponentModel.Win32Exception();
        try {
            LUID l;
            if (!LookupPrivilegeValue(null, name, out l)) throw new System.ComponentModel.Win32Exception();
            TP tp = new TP { Count = 1, Luid = l, Attr = 2 };
            AdjustTokenPrivileges(t, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            int e = Marshal.GetLastWin32Error();
            if (e != 0) throw new System.ComponentModel.Win32Exception(e);
        } finally { CloseHandle(t); }
    }
    // Writes one DWORD under an EXISTING HKLM key with the backup/restore privilege (the key's access list is not used).
    public static void SetDword(string sub, string name, int value) {
        Enable("SeRestorePrivilege"); Enable("SeBackupPrivilege");
        UIntPtr k; int disp;
        int r = RegCreateKeyEx(HKLM, sub, 0, null, 4 /* REG_OPTION_BACKUP_RESTORE */, 0x20006 /* KEY_WRITE */, IntPtr.Zero, out k, out disp);
        if (r != 0) throw new System.ComponentModel.Win32Exception(r);
        try {
            if (disp == 1) throw new InvalidOperationException("the key did not exist");   // REG_CREATED_NEW_KEY: never create service keys
            r = RegSetValueEx(k, name, 0, 4 /* REG_DWORD */, ref value, 4);
            if (r != 0) throw new System.ComponentModel.Win32Exception(r);
        } finally { RegCloseKey(k); }
    }
}
'@

foreach ($i in $items) {
    $kind = [string]$i.kind; $name = [string]$i.name
    try {
        if ($kind -eq 'S') {
            if (-not $allowed["S|$name"] -or $name -notmatch '^[\w\.\-]+$') { throw 'not a service Domain OS changes' }
            $start = [int]$i.start
            if ($start -lt 0 -or $start -gt 4) { throw "start type $start is not 0-4" }
            $key = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$name"
            if (-not (Test-Path -LiteralPath $key)) { throw 'the service is not registered' }
            try { Set-ItemProperty -LiteralPath $key -Name 'Start' -Value $start -Type DWord }
            catch { [DosRestoreReg]::SetDword("SYSTEM\CurrentControlSet\Services\$name", 'Start', $start) }
            if ([int](Get-ItemProperty -LiteralPath $key).Start -ne $start) { throw 'the start type did not change' }
            if ($i.running) { try { Start-Service -Name $name } catch { } }   # it starts after the restart at the latest
            Done 'S' $name $true ''
        } elseif ($kind -eq 'T') {
            if (-not $allowed["T|$name"]) { throw 'not a task Domain OS changes' }
            $enable = [bool]$i.enabled
            $at = $name.LastIndexOf('\')
            $task = Get-ScheduledTask -TaskPath ($name.Substring(0, $at + 1)) -TaskName ($name.Substring($at + 1))
            try {
                if ($enable) { $task | Enable-ScheduledTask | Out-Null } else { $task | Disable-ScheduledTask | Out-Null }
            } catch {
                $flag = if ($enable) { '/ENABLE' } else { '/DISABLE' }
                & (Join-Path $env:SystemRoot 'System32\schtasks.exe') /Change /TN $name $flag 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "schtasks exit code $LASTEXITCODE" }
            }
            $now = (Get-ScheduledTask -TaskPath ($name.Substring(0, $at + 1)) -TaskName ($name.Substring($at + 1))).State -ne 'Disabled'
            if ($now -ne $enable) { throw 'the task did not change' }
            Done 'T' $name $true ''
        } else { throw "unknown item kind '$kind'" }
    } catch { Done $kind $name $false $_.Exception.Message }
}
Save-Result
exit 0
