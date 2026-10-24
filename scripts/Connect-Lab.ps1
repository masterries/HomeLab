<#
.SYNOPSIS
    Opens an SSH session as user "ansible" on a lab VM.

.DESCRIPTION
    Runs on the Windows host, in PowerShell, as your own Windows user. Uses
    keys\ssh_config, which Initialize-Lab.ps1 writes:
      - firewall: directly at its fixed address on the internal switch LabHost (10.10.99.2)
      - every other VM (ansible-control, matrix, keycloak): by its name <name>.lab.internal,
        with the firewall as jump host (ProxyJump)
    The firewall is reached at its fixed LabHost address, not through the Default Switch
    (whose addresses change on every Windows reboot), so this keeps working after a reboot.

    Further arguments are passed on to ssh, for example a command to run on the VM. Without
    a command you get an interactive shell. The only thing it may change: it renews this PC's
    SSH certificate when that expires within 4 hours (Get-LabSshConfig, LabSsh.ps1).

.PARAMETER Machine
    The VM to connect to, as named in keys\ssh_config: ansible-control (default), matrix,
    keycloak, vault or firewall.

.PARAMETER BreakGlass
    If OpenBao cannot sign a new certificate (vault VM broken), let the offline SSH CA sign it
    (see Update-LabSshCertificate.ps1 -BreakGlass).

.EXAMPLE
    .\scripts\Connect-Lab.ps1                      # ansible-control
    .\scripts\Connect-Lab.ps1 matrix
    .\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -sr'      # OPNsense: active filter rules
#>
# BASTION / JUMP HOST
# From the PC, only the firewall VM (OPNsense) is reachable. Besides its internet uplink (hn0
# on the Default Switch), it has one network leg in LabHost (10.10.99.0/24, shared with the PC) and
# one in the private switch LabNet (10.10.10.0/24, VMs only). The PC has no route into
# LabNet; even the chat on "matrix" and the login pages on "keycloak" are reached through the
# firewall, which forwards their published ports to them. This is the bastion host pattern: a
# hardened entry point for administrative access, where access can be restricted, logged and
# audited in one place, while the servers behind it are not exposed at all.
#
# How ProxyJump works: ssh first logs in to the firewall, then asks the firewall's SSH
# server to open a TCP connection to <name>.lab.internal, port 22, and tunnels it back to the
# PC. The SSH session to the target runs end-to-end encrypted inside that tunnel and
# authenticates with the key on the PC; the firewall only relays encrypted bytes and never
# sees the private key. The target name is resolved on the firewall, whose DNS (dnsmasq)
# answers with the VM's LabNet address.
#
# Both hops log in with this PC's SSH certificate (8 hours, principal lab-all; LabSsh.ps1) and
# check the machine's host certificate against the lab's SSH CAs, so even the very first
# connection to a rebuilt VM is verified. The firewall only lets a login forward to port 22 of
# the lab VMs (opnsense\sshd_config.d\20-lab-ssh.conf).
#
# Lab shortcuts and their enterprise equivalents:
#   - The PC signs its own certificate (an AppRole stored with DPAPI). Enterprise: personal
#     accounts with SSO and MFA at the SSH CA, certificates for the person's identity.
#   - A self-built bastion. Enterprise: often a managed or dedicated product with session
#     recording (for example Azure Bastion, AWS Systems Manager Session Manager, Teleport).
#
# A plain script without [CmdletBinding()]: every argument after -Machine lands in $args and
# is passed on to ssh (an advanced script would reject unknown extra arguments). A switch such
# as -BreakGlass never takes a positional value, so it does not disturb that.
param(
    [string]$Machine = 'ansible-control',
    [switch]$BreakGlass
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'LabSecrets.ps1')
$sshConfig = Get-LabSshConfig -BreakGlass:$BreakGlass

# -F: use only the lab's config file; your own ~/.ssh/config is not read.
& ssh -F $sshConfig $Machine @args
# Pass ssh's exit code on: the exit status of the remote command, or 255 if the connection
# failed.
exit $LASTEXITCODE
