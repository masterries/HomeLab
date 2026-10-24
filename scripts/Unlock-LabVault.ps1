<#
.SYNOPSIS
    Unseals OpenBao on the vault VM after it was started.

.DESCRIPTION
    After every start (VM boot, service restart) OpenBao is "sealed": its data stays encrypted
    until enough key shares are presented. This script sends key shares A and B, stored with
    DPAPI on this PC, over HTTPS. Runs on the Windows host as your own user; Initialize-Lab.ps1
    calls it after starting the VMs. Running it again on an unsealed OpenBao does nothing.

    -Interactive asks for two shares instead (recovery after the PC's DPAPI data was lost:
    share B from the recovery file, see New-LabRecoveryKit.ps1 -Open, and share C from paper).
    Run that in your own PowerShell window.

    Until OpenBao is unsealed, nothing that needs it works: certificate renewals (ACME), the
    secrets for deployments, the CA revocation lists of the intermediate CA.

.EXAMPLE
    .\scripts\Unlock-LabVault.ps1
    .\scripts\Unlock-LabVault.ps1 -Interactive
#>
[CmdletBinding()]
param(
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')
Unlock-LabVault -Interactive:$Interactive
