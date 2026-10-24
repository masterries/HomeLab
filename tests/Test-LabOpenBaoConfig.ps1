<#
.SYNOPSIS
    Checks OpenBao's configuration plane (ansible/playbooks/openbao-config.yml): its token can
    configure the engines but not hand out rights, and OpenBao matches the repository.

.DESCRIPTION
    1. Runs the profile test-config-token (config\run-profiles.json: ansible/tests/config-token-check.sh
       with a token of the role ansible-config, the same way openbao-config.yml gets one) and checks:
         - its policies are exactly openbao-config (+ default), it lasts at most 30 minutes, it is
           bound to ansible-control's address and an orphan,
         - it may configure the engines (mounts, KV config, password policies, CRL, ACME, PKI roles),
         - it may NOT touch the identity plane or anything else: ACL policies, auth methods,
           AppRoles, token roles, the SSH CA, choosing or importing a CA, issuing or signing
           certificates, secrets, snapshots, audit devices. OpenBao is only asked which
           capabilities the token has (sys/capabilities-self); nothing is tried.
         - after the run the token is revoked (looked up by its accessor with pc-admin).
    2. Runs openbao-config.yml in check mode: it must find nothing to change ("changed=0"), so
       nobody changed OpenBao's configuration by hand (in the web UI, say) since the last
       "deploy vault" - drift detection.
    No secret is printed. Nothing is changed.

.EXAMPLE
    .\tests\Test-LabOpenBaoConfig.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')
$controlIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip

Write-Host 'The token of the configuration plane'
$lines = @(Invoke-LabRun 'test-config-token')
$exitCode = $LASTEXITCODE
$report = @{}
foreach ($line in $lines) { if ("$line" -match '^([a-z_]+|cap:[A-Za-z0-9_/.-]+)=(.*)$') { $report[$Matches[1]] = $Matches[2] } }

Assert-LabTest 'the command ran with a token' ($exitCode -eq 0 -and $report.token_present -eq 'yes')
Assert-LabTest 'policies: exactly openbao-config and default' ($report.policies -eq 'default,openbao-config') $report.policies
Assert-LabTest 'lifetime at most 30 minutes' ([int]$report.ttl -gt 0 -and [int]$report.ttl -le 1800) "$($report.ttl) s"
Assert-LabTest 'usable only from ansible-control' ($report.bound_cidrs -eq $controlIp) $report.bound_cidrs
Assert-LabTest 'an orphan (outlives the PC login)' ($report.orphan -eq 'True')

$allowed = [ordered]@{
    'sys/mounts'                         = 'read'
    'sys/mounts/pki_int/tune'            = 'read,update'
    'lab/config'                         = 'create,read,update'
    'sys/policies/password/lab-alnum-24' = 'create,read,update'
    'pki_int/config/crl'                 = 'create,read,update'
    'pki_int/config/acme'                = 'create,read,update'
    'pki_int/roles/keycloak'             = 'create,read,update'
}
foreach ($path in $allowed.Keys) {
    Assert-LabTest "may configure $path" ($report["cap:$path"] -eq $allowed[$path]) $report["cap:$path"]
}
$denied = 'sys/policies/acl/openbao-config', 'sys/auth/approle', 'auth/approle/role/pc-admin/secret-id',
    'auth/token/roles/ansible-config', 'auth/token/create', 'auth/token/create/ansible-run', 'sys/mounts/ssh',
    'ssh/config/ca', 'ssh/sign/pc', 'pki_int/config/issuers', 'pki_int/intermediate/set-signed',
    'pki_int/issue/keycloak', 'pki_int/sign/keycloak', 'lab/data/keycloak/admin', 'sys/storage/raft/snapshot', 'sys/audit'
foreach ($path in $denied) {
    Assert-LabTest "no access to $path" ($report["cap:$path"] -eq 'deny') $report["cap:$path"]
}

$admin = Get-LabBaoToken 'pc-admin'
try {
    $stillValid = $true
    try { Invoke-LabBao POST 'auth/token/lookup-accessor' @{ accessor = $report.accessor } -Token $admin | Out-Null } catch { $stillValid = $false }
    Assert-LabTest 'token revoked after the run' (-not $stillValid)
}
finally { Close-LabBaoToken $admin }

Write-Host 'OpenBao matches the repository (openbao-config.yml --check)'
$lines = @(Invoke-LabRun 'openbao-config' @('--check'))
$exitCode = $LASTEXITCODE
# Without the colour codes Ansible adds when the console can show them.
$recap = "$($lines | ForEach-Object { "$_" -replace "\x1b\[[0-9;]*m", '' } | Where-Object { $_ -match '^ansible-control\s+:' } | Select-Object -Last 1)"
Assert-LabTest 'the check run succeeded' ($exitCode -eq 0 -and $recap -match 'failed=0') "exit code $exitCode"
Assert-LabTest 'nothing to change (no drift)' ($recap -match '\bchanged=0\b') ($recap -replace '\s+', ' ').Trim()
Complete-LabTest 'Test-LabOpenBaoConfig'
