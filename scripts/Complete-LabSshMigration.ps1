<#
.SYNOPSIS
    One-time: retires the old shared lab SSH key (keys\ansible_ed25519) once SSH certificates
    work everywhere.

.DESCRIPTION
    Earlier versions of the lab logged in everywhere with one SSH key without a passphrase:
    keys\ansible_ed25519 on the PC, the same private key on ansible-control, its public key in
    authorized_keys on every VM and in the firewall's config.xml. The certificate setup
    (scripts\LabSsh.ps1) keeps accepting that key during the transition, so the first run of the
    new code could not lock itself out. This script ends the transition, in this order:

      1. Proof first: a login with this PC's certificate ONLY (a temporary ssh_config without the
         old key) to the firewall and to every VM, and ping.yml from ansible-control (its own key
         with a certificate). If anything fails, nothing is changed.
      2. Hyper-V checkpoints of the lab VMs are listed and, after you confirm, deleted: they hold
         the old key (authorized_keys, and the private key on ansible-control); restoring one
         would bring it back.
      3. keys\ansible_ed25519 and keys\ansible_ed25519.pub (and the old keys\known_hosts) are
         moved to keys\lab-key-retired-<date-time>. Moved, not deleted: once step 4 has removed
         the key everywhere it opens nothing any more, and you can delete that folder yourself
         whenever you like.
      4. The key's public half is removed everywhere: from the firewall's config.xml
         (opnsense\lab-ssh-trust.php) and from authorized_keys on every VM (Vagrant's
         provisioner "ansible-user", provision\bootstrap-ansible-user.sh).
      5. Check: no machine lists the old key any more.

    Needs an elevated shell (Vagrant's Hyper-V provider, checkpoints). Asks before it deletes
    checkpoints or moves the key (-WhatIf shows what it would do).

    Once the lab key is retired on every PC that uses this repository, the transition code
    (everything marked "TRANSITION") and this script are removed from the repository.

.EXAMPLE
    .\scripts\Complete-LabSshMigration.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
# -WhatIf is honoured by the two ShouldProcess questions below; the read-only proof and the
# temporary files it needs must still really happen (the helpers would otherwise only pretend).
$WhatIfPreference = $false
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

$legacyKey = $script:LabSshLegacyKey
$labComment = 'ansible@deployableserver-lab'
$machines = Get-LabSshMachines
$vmNames = @($script:LabConfig.vms | ForEach-Object { $_.name })

if (-not (Test-Path $legacyKey) -and -not (Test-Path "$legacyKey.pub")) {
    Write-Host 'The old lab key (keys\ansible_ed25519) is already gone; removing it from every machine that may still list it.'
}
else {
    # --- 1. Proof: certificates alone work everywhere ---------------------------------------------
    [void](Get-LabSshConfig)
    $work = New-LabSshTempDir
    try {
        $config = Join-Path $work 'ssh_config'
        [void](Write-LabSshFile $config (Get-LabSshConfigText -NoLegacyKey).Split("`n"))
        $failed = @($machines | Where-Object { -not (Test-LabSshStrictLogin $_ $config) })
        if ($failed.Count -gt 0) { throw "A login with the PC's certificate alone fails on $($failed -join ', '). Run .\scripts\Initialize-Lab.ps1 first; nothing was changed." }
        Write-Host "Check:       the PC's certificate alone logs in to $($machines -join ', ')"
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
    & (Join-Path $PSScriptRoot 'Invoke-LabPlaybook.ps1') ping.yml
    if ($LASTEXITCODE -ne 0) { throw "ping.yml from ansible-control failed (exit code $LASTEXITCODE); nothing was changed." }

    # --- 2. Checkpoints that still contain the old key -------------------------------------------
    $checkpoints = @(Get-VMSnapshot -VMName $vmNames -ErrorAction SilentlyContinue)
    if ($checkpoints.Count -gt 0) {
        $list = ($checkpoints | ForEach-Object { "$($_.VMName): $($_.Name)" }) -join '; '
        if ($PSCmdlet.ShouldProcess($list, 'delete the Hyper-V checkpoints (they contain the old lab key)')) {
            $checkpoints | Remove-VMSnapshot
            Write-Host "Checkpoints: deleted ($list)"
        }
        else { Write-Warning "The checkpoints are kept ($list); restoring one brings the old lab key back." }
    }

    # --- 3. The key files ---------------------------------------------------------------------------
    # Moved out of the way: every script and the Vagrantfile treat the old key as retired as soon
    # as keys\ansible_ed25519(.pub) no longer exists.
    $retired = Join-Path $script:LabKeysDir "lab-key-retired-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if (-not $PSCmdlet.ShouldProcess("keys\ansible_ed25519, keys\ansible_ed25519.pub -> $retired", 'retire the old lab key')) { return }
    New-Item -ItemType Directory -Force -Path $retired | Out-Null
    foreach ($file in $legacyKey, "$legacyKey.pub", (Join-Path $script:LabKeysDir 'known_hosts')) {
        if (Test-Path $file) { Move-Item $file $retired }
    }
    Write-Host "Moved:       keys\ansible_ed25519(.pub) to $retired (it opens nothing once this script is done; delete the folder yourself)"
}

# --- 4. Its public half everywhere ----------------------------------------------------------------
# Without the key file, the trust files and keys\ssh_config are rendered without it. Runs on
# every call (it changes nothing where the key is gone already), so a run that failed here can
# simply be repeated.
[void](Write-LabSshTrustFiles)
Write-LabSshConfig
Set-LabFirewallSshTrust
$previousVagrantCwd = $env:VAGRANT_CWD
$env:VAGRANT_CWD = Join-Path $script:LabProjectRoot 'vagrant'
try {
    & vagrant provision @vmNames --provision-with ansible-user
    if ($LASTEXITCODE -ne 0) { throw "vagrant provision --provision-with ansible-user failed (exit code $LASTEXITCODE). Run this script again." }
}
finally { $env:VAGRANT_CWD = $previousVagrantCwd }

# --- 5. Check -----------------------------------------------------------------------------------------
$left = @()
foreach ($machine in $machines) {
    $count = "$(Invoke-LabSsh $machine "grep -c $labComment ~/.ssh/authorized_keys 2>/dev/null || true")".Trim()
    if ($count -and $count -ne '0') { $left += $machine }
}
if ($left.Count -gt 0) { throw "The old lab key is still in authorized_keys on $($left -join ', ')." }
Write-Host "Done: the old lab key is retired; no machine accepts it any more ($($machines -join ', '))."
