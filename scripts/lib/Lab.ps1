<#
.SYNOPSIS
    The loader of the lab's PowerShell code: finds the project, loads the libraries and holds the
    table of lab.ps1's commands.

.DESCRIPTION
    Not run directly. lab.ps1, every file in scripts\commands and the tests load it with
        . (Join-Path <project>\scripts\lib 'Lab.ps1')
    always at script level, never inside a function: "dot-sourcing" puts the functions and the
    $script: variables of the libraries into the caller's script scope, where every later call
    finds them.

    WHERE CODE RUNS (the boundary rule of the lab)
      1. The PC does only what only the PC can do: drive Hyper-V and Vagrant, hold "secret zero"
         (DPAPI), operate the two offline CAs, read the out-of-band host-key anchors (serial
         console, Hyper-V KVP), own OpenBao's identity plane (who may log in and with which
         policy), install the firewall's bootstrap contract, and look at the lab the way your
         browser and shell see it.
      2. The offline CAs sign only what reaches the PC over its own verified channel (pinned TLS to
         OpenBao, or its own SSH to a host whose key was verified out of band). Nothing that
         passed through ansible-control is ever signed offline.
      3. Everything else is an Ansible run on ansible-control, started by the PC with per-run
         credentials (lib\LabRun.ps1); ansible-control keeps no standing credential.
    Enterprise equivalent: an offline root and an HSM for secret zero, a bastion, an IAM team that
    owns identities and policies, and a GitOps control node or CI runner that applies everything
    else from the repository.

    THE LIBRARIES (scripts\lib)
      LabSecrets.ps1   DPAPI on the PC, OpenBao's REST API (TLS pinned to the lab root), unseal,
                       logins, run tokens, the maintenance due list
      LabSsh.ps1       SSH CAs, certificates, trust files, host keys (offline CA + OpenBao)
      LabPki.ps1       the offline root CA (create, revocation list, sign)
      LabRun.ps1       runs on ansible-control (copy ansible\, per-run certificate and token)
      LabVault.ps1     deploying and administering OpenBao, snapshots, UI token, maintenance
      LabFirewall.ps1  building the OPNsense VM (loaded only by scripts\commands\firewall.ps1 and
                       its tests: it defines many variables of its own)
#>

$script:LabProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# A wrong root would make every library look for keys\ in the wrong place - and
# Initialize-LabSshCa would then create a NEW offline SSH CA there. So the root is checked, not assumed.
foreach ($marker in 'lab.ps1', 'config\lab.json', 'vagrant\Vagrantfile') {
    if (-not (Test-Path (Join-Path $script:LabProjectRoot $marker))) {
        throw "scripts\lib\Lab.ps1: $script:LabProjectRoot is not the project folder ($marker is missing)."
    }
}

. (Join-Path $PSScriptRoot 'LabSecrets.ps1')
. (Join-Path $PSScriptRoot 'LabSsh.ps1')
. (Join-Path $PSScriptRoot 'LabPki.ps1')
. (Join-Path $PSScriptRoot 'LabRun.ps1')
. (Join-Path $PSScriptRoot 'LabVault.ps1')

