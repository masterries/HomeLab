<#
.SYNOPSIS
    Upgrades matrix-docker-ansible-deploy (MDAD) in this repository, vendor\mdad, to another
    upstream commit, with git subtree. The only script that downloads MDAD; deployments never do.

.DESCRIPTION
    Everything the lab executes is in this repository (vendor\README.md). MDAD - the playbook
    that installs the Matrix stack - lives in vendor\mdad as a "git subtree": its files are
    ordinary files of this repository, and the subtree commits record which upstream commit
    they came from, so the link to the source stays. An upgrade is two commits you can review:

      1. git subtree pull: Git fetches the upstream commit from
         https://github.com/spantaleev/matrix-docker-ansible-deploy and merges the changes into
         vendor\mdad ("--squash": one commit that summarises all upstream commits since the last
         pull, instead of copying MDAD's whole history into this repository).
      2. The roles: MDAD's external roles are not in its repository; its requirements.yml pins
         them (most by Git tag). On ansible-control (it has Ansible and internet access through
         the firewall) ansible-galaxy installs exactly those versions, the result replaces
         vendor\mdad\roles\galaxy, and it is committed with "git add -f" - MDAD's own .gitignore
         ignores roles/galaxy, because upstream installs them on demand; here they are tracked.
         The marker vendor\mdad\.lab-vendored-commit is updated in the same commit.

    Then, before deploying (the script prints this list again):
      - review the change: git show --stat HEAD~1 HEAD, and read vendor\mdad\CHANGELOG.md for
        everything since the old commit,
      - set mdad_version in ansible\playbooks\matrix-prepare.yml to the new commit,
      - raise matrix_playbook_migration_validated_version in
        ansible\matrix\inventory\host_vars\matrix.lab.internal\vars.yml as the CHANGELOG says,
      - commit those two lines, run .\scripts\Deploy-LabMatrix.ps1 (with -Setup if the CHANGELOG
        says components were removed or renamed), then push.
    Deploy-LabMatrix.ps1 refuses to run while vendor\mdad and mdad_version differ. To go back,
    revert the commits (git revert) and deploy again.

    Needs: this folder is a Git repository with no uncommitted changes (git subtree requires a
    clean working tree), and Git for Windows. Commits are made with your Git identity.

.PARAMETER Commit
    The full commit hash (40 hex characters) of MDAD's master branch to move to. Find it at
    https://github.com/spantaleev/matrix-docker-ansible-deploy/commits/master

.EXAMPLE
    .\scripts\Update-LabMdad.ps1 -Commit 0123456789abcdef0123456789abcdef01234567
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Commit
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$upstream = 'https://github.com/spantaleev/matrix-docker-ansible-deploy.git'
# LabSecrets.ps1 with LabSsh.ps1: Get-LabSshConfig renews the PC's SSH certificate when it is due.
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')
$sshConfig = Get-LabSshConfig
$galaxyDir = Join-Path $projectRoot 'vendor\mdad\roles\galaxy'
$archive = Join-Path ([IO.Path]::GetTempPath()) 'lab-mdad-roles.tgz'
$short = $Commit.Substring(0, 7)
if (-not (Test-Path $sshConfig)) { throw "No SSH configuration ($sshConfig). Run .\scripts\Initialize-Lab.ps1 first." }

# Git and ssh write progress to stderr; only the exit code decides.
function Invoke-Git {
    $ErrorActionPreference = 'Continue'
    & git -C $projectRoot @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args[0]) failed (exit code $LASTEXITCODE)." }
}
function Invoke-ControlSsh([string]$Command, [string]$What) {
    $ErrorActionPreference = 'Continue'
    & ssh -F $sshConfig -o LogLevel=ERROR ansible-control "{ $Command; } 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "$What failed on ansible-control (exit code $LASTEXITCODE)." }
}

