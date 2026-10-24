<#
.SYNOPSIS
    Deploys (or updates) a service of the lab: .\lab.ps1 deploy vault | keycloak | matrix | all

.DESCRIPTION
    Runs on the Windows host, as your own Windows user (no administrator rights needed). The work
    happens on ansible-control (Ansible, lib\LabRun.ps1); only OpenBao's bootstrap and identities
    need the PC (DPAPI, the offline root CA).

    vault      OpenBao on the VM "vault": the lab's secrets manager, its intermediate CA and its SSH
               CA (lib\LabVault.ps1, Invoke-LabVaultDeploy). First of all services: everything else
               gets its secrets and certificates from it.
    keycloak   Keycloak, the identity provider (ansible\playbooks\keycloak.yml, profile "keycloak"):
               secrets from OpenBao (created there on the very first run), TLS certificate from
               OpenBao's intermediate CA, Docker, Keycloak + PostgreSQL, then the realm "lab", the
               OIDC client for the Matrix Authentication Service and the users alice and bob.
               Before matrix: the Matrix stack needs the client secret created here.
    matrix     The Matrix stack on the VM "matrix" with matrix-docker-ansible-deploy (MDAD, vendored
               in vendor\mdad): first ansible\playbooks\matrix-prepare.yml (profile
               "matrix-prepare": MDAD's code copied to ~/mdad, lab root trusted, checks, the lab's
               MDAD inventory, the Matrix secrets in OpenBao), then ansible\bin\deploy-matrix
               (profile "matrix": MDAD's "install-all", its self-check, mas-cli doctor and
               ansible\playbooks\matrix-check.yml). Nothing is downloaded from GitHub.
    all        vault, keycloak, matrix - in that order, stopping at the first failure.

    A snapshot of OpenBao follows every keycloak and matrix run (also after a failure): secrets
    created by a first deployment exist only in OpenBao.

    Prerequisites: the lab is up (.\lab.ps1 up), and the firewall publishes the services
    ("published" in config\lab.json). Safe to run repeatedly: every step is idempotent.

.PARAMETER Target
    vault, keycloak, matrix or all.

.PARAMETER RotateIntermediate
    vault: make a new intermediate CA now (see Invoke-LabVaultDeploy).

.PARAMETER Setup
    matrix: run MDAD's "setup-all" instead of "install-all" - needed after REMOVING a component
    from vars.yml (install-all skips uninstall tasks and is 2-5x faster otherwise).

.EXAMPLE
    .\lab.ps1 deploy all
    .\lab.ps1 deploy matrix -Setup
#>
# WHY MDAD, AND WHY PINNED
# A Matrix server with calls is a dozen cooperating services. MDAD is a widely used,
# community-maintained Ansible playbook that knows how to install and wire them; writing all of
# that ourselves would be a project of its own. The lab treats it like any third-party dependency:
# one exact version (git commit, vendored in vendor\mdad, mdad_version in matrix-prepare.yml), our
# own configuration in our repository (ansible\matrix\), and upgrades as deliberate, reviewed
# changes (.\lab.ps1 mdad-upgrade). Enterprise equivalent: vendored or pinned automation, promoted
# through test environments.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('vault', 'keycloak', 'matrix', 'all')]
    [string]$Target,
    [switch]$RotateIntermediate,
    [switch]$Setup
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Lab.ps1')
$domain = $script:LabConfig.domain

# One run, then a snapshot of OpenBao in any case; a failed run stops the deployment.
function Invoke-LabDeployRun([string]$RunName, [string]$What) {
    Invoke-LabRun $RunName
    $code = $LASTEXITCODE
    try { Backup-LabOpenBao }
    catch { Write-Warning "OpenBao snapshot failed: $($_.Exception.Message)" }
    if ($code -ne 0) { throw "$What failed on ansible-control (exit code $code)." }
}

function Deploy-LabKeycloak {
    Write-Host '== Keycloak: secrets and certificate from OpenBao, Docker, containers, realm, client, users (keycloak.yml) =='
    Invoke-LabDeployRun 'keycloak' 'keycloak.yml'
    Write-Host ''
    Write-Host "Keycloak is ready:  https://keycloak.$domain/admin/  (admin console, user admin)"
    Write-Host 'Lab users: alice and bob (realm lab). Passwords from OpenBao, copied to the clipboard:'
    Write-Host '  .\lab.ps1 secret keycloak/users/alice     (keycloak/users/bob, keycloak/admin)'
}

function Deploy-LabMatrix {
    # The pinned commit must be the same in vendor\mdad\.lab-vendored-commit and in
    # matrix-prepare.yml (mdad_version), or the wrong configuration could meet the wrong code.
    $vendoredCommit = (Get-Content -Raw (Join-Path $script:LabProjectRoot 'vendor\mdad\.lab-vendored-commit')).Trim()
    $prepareText = Get-Content -Raw (Join-Path $script:LabProjectRoot 'ansible\playbooks\matrix-prepare.yml')
    $pinnedCommit = [regex]::Match($prepareText, '(?m)^\s*mdad_version:\s*(\S+)').Groups[1].Value
    if ($vendoredCommit -ne $pinnedCommit) {
        throw "vendor\mdad holds MDAD $vendoredCommit, but matrix-prepare.yml pins $pinnedCommit. Make them the same (see vendor\README.md, Upgrade)."
    }
    Write-Host "== Matrix 1/2: MDAD $($vendoredCommit.Substring(0, 7)) to ~/mdad, CA trust, checks, inventory, secrets (matrix-prepare.yml) =="
    Invoke-LabDeployRun 'matrix-prepare' 'matrix-prepare.yml'
    $runName = if ($Setup) { 'matrix-setup' } else { 'matrix' }
    Write-Host "== Matrix 2/2: MDAD, its self-check, mas-cli doctor and matrix-check.yml (bin/deploy-matrix; the first run downloads the images and takes a while) =="
    Invoke-LabDeployRun $runName 'The Matrix deployment'
    Write-Host 'alice may use Matrix admin tools (MAS policy admin_users).'
}

switch ($Target) {
    'vault' { Invoke-LabVaultDeploy -RotateIntermediate:$RotateIntermediate }
    'keycloak' { Deploy-LabKeycloak }
    'matrix' { Deploy-LabMatrix }
    'all' {
        Invoke-LabVaultDeploy -RotateIntermediate:$RotateIntermediate
        Deploy-LabKeycloak
        Deploy-LabMatrix
    }
}
