<#
.SYNOPSIS
    Builds the lab or brings it up to date: the firewall VM and the lab VMs from
    config\lab.json (ansible-control, matrix, keycloak, vault).

.DESCRIPTION
    This is the central orchestration script of the lab. It takes the firewall and the lab
    VMs from "nothing" (or from any earlier state) to the state described by the files in this
    repository: config\lab.json (names, MAC and IP addresses), the firewall's configuration
    in opnsense\ (applied by lab.ps1 firewall), vagrant\Vagrantfile (the Linux VMs, their
    network adapters and their provisioning scripts), provision\ (shell scripts that configure
    each Linux VM) and the SSH client configuration it generates in keys\ssh_config.
    Describing the lab in files and applying them with a script is "infrastructure as code":
    the VMs can be deleted and rebuilt at any time and come back the same way.

    Where and how it runs:
      - On the Windows host, in Windows PowerShell 5.1, as your own user. Hyper-V needs an
        elevated shell ("Run as administrator") or membership in the local group
        "Hyper-V Administrators"; the script checks this first.
      - Invoke it by path, for example from the project folder:  .\lab.ps1 up
        All paths are derived from the script's location, and the script points Vagrant
        at vagrant\ itself, so the current directory does not matter.
      - It drives lab.ps1 firewall (the OPNsense firewall), Vagrant (Hyper-V provider,
        the Linux VMs) and the Hyper-V cmdlets, then tests the result over SSH. It does not
        deploy applications: that is done afterwards by .\lab.ps1 deploy vault (OpenBao), then
        .\lab.ps1 deploy all (vault, firewall, keycloak, matrix; other playbooks through
        .\lab.ps1 run).
      - Run again (for example after a Windows restart), it also unseals OpenBao and renews
        what is due: certificates and the root CA's revocation list (step 7).

    Prerequisite, once per PC: .\lab.ps1 host-setup. It creates the
    internal Hyper-V switch "LabHost" (your PC gets the fixed address 10.10.99.1, the
    firewall 10.10.99.2) and a Windows NRPT rule that sends DNS queries for *.lab.internal,
    and only those, to the firewall. Changes to Windows networking and DNS are left to that
    separate, user-run script on purpose, so they never happen silently; this script only
    checks that they exist and stops if they do not.

    Build order. Each step depends on the ones before it, which is why the lab is built
    with this script and not with a plain "vagrant up":

      1. Storage. Decide where VM data lives before anything is downloaded or created:
         once VMs exist, this script no longer moves their disks; that needs a rebuild
         (lab.ps1 down, then this script). Vagrant's box cache goes to VAGRANT_HOME (set
         permanently for your user if it is not set yet).
         vagrant\.vagrant, where Vagrant keeps its per-VM state and the Hyper-V provider
         keeps the virtual disks, becomes a junction (directory link) to -StorageRoot.
         Hyper-V's own files (configuration, checkpoints) are moved in step 5 as soon as
         each Linux VM exists; lab.ps1 firewall creates the firewall there directly.
      2. SSH CA and keys\ssh_config. Initialize-LabSshCa (lib\LabSsh.ps1) creates the offline SSH CA and this
         PC's SSH key if they are missing (keys\ssh). SSH logins in the lab use short-lived
         certificates instead of a shared key, and host keys are checked against host
         certificates instead of being trusted on first use (scripts\lib\LabSsh.ps1 explains it).
         The files that say which CAs to trust are rendered here; the firewall build and
         Vagrant's provisioners copy them. The ssh_config says how to reach each VM: the
         firewall directly at its fixed LabHost address, every other VM through the firewall
         as jump host. lab.ps1 firewall configures the firewall over SSH with this file,
         and Vagrant uses it to reach the lab VMs (ssh.proxy_command in the Vagrantfile), so
         it has to exist before steps 4 and 5.
      3. LabNet. The private Hyper-V switch for the lab network behind the firewall. It
         must exist before the firewall is built, because the firewall's LAN adapter is
         attached to it.
      4. Firewall (OPNsense, lab.ps1 firewall). First, if they exist, the firewall and the
         vault VM are started directly in Hyper-V and OpenBao is unsealed: once deployed,
         OpenBao signs the SSH certificates, and after a Windows restart the PC's certificate
         has expired. Then the firewall is built or checked (its SSH host certificate first),
         before any other VM, because the lab VMs depend on its services: DHCP (dnsmasq hands each lab VM its
         reserved address; without it a lab VM gets no IPv4 address, and Vagrant, which
         reads the guest IP from Hyper-V, has no usable address to connect to), DNS for
         *.lab.internal, NAT to the internet (package installs during provisioning) and
         SSH: Vagrant reaches the lab VMs only through the firewall as jump host, logged in
         as "ansible" with the PC's certificate. A DNS lookup from the PC then checks that the
         firewall answers on the LabHost network.
      5. Lab VMs (ansible-control, matrix, keycloak, vault; the list comes from
         config\lab.json). Started on LabNet only, then provisioned: user "ansible", SSH
         (own host keys, published to the PC through Hyper-V KVP, trust in the lab's SSH CAs,
         certificate logins only); ansible-control also gets its own SSH key and Ansible -
         only what must exist before Ansible can reach a VM. Then every VM gets its host
         certificate. The services on them are deployed afterwards (lab.ps1 deploy ...).
      6. Checks and the base setup. Name resolution from the PC and an SSH login to every
         VM through keys\ssh_config (with the PC's certificate, checking every host
         certificate); then two runs on ansible-control (lib\LabRun.ps1): base.yml (zsh, the
         console autologin - not on vault) on every Ubuntu VM, and checks.yml, which reaches
         every machine by its DNS name with a certificate of its own and checks host
         certificates, sudo, sshd's settings and the firewall's bootstrap contract.
      7. Maintenance (once OpenBao is deployed): renewals that are due - OpenBao's TLS
         certificate, the root CA's revocation list, the intermediate CA (lab.ps1 deploy vault),
         Keycloak's certificate (lab.ps1 deploy keycloak) and the firewall's GUI certificate
         (lab.ps1 deploy firewall); see Get-LabMaintenanceDue in LabSecrets.ps1.

    Idempotency. The script can be run again at any time, also after a Windows reboot
    (which gives the Default Switch a new subnet; only the firewall's WAN side uses it, and
    the firewall simply gets a new DHCP lease there, while everything else uses the fixed
    LabHost address and DNS names). Each step looks at the current state first and only
    changes what is missing: an existing key is kept, the switch is created only once, an
    existing firewall is only started and checked, only VMs that are not running are
    started, Hyper-V files are moved only if they are somewhere else, host certificates are
    signed only when they are due (30 days before they expire). keys\ssh_config is
    rewritten on every run. Provisioning of the Linux VMs also runs on every run ("vagrant
    up" alone runs it only when a VM is first created), and so does base.yml, so changes to
    provision\ and to the base setup are applied by running this script again. Both are
    written so that they can be re-run safely. Changes to the firewall's configuration (opnsense\, and the VMs and
    "published" entries in config\lab.json) need a rebuild of the firewall:
    .\lab.ps1 firewall -Rebuild.

