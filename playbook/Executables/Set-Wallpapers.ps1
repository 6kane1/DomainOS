<#
  Domain OS — wallpapers: a desktop slideshow of the Domain OS pictures and one of them on the lock screen.

  What it does (for the account that installs the playbook, ordinary user settings, no policy is set):
    1. Copies the pictures to C:\Windows\Web\Wallpaper\Domain OS (every account can read them there).
    2. Saves what the desktop and the lock screen show now to %ProgramData%\Domain OS\Undo\Wallpaper\<user>
       (only the first time, so "Undo Domain OS" gets back the original, not an earlier Domain OS look).
    3. Desktop: a slideshow of that folder through Windows' own desktop wallpaper interface (IDesktopWallpaper),
       a new picture every 10 minutes, shuffled. A theme "Domain OS" is also saved under Settings > Personalization >
       Themes, so the slideshow can be chosen again after picking something else.
    4. Lock screen: one picture of the set, through Windows' own lock screen interface (Windows.System.UserProfile.
       LockScreen). Windows Spotlight on the lock screen is switched off for that, as choosing "Picture" in Settings does.
       Windows has no supported way for a program to turn on the lock screen SLIDESHOW: it is three clicks in
       Settings > Personalization > Lock screen > Slideshow > Browse > C:\Windows\Web\Wallpaper\Domain OS.
  Everything stays changeable in Settings as usual.

  -Restore puts back what was saved (used by "Undo Domain OS").
  Log: %ProgramData%\Domain OS\Logs\install.log
#>
[CmdletBinding()]
param([switch]$Restore)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$data = Join-Path $env:ProgramData 'Domain OS'
$log = Join-Path $data 'Logs\install.log'
$dir = Join-Path $env:SystemRoot 'Web\Wallpaper\Domain OS'
$undo = Join-Path $data "Undo\Wallpaper\$env:USERNAME"
$stateFile = Join-Path $undo 'state.json'
$themeFile = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes\Domain OS.theme'
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'Logs') | Out-Null
function Write-Log([string]$text) {
    try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  [Wallpaper] {1}' -f (Get-Date), $text) -Encoding UTF8 } catch { }
    Write-Host $text
}

# ---- Windows' desktop wallpaper interface (documented: IDesktopWallpaper, Windows 8 and later) ----------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DomainOS {
  [StructLayout(LayoutKind.Sequential)] public struct WRect { public int Left, Top, Right, Bottom; }
  [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IDesktopWallpaper {
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    WRect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
    void SetSlideshow(IntPtr items);
    IntPtr GetSlideshow();
    void SetSlideshowOptions(int options, uint slideshowTick);
    void GetSlideshowOptions(out int options, out uint slideshowTick);
    void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitorID, int direction);
    int GetStatus();
    void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
  }
  public static class Wallpaper {
    static readonly Guid ClsidDesktopWallpaper = new Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD");
    static readonly Guid IidShellItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
    static readonly Guid IidShellItemArray = new Guid("b63ea76d-1f85-456f-a19c-48159efa858b");
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [In] ref Guid riid, out IntPtr ppv);
    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SHCreateShellItemArrayFromShellItem(IntPtr psi, [In] ref Guid riid, out IntPtr ppv);
    public static IDesktopWallpaper Open() {
      return (IDesktopWallpaper)Activator.CreateInstance(Type.GetTypeFromCLSID(ClsidDesktopWallpaper));
    }
    /// <summary>Slideshow of every picture in the folder; options 1 = shuffle; tick in milliseconds.</summary>
    public static void Slideshow(string folder, int options, uint tickMs) {
      Guid iItem = IidShellItem, iArray = IidShellItemArray;
      IntPtr item, array;
      SHCreateItemFromParsingName(folder, IntPtr.Zero, ref iItem, out item);
      try {
        SHCreateShellItemArrayFromShellItem(item, ref iArray, out array);
        try {
          IDesktopWallpaper w = Open();
          w.SetSlideshow(array);
          w.SetSlideshowOptions(options, tickMs);
          w.SetPosition(4); // DWPOS_FILL
        } finally { Marshal.Release(array); }
      } finally { Marshal.Release(item); }
    }
  }
}
'@ -ErrorAction Stop

