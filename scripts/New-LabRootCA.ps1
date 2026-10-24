<#
.SYNOPSIS
    The lab's offline root certificate authority (CA): creates it once, keeps its revocation
    list current and signs the few certificates only the root signs.

.DESCRIPTION
    Runs on the Windows host, as your own Windows user, with the OpenSSL from Git for Windows.
    Called by Deploy-LabVault.ps1; can also run alone.

    THE PKI OF THE LAB (two levels, as in enterprises)
      Root CA       "DeployableServer Lab Root CA 2026" - this script. Its private key exists
                    only on this PC, encrypted (below). It signs very rarely: the intermediate
                    CA, and the TLS certificates of the two systems that must work before or
                    without OpenBao (OpenBao's own web server, the firewall's web GUI).
      Intermediate  "DeployableServer Lab Intermediate CA 2026" - lives inside OpenBao (key
                    generated there, never exported). It issues the everyday certificates
                    (Matrix via ACME, Keycloak via CSR signing).
    Why two levels: the root is the trust anchor every client imports. If it were online and
    compromised, every client would have to be touched. An intermediate can be revoked and
    replaced by the root without touching the clients. "Offline" here means: not on any server,
    used only for a few signatures.

    The root carries constraints that limit damage even if a key is stolen:
      pathlen:1          at most one intermediate level below it
      nameConstraints    only names under lab.internal, and no IP addresses at all
    Name constraints are checked by Windows, browsers and OpenSSL for every certificate below.

    THE ROOT KEY ON DISK
    keys\pki\root-ca.key is encrypted (PKCS#8, AES-256, 600,000 PBKDF2 iterations). Its
    passphrase is random and stored with DPAPI (keys\pki\root-ca-passphrase.dpapi, see
    LabSecrets.ps1). openssl gets it through an environment variable, never on a command line.

    FILES (keys\pki\, excluded from version control)
      root-ca.key, root-ca.crt    key (encrypted) and certificate (PEM)
      openssl.cnf                 extensions and CRL settings (written by this script)
      crl\                        OpenSSL's CRL database
      pub\root-ca.crt, .crl       public copies (DER) served at http://vault.lab.internal/pki/
      issued\                     certificates signed by the root (public)

    Idempotent: an existing root is never replaced; the CRL is renewed only when it has fewer
    than 60 days left (or with -RenewCrl).

.PARAMETER SignCsr
    Path of a certificate signing request (PEM) to sign with the root.

.PARAMETER Kind
    Intermediate (a CA one level below the root) or Server (a TLS server certificate).

.PARAMETER DnsName
    Server profile: the DNS names (subject alternative names), all under the lab domain.

.PARAMETER OutFile
    Where to write the signed certificate (PEM).

.PARAMETER RenewCrl
    Renew the root's revocation list now.

.EXAMPLE
    .\scripts\New-LabRootCA.ps1
    .\scripts\New-LabRootCA.ps1 -SignCsr vault.csr -Kind Server -DnsName vault.lab.internal -OutFile vault.crt
#>
[CmdletBinding()]
param(
    [string]$SignCsr,
    [ValidateSet('Intermediate', 'Server')]
    [string]$Kind = 'Server',
    [string[]]$DnsName,
    [int]$Days,
    [string]$OutFile,
    [switch]$RenewCrl
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

$openssl = Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe'
$pkiDir = Join-Path $script:LabKeysDir 'pki'
$keyFile = Join-Path $pkiDir 'root-ca.key'
$certFile = Join-Path $pkiDir 'root-ca.crt'
$configFile = Join-Path $pkiDir 'openssl.cnf'
$crlPem = Join-Path $pkiDir 'crl\root-ca.crl.pem'
$domain = $script:LabConfig.domain
# The public URLs of the root certificate and its CRL, baked into every certificate the root
# signs (AIA: where to download the issuer; CDP: where to check revocation). Plain HTTP on
# purpose (RFC 5280): fetching a CRL must not itself depend on TLS.
$pkiBaseUrl = "http://vault.$domain/pki"

if (-not (Test-Path $openssl)) { throw "$openssl is missing. It comes with Git for Windows." }

# openssl as a native program: stderr carries progress messages, only the exit code decides.
function Invoke-OpenSsl {
    $ErrorActionPreference = 'Continue'
    $output = & $openssl @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "openssl $($args[0]) failed (exit code $LASTEXITCODE): $($output -join ' ')" }
    return $output
}

function New-SerialNumber {
    # 128 random bits, as browsers expect from a CA.
    $bytes = New-Object byte[] 16
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes); $rng.Dispose()
    $bytes[0] = $bytes[0] -band 0x7F   # keep the number positive
    return '0x' + (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

# The OpenSSL configuration: the root's own extensions, the intermediate profile and the CRL
# settings. Rewritten on every run, so the repository's version of this script is the truth.
function Write-OpenSslConfig {
    $lines = @(
        '# Written by scripts/New-LabRootCA.ps1 - edit the script, not this file.'
        '[ req ]'
        'distinguished_name = dn'
        'prompt             = no'
        '[ dn ]'
        'CN = DeployableServer Lab Root CA 2026'
        '[ v3_root ]'
        'basicConstraints     = critical,CA:TRUE,pathlen:1'
        'keyUsage             = critical,keyCertSign,cRLSign'
        'subjectKeyIdentifier = hash'
        "nameConstraints      = critical,permitted;DNS:$domain,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:::/::"
        '[ v3_intermediate ]'
        'basicConstraints       = critical,CA:TRUE,pathlen:0'
        'keyUsage               = critical,keyCertSign,cRLSign'
        'subjectKeyIdentifier   = hash'
        'authorityKeyIdentifier = keyid:always'
        "nameConstraints        = critical,permitted;DNS:$domain,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:::/::"
        "crlDistributionPoints  = URI:$pkiBaseUrl/root-ca.crl"
        "authorityInfoAccess    = caIssuers;URI:$pkiBaseUrl/root-ca.crt"
        '[ ca ]'
        'default_ca = root'
        '[ root ]'
        'database         = crl/index.txt'
        'crlnumber        = crl/crlnumber'
        'default_md       = sha384'
        'default_crl_days = 400'
        'crl_extensions   = crl_ext'
        '[ crl_ext ]'
        'authorityKeyIdentifier = keyid:always'
    )
    [IO.File]::WriteAllLines($configFile, [string[]]$lines)
}

# The root's revocation list (CRL), valid 400 days, with no revoked certificates. Windows
# checks the CRL of every CA in a chain; an expired CRL makes those checks fail.
function Update-RootCrl {
    Push-Location $pkiDir
    try {
        Use-LabRootCaPassphrase {
            Invoke-OpenSsl ca -gencrl -config openssl.cnf -cert root-ca.crt -keyfile root-ca.key -passin env:LAB_CA_PASS -out crl/root-ca.crl.pem | Out-Null
        }
        Invoke-OpenSsl crl -in crl/root-ca.crl.pem -outform DER -out pub/root-ca.crl | Out-Null
    }
    finally { Pop-Location }
    Write-Host "Root CA:     revocation list renewed ($pkiBaseUrl/root-ca.crl)"
}

# --- Create the root once ---------------------------------------------------------------------
foreach ($dir in $pkiDir, (Join-Path $pkiDir 'crl'), (Join-Path $pkiDir 'pub'), (Join-Path $pkiDir 'issued')) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
Write-OpenSslConfig

if (-not (Test-Path $certFile)) {
    if (Test-Path $keyFile) { throw "$keyFile exists without $certFile. Check keys\pki by hand; nothing is overwritten." }
    if (-not (Test-LabSecret 'pki/root-ca-passphrase')) {
        Protect-LabSecret 'pki/root-ca-passphrase' (New-LabRandomText 40)
    }
    Push-Location $pkiDir
    try {
        Use-LabRootCaPassphrase {
            # EC P-384: strong and compact. The key is created encrypted and then re-encrypted as
            # PKCS#8 with many PBKDF2 iterations (OpenSSL 1.1's default uses only 2,048).
            Invoke-OpenSsl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -pkeyopt ec_param_enc:named_curve -aes-256-cbc -pass env:LAB_CA_PASS -out root-ca.key.tmp | Out-Null
            Invoke-OpenSsl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA256 -iter 600000 -passin env:LAB_CA_PASS -passout env:LAB_CA_PASS -in root-ca.key.tmp -out root-ca.key | Out-Null
            Remove-Item -Force root-ca.key.tmp
            # Self-signed: the root vouches for itself; clients trust it because you import it.
            Invoke-OpenSsl req -new -x509 -config openssl.cnf -extensions v3_root -key root-ca.key -passin env:LAB_CA_PASS -sha384 -days 3650 -set_serial (New-SerialNumber) -out root-ca.crt | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $pkiDir 'crl\index.txt'), '')
        [IO.File]::WriteAllText((Join-Path $pkiDir 'crl\crlnumber'), "01`n")
        Invoke-OpenSsl x509 -in root-ca.crt -outform DER -out pub/root-ca.crt | Out-Null
    }
    finally {
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $pkiDir 'root-ca.key.tmp')
        Pop-Location
    }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $keyFile /inheritance:r /grant:r "${me}:F" | Out-Null
    Write-Host "Root CA:     created ($certFile). Trust it on Windows once: .\scripts\Install-LabRootCA.ps1"
    Update-RootCrl
}

