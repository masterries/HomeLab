<#
.SYNOPSIS
    One-time migration: moves the Keycloak and Matrix secrets from the old plain-text files into
    OpenBao, unchanged, and then removes the files from this PC.

.DESCRIPTION
    Before OpenBao, keycloak.yml and matrix-prepare.yml generated their secrets once into plain
    files (mode 0600) on ansible-control, and Deploy-LabKeycloak.ps1 / Deploy-LabMatrix.ps1 kept
    a backup in keys\keycloak\secrets.yml and keys\matrix\secrets.yml on this PC. The playbooks
    now read them from OpenBao instead (KV mount "lab"). This script copies every value there
    WITHOUT changing it: the existing Keycloak database, MDAD's derived keys and the users'
    passwords were all set up with exactly these values.

      keys\keycloak\secrets.yml                       OpenBao (lab/...)
        vault_keycloak_db_password                    keycloak/db                password
        vault_keycloak_admin_password                 keycloak/admin             password
        vault_keycloak_ansible_client_secret          keycloak/clients/lab-ansible  secret
        vault_mas_keycloak_client_secret              keycloak/clients/matrix-authentication-service  secret
        vault_keycloak_alice_password                 keycloak/users/alice       password
        vault_keycloak_bob_password                   keycloak/users/bob         password
      keys\matrix\secrets.yml
        vault_matrix_homeserver_generic_secret_key    matrix/generic-secret-key  value
        vault_postgres_connection_password            matrix/postgres            password
        vault_matrix_admin_password, ..._alice_...    matrix/legacy-users/...    password
                                                      (unused since MAS; kept, not lost)

    Safe order:
      1. The copies on ansible-control must be identical to the PC's (compared by SHA-256, the
         values are not shown).
      2. Each value is written with cas=0 (only if the secret does not exist yet). A secret that
         already exists is compared: the same value is fine, a DIFFERENT one stops the script and
         nothing is overwritten.
      3. An OpenBao snapshot is saved (Backup-LabVault.ps1), so the imported state is backed up.
      4. With -RemovePlaintext, and only when every value is in OpenBao: the two files are
         deleted from this PC. The copies on ansible-control are removed by the playbooks
         themselves on their next run (Deploy-LabKeycloak.ps1, Deploy-LabMatrix.ps1).

    Runs on the Windows host as your own user, with the pc-admin AppRole (DPAPI). Prints no
    secret. Running it again is harmless.

.PARAMETER RemovePlaintext
    Delete keys\keycloak\secrets.yml and keys\matrix\secrets.yml after a successful import.

.EXAMPLE
    .\scripts\Import-LabSecrets.ps1
    .\scripts\Import-LabSecrets.ps1 -RemovePlaintext
