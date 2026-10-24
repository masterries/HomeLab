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
    $nonDpapi = @(Get-ChildItem (Join-Path $script:LabKeysDir 'opnsense') -File | Where-Object { $_.Extension -ne '.dpapi' })
    Assert-LabTest 'keys\opnsense holds only DPAPI files' ($nonDpapi.Count -eq 0) (($nonDpapi | ForEach-Object Name) -join ', ')
}
finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch }
Complete-LabTest 'Test-LabFirewallRender'
