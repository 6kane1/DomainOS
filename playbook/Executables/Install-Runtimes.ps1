<#
  Domain OS — runtimes that games and tools expect: Visual C++ 2015-2022 (x64 and x86),
  the DirectX June 2010 end-user runtime (the old d3dx9/xinput/xaudio DLLs many games still load)
  and 7-Zip.

  Everything is downloaded from the vendor's own address. Microsoft files are accepted only with a
  valid Microsoft signature. 7-Zip installers carry no signature: one known version is downloaded and
  accepted only when its SHA-256 matches the value below (checked against 7-zip.org and the 7-Zip GitHub
  release); a newer 7-Zip comes with the next playbook version. Each step is independent: a failed
  download never stops the others, and the script never fails the playbook.
  Started from the Start menu it asks for administrator rights. Log: %ProgramData%\Domain OS\Logs\runtimes.log
#>
[CmdletBinding()]
param([switch]$Skip7Zip, [switch]$SkipVC, [switch]$SkipDirectX)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'DomainOS-Common.ps1')
if (Start-DomainOSElevated $MyInvocation.MyCommand.Path $PSBoundParameters) { exit 0 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# 7-Zip 26.06 x64 (2026-11-06): the same file at both addresses.
$SevenZipName = '7z2606-x64.exe'
$SevenZipSha256 = '9B697F65ECC2D9B0152F5EE96D72DDE522A7827690349D9307935DACF40F42EC'
$SevenZipUrls = @('https://www.7-zip.org/a/7z2606-x64.exe', 'https://github.com/ip7z/7zip/releases/download/26.06/7z2606-x64.exe')

try { Protect-DomainOSData } catch { Write-Host "The Domain OS data folder could not be protected: $($_.Exception.Message)" }
$logDir = Join-Path $DomainOSData 'Logs'
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
        # One pinned version, checked by SHA-256 (7-Zip installers carry no Authenticode signature). The official
        # site first, the 7-Zip GitHub release if it cannot be reached; a file with another hash is never run.
        $file = Join-Path $work $SevenZipName
        $got = $false; $why = ''
        foreach ($url in $SevenZipUrls) {
            try {
                Get-File $url $file
                $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if ($hash -eq $SevenZipSha256) { $got = $true; break }
                $why = "SHA-256 mismatch from $url ($hash)"
                Write-Log "7-Zip: $why - the file is not run"
                Remove-Item -LiteralPath $file -Force
            } catch { $why = "$url`: $($_.Exception.Message)" }
        }
        if (-not $got) { throw "no download with the expected SHA-256 ($why)" }
        Invoke-Setup $file '/S' @(0) | Out-Null
        "installed ($SevenZipName, SHA-256 checked)"
    }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
$failed = @($results.GetEnumerator() | Where-Object { $_.Value -like 'FAILED*' })
Write-Log ("Done: {0} of {1} steps succeeded." -f ($results.Count - $failed.Count), $results.Count)
exit 0