#>
[CmdletBinding()]
param(
    [switch]$RemovePlaintext
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

$sshConfig = Join-Path $script:LabKeysDir 'ssh_config'
$sources = @(
    @{
        File = Join-Path $script:LabKeysDir 'keycloak\secrets.yml'; Remote = 'keycloak-secrets/secrets.yml'
        Map  = [ordered]@{
            vault_keycloak_db_password           = 'keycloak/db|password'
            vault_keycloak_admin_password        = 'keycloak/admin|password'
            vault_keycloak_ansible_client_secret = 'keycloak/clients/lab-ansible|secret'
            vault_mas_keycloak_client_secret     = 'keycloak/clients/matrix-authentication-service|secret'
            vault_keycloak_alice_password        = 'keycloak/users/alice|password'
            vault_keycloak_bob_password          = 'keycloak/users/bob|password'
        }
    },
    @{
        File = Join-Path $script:LabKeysDir 'matrix\secrets.yml'; Remote = 'matrix-secrets/secrets.yml'
        Map  = [ordered]@{
            vault_matrix_homeserver_generic_secret_key = 'matrix/generic-secret-key|value'
            vault_postgres_connection_password         = 'matrix/postgres|password'
            # From the time before MAS, when Synapse had local accounts with passwords. Unused
            # since login goes through Keycloak, but kept rather than lost.
            vault_matrix_admin_password                = 'matrix/legacy-users/admin|password'
            vault_matrix_alice_password                = 'matrix/legacy-users/alice|password'
        }
    }
) | Where-Object { Test-Path $_.File }

if (-not $sources) {
    Write-Host 'Nothing to import: keys\keycloak\secrets.yml and keys\matrix\secrets.yml do not exist (any more).'
    return
}

# --- 1. ansible-control holds the same files ------------------------------------------------
foreach ($source in $sources) {
    $local = (Get-FileHash $source.File -Algorithm SHA256).Hash.ToLowerInvariant()
    $ErrorActionPreference = 'Continue'
    $remote = & ssh -F $sshConfig -o LogLevel=ERROR ansible-control "sha256sum ~/$($source.Remote) 2>/dev/null | cut -c1-64"
    $sshExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    # Exit code 0 without output: the file does not exist there (any more). Anything else means
    # the comparison could not be made - then nothing is imported.
    if ($sshExit -ne 0) { throw "Cannot reach ansible-control to compare ~/$($source.Remote) (ssh exit code $sshExit); nothing was imported." }
    if ($remote -and "$remote".Trim() -ne $local) {
        throw "~/$($source.Remote) on ansible-control differs from $($source.File). Find out which one is in use before importing (nothing was changed)."
    }
}

# --- 2. Into OpenBao ----------------------------------------------------------------------
# The values are letters and digits only (the old playbooks generated them that way).
$imported = 0
$token = Get-LabAdminToken
try {
    foreach ($source in $sources) {
        $values = @{}
        foreach ($line in [IO.File]::ReadAllLines($source.File)) {
            if ($line -match '^\s*(vault_[a-z0-9_]+):\s*"?([A-Za-z0-9]+)"?\s*$') { $values[$Matches[1]] = $Matches[2] }
        }
        foreach ($name in $source.Map.Keys) {
            $path, $field = $source.Map[$name] -split '\|'
            if (-not $values.ContainsKey($name)) { throw "$name is missing in $($source.File)." }
            $existing = Invoke-LabBao GET "lab/data/$path" -Token $token -AllowNotFound
            if ($existing) {
                if ($existing.data.data.$field -cne $values[$name]) {
                    throw "lab/$path already exists in OpenBao with a DIFFERENT value. Nothing was overwritten; decide which value is right first."
                }
                Write-Host "  lab/$path  already in OpenBao (same value)"
                continue
            }
            Invoke-LabBao POST "lab/data/$path" @{ options = @{ cas = 0 }; data = @{ $field = $values[$name] } } -Token $token | Out-Null
            $check = Invoke-LabBao GET "lab/data/$path" -Token $token
            if ($check.data.data.$field -cne $values[$name]) { throw "lab/$path could not be verified after writing." }
            Write-Host "  lab/$path  imported"
            $imported++
        }
        $values = $null
    }
}
finally { Close-LabBaoToken $token }

# --- 3. Snapshot ------------------------------------------------------------------------------
if ($imported -gt 0) { & (Join-Path $PSScriptRoot 'Backup-LabVault.ps1') }

# --- 4. Plain-text files on the PC -------------------------------------------------------------
if ($RemovePlaintext) {
    foreach ($source in $sources) {
        Remove-Item -Force $source.File
        $folder = Split-Path $source.File
        if (-not (Get-ChildItem $folder -Force)) { Remove-Item -Force $folder }
        Write-Host "Removed $($source.File)"
    }
    Write-Host 'The copies on ansible-control are removed by the next Deploy-LabKeycloak.ps1 / Deploy-LabMatrix.ps1.'
}
else {
    Write-Host 'All values are in OpenBao. Remove the plain-text files with:  .\scripts\Import-LabSecrets.ps1 -RemovePlaintext'
}
