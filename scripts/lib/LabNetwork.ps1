<#
.SYNOPSIS
    The lab's networks behind the firewall: LabNet and the further segments of config\lab.json
    (for example LabK8s, the Kubernetes network), checked once for every reader.

.DESCRIPTION
    Not run directly; loaded by scripts\lib\Lab.ps1 after LabSecrets.ps1 (which reads lab.json).

    WHAT A SEGMENT IS
    A network of its own behind the firewall: its own private Hyper-V switch (only VMs are
    connected, your PC has no adapter there), its own firewall interface with its own address,
    DHCP range and filter rules. VMs in a segment ("network": "<segment>" in lab.json) reach other
    networks only through the firewall, so its rules decide what crosses: the Kubernetes nodes,
    for example, may not open connections into LabNet at all, and from LabNet only ansible-control
    (SSH) and central nginx (the published web ports) may reach them. Enterprise equivalent: a
    VLAN or VPC subnet per zone (server, cluster, management), with the firewall between zones.

    "segments" in config\lab.json, one entry each:
      name        short name, used by the VMs' "network" field (k8s)
      switch      the private Hyper-V switch (LabK8s), created by lab.ps1 up and lab.ps1 firewall
      cidr        the segment's network, a /24 (10.10.20.0/24)
      firewallIp  the firewall's address there: gateway, DNS and DHCP server of the segment
      interface   OPNsense's name for it: opt2 for the first segment, opt3 for the second, ...
      device      FreeBSD's name for its adapter: hn3, hn4, ... (appended after WAN, LAN, HOST)
      mac         the firewall adapter's MAC (by convention the last four bytes = firewallIp)
#>

# Is an IPv4 address inside a network given as a.b.c.d/n?
function Test-LabAddressInNetwork([string]$Address, [string]$Network) {
    $base, $bits = $Network -split '/'
    # As 64-bit numbers: PowerShell reads 0xFFFFFFFF as the 32-bit -1, so no hex masks here.
    $toNumber = { param($Text) $b = ([Net.IPAddress]::Parse($Text)).GetAddressBytes(); ([long]$b[0] -shl 24) + ([long]$b[1] -shl 16) + ([long]$b[2] -shl 8) + [long]$b[3] }
    $mask = ([long]1 -shl 32) - ([long]1 -shl (32 - [int]$bits))
    return (((& $toNumber $Address) -band $mask) -eq ((& $toNumber $base) -band $mask))
}

# The segments of lab.json, checked: names, switches, addresses, interface order. A mistake here
# would otherwise surface much later (a firewall that boots with the wrong interface, a VM that
# gets no address), so every reader goes through this function.
function Get-LabSegments {
    $lab = $script:LabConfig
    if (-not $lab.PSObject.Properties['segments']) { return @() }
    $segments = @($lab.segments)
    $taken = @{ names = @(); switches = @('Default Switch', 'LabNet', 'LabHost'); networks = @($lab.labNetwork, $lab.hostNetwork) }
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $s = $segments[$i]
        $where = "config\lab.json, segments[$i] ($($s.name))"
        if ($s.name -notmatch '^[a-z][a-z0-9]{0,15}$' -or $taken.names -contains $s.name) { throw "${where}: name must be short lower-case letters/digits and unique." }
        if (-not $s.switch -or $taken.switches -contains $s.switch) { throw "${where}: switch '$($s.switch)' is missing or already used." }
        if ($s.cidr -notmatch '^(\d{1,3}\.){3}0/24$') { throw "${where}: cidr must be a /24 network ending in .0, not '$($s.cidr)'." }
        foreach ($other in $taken.networks) {
            if ((Test-LabAddressInNetwork ($s.cidr -split '/')[0] $other) -or (Test-LabAddressInNetwork ($other -split '/')[0] $s.cidr)) { throw "${where}: $($s.cidr) overlaps $other." }
        }
        if (-not (Test-LabAddressInNetwork $s.firewallIp $s.cidr)) { throw "${where}: firewallIp $($s.firewallIp) is not in $($s.cidr)." }
        # Appended after WAN (hn0/wan), LAN (hn1/lan) and HOST (hn2/opt1), in lab.json's order.
        if ($s.interface -ne "opt$($i + 2)" -or $s.device -ne "hn$($i + 3)") { throw "${where}: interface/device must be opt$($i + 2)/hn$($i + 3) (segments are appended after the three fixed interfaces, in this order)." }
        if ($s.mac -notmatch '^02[0-9A-F]{10}$') { throw "${where}: mac must be 12 upper-case hex digits starting with 02 (locally administered)." }
        $taken.names += $s.name; $taken.switches += $s.switch; $taken.networks += $s.cidr
    }
    foreach ($vm in $lab.vms) {
        $network = Get-LabVmNetwork $vm $segments
        $cidr = if ($network) { $network.cidr } else { $lab.labNetwork }
        if (-not (Test-LabAddressInNetwork $vm.ip $cidr)) { throw "config\lab.json, vms: $($vm.name) ($($vm.ip)) is not in its network $cidr." }
    }
    return $segments
}

# A VM's segment, or $null for LabNet (no "network" field, or "network": "lab").
function Get-LabVmNetwork($Vm, $Segments = (Get-LabSegments)) {
    if (-not $Vm.PSObject.Properties['network'] -or $Vm.network -in '', 'lab') { return $null }
    $segment = @($Segments) | Where-Object { $_.name -eq $Vm.network } | Select-Object -First 1
    if (-not $segment) { throw "config\lab.json, vms: $($Vm.name) names the unknown network '$($Vm.network)' (not in segments)." }
    return $segment
}

# The firewall's address in a VM's network: its gateway, and the source address of every SSH
# connection the jump host opens to it.
function Get-LabVmGateway([string]$Name) {
    $vm = $script:LabConfig.vms | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $vm) { throw "No VM '$Name' in config\lab.json." }
    $segment = Get-LabVmNetwork $vm
    if ($segment) { return $segment.firewallIp }
    return $script:LabConfig.firewall.lanIp
}

# Every address the firewall has towards the VMs (LabNet and each segment).
function Get-LabFirewallVmAddresses {
    return @($script:LabConfig.firewall.lanIp) + @(Get-LabSegments | ForEach-Object { $_.firewallIp })
}

# The private Hyper-V switches of the lab networks: LabNet and one per segment. "Private" = only
# VMs are connected; the PC has no adapter there and reaches the VMs only through the firewall.
# Needs an elevated PowerShell (Hyper-V). Creating one is harmless; removing one is left to you.
function Initialize-LabPrivateSwitches {
    foreach ($name in @('LabNet') + @(Get-LabSegments | ForEach-Object { $_.switch })) {
        if (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue) { continue }
        New-VMSwitch -Name $name -SwitchType Private | Out-Null
        Write-Host "Switch:      $name created (private: VMs only)"
    }
}
