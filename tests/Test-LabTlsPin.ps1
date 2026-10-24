<#
.SYNOPSIS
    Checks the certificate pinning of the PC's OpenBao calls (LabTlsPin3 in LabSecrets.ps1).

.DESCRIPTION
    Read-only. Runs in a fresh PowerShell process (a pinned callback, once set, stays for the
    whole process) and checks:
      - OpenBao answers through the pinned connection (its certificate is signed directly by the
        lab root),
      - another lab host is still checked by Windows' normal rules (firewall GUI),
      - a host whose chain does NOT end at the lab root is refused while it is the pinned host
        (www.microsoft.com is used as that foreign chain: one plain HTTPS request goes there),
      - a lab chain through OpenBao's intermediate CA is refused while it is the pinned host
        (keycloak): only the root itself may vouch for OpenBao.

.EXAMPLE
    .\tests\Test-LabTlsPin.ps1
#>
$ErrorActionPreference = 'Stop'
if (-not $env:LAB_TEST_CHILD) {
    # The checks themselves run in a child process, so this session's settings stay untouched.
    $env:LAB_TEST_CHILD = '1'
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath; exit $LASTEXITCODE }
    finally { Remove-Item Env:LAB_TEST_CHILD -ErrorAction SilentlyContinue }
}
. (Join-Path $PSScriptRoot 'LabTest.ps1')
$domain = $script:LabConfig.domain

Write-Host 'TLS pinning'
$health = Get-LabVaultHealth
Assert-LabTest 'OpenBao reachable through the pinned connection' ([bool]$health) "version $($health.version)"
$status = $null
try { $status = (Invoke-WebRequest -UseBasicParsing "https://firewall.$domain/" -TimeoutSec 15).StatusCode } catch { }
Assert-LabTest 'other lab hosts: Windows validation (firewall GUI)' ($status -eq 200) "HTTP $status"

[LabTlsPin3]::PinnedHost = 'www.microsoft.com'
$foreignAccepted = $true
try { Invoke-WebRequest -UseBasicParsing 'https://www.microsoft.com/' -TimeoutSec 15 | Out-Null } catch { $foreignAccepted = $false }
Assert-LabTest 'pinned host with a foreign chain is refused' (-not $foreignAccepted)

# Keycloak's certificate comes from OpenBao's intermediate CA. -DisableKeepAlive: every request
# makes a new TLS connection, so each one is validated (a kept-alive connection would be reused
# without the callback being asked again).
$url = "https://keycloak.$domain/realms/lab/.well-known/openid-configuration"
[LabTlsPin3]::PinnedHost = "keycloak.$domain"
$intermediateAccepted = $true
try { Invoke-WebRequest -UseBasicParsing -DisableKeepAlive $url -TimeoutSec 15 | Out-Null } catch { $intermediateAccepted = $false }
Assert-LabTest 'pinned host with a chain through the intermediate is refused' (-not $intermediateAccepted)
# The same request is accepted while keycloak is not the pinned host (Windows trusts the lab root),
# so the refusal above was the pin's doing.
[LabTlsPin3]::PinnedHost = ([Uri]$script:LabVaultUrl).Host
$status = $null
try { $status = (Invoke-WebRequest -UseBasicParsing -DisableKeepAlive $url -TimeoutSec 15).StatusCode } catch { }
Assert-LabTest 'the same chain is accepted when keycloak is not pinned' ($status -eq 200) "HTTP $status"
Complete-LabTest 'Test-LabTlsPin'
