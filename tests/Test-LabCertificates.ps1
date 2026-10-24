<#
.SYNOPSIS
    Checks every HTTPS endpoint of the lab the way Windows sees it: who issued the certificate,
    how long it is valid, and whether Windows trusts the chain including the revocation check.

.DESCRIPTION
    Read-only. Needs the lab root CA imported into Windows (.\lab.ps1 trust);
    without it every "trusted" check fails. Expected issuers:
      firewall.lab.internal, vault.lab.internal:8200   the offline root CA
      keycloak, matrix, element, lab.internal          the current intermediate CA in OpenBao
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
$issuingKeyId = ($issuing.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension] }).SubjectKeyIdentifier
$rootKeyId = ($root.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension] }).SubjectKeyIdentifier

function Get-AuthorityKeyId($Certificate) {
    $extension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.35' }
    if (-not $extension -or $extension.RawData[2] -ne 0x80) { return '' }
    return -join ($extension.RawData[4..(3 + $extension.RawData[3])] | ForEach-Object { $_.ToString('X2') })
}

$endpoints = @(
    @{ Host = "firewall.$domain"; Port = 443; Issuer = 'root' },
    @{ Host = "vault.$domain"; Port = 8200; Issuer = 'root' },
    @{ Host = "keycloak.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "matrix.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = "element.$domain"; Port = 443; Issuer = 'intermediate' },
    @{ Host = $domain; Port = 443; Issuer = 'intermediate' }
)
Write-Host "Certificates (current intermediate: $($issuing.Subject -replace '^CN=', ''))"
foreach ($e in $endpoints) {
    $cert = Get-LabServedCertificate $e.Host $e.Port
    if (-not $cert) { Assert-LabTest "$($e.Host):$($e.Port) answers" $false; continue }
    $expected = if ($e.Issuer -eq 'root') { $rootKeyId } else { $issuingKeyId }
    Assert-LabTest "$($e.Host):$($e.Port) issued by the $($e.Issuer) CA" ((Get-AuthorityKeyId $cert) -eq $expected) ($cert.Issuer -replace '^CN=', '')
    Assert-LabTest "$($e.Host):$($e.Port) valid for more than 30 days" ($cert.NotAfter -gt (Get-Date).AddDays(30)) "until $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'Online'
    $trusted = $chain.Build($cert)
    Assert-LabTest "$($e.Host):$($e.Port) trusted by Windows, revocation checked" $trusted (($chain.ChainStatus | ForEach-Object { $_.Status }) -join ',')
}
Complete-LabTest 'Test-LabCertificates'
