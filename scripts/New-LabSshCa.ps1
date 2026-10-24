<#
.SYNOPSIS
    Creates the lab's offline SSH certificate authority and this PC's SSH key in keys\ssh (once),
    and restricts access to keys\.

.DESCRIPTION
    Runs on the Windows host, as your own Windows user. Initialize-Lab.ps1 calls it in its step 2;
    running it again changes nothing that exists (it never replaces a CA or a key).

    What it creates (scripts\LabSsh.ps1 explains how they are used):
      keys\ssh\offline-ca(.pub)    the offline SSH CA: an ed25519 key, encrypted with a random
                                   48-character passphrase that is stored with DPAPI
                                   (keys\ssh\offline-ca-passphrase.dpapi). It signs while OpenBao
                                   does not exist yet, and on request when OpenBao is broken.
                                   Every lab machine trusts it permanently.
      keys\ssh\pc_ed25519(.pub)    this PC's SSH key. It has no passphrase, but alone it opens
                                   nothing: logins need a certificate for it, valid 8 hours
                                   (Get-LabSshConfig in LabSsh.ps1 renews it).
      keys\ssh\revoked_host_keys   the revocation list (KRL) for host keys, empty at first. It must
                                   exist before ssh is told to read it (RevokedHostKeys).
      keys\ssh\hosts\              the verified host keys of the lab machines and their
                                   certificates

    After a NEW offline CA, add it to your recovery file (in your own PowerShell window):
        .\scripts\New-LabRecoveryKit.ps1 -Renew

.EXAMPLE
    .\scripts\New-LabSshCa.ps1
#>
# THREAT MODEL, BRIEFLY
#   - Someone who copies files from keys\ (a backup, a disk image) gets the encrypted CA key
#     (useless without the DPAPI-protected passphrase) and at most the remaining hours of the
#     PC's certificate, usable only from the PC's own addresses (source-address).
#   - Code that runs as you can decrypt DPAPI, so it can sign with the offline CA and log in to
#     OpenBao as pc-deploy: the same power the old lab key gave, but every login now shows key ID,
#     serial and CA in the target's SSH log, and certificates expire.
#   - Offline signing passes the CA passphrase to ssh-keygen on its command line (-P; OpenSSH 8.1
#     has no other unattended way). Programs running as you or as an administrator can see it
#     while ssh-keygen runs, and Windows logs it if "Include command line in process creation
#     events" is switched on - this script warns about that setting.
# Enterprise equivalent: the offline CA would live in an HSM or on an air-gapped machine, and
# people would get their certificates from an online CA after an SSO login with MFA.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

if (-not (Test-Path $script:LabSshKeygen)) {
    throw "$script:LabSshKeygen not found. Please install the Windows feature ""OpenSSH Client""."
}
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# --- Restrict access to the keys folder itself --------------------------------------------
# keys\ holds the lab's secrets on the PC: the SSH CA and key (keys\ssh), the offline root CA
# (keys\pki, its key encrypted), the DPAPI-encrypted secrets (keys\opnsense, keys\openbao,
# LabSecrets.ps1) and OpenBao's snapshots. Locking single files is not enough: a new file
# inherits the folder's permissions until a script locks it, and the subfolders would stay
# readable for everyone who can read the project folder. So the folder gets no inherited
# entries; Full control for you and for SYSTEM (Windows services such as backup and antivirus run
# as SYSTEM; "*S-1-5-18" is its language-independent SID, the display name is localized), passed
# on to everything inside: (OI) object inherit = files, (CI) container inherit = subfolders.
# Windows pushes the new entries down to existing subfolders and files automatically; files a
# script locked explicitly (inheritance removed) keep their own, stricter list.
New-Item -ItemType Directory -Force -Path $script:LabSshHostsDir | Out-Null
& icacls $script:LabKeysDir /inheritance:r /grant:r "${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls (keys folder) failed (exit code $LASTEXITCODE)." }

