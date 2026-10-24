<#
.SYNOPSIS
    The lab's recovery kit: OpenBao key share C (on paper or in your password manager), and an
    encrypted recovery file for a USB stick or a NAS. Run it YOURSELF, in your own PowerShell
    window: it shows secrets.

.DESCRIPTION
    WHY A RECOVERY KIT
    The PC's secrets are protected with DPAPI, i.e. by your Windows account (LabSecrets.ps1).
    If that account's keys are lost (Windows reinstalled, profile lost, password reset by an
    administrator), the .dpapi files cannot be decrypted any more - and OpenBao, which holds the
    lab's secrets, could neither be unsealed nor administered again. The kit covers that case
    without weakening the daily setup:

      share C         key share C, written down or kept in your password manager
      recovery file   key share B, the "break-glass" login for OpenBao (AppRole "recovery",
                      administrator rights, its secret only in this file), the root CA key
                      (still encrypted) with its passphrase, the root certificate, the
                      firewall's passwords and API key, and a fingerprint (SHA-256) of share C
                      that catches typing errors - all encrypted with a passphrase YOU choose
                      and remember (or keep in a third place)

    Any 2 of OpenBao's 3 key shares unseal it: normally A + B from DPAPI; after a loss, B (file)
    + C (your copy). Neither your copy of C nor the file alone is enough. This mirrors how
    enterprises keep "break-glass" material: split, offline, in different places. For the lab
    it is enough that share C and the recovery file are not stored together, and that neither
    depends on this Windows installation alone (a NAS or a second disk is fine; a safe is not
    required).

    WHAT THE SCRIPT DOES (create mode, the default)
      1. Shows key share C. You write it down (or copy it into your password manager); to
         confirm, you type its last 6 characters. The screen is cleared afterwards.
      2. Asks twice for a passphrase for the recovery file (at least 12 characters).
      3. Makes a new secret for the break-glass login (older ones stop working).
      4. Writes <Destination>\DeployableServer-recovery-<date>.bin: AES-256 encrypted, with an
         HMAC-SHA256 integrity check, key derived from the passphrase with PBKDF2 (600,000
         iterations). Decrypts it again to verify it, and shows its SHA-256 (note it next to
         share C: it identifies the right file).
      5. After you confirm, deletes the temporary DPAPI copy of share C from this PC.

    OTHER MODES
      -Renew            a new recovery file later (for example after using -Recover, or when the
                        passphrase should change), with a new break-glass secret. Your copy of
                        share C stays valid; it is not shown again.
      -Open <file>      decrypts a recovery file and shows share B, the root CA key's passphrase
                        and the firewall's root password.
      -Recover <file>   after losing this PC's DPAPI keys: puts the root CA passphrase, the
                        firewall's passwords and API key and key shares B and C (you type C,
                        checked against its fingerprint) back into DPAPI, restores the root CA
                        files if they are missing, unseals OpenBao if needed, logs in with the
                        break-glass login and issues NEW logins for the PC's scripts (pc-admin,
                        pc-deploy). Afterwards everything works as before; make a new kit with
                        -Renew (the break-glass secret was used).

.PARAMETER Destination
    Folder for the recovery file, e.g. a USB stick (E:\) or a NAS share
    (Z:\DeployableServer-recovery). The drive must exist; the folder is created. Default:
    keys\recovery on this PC (then copy the file somewhere else yourself: on this PC alone it
    does not survive a lost Windows installation).

.PARAMETER Renew
    Make a new recovery file (and break-glass secret) after the first one.

.PARAMETER Open
    Path of a recovery file to decrypt and show.

.PARAMETER Recover
    Path of a recovery file to restore this PC's access from (see OTHER MODES).

.EXAMPLE
    .\scripts\New-LabRecoveryKit.ps1 -Destination Z:\DeployableServer-recovery
    .\scripts\New-LabRecoveryKit.ps1 -Open Z:\DeployableServer-recovery\DeployableServer-recovery-2026-10-24.bin
    .\scripts\New-LabRecoveryKit.ps1 -Recover Z:\DeployableServer-recovery\DeployableServer-recovery-2026-10-24.bin
