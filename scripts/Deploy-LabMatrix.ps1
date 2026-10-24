<#
.SYNOPSIS
    Deploys (or updates) the Matrix stack on the lab VM "matrix": Synapse, PostgreSQL, Traefik,
    the Matrix Authentication Service (MAS, login through Keycloak), Element Web and LiveKit for
    calls, with matrix-docker-ansible-deploy (MDAD).

.DESCRIPTION
    Runs on the Windows host, in PowerShell, as your own Windows user (no administrator
    rights needed). Everything happens over SSH on ansible-control, the lab's Ansible control
    node, as for every other playbook of the lab.

    WHAT HAPPENS, IN ORDER
      1. Old plain-text secrets (keys\matrix\secrets.yml, keys\keycloak\secrets.yml, from before
         OpenBao) are imported into OpenBao unchanged, if those files still exist
         (Import-LabSecrets.ps1).
      2. MDAD's code from the repository: vendor\mdad (MDAD at the pinned commit with its roles,
         see vendor\README.md) is copied to ~/mdad on ansible-control, replacing what was there,
         as Invoke-LabPlaybook.ps1 does with ~/lab. Nothing is downloaded from GitHub.
      3. Preparation (ansible\playbooks\matrix-prepare.yml, via Invoke-LabPlaybook.ps1, with a
         run token): lab root CA trusted on ansible-control and the Matrix VM, DNS, Keycloak and
         OpenBao's ACME directory checked from the VM, the MDAD version in ~/mdad checked, our
         inventory and the entry point lab-setup.yml put in place, the Matrix secrets present
         in OpenBao. Then a snapshot of OpenBao (Backup-LabVault.ps1): secrets created by a
         first deployment exist only there.
      4. MDAD itself, in ~/mdad on ansible-control, through lab-setup.yml (which reads the
         secrets from OpenBao into memory first), with a new run token: the tags of
         "just install-all" (or "just setup-all" with -Setup). It installs Docker on the Matrix
         VM, pulls the container images, writes the configuration, creates systemd units
         matrix-*.service and starts everything. The first run takes a while (image downloads).
         Users are not created here: a Matrix account is created on the user's first login
         through Keycloak.
      5. Checks: Traefik serves certificates from OpenBao's intermediate CA (ACME) for all three
         names; MDAD's self-check (client API, Element, well-known files with valid
         certificates) and "mas-cli doctor" (MAS, its connection to Synapse; it only reports);
         then two checks that stop the script if they fail: Synapse's
         /_matrix/client/v1/auth_metadata must name MAS as issuer, and MAS's
         /auth/upstream/authorize/<ULID> must redirect to Keycloak.

    Prerequisites: OpenBao and Keycloak are deployed (.\scripts\Deploy-LabVault.ps1,
    .\scripts\Deploy-LabKeycloak.ps1), and the firewall publishes the Matrix VM with the names
    matrix, element and @ and the LiveKit ports TCP 7881 and UDP 7882 ("published" in
    config\lab.json, applied by .\scripts\New-LabFirewall.ps1 -Rebuild).

    Safe to run repeatedly: every step is idempotent. Run it again after changing
    ansible\matrix\ or the pinned MDAD version.

.PARAMETER Setup
    Run the tags of "just setup-all" instead of "just install-all". Needed after REMOVING a
    component from vars.yml (install-all skips uninstall tasks and is 2-5x faster otherwise).

.EXAMPLE
    .\scripts\Deploy-LabMatrix.ps1
    .\scripts\Deploy-LabMatrix.ps1 -Setup
