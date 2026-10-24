<#
.SYNOPSIS
    Deploys (or updates) Keycloak, the lab's identity provider, on the lab VM "keycloak".

.DESCRIPTION
    Runs on the Windows host, in PowerShell, as your own Windows user (no administrator
    rights needed). Everything happens over SSH on ansible-control, like every other playbook.

    WHAT HAPPENS, IN ORDER
      1. Old plain-text secrets (keys\keycloak\secrets.yml, from before OpenBao) are imported
         into OpenBao unchanged, if that file still exists (Import-LabSecrets.ps1).
      2. ansible\playbooks\keycloak.yml (via Invoke-LabPlaybook.ps1, with a short-lived OpenBao
         token for this run): secrets from OpenBao (created there on the very first run), TLS
         certificate from OpenBao's intermediate CA, Docker on the VM, Keycloak + PostgreSQL
         with Docker Compose, then the realm "lab", the OIDC client for the Matrix
         Authentication Service and the users alice and bob, configured through Keycloak's
         admin API.
      3. A snapshot of OpenBao (Backup-LabVault.ps1): secrets created by a first deployment
         exist only in OpenBao, so they are backed up right away.

    The secrets live only in OpenBao (and where the running service needs them, on the Keycloak
    VM). To see one, for example alice's password:  .\scripts\Show-LabSecret.ps1 keycloak/users/alice

    Prerequisites: OpenBao is deployed (.\scripts\Deploy-LabVault.ps1). Run this BEFORE
    .\scripts\Deploy-LabMatrix.ps1: the Matrix stack sends its logins to Keycloak and needs the
    client secret created here. The firewall must publish keycloak (config\lab.json, applied by
    .\scripts\New-LabFirewall.ps1 -Rebuild).

    Safe to run repeatedly: every step is idempotent.

.EXAMPLE
    .\scripts\Deploy-LabKeycloak.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$lab = Get-Content -Raw (Join-Path $projectRoot 'config\lab.json') | ConvertFrom-Json

if (-not (Test-Path (Join-Path $projectRoot 'keys\ssh_config'))) {
    throw 'No SSH configuration found (keys\ssh_config). Run .\scripts\Initialize-Lab.ps1 first.'
}

# --- 1. Secrets from before OpenBao ----------------------------------------------------------
if (Test-Path (Join-Path $projectRoot 'keys\keycloak\secrets.yml')) {
    Write-Host '== 1/2 Secrets: importing keys\keycloak\secrets.yml into OpenBao (Import-LabSecrets.ps1) =='
    & (Join-Path $PSScriptRoot 'Import-LabSecrets.ps1')
}
else {
    Write-Host '== 1/2 Secrets: in OpenBao =='
}

# --- 2. The playbook -------------------------------------------------------------------------
Write-Host '== 2/2 Keycloak: secrets and certificate from OpenBao, Docker, containers, realm, client, users (keycloak.yml) =='
& (Join-Path $PSScriptRoot 'Invoke-LabPlaybook.ps1') keycloak.yml
$playbookExitCode = $LASTEXITCODE

# --- Snapshot of OpenBao ----------------------------------------------------------------------
# On a first deployment the playbook has just created the Keycloak secrets inside OpenBao, and
# OpenBao is now the only place they exist. A snapshot keeps them (Backup-LabVault.ps1, the
# newest 10 are kept), also when a later step of the playbook failed.
try { & (Join-Path $PSScriptRoot 'Backup-LabVault.ps1') }
catch { Write-Warning "OpenBao snapshot failed: $($_.Exception.Message)" }
if ($playbookExitCode -ne 0) { throw "keycloak.yml failed (exit code $playbookExitCode)." }

Write-Host ''
Write-Host "Keycloak is ready:  https://keycloak.$($lab.domain)/admin/  (admin console, user admin)"
Write-Host 'Lab users: alice and bob (realm lab). Passwords from OpenBao, copied to the clipboard:'
Write-Host '  .\scripts\Show-LabSecret.ps1 keycloak/users/alice     (keycloak/users/bob, keycloak/admin)'
Write-Host 'Next: .\scripts\Deploy-LabMatrix.ps1'