function Wait-WinRt($operation, [Type]$resultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq $(if ($resultType) { 'IAsyncOperation`1' } else { 'IAsyncAction' })
    } | Select-Object -First 1
    if ($resultType) { $method = $method.MakeGenericMethod($resultType) }
    $task = $method.Invoke($null, @($operation))
    [void]$task.Wait(30000)
    if ($resultType) { return $task.Result }
}
function Use-WinRt {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
}
function Set-LockImage([string]$path) {
    Use-WinRt
    $file = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    Wait-WinRt ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file)) $null
}

# ======================================== Undo ======================================================================
if ($Restore) {
    if (-not (Test-Path $stateFile)) { Write-Log 'Nothing saved: the wallpapers are left as they are'; exit 0 }
    $s = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    try {
        $w = [DomainOS.Wallpaper]::Open()
        if ($s.backgroundType -eq 1) {
            $w.SetBackgroundColor([uint32]$s.color); $w.Enable($false)
        } elseif ($s.picture -and (Test-Path -LiteralPath $s.picture)) {
            $w.SetWallpaper($null, $s.picture); $w.SetPosition([int]$s.position)
        }
        if ($s.backgroundType -eq 2 -and (Test-Path (Join-Path $undo 'slideshow.ini'))) {
            Copy-Item (Join-Path $undo 'slideshow.ini') (Join-Path $env:APPDATA 'Microsoft\Windows\Themes\slideshow.ini') -Force
            if (Test-Path (Join-Path $undo 'DesktopSlideshow.reg')) { & reg.exe import (Join-Path $undo 'DesktopSlideshow.reg') 2>&1 | Out-Null }
            Write-Log 'Desktop: the earlier slideshow settings are put back (the slideshow starts again after the next sign-in)'
        }
        Write-Log 'Desktop: the earlier wallpaper is back'
    } catch { Write-Log "Desktop wallpaper could not be put back: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $themeFile -Force -ErrorAction SilentlyContinue
    try {
        if (Test-Path (Join-Path $undo 'lock.jpg')) { Set-LockImage (Join-Path $undo 'lock.jpg'); Write-Log 'Lock screen: the earlier picture is back' }
        foreach ($p in $s.cdm.PSObject.Properties) {
            if ($null -eq $p.Value) { Remove-ItemProperty -Path $cdm -Name $p.Name -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -Path $cdm -Name $p.Name -Value ([int]$p.Value) -Type DWord }
        }
    } catch { Write-Log "Lock screen could not be put back: $($_.Exception.Message)" }
    Rename-Item -LiteralPath $stateFile -NewName ('state-restored-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date)) -ErrorAction SilentlyContinue
    exit 0
}

# ======================================== Install ===================================================================
# 1. the pictures
$src = Join-Path $here 'Wallpaper'
$pics = @(Get-ChildItem -Path $src -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' } | Sort-Object Name)
if ($pics.Count -eq 0) { Write-Log 'No pictures in the playbook: nothing changed'; exit 0 }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
# The single picture of versions up to 2.1.0 would join the slideshow: it is replaced by the new set.
Remove-Item -LiteralPath (Join-Path $dir 'DomainOS.png') -Force -ErrorAction SilentlyContinue
foreach ($p in $pics) { Copy-Item -LiteralPath $p.FullName -Destination $dir -Force }
Write-Log ("{0} pictures copied to {1}" -f $pics.Count, $dir)

# 2. what is there now (first time only)
if (-not (Test-Path $stateFile)) {
    New-Item -ItemType Directory -Force -Path $undo | Out-Null
    $state = [ordered]@{ saved = (Get-Date).ToString('o'); backgroundType = $null; picture = $null; position = 4; color = 0; cdm = [ordered]@{} }
    try {
        $state.backgroundType = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' -ErrorAction SilentlyContinue).BackgroundType
        $w = [DomainOS.Wallpaper]::Open()
        $state.position = $w.GetPosition(); $state.color = $w.GetBackgroundColor()
        $current = $w.GetWallpaper($null)
        if ($current -and (Test-Path -LiteralPath $current)) {
            # The picture may live somewhere that changes (TranscodedWallpaper, a slideshow folder): keep a copy.
            $copy = Join-Path $undo ('desktop' + [IO.Path]::GetExtension($current))
            if (-not [IO.Path]::GetExtension($current)) { $copy = Join-Path $undo 'desktop.jpg' }
            Copy-Item -LiteralPath $current -Destination $copy -Force; $state.picture = $copy
        }
    } catch { Write-Log "Desktop state could not be read completely: $($_.Exception.Message)" }
    $ini = Join-Path $env:APPDATA 'Microsoft\Windows\Themes\slideshow.ini'
    if (Test-Path $ini) { Copy-Item $ini (Join-Path $undo 'slideshow.ini') -Force }
    & reg.exe export 'HKCU\Control Panel\Personalization\Desktop Slideshow' (Join-Path $undo 'DesktopSlideshow.reg') /y 2>&1 | Out-Null
    foreach ($n in 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled') {
        $v = (Get-ItemProperty -Path $cdm -Name $n -ErrorAction SilentlyContinue).$n
        $state.cdm[$n] = $v
    }
    try {
        Use-WinRt
        $stream = [Windows.System.UserProfile.LockScreen]::GetImageStream()
        if ($stream) {
            $in = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream)
            $out = [IO.File]::Create((Join-Path $undo 'lock.jpg')); $in.CopyTo($out); $out.Dispose(); $in.Dispose()
        }
    } catch { Write-Log "The current lock screen picture could not be saved: $($_.Exception.Message)" }
    $state | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding UTF8
    Write-Log "Current wallpapers saved for Undo: $undo"
}

# 3. desktop slideshow + a theme to choose it again later
try {
    [DomainOS.Wallpaper]::Slideshow($dir, 1, 600000)
    Write-Log 'Desktop: slideshow of the Domain OS pictures, a new one every 10 minutes'
} catch {
    Write-Log "Desktop slideshow could not be set ($($_.Exception.Message)): the first picture is set instead"
    try { $w = [DomainOS.Wallpaper]::Open(); $w.SetWallpaper($null, (Join-Path $dir $pics[0].Name)); $w.SetPosition(4) } catch { Write-Log "Desktop picture could not be set: $($_.Exception.Message)" }
}
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $themeFile) | Out-Null
    @"
[Theme]
DisplayName=Domain OS

[Control Panel\Desktop]
Wallpaper=$(Join-Path $dir $pics[0].Name)
TileWallpaper=0
WallpaperStyle=10

[VisualStyles]
Path=%SystemRoot%\resources\Themes\Aero\Aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
SystemMode=Dark
AppMode=Dark

[Slideshow]
Interval=600000
Shuffle=1
ImagesRootPath=$dir

[MasterThemeSelector]
MTSM=DABJDKT
"@ | Set-Content -Path $themeFile -Encoding Unicode
    Write-Log 'Theme "Domain OS" saved (Settings > Personalization > Themes)'
} catch { Write-Log "Theme not saved: $($_.Exception.Message)" }

# 4. lock screen: one picture (a file named lock*.* if there is one, otherwise the first)
$lock = @($pics | Where-Object { $_.BaseName -like 'lock*' })[0]; if (-not $lock) { $lock = $pics[0] }
try {
    New-Item -Path $cdm -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $cdm -Name 'RotatingLockScreenEnabled' -Value 0 -Type DWord
    Set-ItemProperty -Path $cdm -Name 'RotatingLockScreenOverlayEnabled' -Value 0 -Type DWord
    Set-LockImage (Join-Path $dir $lock.Name)
    Write-Log "Lock screen: $($lock.Name). Slideshow there: Settings > Personalization > Lock screen > Slideshow > Browse > $dir"
} catch { Write-Log "Lock screen picture could not be set: $($_.Exception.Message)" }
exit 0