.PARAMETER StorageRoot
    Folder for Vagrant boxes, VM disks and Hyper-V files, so that drive C: stays free.
    Default: G:\Vagrant. Layout below it:
      home\                               Vagrant box cache (VAGRANT_HOME), only used if
                                          VAGRANT_HOME was not set before
      machines\<project folder>\vagrant\  target of the vagrant\.vagrant junction (VM disks)
      hyperv\<VM name>\                   Hyper-V configuration, checkpoints, smart paging
    An existing VAGRANT_HOME and an existing .vagrant junction are kept. Once both are in
    place, changing this value only moves the Hyper-V files.

.EXAMPLE
    .\lab.ps1 up

    Builds the lab from scratch, or brings an existing lab up to date: starts stopped VMs,
    re-runs provisioning and the base setup, and runs the checks.

    .\lab.ps1 breakglass up

    The same, but when OpenBao cannot sign SSH certificates (the vault VM is broken), the
    offline SSH CA signs them for this run instead (LabSsh.ps1, Get-LabSshSigner). Without it
    the script stops with the reason, so that OpenBao being unavailable never moves signing
    outside its audit log by accident.

.NOTES
    Lab-only shortcuts in this script, and what an enterprise setup does instead:
      - The PC's SSH key has no passphrase (it opens nothing without its 8-hour certificate),
        and the PC signs its certificates itself with an AppRole stored with DPAPI.
        Enterprise: people log in to the SSH CA with SSO and MFA (OIDC to Vault/OpenBao,
        Teleport, Smallstep) and get a certificate for their own identity.
      - Vagrant's own last hop to each VM (user "vagrant", Vagrant's per-VM key) does not
        check the VM's host key. Nothing of the lab's trust depends on it: VMs publish their
        host keys through Hyper-V KVP, and certificates are installed over connections pinned
        to those keys.

    Related scripts: lab.ps1 host-setup (once, before this script),
    lab.ps1 trust (make Windows trust the lab root CA), lab.ps1 deploy vault (OpenBao:
    secrets and the intermediate CA), lab.ps1 deploy all (vault, firewall, keycloak, matrix,
    in this order after this script), lab.ps1 secret (read a password),
    lab.ps1 connect (SSH login), lab.ps1 run (run Ansible playbooks),
    lab.ps1 down (delete VMs).
