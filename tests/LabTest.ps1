<#
.SYNOPSIS
    Shared helpers for the lab's tests (dot-sourced by tests\Test-*.ps1).

.DESCRIPTION
    Each test script loads this file and LabSecrets.ps1, reports every check with
    Assert-LabTest (one line: PASS or FAIL, a name, details that never contain a secret) and
    ends with Complete-LabTest, which prints a summary and exits with 1 if a check failed - so
    tests\Invoke-LabTests.ps1 (or any other caller) can use the exit code.
#>

$script:LabTestRoot = Split-Path -Parent $PSScriptRoot
$script:LabTestFailures = 0
$script:LabTestCount = 0
. (Join-Path $script:LabTestRoot 'scripts\LabSecrets.ps1')

function Assert-LabTest([string]$Name, [bool]$Condition, [string]$Detail = '') {
    $script:LabTestCount++
    if ($Condition) { Write-Host "  PASS  $Name $(if ($Detail) { "($Detail)" })" }
    else { $script:LabTestFailures++; Write-Host "  FAIL  $Name $(if ($Detail) { "($Detail)" })" -ForegroundColor Red }
}

function Complete-LabTest([string]$What) {
    Write-Host "$What`: $($script:LabTestCount - $script:LabTestFailures) of $script:LabTestCount checks passed"
    if ($script:LabTestFailures -gt 0) { exit 1 }
    exit 0
}

# Copies scripts from tests\remote to /tmp/lab-tests on ansible-control (the tests run them
# there); Remove-LabTestRemote deletes them again.
function Copy-LabTestRemote([string[]]$Files) {
    $sshConfig = Join-Path $script:LabKeysDir 'ssh_config'
    $ErrorActionPreference = 'Continue'
    & ssh -F $sshConfig -o LogLevel=ERROR ansible-control 'rm -rf /tmp/lab-tests && mkdir -m 700 /tmp/lab-tests'
    & scp -q -F $sshConfig -o LogLevel=ERROR ($Files | ForEach-Object { Join-Path $script:LabTestRoot "tests\remote\$_" }) 'ansible-control:/tmp/lab-tests/'
    if ($LASTEXITCODE -ne 0) { throw "Copying the test files to ansible-control failed (exit code $LASTEXITCODE)." }
}

function Remove-LabTestRemote {
    $sshConfig = Join-Path $script:LabKeysDir 'ssh_config'
    $ErrorActionPreference = 'Continue'
    & ssh -F $sshConfig -o LogLevel=ERROR ansible-control 'rm -rf /tmp/lab-tests' | Out-Null
}
