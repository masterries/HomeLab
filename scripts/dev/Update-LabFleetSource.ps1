<#
.SYNOPSIS
    Takes one version of a third-party source that Fleet deploys into this repository: the Apache
    Airflow Helm chart (fleet\airflow\chart) or Rancher's local-path-provisioner manifest
    (fleet\local-path\local-path-storage.yaml). The only script that downloads them; neither
    Fleet nor a deployment ever does.

.DESCRIPTION
    Everything the lab executes is in this repository (vendor\README.md). These two live under
    fleet\ and not under vendor\: Fleet, which deploys them from this repository on GitHub, reads
    only the files inside a bundle's own folder (fleet\<bundle>\), so the chart and the manifest
    must sit next to their fleet.yaml.

    The SHA-256 you pass in is the trust anchor:
      airflow     the "digest" of that version in https://airflow.apache.org/index.yaml (Apache also
                  publishes a GPG signature, airflow-<version>.tgz.asc, verifiable with
                  https://downloads.apache.org/airflow/KEYS)
      local-path  the hash of deploy/local-path-storage.yaml at the release tag (the release has no
                  signed assets); compute it once from the tag and compare with the release notes

    What the script does: download, refuse unless the SHA-256 matches, replace the vendored copy,
    write fleet\<component>\.lab-vendored-version (version and hash; Fleet never bundles hidden
    files). It commits nothing. Then, before deploying:
      - review: git status; git diff --stat -- fleet/; the upstream release notes
      - airflow: check the chart's kubeVersion and the image versions it pulls, and the values
        in fleet\airflow\fleet.yaml against the new chart\values.yaml
      - local-path: update the image digest in fleet\local-path\kustomization.yaml to the new tag's
      - commit, push (Fleet reads GitHub), then .\lab.ps1 deploy fleet

.PARAMETER Component
    airflow or local-path.

.PARAMETER Version
    airflow: the chart version, e.g. 1.22.0. local-path: the release tag, e.g. v0.0.37.

.PARAMETER Sha256
    The expected SHA-256 (64 hex characters) of the downloaded file.

.EXAMPLE
    .\lab.ps1 fleet-upgrade -Component airflow -Version 1.22.0 -Sha256 1f7d1dfe3d58e2c54899950aba907a43625a18c8b6fb3c54760c21592129a5b6
    .\lab.ps1 fleet-upgrade -Component local-path -Version v0.0.37 -Sha256 9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('airflow', 'local-path')]
    [string]$Component,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$Sha256
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundleDir = Join-Path $projectRoot "fleet\$Component"
$scratch = Join-Path ([IO.Path]::GetTempPath()) "lab-fleet-source-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
switch ($Component) {
    'airflow' {
        if ($Version -like 'v*') { throw 'The Airflow chart version has no "v" (e.g. 1.22.0).' }
        $url = "https://downloads.apache.org/airflow/helm-chart/$Version/airflow-$Version.tgz"
        $file = "airflow-$Version.tgz"
    }
    'local-path' {
        if ($Version -notlike 'v*') { throw 'The local-path-provisioner tag starts with "v" (e.g. v0.0.37).' }
        $url = "https://raw.githubusercontent.com/rancher/local-path-provisioner/$Version/deploy/local-path-storage.yaml"
        $file = 'local-path-storage.yaml'
    }
}

New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $download = Join-Path $scratch $file
    Write-Host "== 1/3 Download $url =="
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing -TimeoutSec 120
    $actual = (Get-FileHash -Algorithm SHA256 $download).Hash.ToLower()
    Write-Host "== 2/3 SHA-256 $actual =="
    if ($actual -ne $Sha256.ToLower()) { throw "$file has SHA-256 $actual, not the expected $($Sha256.ToLower()). Nothing was changed." }

    Write-Host "== 3/3 Into fleet\$Component =="
    New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
    if ($Component -eq 'airflow') {
        $unpacked = Join-Path $scratch 'unpacked'
        New-Item -ItemType Directory -Path $unpacked | Out-Null
        # tar.exe is part of Windows 10 (version 1803 and later).
        & tar -xzf $download -C $unpacked
        if ($LASTEXITCODE -ne 0) { throw "tar failed (exit code $LASTEXITCODE)." }
        $chart = Join-Path $unpacked 'airflow'
        $chartVersion = [regex]::Match((Get-Content -Raw (Join-Path $chart 'Chart.yaml')), '(?m)^version:\s*"?([^"\s]+)').Groups[1].Value
        if ($chartVersion -ne $Version) { throw "Chart.yaml says version $chartVersion, not $Version." }
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $bundleDir 'chart')
        Move-Item $chart (Join-Path $bundleDir 'chart')
    }
    else {
        Copy-Item -Force $download (Join-Path $bundleDir $file)
    }
    [IO.File]::WriteAllText((Join-Path $bundleDir '.lab-vendored-version'), "$Version sha256:$actual`n", (New-Object Text.UTF8Encoding $false))
}
finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch }

Write-Host ''
Write-Host "$Component $Version is in fleet\$Component. Next: review (git diff --stat -- fleet/), adjust fleet.yaml or"
Write-Host 'kustomization.yaml as the script help says, commit, push, then .\lab.ps1 deploy fleet'
