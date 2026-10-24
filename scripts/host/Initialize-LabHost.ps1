<#
.SYNOPSIS
    One-time setup of the lab's fixed host network on this PC: Hyper-V switch "LabHost",
    fixed IP 10.10.99.1 and DNS for *.lab.internal through the lab firewall.

.DESCRIPTION
    WHAT THIS IS
    Part of the DeployableServer home lab. It gives your Windows PC a small, stable
    management network to the lab's perimeter firewall. It runs on the Windows host, in
    an elevated PowerShell ("Run as administrator"). Because it changes Windows network
    settings, no other lab script runs it for you: you run it yourself, once, before the
    first .\lab.ps1 up (which refuses to start without this network).

    WHAT IT DOES
      1. Creates the Hyper-V switch "LabHost" of type Internal. Windows gets a virtual
         network adapter "vEthernet (LabHost)" for it; the firewall VM's HOST adapter
         (hn2, 10.10.99.2, plus one published address per published VM: 10.10.99.3 for
         matrix, 10.10.99.4 for keycloak) is connected to the same switch.
      2. Sets the fixed IP 10.10.99.1/24 on that adapter, without a default gateway:
         your internet access and your home network stay exactly as they are. Windows
         only sends traffic for 10.10.99.0/24 through this adapter.
      3. Adds a DNS rule (NRPT, see below): Windows sends queries for names under
         lab.internal to the firewall (10.10.99.2). All other names are resolved by
         your normal DNS servers, as before.

    HYPER-V SWITCH TYPES USED BY THE LAB
      Internal        The VMs on the switch and the Windows host can talk to each other;
                      Windows gets a "vEthernet (<name>)" adapter. Nothing is routed to
                      other networks unless Windows is told to. -> "LabHost"
      Private         Only the VMs on the switch can talk to each other; Windows has no
                      adapter on it and cannot reach them at all. -> "LabNet", the lab
                      network behind the firewall (created by lab.ps1 up).
      Default Switch  Created and managed by Windows: an internal switch plus NAT and
                      DHCP (Internet Connection Sharing). The firewall's WAN adapter (hn0)
                      uses it for internet access only; nothing connects into the lab
                      through it (Vagrant, too, goes through the firewall at 10.10.99.2).
                      Its subnet changes on every Windows reboot and its
                      <host>.mshome.net names go stale, so it cannot serve as a stable
                      way into the lab.
    (A fourth type, External, bridges VMs onto a physical network card, which would put
    them into your home network. The lab does not use it.)

    WHY A FIXED MANAGEMENT NETWORK
    You need addresses that never change: the SSH jump host (bastion) and the DNS server
    for lab.internal are always reached at 10.10.99.2, the published services at
    10.10.99.3 (the Matrix chat) and 10.10.99.4 (Keycloak). Your PC has no route into LabNet
    (10.10.10.0/24) and never talks to ansible-control, matrix or keycloak directly; all
    traffic goes through the firewall, which decides what is allowed.
    Enterprises do the same with a dedicated management network (often a separate VLAN),
    a documented IP address plan, and access to internal systems only through a bastion
    host or VPN, never directly from client machines.

    WHAT NRPT IS
    The Name Resolution Policy Table is a feature of the Windows DNS client: rules that
    send queries for a given namespace to specific DNS servers. DirectAccess and Windows
    VPN profiles (e.g. Always On VPN) use the same mechanism for "split DNS". Here one
    rule sends *.lab.internal to dnsmasq on the firewall. dnsmasq does split-horizon DNS:
    for published names it answers your PC with the published address of the VM on the
    firewall (10.10.99.3 or 10.10.99.4, from which the firewall forwards the published
    ports), and VMs inside the lab with their real LabNet addresses. In an enterprise you
    would instead add a conditional forwarder for the zone on the company DNS servers, or
    push NRPT rules to clients by Group Policy or Intune. ".internal" is a top-level
    domain reserved for private use, so lab.internal can never clash with a real public
    name.

    IDEMPOTENCY
    Each step first checks whether its result already exists and only changes what is
    missing or wrong, so the script can safely run any number of times, and the
    addresses survive Windows reboots. -Remove undoes all three steps.

.PARAMETER Remove
    Remove everything again (DNS rule, IP address and switch).

