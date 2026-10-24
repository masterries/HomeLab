<#
.SYNOPSIS
    Gets one of the lab's secrets, for example a user's login password: copies it to the
    clipboard (default) or shows it.

.DESCRIPTION
    The lab keeps no plain-text secrets. They live in two places:
      OpenBao (KV mount "lab")   everything the services use: Keycloak's and Matrix's secrets,
                                 the lab users' passwords
      this PC (DPAPI, -Pc)       what must exist before or without OpenBao: the firewall's
                                 passwords and API key, OpenBao's own unseal key shares and
                                 logins, the root CA key's passphrase (LabSecrets.ps1)
    This is the way to read one by hand, for example to log in as alice:

        .\lab.ps1 secret keycloak/users/alice

    copies alice's password to the clipboard; paste it into Keycloak's login page. The
    firewall's root password (GUI login):

        .\lab.ps1 secret -Pc opnsense/root-password

    -List shows which secrets exist (names only). -Show prints the value instead of copying it,
    but only in a real console window: output that is redirected or captured by another
    program could be stored in plain text.

    Runs on the Windows host as your own user. OpenBao is read with the pc-admin AppRole
    (DPAPI); every read is recorded in OpenBao's audit log (on the vault VM,
    /var/log/openbao/audit.log, with the value replaced by a hash).

    Note: Windows' clipboard history (Win+V), if you switched it on, keeps copied text. Clear
    it there after use if that matters to you.

.PARAMETER Path
    OpenBao: the path below "lab/", for example keycloak/users/alice, keycloak/admin.
    With -Pc: the name of the DPAPI secret, for example opnsense/root-password.

.PARAMETER Field
    Field of an OpenBao secret. Not needed when the secret has only one field (all lab secrets).

.PARAMETER Pc
    Read a DPAPI secret stored on this PC instead of OpenBao.

.PARAMETER Show
    Print the value instead of copying it.

.PARAMETER List
    List the secrets in OpenBao and on this PC (names only, no values).

.EXAMPLE
    .\lab.ps1 secret -List
    .\lab.ps1 secret keycloak/users/alice
    .\lab.ps1 secret keycloak/admin -Show
    .\lab.ps1 secret -Pc opnsense/root-password
#>
[CmdletBinding(DefaultParameterSetName = 'OpenBao')]
param(
    [Parameter(ParameterSetName = 'OpenBao', Position = 0, Mandatory = $true)]
    [Parameter(ParameterSetName = 'Pc', Position = 0, Mandatory = $true)]
    [string]$Path,
    [Parameter(ParameterSetName = 'OpenBao')]
    [string]$Field,
    [Parameter(ParameterSetName = 'Pc', Mandatory = $true)]
    [switch]$Pc,
    [Parameter(ParameterSetName = 'OpenBao')]
    [Parameter(ParameterSetName = 'Pc')]
    [switch]$Show,
    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Lab.ps1')

# KV version 2 lists "folders" (names ending in /) and secrets under lab/metadata/<path>.
function Get-SecretPaths([string]$Token, [string]$Prefix) {
    $answer = Invoke-LabBao GET "lab/metadata/$Prefix`?list=true" -Token $Token -AllowNotFound
    if (-not $answer) { return }
    foreach ($key in $answer.data.keys) {
        if ($key.EndsWith('/')) { Get-SecretPaths $Token "$Prefix$key" }
        else { "$Prefix$key" }
    }
}

if ($List) {
    # The PC's names first: they need no OpenBao (useful exactly when it is sealed or broken).
    Write-Host 'On this PC (DPAPI, read with -Pc):'
    Get-ChildItem $script:LabKeysDir -Recurse -Filter '*.dpapi' | ForEach-Object {
        $name = $_.FullName.Substring($script:LabKeysDir.Length + 1) -replace '\.dpapi$', '' -replace '\\', '/'
        Write-Host "  $name"
    }
    Write-Host 'In OpenBao (lab/...):'
    try { $token = Get-LabBaoToken 'pc-admin' }
    catch { Write-Warning "OpenBao cannot be read now: $($_.Exception.Message)"; return }
    try {
        foreach ($secretPath in (Get-SecretPaths $token '' | Sort-Object)) {
            $fields = (Invoke-LabBao GET "lab/data/$secretPath" -Token $token).data.data.PSObject.Properties.Name
            Write-Host ('  {0,-52} {1}' -f $secretPath, ($fields -join ', '))
        }
    }
    finally { Close-LabBaoToken $token }
    return
}

if ($Pc) {
    $label = "DPAPI secret $Path"
    $value = Unprotect-LabSecret $Path
}
else {
    $Path = $Path.Trim('/') -replace '^lab/', ''
    $label = "lab/$Path"
    $token = Get-LabBaoToken 'pc-admin'
    try { $secret = Invoke-LabBao GET "lab/data/$Path" -Token $token -AllowNotFound }
    finally { Close-LabBaoToken $token }
    if (-not $secret) { throw "No secret lab/$Path in OpenBao. See: .\lab.ps1 secret -List" }
    $fields = @($secret.data.data.PSObject.Properties.Name)
    if (-not $Field) {
        if ($fields.Count -ne 1) { throw "lab/$Path has several fields ($($fields -join ', ')); choose one with -Field." }
        $Field = $fields[0]
    }
    if ($fields -notcontains $Field) { throw "lab/$Path has no field '$Field' (fields: $($fields -join ', '))." }
    $label = "lab/$Path ($Field)"
    $value = $secret.data.data.$Field
    $secret = $null
}

if ($Show) {
    Assert-LabInteractiveConsole 'lab.ps1 secret -Show'
    Write-Host "${label}:"
    Write-Host "    $value"
}
else {
    Set-Clipboard -Value $value
    Write-Host "$label copied to the clipboard."
}
$value = $null
