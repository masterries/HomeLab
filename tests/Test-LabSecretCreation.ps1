<#
.SYNOPSIS
    Checks how the playbooks create a missing secret (tasks/openbao-secrets.yml): OpenBao
    generates it, it is stored "create only", and --check stores nothing.

.DESCRIPTION
    Uses a throwaway path, lab/keycloak/test-generated, that no service reads:
      1. --check run: the value is generated (24 characters) but NOT stored in OpenBao,
      2. real run: the value is generated and stored,
      3. second real run: the stored value is read, nothing new is created,
      4. the throwaway secret is deleted again (with pc-admin).
    Runs tests/remote/secret-creation.yml on ansible-control with a run token for the policy
    ansible-keycloak. Needs ~/lab on ansible-control (any lab.ps1 run run puts it
    there). No secret is printed, only lengths.

.EXAMPLE
    .\tests\Test-LabSecretCreation.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')
$path = 'keycloak/test-generated'

function Test-Stored {
    $admin = Get-LabBaoToken 'pc-admin'
    try { return Invoke-LabBao GET "lab/data/$path" -Token $admin -AllowNotFound }
    finally { Close-LabBaoToken $admin }
}
function Invoke-Run([string]$Options) {
    $extra = @(); if ($Options) { $extra = @($Options) }
    $output = @(Invoke-LabRun 'test-secret-creation' $extra)
    $result = @{ ExitCode = $LASTEXITCODE; Changed = -1; Length = -1 }
    foreach ($line in $output) {
        # Without Ansible's colour codes (ESC[...m), which an interactive console gets.
        $text = "$line" -replace ([string][char]27 + '\[[0-9;]*m'), ''
        if ($text -match 'length=(\d+)') { $result.Length = [int]$Matches[1] }
        if ($text -match 'localhost\s*:.*changed=(\d+)') { $result.Changed = [int]$Matches[1] }
    }
    return $result
}

Write-Host 'Creating a missing secret (throwaway path lab/keycloak/test-generated)'
if (Test-Stored) { throw "lab/$path exists already (a test that did not finish?). Delete it first: lab/metadata/$path" }
try {
    $check = Invoke-Run '--check'
    Assert-LabTest '--check: a value is generated' ($check.ExitCode -eq 0 -and $check.Length -eq 24) "length $($check.Length)"
    Assert-LabTest '--check: nothing stored in OpenBao' (-not (Test-Stored))

    $first = Invoke-Run ''
    $stored = Test-Stored
    Assert-LabTest 'real run: generated and stored' ($first.ExitCode -eq 0 -and $stored -and $stored.data.data.password.Length -eq 24) "changed=$($first.Changed)"

    $second = Invoke-Run ''
    Assert-LabTest 'second run: read, nothing created' ($second.ExitCode -eq 0 -and $second.Changed -eq 0 -and $second.Length -eq 24) "changed=$($second.Changed)"
}
finally {
    $admin = Get-LabBaoToken 'pc-admin'
    try { Invoke-LabBao DELETE "lab/metadata/$path" -Token $admin | Out-Null } catch { }
    finally { Close-LabBaoToken $admin }
    $stored = $null
}
Assert-LabTest 'throwaway secret deleted again' (-not (Test-Stored))
Complete-LabTest 'Test-LabSecretCreation'