if (-not (Test-Path (Join-Path $projectRoot '.git'))) { throw 'This folder is not a Git repository (vendor\mdad is a git subtree).' }
$dirty = & git -C $projectRoot status --porcelain
if ($dirty) { throw 'There are uncommitted changes. Commit or stash them first (git subtree needs a clean working tree).' }

# --- 1. MDAD itself: git subtree pull ----------------------------------------------------------
Write-Host "== 1/2 MDAD $short from GitHub into vendor\mdad (git subtree pull --squash) =="
Invoke-Git subtree pull --prefix vendor/mdad $upstream $Commit --squash -m "Update MDAD (vendor/mdad) to $short"

# --- 2. The roles at the versions in the new requirements.yml ------------------------------------
Write-Host "== 2/2 MDAD's roles from requirements.yml (ansible-galaxy on ansible-control) =="
$ErrorActionPreference = 'Continue'
Invoke-ControlSsh 'rm -rf /tmp/lab-mdad-roles && mkdir -p /tmp/lab-mdad-roles' 'Preparing'
& scp -q -F $sshConfig -o LogLevel=ERROR (Join-Path $projectRoot 'vendor\mdad\requirements.yml') 'ansible-control:/tmp/lab-mdad-roles/requirements.yml'
if ($LASTEXITCODE -ne 0) { throw "Copying requirements.yml failed (exit code $LASTEXITCODE)." }
# tar -h: symbolic links in a role are stored as the files they point to.
Invoke-ControlSsh 'set -e; cd /tmp/lab-mdad-roles; ansible-galaxy install -r requirements.yml -p galaxy/ --force; tar -czhf /tmp/lab-mdad-roles.tgz -C galaxy .' 'Installing the roles'
& scp -q -F $sshConfig -o LogLevel=ERROR 'ansible-control:/tmp/lab-mdad-roles.tgz' $archive
if ($LASTEXITCODE -ne 0) { throw "Copying the roles from ansible-control failed (exit code $LASTEXITCODE)." }
Invoke-ControlSsh 'rm -rf /tmp/lab-mdad-roles /tmp/lab-mdad-roles.tgz' 'Cleaning up'
$ErrorActionPreference = 'Stop'
try {
    # Everything below roles/galaxy except MDAD's own placeholder file is replaced.
    Get-ChildItem $galaxyDir -Force | Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Recurse -Force
    & tar -xzf $archive -C $galaxyDir
    if ($LASTEXITCODE -ne 0) { throw "Unpacking the roles failed (exit code $LASTEXITCODE)." }
}
finally { Remove-Item -Force -ErrorAction SilentlyContinue $archive }
[IO.File]::WriteAllText((Join-Path $projectRoot 'vendor\mdad\.lab-vendored-commit'), "$Commit`n")
Invoke-Git add -f -A vendor/mdad/roles/galaxy vendor/mdad/.lab-vendored-commit
Invoke-Git commit -q -m "Update MDAD's external roles (vendor/mdad/roles/galaxy) for $short" -m "Installed with ansible-galaxy at the versions pinned in vendor/mdad/requirements.yml of MDAD $Commit."

$roles = @(Get-ChildItem $galaxyDir -Directory).Count
Write-Host "vendor\mdad is now MDAD $Commit with $roles roles (two new commits)."
Write-Host ''
Write-Host 'Before deploying:'
Write-Host '  1. Review: git show --stat HEAD~1 HEAD, and read vendor\mdad\CHANGELOG.md since the old commit.'
Write-Host "  2. Set mdad_version in ansible\playbooks\matrix-prepare.yml to $Commit."
Write-Host '  3. Raise matrix_playbook_migration_validated_version in ansible\matrix\inventory\host_vars\matrix.lab.internal\vars.yml as the CHANGELOG says.'
Write-Host '  4. Commit those two lines, then .\scripts\Deploy-LabMatrix.ps1   (with -Setup if components were removed or renamed)'
Write-Host '  5. git push'
