<#
.SYNOPSIS
    Copies the Ansible project (ansible\) to ansible-control and runs a playbook there.

.DESCRIPTION
    Runs on the Windows host, in PowerShell, as your own Windows user. It reaches the lab
    only over SSH, with keys\ssh_config from Initialize-Lab.ps1: ansible-control is reached
    through the firewall VM as jump host. Initialize-Lab.ps1 calls this script at the end
    with ping.yml to test that Ansible can reach every VM.

    The repository is the source of truth: every call replaces ~/lab on ansible-control
    completely with the current contents of ansible\. Edit playbooks here in the
    repository, not on the VM; changes made on the VM are lost on the next call.

    It also copies the PUBLIC files of the lab's PKI (the root CA certificate and its
    revocation list, keys\pki) to ~/lab-pki, where the playbooks find them.

    Playbooks that read secrets from OpenBao (keycloak.yml, matrix-prepare.yml) get a
    short-lived OpenBao token for exactly this run, with only the policy they need (see
    $openBaoPolicies below and ansible\bin\openbao-run). If OpenBao is sealed (after a restart
    of the vault VM), it is unsealed first, with the key shares stored on this PC.

    Further arguments after the playbook name are passed on to ansible-playbook, for
    example --check --diff or -v.

    Safe to run repeatedly. Whether a run changes anything on the VMs depends on the
    playbook: Ansible modules are designed to be idempotent, i.e. they only change what
    differs from the desired state and report "ok" otherwise.

.PARAMETER Playbook
    File name of a playbook in ansible\playbooks, for example ping.yml. (keycloak.yml and
    matrix-prepare.yml are normally run by Deploy-LabKeycloak.ps1 and Deploy-LabMatrix.ps1.)

.EXAMPLE
    .\scripts\Invoke-LabPlaybook.ps1 ping.yml
    .\scripts\Invoke-LabPlaybook.ps1 ping.yml -v
#>
# WHAT HAPPENS, IN ORDER
#   1. Pack ansible\ into a .tgz archive on the PC and copy it to ansible-control (scp).
#   2. Copy the public PKI files (keys\pki) to ~/lab-pki on ansible-control.
#   3. On ansible-control: unpack into ~/lab.new, then swap it in place of ~/lab.
#   4. Run ansible-playbook on ansible-control; it connects to the other VMs over SSH. A
#      playbook listed in $openBaoPolicies runs with a run token (see "OPENBAO" below).
#
# PATTERN: "THE REPOSITORY IS THE SOURCE OF TRUTH, THE CONTROL NODE GETS A FRESH COPY"
# This follows the idea behind GitOps and infrastructure as code: the desired state of the
# lab lives in version-controlled files, and the machine that applies it keeps no state of
# its own that could drift. Because ~/lab is replaced rather than merged, files deleted in
# the repository also disappear on the VM, and a quick fix made directly on the VM cannot
# silently survive. The control node itself is disposable: rebuild it, run this script, and
# it has exactly the same project again.
# Enterprise equivalent: the control node (or AWX / Ansible Automation Platform, or a CI/CD
# runner) checks out a specific commit from a Git server before every run, so each run can
# be traced to a reviewed change. The lab has no Git server, so it pushes an archive.
#
# Deliberately a plain script WITHOUT [CmdletBinding()]: an "advanced" script would treat
# -v as its own -Verbose parameter instead of passing it on to ansible-playbook. A plain
# script puts every argument that is not bound to $Playbook into $args, which is forwarded.
param(
    [string]$Playbook
)

