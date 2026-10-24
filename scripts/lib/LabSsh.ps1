<#
.SYNOPSIS
    SSH certificates for the lab: two SSH certificate authorities, short-lived user certificates
    for the PC and for ansible-control, host certificates for every machine, and the files that
    tell each machine which CAs to trust.

.DESCRIPTION
    Not run directly: LabSecrets.ps1 loads it at its end, so every script that loads
    LabSecrets.ps1 has these functions.

    WHY CERTIFICATES INSTEAD OF A KEY IN authorized_keys
    Plain SSH keys are trusted one by one: every server lists the public keys that may log in
    (authorized_keys), and every client lists the host keys it believes (known_hosts, usually
    learned on first contact - "trust on first use"). Such a key never expires, and whoever holds
    a copy can use it until someone finds and removes it everywhere. An SSH CERTIFICATE is a
    public key signed by a certificate authority (CA), together with
    - a validity period (here: 8 hours for the PC, 2 hours per Ansible run, 1 year for hosts),
    - principals: for whom it is valid (role names such as "lab-all" or "host-matrix" for user
      certificates, the host's DNS name for host certificates),
    - a key ID and serial number that every server writes into its log,
    - critical options and extensions, e.g. "source-address" (usable only from these IPs) and
      "permit-port-forwarding" (allowed to use the jump host).
    Servers then trust the CA instead of individual keys (TrustedUserCAKeys, or a
    "cert-authority" line in authorized_keys), and clients trust the CA for host keys
    ("@cert-authority" in known_hosts). A rebuilt VM with new host keys gets a new certificate
    and is trusted at once - no "REMOTE HOST IDENTIFICATION HAS CHANGED", no blind "yes".

    THE TWO CAs
      offline CA   An ed25519 key on this PC (keys\ssh\offline-ca), encrypted with a passphrase
                   that is stored with DPAPI (ssh/offline-ca-passphrase). It signs while OpenBao
                   does not exist yet (bootstrap) and when OpenBao is broken (break-glass, only
                   on request: .\lab.ps1 breakglass <command>). Every machine trusts it permanently, so a firewall
                   rebuild is always a way back in. Both are in the recovery file.
      OpenBao CA   The SSH secrets engine "ssh" in OpenBao (lab.ps1 deploy vault). Its key is
                   generated inside OpenBao and never leaves it. It signs everyday certificates,
                   each recorded in OpenBao's audit log. It is used only after
                   lab.ps1 deploy vault has pushed its public key to every machine and logged in
                   with a test certificate (keys\ssh\openbao-ca.trusted).
    Enterprise equivalent: the same split exists everywhere - an offline or HSM-held root of
    trust plus an online issuer (HashiCorp Vault/OpenBao SSH engine, Smallstep, Teleport, AWS
    EC2 Instance Connect), with people getting certificates after an SSO login.

    FIRST CONTACT: HOW THE PC LEARNS A HOST KEY BEFORE IT SIGNS IT
    A host certificate is only as good as the check of the key it certifies. The PC never takes
    a host key from the network unverified:
      firewall    OPNsense prints its host key fingerprints on the serial console when it boots;
                  lab.ps1 firewall reads that console (a Hyper-V named pipe on this PC) and
                  compares it with the key the firewall then presents.
      Ubuntu VMs  provision\harden-ssh.sh publishes the VM's host key through Hyper-V KVP
                  (key-value pairs exchanged over VMBus, the VM's private channel to its host);
                  the PC reads it from Hyper-V (Get-LabKvpHostKey). No other VM can write there.
    The PC keeps the verified keys in keys\ssh\hosts\ and installs each certificate over a
    connection that is pinned to exactly that key.

    No function here prints a secret.
#>

$script:LabSshDir = Join-Path $script:LabKeysDir 'ssh'
$script:LabSshConfigFile = Join-Path $script:LabKeysDir 'ssh_config'
# Windows' own OpenSSH client (8.1 on Windows 10). Pinned by path: Git for Windows and Vagrant
# bring their own ssh-keygen/ssh, and the lab is tested with this one.
$script:LabSshBin = Join-Path $env:SystemRoot 'System32\OpenSSH'
$script:LabSshKeygen = Join-Path $script:LabSshBin 'ssh-keygen.exe'
$script:LabSshKeyscan = Join-Path $script:LabSshBin 'ssh-keyscan.exe'
$script:LabSshOfflineCa = Join-Path $script:LabSshDir 'offline-ca'
$script:LabSshPcKey = Join-Path $script:LabSshDir 'pc_ed25519'
$script:LabSshPcCertInfo = Join-Path $script:LabSshDir 'pc_ed25519-cert.valid-until'
$script:LabSshOpenBaoCa = Join-Path $script:LabSshDir 'openbao-ca.pub'
$script:LabSshOpenBaoTrusted = Join-Path $script:LabSshDir 'openbao-ca.trusted'
$script:LabSshUserCaFile = Join-Path $script:LabSshDir 'lab_user_ca.pub'
$script:LabSshKnownHosts = Join-Path $script:LabSshDir 'known_hosts'
$script:LabSshFirewallKeys = Join-Path $script:LabSshDir 'firewall_authorized_keys'
$script:LabSshKrl = Join-Path $script:LabSshDir 'revoked_host_keys'
$script:LabSshHostsDir = Join-Path $script:LabSshDir 'hosts'
$script:LabSshIssuedLog = Join-Path $script:LabSshDir 'issued.log'
# The fingerprint of the offline SSH CA that the recovery file holds (lab.ps1 recovery).
$script:LabSshCaInKit = Join-Path $script:LabSshDir 'offline-ca.in-recovery-kit'
# The OpenBao mount of the SSH secrets engine (lab.ps1 deploy vault).
$script:LabSshMount = 'ssh'
# Hours a certificate must still be valid; below that it is renewed. Longer than any single
# script or "vagrant up", so no certificate expires in the middle of a run.
$script:LabSshPcRenewHours = 4
$script:LabSshHostRenewDays = 30

# The certificate types the lab issues ("roles", as in OpenBao). lab.ps1 deploy vault creates the
# OpenBao roles of the same names from this table, so both signers issue the same certificates.
#   Type          user (log in as someone) or host (prove a server's identity)
#   Hours         validity
#   Extensions    what a user certificate allows besides the login itself. permit-port-forwarding
#                 is needed for the jump host (ProxyJump and Vagrant's "ssh -W" open forwarding
#                 channels on the firewall); everything else (agent and X11 forwarding, ~/.ssh/rc)
#                 stays off.
#   SourceAddress critical option: the certificate works only from these addresses. The PC
#                 reaches the firewall from its LabHost address and every VM from the firewall's
#                 LAN address (the jump); ansible-control only from its own. A copied certificate
#                 is useless anywhere else.
$script:LabSshRoles = [ordered]@{
    'pc' = @{ Type = 'user'; Hours = 8; Extensions = @('permit-port-forwarding', 'permit-pty')
        SourceAddress = "$($script:LabConfig.firewall.pcIp)/32,$($script:LabConfig.firewall.lanIp)/32" }
    'ansible-control' = @{ Type = 'user'; Hours = 2; Extensions = @('permit-pty')
        SourceAddress = "$(($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip)/32" }
    'lab-hosts' = @{ Type = 'host'; Hours = 8760; Extensions = @(); SourceAddress = $null }
}

# --- Names --------------------------------------------------------------------------------------

# Every machine with an SSH server: the firewall and the VMs of config\lab.json.
function Get-LabSshMachines {
    return @('firewall') + @($script:LabConfig.vms | ForEach-Object { $_.name })
}

function Get-LabSshFqdn([string]$Name) { return "$Name.$($script:LabConfig.domain)" }

# User principals are ROLES, not user names: every machine accepts "lab-all" and
# "host-<its own name>" for the account ansible (AuthorizedPrincipalsFile on the VMs, the
# principals= option on the firewall). The PC gets lab-all; an Ansible run only the hosts it
# configures (lab.ps1 run), so during a Matrix deployment its SSH certificate does not
# open vault or the firewall. LIMIT: every run uses the same account and key on ansible-control
# (with sudo there). Code that runs during one run and plants something on ansible-control could
# pick up the certificate of a LATER run (ping.yml gets lab-all). The scoping protects against
# mistakes and short-lived misuse, not against a persistent compromise of ansible-control; that
# would need one account per automation (e.g. MDAD without sudo, with its own key).
function Get-LabSshUserPrincipals {
    return @('lab-all') + @(Get-LabSshMachines | ForEach-Object { "host-$_" })
}

# --- Small helpers ------------------------------------------------------------------------------

# The SHA256 fingerprint of a public key line ("ssh-ed25519 AAAA... comment"), as ssh-keygen -l
# prints it: base64 of SHA-256 over the decoded key blob, without "=" padding.
function Get-LabSshFingerprint([string]$PublicKeyLine) {
    $parts = "$PublicKeyLine".Trim() -split '\s+'
    if ($parts.Count -lt 2) { throw "Not an OpenSSH public key: '$PublicKeyLine'" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Convert]::FromBase64String($parts[1])) }
    finally { $sha.Dispose() }
    return 'SHA256:' + [Convert]::ToBase64String($hash).TrimEnd('=')
}

