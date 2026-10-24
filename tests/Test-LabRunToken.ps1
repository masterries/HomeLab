<#
.SYNOPSIS
    Checks the run tokens for Ansible (New-LabRunToken / Invoke-LabRunToken in LabSecrets.ps1 and
    ansible/bin/openbao-run): what a token may do, where it works, and that it is gone after the
    run.

.DESCRIPTION
    Creates one run token with the policy ansible-keycloak, the same way a playbook run does,
    and runs tests/remote/run-token-check.sh with it on ansible-control. Checks:
      - the token arrives (wrapped, unwrapped by openbao-run),
      - its policies are exactly ansible-keycloak (+ default), it lasts at most 2 hours, it is
        bound to ansible-control's address and an orphan,
      - Ansible's temporary folder is on a RAM file system (tmpfs),
      - after the run the token is revoked (looked up by its accessor, which is not secret, with
        pc-admin), and the temporary folder is gone.
    No secret is printed. Nothing stays behind (the copied script is removed).

.EXAMPLE
    .\tests\Test-LabRunToken.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')
$controlIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip

Write-Host 'Run tokens for Ansible'
Copy-LabTestRemote 'run-token-check.sh'
try {
    $lines = @(Invoke-LabRunToken 'bash /tmp/lab-tests/run-token-check.sh' @('ansible-keycloak') 'test')
    $exitCode = $LASTEXITCODE
}
finally { Remove-LabTestRemote }
$report = @{}
foreach ($line in $lines) { if ("$line" -match '^([a-z_]+)=(.*)$') { $report[$Matches[1]] = $Matches[2] } }

Assert-LabTest 'the command ran with a token' ($exitCode -eq 0 -and $report.token_present -eq 'yes')
Assert-LabTest 'policies: exactly ansible-keycloak and default' ($report.policies -eq 'ansible-keycloak,default') $report.policies
Assert-LabTest 'lifetime at most 2 hours' ([int]$report.ttl -gt 0 -and [int]$report.ttl -le 7200) "$($report.ttl) s"
Assert-LabTest 'usable only from ansible-control' ($report.bound_cidrs -eq $controlIp) $report.bound_cidrs
Assert-LabTest 'an orphan (outlives the PC login)' ($report.orphan -eq 'True')
Assert-LabTest "Ansible's temporary files on tmpfs" ($report.local_temp_on_tmpfs -eq 'yes') $report.local_temp_on_tmpfs

$admin = Get-LabBaoToken 'pc-admin'
try {
    $stillValid = $true
    try { Invoke-LabBao POST 'auth/token/lookup-accessor' @{ accessor = $report.accessor } -Token $admin | Out-Null } catch { $stillValid = $false }
    Assert-LabTest 'token revoked after the run' (-not $stillValid)
}
finally { Close-LabBaoToken $admin }

$ErrorActionPreference = 'Continue'
# Only this run's folder: another run (a deployment) may have its own at the same time.
$localTemp = "$($report.local_temp)"
$gone = $false
if ($localTemp -match '^/[A-Za-z0-9/._-]+$') {
    $answer = & ssh -F (Get-LabSshConfig) -o LogLevel=ERROR ansible-control "test -e $localTemp && echo present || echo gone"
    $gone = ("$answer".Trim() -eq 'gone')
}
Assert-LabTest "Ansible's temporary folder of this run removed" $gone $localTemp
Complete-LabTest 'Test-LabRunToken'