# 'Stop' turns PowerShell errors into terminating errors. In Windows PowerShell 5.1 it does
# not react to the exit codes of native programs (tar, scp, ssh, icacls), so the script
# checks $LASTEXITCODE itself after each native call whose failure matters.
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$ansibleDir = Join-Path $projectRoot 'ansible'
$sshConfig = Join-Path $projectRoot 'keys\ssh_config'
$controlHost = 'ansible-control'
# OPENBAO: which playbooks read secrets from OpenBao, and with which policies (defined in
# Deploy-LabVault.ps1). Least privilege per run: keycloak.yml cannot read Matrix's secrets and
# matrix-prepare.yml can only read (not create) Keycloak's client secret for MAS.
$openBaoPolicies = @{
    'keycloak.yml'       = @('ansible-keycloak')
    'matrix-prepare.yml' = @('ansible-matrix')
    'hello-nginx.yml'    = @('ansible-web')
}

if (-not $Playbook) {
    throw 'Usage: .\scripts\Invoke-LabPlaybook.ps1 <playbook.yml> [options for ansible-playbook]'
}
if (-not (Test-Path (Join-Path $ansibleDir "playbooks\$Playbook"))) {
    throw "Playbook not found: ansible\playbooks\$Playbook"
}
if (-not (Test-Path $sshConfig)) {
    throw "No SSH configuration found ($sshConfig). Run .\scripts\Initialize-Lab.ps1 first."
}

# --- 1. Pack the Ansible project and copy it to ansible-control ---------------------------
# tar.exe is part of Windows 10 (version 1803 and later). A single archive needs only one
# scp call and keeps the folder structure. scp reads keys\ssh_config, so the copy travels
# through the firewall (ProxyJump) like every other SSH connection into the lab.
# -o LogLevel=ERROR hides informational ssh messages on stderr (for example "Permanently
# added ... to the list of known hosts"); see the note on stderr in step 4.
$archive = Join-Path ([IO.Path]::GetTempPath()) 'lab-ansible.tgz'
& tar -czf $archive -C $ansibleDir .
if ($LASTEXITCODE -ne 0) { throw "tar failed (exit code $LASTEXITCODE)." }
try {
    & scp -q -F $sshConfig -o LogLevel=ERROR $archive "${controlHost}:/tmp/lab-ansible.tgz"
    if ($LASTEXITCODE -ne 0) { throw "Copying to $controlHost failed (exit code $LASTEXITCODE)." }
}
finally {
    # The local archive is only a transport container; remove it even if the copy failed.
    Remove-Item -Force -ErrorAction SilentlyContinue $archive
}

# --- 2. Public files of the lab's PKI (keys\pki) ------------------------------------------
# Internal PKI in short: the lab runs its own certificate authorities. Windows is told once to
# trust the root certificate (Install-LabRootCA.ps1); from then on, browsers that use the
# Windows certificate store (Edge, Chrome; for Firefox see Install-LabRootCA.ps1) accept every
# certificate issued below it for a *.lab.internal name without a warning. The root CA lives
# only on the PC, its key encrypted (New-LabRootCA.ps1); the everyday certificates come from the
# intermediate CA inside OpenBao.
# Only PUBLIC files go to ansible-control: the root certificate (PEM, which the playbooks put
# into the VMs' trust stores) and its DER copies with the root's revocation list (served by the
# vault VM for revocation checks). Playbooks find them in ~/lab-pki (lab_pki_dir in
# group_vars/all.yml).
$pkiPublic = @(
    (Join-Path $projectRoot 'keys\pki\root-ca.crt'),
    (Join-Path $projectRoot 'keys\pki\pub\root-ca.crt'),
    (Join-Path $projectRoot 'keys\pki\pub\root-ca.crl')
)
if (Test-Path $pkiPublic[0]) {
    & ssh -F $sshConfig -o LogLevel=ERROR $controlHost 'mkdir -p -m 755 ~/lab-pki/pub'
    if ($LASTEXITCODE -ne 0) { throw "Could not create ~/lab-pki on $controlHost (exit code $LASTEXITCODE)." }
    & scp -q -F $sshConfig -o LogLevel=ERROR $pkiPublic[0] "${controlHost}:lab-pki/"
    if ($LASTEXITCODE -eq 0) { & scp -q -F $sshConfig -o LogLevel=ERROR $pkiPublic[1] $pkiPublic[2] "${controlHost}:lab-pki/pub/" }
    if ($LASTEXITCODE -ne 0) { throw "Copying the public PKI files to $controlHost failed (exit code $LASTEXITCODE)." }
}

