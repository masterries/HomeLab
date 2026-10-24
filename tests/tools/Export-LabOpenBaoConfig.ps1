<#
.SYNOPSIS
    Writes OpenBao's configuration (no secret values) to a JSON file, to compare two states.

.DESCRIPTION
    Read-only: logs in as pc-admin and reads the configuration the lab sets up - mounts and their
    tuning, the KV settings, the password policies, the ACL policies, the AppRole roles (their
    settings, never role_id or secret_id), the token roles, the PKI configuration and roles, ACME,
    the SSH roles and the SSH CA's public key. No secret is read: not the KV data, not the
    AppRoles' IDs. Use it before and after a change to how OpenBao is configured, then compare the
    two files (for example with: git diff --no-index before.json after.json).

.PARAMETER Path
    The JSON file to write (default: %TEMP%\openbao-config-<date-time>.json).

.EXAMPLE
    .\tests\tools\Export-LabOpenBaoConfig.ps1 -Path $env:TEMP\openbao-before.json
#>
[CmdletBinding()]
param([string]$Path = (Join-Path ([IO.Path]::GetTempPath()) "openbao-config-$(Get-Date -Format yyyyMMdd-HHmmss).json"))

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\lib\Lab.ps1')

$token = Get-LabAdminToken
try {
    function Get-Bao([string]$ApiPath) {
        $answer = Invoke-LabBao GET $ApiPath -Token $token -AllowNotFound
        if ($answer -and $answer.PSObject.Properties['data']) { return $answer.data }
        return $answer
    }
    function Get-List([string]$ApiPath) {
        $answer = Invoke-LabBao GET "$ApiPath`?list=true" -Token $token -AllowNotFound
        if (-not $answer) { return @() }
        return @($answer.data.keys)
    }
    $export = [ordered]@{}
    $mounts = Get-Bao 'sys/mounts'
    $export.mounts = [ordered]@{}
    foreach ($name in 'lab/', 'pki_int/', 'ssh/') {
        $m = $mounts.$name
        if ($m) { $export.mounts[$name] = [ordered]@{ type = $m.type; options = $m.options; config = $m.config; description = $m.description } }
    }
    foreach ($name in 'lab', 'pki_int', 'ssh') { $export["tune:$name"] = Get-Bao "sys/mounts/$name/tune" }
    $export.'lab/config' = Get-Bao 'lab/config'
    $export.password_policies = [ordered]@{}
    foreach ($length in 24, 48, 64) { $export.password_policies["lab-alnum-$length"] = (Get-Bao "sys/policies/password/lab-alnum-$length").policy }
    $export.acl_policies = [ordered]@{}
    foreach ($name in (Get-Bao 'sys/policies/acl?list=true').keys) { $export.acl_policies[$name] = (Get-Bao "sys/policies/acl/$name").policy }
    $export.approle_roles = [ordered]@{}
    foreach ($name in Get-List 'auth/approle/role') { $export.approle_roles[$name] = Get-Bao "auth/approle/role/$name" }
    $export.token_roles = [ordered]@{}
    foreach ($name in Get-List 'auth/token/roles') { $export.token_roles[$name] = Get-Bao "auth/token/roles/$name" }
    foreach ($item in 'cluster', 'urls', 'crl', 'auto-tidy', 'acme', 'issuers') { $export["pki_int/config/$item"] = Get-Bao "pki_int/config/$item" }
    $export.pki_roles = [ordered]@{}
    foreach ($name in Get-List 'pki_int/roles') { $export.pki_roles[$name] = Get-Bao "pki_int/roles/$name" }
    $export.ssh_roles = [ordered]@{}
    foreach ($name in Get-List 'ssh/roles') { $export.ssh_roles[$name] = Get-Bao "ssh/roles/$name" }
    $export.ssh_ca_public_key = "$(Invoke-LabBao GET 'ssh/public_key')".Trim()
}
finally { Close-LabBaoToken $token }

[IO.File]::WriteAllText($Path, ($export | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
Write-Host "OpenBao configuration (no secrets) written to $Path"