# Windows OpenSSH, like OpenSSH on Linux, refuses a private key that other users can read. This
# is the Windows counterpart of "chmod 600": no inherited entries, Full control for you only,
# and you as the owner. Runs every time, so permissions that changed in the meantime are
# repaired.
function Protect-LabSshKeyFile([string]$Path) {
    & icacls $Path /inheritance:r /grant:r "${me}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls (setting permissions on $Path) failed (exit code $LASTEXITCODE)." }
    & icacls $Path /setowner $me | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls (setting the owner of $Path) failed (exit code $LASTEXITCODE)." }
}

# Windows PowerShell 5.1 drops empty-string arguments when it calls native programs, so
# ssh-keygen would take the next argument as the passphrase. '""' puts a literal pair of double
# quotes on the command line, which ssh-keygen reads as an empty string. PowerShell 7.3 and
# later pass '' correctly.
$emptyPassphrase = '""'
if ($PSVersionTable.PSVersion -ge [version]'7.3') { $emptyPassphrase = '' }

# --- The offline SSH CA -------------------------------------------------------------------------
if (Test-Path $script:LabSshOfflineCa) {
    if (-not (Test-LabSecret 'ssh/offline-ca-passphrase')) {
        throw 'keys\ssh\offline-ca exists, but its passphrase (keys\ssh\offline-ca-passphrase.dpapi) does not. Restore it with .\scripts\New-LabRecoveryKit.ps1 -Recover <file>.'
    }
    Write-Host "SSH CA:      offline CA $(Get-LabSshOfflineCaFingerprint) (keys\ssh\offline-ca)"
}
else {
    # -a 100: 100 rounds of bcrypt to derive the encryption key from the passphrase (slows down
    # guessing; the passphrase is random anyway). The passphrase goes to ssh-keygen through
    # .NET's Process class, so PowerShell's own logging never sees it.
    $pass = New-LabRandomText 48
    Protect-LabSecret 'ssh/offline-ca-passphrase' $pass -Force
    # Properties, not New-Object arguments: module logging would record those (LabSsh.ps1).
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
    Write-Host '             Add it to your recovery file, in your own PowerShell window:  .\scripts\New-LabRecoveryKit.ps1 -Renew'
}
Protect-LabSshKeyFile $script:LabSshOfflineCa

# --- This PC's key ------------------------------------------------------------------------------
if (-not (Test-Path $script:LabSshPcKey)) {
    Remove-Item -Force -ErrorAction SilentlyContinue "$($script:LabSshPcKey).pub", "$($script:LabSshPcKey)-cert.pub", $script:LabSshPcCertInfo
    & $script:LabSshKeygen -q -t ed25519 -N $emptyPassphrase -C 'pc@deployableserver-lab' -f $script:LabSshPcKey
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen could not create keys\ssh\pc_ed25519 (exit code $LASTEXITCODE)." }
    Write-Host 'SSH:         new key for this PC (keys\ssh\pc_ed25519; it needs a certificate to log in)'
}
Protect-LabSshKeyFile $script:LabSshPcKey

# --- The host key revocation list ---------------------------------------------------------------
if (-not (Test-Path $script:LabSshKrl)) {
    & $script:LabSshKeygen -q -k -f $script:LabSshKrl
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen could not create keys\ssh\revoked_host_keys (exit code $LASTEXITCODE)." }
}

# "Include command line in process creation events" (Group Policy: Administrative Templates >
# System > Audit Process Creation). With it, Windows writes the command line of every new process
# into the Security event log - for offline signatures that would include the CA passphrase.
$audit = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -Name 'ProcessCreationIncludeCmdLine_Enabled' -ErrorAction SilentlyContinue
if ($audit -and $audit.ProcessCreationIncludeCmdLine_Enabled -eq 1) {
    Write-Warning 'Windows logs the command lines of new processes (ProcessCreationIncludeCmdLine_Enabled = 1): offline SSH signatures put the offline CA passphrase into the Security event log.'
}
