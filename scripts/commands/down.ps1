<#
.SYNOPSIS
    Deletes lab VMs so that lab.ps1 up can build them again from scratch.

.DESCRIPTION
    Runs "vagrant destroy" for the VMs defined in vagrant\Vagrantfile, no matter which
    folder you are currently in. This removes the VMs from Hyper-V and deletes their
    virtual disks under G:\Vagrant\machines. Afterwards the script also deletes the folder
    G:\Vagrant\hyperv\<vm> that "vagrant destroy" leaves behind (only for VMs listed in
    config\lab.json, and only a folder named like its VM). Everything that was stored on the
    VMs is gone afterwards.

    The firewall is not a Vagrant VM (OPNsense, built by lab.ps1 firewall), so it is
    removed directly with the Hyper-V cmdlets: the VM and its folder (disk, configuration,
    serial console log). For safety only a VM that carries lab.ps1 firewall's tag in its
    Notes is touched.

    What stays: the Vagrant box cache, the OPNsense image cache, the scripts and the Ansible
    project in the repository, and keys\: the offline SSH CA and this PC's SSH key (keys\ssh),
    the offline root CA (keys\pki) and the firewall's passwords and API key (DPAPI,
    keys\opnsense). Because the root CA stays, the rebuilt lab's certificates chain to the same
    root and Windows keeps trusting them; because the SSH CA stays, the rebuilt machines get
    host certificates that every client already trusts; because the firewall secrets stay, its
    GUI password does not change either.

    SSH host keys: the deleted machines' host keys go into the revocation list
    (keys\ssh\revoked_host_keys, LabSsh.ps1), so a copy of an old key (from a checkpoint or an
    old disk) can never pass for the rebuilt machine.

    OpenBao (the vault VM) holds the services' secrets and the intermediate CA. Its key shares
    and logins on this PC (keys\openbao) only fit the installation they were made for, so when
    the vault VM is deleted they are MOVED to keys\openbao-retired-<date-time>, together with
    its snapshots (restoring a snapshot needs the key shares of its time). A rebuilt OpenBao
    starts empty, and the Deploy-Lab*.ps1 scripts generate new secrets for NEW Keycloak and
    Matrix installations. Deleting only the vault VM while keeping Keycloak and Matrix
    therefore means restoring OpenBao from a snapshot (README.md, "Restore OpenBao from a
    snapshot"); the playbooks refuse to generate new secrets for an existing database.

    What is lost: the application data. Removing "matrix" deletes the homeserver's database
    and media (rooms, messages, files, Matrix accounts); removing "keycloak" deletes
    Keycloak's database (users get new internal IDs when they are created again). There are
    no backups of them yet.

    If a VM was already deleted by hand in Hyper-V, the script still cleans up its leftover
    disk.

    Asks for confirmation first (skip the question with -Confirm:$false, preview with
    -WhatIf). Runs on the Windows host and needs an elevated shell ("Run as administrator"),
    because Vagrant's Hyper-V provider needs administrator rights. Running it again when
    the VMs are already gone does no harm.

.PARAMETER Machine
    Delete only this VM, for example matrix or firewall. Without it: all lab VMs including
    the firewall.

.EXAMPLE
    .\lab.ps1 down
    .\lab.ps1 down matrix
    .\lab.ps1 down firewall
    .\lab.ps1 up     # then rebuild
#>
# INFRASTRUCTURE AS CODE: VMs ARE DISPOSABLE
# Every VM in this lab is fully described by code: vagrant\Vagrantfile and provision\ for
# the Ubuntu VMs (hardware, networks, the base setup that Vagrant's provisioners apply),
# opnsense\ and config\ for the firewall (built by scripts\commands\firewall.ps1), and
# ansible\ (the services). Deleting and rebuilding a VM is therefore a routine operation,
# not a disaster ("cattle, not pets").
# It is also the best test of the code: anything that was set up by hand on a VM is lost
# here and shows up as missing after the rebuild. Data that has to survive a rebuild needs
# a copy outside the VM, as keys\pki is for the root CA and the OpenBao snapshots
# (lab.ps1 backup) are for the secrets. The application data (the databases of Matrix and
# Keycloak) has no such copy yet: backups are on the roadmap in README.md.
# Enterprise equivalent: immutable infrastructure - servers are replaced from templates or
# images instead of being repaired by hand, and persistent data lives in backed-up storage.
#
# SupportsShouldProcess adds the standard -WhatIf and -Confirm parameters. ConfirmImpact
# 'High' matches the default $ConfirmPreference ('High'), so PowerShell asks before the
# destroy unless -Confirm:$false is given.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [string]$Machine
)