#>
# WHY MDAD, AND WHY PINNED
# A Matrix server with calls is a dozen cooperating services. MDAD is a widely used,
# community-maintained Ansible playbook that knows how to install and wire them; writing all of
# that ourselves would be a project of its own. The lab treats it like any third-party
# dependency: one exact version (git commit, mdad_version in matrix-prepare.yml), our own
# configuration in our repository (ansible\matrix\), and upgrades as deliberate, reviewed
# changes. Enterprise equivalent: vendored or pinned automation (an internal mirror of the
# playbook, a version in a requirements file), promoted through test environments.
[CmdletBinding()]
param(
    [switch]$Setup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

$projectRoot = $script:LabProjectRoot
$domain = $script:LabConfig.domain

if (-not (Test-Path (Join-Path $projectRoot 'keys\ssh_config'))) {
    throw 'No SSH configuration found (keys\ssh_config). Run .\scripts\Initialize-Lab.ps1 first.'
}

# Runs MDAD's playbook through the lab's entry point lab-setup.yml, with the given tags, with a
# run token for the policy ansible-matrix (Invoke-LabRunToken, LabSecrets.ps1). The tags are
# those of MDAD's "just" recipes (see vendor\mdad\justfile), which would run setup.yml directly.
# Running it in ~/mdad makes Ansible use MDAD's own ansible.cfg (not the lab's in ~/lab).
# ANSIBLE_HOST_KEY_CHECKING=False: the same LAB SHORTCUT as host_key_checking in the lab's
# ansible.cfg (rebuilt VMs get new SSH host keys). ANSIBLE_COLOR_VERBOSE=magenta: no blue text on
# the blue background of Windows PowerShell.
function Invoke-Mdad([string]$Tags, [string]$What) {
    Invoke-LabRunToken "cd ~/mdad && ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_COLOR_VERBOSE=magenta ansible-playbook -i inventory/hosts lab-setup.yml --tags=$Tags" @('ansible-matrix') 'mdad'
    if ($LASTEXITCODE -ne 0) { throw "$What failed on ansible-control (exit code $LASTEXITCODE)." }
}

# The certificate a server presents for a name (SNI), and whether Windows trusts its chain.
function Get-ServedCertificate([string]$HostName) {
    $tcp = New-Object Net.Sockets.TcpClient($HostName, 443)
    try {
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($HostName)
        return New-Object Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
    }
    finally { $tcp.Close() }
}

# --- 1. Secrets from before OpenBao ----------------------------------------------------------
if ((Test-Path (Join-Path $projectRoot 'keys\matrix\secrets.yml')) -or (Test-Path (Join-Path $projectRoot 'keys\keycloak\secrets.yml'))) {
    Write-Host '== 1/5 Secrets: importing the old plain-text files into OpenBao (Import-LabSecrets.ps1) =='
    & (Join-Path $PSScriptRoot 'Import-LabSecrets.ps1')
}
else {
    Write-Host '== 1/5 Secrets: in OpenBao =='
}

# --- 2. MDAD's code from the repository --------------------------------------------------------
# Everything that runs is in this repository: MDAD and its roles are vendored in vendor\mdad
# (vendor\README.md). Packed into one archive (tar.exe is part of Windows 10), copied with one
# scp call, and unpacked into ~/mdad.new, which then replaces ~/mdad - the same pattern as
# Invoke-LabPlaybook.ps1 uses for ~/lab: the control node keeps no MDAD code of its own that
# could drift. matrix-prepare.yml then adds the lab's inventory and lab-setup.yml.
# The pinned commit must be the same in vendor\mdad\.lab-vendored-commit and in
# matrix-prepare.yml (mdad_version), or the wrong configuration could meet the wrong code.
$vendorDir = Join-Path $projectRoot 'vendor\mdad'
$vendoredCommit = (Get-Content -Raw (Join-Path $vendorDir '.lab-vendored-commit')).Trim()
$prepareText = Get-Content -Raw (Join-Path $projectRoot 'ansible\playbooks\matrix-prepare.yml')
$pinnedCommit = [regex]::Match($prepareText, '(?m)^\s*mdad_version:\s*(\S+)').Groups[1].Value
if ($vendoredCommit -ne $pinnedCommit) {
    throw "vendor\mdad holds MDAD $vendoredCommit, but matrix-prepare.yml pins $pinnedCommit. Make them the same (see vendor\README.md, Upgrade)."
}
Write-Host "== 2/5 MDAD $($vendoredCommit.Substring(0, 7)) from the repository (vendor\mdad) to ~/mdad on ansible-control =="
$sshConfig = Join-Path $projectRoot 'keys\ssh_config'
$archive = Join-Path ([IO.Path]::GetTempPath()) 'lab-mdad.tgz'
& tar -czf $archive -C $vendorDir .
if ($LASTEXITCODE -ne 0) { throw "tar failed (exit code $LASTEXITCODE)." }
try {
    $ErrorActionPreference = 'Continue'
    & scp -q -F $sshConfig -o LogLevel=ERROR $archive 'ansible-control:/tmp/lab-mdad.tgz'
    if ($LASTEXITCODE -ne 0) { throw "Copying MDAD to ansible-control failed (exit code $LASTEXITCODE)." }
    # chmod -R go-w: Ansible ignores an ansible.cfg in a world-writable directory (MDAD's own
    # ansible.cfg sits in ~/mdad).
    & ssh -F $sshConfig -o LogLevel=ERROR ansible-control 'rm -rf ~/mdad.new && mkdir ~/mdad.new && tar -xzf /tmp/lab-mdad.tgz -C ~/mdad.new && rm -f /tmp/lab-mdad.tgz && chmod -R go-w ~/mdad.new && rm -rf ~/mdad && mv ~/mdad.new ~/mdad'
    if ($LASTEXITCODE -ne 0) { throw "Unpacking MDAD on ansible-control failed (exit code $LASTEXITCODE)." }
    $ErrorActionPreference = 'Stop'
}
finally { Remove-Item -Force -ErrorAction SilentlyContinue $archive }

# --- 3. Preparation ----------------------------------------------------------------------------
Write-Host '== 3/5 Preparation: CA trust, checks, MDAD version, inventory, secrets (matrix-prepare.yml) =='
& (Join-Path $PSScriptRoot 'Invoke-LabPlaybook.ps1') matrix-prepare.yml
$prepareExitCode = $LASTEXITCODE
# On a first deployment matrix-prepare.yml has just created the Matrix secrets inside OpenBao,
# the only place they exist: a snapshot keeps them (Backup-LabVault.ps1), also after a failure.
try { & (Join-Path $PSScriptRoot 'Backup-LabVault.ps1') }
catch { Write-Warning "OpenBao snapshot failed: $($_.Exception.Message)" }
if ($prepareExitCode -ne 0) { throw "matrix-prepare.yml failed (exit code $prepareExitCode)." }

# --- 4. MDAD -------------------------------------------------------------------------------------
$recipe = 'install-all'
if ($Setup) { $recipe = 'setup-all' }
Write-Host "== 4/5 MDAD: the tags of just $recipe, through lab-setup.yml (the first run downloads Docker and the images; this takes a while) =="
Invoke-Mdad "$recipe,ensure-matrix-users-created,start" "MDAD ($recipe)"

# --- 5. Checks ---------------------------------------------------------------------------------
Write-Host '== 5/5 Checks: ACME certificates, MDAD self-check, mas-cli doctor, login path to Keycloak =='
# Traefik requests its certificates from OpenBao when it starts with a new router (seconds,
# normally). Until then it answers with its own self-signed "TRAEFIK DEFAULT CERT".
# "From OpenBao" means: signed by the CURRENT intermediate CA - compared by key identifier (the
# served certificate's authority key identifier = the CA's subject key identifier), because an
# older intermediate (before a rotation, or before a rebuild of the vault VM) may have the same
# name.
$issuingCa = (Invoke-LabBao GET 'pki_int/cert/ca').data.certificate
$issuingCaCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($issuingCa))
$caKeyId = ($issuingCaCert.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension] }).SubjectKeyIdentifier
function Get-AuthorityKeyId($Certificate) {
    # DER: SEQUENCE { [0] keyIdentifier } = 30 len 80 len <key id bytes>
    $extension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.35' }
    if (-not $extension -or $extension.RawData[2] -ne 0x80) { return '' }
    $length = $extension.RawData[3]
    return -join ($extension.RawData[4..(3 + $length)] | ForEach-Object { $_.ToString('X2') })
}
foreach ($name in "matrix.$domain", "element.$domain", $domain) {
    $deadline = (Get-Date).AddMinutes(3)
    while ($true) {
        $served = $null
        try { $served = Get-ServedCertificate $name } catch { }
        if ($served -and (Get-AuthorityKeyId $served) -eq $caKeyId) { break }
        if ((Get-Date) -gt $deadline) {
            throw "Traefik does not serve a certificate from OpenBao for $name (issuer: '$($served.Issuer)'). Look at: .\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-traefik -n 80'"
        }
        Start-Sleep -Seconds 5
    }
    Write-Host ("Check: {0,-22} certificate from {1}, valid until {2:yyyy-MM-dd}" -f $name, ($served.Issuer -replace '^CN=', ''), $served.NotAfter)
}

