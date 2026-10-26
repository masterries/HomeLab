<#
.SYNOPSIS
    Checks the build path of lab.ps1 firewall without building a firewall: secrets, GUI
    certificate, rendered config.xml and seed ISO, all into a temporary folder.

.DESCRIPTION
    Loads everything of lab.ps1 firewall before its main part (parameters, paths, functions),
    points the VM folder to a temporary folder and runs Get-Secrets, Get-GuiCertificate,
    New-FirewallConfig and New-SeedIso. Checks: the GUI certificate is signed by the lab root,
    the root is the CA in config.xml, the GUI key is in it, the password hashes are SHA-512-crypt,
    the ISO exists and its staging folder (with the plain config.xml) is gone, keys\opnsense
    holds only DPAPI files.

    Side effects, all harmless: the offline root signs one extra GUI certificate (it is listed in
    keys\pki\crl\index.txt; keys\pki\issued\firewall-gui.crt is put back as it was), and the
    temporary folder is deleted at the end. Nothing is printed that is secret.

.EXAMPLE
    .\tests\Test-LabFirewallRender.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

$scratch = Join-Path ([IO.Path]::GetTempPath()) "lab-fwtest-$PID"
$archived = Join-Path $script:LabKeysDir 'pki\issued\firewall-gui.crt'
$archivedCopy = if (Test-Path $archived) { [IO.File]::ReadAllText($archived) } else { $null }

# The firewall's building blocks (lib\LabFirewall.ps1), with the default storage location.
$StorageRoot = 'G:\Vagrant'; $TimeZone = 'Europe/Berlin'
. (Join-Path $script:LabTestRoot 'scripts\lib\LabFirewall.ps1')
$vmDir = Join-Path $scratch 'firewall'
$seedIso = Join-Path $vmDir 'seed\lab-config.iso'

