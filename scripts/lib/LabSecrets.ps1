<#
.SYNOPSIS
    Shared helpers for the lab's secrets: DPAPI storage on the PC and the OpenBao REST API.

.DESCRIPTION
    Not run directly: scripts\lib\Lab.ps1 loads it together with the other libraries
    ("dot-sourcing": the functions become available in the calling script).

    SECRET ZERO ON THE PC: WINDOWS DPAPI
    Every secret system needs a first key that is not itself stored in that system. In this
    lab it is your Windows account: secrets the PC needs (OpenBao unseal key shares, the PC's
    OpenBao credentials, the root CA key passphrase) are encrypted with DPAPI, the Windows Data
    Protection API, in the scope "CurrentUser". Windows derives the key from your logon, so only
    processes running as you, on this PC, can decrypt them; other local accounts, copied files
    and backups see only ciphertext. They are stored as keys\<area>\<name>.dpapi (base64).
    What DPAPI does NOT protect against: programs that run as you (malware, scripts, coding
    assistants). And if your Windows profile is lost or your password is reset by an
    administrator, the blobs cannot be decrypted any more - hence the recovery kit
    (lab.ps1 recovery: one key share on paper, one in a passphrase-encrypted file).
    Enterprise equivalent: an HSM or cloud KMS holds the first key, with recovery procedures.

    OPENBAO OVER HTTPS, PINNED TO THE LAB ROOT
    OpenBao's certificate is issued by the lab's root CA (keys\pki\root-ca.crt). For OpenBao's
    address the helpers accept a certificate only when its chain ends exactly at that root
    certificate (compared by thumbprint) and the host name matches - whatever else Windows
    trusts. This is "certificate pinning": stricter than trusting the Windows store, which may
    also hold roots of TLS-inspecting security software or the retired first lab CA. It also
    works before you have imported the root into Windows. Other HTTPS addresses called from the
    same PowerShell session keep Windows' normal validation.

    No function here prints a secret. Values are returned to the caller, which must not print
    them either: this console's output may be logged (transcripts, tool logs).
#>

Add-Type -AssemblyName System.Security

# scripts\lib\ -> the project folder, two levels up.
$script:LabProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:LabKeysDir = Join-Path $script:LabProjectRoot 'keys'
$script:LabConfig = Get-Content -Raw (Join-Path $script:LabProjectRoot 'config\lab.json') | ConvertFrom-Json
$script:LabVaultUrl = "https://vault.$($script:LabConfig.domain):8200"
$script:LabRootCaCert = Join-Path $script:LabKeysDir 'pki\root-ca.crt'

# --- DPAPI ------------------------------------------------------------------------------------

