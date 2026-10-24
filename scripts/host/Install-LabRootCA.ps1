<#
.SYNOPSIS
    Makes Windows trust the lab's root CA, so that HTTPS in the lab works without certificate
    warnings.

.DESCRIPTION
    WHAT THIS IS
    Part of the DeployableServer home lab. It runs on the Windows host as your own user
    and needs no administrator rights (an elevated shell works too). Trusting a CA is a
    security setting of your PC, so no other lab script runs it for you: you run it
    yourself, once, after the root CA exists (lab.ps1 deploy vault creates it).

    WHAT IT DOES
    Imports the lab's root certificate into the "Trusted Root Certification Authorities"
    store of your Windows user (Cert:\CurrentUser\Root), not into the machine-wide store:
      keys\pki\root-ca.crt     "DeployableServer Lab Root CA 2026", the offline root of the
                               lab's two-level PKI (lib\LabPki.ps1)
    Windows shows a security warning with the certificate's thumbprint; confirm it with "Yes".
    You can compare that thumbprint with the one this script prints.
    The lab's first CA ("DeployableServer Lab CA", keys\ca\lab-root-ca.crt) is retired: no
    lab service uses its certificates any more. If Windows still trusts it, -RemoveRetired
    takes that trust back.

    INTERNAL PKI IN THIS LAB
    HTTPS needs a certificate the browser trusts. Public CAs only issue certificates for
    names in public DNS, so internal names such as matrix.lab.internal need an internal
    CA (a private PKI). The lab's PKI has two levels, as in enterprises:
      root CA          on this PC only, its key encrypted (keys\pki, lib\LabPki.ps1). It
                       signs very rarely: the intermediate CA, and the certificates of the two
                       systems that must work before OpenBao (OpenBao's own, the firewall's GUI).
      intermediate CA  inside OpenBao on the vault VM (its key never leaves OpenBao). It issues
                       the everyday certificates: Keycloak's (CSR signing by Ansible) and the
                       Matrix stack's (ACME, renewed automatically by Traefik).
    Trusting the root once is enough for all of them, including those issued later.

    TRUST STORES
    A trust store is the list of root certificates a client accepts as the top of a
    certificate chain. Trusting a root means accepting every certificate it (or a CA below it)
    signs, for the names written in that certificate. Windows keeps one root store per user
    and one for the whole machine. Edge and Chrome trust roots that were added to these Windows
    stores; Firefox has its own (see FIREFOX below).

    WHY PER USER
    Least privilege: the trust applies only to your account, not to other users or to
    Windows services, and adding it needs no administrator rights. -Remove takes it back.
    In an enterprise the root certificate of the internal CA is distributed to the
    machine store of all managed devices by Group Policy or Intune/MDM.

    NAME CONSTRAINTS
    The root certificate carries a critical X.509 Name Constraints extension that permits only
    DNS names under lab.internal and no IP addresses. Clients that enforce it (Windows,
    current browsers, OpenSSL) reject any certificate below this root for another name. So
    even someone who stole a lab CA key could not use it to impersonate a real website. This
    makes trusting a home-made root CA far less risky. It also means every name in a lab
    certificate must be a full name under lab.internal (matrix.lab.internal, not matrix).

    FIREFOX
    Edge and Chrome pick up the root from this certificate store directly. Firefox keeps
    its own trust store and reads roots added to the Windows store only while
    "security.enterprise_roots.enabled" is true in about:config. Recent Firefox versions
    on Windows (120 and later) have this on by default; if it is false on your PC, set it
    to true (managed installations can set the enterprise policy ImportEnterpriseRoots
    instead). Alternatively import keys\pki\root-ca.crt in Firefox itself under
    Settings > Privacy & Security > Certificates > View Certificates > Authorities.

    REVOCATION
    Every lab certificate names where its CA publishes the revocation list (CRL distribution
    point): http://vault.lab.internal/pki/root-ca.crl for the root, OpenBao's CRL for the
    intermediate, served by the vault VM on port 80. So Windows can check revocation, and
    curl.exe (Schannel) works with lab sites without --ssl-no-revoke.

    IDEMPOTENCY
    The certificate is identified by its thumbprint. If it is already trusted, the script
    only says so; -Remove deletes exactly that certificate from your user's root store.