#>
[CmdletBinding()]
param(
    [string]$StorageRoot = 'G:\Vagrant'
)

# Stop at the first failing cmdlet. A native program (vagrant, ssh) that ends with a non-zero
# exit code does not stop the script, so exit codes are checked explicitly below. (Its stderr
# output can stop it in Windows PowerShell 5.1, though: see the LogLevel=ERROR note in step 6.)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Lab.ps1')

$projectRoot = $script:LabProjectRoot
$vagrantDir = Join-Path $projectRoot 'vagrant'
$dotVagrant = Join-Path $vagrantDir '.vagrant'
# Target of the .vagrant junction. The project folder's name is part of the path, so
# projects in differently named folders do not share one machine store.
$machineStore = Join-Path $StorageRoot "machines\$(Split-Path -Leaf $projectRoot)\vagrant"
$keyDir = Join-Path $projectRoot 'keys'
$sshConfig = Join-Path $keyDir 'ssh_config'
# Addresses and the domain come from config\lab.json, the lab's main source for this data
# (also read by the Vagrantfile and lab.ps1 firewall). The switch names must match
# vagrant\Vagrantfile, lab.ps1 firewall and lab.ps1 host-setup (which also creates
# the NRPT rule for the lab domain).
$lab = Get-Content -Raw (Join-Path $projectRoot 'config\lab.json') | ConvertFrom-Json
$firewallName = 'firewall'
$firewallHostIp = $lab.firewall.hostIp
$labSwitch = 'LabNet'
$hostSwitch = 'LabHost'
$labDomain = $lab.domain

# Runs vagrant and turns a non-zero exit code into a terminating error. Without a param
# block, all arguments land in the automatic variable $args and are passed on with @args.
function Invoke-Vagrant {
    & vagrant @args
    if ($LASTEXITCODE -ne 0) { throw "vagrant $($args -join ' ') failed (exit code $LASTEXITCODE)." }
}

# Returns every VM defined in the Vagrantfile with its state, in Vagrantfile order, for
# example matrix = running (other states: off, not_created, ...).
# "vagrant status --machine-readable" prints CSV lines: timestamp,target,type,data.
function Get-VagrantMachineStates {
    $lines = & vagrant status --machine-readable
    if ($LASTEXITCODE -ne 0) { throw "vagrant status failed (exit code $LASTEXITCODE)." }
    $states = [ordered]@{}
    foreach ($line in $lines) {
        $fields = $line -split ','
        if ($fields.Count -ge 4 -and $fields[2] -eq 'state') { $states[$fields[1]] = $fields[3] }
    }
    return $states
}