#>
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(ParameterSetName = 'Create')]
    [string]$Destination,
    [Parameter(ParameterSetName = 'Create')]
    [switch]$Renew,
    [Parameter(ParameterSetName = 'Open', Mandatory = $true)]
    [string]$Open,
    [Parameter(ParameterSetName = 'Recover', Mandatory = $true)]
    [string]$Recover
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')
Assert-LabInteractiveConsole 'New-LabRecoveryKit.ps1'

$magic = [Text.Encoding]::ASCII.GetBytes('DSLABRK1')

function ConvertFrom-SecureText([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# 64 bytes from the passphrase: 32 for AES-256, 32 for HMAC-SHA256 (separate keys).
function Get-Keys([string]$Passphrase, [byte[]]$Salt) {
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes -ArgumentList ([Text.Encoding]::UTF8.GetBytes($Passphrase)), $Salt, 600000, ([Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return , $kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function Protect-Bundle([string]$Json, [string]$Passphrase) {
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $salt = New-Object byte[] 16; $rng.GetBytes($salt)
    $keys = Get-Keys $Passphrase $salt
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys[0..31]; $aes.GenerateIV(); $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $plain = [Text.Encoding]::UTF8.GetBytes($Json)
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    [Array]::Clear($plain, 0, $plain.Length)
    $body = $magic + $salt + $aes.IV + $cipher
    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, [byte[]]$keys[32..63])
    $mac = $hmac.ComputeHash([byte[]]$body)
    return , ([byte[]]($body + $mac))
}

function Unprotect-Bundle([byte[]]$Data, [string]$Passphrase) {
    if ($Data.Length -lt 8 + 16 + 16 + 16 + 32 -or [Text.Encoding]::ASCII.GetString($Data, 0, 8) -ne 'DSLABRK1') { throw 'Not a DeployableServer recovery file.' }
    $salt = $Data[8..23]; $iv = $Data[24..39]
    $body = $Data[0..($Data.Length - 33)]; $mac = $Data[($Data.Length - 32)..($Data.Length - 1)]
    $keys = Get-Keys $Passphrase ([byte[]]$salt)
    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, [byte[]]$keys[32..63])
    $expected = $hmac.ComputeHash([byte[]]$body)
    if ([Convert]::ToBase64String($expected) -ne [Convert]::ToBase64String([byte[]]$mac)) { throw 'Wrong passphrase, or the file is damaged.' }
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys[0..31]; $aes.IV = $iv; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
    $cipher = [byte[]]$Data[40..($Data.Length - 33)]
    $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    return [Text.Encoding]::UTF8.GetString($plain)
}

function Read-RecoveryFile([string]$Path) {
    $pass = ConvertFrom-SecureText (Read-Host -AsSecureString 'Passphrase of the recovery file')
    # ProviderPath: a plain file system path also for \\nas\share\... (".Path" would carry a
    # PowerShell provider prefix that .NET rejects); -LiteralPath: "[" "]" are not wildcards.
    return Unprotect-Bundle ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)) $pass | ConvertFrom-Json
}

# SHA-256 (hex) of a text: the "fingerprint" of share C in the recovery file. It lets -Recover
# catch a typing error in the share you type in, and reveals nothing about the share (a random
# 256-bit value cannot be guessed back from its hash). Also kept on this PC in
# keys\openbao\unseal-c.sha256, so a renewed file carries it too.
function Get-TextSha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}
$shareCFingerprintFile = Join-Path $script:LabKeysDir 'openbao\unseal-c.sha256'

# --- Open mode ----------------------------------------------------------------------------------
if ($Open) {
    $content = Read-RecoveryFile $Open
    Write-Host ''
    Write-Host "Created:                   $($content.created)"
    Write-Host "OpenBao key share B:       $($content.openbao_unseal_share_b)"
    Write-Host "Root CA key passphrase:    $($content.root_ca_key_passphrase)"
    Write-Host "Firewall root password:    $($content.firewall_root_password)"
    Write-Host 'Root CA key and certificate, break-glass login, firewall API key: in the file (used by -Recover).'
    Write-Host 'Unseal with share B and your share C:            .\scripts\Unlock-LabVault.ps1 -Interactive'
    Write-Host 'Restore this PC''s access after losing DPAPI:    .\scripts\New-LabRecoveryKit.ps1 -Recover <file>'
    Read-Host 'Press Enter to clear the screen' | Out-Null
    Clear-Host
    return
}

