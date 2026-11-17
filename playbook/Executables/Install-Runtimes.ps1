<#
  Domain OS — runtimes that games and tools expect: Visual C++ 2015-2022 (x64 and x86),
  the DirectX June 2010 end-user runtime (the old d3dx9/xinput/xaudio DLLs many games still load)
  and 7-Zip.

  Everything is downloaded from the vendor's own address. Microsoft files are accepted only with a
  valid Microsoft signature. Each step is independent: a failed download never stops the others,
  and the script never fails the playbook. Log: %ProgramData%\Domain OS\Logs\runtimes.log
#>
[CmdletBinding()]
param([switch]$Skip7Zip, [switch]$SkipVC, [switch]$SkipDirectX)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$logDir = Join-Path $env:ProgramData 'Domain OS\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'runtimes.log'
$work = Join-Path $env:TEMP ('DomainOS-runtimes-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$results = [ordered]@{}

function Write-Log([string]$text) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $text
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Host $text
}

function Get-File([string]$url, [string]$path) {
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -TimeoutSec 120
            if ((Test-Path $path) -and (Get-Item $path).Length -gt 100KB) { return }
            throw "the file is too small"
        } catch {
            if ($try -eq 3) { throw }
            Start-Sleep -Seconds (3 * $try)
        }
    }
}

# A Microsoft installer is run only when Windows confirms its signature and the signer is Microsoft.
function Test-MicrosoftSigned([string]$path) {
    $sig = Get-AuthenticodeSignature -FilePath $path
    return $sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation'
}

function Invoke-Setup([string]$exe, [string]$arguments, [int[]]$ok) {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($ok -notcontains $p.ExitCode) { throw "exit code $($p.ExitCode)" }
    return $p.ExitCode
}

function Step([string]$name, [scriptblock]$body) {
    try {
        $results[$name] = & $body
        Write-Log "$name`: $($results[$name])"
    } catch {
        $results[$name] = "FAILED: $($_.Exception.Message)"
        Write-Log "$name`: FAILED: $($_.Exception.Message)"
    }
}

Write-Log '--- Domain OS runtimes ---'

$online = $false
try { $online = [bool](Invoke-WebRequest -Uri 'https://aka.ms' -UseBasicParsing -TimeoutSec 15 -Method Head) } catch { $online = $false }
if (-not $online) {
    Write-Log 'No internet connection: nothing was installed. Run this script again later (Start menu, Domain OS, "Install runtimes").'
    exit 0
}

if (-not $SkipVC) {
    foreach ($arch in 'x64', 'x86') {
        Step "Visual C++ 2015-2022 $arch" {
            $file = Join-Path $work "vc_redist.$arch.exe"
            Get-File "https://aka.ms/vs/17/release/vc_redist.$arch.exe" $file
            if (-not (Test-MicrosoftSigned $file)) { throw 'the signature is not a valid Microsoft signature' }
            # 0 = installed, 3010 = installed, restart needed, 1638 = a newer version is already there
            $code = Invoke-Setup $file '/install /quiet /norestart' @(0, 3010, 1638)
            if ($code -eq 1638) { 'a newer version is already installed' } else { 'installed' }
        }
    }
}

if (-not $SkipDirectX) {
    Step 'DirectX June 2010 runtime' {
        if (Test-Path (Join-Path $env:SystemRoot 'System32\d3dx9_43.dll')) { return 'already installed' }
        $file = Join-Path $work 'directx_Jun2010_redist.exe'
        Get-File 'https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe' $file
        if (-not (Test-MicrosoftSigned $file)) { throw 'the signature is not a valid Microsoft signature' }
        $dx = Join-Path $work 'dx'
        Invoke-Setup $file "/Q /T:`"$dx`"" @(0) | Out-Null
        $setup = Join-Path $dx 'DXSETUP.exe'
        if (-not (Test-Path $setup)) { throw 'DXSETUP.exe was not unpacked' }
        Invoke-Setup $setup '/silent' @(0) | Out-Null
        'installed'
    }
}

if (-not $Skip7Zip) {
    Step '7-Zip' {
        $installed = (Get-ItemProperty 'HKLM:\SOFTWARE\7-Zip' -ErrorAction SilentlyContinue).Path
        if ($installed -and (Test-Path (Join-Path $installed '7z.exe'))) { return 'already installed' }
        # The newest x64 installer named on the official download page; a known version when the page cannot be read.
        $name = '7z2501-x64.exe'
        try {
            $page = (Invoke-WebRequest -Uri 'https://www.7-zip.org/download.html' -UseBasicParsing -TimeoutSec 30).Content
            $m = [regex]::Match($page, 'a/(7z\d{4}-x64\.exe)')
            if ($m.Success) { $name = $m.Groups[1].Value }
        } catch { }
        $file = Join-Path $work $name
        Get-File "https://www.7-zip.org/a/$name" $file
        # 7-Zip installers carry no Authenticode signature, so only the origin (HTTPS, 7-zip.org) and the file type are checked.
        $bytes = [IO.File]::ReadAllBytes($file)
        if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'the download is not a program file' }
        Invoke-Setup $file '/S' @(0) | Out-Null
        "installed ($name)"
    }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
$failed = @($results.GetEnumerator() | Where-Object { $_.Value -like 'FAILED*' })
Write-Log ("Done: {0} of {1} steps succeeded." -f ($results.Count - $failed.Count), $results.Count)
exit 0