# Returns the Hyper-V VM behind a Vagrant machine. Vagrant stores the VM's Hyper-V ID in
# .vagrant\machines\<name>\hyperv\id; a lookup by ID is unambiguous, unlike one by name.
function Get-LabVM([string]$Name) {
    $vmId = (Get-Content -LiteralPath (Join-Path $dotVagrant "machines\$Name\hyperv\id") -Raw).Trim()
    return Get-VM -Id $vmId
}

# Vagrant creates each VM with Hyper-V's default folders on C: for its configuration
# (including saved states), checkpoints and smart paging file. Move-VMStorage moves them
# to -StorageRoot, which also works while the VM is running. Only these files are moved:
# the virtual disks already live on -StorageRoot through the .vagrant junction.
# Idempotent: does nothing if the VM's configuration is already in the target folder.
function Move-LabVMConfig([string]$Name) {
    $vm = Get-LabVM $Name
    $vmStore = Join-Path $StorageRoot "hyperv\$($vm.Name)"
    if ($vm.ConfigurationLocation -ne $vmStore) {
        New-Item -ItemType Directory -Force -Path $vmStore | Out-Null
        Move-VMStorage -VM $vm -VirtualMachinePath $vmStore -SnapshotFilePath $vmStore -SmartPagingFilePath $vmStore
    }
    # The backtick before ":" stops PowerShell from reading "$Name:" as a scoped variable.
    Write-Host "Hyper-V files $Name`: $vmStore"
}

