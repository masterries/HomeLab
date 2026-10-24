<#
.SYNOPSIS
    The lab's offline root certificate authority (CA): creates it once, keeps its revocation
    list current and signs the few certificates only the root signs.

.DESCRIPTION
    Not run directly: scripts\lib\Lab.ps1 loads it. Runs on the Windows host, as your own Windows
    user, with the OpenSSL from Git for Windows. "lab.ps1 deploy vault" and "lab.ps1 firewall"
    use it.

    THE PKI OF THE LAB (two levels, as in enterprises)
      Root CA       "DeployableServer Lab Root CA 2026" - here. Its private key exists only on this
                    PC, encrypted (below). It signs very rarely: the intermediate CA, and the TLS
                    certificates of the two systems that must work before or without OpenBao
                    (OpenBao's own web server, the firewall's web GUI at its first boot).
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
      openssl.cnf                 extensions and CRL settings (written here)
      crl\                        OpenSSL's CRL database
      pub\root-ca.crt, .crl       public copies (DER) served at http://vault.lab.internal/pki/
      issued\                     certificates signed by the root (public)
#>

$script:LabPkiOpenSsl = Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe'
$script:LabPkiDir = Join-Path $script:LabKeysDir 'pki'
$script:LabPkiConfig = Join-Path $script:LabPkiDir 'openssl.cnf'
# The public URLs of the root certificate and its CRL, baked into every certificate the root
# signs (AIA: where to download the issuer; CDP: where to check revocation). Plain HTTP on
# purpose (RFC 5280): fetching a CRL must not itself depend on TLS.
$script:LabPkiBaseUrl = "http://vault.$($script:LabConfig.domain)/pki"

# openssl as a native program: stderr carries progress messages, only the exit code decides.
function Invoke-LabPkiOpenSsl {
    if (-not (Test-Path $script:LabPkiOpenSsl)) { throw "$script:LabPkiOpenSsl is missing. It comes with Git for Windows." }
    $ErrorActionPreference = 'Continue'
    $output = & $script:LabPkiOpenSsl @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "openssl $($args[0]) failed (exit code $LASTEXITCODE): $($output -join ' ')" }
    return $output
}

