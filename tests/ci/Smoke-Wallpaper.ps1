<#
  CI smoke test (Windows PowerShell 5.1, READ ONLY): compiles the IDesktopWallpaper wrapper of
  playbook\Executables\Set-Wallpapers.ps1 and calls its read methods from PowerShell. Catches the 2.2.2 bug where the
  script called methods on the raw COM object, which PowerShell cannot do (no IDispatch). Nothing is changed.
#>
$ErrorActionPreference = 'Stop'
$src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\playbook\Executables\Set-Wallpapers.ps1')
$m = [regex]::Match($src, "Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@", 'Singleline')
if (-not $m.Success) { throw 'the Add-Type block was not found in Set-Wallpapers.ps1' }
Add-Type -TypeDefinition $m.Groups[1].Value
foreach ($name in 'GetPosition', 'GetBackgroundColor', 'GetWallpaper', 'SetWallpaper', 'SetPosition', 'SetBackgroundColor', 'Enable') {
    if (-not [DomainOS.Wallpaper].GetMethod($name)) { throw "DomainOS.Wallpaper has no static method $name" }
}
# every $w.<Method>( call on a COM object is the bug pattern: none may be left
if ($src -match '\$w\.\w+\(') { throw 'Set-Wallpapers.ps1 still calls a method on the raw COM object ($w.…)' }
try {
    "position: $([DomainOS.Wallpaper]::GetPosition())"
    "background color: $([DomainOS.Wallpaper]::GetBackgroundColor())"
    "wallpaper: $([DomainOS.Wallpaper]::GetWallpaper())"
} catch {
    # a runner without an interactive desktop may refuse the COM server; the static methods were still found above
    Write-Host "::warning::IDesktopWallpaper not usable on this runner: $($_.Exception.Message)"
}
'wallpaper wrapper OK'
