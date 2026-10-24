<#
.SYNOPSIS
    Checks the SSH certificate code (scripts\LabSsh.ps1) on the PC, without touching the lab:
    offline signing, what a certificate contains, refused principals, the encrypted CA key, the
    revocation list and the rendered trust files.

.DESCRIPTION
    Works with a throwaway key in keys\ssh\tmp (deleted at the end). The offline SSH CA signs two
    short-lived certificates for it (6 minutes; they are listed in keys\ssh\issued.log like every
    certificate). Nothing is changed on any machine, and nothing secret is printed.

.EXAMPLE
    .\tests\Test-LabSshCa.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

Write-Host 'SSH CA (offline signing, certificate contents, principals, KRL, trust files)'
$work = New-LabSshTempDir
try {
    $key = Join-Path $work 'test_ed25519'
    $emptyPassphrase = '""'
    if ($PSVersionTable.PSVersion -ge [version]'7.3') { $emptyPassphrase = '' }
    & $script:LabSshKeygen -q -t ed25519 -N $emptyPassphrase -C 'lab-test' -f $key
    $keyFingerprint = Get-LabSshFingerprint ([IO.File]::ReadAllText("$key.pub"))

    # 1. A user certificate for the role pc, from the offline CA.
    $user = New-LabSshCertificate "$key.pub" 'pc' @('lab-all') 'test' -Hours 0.1 -Offline
    $cert = Read-LabSshCertificate $user.Path
    $pc = $script:LabSshRoles['pc']
    Assert-LabTest 'offline CA signs (ssh-keygen -P, OpenSSH for Windows)' (Test-Path $user.Path) $user.KeyId
    Assert-LabTest 'user certificate: signed by the offline CA' ($cert.CaFingerprint -eq (Get-LabSshOfflineCaFingerprint))
    Assert-LabTest 'user certificate: certifies the requested key' ($cert.KeyFingerprint -eq $keyFingerprint)
    Assert-LabTest 'user certificate: principal lab-all only' ((@($cert.Principals) -join ',') -eq 'lab-all')
    Assert-LabTest 'user certificate: extensions exactly permit-port-forwarding, permit-pty' ((@($cert.Extensions | Sort-Object) -join ',') -eq 'permit-port-forwarding,permit-pty') ($cert.Extensions -join ', ')
    Assert-LabTest 'user certificate: source-address PC + firewall LAN' ((@($cert.CriticalOptions) -join '|') -eq "source-address $($pc.SourceAddress)") ($cert.CriticalOptions -join ', ')
    Assert-LabTest 'user certificate: valid about 6 minutes, backdated 5' ($cert.ValidTo -lt [datetime]::UtcNow.AddMinutes(8) -and $cert.ValidFrom -lt [datetime]::UtcNow.AddMinutes(-4)) "$($cert.ValidFrom) - $($cert.ValidTo)"
    Assert-LabTest 'user certificate: random serial, key ID names the purpose' ($cert.Serial -gt 0 -and $cert.KeyId -like 'offline-pc-test-*') "serial $($cert.Serial)"

    # 2. A host certificate.
    $fqdn = Get-LabSshFqdn 'matrix'
    $hostCert = Read-LabSshCertificate (New-LabSshCertificate "$key.pub" 'lab-hosts' @($fqdn) 'test' -Hours 0.1 -Offline).Path
    Assert-LabTest 'host certificate: type host, exactly the FQDN' ($hostCert.Type -eq 'host' -and (@($hostCert.Principals) -join ',') -eq $fqdn)
    Assert-LabTest 'host certificate: no extensions, no critical options' (@($hostCert.Extensions).Count -eq 0 -and @($hostCert.CriticalOptions).Count -eq 0)

    # 3. Principals that must never be signed.
    $refused = @(
        @{ Role = 'lab-hosts'; Principals = @() }, @{ Role = 'lab-hosts'; Principals = @('*') }
        @{ Role = 'lab-hosts'; Principals = @("*.$($script:LabConfig.domain)") }, @{ Role = 'lab-hosts'; Principals = @("evil.$($script:LabConfig.domain)") }
        @{ Role = 'lab-hosts'; Principals = @($fqdn, (Get-LabSshFqdn 'keycloak')) }, @{ Role = 'lab-hosts'; Principals = @('matrix') }
        @{ Role = 'ansible-control'; Principals = @('root') }, @{ Role = 'ansible-control'; Principals = @('vagrant') }
        @{ Role = 'ansible-control'; Principals = @('host-*') }, @{ Role = 'pc'; Principals = @('host-matrix') }
    )
    foreach ($case in $refused) {
        $threw = $false
        try { Assert-LabSshPrincipals $case.Role $case.Principals } catch { $threw = $true }
        Assert-LabTest "refused: $($case.Role) for '$($case.Principals -join ',')'" $threw
    }
    # A certificate whose contents differ from the request is rejected (and deleted).
    $threw = $false
    try { [void](Assert-LabSshCertificate $user.Path @{ Type = 'user'; KeyFingerprint = $keyFingerprint; CaFingerprint = (Get-LabSshOfflineCaFingerprint); Principals = @('host-matrix'); Hours = 0.1; SourceAddress = $pc.SourceAddress; Extensions = $pc.Extensions }) }
    catch { $threw = $true }
    Assert-LabTest 'a certificate that differs from the request is rejected' ($threw -and -not (Test-Path $user.Path))

    # 4. The CA key file is encrypted; signing leaves no private key behind.
    $ErrorActionPreference = 'Continue'
    & $script:LabSshKeygen -y -P 'wrong-passphrase' -f $script:LabSshOfflineCa 2>&1 | Out-Null
    $openedWithWrong = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    Assert-LabTest 'offline CA key is encrypted (a wrong passphrase does not open it)' (-not $openedWithWrong)
    $leftovers = @(Get-ChildItem $work -File | Where-Object { $_.Name -notlike '*.pub' -and $_.Name -ne 'test_ed25519' })
    Assert-LabTest 'no private key left in the signing folder' ($leftovers.Count -eq 0) (($leftovers | ForEach-Object Name) -join ', ')

    # 5. The revocation list: the throwaway key is not in it; in a copy with it added, it is.
    $ErrorActionPreference = 'Continue'
    & $script:LabSshKeygen -Q -f $script:LabSshKrl "$key.pub" 2>&1 | Out-Null
    $notRevoked = ($LASTEXITCODE -eq 0)
    $krlCopy = Join-Path $work 'krl'
    Copy-Item $script:LabSshKrl $krlCopy
    & $script:LabSshKeygen -k -u -f $krlCopy "$key.pub" 2>&1 | Out-Null
    & $script:LabSshKeygen -Q -f $krlCopy "$key.pub" 2>&1 | Out-Null
    $revoked = ($LASTEXITCODE -ne 0)
    $ErrorActionPreference = 'Stop'
    Assert-LabTest 'revocation list: an unknown key passes, a revoked key is refused' ($notRevoked -and $revoked)

    # 6. The rendered trust files and ssh_config.
    [void](Write-LabSshTrustFiles)
    $names = @(Get-LabSshMachines | ForEach-Object { Get-LabSshFqdn $_ }) -join ','
    $knownHosts = @(Get-Content $script:LabSshKnownHosts | Where-Object { $_ })
    Assert-LabTest 'known_hosts: only @cert-authority lines for the exact lab names' ((@($knownHosts | Where-Object { $_ -notlike "@cert-authority $names ssh-ed25519 *" }).Count -eq 0) -and $knownHosts.Count -ge 1) "$($knownHosts.Count) CA(s)"
    Assert-LabTest 'known_hosts: no wildcard' (-not ($knownHosts -match '\*'))
    $controlIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip
    $firewallLines = @(Get-Content $script:LabSshFirewallKeys | Where-Object { $_ })
    $caLines = @($firewallLines | Where-Object { $_ -like "cert-authority,principals=`"lab-all,host-firewall`",from=`"$($script:LabConfig.firewall.pcIp),$controlIp`" ssh-ed25519 *" })
    Assert-LabTest 'firewall authorized_keys: only CA lines with principals and from=' ($caLines.Count -ge 1 -and $caLines.Count -eq $firewallLines.Count) "$($caLines.Count) CA line(s)"
    $config = Get-Content -Raw $script:LabSshConfigFile
    Assert-LabTest 'ssh_config: host keys only with a certificate, strictly checked' ($config -match 'HostKeyAlgorithms ssh-ed25519-cert-v01@openssh\.com' -and $config -match 'StrictHostKeyChecking yes' -and $config -notmatch 'accept-new')
    Assert-LabTest 'ssh_config: firewall checked under its name (HostKeyAlias)' ($config -match "HostKeyAlias firewall\.$([regex]::Escape($script:LabConfig.domain))")
}
finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }

Complete-LabTest 'Test-LabSshCa'
