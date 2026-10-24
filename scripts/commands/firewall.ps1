<#
.SYNOPSIS
    Builds the lab firewall: an OPNsense 26.7 VM on Hyper-V, configured from the repository.

.DESCRIPTION
    WHAT THIS IS
    The lab's perimeter firewall is OPNsense (open source, FreeBSD/pf based, web GUI and REST
    API). There is no Vagrant box for OPNsense on Hyper-V, so this script builds the VM itself.
    It runs on the Windows host in an elevated PowerShell and is normally called by
    scripts\commands\up.ps1 (step 4); it can also be run on its own.

    BUILD STEPS (each one is skipped when its result already exists)
      1. Image: download the official OPNsense "nano" image (already installed, no installer)
         once into a cache on G:, check its SHA-256 against the value pinned below and its
         signature against OPNsense's signing key, unpack it (Git for Windows' bzip2) and turn
         the raw disk image into a VHDX.
      2. Secrets: random passwords for root (GUI login) and ansible, an API key for Ansible,
         encrypted with DPAPI in keys\opnsense\*.dpapi (LabSecrets.ps1: only your Windows
         account can decrypt them). The root password, for the GUI login:
           .\lab.ps1 secret -Pc opnsense/root-password
      3. GUI certificate for firewall.lab.internal, signed by the lab's offline root CA
         (lib\LabPki.ps1, keys\pki), so the GUI opens without a browser warning. The
         firewall exists before OpenBao and its intermediate CA, so the root signs it directly,
         like OpenBao's own certificate.
      4. Configuration: opnsense\config.xml.template + config\lab.json (VMs, published
         addresses, names and ports) -> config.xml, checked and packed into a small ISO. The
         rendered file holds password hashes and the GUI's private key, so it exists only in the
         ISO's staging folder and the ISO, and both are deleted once the firewall has imported
         it.
      5. VM: Generation 1 (the nano image boots with BIOS only), 1 vCPU (the 26.7 kernel can
         panic on Hyper-V with more; fixed in 26.7.7), 3 GB RAM, three network adapters with
         fixed MACs, all still DISCONNECTED, COM1 as a named pipe.
      6. First boot, driven over the serial console like the Unix tool "expect": answer
         OPNsense's configuration importer with the ISO, connect the network adapters, wait
         for the login prompt. With the adapters disconnected until our configuration is in,
         OPNsense's factory default (a DHCP server on its first adapter) never reaches a
         real network.
      7. Over SSH (as ansible): first SSH itself (Update-FirewallSsh). The firewall's host key is
         checked against the fingerprint it printed on its serial console, the key gets a host
         certificate from a lab SSH CA, and the sshd drop-in (opnsense\sshd_config.d) limits
         the jump host to SSH of the lab VMs. From then on every connection checks that
         certificate. Then: check the adapter mapping, install the split-horizon DNS drop-in,
         update OPNsense to the latest 26.7.x (the images are only released for 26.7; the
         Hyper-V fixes came in 26.7.6/26.7.7), reboot if needed, and renew the GUI certificate
         in place when it is due (Update-GuiCertificate).
      8. Checks: version, interfaces, DNS answers seen from your PC.

    RE-RUNS
    If the firewall VM already exists (built by this script, recognised by a tag in its Notes),
    nothing is rebuilt: the VM is started if it is off, its SSH setup (host certificate when
    due, sshd drop-in, the SSH CAs user ansible accepts) and the DNS drop-in are re-applied, a
    pending update or reboot is finished, the GUI certificate is renewed in place when it
    expires within 30 days or does not come from the lab root CA, and the checks run.
    Changes to opnsense\ or to
    config\lab.json (VMs, "published") are only applied by a rebuild. Use -Rebuild to throw
    it away and build it again from the repository (the "cattle, not pets" idea: servers are
    rebuilt from code instead of being repaired by hand).

    WHAT IS KEPT WHERE
      G:\Vagrant\images\opnsense\26.7\   downloaded image and base VHDX (cache, reused)
      G:\Vagrant\hyperv\firewall\        the VM: configuration, disk, serial console log
      keys\opnsense\                      passwords and API key (DPAPI-encrypted)
      keys\pki\issued\firewall-gui.crt    the GUI certificate (public; its key is only on the
                                          firewall)

.PARAMETER StorageRoot
    Folder for images and VMs. Default: G:\Vagrant (C: stays free).

.PARAMETER TimeZone
    Time zone of the firewall (IANA name). Default: Europe/Berlin.

.PARAMETER Rebuild
    Delete an existing firewall VM and build it again.

