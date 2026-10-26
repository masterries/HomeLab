<#
.SYNOPSIS
    Checks every HTTPS endpoint of the lab the way Windows sees it: who issued the certificate,
    how long it is valid, and whether Windows trusts the chain including the revocation check.

.DESCRIPTION
    Read-only. Needs the lab root CA imported into Windows (.\lab.ps1 trust);
    without it every "trusted" check fails. Expected issuers:
      vault.lab.internal:8200 (directly, never via nginx) the offline root CA
      firewall, keycloak, matrix, element, lab.internal  the current intermediate CA in OpenBao
      rustfs.lab.internal and rustfs-console.lab.internal the current intermediate CA in OpenBao
      rancher.lab.internal and hubble.lab.internal        the current intermediate CA in OpenBao
                                                          (Kubernetes: lab.ps1 deploy k8s)
    (A newly built firewall starts with a certificate from the root; lab.ps1 up and
    lab.ps1 deploy firewall move it to the intermediate.)
    The "current intermediate" is compared by key identifier (authority key identifier of the
    certificate = subject key identifier of OpenBao's issuing CA), as lab.ps1 deploy matrix does.

.EXAMPLE
    .\tests\Test-LabCertificates.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

$domain = $script:LabConfig.domain
$root = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $script:LabRootCaCert
$issuingPem = (Invoke-LabBao GET 'pki_int/cert/ca').data.certificate
$issuing = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($issuingPem))
$issuingKeyId = Get-LabSubjectKeyId $issuing
$rootKeyId = Get-LabSubjectKeyId $root

$endpoints = @(
    @{ Host = "firewall.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "vault.$domain"; Port = 8200; Issuer = 'root' },
    @{ Host = "keycloak.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "rustfs.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "rustfs-console.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "matrix.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "element.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = $domain; Port = 443; Issuer = 'intermediate' },
    @{ Host = "rancher.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "hubble.$domain"; Port = 443; Issuer = 'intermediate' }
)
Write-Host "Certificates (current intermediate: $($issuing.Subject -replace '^CN=', ''))"
foreach ($e in $endpoints) {
    $cert = Get-LabServedCertificate $e.Host $e.Port
    if (-not $cert) { Assert-LabTest "$($e.Host):$($e.Port) answers" $false; continue }
    $expected = if ($e.Issuer -eq 'root') { $rootKeyId } else { $issuingKeyId }
    Assert-LabTest "$($e.Host):$($e.Port) issued by the $($e.Issuer) CA" ((Get-LabAuthorityKeyId $cert) -eq $expected) ($cert.Issuer -replace '^CN=', '')
    Assert-LabTest "$($e.Host):$($e.Port) valid for more than 30 days" ($cert.NotAfter -gt (Get-Date).AddDays(30)) "until $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'Online'
    $trusted = $chain.Build($cert)
    Assert-LabTest "$($e.Host):$($e.Port) trusted by Windows, revocation checked" $trusted (($chain.ChainStatus | ForEach-Object { $_.Status }) -join ',')
}
Complete-LabTest 'Test-LabCertificates'
