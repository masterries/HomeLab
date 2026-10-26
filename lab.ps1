<#
.SYNOPSIS
    The lab's single entry point: .\lab.ps1 <command> [arguments]. ".\lab.ps1 help" lists the
    commands, ".\lab.ps1 help <command>" explains one.

.DESCRIPTION
    Every task on the Windows PC goes through this script: building and starting the lab (up),
    deploying the services (deploy vault | nginx | keycloak | matrix | rustfs | firewall | all), running a playbook
    (run), logging in (connect), reading a secret (secret), tearing it down (down). Most commands
    hand the actual work to Ansible on the VM ansible-control; the PC keeps only what needs
    Windows (Hyper-V, DPAPI, the offline CAs) - scripts\lib\Lab.ps1 explains the rule.

    The command table, with the rights each command needs, is in scripts\lib\Lab.ps1
    ($LabCommands). lab.ps1 itself only checks those rights and passes every further argument on
    unchanged.

    Exit codes: 0 done, 1 the command failed (the reason is printed) or is unknown (PowerShell
    itself refuses it; Tab completes the command names), 2 refused before anything was changed
    (wrong window, not elevated); run, connect and test pass on the exit code of what they ran.

.EXAMPLE
    .\lab.ps1 up
    .\lab.ps1 deploy all
    .\lab.ps1 connect matrix
    .\lab.ps1 run ping.yml -v
    .\lab.ps1 breakglass up
#>
# A plain script on purpose (no [CmdletBinding()]): every argument after the command lands in
# $args and is passed on unchanged - also "-v", "--check" or "-WhatIf" for the command behind it
# (only "-Name:value" pairs are rebuilt as named parameters, see Split-LabArguments).
# The only parameter starts with "_", so that no abbreviation a command uses (-s, -c, -f ...) can
# be taken for it. Enterprise equivalent: one CLI with subcommands (az, kubectl, gh).
param(
    [ValidateSet('help', 'status', 'up', 'down', 'firewall', 'deploy', 'run', 'maintain', 'connect', 'secret', 'ui',
        'unseal', 'backup', 'ssh-cert', 'breakglass', 'test', 'host-setup', 'trust', 'recovery', 'mdad-upgrade')]
    [string]$_Command = 'help'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\lib\Lab.ps1')

# The arguments for the command, "-Name:value" pairs as named parameters (Split-LabArguments in
# scripts\lib\Lab.ps1 explains why; -Confirm:$false would otherwise not arrive).
$split = Split-LabArguments $args
$rest = $split.Positional
$named = $split.Named

if ($_Command -eq 'help') { Show-LabHelp @rest @named; exit 0 }

# BREAK-GLASS: one command with the offline SSH CA allowed to sign when OpenBao cannot
# (LabSsh.ps1, Get-LabSshSigner). Set for the inner command only, then removed again.
if ($_Command -eq 'breakglass') {
    if (-not $args) { Write-Host 'Usage: .\lab.ps1 breakglass <command> [arguments]'; exit 2 }
    Write-Host 'BREAK-GLASS: the offline SSH CA may sign SSH certificates for this command.' -ForegroundColor Red
    $previous = $env:LAB_SSH_BREAKGLASS
    $env:LAB_SSH_BREAKGLASS = '1'
    try { & $PSCommandPath @rest @named; $code = $LASTEXITCODE }
    finally { $env:LAB_SSH_BREAKGLASS = $previous }
    exit $code
}

$entry = $script:LabCommands[$_Command]
if ($entry.Elevated -and -not (Test-LabElevated)) {
    Write-Host "'$_Command' needs Hyper-V: start PowerShell with ""Run as administrator""."
    exit 2
}
# Commands that change Windows settings or show secrets only run in your own window: with
# redirected input or output (a log file, a tool, an AI assistant's shell) they are refused, so
# nothing secret ends up stored somewhere and no setting changes without you watching.
if ($entry.UserOnly -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
    Write-Host "'$_Command' changes Windows settings or shows secrets: run it yourself in your own PowerShell window."
    exit 2
}

$global:LASTEXITCODE = 0
try {
    if ($entry.File) { & (Join-Path $PSScriptRoot $entry.File) @rest @named }
    else { & $entry.Function @rest @named }
}
catch {
    Write-Host "$($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) { Write-Host $_.InvocationInfo.PositionMessage }
    exit 1
}
if ($entry.PassExitCode) { exit $LASTEXITCODE }
exit 0