$ErrorActionPreference = 'Stop'
# The libraries (lib\Lab.ps1): the OpenBao snapshot, the revocation list for the deleted machines' host keys.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Lab.ps1')

$vagrantDir = Join-Path $script:LabProjectRoot 'vagrant'
# Must match lab.ps1 firewall.
$firewallName = 'firewall'
$firewallTag = 'managed-by=DeployableServer/scripts/New-LabFirewall.ps1'

# Removes the OPNsense firewall VM and its folder (disk, configuration, logs).
function Remove-LabFirewall {
    $vm = Get-VM -Name $firewallName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Host "Firewall: no VM named '$firewallName', nothing to do."; return }
    if ($vm.Notes -ne $firewallTag) {
        throw "The VM '$firewallName' was not built by lab.ps1 firewall (tag missing in its Notes); it is left alone."
    }
    # lab.ps1 firewall keeps everything of the VM in one folder (G:\Vagrant\hyperv\firewall).
    $vmFolder = $vm.Path
    if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
    Remove-VM -VM $vm -Force
    if ($vmFolder -and (Split-Path -Leaf $vmFolder) -eq $firewallName -and (Test-Path $vmFolder)) {
        Remove-Item -Recurse -Force $vmFolder
    }
    Write-Host "Firewall: VM '$firewallName' and $vmFolder removed."
    Revoke-LabSshHostKey $firewallName
}

# lab.ps1 up stores VAGRANT_HOME (where Vagrant keeps boxes, plugins and its index
# of machines; G:\Vagrant\home by default) as a permanent user variable. Shells that were
# already open before the first lab.ps1 up run do not have it in their environment
# yet, so read it from the user environment; this vagrant run then uses the same folder.
$vagrantHome = [Environment]::GetEnvironmentVariable('VAGRANT_HOME', 'User')
if ($vagrantHome) { $env:VAGRANT_HOME = $vagrantHome }

# Shown in the confirmation prompt and in the -WhatIf output.
$target = 'all lab VMs'
if ($Machine) { $target = "VM $Machine" }