.EXAMPLE
    .\lab.ps1 firewall
    .\lab.ps1 firewall -Rebuild

    Break-glass (OpenBao cannot sign the firewall's host certificate): .\lab.ps1 breakglass firewall
#>
[CmdletBinding()]
param(
    [string]$StorageRoot = 'G:\Vagrant',
    [string]$TimeZone = 'Europe/Berlin',
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Lab.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\LabFirewall.ps1')

# --- Main -------------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run in an elevated PowerShell ("Run as administrator"): Hyper-V and its serial console pipe need it.'
}
foreach ($tool in $openssl, $bzip2) {
    if (-not (Test-Path $tool)) { throw "$tool is missing. It comes with Git for Windows." }
}
foreach ($switch in 'Default Switch', 'LabNet', 'LabHost') {
    if (-not (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue)) {
        throw "Hyper-V switch '$switch' is missing (LabNet: lab.ps1 up, LabHost: lab.ps1 host-setup)."
    }
}
if (-not (Test-Path $sshConfig)) { throw "keys\ssh_config is missing. Run .\lab.ps1 up." }

$existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($existing -and $existing.Notes -ne $vmTag) {
    # lab.ps1 down refuses untagged VMs too (on purpose: neither script deletes a VM it did
    # not create), so the way out is a deliberate manual step.
    throw "A VM named '$vmName' exists that this script did not build (an old Vagrant firewall?). Check what it is, then delete it yourself in Hyper-V Manager or with: Remove-VM -Name $vmName -Force (and its disk folder)."
}
if ($existing -and -not $Rebuild) {
    # Left behind by an earlier first boot that failed?
    Remove-SeedIso
    if ($existing.State -ne 'Running') { Start-VM -VM $existing; Write-Host "VM:          $vmName started" }
    Wait-TcpPort $lab.firewall.hostIp 22 300
    Update-FirewallSsh
}
else {
    # Everything that depends on the repository's content (image, secrets, certificate, the
    # rendered template) is prepared BEFORE an existing firewall is deleted. A typo in
    # config.xml.template or config\lab.json then stops the script while the old
    # firewall keeps running, instead of leaving the lab without one. Same idea as a deployment
    # pipeline that builds and validates the new version before it takes the old one down.
    Get-BaseImage
    $secrets = Get-Secrets
    $certificate = Get-GuiCertificate
    $configXml = New-FirewallConfig $secrets $certificate
    # Once OpenBao signs the SSH certificates, the new firewall's host certificate comes from it,
    # through the new firewall's port forward to the vault VM. So the vault VM must run (after a
    # Windows restart it is off); started here, before the old firewall is deleted.
    if ((Test-LabSshOpenBaoTrusted) -and $env:LAB_SSH_BREAKGLASS -ne '1') {
        $vaultVm = Get-LabSshHyperVVm 'vault'
        if (-not $vaultVm) { throw 'OpenBao signs the SSH host certificates, but the vault VM does not exist. Nothing was deleted; to let the offline SSH CA sign: .\lab.ps1 breakglass firewall -Rebuild' }
        if ($vaultVm.State -ne 'Running') { Start-VM -VM $vaultVm; Write-Host 'VM:          vault started (OpenBao signs the new host certificate)' }
    }
    if ($existing) {
        Write-Host "Rebuild:     removing the existing $vmName VM"
        Stop-VM -VM $existing -TurnOff -Force
        Remove-VM -VM $existing -Force
        if (Test-Path $vmDir) { Remove-Item -Recurse -Force $vmDir }
    }
    # A new firewall has new SSH host keys: the old key goes into the revocation list, so a copy
    # of it can never pass for the new firewall (LabSsh.ps1, Revoke-LabSshHostKey).
    Revoke-LabSshHostKey 'firewall'
    try {
        New-SeedIso $configXml
        $configXml = $null
        New-FirewallVm
        $bootFingerprint = Invoke-FirstBoot
    }
    finally { Remove-SeedIso }
    Wait-TcpPort $lab.firewall.hostIp 22 300
    Update-FirewallSsh $bootFingerprint
    # ansible-control must refuse the old firewall's key at once (LabSsh.ps1, Send-LabSshKrl).
    Send-LabSshKrl
    Test-AdapterMapping
}
Install-DnsDropIn
Update-Firewall
Update-GuiCertificate
Test-Firewall
Write-Host "Firewall ready: https://firewall.$($lab.domain) (user root; password to the clipboard: .\lab.ps1 secret -Pc opnsense/root-password)"
