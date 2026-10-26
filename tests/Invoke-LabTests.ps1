<#
.SYNOPSIS
    Runs the lab's tests (tests\Test-*.ps1) and reports which passed.

.DESCRIPTION
    By default the tests that change nothing in the lab (see tests\README.md). Test-LabRecoveryLogin.ps1
    changes logins and is only run with -IncludeStateChanging. Each test prints one line per
    check; this script prints a summary and exits with 1 if any test failed.

.PARAMETER Name
    Run only these tests (file names without .ps1), e.g. Test-LabCertificates.

.PARAMETER IncludeStateChanging
    Also run Test-LabRecoveryLogin.ps1 (new pc-admin/pc-deploy logins; invalidates the
    break-glass login of an existing recovery kit). It still asks before it starts.

.EXAMPLE
    .\tests\Invoke-LabTests.ps1
    .\tests\Invoke-LabTests.ps1 -Name Test-LabCertificates
#>
param(
    [string[]]$Name,
    [switch]$IncludeStateChanging
)
$ErrorActionPreference = 'Stop'

$safe = 'Test-LabLayout', 'Test-LabAnsible', 'Test-LabNginxPlan', 'Test-LabNginxFirewallRender', 'Test-LabCertificates', 'Test-LabTlsPin', 'Test-LabPasswordHash', 'Test-LabRetiredDpapi', 'Test-LabRunToken', 'Test-LabOpenBaoConfig', 'Test-LabSecretCreation', 'Test-LabFirewallRender', 'Test-LabSshCa', 'Test-LabSshCertificates'
$tests = if ($Name) { $Name } else { $safe + $(if ($IncludeStateChanging) { 'Test-LabRecoveryLogin' }) }
$results = [ordered]@{}
foreach ($test in $tests) {
    Write-Host ''
    Write-Host "=== $test ==="
    # Only the exit code decides: a test's stderr (a remote warning, say) must not stop the run
    # (Windows PowerShell 5.1 turns redirected stderr of a native program into error records).
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$test.ps1")
    $results[$test] = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
}
Write-Host ''
Write-Host 'Summary:'
foreach ($test in $results.Keys) { Write-Host ("  {0,-26} {1}" -f $test, $(if ($results[$test]) { 'passed' } else { 'FAILED' })) }
if ($results.Values -contains $false) { exit 1 }