if ($PSCmdlet.ShouldProcess($target, 'delete')) {
    # The vault VM holds the only copy of the services' secrets: take a fresh snapshot first
    # (keys\openbao\snapshots, moved aside below together with the key shares it needs). If that
    # is not possible while Keycloak or Matrix stay, stop: their data depends on those secrets.
    if ((-not $Machine -or $Machine -eq 'vault') -and (Get-VM -Name vault -ErrorAction SilentlyContinue)) {
        try { Backup-LabOpenBao }
        catch {
            # A broken OpenBao is a good reason to rebuild the vault VM; then an existing
            # snapshot (every deployment makes one) is enough to restore from.
            $why = $_.Exception.Message
            $remaining = @(Get-VM -Name keycloak, matrix -ErrorAction SilentlyContinue)
            $latest = Get-ChildItem (Join-Path $script:LabProjectRoot 'keys\openbao\snapshots') -Filter 'vault-*.snap' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($Machine -eq 'vault' -and $remaining -and -not $latest) {
                throw "No OpenBao snapshot possible ($why), and keys\openbao\snapshots has none, while $(($remaining | ForEach-Object Name) -join ' and ') keep data that depends on its secrets. Start the vault VM and unseal OpenBao (.\lab.ps1 up), then try again; nothing was deleted."
            }
            if ($latest) { Write-Warning "No fresh OpenBao snapshot ($why); the newest kept one is $($latest.Name). It moves to keys\openbao-retired-* together with the key shares it needs." }
            else { Write-Warning "OpenBao snapshot failed: $why" }
        }
    }
    if ($Machine -ne $firewallName) {
        # lab.ps1 up moves each VM's Hyper-V files (configuration, checkpoints) into a
        # folder of its own (G:\Vagrant\hyperv\<name>). "vagrant destroy" deletes the VM and its
        # disk but leaves that folder behind, so remember the folders now and remove them after
        # the destroy. Only the lab's VMs (config\lab.json) are considered, and only a folder
        # named exactly like its VM is touched.
        $lab = Get-Content -Raw (Join-Path $script:LabProjectRoot 'config\lab.json') | ConvertFrom-Json
        $labVmNames = @($lab.vms | ForEach-Object { $_.name })
        $hyperVFolders = @(Get-VM -ErrorAction SilentlyContinue |
            Where-Object { $labVmNames -contains $_.Name -and (-not $Machine -or $_.Name -eq $Machine) -and (Split-Path -Leaf $_.Path) -eq $_.Name } |
            ForEach-Object { $_.Path })
        # VAGRANT_CWD tells Vagrant where the Vagrantfile is, so the script works from any
        # folder. As in lab.ps1 up, it is set only for this command and restored in
        # 'finally', even after an error: left in the shell, every later vagrant command (even
        # "vagrant destroy" in another project's folder) would act on the lab VMs.
        $previousVagrantCwd = $env:VAGRANT_CWD
        $env:VAGRANT_CWD = $vagrantDir
        try {
            # -f skips Vagrant's own yes/no question; the confirmation already happened above.
            if ($Machine) { & vagrant destroy -f $Machine } else { & vagrant destroy -f }
            if ($LASTEXITCODE -ne 0) { throw "vagrant destroy failed (exit code $LASTEXITCODE)." }
        }
        finally {
            $env:VAGRANT_CWD = $previousVagrantCwd
        }
        foreach ($folder in $hyperVFolders) {
            # Only if the VM is really gone (a VM that vagrant did not manage stays untouched).
            if (-not (Get-VM -Name (Split-Path -Leaf $folder) -ErrorAction SilentlyContinue) -and (Test-Path $folder)) {
                Remove-Item -Recurse -Force $folder
                Write-Host "Removed the leftover Hyper-V folder $folder"
            }
        }
        foreach ($name in $labVmNames) {
            if ((-not $Machine -or $Machine -eq $name) -and -not (Get-VM -Name $name -ErrorAction SilentlyContinue)) { Revoke-LabSshHostKey $name }
        }
    }
    # OpenBao's key shares and logins fit only the deleted installation. Moved, not deleted:
    # the snapshots in there can only be restored with the key shares of their time.
    $openBaoKeys = Join-Path $script:LabProjectRoot 'keys\openbao'
    if ((-not $Machine -or $Machine -eq 'vault') -and -not (Get-VM -Name vault -ErrorAction SilentlyContinue) -and (Test-Path $openBaoKeys)) {
        $retired = "$openBaoKeys-retired-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item $openBaoKeys $retired
        Write-Host "OpenBao: key shares, logins and snapshots of the deleted installation moved to $retired"
        # Its SSH CA is gone with it: the machines stop trusting it at the next lab.ps1 up
        # (the trust files are rendered without it), and the offline SSH CA signs again until
        # lab.ps1 deploy vault has made the new OpenBao's CA trusted.
        $sshRetired = Join-Path $retired 'ssh'
        foreach ($file in $script:LabSshOpenBaoCa, $script:LabSshOpenBaoTrusted) {
            if (Test-Path $file) {
                New-Item -ItemType Directory -Force -Path $sshRetired | Out-Null
                Move-Item $file $sshRetired
            }
        }
    }
    # Without a machine name the firewall goes too, after the VMs behind it.
    if (-not $Machine -or $Machine -eq $firewallName) { Remove-LabFirewall }
    # ansible-control checks host keys against the revocation list too: give it the new one now
    # if it still runs (otherwise its next provisioning uploads it).
    $control = Get-LabSshHyperVVm 'ansible-control'
    if ($Machine -and $Machine -ne 'ansible-control' -and $Machine -ne $firewallName -and $control -and $control.State -eq 'Running') {
        try { Update-LabSshTrust -KrlOnly }
        catch { Write-Warning "The revocation list could not be copied to ansible-control now ($($_.Exception.Message)); lab.ps1 up does it." }
    }
    Write-Host 'Rebuild with:  .\lab.ps1 up'
}