# --- Recover mode -------------------------------------------------------------------------------
if ($Recover) {
    $content = Read-RecoveryFile $Recover
    if (-not $content.openbao_recovery_secret_id) { throw 'This recovery file has no break-glass login (made before it existed). Unseal with .\scripts\Unlock-LabVault.ps1 -Interactive; administering OpenBao then needs a token from elsewhere.' }
    $shareC = (ConvertFrom-SecureText (Read-Host -AsSecureString 'OpenBao key share C (from your copy)')).Trim()
    $shareCChecked = $false
    if ($content.openbao_unseal_share_c_sha256) {
        if ((Get-TextSha256 $shareC) -ne $content.openbao_unseal_share_c_sha256) { throw 'Share C does not match this recovery file (a typing error?). Nothing was changed.' }
        $shareCChecked = $true
    }

    # 1. The root CA: its files only if missing (an existing, different one is left alone, and
    #    then its passphrase is not replaced either: the file's passphrase belongs to its key).
    $pkiDir = Join-Path $script:LabKeysDir 'pki'
    New-Item -ItemType Directory -Force -Path $pkiDir | Out-Null
    $caKeyMatches = $true
    foreach ($file in @(@{ Name = 'root-ca.key'; Pem = $content.root_ca_key_pem }, @{ Name = 'root-ca.crt'; Pem = $content.root_ca_cert_pem })) {
        $path = Join-Path $pkiDir $file.Name
        if (-not (Test-Path $path)) { [IO.File]::WriteAllText($path, $file.Pem); Write-Host "Restored keys\pki\$($file.Name)" }
        elseif ([IO.File]::ReadAllText($path).Trim() -ne $file.Pem.Trim()) {
            Write-Warning "keys\pki\$($file.Name) differs from the one in the recovery file; it was left as it is."
            if ($file.Name -eq 'root-ca.key') { $caKeyMatches = $false }
        }
    }
    if ($caKeyMatches) { Protect-LabSecret 'pki/root-ca-passphrase' $content.root_ca_key_passphrase -Force }
    else { Write-Warning 'The root CA passphrase was not replaced: keys\pki\root-ca.key is a different key than the one in the file.' }

    # The firewall's secrets. A file made before the ansible password and API key were included
    # restores only the root password; the other two are then made new by the next firewall
    # build (New-LabFirewall.ps1 -Rebuild), and nothing else needs them.
    if ($content.firewall_root_password) { Protect-LabSecret 'opnsense/root-password' $content.firewall_root_password -Force }
    if ($content.firewall_ansible_password) { Protect-LabSecret 'opnsense/ansible-password' $content.firewall_ansible_password -Force }
    if ($content.firewall_api_ansible) { Protect-LabSecret 'opnsense/api-ansible' $content.firewall_api_ansible -Force }
    if (-not $content.firewall_api_ansible) { Write-Warning 'This file holds no firewall API key and ansible password; a firewall rebuild (.\scripts\New-LabFirewall.ps1 -Rebuild) makes new ones.' }

    # 2. OpenBao: unseal with B and C if it is sealed (after a restart of the vault VM). Two
    #    shares are needed, so a successful unseal also proves share C.
    $health = Wait-LabVaultReachable 60
    if ($health.sealed) {
        foreach ($share in $content.openbao_unseal_share_b, $shareC) {
            $state = Invoke-LabBao POST 'sys/unseal' @{ key = $share.Trim() }
            if (-not $state.sealed) { break }
        }
        if ((Get-LabVaultHealth).sealed) { throw 'OpenBao is still sealed: share B or C is wrong.' }
        Wait-LabVaultActive
        $shareCChecked = $true
        Write-Host 'OpenBao:     unsealed with shares B and C'
    }

    # 3. Break-glass login, then new everyday logins for the PC; the older ones stop working
    #    once the new ones are stored.
    $login = Invoke-LabBao POST 'auth/approle/login' @{ role_id = $content.openbao_recovery_role_id; secret_id = $content.openbao_recovery_secret_id }
    $token = $login.auth.client_token
    try {
        foreach ($role in 'pc-admin', 'pc-deploy') {
            $new = New-LabAppRoleSecret $role $token
            Protect-LabSecret "openbao/$role" (@{ role_id = $new.role_id; secret_id = $new.secret_id } | ConvertTo-Json -Compress) -Force
            Remove-LabAppRoleSecretIds $role $token $new.accessor
            $new = $null
            Write-Host "OpenBao:     new login for $role stored with DPAPI"
        }
    }
    finally { Close-LabBaoToken $token }

    # 4. Shares C and B become this PC's two shares (Unlock-LabVault uses them after every
    #    restart). B keeps its name, so a renewed recovery file again holds share B, and B (file)
    #    + C (your copy) stay two different shares.
    Protect-LabSecret 'openbao/unseal-a' $shareC -Force
    Protect-LabSecret 'openbao/unseal-b' $content.openbao_unseal_share_b -Force
    [IO.File]::WriteAllText($shareCFingerprintFile, (Get-TextSha256 $shareC))
    $pending = Get-LabSecretPath 'openbao/unseal-c-pending'
    if (Test-Path $pending) { Remove-Item -Force $pending }
    $content = $null; $shareC = $null
    if (-not $shareCChecked) {
        Write-Warning 'Share C could not be checked (OpenBao was unsealed already, and the file holds no fingerprint of C). It is checked at the next unseal, after a restart of the vault VM.'
    }
    Write-Host 'Done. This PC can unseal and administer OpenBao again.'
    Write-Host 'The break-glass secret has been used: make a new recovery file with  .\scripts\New-LabRecoveryKit.ps1 -Renew'
    return
}

