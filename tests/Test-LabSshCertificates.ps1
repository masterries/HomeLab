<#
.SYNOPSIS
    Checks SSH in the running lab: certificate logins work, and everything that should be refused
    is refused - plain host keys, certificates from an unknown CA, certificates for other hosts or
    from other addresses, revoked host keys, the old lab key.

.DESCRIPTION
    Needs the whole lab running (firewall and every VM of config\lab.json). Changes nothing: it
    uses throwaway keys and CAs in keys\ssh\tmp and /tmp/lab-tests on ansible-control (deleted
    at the end), and short-lived certificates (logged in keys\ssh\issued.log like every one).
    Checks that need Hyper-V (the KVP host keys, Vagrant's connection) run only in an elevated
    shell.

    What it proves, in short:
      - every machine presents a valid host certificate for its name, and the PC and
        ansible-control refuse a machine that offers only a plain host key;
      - the PC's certificate logs in everywhere on its own (no other key needed), and so does a
        certificate from the offline CA (the break-glass path);
      - a certificate from a CA the lab does not trust logs in nowhere;
      - an Ansible run's certificate opens only its hosts, and a PC certificate does not work
        from ansible-control (source-address);
      - a host key in the revocation list is refused even with its certificate;
      - sshd on every machine runs with the lab's settings.

.EXAMPLE
    .\tests\Test-LabSshCertificates.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabTest.ps1')

$machines = Get-LabSshMachines
$vms = @($script:LabConfig.vms | ForEach-Object { $_.name })
$domain = $script:LabConfig.domain
$sshConfig = Get-LabSshConfig
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$emptyPassphrase = '""'
if ($PSVersionTable.PSVersion -ge [version]'7.3') { $emptyPassphrase = '' }

# A login attempt with a given config and extra options: the exit code (0 = it worked).
function Test-Login([string]$Config, [string]$Machine, [string[]]$Options = @()) {
    $ErrorActionPreference = 'Continue'
    & ssh -F $Config -o LogLevel=QUIET -o BatchMode=yes -o ConnectTimeout=15 @Options $Machine 'true' 2>&1 | Out-Null
    return $LASTEXITCODE
}
function New-TestKey([string]$Path) {
    $ErrorActionPreference = 'Continue'
    & $script:LabSshKeygen -q -t ed25519 -N $emptyPassphrase -C 'lab-test' -f $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen could not make $Path." }
}
# A config like keys\ssh_config, but with another identity for the target; the jump through the
# firewall keeps the PC's own certificate (IdentityFile lines add up in ssh_config, and the
# firewall's block comes first), so the TARGET's decision is what is tested.
function New-TestConfig([string]$Folder, [string]$IdentityFile, [switch]$KeepPcIdentityForJump) {
    $text = Get-LabSshConfigText -IdentityFile $IdentityFile -NoLegacyKey
    if ($KeepPcIdentityForJump) {
        $pcKey = $script:LabSshPcKey -replace '\\', '/'
        $text = $text.Replace("    HostKeyAlias firewall.$domain", "    HostKeyAlias firewall.$domain`n    IdentityFile `"$pcKey`"`n    CertificateFile `"$pcKey-cert.pub`"")
    }
    $path = Join-Path $Folder "ssh_config-$([IO.Path]::GetFileName($IdentityFile))"
    [void](Write-LabSshFile $path $text.Split("`n"))
    return $path
}

Write-Host 'SSH certificates in the running lab'
$work = New-LabSshTempDir
try {
    # --- Host certificates ------------------------------------------------------------------------
    foreach ($machine in $machines) {
        Assert-LabTest "$machine`: strict login (PC certificate, host certificate checked)" ((Test-Login $sshConfig $machine) -eq 0)
        Assert-LabTest "$machine`: a plain host key is refused" ((Test-Login $sshConfig $machine @('-o', 'HostKeyAlgorithms=ssh-ed25519')) -ne 0)
        $certFile = Join-Path $script:LabSshHostsDir "$machine-cert.pub"
        if (Test-Path $certFile) {
            $cert = Read-LabSshCertificate $certFile
            $ok = $cert.Type -eq 'host' -and (@($cert.Principals) -join ',') -eq (Get-LabSshFqdn $machine) -and (Get-LabSshTrustedCaFingerprints) -contains $cert.CaFingerprint -and $cert.ValidTo -gt [datetime]::UtcNow.AddDays(30)
            Assert-LabTest "$machine`: host certificate for $(Get-LabSshFqdn $machine) from a trusted CA, valid > 30 days" $ok "until $($cert.ValidTo.ToLocalTime().ToString('yyyy-MM-dd')), $($cert.KeyId)"
        }
        else { Assert-LabTest "$machine`: host certificate stored on the PC" $false }
    }
    $fingerprints = @(Get-ChildItem $script:LabSshHostsDir -Filter '*.pub' -File | Where-Object { $_.Name -notlike '*-cert.pub' } | ForEach-Object { Get-LabSshFingerprint ([IO.File]::ReadAllText($_.FullName)) })
    Assert-LabTest 'no two machines share a host key' (@($fingerprints | Select-Object -Unique).Count -eq $fingerprints.Count)

    # --- User certificates --------------------------------------------------------------------------
    $pcOnly = New-TestConfig $work $script:LabSshPcKey
    foreach ($machine in $machines) { Assert-LabTest "$machine`: the PC's certificate alone logs in (no other key offered)" ((Test-Login $pcOnly $machine) -eq 0) }

    # The break-glass CA must stay usable after OpenBao took over.
    $offlineKey = Join-Path $work 'offline_ed25519'
    New-TestKey $offlineKey
    [void](New-LabSshCertificate "$offlineKey.pub" 'pc' @('lab-all') 'test' -Hours 0.2 -Offline)
    $offlineConfig = New-TestConfig $work $offlineKey
    foreach ($machine in $machines) { Assert-LabTest "$machine`: a certificate from the offline CA logs in (break-glass)" ((Test-Login $offlineConfig $machine) -eq 0) }

    # A CA that the lab does not know.
    $rogueCa = Join-Path $work 'rogue_ca'
    $rogueKey = Join-Path $work 'rogue_ed25519'
    New-TestKey $rogueCa
    New-TestKey $rogueKey
    $ErrorActionPreference = 'Continue'
    & $script:LabSshKeygen -s $rogueCa -I 'rogue' -n 'lab-all,ansible' -V '-5m:+10m' -z 4242 -O clear -O permit-pty -O permit-port-forwarding "$rogueKey.pub" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$rogueKey-cert.pub")) { throw 'Could not sign the rogue test certificate; the unknown-CA checks would prove nothing.' }
    $ErrorActionPreference = 'Stop'
    Assert-LabTest 'firewall: a certificate from an unknown CA is refused' ((Test-Login (New-TestConfig $work $rogueKey) 'firewall') -ne 0)
    $rogueViaJump = New-TestConfig $work $rogueKey -KeepPcIdentityForJump
    foreach ($vm in $vms) { Assert-LabTest "$vm`: a certificate from an unknown CA is refused" ((Test-Login $rogueViaJump $vm) -ne 0) }

    # --- Revocation list ----------------------------------------------------------------------------
    $krl = Join-Path $work 'krl'
    Copy-Item $script:LabSshKrl $krl
    $ErrorActionPreference = 'Continue'
    & $script:LabSshKeygen -k -u -f $krl (Get-LabSshHostKeyFile 'matrix') 2>&1 | Out-Null
    $ErrorActionPreference = 'Stop'
    Assert-LabTest 'matrix: refused when its host key is in the revocation list' ((Test-Login $sshConfig 'matrix' @('-o', "RevokedHostKeys=$(ConvertTo-LabSshPath $krl)")) -ne 0)

    # --- From ansible-control ---------------------------------------------------------------------
    Copy-LabTestRemote @('ssh-cert-check.sh')
    try {
        $pcCertKey = Join-Path $work 'pccert_ed25519'
        New-TestKey $pcCertKey
        [void](New-LabSshCertificate "$pcCertKey.pub" 'pc' @('lab-all') 'test' -Hours 0.2)
        Copy-LabSshFile @($pcCertKey, "$pcCertKey.pub", "$pcCertKey-cert.pub") 'ansible-control:/tmp/lab-tests/' -ConfigFile $sshConfig
        $certificate = Get-LabControlCertificateCommand @('host-matrix')
        $others = @($machines | Where-Object { $_ -notin 'matrix', 'ansible-control' } | ForEach-Object { Get-LabSshFqdn $_ })
        $remote = "chmod 600 /tmp/lab-tests/pccert_ed25519 && $($certificate.Install) && bash /tmp/lab-tests/ssh-cert-check.sh scope $(Get-LabSshFqdn 'matrix') $($others -join ' '); bash /tmp/lab-tests/ssh-cert-check.sh plainhost $(Get-LabSshFqdn 'matrix'); bash /tmp/lab-tests/ssh-cert-check.sh key /tmp/lab-tests/pccert_ed25519 $(Get-LabSshFqdn 'keycloak'); $($certificate.Remove)"
        $lines = @(Invoke-LabSsh 'ansible-control' $remote -ConfigFile $sshConfig)
        $result = @{}
        foreach ($line in $lines) { if ("$line" -match '^(\S+) (\S+) (\d+)$') { $result["$($Matches[1]) $($Matches[2])"] = [int]$Matches[3] } }
        Assert-LabTest 'ansible-control: a certificate for host-matrix logs in to matrix' ($result["scope $(Get-LabSshFqdn 'matrix')"] -eq 0)
        foreach ($other in $others) { Assert-LabTest "ansible-control: ... and is refused on $other" ($result["scope $other"] -ne $null -and $result["scope $other"] -ne 0) }
        Assert-LabTest 'ansible-control: a plain host key is refused' ($result["plainhost $(Get-LabSshFqdn 'matrix')"] -ne $null -and $result["plainhost $(Get-LabSshFqdn 'matrix')"] -ne 0)
        Assert-LabTest 'ansible-control: a PC certificate does not work from there (source-address)' ($result["key $(Get-LabSshFqdn 'keycloak')"] -ne $null -and $result["key $(Get-LabSshFqdn 'keycloak')"] -ne 0)
        $leftCert = "$(Invoke-LabSsh 'ansible-control' 'test -e ~/.ssh/id_ed25519-cert.pub && echo present || echo gone' -ConfigFile $sshConfig)".Trim()
        Assert-LabTest 'ansible-control: the run certificate is removed afterwards' ($leftCert -eq 'gone')
    }
    finally { Remove-LabTestRemote }

    # --- sshd settings --------------------------------------------------------------------------------
    foreach ($vm in $vms) {
        $settings = @(Invoke-LabSsh $vm 'sudo sshd -T' -ConfigFile $sshConfig)
        $expected = @('permitrootlogin no', 'passwordauthentication no', 'allowtcpforwarding no', 'allowagentforwarding no',
            'trustedusercakeys /etc/ssh/lab_user_ca.pub', 'authorizedprincipalsfile /etc/ssh/lab_principals/%u', 'hostcertificate /etc/ssh/ssh_host_ed25519_key-cert.pub')
        $missing = @($expected | Where-Object { $settings -notcontains $_ })
        Assert-LabTest "$vm`: sshd runs with the lab's settings" ($missing.Count -eq 0) $(if ($missing) { "missing: $($missing -join '; ')" } else { 'certificates only, no forwarding, no root' })
        $users = @($settings | Where-Object { $_ -like 'allowusers *' })
        Assert-LabTest "$vm`: AllowUsers only from the jump host and ansible-control" ($users.Count -eq 3) ($users -join '; ')
    }
    $settings = @(Invoke-LabSsh 'firewall' 'sudo /usr/local/sbin/sshd -T -f /usr/local/etc/ssh/sshd_config' -ConfigFile $sshConfig)
    $missing = @(@('allowtcpforwarding local', 'hostcertificate /conf/sshd/ssh_host_ed25519_key-cert.pub', 'permittunnel no', 'allowagentforwarding no') | Where-Object { $settings -notcontains $_ })
    $permitOpen = "$($settings | Where-Object { $_ -like 'permitopen *' })"
    Assert-LabTest 'firewall: sshd limited to the jump host job' ($missing.Count -eq 0 -and $permitOpen -match ':22' -and $permitOpen -notmatch 'any') $(if ($missing) { "missing: $($missing -join '; ')" } else { $permitOpen })

    # --- The old lab key -------------------------------------------------------------------------------
    if (-not (Test-Path $script:LabSshLegacyKey)) {
        foreach ($machine in $machines) {
            $count = "$(Invoke-LabSsh $machine 'grep -c ansible@deployableserver-lab ~/.ssh/authorized_keys 2>/dev/null || true' -ConfigFile $sshConfig)".Trim()
            Assert-LabTest "$machine`: the old lab key is not accepted any more" (-not $count -or $count -eq '0')
        }
    }
    else { Write-Host '  (old lab key keys\ansible_ed25519 still there: retire it with .\scripts\Complete-LabSshMigration.ps1)' }

    # --- Hyper-V: KVP and Vagrant ------------------------------------------------------------------------
    if ($elevated) {
        foreach ($vm in $vms) {
            $kvp = Get-LabKvpHostKey $vm 30
            Assert-LabTest "$vm`: host key from Hyper-V KVP = the certified key" ((Get-LabSshFingerprint $kvp) -eq (Get-LabSshFingerprint ([IO.File]::ReadAllText((Get-LabSshHostKeyFile $vm)))))
        }
        $previousVagrantCwd = $env:VAGRANT_CWD
        $env:VAGRANT_CWD = Join-Path $script:LabProjectRoot 'vagrant'
        try {
            $ErrorActionPreference = 'Continue'
            $vagrantConfig = "$(& vagrant ssh-config matrix 2>&1)"
            & vagrant ssh matrix -c 'true' 2>&1 | Out-Null
            $vagrantSsh = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
        }
        finally { $env:VAGRANT_CWD = $previousVagrantCwd }
        Assert-LabTest "Vagrant jumps with Windows' ssh.exe" ($vagrantConfig -match 'ProxyCommand C:/Windows/System32/OpenSSH/ssh\.exe')
        Assert-LabTest 'Vagrant reaches matrix through the certified jump host' ($vagrantSsh -eq 0)
    }
    else { Write-Host '  (not elevated: KVP and Vagrant checks skipped)' }
}
finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }

Complete-LabTest 'Test-LabSshCertificates'