# The commands of lab.ps1. Each one is either a script (File, relative to the project folder: it
# has its own parameters, confirmation or exit code) or a library function (Function). lab.ps1
# passes every further argument on unchanged.
#   Elevated      needs an elevated PowerShell (Hyper-V)
#   UserOnly      changes Windows settings or shows secrets: refused when input or output is
#                 redirected, so that only you, in your own window, can run it - never a tool
#   PassExitCode  lab.ps1 ends with the command's exit code (ssh, ansible-playbook, tests)
$script:LabCommands = [ordered]@{
    'help'         = @{ Function = 'Show-LabHelp'; Group = 'Overview'; Help = 'this overview; "help <command>" shows the details of one command' }
    'status'       = @{ Function = 'Show-LabStatus'; Group = 'Overview'; Help = 'what is running, what is due, and the next step (changes nothing)' }
    'up'           = @{ File = 'scripts\commands\up.ps1'; Elevated = $true; Group = 'Build'; Help = 'build or start the lab and bring it up to date (also after every Windows restart)' }
    'down'         = @{ File = 'scripts\commands\down.ps1'; Elevated = $true; Group = 'Build'; Help = 'delete the lab VMs (or one VM: down matrix); asks first' }
    'firewall'     = @{ File = 'scripts\commands\firewall.ps1'; Elevated = $true; Group = 'Build'; Help = 'build (-Rebuild) or check the OPNsense firewall VM' }
    'deploy'       = @{ File = 'scripts\commands\deploy.ps1'; Group = 'Deploy'; Help = 'deploy vault | firewall | nginx | keycloak | matrix | rustfs | all' }
    'run'          = @{ Function = 'Invoke-LabRunCli'; PassExitCode = $true; Group = 'Deploy'; Help = 'run a profile on ansible-control (run <profile|playbook.yml> [ansible-playbook options]; alone: list them)' }
    'maintain'     = @{ Function = 'Invoke-LabMaintenance'; Group = 'Deploy'; Help = 'renew what is due (certificates, revocation lists); -List only shows it' }
    'connect'      = @{ File = 'scripts\commands\connect.ps1'; PassExitCode = $true; Group = 'Use'; Help = 'SSH to a lab machine as ansible (connect [vm] [command])' }
    'secret'       = @{ File = 'scripts\commands\secret.ps1'; Group = 'Use'; Help = 'copy a secret to the clipboard (secret keycloak/users/alice, secret -List)' }
    'ui'           = @{ Function = 'Open-LabVaultUi'; Group = 'Use'; Help = "open OpenBao's web UI with a 1-hour login token" }
    'unseal'       = @{ Function = 'Invoke-LabUnseal'; Group = 'Use'; Help = 'unseal OpenBao (-Interactive: type two key shares)' }
    'backup'       = @{ Function = 'Backup-LabOpenBao'; Group = 'Use'; Help = "snapshot of OpenBao's data to keys\openbao\snapshots" }
    'ssh-cert'     = @{ Function = 'Invoke-LabSshCertRenewal'; Group = 'Use'; Help = "renew this PC's 8-hour SSH certificate (-Force: now)" }
    'breakglass'   = @{ Group = 'Use'; Help = 'run one command with the offline SSH CA allowed to sign (breakglass up)' }
    'test'         = @{ File = 'tests\Invoke-LabTests.ps1'; PassExitCode = $true; Group = 'Use'; Help = 'run the tests (-Name <test>, -IncludeStateChanging)' }
    'host-setup'   = @{ File = 'scripts\host\Initialize-LabHost.ps1'; Elevated = $true; UserOnly = $true; Group = 'Your own window'; Help = 'once per PC: LabHost network, DNS rule for the lab domain' }
    'trust'        = @{ File = 'scripts\host\Install-LabRootCA.ps1'; UserOnly = $true; Group = 'Your own window'; Help = 'let Windows trust the lab root CA (-Remove, -RemoveRetired)' }
    'recovery'     = @{ File = 'scripts\commands\recovery.ps1'; UserOnly = $true; Group = 'Your own window'; Help = 'the recovery kit (-Renew, -Open <file>, -Recover <file>)' }
    'mdad-upgrade' = @{ File = 'scripts\dev\Update-LabMdad.ps1'; Group = 'Maintainer'; Help = 'take a new matrix-docker-ansible-deploy commit into vendor\mdad' }
}

# lab.ps1's arguments for the command behind it, as @{ Positional = @(...); Named = @{...} } for
# splatting both. "-Name:value" (for example -Confirm:$false) arrives in $args as TWO elements,
# "-Name:" and the value, and splatting the array would pass them on as two arguments: for
# -Confirm that means "ask" plus $false as the first positional parameter. Such pairs become named
# parameters; every other argument stays as it is (also "-WhatIf" or "--check"), in its order.
function Split-LabArguments([object[]]$Arguments) {
    $named = @{}
    $positional = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -is [string] -and $Arguments[$i] -match '^-([A-Za-z][A-Za-z0-9_]*):$' -and $i + 1 -lt $Arguments.Count) {
            $named[$Matches[1]] = $Arguments[$i + 1]
            $i++
        }
        else { $positional += , $Arguments[$i] }
    }
    return @{ Positional = $positional; Named = $named }
}

# Administrator rights (elevated, under UAC) or membership in "Hyper-V Administrators"
# (S-1-5-32-578): Hyper-V and Vagrant's Hyper-V provider need one of them.
function Test-LabElevated {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        $principal.IsInRole([Security.Principal.SecurityIdentifier]'S-1-5-32-578')
}

# Runs one lab.ps1 command from code (the maintenance step uses it), through a new lab.ps1 so the
# command gets exactly the same checks and scope as when you type it. Leaves its exit code in
# $LASTEXITCODE and throws when it is not 0.
function Invoke-LabCommand([string]$Name, [string[]]$Arguments = @()) {
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:LabProjectRoot 'lab.ps1') $Name @Arguments
    if ($LASTEXITCODE -ne 0) { throw ".\lab.ps1 $Name $($Arguments -join ' ') failed (exit code $LASTEXITCODE)." }
}