.PARAMETER Remove
    Withdraw the trust again: removes the lab's roots from your user's root store - the ones in
    keys\, and also any other "DeployableServer Lab ..." root whose file is gone (for example
    after keys\ was moved aside for a rebuild from scratch).

.PARAMETER RemoveRetired
    Remove only the retired first lab CA (keys\ca), keep the 2026 root.

.EXAMPLE
    .\lab.ps1 trust
    Trusts the lab root CA for your Windows user (Windows asks for confirmation).

.EXAMPLE
    .\lab.ps1 trust -RemoveRetired
    Stops trusting the retired first lab CA.

.EXAMPLE
    .\lab.ps1 trust -Remove
    Stops trusting the lab's root CAs.
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$RemoveRetired
)

$ErrorActionPreference = 'Stop'

# Only the public CA certificates are needed here. Private keys never go into a trust store.
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$roots = @(
    @{ File = Join-Path $projectRoot 'keys\pki\root-ca.crt'; Retired = $false },
    @{ File = Join-Path $projectRoot 'keys\ca\lab-root-ca.crt'; Retired = $true }
) | Where-Object { Test-Path $_.File }
if (-not $roots -and -not $Remove) {
    throw 'No lab root CA found (keys\pki\root-ca.crt). It is created by the first firewall build (.\lab.ps1 up) or by .\lab.ps1 deploy vault.'
}
$roots = @($roots)

# -Remove also finds lab roots whose files are gone (keys\ moved aside before a rebuild from
# scratch): every root in your store whose subject starts with "CN=DeployableServer Lab".
if ($Remove) {
    $known = @($roots | ForEach-Object { (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $_.File).Thumbprint })
    foreach ($orphan in @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like 'CN=DeployableServer Lab*' -and $known -notcontains $_.Thumbprint })) {
        Remove-Item -Path "Cert:\CurrentUser\Root\$($orphan.Thumbprint)"
        Write-Host "Windows no longer trusts $($orphan.Subject) ($($orphan.Thumbprint)), a lab root without its file in keys\."
    }
}

$imported = $false
foreach ($root in $roots) {
    # The thumbprint (a SHA-1 hash of the whole certificate) identifies it in the store.
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $root.File
    $installed = @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })
    if ($Remove -or ($RemoveRetired -and $root.Retired)) {
        foreach ($entry in $installed) { Remove-Item -Path "Cert:\CurrentUser\Root\$($entry.Thumbprint)" }
        Write-Host "Windows no longer trusts $($cert.Subject) ($($cert.Thumbprint))."
        continue
    }
    if ($RemoveRetired) { continue }
    # The retired CA is never imported (again); it is only listed here so it can be removed.
    if ($root.Retired) {
        if ($installed.Count -gt 0) { Write-Host "Windows still trusts the retired $($cert.Subject). Remove it with:  .\lab.ps1 trust -RemoveRetired" }
        continue
    }
    if ($installed.Count -gt 0) {
        Write-Host "Windows already trusts $($cert.Subject) ($($cert.Thumbprint))."
        continue
    }
    Write-Host "Importing $($cert.Subject), thumbprint $($cert.Thumbprint)."
    Write-Host 'Windows will now show a security warning: please confirm with "Yes".'
    # Adding a certificate to the current user's root store makes Windows show this
    # confirmation dialog; it is Windows' own protection against programs silently adding
    # trusted roots.
    Import-Certificate -FilePath $root.File -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    $imported = $true
}
if ($imported) {
    Write-Host 'Done. Restart your browser once, then open: https://firewall.lab.internal, https://element.lab.internal, https://vault.lab.internal:8200/ui/'
}
