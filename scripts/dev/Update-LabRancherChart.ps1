<#
.SYNOPSIS
    Takes one version of the Rancher Manager Helm chart into this repository, vendor\rancher\chart.
    The only script that downloads it; deployments never do.

.DESCRIPTION
    Everything the lab executes is in this repository (vendor\README.md). Rancher Manager is
    installed from its Helm chart (a folder of Kubernetes manifest templates and default values).
    Rancher publishes the chart in a Helm repository as rancher-<version>.tgz, without a signature
    (there is no .prov file for "helm install --verify"), so the SHA-256 of that file is the trust
    anchor: take it from the "digest" of that version in the repository's index.yaml
    (https://releases.rancher.com/server-charts/stable/index.yaml) and pass it in.

    What the script does:
      1. download rancher-<Version>.tgz from the stable repository into a temporary folder,
      2. refuse it unless its SHA-256 is -Sha256,
      3. unpack it and replace vendor\rancher\chart with its folder "rancher" (unchanged),
      4. write vendor\rancher\.lab-vendored-version: the version and the file's SHA-256.
    It commits nothing. Then, before deploying:
      - review the change: git diff --stat -- vendor/rancher, and Rancher's release notes,
      - check the chart's kubeVersion (vendor\rancher\chart\Chart.yaml) against the RKE2 version
        in ansible\kubernetes\vars\kubernetes.yml (Rancher's support matrix names the
        Kubernetes versions each release runs on),
      - set rancher_chart_version in ansible\kubernetes\vars\kubernetes.yml to the same version,
      - commit, then .\lab.ps1 deploy k8s (rancher.yml refuses to run while the marker and
        rancher_chart_version differ).

    Why "stable" and not "latest": the latest repository also carries release candidates.

.PARAMETER Version
    The chart version, e.g. 2.15.2 (equal to Rancher's version without the "v").

.PARAMETER Sha256
    The SHA-256 of rancher-<Version>.tgz (64 hex characters), from the repository's index.yaml.

.EXAMPLE
    .\lab.ps1 rancher-upgrade -Version 2.15.2 -Sha256 855cb9be954f65a31b9a8c77f7aebce125c2d7797425257d21d35e3380816ac8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$Sha256
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$vendorDir = Join-Path $projectRoot 'vendor\rancher'
$url = "https://releases.rancher.com/server-charts/stable/rancher-$Version.tgz"
$scratch = Join-Path ([IO.Path]::GetTempPath()) "lab-rancher-chart-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $archive = Join-Path $scratch "rancher-$Version.tgz"
    Write-Host "== 1/3 Download $url =="
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -TimeoutSec 120
    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower()
    Write-Host "== 2/3 SHA-256 $actual =="
    if ($actual -ne $Sha256.ToLower()) { throw "rancher-$Version.tgz has SHA-256 $actual, not the expected $($Sha256.ToLower()). Nothing was changed." }

    Write-Host "== 3/3 Unpack into vendor\rancher\chart =="
    $unpacked = Join-Path $scratch 'unpacked'
    New-Item -ItemType Directory -Path $unpacked | Out-Null
    # tar.exe is part of Windows 10 (version 1803 and later).
    & tar -xzf $archive -C $unpacked
    if ($LASTEXITCODE -ne 0) { throw "tar failed (exit code $LASTEXITCODE)." }
    $chart = Join-Path $unpacked 'rancher'
    $chartYaml = Join-Path $chart 'Chart.yaml'
    if (-not (Test-Path $chartYaml)) { throw 'The archive holds no rancher\Chart.yaml.' }
    $chartVersion = [regex]::Match((Get-Content -Raw $chartYaml), '(?m)^version:\s*"?([^"\s]+)').Groups[1].Value
    if ($chartVersion -ne $Version) { throw "Chart.yaml says version $chartVersion, not $Version." }

    New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $vendorDir 'chart')
    Move-Item $chart (Join-Path $vendorDir 'chart')
    [IO.File]::WriteAllText((Join-Path $vendorDir '.lab-vendored-version'), "$Version sha256:$actual`n", (New-Object Text.UTF8Encoding $false))
}
finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch }

Write-Host ''
Write-Host "Rancher chart $Version is in vendor\rancher\chart. Next:"
Write-Host '  - review: git status; git diff --stat -- vendor/rancher; read the release notes'
Write-Host "  - check kubeVersion in vendor\rancher\chart\Chart.yaml against the RKE2 version"
Write-Host "  - set rancher_chart_version: $Version in ansible\kubernetes\vars\kubernetes.yml"
Write-Host '  - commit, then .\lab.ps1 deploy k8s'