# Writes a text file with LF line endings and without a BOM (OpenSSH on every platform reads
# that), only when the content differs. Returns $true when the file changed.
function Write-LabSshFile([string]$Path, [string[]]$Lines) {
    $text = (@($Lines | ForEach-Object { "$_".TrimEnd("`r") }) -join "`n").TrimEnd("`n") + "`n"
    if ((Test-Path $Path) -and [IO.File]::ReadAllText($Path) -ceq $text) { return $false }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false))
    return $true
}

# A fresh folder under keys\ssh\tmp for one signing or test. Only public material goes there.
function New-LabSshTempDir {
    $dir = Join-Path $script:LabSshDir "tmp\$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# OpenSSH options take paths with forward slashes. Paths with spaces would need quotes inside
# an argument, which Windows PowerShell 5.1 does not pass to native programs correctly.
function ConvertTo-LabSshPath([string]$Path) {
    if ($Path -match '\s') { throw "Paths for ssh options must not contain spaces: $Path" }
    return $Path -replace '\\', '/'
}

# Runs one command over SSH (keys\ssh_config, plus $Options) and returns its output lines; throws
# on a non-zero exit code unless -AllowFailure. No double quotes in $Command (Windows
# PowerShell 5.1).
function Invoke-LabSsh([string]$Machine, [string]$Command, [string[]]$Options = @(), [switch]$AllowFailure, [string]$ConfigFile) {
    if (-not $ConfigFile) { $ConfigFile = Get-LabSshConfig }
    $ErrorActionPreference = 'Continue'
    $output = & ssh -F $ConfigFile -o LogLevel=ERROR -o ConnectTimeout=15 @Options $Machine "{ $Command; } 2>&1"
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "SSH to $Machine failed (exit code $LASTEXITCODE): $(($output | Select-Object -Last 3) -join ' / ')"
    }
    return $output
}

function Copy-LabSshFile([string[]]$Source, [string]$Destination, [string[]]$Options = @(), [string]$ConfigFile) {
    if (-not $ConfigFile) { $ConfigFile = Get-LabSshConfig }
    $ErrorActionPreference = 'Continue'
    $output = & scp -q -F $ConfigFile -o LogLevel=ERROR @Options @Source $Destination 2>&1
    if ($LASTEXITCODE -ne 0) { throw "scp to $Destination failed (exit code $LASTEXITCODE): $($output -join ' ')" }
}

# The Hyper-V VM behind a lab VM: by the ID Vagrant stored (unambiguous), else by name.
function Get-LabSshHyperVVm([string]$Name) {
    $idFile = Join-Path $script:LabProjectRoot "vagrant\.vagrant\machines\$Name\hyperv\id"
    if (Test-Path $idFile) { return Get-VM -Id ((Get-Content -Raw $idFile).Trim()) -ErrorAction SilentlyContinue }
    return Get-VM -Name $Name -ErrorAction SilentlyContinue
}

