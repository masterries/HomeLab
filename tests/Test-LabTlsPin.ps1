<#
.SYNOPSIS
    Checks the certificate pinning of the PC's OpenBao calls (LabTlsPin2 in LabSecrets.ps1).

.DESCRIPTION
    Read-only. Runs in a fresh PowerShell process (a pinned callback, once set, stays for the
    whole process) and checks:
      - OpenBao answers through the pinned connection,
      - another lab host is still checked by Windows' normal rules (firewall GUI),
      - a host whose chain does NOT end at the lab root is refused while it is the pinned host
        (www.microsoft.com is used as that foreign chain: one plain HTTPS request goes there),
      - a lab chain is accepted while it is the pinned host (keycloak).

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

[LabTlsPin2]::PinnedHost = 'www.microsoft.com'
$foreignAccepted = $true
try { Invoke-WebRequest -UseBasicParsing 'https://www.microsoft.com/' -TimeoutSec 15 | Out-Null } catch { $foreignAccepted = $false }
Assert-LabTest 'pinned host with a foreign chain is refused' (-not $foreignAccepted)

[LabTlsPin2]::PinnedHost = "keycloak.$domain"
$status = $null
try { $status = (Invoke-WebRequest -UseBasicParsing "https://keycloak.$domain/realms/lab/.well-known/openid-configuration" -TimeoutSec 15).StatusCode } catch { }
Assert-LabTest 'pinned host with a lab chain is accepted' ($status -eq 200) "HTTP $status"
Complete-LabTest 'Test-LabTlsPin'