# --- Keep the CRL current ---------------------------------------------------------------------
$renew = $RenewCrl -or -not (Test-Path $crlPem)
if (-not $renew) {
    $nextUpdate = (Invoke-OpenSsl crl -in $crlPem -noout -nextupdate) -replace '^nextUpdate=', ''
    $expires = [datetime]::ParseExact(($nextUpdate -replace '\s+', ' '), 'MMM d HH:mm:ss yyyy \G\M\T', [Globalization.CultureInfo]::InvariantCulture)
    $renew = $expires -lt (Get-Date).AddDays(60)
}
if ($renew) { Update-RootCrl }

# --- Sign a CSR -------------------------------------------------------------------------------
if ($SignCsr) {
    if (-not $OutFile) { throw '-OutFile is required with -SignCsr.' }
    $csrPath = (Resolve-Path $SignCsr).Path
    $outPath = [IO.Path]::GetFullPath($OutFile)
    if ($Kind -eq 'Intermediate') {
        # OpenSSL 1.1 never copies extensions from the CSR: only the profile below counts, so a
        # CSR cannot sneak in extra names or CA rights.
        if (-not $Days) { $Days = 1095 }
        $extArgs = @('-extfile', $configFile, '-extensions', 'v3_intermediate')
        $digest = '-sha384'
    }
    else {
        if (-not $DnsName) { throw '-DnsName is required for the Server kind.' }
        foreach ($name in $DnsName) {
            if ($name -ne $domain -and -not $name.EndsWith(".$domain")) { throw "$name is outside $domain (the root's name constraint would make it invalid)." }
        }
        if (-not $Days) { $Days = 397 }
        $extFile = Join-Path $pkiDir 'server.ext.tmp'
        [IO.File]::WriteAllLines($extFile, [string[]]@(
            'basicConstraints = critical,CA:FALSE'
            'keyUsage = critical,digitalSignature'
            'extendedKeyUsage = serverAuth'
            'subjectAltName = ' + (($DnsName | ForEach-Object { "DNS:$_" }) -join ',')
            'subjectKeyIdentifier = hash'
            'authorityKeyIdentifier = keyid'
            "crlDistributionPoints = URI:$pkiBaseUrl/root-ca.crl"
            "authorityInfoAccess = caIssuers;URI:$pkiBaseUrl/root-ca.crt"
        ))
        $extArgs = @('-extfile', $extFile)
        $digest = '-sha256'
    }
    try {
        Use-LabRootCaPassphrase {
            Invoke-OpenSsl x509 -req -in $csrPath -CA $certFile -CAkey $keyFile -passin env:LAB_CA_PASS -set_serial (New-SerialNumber) -days $Days $digest @extArgs -out $outPath | Out-Null
        }
    }
    finally { if ($extFile) { Remove-Item -Force -ErrorAction SilentlyContinue $extFile } }
    # Keep a copy of everything the root signed in keys\pki\issued (unless it was written there).
    $archived = Join-Path $pkiDir ("issued\" + [IO.Path]::GetFileName($outPath))
    if ($archived -ne $outPath) { Copy-Item $outPath $archived -Force }
    Write-Host "Root CA:     signed $Kind certificate -> $outPath"
}
