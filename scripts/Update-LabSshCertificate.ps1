<#
.SYNOPSIS
    Renews this PC's SSH certificate (keys\ssh\pc_ed25519-cert.pub) when it is due, and shows
    which CA signed it and until when it is valid.

.DESCRIPTION
    Every lab script renews the certificate by itself (Get-LabSshConfig in LabSsh.ps1), and the
    Vagrantfile runs this script before "vagrant up/provision/reload/ssh/halt/resume" when the
    certificate expires within 4 hours. Run it by hand to see the current state, to get a new
    certificate now (-Force), or for break-glass (-BreakGlass).

    The certificate is valid for 8 hours and only for the principal "lab-all", from this PC's
    addresses. OpenBao signs it once Deploy-LabVault.ps1 has made its SSH CA trusted everywhere;
    before that, the offline SSH CA (bootstrap).

.PARAMETER Force
    Sign a new certificate even if the current one is still fresh.

.PARAMETER BreakGlass
    When OpenBao cannot sign (vault VM broken, OpenBao not unsealable), sign with the offline SSH
    CA instead. The certificate's key ID starts with "offline-breakglass-", every lab machine
    logs it, and keys\ssh\issued.log records it. Without this switch the script stops with the
    reason instead: OpenBao being unavailable must not silently move signing outside its audit
    log.

.EXAMPLE
    .\scripts\Update-LabSshCertificate.ps1
    .\scripts\Update-LabSshCertificate.ps1 -BreakGlass
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$BreakGlass
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

if ($Force) { Use-LabSshLock { Update-LabPcCertificate -BreakGlass:$BreakGlass } }
else { [void](Get-LabSshConfig -BreakGlass:$BreakGlass) }

$cert = Read-LabSshCertificate "$($script:LabSshPcKey)-cert.pub"
$signer = if ($cert.CaFingerprint -eq (Get-LabSshOfflineCaFingerprint)) { 'the offline SSH CA' } else { 'OpenBao' }
Write-Host "SSH certificate of this PC: signed by $signer, valid until $($cert.ValidTo.ToLocalTime().ToString('yyyy-MM-dd HH:mm')), key ID $($cert.KeyId), serial $($cert.Serial)"
