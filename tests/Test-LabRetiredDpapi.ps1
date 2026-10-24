<#
.SYNOPSIS
    Checks that DPAPI secrets moved by Remove-Lab.ps1 to keys\openbao-retired-<date-time>\ can
    still be read under their new names (Unprotect-LabSecret in LabSecrets.ps1).

.DESCRIPTION
    Local only. Copies keys\openbao\unseal-a.dpapi into a temporary folder named like a retired
    one (keys\openbao-retired-20990101-000000), reads it under that name - with "/" and with "\"
    as separator - compares it with the original (nothing is printed) and deletes the copy.

.EXAMPLE
    .\tests\Test-LabRetiredDpapi.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

Write-Host 'Retired DPAPI secrets'
if (-not (Test-LabSecret 'openbao/unseal-a')) { throw 'No keys\openbao\unseal-a.dpapi (OpenBao not deployed yet).' }
$fake = Join-Path $script:LabKeysDir 'openbao-retired-20990101-000000'
New-Item -ItemType Directory -Force -Path $fake | Out-Null
try {
    Copy-Item (Get-LabSecretPath 'openbao/unseal-a') (Join-Path $fake 'unseal-a.dpapi')
    $original = Unprotect-LabSecret 'openbao/unseal-a'
    Assert-LabTest 'readable under openbao-retired-<date-time>/unseal-a' ((Unprotect-LabSecret 'openbao-retired-20990101-000000/unseal-a') -ceq $original)
    Assert-LabTest 'readable with a backslash in the name' ((Unprotect-LabSecret 'openbao-retired-20990101-000000\unseal-a') -ceq $original)
    $original = $null
}
finally { Remove-Item -Recurse -Force $fake }
Complete-LabTest 'Test-LabRetiredDpapi'