Write-Host 'Firewall build path (rendered into a temporary folder)'
try {
    $secrets = Get-Secrets
    try { $certificate = Get-GuiCertificate }
    finally { if ($archivedCopy) { [IO.File]::WriteAllText($archived, $archivedCopy) } }
    $configXml = New-FirewallConfig $secrets $certificate
    $secrets = $null
    New-SeedIso $configXml
    $xml = [xml]$configXml
    $configXml = $null
    $crt = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($xml.opnsense.cert.crt))
    $caCrt = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($xml.opnsense.ca.crt))
    $leaf = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($crt))
    $ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($caCrt))
    $root = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $script:LabRootCaCert
    Assert-LabTest 'GUI certificate signed by the lab root' ($leaf.Issuer -eq $root.Subject) ($leaf.Issuer -replace '^CN=', '')
    Assert-LabTest 'GUI certificate for firewall.<domain>' ($leaf.GetNameInfo('DnsName', $false) -eq "firewall.$($script:LabConfig.domain)")
    Assert-LabTest 'the CA in config.xml is the lab root' ($ca.Thumbprint -eq $root.Thumbprint)
    Assert-LabTest 'GUI private key in config.xml' ([bool]$xml.opnsense.cert.prv)
    Assert-LabTest 'root password stored as SHA-512-crypt hash' ($xml.opnsense.system.user[0].password -like '$6$*')
    Assert-LabTest 'seed ISO written' ((Test-Path $seedIso) -and (Get-Item $seedIso).Length -gt 0)
    Assert-LabTest 'staging folder with the plain config.xml removed' (-not (Test-Path (Join-Path $vmDir 'seed\content')))
    # SSH: user ansible accepts the lab's SSH CAs (cert-authority lines with principals and from=),
    # including the offline CA, from the very first boot.
    $authorized = @(([Text.Encoding]::ASCII.GetString([Convert]::FromBase64String(($xml.opnsense.system.user | Where-Object { $_.name -eq 'ansible' }).authorizedkeys))) -split "`n" | Where-Object { $_ })
    $caLines = @($authorized | Where-Object { $_ -like 'cert-authority,principals="lab-all,host-firewall",from="*" ssh-ed25519 *' })
    $offlineCa = (([IO.File]::ReadAllText("$($script:LabSshOfflineCa).pub").Trim() -split '\s+')[1])
    Assert-LabTest 'ansible accepts the lab SSH CAs (cert-authority, principals, from)' ($caLines.Count -ge 1 -and ($caLines -join "`n").Contains($offlineCa)) "$($caLines.Count) CA line(s)"
    Assert-LabTest 'no other key lines than the CAs' (@($authorized | Where-Object { $caLines -notcontains $_ }).Count -eq 0)
    # Segments (config\lab.json "segments", e.g. LabK8s): adapter, interface, DHCP, DNS, rules.
    $rules = @($xml.opnsense.OPNsense.Firewall.Filter.rules.rule)
    $lanRules = @($rules | Where-Object { $_.interface -eq 'lan' } | Sort-Object { [int]$_.sequence })
    $lanPassAll = [array]::IndexOf($lanRules, @($lanRules | Where-Object { $_.action -eq 'pass' -and $_.destination_net -eq 'any' })[0])
    $controlIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip
    $nginxIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'nginx' }).ip
    foreach ($segment in @(Get-LabSegments)) {
        $label = $segment.name.ToUpper()
        $position = [array]::IndexOf(@($adapters | ForEach-Object { $_.Device }), $segment.device)
        Assert-LabTest "${label}: adapter $($segment.device) appended after WAN, LAN and HOST" ($position -ge 3 -and $adapters[$position].Switch -eq $segment.switch -and $adapters[$position].Mac -eq $segment.mac)
        $interface = $xml.opnsense.interfaces.($segment.interface)
        Assert-LabTest "${label}: interface $($segment.interface) on $($segment.device) with $($segment.firewallIp)/24" ($interface -and $interface.if -eq $segment.device -and $interface.ipaddr -eq $segment.firewallIp -and $interface.subnet -eq '24')
        Assert-LabTest "${label}: dnsmasq answers DNS and DHCP there" ((($xml.opnsense.dnsmasq.interface -split ',') -contains $segment.interface) -and $xml.opnsense.dnsmasq.dhcp.no_interface -eq 'opt1')
        Assert-LabTest "${label}: one DHCP range" (@($xml.opnsense.dnsmasq.dhcp_ranges | Where-Object { $_.interface -eq $segment.interface }).Count -eq 1)
        $members = @($script:LabConfig.vms | Where-Object { $_.network -eq $segment.name })
        $reserved = @($members | Where-Object { $vm = $_; @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq $vm.name -and $_.ip -eq $vm.ip -and $_.hwaddr }).Count -eq 1 })
        Assert-LabTest "${label}: a DHCP reservation for each of its VMs" ($members.Count -gt 0 -and $reserved.Count -eq $members.Count) "$($reserved.Count) of $($members.Count)"
        $own = @($rules | Where-Object { $_.interface -eq $segment.interface } | Sort-Object { [int]$_.sequence })
        $passes = @($own | Where-Object { $_.action -eq 'pass' })
        Assert-LabTest "${label}: passes only DNS to the firewall, then the internet last" ($passes.Count -eq 3 -and @($passes[0..1] | Where-Object { $_.destination_net -eq $segment.firewallIp -and $_.destination_port -eq '53' }).Count -eq 2 -and $own[-1].action -eq 'pass' -and $own[-1].destination_net -eq 'any')
        $blocked = @($own | Where-Object { $_.action -eq 'block' } | ForEach-Object { $_.destination_net })
        Assert-LabTest "${label}: blocks the firewall's other services, LabNet, the PC network and WAN" ((@($segment.firewallIp, 'lan', 'opt1', 'wan') | Where-Object { $blocked -notcontains $_ }).Count -eq 0) ($blocked -join ', ')
        $into = @($lanRules | Where-Object { $_.destination_net -eq $segment.cidr -or ($_.destination_net -match '^\d+\.\d+\.\d+\.\d+$' -and (Test-LabAddressInNetwork $_.destination_net $segment.cidr)) })
        $intoPasses = @($into | Where-Object { $_.action -eq 'pass' })
        $blockInto = [array]::IndexOf($lanRules, @($into | Where-Object { $_.action -eq 'block' })[0])
        Assert-LabTest "${label}: LabNet is blocked from it, before 'Lab to internet'" ($blockInto -ge 0 -and $blockInto -lt $lanPassAll)
        Assert-LabTest "${label}: from LabNet only ansible-control (SSH) and nginx get in" ((@($intoPasses | Where-Object { -not (($_.source_net -eq $controlIp -and $_.destination_port -eq '22') -or $_.source_net -eq $nginxIp) }).Count -eq 0) -and @($intoPasses | Where-Object { $_.source_net -eq $controlIp }).Count -eq 1) "$($intoPasses.Count) pass rule(s)"
    }
    $nonDpapi = @(Get-ChildItem (Join-Path $script:LabKeysDir 'opnsense') -File | Where-Object { $_.Extension -ne '.dpapi' })
    Assert-LabTest 'keys\opnsense holds only DPAPI files' ($nonDpapi.Count -eq 0) (($nonDpapi | ForEach-Object Name) -join ', ')
}
finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch }
Complete-LabTest 'Test-LabFirewallRender'