function Show-LabHelp([string]$Command) {
    if ($Command) {
        $entry = $script:LabCommands[$Command]
        if (-not $entry) { Write-Host "Unknown command '$Command'. .\lab.ps1 help lists them."; return }
        if ($entry.File) { Get-Help (Join-Path $script:LabProjectRoot $entry.File) -Detailed | Out-Host }
        elseif ($entry.Function) { Get-Help $entry.Function -Detailed | Out-Host }
        else { Write-Host "$Command`: $($entry.Help)" }
        return
    }
    Write-Host 'The lab, one command:  .\lab.ps1 <command> [arguments]'
    foreach ($group in @($script:LabCommands.Values | ForEach-Object { $_.Group } | Select-Object -Unique)) {
        Write-Host ''
        Write-Host "  $group"
        foreach ($name in $script:LabCommands.Keys) {
            $entry = $script:LabCommands[$name]
            if ($entry.Group -ne $group) { continue }
            $flags = @(); if ($entry.Elevated) { $flags += 'elevated' }; if ($entry.UserOnly) { $flags += 'your own window' }
            $note = if ($flags) { " [$($flags -join ', ')]" } else { '' }
            Write-Host ("    {0,-13} {1}{2}" -f $name, $entry.Help, $note)
        }
    }
    Write-Host ''
    Write-Host 'First time:  host-setup (own window) -> up -> deploy vault -> trust (own window) -> recovery (own window) -> deploy all'
    Write-Host 'Every day:   up (after a Windows restart), then connect / secret / ui as needed'
}

# A read-only overview, ending with the next step.
function Show-LabStatus {
    $next = @()
    Write-Host 'Lab status'
    if (Test-LabElevated) {
        $names = @('firewall') + @($script:LabConfig.vms | ForEach-Object { $_.name })
        foreach ($name in $names) {
            $vm = if ($name -eq 'firewall') { Get-VM -Name firewall -ErrorAction SilentlyContinue } else { Get-LabSshHyperVVm $name }
            $state = if ($vm) { "$($vm.State)" } else { 'missing' }
            Write-Host ("  VM {0,-16} {1}" -f $name, $state)
            if ($state -ne 'Running') { $next += '.\lab.ps1 up' }
        }
    }
    else { Write-Host '  VMs:            (run elevated to see the Hyper-V state)' }
    if (Test-Path (Join-Path $script:LabKeysDir 'openbao\unseal-a.dpapi')) {
        $health = Get-LabVaultHealth
        if (-not $health) { Write-Host '  OpenBao:        not reachable'; $next += '.\lab.ps1 up' }
        elseif ($health.sealed) { Write-Host '  OpenBao:        sealed'; $next += '.\lab.ps1 unseal' }
        else { Write-Host "  OpenBao:        unsealed$(if (Test-LabSshOpenBaoTrusted) { ', signs the SSH certificates' } else { ' (its SSH CA is not in use yet: .\lab.ps1 deploy vault)' })" }
    }
    else { Write-Host '  OpenBao:        not deployed'; $next += '.\lab.ps1 deploy vault' }
    if (Test-Path "$($script:LabSshPcKey)-cert.pub") {
        $cert = Read-LabSshCertificate "$($script:LabSshPcKey)-cert.pub"
        Write-Host "  SSH certificate: valid until $($cert.ValidTo.ToLocalTime().ToString('yyyy-MM-dd HH:mm')) ($(if ($cert.CaFingerprint -eq (Get-LabSshOfflineCaFingerprint)) { 'offline CA' } else { 'OpenBao' }))"
    }
    else { Write-Host '  SSH certificate: none yet' }
    if (Test-LabSecret 'openbao/unseal-c-pending') { Write-Host '  Recovery kit:   PENDING (share C still on this PC)'; $next += '.\lab.ps1 recovery   (your own window)' }
    elseif ((Test-Path (Join-Path $script:LabKeysDir 'openbao\unseal-c.sha256')) -and -not (Test-LabSshCaInRecoveryKit)) { Write-Host '  Recovery kit:   PENDING (no copy of the offline SSH CA)'; $next += '.\lab.ps1 recovery -Renew   (your own window)' }
    if ((Test-Path (Join-Path $script:LabKeysDir 'openbao\unseal-a.dpapi')) -and (Get-LabVaultHealth)) {
        $due = Get-LabMaintenanceDue
        foreach ($item in $due) { Write-Host "  Due:            $($item.What)"; $next += ".\lab.ps1 $($item.Action -join ' ')" }
    }
    $next = @($next | Select-Object -Unique)
    Write-Host ''
    if ($next.Count -gt 0) { Write-Host "Next: $($next[0])" } else { Write-Host 'Next: nothing due' }
}
