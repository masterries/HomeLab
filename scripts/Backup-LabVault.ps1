<#
.SYNOPSIS
    Saves a snapshot (backup) of OpenBao's data to this PC.

.DESCRIPTION
    OpenBao's integrated storage (raft) can export all its data as one snapshot file. The file
    is encrypted by OpenBao's own barrier: without OpenBao's unseal key shares it is useless,
    so it may be stored like any backup, e.g. on the USB stick next to the recovery file
    (New-LabRecoveryKit.ps1). Restoring needs the key shares that were valid when the
    snapshot was taken - keep both, but in different places.

    Runs on the Windows host as your own user. It logs in with the "pc-deploy" AppRole (DPAPI,
    allowed only from your PC), whose policy may read exactly this endpoint, saves
    keys\openbao\snapshots\vault-<date-time>.snap and keeps the newest -Keep files.

    Restore (onto a rebuilt vault VM, rare): see README, section "Restore OpenBao from a snapshot".

.PARAMETER Destination
    Also copy the snapshot to this folder (for example a USB stick, E:\).

.PARAMETER Keep
    How many snapshots to keep in keys\openbao\snapshots (default 10).

.EXAMPLE
    .\scripts\Backup-LabVault.ps1
    .\scripts\Backup-LabVault.ps1 -Destination E:\
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [int]$Keep = 10
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

$folder = Join-Path $script:LabKeysDir 'openbao\snapshots'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$file = Join-Path $folder ("vault-{0}.snap" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$token = Get-LabBaoToken 'pc-deploy'
try {
    Invoke-WebRequest -UseBasicParsing -Headers @{ 'X-Vault-Token' = $token } -Uri "$script:LabVaultUrl/v1/sys/storage/raft/snapshot" -OutFile $file
}
finally { Close-LabBaoToken $token }

$size = (Get-Item $file).Length
if ($size -lt 1024) { throw "The snapshot $file is suspiciously small ($size bytes)." }
Write-Host "Snapshot: $file ($([int]($size / 1KB)) KB)"

Get-ChildItem $folder -Filter 'vault-*.snap' | Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item -Force
if ($Destination) {
    Copy-Item $file $Destination
    Write-Host "Copied to $Destination"
}
