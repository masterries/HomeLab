<#
.SYNOPSIS
    Opens OpenBao's web UI and puts a login token for it on the clipboard (valid 1 hour).

.DESCRIPTION
    OpenBao's web UI (https://vault.lab.internal:8200/ui/) shows the lab's secrets (KV mount
    "lab"), policies, AppRoles, the PKI with its certificates and issuers, and the audit
    devices. In this lab nobody has a personal OpenBao account yet: every login is a machine
    login (AppRoles pc-admin, pc-deploy, recovery), and the initial root token was revoked.
    So this script makes a short-lived token for you:

      1. logs in as pc-admin (DPAPI, only from your PC),
      2. creates a token through the token role "ui-admin": administrator policy
         (openbao-admin), valid for 1 hour at most, usable only from your PC's address
         (10.10.99.1), an "orphan" so it outlives the pc-admin login,
      3. copies it to the clipboard and opens the UI in your default browser.

    In the UI choose the method "Token", paste it (Ctrl+V) and sign in. "Sign out" in the UI
    (top right) revokes it at once; otherwise it expires after an hour. Every request is in
    OpenBao's audit log, under the display name "token-ui".

    Careful: the token has full administrator rights. Read and look around freely; a change made
    by hand in the UI is not in the repository and is overwritten or lost on the next
    Deploy-LabVault.ps1 run or rebuild (secrets you change there are the exception: they live
    only in OpenBao). The proper way for people is a personal login through the company's
    identity provider (OIDC); for the lab that is on the roadmap (Keycloak as login for OpenBao).

    Runs on the Windows host as your own user. Prints no secret. Windows' clipboard history
    (Win+V), if you switched it on, keeps copied text.

.PARAMETER NoBrowser
    Only copy the token, do not open the browser.

.EXAMPLE
    .\scripts\Open-LabVaultUi.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

$health = Get-LabVaultHealth
if (-not $health) { throw "OpenBao ($script:LabVaultUrl) is not reachable. Is the vault VM running (.\scripts\Initialize-Lab.ps1)?" }
if ($health.sealed) { Unlock-LabVault }

$admin = Get-LabBaoToken 'pc-admin'
try {
    # The role is part of Deploy-LabVault.ps1; applied here too, for a lab deployed before it existed.
    Set-LabUiTokenRole $admin
    $answer = Invoke-LabBao POST 'auth/token/create/ui-admin' @{ policies = @('openbao-admin'); display_name = 'ui'; ttl = '1h' } -Token $admin
}
finally { Close-LabBaoToken $admin }

Set-Clipboard -Value $answer.auth.client_token
$expires = (Get-Date).AddSeconds($answer.auth.lease_duration)
$answer = $null
Write-Host "A login token for OpenBao's web UI is on the clipboard (valid until $($expires.ToString('HH:mm')), only from this PC)."
Write-Host 'In the UI: method "Token", paste with Ctrl+V, "Sign in". "Sign out" revokes it again.'
$uiUrl = "$script:LabVaultUrl/ui/"
if (-not $NoBrowser) { Start-Process $uiUrl } else { Write-Host "UI: $uiUrl" }
