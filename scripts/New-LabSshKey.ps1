<#
.SYNOPSIS
    Creates the lab SSH key pair in keys\ (ed25519, no passphrase).

.DESCRIPTION
    Runs on the Windows host, as your own Windows user. Initialize-Lab.ps1 calls it in its
    step 2; you can also run it by hand.

    How the key pair is used:
      - Public key (keys\ansible_ed25519.pub): Vagrant uploads it to the Ubuntu VMs, where
        provision\bootstrap-ansible-user.sh adds it to ~/.ssh/authorized_keys of the user
        "ansible"; New-LabFirewall.ps1 puts it into the firewall's configuration
        (config.xml) when it builds the firewall. With it you log in from the PC
        (Connect-Lab.ps1, Invoke-LabPlaybook.ps1).
      - Private key (keys\ansible_ed25519): stays on the PC for your logins and is also
        installed on ansible-control as ~ansible/.ssh/id_ed25519, so that Ansible can log
        in to the other VMs.
    The key comment "ansible@deployableserver-lab" marks the lab key: after a key rotation,
    bootstrap-ansible-user.sh uses it to replace the old lab key in authorized_keys and
    keeps all other entries.

    Safe to run repeatedly: an existing key is kept unless you pass -Force. After creating
    a new key with -Force, rebuild the firewall (.\scripts\New-LabFirewall.ps1 -Rebuild; it
    only reads the key when it builds), then run .\scripts\Initialize-Lab.ps1 (it provisions
    the Ubuntu VMs again) so that every VM gets the new key.

.PARAMETER Force
    Create a new key pair even if one exists (key rotation). The old key files are deleted.

.EXAMPLE
    .\scripts\New-LabSshKey.ps1
    .\scripts\New-LabSshKey.ps1 -Force   # create a new key (rotation)
#>
# LAB SHORTCUTS (and what an enterprise would do instead)
#   - No passphrase: scripts and Ansible can use the key unattended, but anyone who gets a
#     copy of the file can use it. Enterprise: passphrase-protected keys held in ssh-agent,
#     hardware-backed keys (FIDO2, smart card), or short-lived SSH certificates issued by an
#     SSH CA (for example HashiCorp Vault, Smallstep, Teleport).
#   - One key for everything: the same key serves your logins from the PC and Ansible's
#     logins from ansible-control, on every VM. Enterprise: a personal key per administrator
#     and a separate key for the automation account, kept in a secrets manager, so that each
#     can be revoked on its own and every login can be traced to a person or a system.
# keys\ is excluded from version control (.gitignore), so the private key is never committed.
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$keyDir = Join-Path $projectRoot 'keys'
$keyFile = Join-Path $keyDir 'ansible_ed25519'
# Do not change: bootstrap-ansible-user.sh finds the lab key in authorized_keys by it.
$keyComment = 'ansible@deployableserver-lab'

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw 'ssh-keygen not found. Please install the Windows feature "OpenSSH Client".'
}

if ((Test-Path $keyFile) -and -not $Force) {
    Write-Host "Key already exists: $keyFile (create a new one with -Force)"
}
else {
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    # Delete old key files first; otherwise ssh-keygen would ask interactively whether to
    # overwrite them.
    Remove-Item -Force -ErrorAction SilentlyContinue $keyFile, "$keyFile.pub"

    # Windows PowerShell 5.1 drops empty-string arguments when it calls native programs, so
    # ssh-keygen would take the next argument as the passphrase. '""' puts a literal pair of
    # double quotes on the command line, which ssh-keygen reads as an empty string.
    # PowerShell 7.3 and later pass '' correctly.
    $emptyPassphrase = '""'
    if ($PSVersionTable.PSVersion -ge [version]'7.3') { $emptyPassphrase = '' }

    # -q quiet, -t key type, -N passphrase, -C comment, -f output file (.pub is added
    # for the public key).
    & ssh-keygen -q -t ed25519 -N $emptyPassphrase -C $keyComment -f $keyFile
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed (exit code $LASTEXITCODE)." }
    Write-Host "New key created: $keyFile"
}

# --- Restrict access to the private key ---------------------------------------------------
# Windows OpenSSH, like OpenSSH on Linux, refuses a private key that other users can read.
# New files inherit the permissions of the project folder (here, for example, read access
# for the group CodexSandboxUsers). Therefore: /inheritance:r removes the inherited entries,
# /grant:r gives Full control to the current user only (replacing that user's existing
# grants), and /setowner makes the current user the owner. This is the Windows counterpart
# of "chmod 600": least privilege for a secret. It runs every time, also for an existing
# key, so permissions that have changed in the meantime are repaired.
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $keyFile /inheritance:r /grant:r "${me}:F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls (setting permissions) failed (exit code $LASTEXITCODE)." }
& icacls $keyFile /setowner $me | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls (setting owner) failed (exit code $LASTEXITCODE)." }

# --- Restrict access to the keys folder itself --------------------------------------------
# keys\ holds the lab's secrets on the PC: this key, the offline root CA (keys\pki, its key
# encrypted), the DPAPI-encrypted secrets (keys\opnsense, keys\openbao, LabSecrets.ps1) and
# OpenBao's snapshots. Locking
# single files is not enough: a new file inherits the folder's permissions until a script
# locks it, and the subfolders would stay readable for everyone who can read the project
# folder. So the folder gets the same treatment as the key: no inherited entries; Full control
# for you and for SYSTEM (Windows services such as backup and antivirus run as SYSTEM;
# "*S-1-5-18" is its language-independent SID, the display name is localized), passed on to
# everything inside: (OI) object inherit = files, (CI) container inherit = subfolders.
# Windows pushes the new entries down to existing subfolders and files automatically; files a
# script locked explicitly (inheritance removed) keep their own, stricter list.
& icacls $keyDir /inheritance:r /grant:r "${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls (keys folder) failed (exit code $LASTEXITCODE)." }

Write-Host "Public key:"
Get-Content "$keyFile.pub"