# MDAD's self-check fetches the client API, Element and the well-known files with certificate
# verification. One task of it prints "fatal ... 404 ... /_matrix/federation/v1/version" and is
# then marked "ignored": with federation switched off, that 404 is the expected answer.
# "mas-cli doctor" checks MAS from inside its container: its view of the well-known file, of
# Synapse and of the login API. It only REPORTS (its exit code is always 0), so read its output;
# the two checks after it are the ones that can fail the script.
Invoke-Mdad 'self-check' 'The self-check'
Invoke-Mdad 'matrix-authentication-service-mas-cli-doctor' 'mas-cli doctor'

# Synapse delegates login to MAS: its auth metadata endpoint (Matrix OAuth 2.0 API) answers
# only when that delegation is on, and names MAS as the issuer.
$masIssuer = "https://matrix.$domain/auth/"
# curl.exe is Windows' own (Schannel): it trusts the lab root from your Windows store and checks
# revocation through the CRLs the vault VM publishes on port 80.
$metadata = & curl.exe -s --max-time 15 "https://matrix.$domain/_matrix/client/v1/auth_metadata" | ConvertFrom-Json
if ($metadata.issuer -ne $masIssuer) { throw "Synapse does not report MAS ($masIssuer) as its issuer (got '$($metadata.issuer)')." }
Write-Host "Check: Synapse delegates login to MAS ($masIssuer)"
# The first step of every login: MAS sends the browser to Keycloak. MAS answers with this
# redirect only after it has fetched Keycloak's discovery document from inside its container,
# so this proves the container's DNS, its trust in the lab root CA and the exact issuer. The
# provider ID is read from the single place it is defined (group_vars/all.yml).
$allVars = Get-Content -Raw (Join-Path $projectRoot 'ansible\inventory\group_vars\all.yml')
$providerId = [regex]::Match($allVars, '(?m)^lab_mas_keycloak_provider_id:\s*(\S+)').Groups[1].Value
$answer = & curl.exe -s -o NUL --max-time 15 -w '%{http_code} %{redirect_url}' "${masIssuer}upstream/authorize/$providerId"
$status, $location = "$answer" -split ' ', 2
if ($status -notmatch '^30[0-9]$' -or $location -notlike "https://keycloak.$domain/realms/*") {
    throw "MAS does not send logins to Keycloak (HTTP $status, Location '$location'). Look at: .\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-authentication-service -n 50'"
}
Write-Host "Check: MAS sends logins to Keycloak ($($location.Split('?')[0]))"

Write-Host ''
Write-Host "Matrix is ready:  https://element.$domain  (homeserver https://matrix.$domain)"
Write-Host 'Sign in through Keycloak as alice or bob. Password to the clipboard:'
Write-Host '  .\scripts\Show-LabSecret.ps1 keycloak/users/alice'
Write-Host 'alice may use Matrix admin tools (MAS policy admin_users).'