# --- Create mode --------------------------------------------------------------------------------
if (-not $Renew -and -not (Test-LabSecret 'openbao/unseal-c-pending')) {
    throw 'Key share C is no longer on this PC (the kit was made already). For a new recovery file:  .\scripts\New-LabRecoveryKit.ps1 -Renew'
}
if (-not $Destination) { $Destination = Join-Path $script:LabKeysDir 'recovery' }
# Check the drive before anything secret is shown (a USB stick that is not plugged in).
$driveRoot = [IO.Path]::GetPathRoot($Destination)
if ($driveRoot -and -not (Test-Path -LiteralPath $driveRoot)) {
    throw "The drive $driveRoot does not exist (USB stick not plugged in?). Choose another folder, e.g. -Destination Z:\DeployableServer-recovery, or leave -Destination out for keys\recovery."
}
# The full path: .NET file functions resolve relative paths against the process's directory,
# which in Windows PowerShell 5.1 is not the current PowerShell location. Then a test write,
# before anything secret is shown (a write-protected stick, a read-only share).
$Destination = (New-Item -ItemType Directory -Force -Path $Destination).FullName
$probe = Join-Path $Destination ".write-test-$PID"
try { [IO.File]::WriteAllBytes($probe, [byte[]]@(0)); Remove-Item -LiteralPath $probe -Force }
catch { throw "Cannot write to $Destination ($($_.Exception.Message)). Nothing was changed." }

# Everything the file will hold, read now: if something is missing, the script stops here,
# before the break-glass login of an older recovery file is replaced.
function Get-OptionalSecret([string]$Name) { if (Test-LabSecret $Name) { return Unprotect-LabSecret $Name } return '' }
$bundleShareB = Unprotect-LabSecret 'openbao/unseal-b'
$bundleCaPassphrase = Unprotect-LabSecret 'pki/root-ca-passphrase'
$bundleCaKey = [IO.File]::ReadAllText((Join-Path $script:LabKeysDir 'pki\root-ca.key'))
$bundleCaCert = [IO.File]::ReadAllText((Join-Path $script:LabKeysDir 'pki\root-ca.crt'))
$bundleFirewallRoot = Get-OptionalSecret 'opnsense/root-password'
$bundleFirewallAnsible = Get-OptionalSecret 'opnsense/ansible-password'
$bundleFirewallApi = Get-OptionalSecret 'opnsense/api-ansible'

# 1. Share C, to write down (a renewed file does not need it: the file holds share B, and your
#    copy of C stays valid). Its fingerprint goes into the file and to keys\openbao.
$shareCFingerprint = ''
if (-not $Renew) {
    $shareC = Unprotect-LabSecret 'openbao/unseal-c-pending'
    $shareCFingerprint = Get-TextSha256 $shareC
    Clear-Host
    Write-Host 'OpenBao KEY SHARE C - write it down or put it in your password manager (case-sensitive):'
    Write-Host ''
    Write-Host ('    ' + (($shareC -split '(.{4})' | Where-Object { $_ }) -join ' '))
    Write-Host ''
    Write-Host 'Note with it: "DeployableServer OpenBao share C", the date, and later the SHA-256 shown at the end.'
    Write-Host 'The spaces are only there for reading (groups of 4); they are not part of the share.'
    # Spaces in the answer are ignored: the last 6 characters usually span two groups.
    do { $check = Read-Host 'To confirm, type the LAST 6 characters of the share (spaces do not matter)' } while (($check -replace '\s', '') -cne $shareC.Substring($shareC.Length - 6))
    Clear-Host
}
elseif (Test-Path $shareCFingerprintFile) { $shareCFingerprint = [IO.File]::ReadAllText($shareCFingerprintFile).Trim() }

