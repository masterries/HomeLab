<#
.SYNOPSIS
    Runs the regression tests of opnsense\lab-nginx.php (tests\Test-LabNginxFirewall.php) with the
    firewall's own PHP.

.DESCRIPTION
    lab-nginx.php decides which forwards and DNS records of the running firewall change when
    lab.json's publications change (deploy nginx). Its tests are pure: they build firewall
    configurations in memory, never load OPNsense's config.inc and change nothing. They need a PHP
    interpreter, and in the lab only the firewall has one (the same PHP lab-nginx.php runs on).
    This copies the helper, config\lab.json and the test into a private temporary folder on the
    firewall, runs the test there and deletes the folder again, also after a failure.

.EXAMPLE
    .\tests\Test-LabNginxPlan.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

Write-Host 'Central nginx firewall plan (lab-nginx.php)'
$remote = "$(@(Invoke-LabSsh 'firewall' 'umask 077 && mktemp -d /tmp/lab-nginx-test.XXXXXX')[-1])".Trim()
if ($remote -notmatch '^/tmp/lab-nginx-test\.[A-Za-z0-9]+$') { throw "Unexpected temporary folder on the firewall: $remote" }
try {
    $files = @('opnsense\lab-nginx.php', 'config\lab.json', 'tests\Test-LabNginxFirewall.php') | ForEach-Object { Join-Path $script:LabTestRoot $_ }
    Copy-LabSshFile $files "firewall:$remote/"
    $output = @(Invoke-LabSsh 'firewall' "/usr/local/bin/php $remote/Test-LabNginxFirewall.php $remote/lab-nginx.php $remote/lab.json" -AllowFailure)
    $code = $LASTEXITCODE
    $passed = @($output | Where-Object { "$_" -like 'PASS: *' }).Count
    $failure = @($output | Where-Object { "$_" -match 'FAIL|Fatal|Error' } | Select-Object -First 3)
    Assert-LabTest 'lab-nginx.php regression tests pass on the firewall''s PHP' ($code -eq 0 -and ($output -join "`n") -match 'all tests passed') "$passed checks$(if ($failure) { '; ' + ($failure -join ' / ') })"
}
finally {
    Invoke-LabSsh 'firewall' "rm -rf $remote" -AllowFailure | Out-Null
}
Complete-LabTest 'Test-LabNginxPlan'