function New-LabPkiSerial {
    # 128 random bits, as browsers expect from a CA.
    $bytes = New-Object byte[] 16
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes); $rng.Dispose()
    $bytes[0] = $bytes[0] -band 0x7F   # keep the number positive
    return '0x' + (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

# The OpenSSL configuration: the root's own extensions, the intermediate profile and the CRL
# settings. Rewritten on every use, so the repository's version of this code is the truth.
# The intermediate profile also EXCLUDES OpenBao's own name: no certificate the intermediate (and
# so OpenBao itself, or anyone who can change its roles) issues can ever be valid for
# vault.<domain>. Together with the PC's TLS pin, which accepts only a vault certificate issued
# directly by the root (LabSecrets.ps1), no one but the root can impersonate OpenBao to the PC.
function Write-LabPkiConfig {
    $domain = $script:LabConfig.domain
    $lines = @(
        '# Written by scripts/lib/LabPki.ps1 - edit the script, not this file.'
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
        "nameConstraints        = critical,permitted;DNS:$domain,excluded;DNS:vault.$domain,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:::/::"
        "crlDistributionPoints  = URI:$($script:LabPkiBaseUrl)/root-ca.crl"
        "authorityInfoAccess    = caIssuers;URI:$($script:LabPkiBaseUrl)/root-ca.crt"
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
    [IO.File]::WriteAllLines($script:LabPkiConfig, [string[]]$lines)
}

# The root's revocation list (CRL), valid 400 days, with no revoked certificates. Windows checks
# the CRL of every CA in a chain; an expired CRL makes those checks fail. Renewed when it has fewer
# than 60 days left, or with -Force. Returns $true when it was renewed (it then needs publishing on
# the vault VM: openbao.yml).
function Update-LabRootCrl([switch]$Force) {
    Write-LabPkiConfig
    $crlPem = Join-Path $script:LabPkiDir 'crl\root-ca.crl.pem'
    $renew = $Force -or -not (Test-Path $crlPem)
    if (-not $renew) {
        $nextUpdate = (Invoke-LabPkiOpenSsl crl -in $crlPem -noout -nextupdate) -replace '^nextUpdate=', ''
        $expires = [datetime]::ParseExact(($nextUpdate -replace '\s+', ' '), 'MMM d HH:mm:ss yyyy \G\M\T', [Globalization.CultureInfo]::InvariantCulture)
        $renew = $expires -lt (Get-Date).AddDays(60)
    }
    if (-not $renew) { return $false }
    Push-Location $script:LabPkiDir
    try {
        Use-LabRootCaPassphrase {
            Invoke-LabPkiOpenSsl ca -gencrl -config openssl.cnf -cert root-ca.crt -keyfile root-ca.key -passin env:LAB_CA_PASS -out crl/root-ca.crl.pem | Out-Null
        }
        Invoke-LabPkiOpenSsl crl -in crl/root-ca.crl.pem -outform DER -out pub/root-ca.crl | Out-Null
    }
    finally { Pop-Location }
    Write-Host "Root CA:     revocation list renewed ($($script:LabPkiBaseUrl)/root-ca.crl)"
    return $true
}

# Creates the root once (an existing root is never replaced) and keeps its CRL current.
function Initialize-LabRootCa {
    foreach ($dir in $script:LabPkiDir, (Join-Path $script:LabPkiDir 'crl'), (Join-Path $script:LabPkiDir 'pub'), (Join-Path $script:LabPkiDir 'issued')) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Write-LabPkiConfig
    $keyFile = Join-Path $script:LabPkiDir 'root-ca.key'
    if (-not (Test-Path $script:LabRootCaCert)) {
        if (Test-Path $keyFile) { throw "$keyFile exists without $script:LabRootCaCert. Check keys\pki by hand; nothing is overwritten." }
        if (-not (Test-LabSecret 'pki/root-ca-passphrase')) {
            Protect-LabSecret 'pki/root-ca-passphrase' (New-LabRandomText 40)
        }
        Push-Location $script:LabPkiDir
        try {
            Use-LabRootCaPassphrase {
                # EC P-384: strong and compact. The key is created encrypted and then re-encrypted as
                # PKCS#8 with many PBKDF2 iterations (OpenSSL 1.1's default uses only 2,048).
                Invoke-LabPkiOpenSsl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -pkeyopt ec_param_enc:named_curve -aes-256-cbc -pass env:LAB_CA_PASS -out root-ca.key.tmp | Out-Null
                Invoke-LabPkiOpenSsl pkcs8 -topk8 -v2 aes-256-cbc -v2prf hmacWithSHA256 -iter 600000 -passin env:LAB_CA_PASS -passout env:LAB_CA_PASS -in root-ca.key.tmp -out root-ca.key | Out-Null
                Remove-Item -Force root-ca.key.tmp
                # Self-signed: the root vouches for itself; clients trust it because you import it.
                Invoke-LabPkiOpenSsl req -new -x509 -config openssl.cnf -extensions v3_root -key root-ca.key -passin env:LAB_CA_PASS -sha384 -days 3650 -set_serial (New-LabPkiSerial) -out root-ca.crt | Out-Null
            }
            [IO.File]::WriteAllText((Join-Path $script:LabPkiDir 'crl\index.txt'), '')
            [IO.File]::WriteAllText((Join-Path $script:LabPkiDir 'crl\crlnumber'), "01`n")
            Invoke-LabPkiOpenSsl x509 -in root-ca.crt -outform DER -out pub/root-ca.crt | Out-Null
        }
        finally {
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:LabPkiDir 'root-ca.key.tmp')
            Pop-Location
        }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $keyFile /inheritance:r /grant:r "${me}:F" | Out-Null
        Write-Host "Root CA:     created ($script:LabRootCaCert). Trust it on Windows once, in your own window: .\lab.ps1 trust"
    }
    [void](Update-LabRootCrl)
}

# Signs a certificate signing request (PEM) with the root and writes the certificate (PEM) to
# $OutFile; a copy goes to keys\pki\issued.
#   -Kind Intermediate   a CA one level below the root (3 years by default)
#   -Kind Server         a TLS server certificate for $DnsName, all under the lab domain (397 days)
# OpenSSL 1.1 never copies extensions from the CSR: only the profile here counts, so a CSR cannot
# sneak in extra names or CA rights.
function Invoke-LabRootCaSign([string]$Csr, [ValidateSet('Intermediate', 'Server')][string]$Kind, [string[]]$DnsName, [int]$Days, [string]$OutFile) {
    if (-not $OutFile) { throw 'Invoke-LabRootCaSign: -OutFile is required.' }
    Write-LabPkiConfig
    $domain = $script:LabConfig.domain
    $csrPath = (Resolve-Path $Csr).Path
    $outPath = [IO.Path]::GetFullPath($OutFile)
    $keyFile = Join-Path $script:LabPkiDir 'root-ca.key'
    $extFile = $null
    if ($Kind -eq 'Intermediate') {
        if (-not $Days) { $Days = 1095 }
        $extArgs = @('-extfile', $script:LabPkiConfig, '-extensions', 'v3_intermediate')
        $digest = '-sha384'
    }
    else {
        if (-not $DnsName) { throw '-DnsName is required for the Server kind.' }
        foreach ($name in $DnsName) {
            if ($name -ne $domain -and -not $name.EndsWith(".$domain")) { throw "$name is outside $domain (the root's name constraint would make it invalid)." }
        }
        if (-not $Days) { $Days = 397 }
        $extFile = Join-Path $script:LabPkiDir 'server.ext.tmp'
        [IO.File]::WriteAllLines($extFile, [string[]]@(
            'basicConstraints = critical,CA:FALSE'
            'keyUsage = critical,digitalSignature'
            'extendedKeyUsage = serverAuth'
            'subjectAltName = ' + (($DnsName | ForEach-Object { "DNS:$_" }) -join ',')
            'subjectKeyIdentifier = hash'
            'authorityKeyIdentifier = keyid'
            "crlDistributionPoints = URI:$($script:LabPkiBaseUrl)/root-ca.crl"
            "authorityInfoAccess = caIssuers;URI:$($script:LabPkiBaseUrl)/root-ca.crt"
        ))
        $extArgs = @('-extfile', $extFile)
        $digest = '-sha256'
    }
    try {
        Use-LabRootCaPassphrase {
            Invoke-LabPkiOpenSsl x509 -req -in $csrPath -CA $script:LabRootCaCert -CAkey $keyFile -passin env:LAB_CA_PASS -set_serial (New-LabPkiSerial) -days $Days $digest @extArgs -out $outPath | Out-Null
        }
    }
    finally { if ($extFile) { Remove-Item -Force -ErrorAction SilentlyContinue $extFile } }
    # Keep a copy of everything the root signed in keys\pki\issued (unless it was written there).
    $archived = Join-Path $script:LabPkiDir ("issued\" + [IO.Path]::GetFileName($outPath))
    if ($archived -ne $outPath) { Copy-Item $outPath $archived -Force }
    Write-Host "Root CA:     signed $Kind certificate -> $outPath"
}