.EXAMPLE
    .\lab.ps1 host-setup
    Creates the switch, the IP address and the DNS rule (or confirms they are in place).

.EXAMPLE
    .\lab.ps1 host-setup -Remove
    Removes the DNS rule and the switch; removing the switch also removes its IP address.
#>
[CmdletBinding()]
param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# Must match config\lab.json (firewall "hostIp" 10.10.99.2 and "pcIp" 10.10.99.1, the
# firewall's HOST adapter on switch LabHost) and the OPNsense configuration built by
# lab.ps1 firewall (its dnsmasq answers DNS for lab.internal on that address).
$switchName = 'LabHost'
$hostIp = '10.10.99.1'
$prefixLength = 24
$dnsServer = '10.10.99.2'
# Leading dot: the rule applies to every name ending in .lab.internal and, as checked in this
# lab, to lab.internal itself (Matrix serves its .well-known files there).
$namespace = '.lab.internal'
$adapterAlias = "vEthernet ($switchName)"

# Switches, IP addresses and NRPT rules can only be changed by an administrator. Fail
# early with a clear message instead of halfway through with "access denied".
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please start PowerShell with "Run as administrator".'
}

# Existing NRPT rules for our namespace. They are found by namespace, not by their
# comment, so a rule for .lab.internal created some other way is also detected.
$rules = @(Get-DnsClientNrptRule | Where-Object { $_.Namespace -contains $namespace })

# --- -Remove: undo everything this script sets up ---
if ($Remove) {
    foreach ($rule in $rules) { Remove-DnsClientNrptRule -Name $rule.Name -Force }
    if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
        # Also removes the network adapter "vEthernet (LabHost)" together with its IP.
        Remove-VMSwitch -Name $switchName -Force
    }
    # Forget cached lab.internal answers so the change takes effect immediately.
    Clear-DnsClientCache
    Write-Host 'Lab host network removed.'
    return
}

# --- Step 1: the Internal switch ---
# Internal, not Private: Windows itself must be connected to it. Not the Default Switch:
# its addresses change on every reboot.
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    Write-Host "Switch $switchName created."
}

# Windows creates the host adapter of a new switch asynchronously; wait up to about
# 10 seconds (20 tries, 0.5 s apart) for it to appear.
$adapter = $null
for ($try = 0; $try -lt 20 -and -not $adapter; $try++) {
    if ($try -gt 0) { Start-Sleep -Milliseconds 500 }
    $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
}
if (-not $adapter) { throw "Network adapter '$adapterAlias' not found." }

# --- Step 2: static address on the host adapter ---
# A static address (no DHCP) keeps this network predictable. There is deliberately no
# -DefaultGateway: the default route (internet) stays on your normal network adapter,
# and only 10.10.99.0/24 is reached through LabHost.
if (-not (Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $hostIp })) {
    New-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $hostIp -PrefixLength $prefixLength | Out-Null
    Write-Host "Fixed IP $hostIp/$prefixLength set on '$adapterAlias'."
}

# --- Step 3: NRPT rule for *.lab.internal ---
# Add the rule if it is missing. If rules for the namespace exist but at least one points
# to a different DNS server, point all of them at the firewall. The comment
# 'DeployableServer-Lab' only labels the rule (shown by Get-DnsClientNrptRule).
if ($rules.Count -eq 0) {
    Add-DnsClientNrptRule -Namespace $namespace -NameServers $dnsServer -Comment 'DeployableServer-Lab' | Out-Null
    Write-Host "DNS rule created: *$namespace -> $dnsServer"
}
elseif (@($rules | Where-Object { @($_.NameServers) -notcontains $dnsServer }).Count -gt 0) {
    foreach ($rule in $rules) { Set-DnsClientNrptRule -Name $rule.Name -NameServers $dnsServer }
    Write-Host "DNS rule corrected to $dnsServer."
}
# Drop cached answers, including "name not found" results from before the rule existed.
Clear-DnsClientCache

Write-Host ''
Write-Host "Done: your PC is $hostIp in the lab host network and asks $dnsServer for names under lab.internal."
Write-Host 'Next: .\lab.ps1 up builds the firewall (OPNsense) with its HOST adapter in this network.'