# --- 3. Replace ~/lab with the fresh copy -------------------------------------------------
# The archive is unpacked into ~/lab.new first and only then swapped in for ~/lab, so a
# failed unpack leaves the previous ~/lab in place instead of a half-written one.
# chmod -R go-w: Ansible ignores an ansible.cfg in a world-writable directory (otherwise
# another user could inject settings). The permissions of the unpacked files depend on the
# archive made on Windows and on the umask, so write access for group and others is
# removed explicitly.
& ssh -F $sshConfig -o LogLevel=ERROR $controlHost 'rm -rf ~/lab.new && mkdir ~/lab.new && tar -xzf /tmp/lab-ansible.tgz -C ~/lab.new && rm -f /tmp/lab-ansible.tgz && chmod -R go-w ~/lab.new && rm -rf ~/lab && mv ~/lab.new ~/lab'
if ($LASTEXITCODE -ne 0) { throw "Unpacking on $controlHost failed (exit code $LASTEXITCODE)." }

# --- 4. Run the playbook on ansible-control -----------------------------------------------
# ansible-playbook writes warnings to stderr. In Windows PowerShell 5.1 with
# $ErrorActionPreference = 'Stop', stderr output of a native program becomes a terminating
# error as soon as the output is redirected (for example ... *> log.txt), which would abort
# the script on a mere warning. From here on, success is judged by the exit code only.
$ErrorActionPreference = 'Continue'
# -t requests a pseudo-terminal on the VM, so ansible-playbook sees a terminal and prints
# coloured output. When the output is redirected to a file, -t is left out; otherwise colour
# escape codes and ssh's "Connection ... closed." message would end up in the log.
$ttyOption = @()
if (-not [Console]::IsOutputRedirected) { $ttyOption = @('-t') }
# sshd on ansible-control hands this command line to the ansible user's shell (zsh), which
# runs it (non-interactively, so no prompt or history is involved). Starting in ~/lab
# makes ansible-playbook use ~/lab/ansible.cfg (inventory, remote user, SSH key).
# The extra arguments ($args) are joined with spaces into this one command line and split
# again by the remote shell. Avoid double quotes inside them: Windows PowerShell 5.1 does
# not escape embedded double quotes when it passes arguments to native programs.
$command = "cd ~/lab && ansible-playbook playbooks/$Playbook $($args -join ' ')"
if ($openBaoPolicies.ContainsKey($Playbook)) {
    # A run token instead of a pseudo-terminal: Invoke-LabRunToken (LabSecrets.ps1) passes the
    # wrapped token on stdin, which rules out -t, and switches Ansible's colours on another way.
    . (Join-Path $PSScriptRoot 'LabSecrets.ps1')
    $health = Get-LabVaultHealth
    if (-not $health) { throw "OpenBao ($script:LabVaultUrl) is not reachable; $Playbook needs it. Is the vault VM running, and has OpenBao been deployed (.\scripts\Deploy-LabVault.ps1)?" }
    if ($health.sealed) { Unlock-LabVault }
    Invoke-LabRunToken $command $openBaoPolicies[$Playbook] ($Playbook -replace '\.yml$', '')
}
else {
    # "{ ...; } 2>&1" merges Ansible's warnings (stderr) into stdout on ansible-control, so
    # Windows PowerShell 5.1 does not show them as red error records when this output is
    # redirected to a file.
    & ssh -F $sshConfig -o LogLevel=ERROR @ttyOption $controlHost "{ $command; } 2>&1"
}
# Exit code of ansible-playbook (or 255 if the SSH connection itself failed).
$playbookExitCode = $LASTEXITCODE

# Return the playbook's exit code, so that callers (such as Initialize-Lab.ps1) can check
# $LASTEXITCODE.
exit $playbookExitCode