function Get-LabSecretPath([string]$Name) {
    return Join-Path $script:LabKeysDir (($Name -replace '/', '\') + '.dpapi')
}

function Test-LabSecret([string]$Name) {
    return Test-Path (Get-LabSecretPath $Name)
}

# Encrypts $Value for the current Windows user and stores it. The "entropy" (an extra input to
# the encryption) binds each blob to its name, so a blob copied to another name cannot be
# decrypted by mistake. It is not secret. An existing secret is never overwritten silently.
function Protect-LabSecret([string]$Name, [string]$Value, [switch]$Force) {
    if (-not $Name -or -not $Value) { throw 'Protect-LabSecret: name and value are required.' }
    $path = Get-LabSecretPath $Name
    if ((Test-Path $path) -and -not $Force) {
        throw "Secret '$Name' already exists ($path). It is not overwritten; use -Force only on purpose."
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    $entropy = [Text.Encoding]::UTF8.GetBytes("DeployableServer|$($Name -replace '\\', '/')")
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $blob = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    [IO.File]::WriteAllText($path, [Convert]::ToBase64String($blob))
    # Like every file in keys\: readable only by you (on top of the encryption).
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $path /inheritance:r /grant:r "${me}:F" | Out-Null
}

function Unprotect-LabSecret([string]$Name) {
    $path = Get-LabSecretPath $Name
    if (-not (Test-Path $path)) { throw "Secret '$Name' not found ($path)." }
    # Blobs that lab.ps1 down moved to keys\openbao-retired-<date-time>\ keep the entropy of
    # their original name (openbao/<x>): it is part of the encryption and cannot be changed
    # without decrypting and encrypting again.
    $entropyName = ($Name -replace '\\', '/') -replace '^openbao-retired-\d{8}-\d{6}/', 'openbao/'
    $entropy = [Text.Encoding]::UTF8.GetBytes("DeployableServer|$entropyName")
    $blob = [Convert]::FromBase64String([IO.File]::ReadAllText($path).Trim())
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($blob, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

# Random letters and digits from the cryptographic random number generator. Letters and digits
# only: such values survive YAML, shell, URLs and env files without escaping.
function New-LabRandomText([int]$Length = 32) {
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $result = New-Object Text.StringBuilder
    $buffer = New-Object byte[] 1
    while ($result.Length -lt $Length) {
        $rng.GetBytes($buffer)
        # 248 = 4 x 62: values above would make some characters more likely (modulo bias).
        if ($buffer[0] -lt 248) { [void]$result.Append($chars[$buffer[0] % 62]) }
    }
    $rng.Dispose()
    return $result.ToString()
}

# Stops scripts that show secrets unless they run in a real console window: output that is
# redirected (to a log file, or captured by a tool) could end up stored in plain text.
function Assert-LabInteractiveConsole([string]$What) {
    if (-not [Environment]::UserInteractive -or [Console]::IsOutputRedirected -or [Console]::IsInputRedirected) {
        throw "$What shows secrets on the screen. Run it yourself in a PowerShell window, not through another program or with redirected output."
    }
}

# --- OpenBao REST API -------------------------------------------------------------------------

function Initialize-LabTls {
    if (-not (Test-Path $script:LabRootCaCert)) {
        throw "No lab root CA yet ($script:LabRootCaCert). It is created by .\lab.ps1 deploy vault."
    }
    # A type added with Add-Type stays loaded for the whole PowerShell session and cannot be
    # replaced, hence the version in its name.
    if (-not ('LabTlsPin2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class LabTlsPin2 {
    public static X509Certificate2 Root;
    public static string PinnedHost;
    public static readonly RemoteCertificateValidationCallback Callback = Validate;
    // The callback applies to every HTTPS request of this PowerShell process (it is set on
    // ServicePointManager). For OpenBao's host name: accept a server certificate only if its
    // chain ends exactly at the lab root (by thumbprint), whatever Windows trusts; wrong host
    // names are always rejected. For any other host: Windows' normal validation.
    static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
        HttpWebRequest request = sender as HttpWebRequest;
        bool pinned = request != null && string.Equals(request.RequestUri.Host, PinnedHost, StringComparison.OrdinalIgnoreCase);
        if (!pinned) return errors == SslPolicyErrors.None;
        if (Root == null || certificate == null) return false;
        if ((errors & (SslPolicyErrors.RemoteCertificateNameMismatch | SslPolicyErrors.RemoteCertificateNotAvailable)) != 0) return false;
        using (X509Chain c = new X509Chain()) {
            c.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            c.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
            c.ChainPolicy.ExtraStore.Add(Root);
            if (!c.Build(new X509Certificate2(certificate))) return false;
            X509Certificate2 top = c.ChainElements[c.ChainElements.Count - 1].Certificate;
            return top.Thumbprint == Root.Thumbprint;
        }
    }
}
'@
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [LabTlsPin2]::Root = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $script:LabRootCaCert
    [LabTlsPin2]::PinnedHost = ([Uri]$script:LabVaultUrl).Host
    [Net.ServicePointManager]::ServerCertificateValidationCallback = [LabTlsPin2]::Callback
}

# One call to the OpenBao API (https://vault.lab.internal:8200/v1/<Path>). The body is sent as
# JSON. Errors carry OpenBao's own message (never the request body, which may hold secrets).
function Invoke-LabBao([string]$Method, [string]$Path, $Body, [string]$Token, [hashtable]$Headers, [switch]$AllowNotFound) {
    Initialize-LabTls
    $h = @{}
    if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
    if ($Token) { $h['X-Vault-Token'] = $Token }
    $request = @{ Method = $Method; Uri = "$script:LabVaultUrl/v1/$Path"; Headers = $h; TimeoutSec = 120 }
    if ($null -ne $Body) {
        $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
        $request.ContentType = 'application/json'
    }
    try { return Invoke-RestMethod @request }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw "OpenBao $Method $Path failed (HTTP $status): $($_.ErrorDetails.Message) $($_.Exception.Message)"
    }
}

# Health without exceptions: sealed (503) and uninitialised (501) are answered with 200 here, so
# the state can be read from the body. $null if OpenBao is not reachable at all.
function Get-LabVaultHealth {
    try { return Invoke-LabBao GET 'sys/health?sealedcode=200&uninitcode=200&standbyok=true' }
    catch { return $null }
}

function Wait-LabVaultReachable([int]$TimeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $health = Get-LabVaultHealth
        if ($health) { return $health }
        Start-Sleep -Seconds 5
    }
    # An expired certificate looks like "no answer" here (the pinned TLS check rejects it).
    $served = Get-LabServedCertificate ([Uri]$script:LabVaultUrl).Host ([Uri]$script:LabVaultUrl).Port
    if ($served -and $served.NotAfter -lt (Get-Date)) {
        throw "OpenBao's TLS certificate expired on $($served.NotAfter.ToString('yyyy-MM-dd')). Renew it with .\lab.ps1 deploy vault."
    }
    throw "OpenBao ($script:LabVaultUrl) does not answer after $TimeoutSeconds s."
}

# UNSEAL: after every start OpenBao is "sealed": its data is encrypted and it does not know the
# key yet. Shamir's secret sharing split that key into 3 shares when OpenBao was initialised;
# any 2 rebuild it. Shares A and B are stored with DPAPI on this PC, so this needs no input;
# -Interactive asks for two shares instead (recovery: share B from the recovery file, C from
# paper). The shares are sent over HTTPS and never written anywhere else.
function Unlock-LabVault([switch]$Interactive, [int]$TimeoutSeconds = 180) {
    $health = Wait-LabVaultReachable $TimeoutSeconds
    if (-not $health.initialized) { throw 'OpenBao is not initialised yet. Run .\lab.ps1 deploy vault.' }
    if (-not $health.sealed) { Wait-LabVaultActive; Write-Host 'OpenBao: already unsealed.'; return }
    $names = @('openbao/unseal-a', 'openbao/unseal-b')
    foreach ($i in 0, 1) {
        if ($Interactive) {
            Assert-LabInteractiveConsole 'Unlock-LabVault -Interactive'
            $secure = Read-Host -AsSecureString "Unseal key share $($i + 1) of 2"
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $share = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        else { $share = Unprotect-LabSecret $names[$i] }
        $state = Invoke-LabBao POST 'sys/unseal' @{ key = $share.Trim() }
        $share = $null
        if (-not $state.sealed) { break }
    }
    $health = Get-LabVaultHealth
    if (-not $health -or $health.sealed) { throw 'OpenBao is still sealed after two key shares. Wrong shares?' }
    Wait-LabVaultActive
    Write-Host 'OpenBao: unsealed.'
}

# Right after unsealing, the storage layer (raft) first elects a leader; until then the node is
# a read-only "standby" and writes fail ("cannot write to readonly storage"). Wait for "active".
function Wait-LabVaultActive([int]$TimeoutSeconds = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $health = Get-LabVaultHealth
        if ($health -and -not $health.sealed -and -not $health.standby) { return }
        Start-Sleep -Seconds 1
    }
    throw "OpenBao is unsealed but did not become active within $TimeoutSeconds s."
}

# A token for the PC's own work, from an AppRole whose role_id and secret_id are stored with
# DPAPI ("openbao/pc-admin" or "openbao/pc-deploy"). OpenBao only accepts them from your PC's
# address (bound CIDR 10.10.99.1/32). Revoke the token when done (Close-LabBaoToken).
function Get-LabBaoToken([string]$Role) {
    $credential = Unprotect-LabSecret "openbao/$Role" | ConvertFrom-Json
    $login = Invoke-LabBao POST 'auth/approle/login' @{ role_id = $credential.role_id; secret_id = $credential.secret_id }
    return $login.auth.client_token
}

# A new login for an AppRole: its role_id and a NEW secret_id. Returns @{ role_id; secret_id;
# accessor }. The caller stores role_id and secret_id (DPAPI, or the recovery file) and only
# THEN calls Remove-LabAppRoleSecretIds with the accessor, so that until the new login is safely
# stored, the old one keeps working.
function New-LabAppRoleSecret([string]$Role, [string]$Token) {
    $roleId = (Invoke-LabBao GET "auth/approle/role/$Role/role-id" -Token $Token).data.role_id
    $new = (Invoke-LabBao POST "auth/approle/role/$Role/secret-id" @{} -Token $Token).data
    return @{ role_id = $roleId; secret_id = $new.secret_id; accessor = $new.secret_id_accessor }
}

# Destroys every secret_id of an AppRole except the one with accessor $Except: older, lost or
# leaked logins stop working. (An accessor identifies a secret_id without revealing it.)
function Remove-LabAppRoleSecretIds([string]$Role, [string]$Token, [string]$Except) {
    $existing = Invoke-LabBao GET "auth/approle/role/$Role/secret-id?list=true" -Token $Token -AllowNotFound
    if (-not $existing) { return }
    foreach ($accessor in $existing.data.keys) {
        if ($accessor -ne $Except) {
            Invoke-LabBao POST "auth/approle/role/$Role/secret-id-accessor/destroy" @{ secret_id_accessor = $accessor } -Token $Token | Out-Null
        }
    }
}

# Token role "ui-admin": tokens for you in OpenBao's web UI (lab.ps1 ui). Orphans (they
# outlive the short pc-admin login that creates them), 1 hour at most, usable only from your PC's
# address, administrator policy. Defined here once; lab.ps1 deploy vault and lab.ps1 ui
# both apply it (idempotent).
# Enterprise equivalent: people log in to the UI with their own identity (OIDC through the
# company IdP, here it would be Keycloak), with policies per team - not with tokens.
function Set-LabUiTokenRole([string]$Token) {
    Invoke-LabBao POST 'auth/token/roles/ui-admin' @{
        allowed_policies = @('openbao-admin'); orphan = $true; renewable = $false; token_type = 'service'
        token_explicit_max_ttl = '1h'; token_bound_cidrs = @("$($script:LabConfig.firewall.pcIp)/32")
    } -Token $Token | Out-Null
}

# Admin token: the initial root token while the bootstrap is not finished, pc-admin afterwards.
function Get-LabAdminToken {
    if (Test-LabSecret 'openbao/root-token') { return Unprotect-LabSecret 'openbao/root-token' }
    return Get-LabBaoToken 'pc-admin'
}

function Close-LabBaoToken([string]$Token) {
    # Never revoke the bootstrap root token by accident here (lab.ps1 deploy vault does it once,
    # deliberately).
    if ((Test-LabSecret 'openbao/root-token') -and $Token -eq (Unprotect-LabSecret 'openbao/root-token')) { return }
    try { Invoke-LabBao POST 'auth/token/revoke-self' $null -Token $Token | Out-Null } catch { }
}

# --- Run tokens for Ansible -------------------------------------------------------------------

# Ansible's colours are ANSI escape sequences ("ESC[0;32m" = green). ssh.exe without a
# pseudo-terminal (-t) passes them through unchanged, and the classic Windows console shows them
# as text ("[0;32m") unless its "virtual terminal processing" is switched on. This switches it on
# for the current console window (Windows 10 and later) and returns $true; $false when the
# output is redirected or the console does not allow it - then no colours are requested.
function Enable-LabConsoleColors {
    if ([Console]::IsOutputRedirected) { return $false }
    if (-not ('LabConsoleMode' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LabConsoleMode {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleMode(IntPtr handle, uint mode);
    public static bool EnableVirtualTerminal() {
        IntPtr handle = GetStdHandle(-11);                  // STD_OUTPUT_HANDLE
        uint mode;
        if (!GetConsoleMode(handle, out mode)) return false;
        return SetConsoleMode(handle, mode | 0x0004);       // ENABLE_VIRTUAL_TERMINAL_PROCESSING
    }
}
'@
    }
    try { return [LabConsoleMode]::EnableVirtualTerminal() } catch { return $false }
}

# A token for ONE Ansible run on ansible-control, returned WRAPPED: what comes back is a
# single-use wrapping token, valid for 120 seconds, that ansible-control exchanges for the real
# token (ansible\bin\openbao-run explains the pattern). Minted through a token role (LabVault.ps1),
# usable only from ansible-control's address, with only the given policies (those of the run's
# profile, config\run-profiles.json). Which of the PC's logins may mint depends on the role:
#   ansible-run     deployments, at most 2 hours     pc-deploy, which may do little else (sign SSH
#                                                    certificates, take snapshots)
#   ansible-config  openbao-config.yml, 30 minutes   pc-admin (the root token while the bootstrap is
#                                                    not finished): changing how OpenBao works is an
#                                                    administrator's decision
# LabRun.ps1 (Invoke-LabRun) hands it to ansible-control on stdin.
function New-LabRunToken([string[]]$Policies, [string]$Name = 'ansible', [string]$Role = 'ansible-run') {
    $minter = switch ($Role) {
        'ansible-run' { Get-LabBaoToken 'pc-deploy' }
        'ansible-config' { Get-LabAdminToken }
        default { throw "No token role '$Role' for runs (ansible-run or ansible-config)." }
    }
    try {
        $answer = Invoke-LabBao POST "auth/token/create/$Role" @{ policies = $Policies; display_name = $Name } -Token $minter -Headers @{ 'X-Vault-Wrap-TTL' = '120s' }
        if (-not $answer.wrap_info.token) { throw 'OpenBao returned no wrapped token.' }
        return $answer.wrap_info.token
    }
    finally { Close-LabBaoToken $minter }
}

# --- Certificate maintenance --------------------------------------------------------------------

# The certificate a TLS server presents for a name (SNI). Only read here, not judged: the caller
# looks at its dates. $null when nothing answers.
function Get-LabServedCertificate([string]$HostName, [int]$Port = 443) {
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        if (-not $tcp.ConnectAsync($HostName, $Port).Wait(5000)) { return $null }
        try {
            $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
            $ssl.AuthenticateAsClient($HostName)
            return New-Object Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
        }
        finally { $tcp.Close() }
    }
    catch { return $null }
}

# Which CA key signed a certificate: its "authority key identifier" extension (2.5.29.35), as hex,
# equals the issuing CA's "subject key identifier". Comparing the two tells which of several CAs
# with similar names (the root, the current or a rotated intermediate) issued it. '' if none.
function Get-LabAuthorityKeyId($Certificate) {
    $extension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.35' }
    # DER: SEQUENCE { [0] keyIdentifier ... }; byte 2 is the tag 0x80, byte 3 its length.
    if (-not $extension -or $extension.RawData[2] -ne 0x80) { return '' }
    return -join ($extension.RawData[4..(3 + $extension.RawData[3])] | ForEach-Object { $_.ToString('X2') })
}

function Get-LabSubjectKeyId($Certificate) {
    return "$(($Certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension] }).SubjectKeyIdentifier)"
}

# What has to be renewed soon. Certificates expire, and a renewal only happens when the script
# that does it runs; lab.ps1 up (after every Windows restart) asks this function and
# runs the right script when something is due. Checked (all public, no login needed):
#   OpenBao's TLS certificate        30 days before it expires    lab.ps1 deploy vault
#   the root CA's revocation list    60 days before (lib\LabPki.ps1 renews it, and
#                                    lab.ps1 deploy vault publishes it on the vault VM); also
#                                    when the published copy differs from the PC's
#   the intermediate CA              400 days before              lab.ps1 deploy vault
#   Keycloak's TLS certificate       30 days before               lab.ps1 deploy keycloak
#   the firewall's GUI certificate   30 days before, and when it  lab.ps1 deploy firewall
#                                    is not from the current
#                                    intermediate (a new firewall
#                                    starts with one from the root)
# Not here: the Matrix certificates (Traefik renews them itself).
# Returns a list of @{ What; Action }: Action is the lab.ps1 command that renews it (Invoke-LabMaintenance
# in LabVault.ps1 runs it).
function Get-LabMaintenanceDue {
    $due = @()
    $now = Get-Date
    $vault = Get-LabServedCertificate ([Uri]$script:LabVaultUrl).Host ([Uri]$script:LabVaultUrl).Port
    if ($vault -and $vault.NotAfter -lt $now.AddDays(30)) {
        $due += @{ What = "OpenBao's TLS certificate (valid until $($vault.NotAfter.ToString('yyyy-MM-dd')))"; Action = @('deploy', 'vault') }
    }
    $openssl = Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe'
    $crl = Join-Path $script:LabKeysDir 'pki\crl\root-ca.crl.pem'
    if ((Test-Path $openssl) -and (Test-Path $crl)) {
        # "nextUpdate=Nov 28 01:15:44 2027 GMT": the date after which clients consider it stale.
        $line = "$(& $openssl crl -in $crl -noout -nextupdate 2>$null)" -replace '^nextUpdate=', '' -replace '\s+GMT$', '' -replace '\s+', ' '
        $nextUpdate = [datetime]::MinValue
        if ([datetime]::TryParseExact($line, 'MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture, 'AssumeUniversal', [ref]$nextUpdate) -and $nextUpdate -lt $now.AddDays(60)) {
            $due += @{ What = "the root CA's revocation list (next update $($nextUpdate.ToString('yyyy-MM-dd')))"; Action = @('deploy', 'vault') }
        }
    }
    # Renewed on the PC, but not published yet? lib\LabPki.ps1 also renews the CRL when it
    # signs something else (the first GUI certificate of a new firewall), and only lab.ps1 deploy
    # vault copies it to the vault VM. So the published copy is compared with this PC's (as bytes).
    $publishedCrl = Join-Path $script:LabKeysDir 'pki\pub\root-ca.crl'
    if (Test-Path $publishedCrl) {
        try {
            $served = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "http://vault.$($script:LabConfig.domain)/pki/root-ca.crl").RawContentStream.ToArray()
            if ([Convert]::ToBase64String($served) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes($publishedCrl))) {
                $due += @{ What = "the renewed root CA revocation list (not yet published on the vault VM)"; Action = @('deploy', 'vault') }
            }
        }
        catch { }
    }
    $intermediate = $null
    try {
        $pem = (Invoke-LabBao GET 'pki_int/cert/ca').data.certificate
        $intermediate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($pem))
        if ($intermediate.NotAfter -lt $now.AddDays(400)) {
            $due += @{ What = "the intermediate CA (valid until $($intermediate.NotAfter.ToString('yyyy-MM-dd')))"; Action = @('deploy', 'vault') }
        }
    }
    catch { }
    $firewall = Get-LabServedCertificate "firewall.$($script:LabConfig.domain)" 443
    if ($firewall -and $intermediate) {
        if ($firewall.NotAfter -lt $now.AddDays(30)) {
            $due += @{ What = "the firewall's GUI certificate (valid until $($firewall.NotAfter.ToString('yyyy-MM-dd')))"; Action = @('deploy', 'firewall') }
        }
        elseif ((Get-LabAuthorityKeyId $firewall) -ne (Get-LabSubjectKeyId $intermediate)) {
            $due += @{ What = "the firewall's GUI certificate (issued by $($firewall.Issuer -replace '^CN=', ''), not by the current intermediate)"; Action = @('deploy', 'firewall') }
        }
    }
    $keycloak = Get-LabServedCertificate "keycloak.$($script:LabConfig.domain)" 443
    if ($keycloak -and $keycloak.NotAfter -lt $now.AddDays(30)) {
        $due += @{ What = "Keycloak's TLS certificate (valid until $($keycloak.NotAfter.ToString('yyyy-MM-dd')))"; Action = @('deploy', 'keycloak') }
    }
    return , $due
}

# Runs $Script with the root CA key's passphrase in the environment variable LAB_CA_PASS, which
# openssl reads with "-passin env:LAB_CA_PASS". An environment variable, not a command-line
# argument: command lines of running processes are visible to other programs and can be logged
# by Windows. The variable is removed again afterwards.
function Use-LabRootCaPassphrase([scriptblock]$Script) {
    $env:LAB_CA_PASS = Unprotect-LabSecret 'pki/root-ca-passphrase'
    try { & $Script }
    finally { Remove-Item Env:LAB_CA_PASS -ErrorAction SilentlyContinue }
}

