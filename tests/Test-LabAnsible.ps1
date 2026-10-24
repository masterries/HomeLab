<#
.SYNOPSIS
    Checks the Ansible side of the lab: every playbook parses, checks.yml passes, and the
    playbooks that should leave nothing to do find nothing to do ("no drift").

.DESCRIPTION
    Changes nothing: every run is either read-only or in check mode (--check). Runs on
    ansible-control through lab.ps1 run (each with its own SSH certificate and, where the profile
    needs one, its own OpenBao token):
      - profile syntax: ansible-playbook --syntax-check for every playbook (bin/syntax-check),
      - profile checks: checks.yml, the read-only checks of every machine,
      - base.yml --check and firewall.yml --check: "changed=0", so the VMs' base setup and the
        firewall's GUI certificate match the repository. A change made by hand on a VM shows up
        here. (OpenBao's configuration is checked by Test-LabOpenBaoConfig.ps1.)

.EXAMPLE
    .\tests\Test-LabAnsible.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

# The last recap line of every host, without the colour codes Ansible adds when the console can
# show them.
function Get-LabRecap([object[]]$Lines) {
    $plain = @($Lines | ForEach-Object { "$_" -replace "\x1b\[[0-9;]*m", '' })
    return @($plain | Where-Object { $_ -match '^\S+\s+:\s+ok=\d+' })
}

Write-Host 'Ansible'
$lines = @(Invoke-LabRun 'syntax')
$code = $LASTEXITCODE
$failed = @($lines | Where-Object { "$_" -match '^SYNTAX ERROR' })
Assert-LabTest 'every playbook parses (syntax)' ($code -eq 0 -and $failed.Count -eq 0) "exit code $code$(if ($failed) { ': ' + ($failed -join ', ') })"

$lines = @(Invoke-LabRun 'checks')
$code = $LASTEXITCODE
$recap = Get-LabRecap $lines
Assert-LabTest 'checks.yml passes on every machine' ($code -eq 0 -and $recap.Count -gt 0 -and -not ($recap -match 'failed=[1-9]|unreachable=[1-9]')) "exit code $code, $($recap.Count) hosts"

foreach ($runName in 'base', 'firewall') {
    $lines = @(Invoke-LabRun $runName @('--check'))
    $code = $LASTEXITCODE
    $recap = Get-LabRecap $lines
    $changed = @($recap | Where-Object { $_ -notmatch '\bchanged=0\b' })
    Assert-LabTest "$runName --check succeeds" ($code -eq 0 -and $recap.Count -gt 0) "exit code $code"
    Assert-LabTest "$runName --check: nothing to change (no drift)" ($recap.Count -gt 0 -and $changed.Count -eq 0) (($changed | ForEach-Object { ($_ -replace '\s+', ' ').Trim() }) -join '; ')
}
Complete-LabTest 'Test-LabAnsible'