# 2. Passphrase.
do {
    $p1 = ConvertFrom-SecureText (Read-Host -AsSecureString 'Passphrase for the recovery file (at least 12 characters)')
    $p2 = ConvertFrom-SecureText (Read-Host -AsSecureString 'Same passphrase again')
    if ($p1 -cne $p2) { Write-Host 'The two entries differ.' }
    elseif ($p1.Length -lt 12) { Write-Host 'Too short.' }
} while ($p1 -cne $p2 -or $p1.Length -lt 12)

# 3. A new secret for the break-glass login, 4. the file. Older break-glass secrets are destroyed
#    only after the new file is written and verified.
$file = Join-Path $Destination ("DeployableServer-recovery-{0}.bin" -f (Get-Date -Format 'yyyy-MM-dd'))
$token = Get-LabBaoToken 'pc-admin'
try {
    try { $recoveryLogin = New-LabAppRoleSecret 'recovery' $token }
    catch { throw "Could not make the break-glass login (AppRole 'recovery'); run .\scripts\Deploy-LabVault.ps1 once first. $($_.Exception.Message)" }
    $content = [ordered]@{
        created                       = (Get-Date).ToString('s')
        note                          = 'DeployableServer lab recovery file. Open with: .\scripts\New-LabRecoveryKit.ps1 -Open <file> (or -Recover <file>)'
        openbao_unseal_share_b        = $bundleShareB
        openbao_unseal_share_c_sha256 = $shareCFingerprint
        openbao_recovery_role_id      = $recoveryLogin.role_id
        openbao_recovery_secret_id    = $recoveryLogin.secret_id
        root_ca_key_passphrase        = $bundleCaPassphrase
        root_ca_key_pem               = $bundleCaKey
        root_ca_cert_pem              = $bundleCaCert
        firewall_root_password        = $bundleFirewallRoot
        firewall_ansible_password     = $bundleFirewallAnsible
        firewall_api_ansible          = $bundleFirewallApi
    } | ConvertTo-Json
    [IO.File]::WriteAllBytes($file, (Protect-Bundle $content $p1))
    $verify = Unprotect-Bundle ([IO.File]::ReadAllBytes($file)) $p1 | ConvertFrom-Json
    if ($verify.openbao_unseal_share_b -ne $bundleShareB -or $verify.openbao_recovery_secret_id -ne $recoveryLogin.secret_id) { throw 'Verification of the recovery file failed.' }
    Remove-LabAppRoleSecretIds 'recovery' $token $recoveryLogin.accessor
}
finally {
    Close-LabBaoToken $token
    $content = $null; $verify = $null; $recoveryLogin = $null
    $bundleShareB = $null; $bundleCaPassphrase = $null; $bundleFirewallRoot = $null; $bundleFirewallAnsible = $null; $bundleFirewallApi = $null
}
if ($shareCFingerprint) { [IO.File]::WriteAllText($shareCFingerprintFile, $shareCFingerprint) }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
Write-Host "Recovery file written and verified: $file"
Write-Host "SHA-256 (note it next to share C): $hash"
Write-Host 'Keep the file away from share C, and not only on this PC (USB stick, NAS).'
if ($Renew) {
    Write-Host 'Older recovery files can still unseal, but their break-glass login no longer works: keep only this one.'
    $p1 = $null; $p2 = $null
    return
}

# 5. Remove the temporary copy of share C.
do { $answer = Read-Host 'Have you stored share C and the recovery file safely? Type yes' } while ($answer -ne 'yes')
Remove-Item -Force (Get-LabSecretPath 'openbao/unseal-c-pending')
$shareC = $null; $p1 = $null; $p2 = $null
Write-Host 'Done. Share C is no longer on this PC; only your copy of it remains.'