# One signing or certificate check at a time: two scripts (or a script and Vagrant's guard)
# renewing the PC's certificate at once would write over each other's files. A lock file opened
# without sharing works across all PowerShell windows, elevated or not.
function Use-LabSshLock([scriptblock]$Action) {
    New-Item -ItemType Directory -Force -Path $script:LabSshDir | Out-Null
    $lockFile = Join-Path $script:LabSshDir '.lock'
    $deadline = (Get-Date).AddSeconds(120)
    while ($true) {
        try { $lock = [IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None'); break }
        catch [IO.IOException] {
            if ((Get-Date) -gt $deadline) { throw "keys\ssh\.lock is held by another script for more than 2 minutes." }
            Start-Sleep -Milliseconds 500
        }
    }
    try { & $Action }
    finally { $lock.Dispose() }
}

# --- Certificates: reading and checking ---------------------------------------------------------

# Parses "ssh-keygen -L" (the human-readable dump of a certificate) into an object. ssh-keygen
# prints times in the local time zone, which is ambiguous for an hour every autumn and shifts by
# an hour across a daylight saving change; with TZ=UTC0 it prints UTC instead, and every time
# here is UTC (DateTimeKind Utc; .ToLocalTime() only for display).
function Read-LabSshCertificate([string]$Path) {
    $ErrorActionPreference = 'Continue'
    $previousTz = $env:TZ
    $env:TZ = 'UTC0'
    try { $lines = @(& $script:LabSshKeygen -L -f $Path 2>&1 | ForEach-Object { "$_".TrimEnd() }) }
    finally { $env:TZ = $previousTz }
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen -L failed for $Path`: $($lines -join ' ')" }
    $cert = [pscustomobject]@{ Type = $null; KeyFingerprint = $null; CaFingerprint = $null; KeyId = $null; Serial = $null
        ValidFrom = $null; ValidTo = $null; Principals = @(); CriticalOptions = @(); Extensions = @() }
    $section = $null
    $parseTime = { param($Text) if ($Text -eq 'forever') { return [datetime]::MaxValue }
        [datetime]::ParseExact($Text, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, 'AssumeUniversal, AdjustToUniversal') }
    foreach ($line in $lines) {
        if ($line -match '^\s+Type: \S+ (user|host) certificate$') { $cert.Type = $Matches[1]; $section = $null }
        elseif ($line -match '^\s+Public key: \S+ (SHA256:\S+)') { $cert.KeyFingerprint = $Matches[1]; $section = $null }
        elseif ($line -match '^\s+Signing CA: \S+ (SHA256:\S+)') { $cert.CaFingerprint = $Matches[1]; $section = $null }
        elseif ($line -match '^\s+Key ID: "(.*)"$') { $cert.KeyId = $Matches[1]; $section = $null }
        elseif ($line -match '^\s+Serial: (\d+)$') { $cert.Serial = [UInt64]$Matches[1]; $section = $null }
        elseif ($line -match '^\s+Valid: from (\S+) to (\S+)$') { $cert.ValidFrom = & $parseTime $Matches[1]; $cert.ValidTo = & $parseTime $Matches[2]; $section = $null }
        elseif ($line -match '^\s+Valid: forever$') { $cert.ValidFrom = [datetime]::MinValue; $cert.ValidTo = [datetime]::MaxValue; $section = $null }
        elseif ($line -match '^\s+(Principals|Critical Options|Extensions): ?(.*)$') {
            $section = @{ 'Principals' = 'Principals'; 'Critical Options' = 'CriticalOptions'; 'Extensions' = 'Extensions' }[$Matches[1]]
            if ($Matches[2] -eq '(none)') { $section = $null }
        }
        elseif ($section -and $line -match '^\s{9,}(\S.*)$') { $cert.$section = @($cert.$section) + $Matches[1] }
    }
    if (-not $cert.Type -or -not $cert.CaFingerprint) { throw "$Path is not an SSH certificate." }
    return $cert
}

# The CAs every machine trusts right now, as public key lines: the offline CA, and OpenBao's once
# lab.ps1 deploy vault has cached its public key. Comments name them in the rendered files.
function Get-LabSshCaKeys {
    if (-not (Test-Path "$($script:LabSshOfflineCa).pub")) { throw 'The offline SSH CA is missing (keys\ssh\offline-ca.pub). Run .\lab.ps1 up (step 2 creates it).' }
    $keys = @(([IO.File]::ReadAllText("$($script:LabSshOfflineCa).pub").Trim() -split '\s+')[0..1] -join ' ')
    $keys[0] += ' lab-offline-ssh-ca'
    if (Test-Path $script:LabSshOpenBaoCa) {
        $keys += ((([IO.File]::ReadAllText($script:LabSshOpenBaoCa).Trim() -split '\s+')[0..1]) -join ' ') + ' openbao-ssh-ca'
    }
    return $keys
}

function Get-LabSshTrustedCaFingerprints { return @(Get-LabSshCaKeys | ForEach-Object { Get-LabSshFingerprint $_ }) }

function Get-LabSshOfflineCaFingerprint { return Get-LabSshFingerprint ([IO.File]::ReadAllText("$($script:LabSshOfflineCa).pub")) }

# Whether the newest recovery file holds the current offline SSH CA. Only meaningful once a
# recovery kit exists (keys\openbao\unseal-c.sha256).
function Test-LabSshCaInRecoveryKit {
    if (-not (Test-Path $script:LabSshCaInKit) -or -not (Test-Path "$($script:LabSshOfflineCa).pub")) { return $false }
    return ([IO.File]::ReadAllText($script:LabSshCaInKit).Trim() -eq (Get-LabSshOfflineCaFingerprint))
}

# OpenBao signs only once its CA is known everywhere: openbao-ca.trusted holds the fingerprint
# that lab.ps1 deploy vault verified with a test login on every machine.
function Test-LabSshOpenBaoTrusted {
    if (-not (Test-Path $script:LabSshOpenBaoCa) -or -not (Test-Path $script:LabSshOpenBaoTrusted)) { return $false }
    return ([IO.File]::ReadAllText($script:LabSshOpenBaoTrusted).Trim() -eq (Get-LabSshFingerprint ([IO.File]::ReadAllText($script:LabSshOpenBaoCa))))
}

# Principals are checked BEFORE anything is signed. An empty list is the dangerous case: OpenSSH
# accepts a HOST certificate without principals for every host name, and Windows PowerShell 5.1
# silently drops an empty argument, so "-n ''" would make ssh-keygen take the next argument.
# Wildcards ("*.lab.internal") are refused for the same reason.
function Assert-LabSshPrincipals([string]$Role, [string[]]$Principals) {
    $spec = $script:LabSshRoles[$Role]
    if (-not $spec) { throw "Unknown SSH certificate role '$Role'." }
    if (-not $Principals -or $Principals.Count -eq 0) { throw "No principals for an SSH certificate ($Role)." }
    $allowed = if ($spec.Type -eq 'host') { @(Get-LabSshMachines | ForEach-Object { Get-LabSshFqdn $_ }) } else { Get-LabSshUserPrincipals }
    foreach ($p in $Principals) {
        if ($p -notmatch '^[a-z0-9][a-z0-9.-]*$') { throw "Principal '$p' is not allowed (letters, digits, dots and hyphens only; no wildcards)." }
        if ($allowed -notcontains $p) { throw "Principal '$p' is not allowed for $Role (allowed: $($allowed -join ', '))." }
    }
    if ($spec.Type -eq 'host' -and $Principals.Count -ne 1) { throw 'A host certificate names exactly one host.' }
    if ($Role -eq 'pc' -and (@($Principals) -join ',') -ne 'lab-all') { throw 'The PC certificate is for the principal lab-all.' }
}

# Checks a freshly signed certificate against what was asked for, whichever CA signed it, and
# throws if anything differs (the certificate is deleted first).
function Assert-LabSshCertificate([string]$Path, $Expected) {
    $cert = Read-LabSshCertificate $Path
    $now = [datetime]::UtcNow
    $problems = @()
    if ($cert.Type -ne $Expected.Type) { $problems += "type $($cert.Type) instead of $($Expected.Type)" }
    if ($cert.KeyFingerprint -ne $Expected.KeyFingerprint) { $problems += 'it certifies another key' }
    if ($cert.CaFingerprint -ne $Expected.CaFingerprint) { $problems += "signed by $($cert.CaFingerprint) instead of $($Expected.CaFingerprint)" }
    if ((@($cert.Principals | Sort-Object) -join ',') -ne (@($Expected.Principals | Sort-Object) -join ',')) { $problems += "principals $($cert.Principals -join ',')" }
    if (-not $cert.Serial) { $problems += 'serial 0' }
    if ($cert.ValidFrom -gt $now.AddMinutes(1)) { $problems += "not valid before $($cert.ValidFrom)" }
    if ($cert.ValidTo -gt $now.AddHours($Expected.Hours).AddMinutes(10) -or $cert.ValidTo -lt $now.AddHours($Expected.Hours * 0.9)) { $problems += "valid until $($cert.ValidTo)" }
    $options = @(); if ($Expected.SourceAddress) { $options = @("source-address $($Expected.SourceAddress)") }
    if ((@($cert.CriticalOptions) -join '|') -ne ($options -join '|')) { $problems += "critical options '$($cert.CriticalOptions -join ', ')'" }
    if ((@($cert.Extensions | Sort-Object) -join ',') -ne (@($Expected.Extensions | Sort-Object) -join ',')) { $problems += "extensions '$($cert.Extensions -join ', ')'" }
    if ($problems.Count -gt 0) {
        Remove-Item -Force -ErrorAction SilentlyContinue $Path
        throw "The new SSH certificate was rejected: $($problems -join '; ')."
    }
    return $cert
}

# --- Signing ------------------------------------------------------------------------------------

# Which CA signs now. OpenBao, once it is trusted everywhere; the offline CA only
#   - during the bootstrap (OpenBao not deployed yet, or its CA not yet pushed and verified),
#   - when OpenBao's TLS certificate is genuine (issued under the lab root, right name) but has
#     expired: renewing it needs SSH to the vault VM, so this must not depend on OpenBao itself,
#   - on request: .\lab.ps1 breakglass <command> (it sets $env:LAB_SSH_BREAKGLASS = '1'), or the
#     -BreakGlass switch of the functions below.
# Everything else (OpenBao stopped, sealed and not unsealable, a TLS certificate that does not
# chain to the lab root) throws: an attacker who blocks or impersonates OpenBao must not be
# able to push the lab into unaudited offline signing.
function Get-LabSshSigner([switch]$BreakGlass) {
    $offline = @{ Kind = 'offline'; Reason = ''; CaFingerprint = (Get-LabSshOfflineCaFingerprint) }
    if (-not (Test-LabSshOpenBaoTrusted)) { $offline.Reason = 'bootstrap'; return $offline }
    $vaultUri = [Uri]$script:LabVaultUrl
    try {
        $published = $script:LabConfig.published | Where-Object { $_.vm -eq 'vault' }
        $tcp = New-Object Net.Sockets.TcpClient
        try { $reachable = $tcp.ConnectAsync($published.address, $vaultUri.Port).Wait(3000) -and $tcp.Connected } catch { $reachable = $false } finally { $tcp.Close() }
        if (-not $reachable) { throw "OpenBao ($($published.address):$($vaultUri.Port)) does not answer: is the vault VM running?" }
        $health = Get-LabVaultHealth
        if (-not $health) {
            $served = Get-LabServedCertificate $vaultUri.Host $vaultUri.Port
            if ($served -and $served.NotAfter -lt (Get-Date) -and (Test-LabSshGenuineVaultCertificate $served)) {
                Write-Warning "OpenBao's TLS certificate expired on $($served.NotAfter.ToString('yyyy-MM-dd')): the offline SSH CA signs until lab.ps1 deploy vault has renewed it."
                $offline.Reason = 'OpenBao TLS certificate expired'
                return $offline
            }
            throw "OpenBao answers, but not with a TLS certificate under the lab root for $($vaultUri.Host)"
        }
        if ($health.sealed) { Unlock-LabVault -TimeoutSeconds 30 }
        # The CA OpenBao serves must be the one every machine trusts. After a snapshot restore it
        # can be another one; its certificates would be refused everywhere.
        $trusted = Get-LabSshFingerprint ([IO.File]::ReadAllText($script:LabSshOpenBaoCa))
        $served = "$(Invoke-LabBao GET "$($script:LabSshMount)/public_key")".Trim()
        if ($served -notmatch '^ssh-ed25519 ' -or (Get-LabSshFingerprint $served) -ne $trusted) {
            throw "OpenBao serves another SSH CA than the one the machines trust (keys\ssh\openbao-ca.pub; restored from another snapshot?). Move keys\ssh\openbao-ca.pub and openbao-ca.trusted aside, then run .\lab.ps1 up and .\lab.ps1 deploy vault"
        }
        return @{ Kind = 'openbao'; Reason = ''; CaFingerprint = $trusted }
    }
    catch { return Resolve-LabSshSignerFailure $_.Exception.Message -BreakGlass:$BreakGlass }
}

# What happens when OpenBao cannot sign: with -BreakGlass (or $env:LAB_SSH_BREAKGLASS = '1') the
# offline CA signs, with a warning; otherwise the reason is thrown, with the ways out.
function Resolve-LabSshSignerFailure([string]$Why, [switch]$BreakGlass) {
    if ($BreakGlass -or $env:LAB_SSH_BREAKGLASS -eq '1') {
        Write-Warning "Break-glass: the offline SSH CA signs ($Why)."
        return @{ Kind = 'offline'; Reason = 'break-glass'; CaFingerprint = (Get-LabSshOfflineCaFingerprint) }
    }
    throw "$Why. Start and unseal OpenBao with .\lab.ps1 up, or let the offline CA sign (break-glass): .\lab.ps1 breakglass ssh-cert -Force (this PC's certificate), .\lab.ps1 breakglass up or .\lab.ps1 breakglass firewall (host certificates too)"
}

# An expired certificate served for vault: genuine if it chains to the lab root and names vault.
function Test-LabSshGenuineVaultCertificate($Certificate) {
    $root = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $script:LabRootCaCert
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority, IgnoreNotTimeValid'
    [void]$chain.ChainPolicy.ExtraStore.Add($root)
    $chained = $chain.Build($Certificate) -and $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint -eq $root.Thumbprint
    return ($chained -and $Certificate.GetNameInfo('DnsName', $false) -eq ([Uri]$script:LabVaultUrl).Host)
}

# Runs ssh-keygen with the offline CA. The CA key file is encrypted; ssh-keygen gets its
# passphrase with -P, the only unattended way in OpenSSH 8.1 (it reads passphrases from the
# console, not from stdin). That is a deliberate exception to the lab rule "no secrets on command
# lines": the process is started through .NET, so PowerShell's own logging never sees the value;
# other programs running as you (or as an administrator) could read it while ssh-keygen runs -
# they could decrypt the DPAPI value anyway - and it is useless without the encrypted key file.
# Initialize-LabSshCa (lib\LabSsh.ps1) warns if Windows is set to log command lines of new processes.
function Invoke-LabSshOfflineCa([string[]]$Arguments) {
    foreach ($a in $Arguments) { if ($a -match '"') { throw 'ssh-keygen arguments must not contain double quotes.' } }
    $pass = Unprotect-LabSecret 'ssh/offline-ca-passphrase'
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
    # Set as properties, not as arguments of New-Object: PowerShell's module logging (event 4103,
    # if a policy switches it on) records cmdlet parameters, but not property assignments.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:LabSshKeygen
    $psi.Arguments = "-s `"$($script:LabSshOfflineCa)`" -P $pass " + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($psi)
    $psi = $null; $pass = $null
    $process.StandardInput.Close()
    $out = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "ssh-keygen with the offline SSH CA failed (exit code $($process.ExitCode)): $($err.Trim()) $($out.Trim())" }
}

# A random serial number (non-zero, 63 bits): every certificate can be told apart in the logs
# and revoked by serial. ssh-keygen would use 0 for all of them.
function New-LabSshSerial {
    $bytes = New-Object byte[] 8
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    try { do { $rng.GetBytes($bytes); $serial = [BitConverter]::ToUInt64($bytes, 0) -band [UInt64]::Parse('9223372036854775807') } while ($serial -eq 0) }
    finally { $rng.Dispose() }
    return $serial
}

# Signs one public key file and returns the checked certificate (object with Path, Signer,
# KeyId, Serial, ValidTo, CaFingerprint). The certificate is written next to the key as
# <name>-cert.pub, the place where ssh looks for it.
#   $Role        pc, ansible-control or lab-hosts ($script:LabSshRoles)
#   $Principals  user roles (lab-all, host-<name>) or the host's full DNS name
#   $Purpose     what the certificate is for, part of the offline key ID (pc, run, matrix, ...)
#   -Offline     sign with the offline CA whatever Get-LabSshSigner would choose (the tests use it
#                to prove that every machine still accepts the break-glass CA)
function New-LabSshCertificate([string]$PublicKeyFile, [string]$Role, [string[]]$Principals, [string]$Purpose, [switch]$BreakGlass, [double]$Hours, [switch]$Offline) {
    Assert-LabSshPrincipals $Role $Principals
    $spec = $script:LabSshRoles[$Role]
    if (-not $Hours) { $Hours = $spec.Hours }
    $keyLine = [IO.File]::ReadAllText($PublicKeyFile).Trim()
    if ($keyLine -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+=* ?') { throw "$PublicKeyFile is not an ed25519 public key." }
    $certFile = $PublicKeyFile -replace '\.pub$', '-cert.pub'
    Remove-Item -Force -ErrorAction SilentlyContinue $certFile
    if ($Offline) { $signer = @{ Kind = 'offline'; Reason = 'requested'; CaFingerprint = (Get-LabSshOfflineCaFingerprint) } }
    else { $signer = Get-LabSshSigner -BreakGlass:$BreakGlass }
    $expected = @{ Type = $spec.Type; KeyFingerprint = (Get-LabSshFingerprint $keyLine); Principals = $Principals; Hours = $Hours
        SourceAddress = $spec.SourceAddress; Extensions = $spec.Extensions }
    if ($signer.Kind -eq 'openbao') {
        # OpenBao can answer its health check and still fail to sign (a login that no longer
        # works, an audit device that blocks requests, a certificate that is not what was asked
        # for). That is the break-glass case too.
        try {
            $token = Get-LabBaoToken 'pc-deploy'
            try {
                $body = @{ public_key = $keyLine; cert_type = $spec.Type; valid_principals = ($Principals -join ','); ttl = "$([int]($Hours * 60))m" }
                $answer = Invoke-LabBao POST "$($script:LabSshMount)/sign/$Role" $body -Token $token
                [IO.File]::WriteAllText($certFile, $answer.data.signed_key.Trim() + "`n", (New-Object Text.UTF8Encoding $false))
            }
            finally { Close-LabBaoToken $token }
            $expected.CaFingerprint = $signer.CaFingerprint
            $cert = Assert-LabSshCertificate $certFile $expected
        }
        catch {
            Remove-Item -Force -ErrorAction SilentlyContinue $certFile
            $signer = Resolve-LabSshSignerFailure "OpenBao could not sign the SSH certificate: $($_.Exception.Message)" -BreakGlass:$BreakGlass
        }
    }
    if ($signer.Kind -ne 'openbao') {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $keyId = "offline$(if ($signer.Reason -eq 'break-glass') { '-breakglass' })-$Role-$Purpose-$stamp"
        # -V -5m:+<n>m: valid from 5 minutes ago (a VM whose clock lags a little still accepts it),
        # for $Hours from now. -O clear first removes ssh-keygen's default extensions.
        $arguments = @('-I', $keyId, '-n', ($Principals -join ','), '-V', "-5m:+$([int]($Hours * 60))m", '-z', "$(New-LabSshSerial)")
        if ($spec.Type -eq 'host') { $arguments = @('-h') + $arguments }
        else {
            $arguments += @('-O', 'clear')
            foreach ($extension in $spec.Extensions) { $arguments += @('-O', $extension) }
            $arguments += @('-O', "source-address=$($spec.SourceAddress)")
        }
        Invoke-LabSshOfflineCa ($arguments + $PublicKeyFile)
        $expected.CaFingerprint = $signer.CaFingerprint
        $cert = Assert-LabSshCertificate $certFile $expected
    }
    # One line per certificate, for your own audit trail of offline signatures (OpenBao has its
    # audit log). No secrets in it.
    $signerName = if ($signer.Kind -eq 'openbao') { 'openbao' } else { "offline ($($signer.Reason))" }
    Add-Content -Path $script:LabSshIssuedLog -Value ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f [datetime]::UtcNow.ToString('s'), $signerName, $Role, $cert.KeyId, $cert.Serial, ($cert.Principals -join ','), $cert.ValidTo.ToString('s'), $cert.KeyFingerprint)
    return [pscustomobject]@{ Path = $certFile; Signer = $signerName; KeyId = $cert.KeyId; Serial = $cert.Serial; ValidTo = $cert.ValidTo; CaFingerprint = $cert.CaFingerprint }
}

# --- The PC's own certificate -------------------------------------------------------------------

# True while the PC's certificate is valid for at least $MinHours more hours and was signed by a
# CA that every machine trusts. Reads only a small file; no network.
function Test-LabPcCertificateFresh([double]$MinHours = $script:LabSshPcRenewHours) {
    if (-not (Test-Path $script:LabSshPcCertInfo) -or -not (Test-Path "$($script:LabSshPcKey)-cert.pub")) { return $false }
    $until, $caFingerprint = [IO.File]::ReadAllText($script:LabSshPcCertInfo).Trim() -split '\s+'
    $validTo = [datetime]::Parse($until, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal')
    return ($validTo -gt [datetime]::UtcNow.AddHours($MinHours)) -and ((Get-LabSshTrustedCaFingerprints) -contains $caFingerprint)
}

# A new certificate for the PC's key (the key pair itself stays; Initialize-LabSshCa (lib\LabSsh.ps1) made it once).
# Written as a new file and then moved over the old one, so an ssh starting at that moment sees
# either the old or the new certificate, never half of one.
function Update-LabPcCertificate([switch]$BreakGlass) {
    if (-not (Test-Path "$($script:LabSshPcKey).pub")) { throw 'The PC has no SSH key yet (keys\ssh\pc_ed25519). Run .\lab.ps1 up.' }
    $work = New-LabSshTempDir
    try {
        Copy-Item "$($script:LabSshPcKey).pub" (Join-Path $work 'pc_ed25519.pub')
        $issued = New-LabSshCertificate (Join-Path $work 'pc_ed25519.pub') 'pc' @('lab-all') 'pc' -BreakGlass:$BreakGlass
        Move-Item -Force $issued.Path "$($script:LabSshPcKey)-cert.pub"
        [void](Write-LabSshFile $script:LabSshPcCertInfo @("$($issued.ValidTo.ToString('yyyy-MM-ddTHH:mm:ssZ')) $($issued.CaFingerprint)"))
        Write-Host "SSH:         new certificate for this PC, signed by $($issued.Signer), valid until $($issued.ValidTo.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) (key ID $($issued.KeyId))"
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
}

# THE ENTRY POINT for every script that uses ssh, scp or vagrant: renews the PC's certificate
# when it expires within 4 hours (or its CA is no longer trusted) and returns the path of
# keys\ssh_config. Costs no network call while the certificate is fresh.
function Get-LabSshConfig([switch]$BreakGlass) {
    if (-not (Test-Path $script:LabSshConfigFile)) { throw 'No SSH configuration (keys\ssh_config). Run .\lab.ps1 up first.' }
    if (-not (Test-LabPcCertificateFresh)) {
        Use-LabSshLock { if (-not (Test-LabPcCertificateFresh)) { Update-LabPcCertificate -BreakGlass:$BreakGlass } }
    }
    return $script:LabSshConfigFile
}

# --- ansible-control's certificate for one run --------------------------------------------------

# ansible-control has its own key (made on the VM by provision\bootstrap-ansible-control.sh; it
# never leaves the VM). Before each Ansible run the PC signs its public key for exactly the
# principals that run needs, valid 2 hours like the run's OpenBao token, and the run deletes the
# certificate again when it ends (ansible\bin\lab-run). The certificate is public, so it may
# travel on the command line, base64-encoded to avoid quoting problems.
# Get-LabControlCertificateCommand returns the two shell snippets that install and remove it, for
# commands that do not go through lab-run (tests\Test-LabSshCertificates.ps1).
function Get-LabControlCertificateCommand([string[]]$Principals) {
    $b64 = Get-LabControlCertificate $Principals
    # rm -rf ~/.ansible/cp: Ansible keeps SSH connections open for 60 seconds after a run
    # (ControlPersist, sockets in ~/.ansible/cp). A connection of an earlier run with a broader
    # certificate must not be reusable by this one; without its socket nobody can reach it, and it
    # ends by itself. (No glob: the login shell is zsh, which aborts on a glob without matches.)
    return @{ Install = "rm -rf ~/.ansible/cp && echo $b64 | base64 -d > ~/.ssh/id_ed25519-cert.pub"; Remove = 'rm -f ~/.ssh/id_ed25519-cert.pub; rm -rf ~/.ansible/cp' }
}

# The certificate for one run as base64 text (ansible\bin\lab-run installs it).
function Get-LabControlCertificate([string[]]$Principals) {
    $sshConfig = Get-LabSshConfig
    if (-not $script:LabControlPublicKey) {
        $line = "$(Invoke-LabSsh 'ansible-control' 'cat ~/.ssh/id_ed25519.pub' -ConfigFile $sshConfig)".Trim()
        if ($line -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+=* ') { throw "ansible-control has no ed25519 key in ~/.ssh/id_ed25519.pub (provision it: .\lab.ps1 up)." }
        $script:LabControlPublicKey = $line
    }
    $work = New-LabSshTempDir
    try {
        [IO.File]::WriteAllText((Join-Path $work 'ansible-control.pub'), $script:LabControlPublicKey + "`n")
        $issued = New-LabSshCertificate (Join-Path $work 'ansible-control.pub') 'ansible-control' $Principals 'run'
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($issued.Path))
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
    return $b64
}

# --- Trust files --------------------------------------------------------------------------------

# Renders the three files that say which CAs to trust, from the CA public keys and lab.json. The
# PC is their only author; provisioning and Update-LabSshTrust copy them unchanged.
#   lab_user_ca.pub           TrustedUserCAKeys on the Ubuntu VMs: CAs for user certificates
#   known_hosts               "@cert-authority <names> <CA>": CAs for host certificates, for the
#                             exact host names of the lab (no wildcard: a name that is not in
#                             lab.json is never accepted)
#   firewall_authorized_keys  the authorized_keys of user ansible on the firewall: each CA with
#                             the principals it accepts there and the addresses logins may come
#                             from (the PC and ansible-control)
# Returns $true when one of them changed.
function Write-LabSshTrustFiles {
    $cas = Get-LabSshCaKeys
    $names = @(Get-LabSshMachines | ForEach-Object { Get-LabSshFqdn $_ }) -join ','
    $controlIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip
    $firewallLines = @($cas | ForEach-Object { "cert-authority,principals=`"lab-all,host-firewall`",from=`"$($script:LabConfig.firewall.pcIp),$controlIp`" $_" })
    $changed = Write-LabSshFile $script:LabSshUserCaFile $cas
    $changed = (Write-LabSshFile $script:LabSshKnownHosts @($cas | ForEach-Object { "@cert-authority $names $_" })) -or $changed
    $changed = (Write-LabSshFile $script:LabSshFirewallKeys $firewallLines) -or $changed
    return $changed
}

# The text of keys\ssh_config. lab.ps1 up writes it; tests and lab.ps1 deploy vault render
# variants with another key (a throwaway key with a test certificate) into temporary files.
function Get-LabSshConfigText([string]$IdentityFile = $script:LabSshPcKey) {
    $lab = $script:LabConfig
    $domain = $lab.domain
    $vmNames = @($lab.vms | ForEach-Object { $_.name })
    $p = { param($Path) '"' + ($Path -replace '\\', '/') + '"' }
    $identity = @("    IdentityFile $(& $p $IdentityFile)", "    CertificateFile $(& $p "$IdentityFile-cert.pub")")
    return @"
# Generated by scripts/lib/LabSsh.ps1 (Get-LabSshConfigText) and rewritten by lab.ps1 up:
# edit the script, not this file. Only the firewall is reachable directly from the PC (fixed IP
# on the LabHost network); all other VMs are reached through it as jump host, and their names
# are resolved by the firewall's DNS. Logins use the PC's key with its short-lived certificate;
# host keys are accepted only with a certificate from a lab SSH CA (known_hosts).
Host firewall firewall.$domain
    HostName $($lab.firewall.hostIp)
    HostKeyAlias firewall.$domain

Host $($vmNames -join ' ')
    HostName %h.$domain
    ProxyJump firewall

Host *.$domain !firewall.$domain
    ProxyJump firewall

Host *
    User ansible
$($identity -join "`n")
    IdentitiesOnly yes
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com
    StrictHostKeyChecking yes
    UserKnownHostsFile $(& $p $script:LabSshKnownHosts)
    GlobalKnownHostsFile $(& $p $script:LabSshKnownHosts)
    RevokedHostKeys $(& $p $script:LabSshKrl)
    CheckHostIP no
    UpdateHostKeys no
"@
}

# Writes keys\ssh_config (LF, no BOM: Windows OpenSSH fails on a config that starts with a UTF-8
# byte order mark).
function Write-LabSshConfig {
    [void](Write-LabSshFile $script:LabSshConfigFile (Get-LabSshConfigText).Split("`n"))
}

# Pushes the trust files to every running machine: the firewall's authorized_keys
# (opnsense\lab-ssh-trust.php), lab_user_ca.pub on every VM, known_hosts and the revocation list
# on ansible-control. sshd reads TrustedUserCAKeys and authorized_keys at every login, so no
# restart is needed. -KrlOnly: only the revocation list (lab.ps1 down).
function Update-LabSshTrust([switch]$KrlOnly) {
    $sshConfig = Get-LabSshConfig
    if (-not $KrlOnly) { Set-LabFirewallSshTrust }
    foreach ($vm in $script:LabConfig.vms) {
        # Hyper-V tells whether a VM runs, but only to administrators; without that right (a normal
        # window) the push is simply tried.
        $hv = Get-LabSshHyperVVm $vm.name
        if ($hv -and $hv.State -ne 'Running') { Write-Host "SSH trust:   $($vm.name) is not running; its next provisioning installs the files"; continue }
        if (-not $hv -and -not (Test-LabSshStrictLogin $vm.name $sshConfig)) { Write-Warning "SSH trust:   $($vm.name) is not reachable; its next provisioning installs the files"; continue }
        $files = @()
        if (-not $KrlOnly) { $files += $script:LabSshUserCaFile }
        if ($vm.name -eq 'ansible-control') { $files += $script:LabSshKnownHosts, $script:LabSshKrl }
        if ($files.Count -eq 0) { continue }
        Invoke-LabSsh $vm.name 'rm -rf /tmp/lab-ssh-trust && mkdir -m 700 /tmp/lab-ssh-trust' -ConfigFile $sshConfig | Out-Null
        Copy-LabSshFile $files "$($vm.name):/tmp/lab-ssh-trust/" -ConfigFile $sshConfig
        $commands = @()
        if (-not $KrlOnly) { $commands += 'sudo install -m 0644 -o root -g root /tmp/lab-ssh-trust/lab_user_ca.pub /etc/ssh/lab_user_ca.pub' }
        if ($vm.name -eq 'ansible-control') {
            $commands += 'sudo install -m 0644 -o root -g root /tmp/lab-ssh-trust/known_hosts /etc/ssh/ssh_known_hosts'
            $commands += 'sudo install -m 0644 -o root -g root /tmp/lab-ssh-trust/revoked_host_keys /etc/ssh/lab_revoked_host_keys'
        }
        Invoke-LabSsh $vm.name "$($commands -join ' && ') && rm -rf /tmp/lab-ssh-trust" -ConfigFile $sshConfig | Out-Null
        Write-Host "SSH trust:   $($vm.name) updated"
    }
}

# The firewall keeps the authorized_keys of its users in config.xml (base64), and OPNsense writes
# ~ansible/.ssh/authorized_keys from there. opnsense\lab-ssh-trust.php replaces the entry of user
# ansible with keys\ssh\firewall_authorized_keys and writes the file again - the same as pasting
# the keys into System > Access > Users in the GUI. $Options: ssh options for a pinned connection
# (lab.ps1 firewall, before the firewall has a host certificate).
function Set-LabFirewallSshTrust([string[]]$Options = @()) {
    $sshConfig = Get-LabSshConfig
    $remote = "$(@(Invoke-LabSsh 'firewall' 'mktemp -d /tmp/lab-ssh-trust.XXXXXX' -Options $Options -ConfigFile $sshConfig)[-1])".Trim()
    if ($remote -notmatch '^/tmp/lab-ssh-trust\.[A-Za-z0-9]+$') { throw "Unexpected answer from the firewall: $remote" }
    try {
        Copy-LabSshFile @($script:LabSshFirewallKeys, (Join-Path $script:LabProjectRoot 'opnsense\lab-ssh-trust.php')) "firewall:$remote/" -Options $Options -ConfigFile $sshConfig
        $answer = Invoke-LabSsh 'firewall' "sudo /usr/local/bin/php $remote/lab-ssh-trust.php $remote/firewall_authorized_keys" -Options $Options -ConfigFile $sshConfig
        if ("$answer" -match 'changed') { Write-Host 'SSH trust:   firewall: authorized_keys of user ansible updated in config.xml' }
    }
    finally { Invoke-LabSsh 'firewall' "rm -rf $remote" -Options $Options -AllowFailure -ConfigFile $sshConfig | Out-Null }
}

# --- Host keys and host certificates ------------------------------------------------------------

function Get-LabSshHostKeyFile([string]$Name) { return Join-Path $script:LabSshHostsDir "$Name.pub" }

# Stores a verified host key as keys\ssh\hosts\<name>.pub. Refuses a key that another machine
# already has (two VMs made from the same image would share host keys).
function Save-LabSshHostKey([string]$Name, [string]$KeyLine) {
    $key = ((($KeyLine.Trim() -split '\s+')[0..1]) -join ' ')
    if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+=*$') { throw "Not an ed25519 host key for $Name`: $KeyLine" }
    $fingerprint = Get-LabSshFingerprint $key
    foreach ($other in Get-ChildItem $script:LabSshHostsDir -Filter '*.pub' -File -ErrorAction SilentlyContinue) {
        if ($other.Name -like '*-cert.pub' -or $other.BaseName -eq $Name) { continue }
        if ((Get-LabSshFingerprint ([IO.File]::ReadAllText($other.FullName))) -eq $fingerprint) { throw "$Name has the same host key as $($other.BaseName) ($fingerprint): refusing to certify it." }
    }
    [void](Write-LabSshFile (Get-LabSshHostKeyFile $Name) @("$key $(Get-LabSshFqdn $Name)"))
}

# A machine was deleted or got a new host key: its old key goes into the revocation list (KRL).
# ssh on the PC and on ansible-control then refuses that key with any certificate - a copy of it
# (from a checkpoint or an old disk) can no longer impersonate the machine.
function Revoke-LabSshHostKey([string]$Name) {
    $file = Get-LabSshHostKeyFile $Name
    if (-not (Test-Path $file)) { return }
    $ErrorActionPreference = 'Continue'
    $output = & $script:LabSshKeygen -k -u -f $script:LabSshKrl $file 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Revoking the old host key of $Name failed: $($output -join ' ')" }
    $retired = Join-Path $script:LabSshHostsDir 'retired'
    New-Item -ItemType Directory -Force -Path $retired | Out-Null
    Move-Item -Force $file (Join-Path $retired "$Name-$(Get-Date -Format yyyyMMdd-HHmmss).pub")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $script:LabSshHostsDir "$Name-cert.pub")
    Write-Host "SSH:         old host key of $Name revoked (keys\ssh\revoked_host_keys)"
}

# Why the stored certificate of a machine must be renewed, or $null. "Soft" reasons (it expires
# within 30 days; the offline CA signed it while OpenBao is available) allow keeping the current
# one if signing fails.
function Get-LabSshHostCertificateDue([string]$Name) {
    $certFile = Join-Path $script:LabSshHostsDir "$Name-cert.pub"
    if (-not (Test-Path $certFile)) { return @{ Reason = 'no certificate yet'; Soft = $false } }
    $cert = Read-LabSshCertificate $certFile
    if ($cert.KeyFingerprint -ne (Get-LabSshFingerprint ([IO.File]::ReadAllText((Get-LabSshHostKeyFile $Name))))) { return @{ Reason = 'the host key changed'; Soft = $false } }
    if ((Get-LabSshTrustedCaFingerprints) -notcontains $cert.CaFingerprint) { return @{ Reason = 'its CA is no longer trusted'; Soft = $false } }
    if ($cert.ValidTo -lt [datetime]::UtcNow) { return @{ Reason = 'it has expired'; Soft = $false } }
    if ($cert.ValidTo -lt [datetime]::UtcNow.AddDays($script:LabSshHostRenewDays)) { return @{ Reason = "it expires on $($cert.ValidTo.ToLocalTime().ToString('yyyy-MM-dd'))"; Soft = $true } }
    if ((Test-LabSshOpenBaoTrusted) -and $cert.CaFingerprint -eq (Get-LabSshOfflineCaFingerprint)) { return @{ Reason = 'the offline CA signed it, OpenBao signs from now on'; Soft = $true } }
    return $null
}

# Signs the stored host key of a machine when its certificate is due. Returns $true when a new
# certificate was made.
function Update-LabSshHostCertificateFile([string]$Name, [switch]$BreakGlass) {
    $due = Get-LabSshHostCertificateDue $Name
    if (-not $due) { return $false }
    $work = New-LabSshTempDir
    try {
        Copy-Item (Get-LabSshHostKeyFile $Name) (Join-Path $work "$Name.pub")
        try { $issued = New-LabSshCertificate (Join-Path $work "$Name.pub") 'lab-hosts' @(Get-LabSshFqdn $Name) $Name -BreakGlass:$BreakGlass }
        catch {
            if (-not $due.Soft) { throw }
            Write-Warning "Host certificate of $Name is due ($($due.Reason)) but could not be renewed now: $($_.Exception.Message). The current one stays; the next run tries again."
            return $false
        }
        Move-Item -Force $issued.Path (Join-Path $script:LabSshHostsDir "$Name-cert.pub")
        Write-Host "SSH:         host certificate for $(Get-LabSshFqdn $Name) ($($due.Reason)): signed by $($issued.Signer), valid until $($issued.ValidTo.ToLocalTime().ToString('yyyy-MM-dd'))"
        return $true
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
}

# ssh options for a connection that trusts exactly one stored host key, without a certificate:
# used to install a host certificate (the stored key was verified on first contact). Works
# whether the machine has a valid, an expired or no certificate. The ssh options apply to the
# last hop only; a jump through the firewall still uses keys\ssh_config.
function Get-LabSshPinnedOptions([string]$Name, [string]$Folder) {
    $pin = Join-Path $Folder "pin-$Name"
    [void](Write-LabSshFile $pin @("$(Get-LabSshFqdn $Name) $(((([IO.File]::ReadAllText((Get-LabSshHostKeyFile $Name))).Trim() -split '\s+')[0..1]) -join ' ')"))
    $path = ConvertTo-LabSshPath $pin
    return @('-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', "UserKnownHostsFile=$path", '-o', "GlobalKnownHostsFile=$path", '-o', 'StrictHostKeyChecking=yes')
}

# A normal, fully checked login (host certificate against the lab CAs): $true if it works.
function Test-LabSshStrictLogin([string]$Machine, [string]$ConfigFile) {
    if (-not $ConfigFile) { $ConfigFile = Get-LabSshConfig }
    $ErrorActionPreference = 'Continue'
    & ssh -F $ConfigFile -o LogLevel=QUIET -o BatchMode=yes -o ConnectTimeout=15 $Machine 'true' 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# The host key a lab VM published through Hyper-V KVP (provision\harden-ssh.sh). KVP data items
# are exchanged over VMBus between a VM and its own host; only root inside that VM can write
# them, and Hyper-V shows them per VM (Msvm_KvpExchangeComponent.GuestExchangeItems, readable
# for administrators). So this is the VM's own statement about its key, independent of the
# network. Waits up to $TimeoutSeconds for the item to appear.
function Get-LabKvpHostKey([string]$Name, [int]$TimeoutSeconds = 90) {
    $vm = Get-LabSshHyperVVm $Name
    if (-not $vm) { throw "No Hyper-V VM for $Name." }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $kvp = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_KvpExchangeComponent' -Filter "SystemName='$($vm.Id)'"
        foreach ($item in @($kvp.GuestExchangeItems)) {
            if (-not $item) { continue }
            $properties = ([xml]$item).INSTANCE.PROPERTY
            $itemName = ($properties | Where-Object { $_.NAME -eq 'Name' }).VALUE
            $data = ($properties | Where-Object { $_.NAME -eq 'Data' }).VALUE
            if ($itemName -eq 'LabSshHostKeyEd25519' -and $data -match '^ssh-ed25519 [A-Za-z0-9+/]+=*$') { return $data }
        }
        if ((Get-Date) -gt $deadline) { throw "$Name has not published its SSH host key through Hyper-V KVP (item LabSshHostKeyEd25519) within $TimeoutSeconds s. Provision it: .\lab.ps1 up" }
        Start-Sleep -Seconds 3
    }
}

# Every lab VM in $Names: read its host key from KVP (a changed key is revoked first), sign a
# host certificate when one is due, and install it over a connection pinned to that key when the
# VM does not present it yet. Ends with a fully checked login. Needs an elevated shell (KVP).
function Update-LabVmHostCertificates([string[]]$Names, [switch]$BreakGlass) {
    $sshConfig = Get-LabSshConfig -BreakGlass:$BreakGlass
    $revoked = $false
    foreach ($name in $Names) {
        $kvpKey = Get-LabKvpHostKey $name
        $stored = Get-LabSshHostKeyFile $name
        if ((Test-Path $stored) -and (Get-LabSshFingerprint ([IO.File]::ReadAllText($stored))) -ne (Get-LabSshFingerprint $kvpKey)) {
            Write-Warning "$name has a new SSH host key (rebuilt?): the old one is revoked."
            Revoke-LabSshHostKey $name
            $revoked = $true
        }
        Save-LabSshHostKey $name $kvpKey
        $new = Update-LabSshHostCertificateFile $name -BreakGlass:$BreakGlass
        if (-not $new -and (Test-LabSshStrictLogin $name $sshConfig)) { Write-Host "SSH:         $name presents its host certificate (checked)"; continue }
        $work = New-LabSshTempDir
        try {
            $pinned = Get-LabSshPinnedOptions $name $work
            Copy-LabSshFile @(Join-Path $script:LabSshHostsDir "$name-cert.pub") "${name}:/tmp/lab-host-cert.pub" -Options $pinned -ConfigFile $sshConfig
            # sshd -t checks the whole configuration before the reload, so a broken file never
            # takes SSH down. The reload makes sshd read its host certificate again; existing
            # sessions keep running.
            Invoke-LabSsh $name 'sudo install -m 0644 -o root -g root /tmp/lab-host-cert.pub /etc/ssh/ssh_host_ed25519_key-cert.pub && rm -f /tmp/lab-host-cert.pub && sudo sshd -t && sudo systemctl reload-or-restart ssh' -Options $pinned -ConfigFile $sshConfig | Out-Null
        }
        finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
        if (-not (Test-LabSshStrictLogin $name $sshConfig)) { throw "$name does not pass the strict SSH check after installing its host certificate." }
        Write-Host "SSH:         host certificate installed on $name (checked)"
    }
    # ansible-control checks the revocation list too: it gets the new one now, not only at its
    # next provisioning.
    if ($revoked) { Send-LabSshKrl }
}

# The revocation list to ansible-control, when it runs; a failure only warns (its next
# provisioning uploads the list anyway).
function Send-LabSshKrl {
    $control = Get-LabSshHyperVVm 'ansible-control'
    if ($control -and $control.State -ne 'Running') { return }
    try { Update-LabSshTrust -KrlOnly }
    catch { Write-Warning "ansible-control did not get the new revocation list now ($($_.Exception.Message)); its next provisioning installs it." }
}

# --- OpenBao's SSH CA ---------------------------------------------------------------------------

# lab.ps1 deploy vault, after it has configured the SSH secrets engine: makes every machine trust
# OpenBao's CA, PROVES it with a login by a throwaway certificate from OpenBao on every machine,
# and only then marks the CA as trusted (keys\ssh\openbao-ca.trusted) - from then on OpenBao signs.
# Until that proof succeeds the offline CA keeps signing, so a failed rollout locks nobody out.
function Enable-LabOpenBaoSshCa {
    $served = "$(Invoke-LabBao GET "$($script:LabSshMount)/public_key")".Trim()
    if ($served -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+=*$') { throw "OpenBao's SSH CA public key looks wrong: $served" }
    if (Test-Path $script:LabSshOpenBaoCa) {
        if ((Get-LabSshFingerprint ([IO.File]::ReadAllText($script:LabSshOpenBaoCa))) -ne (Get-LabSshFingerprint $served)) {
            throw "OpenBao serves a different SSH CA than keys\ssh\openbao-ca.pub (restored from another snapshot?). lab.ps1 down vault moves the old one aside; or move keys\ssh\openbao-ca.pub and openbao-ca.trusted away yourself to accept the new CA."
        }
    }
    else { [void](Write-LabSshFile $script:LabSshOpenBaoCa @($served)) }
    if (Test-LabSshOpenBaoTrusted) { Write-Host 'SSH CA:      OpenBao signs SSH certificates (trusted by every machine)'; return }
    [void](Write-LabSshTrustFiles)
    Update-LabSshTrust
    # The proof: a throwaway key, a 10-minute certificate from OpenBao (role pc), and a temporary
    # ssh_config that offers only this key. ProxyJump passes -F on to the jump, so both hops of
    # every VM login are tested.
    $work = New-LabSshTempDir
    try {
        $key = Join-Path $work 'probe_ed25519'
        $emptyPassphrase = '""'
        if ($PSVersionTable.PSVersion -ge [version]'7.3') { $emptyPassphrase = '' }
        $ErrorActionPreference = 'Continue'
        & $script:LabSshKeygen -q -t ed25519 -N $emptyPassphrase -C 'openbao-ssh-ca-probe' -f $key 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen could not make the probe key.' }
        $ErrorActionPreference = 'Stop'
        $token = Get-LabBaoToken 'pc-deploy'
        try {
            $answer = Invoke-LabBao POST "$($script:LabSshMount)/sign/pc" @{ public_key = [IO.File]::ReadAllText("$key.pub").Trim(); cert_type = 'user'; valid_principals = 'lab-all'; ttl = '10m' } -Token $token
            [IO.File]::WriteAllText("$key-cert.pub", $answer.data.signed_key.Trim() + "`n", (New-Object Text.UTF8Encoding $false))
        }
        finally { Close-LabBaoToken $token }
        $config = Join-Path $work 'ssh_config'
        [void](Write-LabSshFile $config (Get-LabSshConfigText -IdentityFile $key).Split("`n"))
        $failed = @(Get-LabSshMachines | Where-Object { -not (Test-LabSshStrictLogin $_ $config) })
        if ($failed.Count -gt 0) { throw "A certificate from OpenBao's SSH CA is not accepted by $($failed -join ', ') yet. The offline CA keeps signing; run lab.ps1 deploy vault again once every machine is running." }
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
    [void](Write-LabSshFile $script:LabSshOpenBaoTrusted @(Get-LabSshFingerprint $served))
    Write-Host 'SSH CA:      OpenBao''s SSH CA is trusted by every machine (test login passed); it signs from now on'
}

# --- Setting up the offline CA and this PC's key (once) ----------------------------------------

# Creates the offline SSH CA and this PC's SSH key in keys\ssh when they are missing, the empty
# host key revocation list, and restricts access to keys\. Never replaces a CA or a key. Called by
# "lab.ps1 up" (step 2).
#   keys\ssh\offline-ca(.pub)    the offline SSH CA: an ed25519 key, encrypted with a random
#                                48-character passphrase stored with DPAPI
#                                (keys\ssh\offline-ca-passphrase.dpapi). It signs while OpenBao does
#                                not exist yet, and on request when OpenBao is broken. Every lab
#                                machine trusts it permanently.
#   keys\ssh\pc_ed25519(.pub)    this PC's SSH key. No passphrase, but alone it opens nothing:
#                                logins need a certificate for it, valid 8 hours.
#   keys\ssh\revoked_host_keys   the revocation list (KRL) for host keys, empty at first. It must
#                                exist before ssh is told to read it (RevokedHostKeys).
# After a NEW offline CA, add it to the recovery file: .\lab.ps1 recovery -Renew (own window).
# THREAT MODEL, BRIEFLY
#   - Someone who copies files from keys\ (a backup, a disk image) gets the encrypted CA key
#     (useless without the DPAPI-protected passphrase) and at most the remaining hours of the PC's
#     certificate, usable only from the PC's own addresses (source-address).
#   - Code that runs as you can decrypt DPAPI, so it can sign with the offline CA and log in to
#     OpenBao as pc-deploy: every login still shows key ID, serial and CA in the target's SSH log,
#     and certificates expire.
#   - Offline signing passes the CA passphrase to ssh-keygen on its command line (-P; OpenSSH 8.1
#     has no other unattended way). Programs running as you or as an administrator can see it while
#     ssh-keygen runs, and Windows logs it if "Include command line in process creation events" is
#     switched on - this function warns about that setting.
# Enterprise equivalent: the offline CA would live in an HSM or on an air-gapped machine, and
# people would get their certificates from an online CA after an SSO login with MFA.
function Initialize-LabSshCa {
    if (-not (Test-Path $script:LabSshKeygen)) {
        throw "$script:LabSshKeygen not found. Please install the Windows feature ""OpenSSH Client""."
    }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # keys\ holds the lab's secrets on the PC: the SSH CA and key (keys\ssh), the offline root CA
    # (keys\pki, its key encrypted), the DPAPI-encrypted secrets (keys\opnsense, keys\openbao) and
    # OpenBao's snapshots. Locking single files is not enough: a new file inherits the folder's
    # permissions until a script locks it, and the subfolders would stay readable for everyone who
    # can read the project folder. So the folder gets no inherited entries; Full control for you and
    # for SYSTEM (Windows services such as backup and antivirus run as SYSTEM; "*S-1-5-18" is its
    # language-independent SID), passed on to everything inside: (OI) object inherit = files, (CI)
    # container inherit = subfolders. Files a script locked explicitly keep their own, stricter list.
    New-Item -ItemType Directory -Force -Path $script:LabSshHostsDir | Out-Null
    & icacls $script:LabKeysDir /inheritance:r /grant:r "${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls (keys folder) failed (exit code $LASTEXITCODE)." }

    # Windows OpenSSH, like OpenSSH on Linux, refuses a private key that other users can read: no
    # inherited entries, Full control for you only, and you as the owner (the Windows counterpart of
    # "chmod 600"). Runs every time, so permissions that changed in the meantime are repaired.
    $protect = {
        param($Path)
        & icacls $Path /inheritance:r /grant:r "${me}:F" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls (setting permissions on $Path) failed (exit code $LASTEXITCODE)." }
        & icacls $Path /setowner $me | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls (setting the owner of $Path) failed (exit code $LASTEXITCODE)." }
    }

    # Windows PowerShell 5.1 drops empty-string arguments when it calls native programs, so
    # ssh-keygen would take the next argument as the passphrase. '""' puts a literal pair of double
    # quotes on the command line, which ssh-keygen reads as an empty string (PowerShell 7.3 and
    # later pass '' correctly).
    $emptyPassphrase = '""'
    if ($PSVersionTable.PSVersion -ge [version]'7.3') { $emptyPassphrase = '' }

    if (Test-Path $script:LabSshOfflineCa) {
        if (-not (Test-LabSecret 'ssh/offline-ca-passphrase')) {
            throw 'keys\ssh\offline-ca exists, but its passphrase (keys\ssh\offline-ca-passphrase.dpapi) does not. Restore it with .\lab.ps1 recovery -Recover <file>.'
        }
        Write-Host "SSH CA:      offline CA $(Get-LabSshOfflineCaFingerprint) (keys\ssh\offline-ca)"
    }
    else {
        # -a 100: 100 rounds of bcrypt to derive the encryption key from the passphrase (slows down
        # guessing; the passphrase is random anyway). The passphrase goes to ssh-keygen through
        # .NET's Process class, set as a property (module logging records cmdlet parameters).
        $pass = New-LabRandomText 48
        Protect-LabSecret 'ssh/offline-ca-passphrase' $pass -Force
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $script:LabSshKeygen
        $psi.Arguments = "-q -t ed25519 -a 100 -N $pass -C lab-offline-ssh-ca -f `"$script:LabSshOfflineCa`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        $psi = $null; $pass = $null
        $process.StandardInput.Close()
        $errorText = $process.StandardError.ReadToEnd() + $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "ssh-keygen could not create the offline SSH CA (exit code $($process.ExitCode)): $errorText" }
        Write-Host "SSH CA:      NEW offline CA $(Get-LabSshOfflineCaFingerprint) (keys\ssh\offline-ca, passphrase in DPAPI)"
        Write-Host '             Add it to your recovery file, in your own PowerShell window:  .\lab.ps1 recovery -Renew'
    }
    & $protect $script:LabSshOfflineCa

    if (-not (Test-Path $script:LabSshPcKey)) {
        Remove-Item -Force -ErrorAction SilentlyContinue "$($script:LabSshPcKey).pub", "$($script:LabSshPcKey)-cert.pub", $script:LabSshPcCertInfo
        & $script:LabSshKeygen -q -t ed25519 -N $emptyPassphrase -C 'pc@deployableserver-lab' -f $script:LabSshPcKey
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen could not create keys\ssh\pc_ed25519 (exit code $LASTEXITCODE)." }
        Write-Host 'SSH:         new key for this PC (keys\ssh\pc_ed25519; it needs a certificate to log in)'
    }
    & $protect $script:LabSshPcKey

    if (-not (Test-Path $script:LabSshKrl)) {
        & $script:LabSshKeygen -q -k -f $script:LabSshKrl
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen could not create keys\ssh\revoked_host_keys (exit code $LASTEXITCODE)." }
    }

    # "Include command line in process creation events" (Group Policy: Administrative Templates >
    # System > Audit Process Creation): Windows would write the CA passphrase of every offline
    # signature into the Security event log.
    $audit = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -Name 'ProcessCreationIncludeCmdLine_Enabled' -ErrorAction SilentlyContinue
    if ($audit -and $audit.ProcessCreationIncludeCmdLine_Enabled -eq 1) {
        Write-Warning 'Windows logs the command lines of new processes (ProcessCreationIncludeCmdLine_Enabled = 1): offline SSH signatures put the offline CA passphrase into the Security event log.'
    }
}

<#
.SYNOPSIS
    Renews this PC's SSH certificate when it is due (lab.ps1 ssh-cert), and shows which CA signed
    it and until when it is valid.

.DESCRIPTION
    Every lab command renews the certificate by itself (Get-LabSshConfig), and the Vagrantfile runs
    ".\lab.ps1 ssh-cert" before "vagrant up/provision/reload/ssh/halt/resume" when it expires within
    4 hours. Run it by hand to see the current state or to get a new certificate now (-Force). The
    certificate is valid for 8 hours and only for the principal "lab-all", from this PC's
    addresses. OpenBao signs it once "lab.ps1 deploy vault" has made its SSH CA trusted
    everywhere; before that, the offline SSH CA (bootstrap). Break-glass (OpenBao broken):
    .\lab.ps1 breakglass ssh-cert -Force

.PARAMETER Force
    Sign a new certificate even if the current one is still fresh.
#>
function Invoke-LabSshCertRenewal {
    [CmdletBinding()]
    param([switch]$Force)
    if ($Force) { Use-LabSshLock { Update-LabPcCertificate } }
    else { [void](Get-LabSshConfig) }
    $cert = Read-LabSshCertificate "$($script:LabSshPcKey)-cert.pub"
    $signer = if ($cert.CaFingerprint -eq (Get-LabSshOfflineCaFingerprint)) { 'the offline SSH CA' } else { 'OpenBao' }
    Write-Host "SSH certificate of this PC: signed by $signer, valid until $($cert.ValidTo.ToLocalTime().ToString('yyyy-MM-dd HH:mm')), key ID $($cert.KeyId), serial $($cert.Serial)"
}
