<#
.SYNOPSIS
    Checks the break-glass path of New-LabRecoveryKit.ps1 -Recover without a recovery file:
    the AppRole "recovery" logs in with administrator rights and issues new logins for the PC.

.DESCRIPTION
    CHANGES STATE (on purpose, the same as -Recover does):
      1. a secret_id for the AppRole "recovery" is made (in memory only),
      2. it logs in; the token must carry openbao-admin,
      3. with that token NEW logins for pc-admin and pc-deploy are issued and stored with DPAPI
         (keys\openbao\pc-admin.dpapi, pc-deploy.dpapi); the older secret_ids are destroyed,
      4. both new logins must work,
      5. every secret_id of "recovery" is destroyed again - so if you already made a recovery
         kit, its break-glass login stops working: make a new one with
         .\scripts\New-LabRecoveryKit.ps1 -Renew. The test asks before it starts.
    The key shares are not touched. No secret is printed.

.PARAMETER Force
    Do not ask before starting.

.EXAMPLE
    .\tests\Test-LabRecoveryLogin.ps1
#>
param([switch]$Force)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

Write-Host 'Break-glass login (AppRole recovery)'
if (-not $Force) {
    $answer = Read-Host 'This makes new pc-admin/pc-deploy logins and invalidates the break-glass login of an existing recovery kit. Type yes to continue'
    if ($answer -ne 'yes') { Write-Host 'Not run.'; exit 0 }
}
$admin = Get-LabBaoToken 'pc-admin'
try { $recovery = New-LabAppRoleSecret 'recovery' $admin } finally { Close-LabBaoToken $admin }
$login = Invoke-LabBao POST 'auth/approle/login' @{ role_id = $recovery.role_id; secret_id = $recovery.secret_id }
$token = $login.auth.client_token
Assert-LabTest 'break-glass login has openbao-admin' (@($login.auth.policies) -contains 'openbao-admin') (@($login.auth.policies) -join ',')
try {
    foreach ($role in 'pc-admin', 'pc-deploy') {
        $new = New-LabAppRoleSecret $role $token
        Protect-LabSecret "openbao/$role" (@{ role_id = $new.role_id; secret_id = $new.secret_id } | ConvertTo-Json -Compress) -Force
        Remove-LabAppRoleSecretIds $role $token $new.accessor
        $new = $null
    }
}
finally { Close-LabBaoToken $token; $recovery = $null }
foreach ($role in 'pc-admin', 'pc-deploy') {
    $t = $null
    try { $t = Get-LabBaoToken $role } catch { }
    Assert-LabTest "new $role login works" ([bool]$t)
    if ($t) { Close-LabBaoToken $t }
}
$admin = Get-LabBaoToken 'pc-admin'
try {
    Remove-LabAppRoleSecretIds 'recovery' $admin ''
    foreach ($role in 'pc-admin', 'pc-deploy', 'recovery') {
        $ids = Invoke-LabBao GET "auth/approle/role/$role/secret-id?list=true" -Token $admin -AllowNotFound
        $count = if ($ids) { @($ids.data.keys).Count } else { 0 }
        $expected = if ($role -eq 'recovery') { 0 } else { 1 }
        Assert-LabTest "$role has $expected valid secret_id" ($count -eq $expected) "$count"
    }
}
finally { Close-LabBaoToken $admin }
Write-Host 'If you had made a recovery kit already, make a new one:  .\scripts\New-LabRecoveryKit.ps1 -Renew'
Complete-LabTest 'Test-LabRecoveryLogin'