# Resolves a lab name through the normal Windows resolver. The NRPT rule from
# lab.ps1 host-setup sends every *.lab.internal query to dnsmasq on the firewall
# (10.10.99.2). Up to 6 tries, 5 seconds apart, in case dnsmasq has only just started.
# The DNS client cache is cleared before each try because Windows also caches negative
# answers; a cached "name not found" would otherwise survive the retries.
function Resolve-LabName([string]$Name) {
    for ($try = 0; $try -lt 6; $try++) {
        if ($try -gt 0) { Start-Sleep -Seconds 5 }
        Clear-DnsClientCache
        $ips = @(Resolve-DnsName -Name $Name -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        if ($ips.Count -gt 0) { return $ips }
    }
    return @()
}

# Hyper-V (and therefore Vagrant's Hyper-V provider) needs either the local Administrators
# group, which under UAC only counts in an elevated shell, or the built-in group
# "Hyper-V Administrators" (well-known SID S-1-5-32-578). The latter grants Hyper-V
# management without full administrator rights, the least-privilege option.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isHyperVAdmin = $principal.IsInRole([Security.Principal.SecurityIdentifier]'S-1-5-32-578')
if (-not ($isAdmin -or $isHyperVAdmin)) {
    throw 'Hyper-V needs administrator rights: start PowerShell with "Run as administrator".'
}
# The Windows side of the lab network is set up once by lab.ps1 host-setup: the
# internal switch LabHost and the NRPT rule for *.lab.internal. This script only checks
# for both; it never changes Windows network or DNS settings itself.
$hostNetworkReady = (Get-VMSwitch -Name $hostSwitch -ErrorAction SilentlyContinue) -and
    @(Get-DnsClientNrptRule | Where-Object { $_.Namespace -contains ".$labDomain" }).Count -gt 0
if (-not $hostNetworkReady) {
    throw "The lab's host network is missing. Run this once: .\lab.ps1 host-setup"
}

# VAGRANT_CWD tells vagrant which folder holds the Vagrantfile, so the vagrant commands
# below work from any current directory. It is set only while this script runs and the
# previous value is restored in "finally": left in the shell, it would make every later
# vagrant command (even "destroy" in another project's folder) act on these VMs.
$previousVagrantCwd = $env:VAGRANT_CWD
$env:VAGRANT_CWD = $vagrantDir
try {
    # --- Step 1: storage. This comes first: once VMs exist, their disks can no longer be
    # moved by this script; that needs a rebuild (lab.ps1 down, then this script).
    Write-Host "== 1/7 Storage location $StorageRoot =="
    # VAGRANT_HOME is Vagrant's own data folder (box cache, plugins). An existing value in
    # your user environment is never changed.
    $vagrantHome = [Environment]::GetEnvironmentVariable('VAGRANT_HOME', 'User')
    if (-not $vagrantHome) {
        $vagrantHome = Join-Path $StorageRoot 'home'
        New-Item -ItemType Directory -Force -Path $vagrantHome | Out-Null
        # Stored in the user environment (HKCU\Environment): applies to new shells and to
        # every Vagrant project of this Windows user.
        [Environment]::SetEnvironmentVariable('VAGRANT_HOME', $vagrantHome, 'User')
        Write-Host "VAGRANT_HOME set permanently for your user (applies to new shells)."
    }
    # Unlike VAGRANT_CWD, this may stay in the shell: it equals the permanent value and
    # applies to all Vagrant projects.
    $env:VAGRANT_HOME = $vagrantHome
    Write-Host "Boxes:    $vagrantHome"
    # %USERPROFILE%\.vagrant.d is Vagrant's default data folder. Data left there from before
    # VAGRANT_HOME was set is no longer used; it is only reported, never deleted.
    $defaultVagrantHome = Join-Path $HOME '.vagrant.d'
    if ((Test-Path $defaultVagrantHome) -and ($defaultVagrantHome -ne $vagrantHome)) {
        Write-Warning "Old Vagrant data (boxes/plugins) is still in $defaultVagrantHome. Move it to $vagrantHome or delete it if you no longer need it."
    }

    # vagrant\.vagrant holds Vagrant's per-VM state and, with the Hyper-V provider, the VMs'
    # virtual disks. A junction (an NTFS directory link that, unlike a symbolic link, needs
    # no special privilege) lets the folder live on -StorageRoot while Vagrant still finds
    # it next to the Vagrantfile. Three cases:
    $dotVagrantItem = Get-Item -LiteralPath $dotVagrant -Force -ErrorAction SilentlyContinue
    if ($dotVagrantItem -and $dotVagrantItem.LinkType) {
        # Already a link: nothing to do.
        Write-Host "VM disks: $dotVagrant -> $($dotVagrantItem.Target -join ', ')"
    }
    elseif ($dotVagrantItem -and @((Get-VagrantMachineStates).Values | Where-Object { $_ -ne 'not_created' }).Count -gt 0) {
        # A real folder that already holds VMs. Hyper-V refers to their disks by full path,
        # so the folder cannot simply be moved; only warn, the VMs keep working where they are.
        Write-Warning "The VMs are still stored directly in $dotVagrant. To move them: run .\lab.ps1 down, then run this script again."
    }
    else {
        # No VM has been created yet, so .vagrant holds at most Vagrant metadata and can be
        # replaced by the junction.
        if ($dotVagrantItem) { Remove-Item -LiteralPath $dotVagrant -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $machineStore | Out-Null
        New-Item -ItemType Junction -Path $dotVagrant -Target $machineStore | Out-Null
        Write-Host "VM disks: $dotVagrant -> $machineStore"
    }

    # --- Step 2: the SSH CA, the PC's SSH key and the SSH client configuration.
    Write-Host '== 2/7 SSH CA, SSH key and SSH configuration =='
    # Creates the offline SSH CA and this PC's key in keys\ssh if they are missing; existing
    # ones are kept (Initialize-LabSshCa, lib\LabSsh.ps1, which also explains the certificates).
    Initialize-LabSshCa
    # The files that tell every machine which SSH CAs to trust: rendered here from the CA public
    # keys and config\lab.json; Vagrant's provisioners and lab.ps1 firewall copy them.
    if (Write-LabSshTrustFiles) { Write-Host 'Written: keys\ssh\lab_user_ca.pub, known_hosts, firewall_authorized_keys' }
    # keys\ssh_config is used by lab.ps1 connect, lab.ps1 run, the tests in step 6
    # and by Vagrant itself: the Vagrantfile's ssh.proxy_command reaches the lab VMs through
    # the firewall with this file, so it must be written before step 5 starts them.
    # The firewall is addressed by its fixed LabHost IP rather than its name, so SSH to it
    # still works when its DNS is not running (its Default Switch address changes on every
    # Windows reboot); HostKeyAlias tells ssh to check its host certificate for its name.
    # The other VMs use ProxyJump: ssh first connects to the firewall and opens the onward
    # connection from there, so the name in HostName is resolved by the firewall and gets
    # the lab-side address (split-horizon DNS). This is the bastion host (jump host)
    # pattern: the lab network has a single SSH entry point that can be secured and logged
    # in one place, instead of SSH being reachable on every server.
    # The "*.lab.internal" block covers full names such as "ssh matrix.lab.internal": without
    # it, the PC would resolve that name itself and get 10.10.99.3, the published address
    # (split DNS), where only the published ports (80, 443, 7881, udp 7882) are forwarded, so
    # SSH would time out instead of reaching the VM. With ProxyJump the firewall resolves it
    # to the lab VM.
    # Host keys: accepted only with a certificate from a lab SSH CA (keys\ssh\known_hosts,
    # StrictHostKeyChecking yes), never "on first use". The text comes from Get-LabSshConfigText
    # (LabSsh.ps1).
    Write-LabSshConfig
    Write-Host "Written: $sshConfig"
    # The Linux VM names come from the Vagrantfile (all of them are lab VMs behind the
    # firewall; the filter only matters if the Vagrantfile ever defines a VM called "firewall").
    $states = Get-VagrantMachineStates
    $labMachines = @($states.Keys | Where-Object { $_ -ne $firewallName })

    # --- Step 3: the lab network. Hyper-V has three switch types: External (VMs share a
    # physical network adapter of the PC), Internal (VMs plus a virtual adapter on the PC;
    # that is LabHost) and Private (VMs only). LabNet is private: the PC has no address in
    # 10.10.10.0/24 and reaches the lab VMs only through the firewall, like servers in an
    # internal network segment behind a perimeter firewall. The switch must exist before
    # the firewall is built, because the firewall's LAN adapter (hn1) is attached to it.
    Write-Host "== 3/7 Lab network: private switch $labSwitch =="
    if (-not (Get-VMSwitch -Name $labSwitch -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $labSwitch -SwitchType Private | Out-Null
        Write-Host "Created (private: VMs only, no access from the PC)."
    }
    else {
        Write-Host 'Already exists.'
    }

    # --- Step 4: the firewall, before every other VM (see the build order in the help).
    Write-Host "== 4/7 Firewall (OPNsense) =="
    # Every SSH login needs a valid certificate, and once OpenBao is deployed it is OpenBao that
    # signs them - reached through the firewall's port forward. After a Windows restart the
    # firewall and the vault VM are off and the PC's certificate (8 hours) has expired; "vagrant
    # up" cannot start vault, because it would need SSH. So both VMs are started directly in
    # Hyper-V and OpenBao is unsealed over HTTPS first - no SSH involved.
    $firewallVm = Get-VM -Name $firewallName -ErrorAction SilentlyContinue
    if ($firewallVm -and $firewallVm.State -ne 'Running') { Start-VM -VM $firewallVm; Write-Host "Started:     $firewallName" }
    if ($states.Contains('vault') -and $states['vault'] -notin 'running', 'not_created') {
        Start-VM -VM (Get-LabVM 'vault')
        Write-Host 'Started:     vault (Hyper-V; OpenBao signs the SSH certificates)'
    }
    if ($states.Contains('vault') -and $states['vault'] -ne 'not_created' -and (Test-LabSshOpenBaoTrusted)) {
        try { Unlock-LabVault -TimeoutSeconds 240 }
        catch { Write-Warning "OpenBao is not usable yet ($($_.Exception.Message)). SSH certificates need it; if it stays broken: .\lab.ps1 breakglass up" }
    }
    # The firewall is an OPNsense VM. There is no Vagrant box for OPNsense on Hyper-V, so
    # lab.ps1 firewall builds it: official nano image, configuration rendered from
    # opnsense\config.xml.template, first boot driven over the serial console, update to the
    # current 26.7.x. If the firewall already exists, the script only makes sure it runs and
    # re-checks it; .\lab.ps1 firewall -Rebuild builds it again from scratch.
    & (Join-Path $PSScriptRoot 'firewall.ps1') -StorageRoot $StorageRoot

    # Checks the whole DNS path from the PC: Windows resolver -> NRPT rule -> LabHost
    # network -> dnsmasq on the firewall's HOST adapter (hn2). With split-horizon DNS
    # (localise-queries), dnsmasq answers each side with the address from that side's
    # subnet, so the PC must get the firewall's LabHost address, not its lab address.
    $fwIps = Resolve-LabName "$firewallName.$labDomain"
    if ($fwIps -notcontains $firewallHostIp) {
        throw "$firewallName.$labDomain resolves to '$($fwIps -join ', ')' instead of $firewallHostIp. Is dnsmasq running on the firewall, and does the DNS rule from lab.ps1 host-setup exist?"
    }
    Write-Host "DNS from the PC: $firewallName.$labDomain -> $($fwIps -join ', ')"

    # --- Step 5: the lab VMs. They are attached only to the private LabNet. Each one has a
    # fixed MAC address (Vagrantfile), and dnsmasq on the firewall holds a DHCP reservation
    # for that MAC, so a VM always gets the same IP and name. Vagrant reads the IP from
    # Hyper-V and connects through the firewall (ssh.proxy_command with keys\ssh_config).
    # Only VMs that are not running are started, all of them in one vagrant call.
    Write-Host "== 5/7 Lab VMs: $($labMachines -join ', ') =="
    # Vagrant logs in through the firewall with the PC's SSH certificate: renewed here when it
    # expires within 4 hours, so it lasts through "vagrant up" and "vagrant provision".
    [void](Get-LabSshConfig)
    $toStart = @($labMachines | Where-Object { $states[$_] -ne 'running' })
    if ($toStart.Count -gt 0) {
        Invoke-Vagrant up @toStart --provider=hyperv --no-provision
    }
    foreach ($name in $labMachines) { Move-LabVMConfig $name }
    # Provisioning runs for every lab VM, also for VMs that were already running.
    [void](Get-LabSshConfig)
    Invoke-Vagrant provision @labMachines
    # Host certificates: each VM published its host key through Hyper-V KVP during provisioning
    # (provision/harden-ssh.sh); a certificate is signed for exactly that key when one is due and
    # installed over a connection pinned to it (LabSsh.ps1, Update-LabVmHostCertificates).
    Update-LabVmHostCertificates $labMachines

    # OpenBao is sealed after every start of the vault VM. Once it has been initialised
    # (lab.ps1 deploy vault stored key shares A and B with DPAPI), unseal it here, so certificate
    # renewals and deployments work again after a Windows restart. Before that: nothing to do.
    # A TLS certificate that is due (or already expired, after weeks without a run) is renewed
    # first: the unseal itself would be refused by the pinned TLS check. lab.ps1 deploy vault
    # renews it over SSH before any API call, then unseals.
    if (Test-Path (Join-Path $keyDir 'openbao\unseal-a.dpapi')) {
        $vaultUri = [Uri]$script:LabVaultUrl
        $vaultCert = Get-LabServedCertificate $vaultUri.Host $vaultUri.Port
        if ($vaultCert -and $vaultCert.NotAfter -lt (Get-Date).AddDays(30)) {
            Write-Host "OpenBao: TLS certificate valid until $($vaultCert.NotAfter.ToString('yyyy-MM-dd')) -> deploy vault (renews it, then unseals)"
            Invoke-LabVaultDeploy
        }
        else {
            Write-Host 'OpenBao: unsealing'
            Unlock-LabVault
        }
    }

    # --- Step 6: the PC's view, then Ansible from ansible-control.
    Write-Host '== 6/7 Checks from the PC, then base setup and checks from ansible-control =='
    # Names as the PC sees them. Names that are published ("published" in config\lab.json,
    # for example matrix and keycloak) resolve to the VM's published address on the firewall
    # (10.10.99.x), which forwards the listed ports to the VM (DNAT). Other names resolve to
    # their lab address, which the PC cannot reach directly; that is expected.
    foreach ($name in $labMachines) {
        Write-Host "DNS from the PC: $name.$labDomain -> $((Resolve-LabName "$name.$labDomain") -join ', ')"
    }
    $sshConfig = Get-LabSshConfig
    foreach ($name in @($firewallName) + $labMachines) {
        # SSH to every VM the way a user would (the firewall directly, the others through
        # it): tests the PC's certificate, every host certificate (keys\ssh_config accepts host
        # keys only with one), the user "ansible" and the jump host. The command is in
        # single quotes, so PowerShell passes it on unchanged and the $(...) parts run in
        # the VM's shell. The firewall runs FreeBSD (OPNsense), whose hostname command has no
        # -I option, so it reports its OPNsense version instead.
        # LogLevel=ERROR hides the "Permanently added ..." notice on stderr, which Windows
        # PowerShell 5.1 would otherwise turn into a terminating error when the output is
        # redirected (*> log). No double quotes inside the command: PowerShell 5.1 does not
        # pass embedded double quotes to native programs correctly.
        $command = 'echo SSH ok: $(whoami)@$(hostname) $(hostname -I)'
        if ($name -eq $firewallName) { $command = 'echo SSH ok: $(whoami)@$(hostname) OPNsense $(opnsense-version -v)' }
        & ssh -F $sshConfig -o LogLevel=ERROR $name $command
        if ($LASTEXITCODE -ne 0) { throw "SSH to $name failed (exit code $LASTEXITCODE)." }
    }
    # Everything past the bootstrap is configuration management on ansible-control: base.yml
    # (zsh, console autologin) on every Ubuntu VM, then checks.yml, which connects from
    # ansible-control to every machine by its DNS name with ansible-control's own key and a
    # certificate for this run, checks their host certificates, sudo, sshd's settings and the
    # firewall's bootstrap contract (lib\LabRun.ps1, config\run-profiles.json).
    Invoke-LabRun base
    if ($LASTEXITCODE -ne 0) { throw "base.yml failed (exit code $LASTEXITCODE)." }
    Invoke-LabRun checks
    if ($LASTEXITCODE -ne 0) { throw "checks.yml failed (exit code $LASTEXITCODE)." }
}
finally {
    # Restores the caller's value. If VAGRANT_CWD was not set before, assigning $null removes it.
    $env:VAGRANT_CWD = $previousVagrantCwd
}

# --- Step 7: maintenance - renewals that are due ------------------------------------------------
# Certificates expire, and they are only renewed when the script that renews them runs. This
# script runs after every Windows restart anyway, so it checks what is due (Get-LabMaintenanceDue
# in LabSecrets.ps1: OpenBao's certificate, the root CA's revocation list, the intermediate CA,
# Keycloak's and the firewall's certificates) and runs the deployment that renews it. Traefik
# renews the Matrix certificates itself.
$maintenanceDone = $false
if (Test-Path (Join-Path $keyDir 'openbao\unseal-a.dpapi')) {
    Write-Host '== 7/7 Maintenance: renewals that are due =='
    Invoke-LabMaintenance
    $maintenanceDone = $true
}

Write-Host ''
Write-Host 'Done. Log in with:  .\lab.ps1 connect  (or: .\lab.ps1 connect matrix / keycloak / vault / firewall)'
if ((Test-Path (Join-Path $keyDir 'openbao\unseal-c.sha256')) -and -not (Test-LabSshCaInRecoveryKit)) {
    Write-Host 'PENDING: your recovery file has no copy of the current offline SSH CA. In your own PowerShell window:  .\lab.ps1 recovery -Renew'
}
if (-not $maintenanceDone) {
    Write-Host 'Next: .\lab.ps1 deploy vault (OpenBao), .\lab.ps1 trust (once per PC), .\lab.ps1 recovery (in your own window),'
    Write-Host '      then .\lab.ps1 deploy keycloak and .\lab.ps1 deploy matrix (Element: https://element.lab.internal)'
}
