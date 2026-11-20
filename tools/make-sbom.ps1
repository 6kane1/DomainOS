<#
  Writes an SPDX 2.3 SBOM (JSON) of the Toolbox exe: the exe itself (with its SHA-256) and every NuGet package it is
  built from, direct and transitive, as "dotnet list package" reports them after the build's restore.
      pwsh tools/make-sbom.ps1 -Project toolbox/src/DomainScheduler/DomainScheduler.csproj -Exe out/X.exe -Out out/X.spdx.json
  Used by .github/workflows/toolbox-build.yml; the SBOM is attested together with the exe (actions/attest-sbom).
#>
param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$json = & dotnet list $Project package --include-transitive --format json
if ($LASTEXITCODE -ne 0) { throw "dotnet list package failed ($LASTEXITCODE)" }
$data = ($json -join "`n") | ConvertFrom-Json
$pkgs = @{}
foreach ($p in $data.projects) {
    foreach ($fw in @($p.frameworks)) {
        foreach ($d in @($fw.topLevelPackages) + @($fw.transitivePackages)) {
            if ($null -eq $d) { continue }
            $v = if ($d.resolvedVersion) { $d.resolvedVersion } else { $d.requestedVersion }
            $pkgs["$($d.id)@$v"] = [pscustomobject]@{ id = $d.id; version = $v; direct = [bool]$d.requestedVersion }
        }
    }
}
$exeName = Split-Path $Exe -Leaf
$sha = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLower()
$root = 'SPDXRef-Package-Toolbox'
$packages = New-Object System.Collections.Generic.List[object]
$packages.Add([ordered]@{
    name = 'Domain OS Toolbox'; SPDXID = $root; versionInfo = $exeName; downloadLocation = 'https://github.com/6kane1/DomainOS'
    filesAnalyzed = $false; licenseConcluded = 'LicenseRef-Domain-OS-License'; licenseDeclared = 'LicenseRef-Domain-OS-License'
    copyrightText = 'Copyright (c) 2026 Domain OS'; checksums = @([ordered]@{ algorithm = 'SHA256'; checksumValue = $sha })
})
$rels = New-Object System.Collections.Generic.List[object]
$rels.Add([ordered]@{ spdxElementId = 'SPDXRef-DOCUMENT'; relationshipType = 'DESCRIBES'; relatedSpdxElement = $root })
$i = 0
foreach ($k in ($pkgs.Keys | Sort-Object)) {
    $p = $pkgs[$k]; $i++
    $id = "SPDXRef-Package-NuGet-$i"
    $packages.Add([ordered]@{
        name = $p.id; SPDXID = $id; versionInfo = $p.version
        downloadLocation = "https://www.nuget.org/packages/$($p.id)/$($p.version)"; filesAnalyzed = $false
        licenseConcluded = 'NOASSERTION'; licenseDeclared = 'NOASSERTION'; copyrightText = 'NOASSERTION'
        externalRefs = @([ordered]@{ referenceCategory = 'PACKAGE-MANAGER'; referenceType = 'purl'; referenceLocator = "pkg:nuget/$($p.id)@$($p.version)" })
    })
    $rels.Add([ordered]@{ spdxElementId = $root; relationshipType = 'DEPENDS_ON'; relatedSpdxElement = $id })
}
$doc = [ordered]@{
    spdxVersion = 'SPDX-2.3'; dataLicense = 'CC0-1.0'; SPDXID = 'SPDXRef-DOCUMENT'; name = "Domain OS Toolbox $exeName"
    documentNamespace = "https://github.com/6kane1/DomainOS/sbom/$sha"
    creationInfo = [ordered]@{ created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); creators = @('Tool: tools/make-sbom.ps1') }
    hasExtractedLicensingInfos = @([ordered]@{ licenseId = 'LicenseRef-Domain-OS-License'; name = 'Domain OS License'; extractedText = 'See LICENSE in the repository: all rights reserved.' })
    packages = $packages; relationships = $rels
}
$doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Out -Encoding utf8
Write-Host "SBOM: $Out ($($pkgs.Count) NuGet packages)"
