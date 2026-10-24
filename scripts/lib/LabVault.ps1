<#
.SYNOPSIS
    OpenBao on the PC side: deploying and configuring it, snapshots, the UI token, unsealing and the
    maintenance step.

.DESCRIPTION
    Not run directly: scripts\lib\Lab.ps1 loads it. The functions are the lab.ps1 commands
    "deploy vault" (Invoke-LabVaultDeploy), "backup" (Backup-LabOpenBao), "ui" (Open-LabVaultUi),
    "unseal" (Invoke-LabUnseal) and "maintain" (Invoke-LabMaintenance).
#>

<#
.SYNOPSIS
    Deploys and configures OpenBao on the lab VM "vault": the lab's secrets manager and
    certificate authority (intermediate CA with an ACME server).

.DESCRIPTION
    Runs on the Windows host, in PowerShell, as your own Windows user. Talks to the vault VM
    over SSH (through the firewall) and to OpenBao's API over HTTPS
    (https://vault.lab.internal:8200, certificate pinned to the lab root, see LabSecrets.ps1).

    WHAT HAPPENS, IN ORDER (every step is idempotent: it checks first, then acts)
      1. Offline root CA: created if missing, its revocation list kept current
         (lib\LabPki.ps1).
      2. OpenBao's own TLS certificate: key and certificate request made ON the vault VM, signed
         by the root on this PC, installed back. The private key never leaves the VM.
      3. ansible\playbooks\openbao.yml: package, configuration, service, nginx for CRLs.
      4. Initialisation (only the very first time): OpenBao creates its master key and splits
         the key that protects it into 3 shares (Shamir's secret sharing, any 2 unlock).
         Shares A and B go straight into DPAPI on this PC; share C waits (DPAPI-protected) until
         you move it to paper and the recovery file with .\lab.ps1 recovery. The
         initial root token is stored the same way, only until step 7. Nothing is printed.
      5. Unseal with shares A and B.
      6. Configuration (re-applied on every run, so the code is the truth), in two planes:
         IDENTITY PLANE, from this PC through the API - who may do what:
         - access policies, one per consumer, least privilege (config\openbao\policies\*.hcl)
         - AppRoles "pc-admin" and "pc-deploy" for this PC (credentials stored with DPAPI,
           usable only from your PC's address), the break-glass AppRole "recovery" (its
           secret only in the recovery file), and the token roles "ansible-run" (deployments),
           "ansible-config" (the configuration plane) and "ui-admin" (lab.ps1 ui)
         - SSH: the secrets engine "ssh", an SSH CA whose key is generated inside OpenBao, and
           the roles pc, ansible-control and lab-hosts (scripts\lib\LabSsh.ps1, $LabSshRoles)
         - the intermediate CA: key generated inside OpenBao, certificate signed by the offline
           root on this PC; a new one 400 days before the current one expires
         CONFIGURATION PLANE, by Ansible on ansible-control (ansible\playbooks\openbao-config.yml,
         profile openbao-config, a token of the role ansible-config for that run only) - the
         engines and how they behave:
         - secrets engine "lab" (KV version 2, check-and-set required)
         - password policies (OpenBao generates passwords, Ansible never invents them)
         - PKI: the intermediate's mount, its URLs, revocation lists, tidying, roles, ACME
         Its token cannot write a policy, a login or a CA, so the configuration plane cannot
         hand out rights. ".\lab.ps1 run openbao-config --check --diff" shows what it would change.
      7. End of the bootstrap: once a pc-admin login works, the root token is revoked and its
         DPAPI file deleted. Routine administration then uses pc-admin.
      8. SSH CA in use (once): OpenBao's SSH CA public key goes to every machine (firewall,
         VMs, the PC's known_hosts), a login with a throwaway certificate from OpenBao is
         tried on each of them, and only when all pass does OpenBao take over signing the SSH
         certificates from the offline SSH CA (Enable-LabOpenBaoSshCa in LabSsh.ps1).

    It refuses to initialise a NEW OpenBao while key shares of an earlier one exist in
    keys\openbao (they could be the only way to restore a backup).

    MAINTENANCE: running it again renews what is due - the root CRL (60 days before it
    expires), OpenBao's TLS certificate (30 days before), the intermediate CA (400 days
    before) - and publishes the new CRL. lab.ps1 up runs it by itself when one of
    them is due (Get-LabMaintenanceDue in LabSecrets.ps1).

.PARAMETER RotateIntermediate
    Make a new intermediate CA now, even if the current one is still valid long enough (for
    example after a suspected key compromise, or to try the rotation). The old one stays in
    OpenBao for its revocation list; new certificates come from the new one.

.EXAMPLE
    .\lab.ps1 deploy vault
    .\lab.ps1 deploy vault -RotateIntermediate
#>
function Invoke-LabVaultDeploy {
    [CmdletBinding()]
    param(
        [switch]$RotateIntermediate
    )


    $projectRoot = $script:LabProjectRoot
    $domain = $script:LabConfig.domain
    $vaultName = "vault.$domain"
    $published = $script:LabConfig.published | Where-Object { $_.vm -eq 'vault' }
    $issuedDir = Join-Path $script:LabKeysDir 'pki\issued'
    # The PKI mount is also named in the playbooks (tasks/openbao-certificate.yml) and MDAD's
    # vars.yml (ACME directory): change it in all places. The intermediate's names carry its year
    # (a rotation within the same year adds the date, see step 6).
    $pkiMount = 'pki_int'
    $intermediateKeyName = "lab-int-$(Get-Date -Format yyyy)"
    $intermediateCommonName = "DeployableServer Lab Intermediate CA $(Get-Date -Format yyyy)"

    # A command on the vault VM (as user ansible, sudo inside the command). No double quotes in
    # $Command (Windows PowerShell 5.1). Returns the output lines. Get-LabSshConfig renews the PC's
    # SSH certificate when it is due; while OpenBao's own TLS certificate has expired, the offline
    # SSH CA signs it (LabSsh.ps1), so this renewal never depends on OpenBao being reachable.
    function Invoke-VaultSsh([string]$Command, [string]$What) {
        $sshConfig = Get-LabSshConfig
        $ErrorActionPreference = 'Continue'
        $output = & ssh -F $sshConfig -o LogLevel=ERROR vault "{ $Command; } 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "$What failed on vault (exit code $LASTEXITCODE): $($output -join ' ')" }
        return $output
    }

    # --- 0. Preconditions -----------------------------------------------------------------------
    $answer = @(Resolve-DnsName -Name $vaultName -Type A -DnsOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    if (($answer -join ',') -ne $published.address) {
        throw "$vaultName resolves to '$($answer -join ', ')' for this PC, expected $($published.address). Is vault published in config\lab.json and the firewall rebuilt (.\lab.ps1 firewall -Rebuild)?"
    }

    # --- 1. Offline root CA -----------------------------------------------------------------------
    Write-Host '== 1/8 Offline root CA =='
    Initialize-LabRootCa
    $rootCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $script:LabRootCaCert

    # --- 2. OpenBao's TLS certificate ----------------------------------------------------------------
    Write-Host '== 2/8 TLS certificate of OpenBao (signed by the offline root) =='
    function Test-ListenerCertificate {
        $pem = Invoke-VaultSsh 'sudo cat /opt/openbao/tls/tls.crt 2>/dev/null || true' 'Reading the TLS certificate'
        $text = ($pem -join "`n")
        if ($text -notmatch '-----BEGIN CERTIFICATE-----') { return $false }
        $b64 = ($text -replace '(?s).*?-----BEGIN CERTIFICATE-----', '' -replace '(?s)-----END CERTIFICATE-----.*', '' -replace '\s', '')
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Convert]::FromBase64String($b64))
        $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
        [void]$chain.ChainPolicy.ExtraStore.Add($rootCert)
        $chained = $chain.Build($cert) -and $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint -eq $rootCert.Thumbprint
        $fresh = $cert.NotAfter -gt (Get-Date).AddDays(30)
        $named = $cert.GetNameInfo('DnsName', $false) -eq $vaultName
        return ($chained -and $fresh -and $named)
    }
    if (Test-ListenerCertificate) {
        Write-Host 'TLS:         current certificate is valid for more than 30 days'
    }
    else {
        # Key on the VM (kept across renewals), certificate request printed to stdout (public).
        $csr = Invoke-VaultSsh "sudo mkdir -p /opt/openbao/tls && { sudo test -s /opt/openbao/tls/tls.key || sudo openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out /opt/openbao/tls/tls.key; } && sudo chmod 0600 /opt/openbao/tls/tls.key && sudo openssl req -new -key /opt/openbao/tls/tls.key -subj /CN=$vaultName" 'Creating the key and request'
        $csrFile = Join-Path $issuedDir 'vault.csr'
        [IO.File]::WriteAllText($csrFile, (($csr -join "`n") + "`n"))
        $certFile = Join-Path $issuedDir 'vault.crt'
        Invoke-LabRootCaSign -Csr $csrFile -Kind Server -DnsName $vaultName -OutFile $certFile
        Remove-Item -Force $csrFile
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($certFile))
        # "systemctl reload" (SIGHUP) makes a running OpenBao read the new files at once (it also
        # watches them, tls_auto_reload); it does not seal it. On the first run OpenBao is not
        # installed yet, hence "|| true".
        Invoke-VaultSsh "echo $b64 | base64 -d | sudo tee /opt/openbao/tls/tls.crt.new >/dev/null && sudo mv /opt/openbao/tls/tls.crt.new /opt/openbao/tls/tls.crt && sudo chmod 0644 /opt/openbao/tls/tls.crt && (id openbao >/dev/null 2>&1 && sudo chown openbao:openbao /opt/openbao/tls/tls.crt /opt/openbao/tls/tls.key || true) && (sudo systemctl reload openbao 2>/dev/null || true)" 'Installing the certificate' | Out-Null
        Write-Host "TLS:         new certificate for $vaultName installed (397 days)"
    }

    # --- 3. Package and configuration --------------------------------------------------------------
    Write-Host '== 3/8 OpenBao package, configuration, service (openbao.yml) =='
    Invoke-LabRun openbao
    if ($LASTEXITCODE -ne 0) { throw "openbao.yml failed (exit code $LASTEXITCODE)." }

    # --- 4. Initialisation (once) -----------------------------------------------------------------
    Write-Host '== 4/8 Initialisation =='
    $health = Wait-LabVaultReachable 120
    if ($health.initialized) {
        Write-Host 'OpenBao:     already initialised'
    }
    else {
        if (Test-LabSecret 'openbao/unseal-a') {
            throw "keys\openbao holds key shares of an earlier OpenBao. They are not overwritten (they may be needed to restore a backup). lab.ps1 down moves them aside when it deletes the vault VM; otherwise move keys\openbao away on purpose before initialising a new one."
        }
        $init = Invoke-LabBao POST 'sys/init' @{ secret_shares = 3; secret_threshold = 2 }
        # Stored before anything else happens; nothing of it is printed.
        Protect-LabSecret 'openbao/unseal-a' $init.keys_base64[0]
        Protect-LabSecret 'openbao/unseal-b' $init.keys_base64[1]
        Protect-LabSecret 'openbao/unseal-c-pending' $init.keys_base64[2]
        Protect-LabSecret 'openbao/root-token' $init.root_token
        $init = $null
        Write-Host 'OpenBao:     initialised (3 key shares, 2 needed). Shares A and B are stored with DPAPI;'
        Write-Host '             share C waits for you: run .\lab.ps1 recovery in your own PowerShell window.'
    }

    # --- 5. Unseal ----------------------------------------------------------------------------------
    Write-Host '== 5/8 Unseal =='
    Unlock-LabVault

    # --- 6. Configuration ---------------------------------------------------------------------------
    # Two planes (ansible\playbooks\openbao-config.yml explains them): the PC writes the IDENTITY
    # plane - who may do what: policies, AppRoles, token roles, the SSH CA - and Ansible on
    # ansible-control writes the CONFIGURATION plane - the engines and how they behave - with a token
    # for one run that cannot touch the identity plane. The intermediate CA's certificate is signed
    # by the offline root, which only this PC holds, so that part stays here as well.
    Write-Host '== 6/8 Configuration: identities and policies (PC), engines (Ansible), intermediate CA (PC) =='
    $token = Get-LabAdminToken
    try {
        function Bao([string]$Method, [string]$Path, $Body) { Invoke-LabBao $Method $Path $Body -Token $token }
        function Test-Mount([string]$Path, [string]$Kind) {
            $list = Bao GET "sys/$Kind"
            return @($list.data.PSObject.Properties.Name) -contains "$Path/"
        }
        # Does the intermediate's mount hold an issuer with its key (a CA that can sign)?
        function Test-Issuer {
            if (-not (Test-Mount $pkiMount 'mounts')) { return $false }
            $issuers = Invoke-LabBao GET "$pkiMount/issuers?list=true" -Token $token -AllowNotFound
            if ($issuers) { foreach ($id in $issuers.data.keys) { if ($issuers.data.key_info.$id.key_id) { return $true } } }
            return $false
        }

        # Access policies (HCL), one file per policy in config\openbao\policies: the file name is the
        # policy's name, its comments say who uses it. Paths of KV v2 have "data/" and "metadata/" in
        # them. "create" without "update" means write-once: a consumer can add a missing secret but
        # never change an existing one; rotation is an administrator's decision.
        foreach ($file in Get-ChildItem (Join-Path $projectRoot 'config\openbao\policies') -Filter '*.hcl') {
            $hcl = [IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
            Bao POST "sys/policies/acl/$($file.BaseName)" @{ policy = $hcl } | Out-Null
        }

        # AppRole: a login for machines (role_id = user name, secret_id = password). The PC's roles
        # only accept logins from the PC's address, and their tokens only work from there.
        #   pc-admin, pc-deploy  everyday logins of the PC's scripts, stored with DPAPI
        #   recovery             the "break-glass" login: administrator rights like pc-admin, but its
        #                        secret_id is stored ONLY in the passphrase-encrypted recovery file
        #                        (lab.ps1 recovery makes a new one for every kit). It is the way
        #                        back in when the PC's DPAPI keys are lost - OpenBao's old way to make a
        #                        new root token from key shares (sys/generate-root without a token) is
        #                        switched off by default since OpenBao 2.5.3.
        if (-not (Test-Mount 'approle' 'auth')) { Bao POST 'sys/auth/approle' @{ type = 'approle' } | Out-Null }
        $pcCidr = "$($script:LabConfig.firewall.pcIp)/32"
        $roles = [ordered]@{
            'pc-admin'  = @{ token_policies = @('openbao-admin'); token_ttl = '30m'; token_max_ttl = '1h' }
            'pc-deploy' = @{ token_policies = @('pc-deploy'); token_ttl = '5m'; token_max_ttl = '10m' }
            'recovery'  = @{ token_policies = @('openbao-admin'); token_ttl = '30m'; token_max_ttl = '1h' }
        }
        foreach ($role in $roles.Keys) {
            $body = $roles[$role]
            $body.token_type = 'service'
            $body.token_bound_cidrs = @($pcCidr)
            $body.secret_id_bound_cidrs = @($pcCidr)
            Bao POST "auth/approle/role/$role" $body | Out-Null
            # A missing DPAPI login (first run, or a new Windows profile) gets a new secret_id; older
            # ones, which nobody can read any more, are destroyed with it.
            if ($role -ne 'recovery' -and -not (Test-LabSecret "openbao/$role")) {
                $login = New-LabAppRoleSecret $role $token
                Protect-LabSecret "openbao/$role" (@{ role_id = $login.role_id; secret_id = $login.secret_id } | ConvertTo-Json -Compress)
                Remove-LabAppRoleSecretIds $role $token $login.accessor
                $login = $null
            }
        }
        # A recovery file made before the break-glass login existed cannot restore administration;
        # the hint at the end asks for a new one (lab.ps1 recovery -Renew).
        $recoveryIds = Invoke-LabBao GET 'auth/approle/role/recovery/secret-id?list=true' -Token $token -AllowNotFound
        $kitOutdated = (-not (Test-LabSecret 'openbao/unseal-c-pending')) -and -not ($recoveryIds -and @($recoveryIds.data.keys).Count -gt 0)

        # Token roles for Ansible runs (New-LabRunToken in LabSecrets.ps1 mints through them). Their
        # tokens are "orphans" (they outlive the PC's short login), cannot be renewed and work only
        # from ansible-control's address:
        #   ansible-run     deployments: the secrets of one application, at most 2 hours (pc-deploy)
        #   ansible-config  openbao-config.yml: OpenBao's configuration plane, at most 30 minutes
        #                   (pc-admin: changing how OpenBao works is an administrator's decision)
        $controlIp = ($script:LabConfig.vms | Where-Object { $_.name -eq 'ansible-control' }).ip
        $tokenRoles = [ordered]@{
            'ansible-run'    = @{ allowed_policies = @('ansible-keycloak', 'ansible-matrix', 'ansible-web'); token_explicit_max_ttl = '2h' }
            'ansible-config' = @{ allowed_policies = @('openbao-config'); token_explicit_max_ttl = '30m' }
        }
        foreach ($role in $tokenRoles.Keys) {
            $body = $tokenRoles[$role]
            $body.orphan = $true; $body.renewable = $false; $body.token_type = 'service'; $body.token_bound_cidrs = @("$controlIp/32")
            Bao POST "auth/token/roles/$role" $body | Out-Null
        }
        # Token role for your web UI sessions (lab.ps1 ui; defined in LabSecrets.ps1).
        Set-LabUiTokenRole $token

        # --- The configuration plane, on ansible-control --------------------------------------------
        # The KV mount "lab", password policies, the intermediate's mount and URLs (they must be set
        # before its first certificate), revocation list, tidying, PKI roles and ACME. On a new
        # OpenBao the PKI roles and ACME wait for the intermediate CA made below, so the run is
        # repeated after it.
        $hadIssuer = Test-Issuer
        Invoke-LabRun openbao-config
        if ($LASTEXITCODE -ne 0) { throw "openbao-config.yml failed (exit code $LASTEXITCODE)." }

        # --- PKI: the intermediate CA ---------------------------------------------------------------
        # The default issuer (the intermediate CA that signs new certificates) must stay valid for
        # longer than the longest certificate it issues (Keycloak's: 1 year) plus a margin, so a new
        # one is made 400 days before the current one expires: a "rotation". The old issuer stays in
        # OpenBao and keeps publishing its revocation list until its last certificates expire; the
        # services move to the new one at their next renewal (Keycloak's playbook and Traefik notice
        # that their certificate comes from another CA). Issuer and key names are unique, so a
        # rotation gets names with the date.
        $hasIssuer = Test-Issuer
        $issuerValid = $false
        if ($hasIssuer) {
            $default = Invoke-LabBao GET "$pkiMount/issuer/default" -Token $token
            $currentIssuer = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, [Text.Encoding]::ASCII.GetBytes($default.data.certificate))
            $issuerValid = $currentIssuer.NotAfter -gt (Get-Date).AddDays(400)
            if (-not $issuerValid) { Write-Host "PKI:         the intermediate CA expires on $($currentIssuer.NotAfter.ToString('yyyy-MM-dd')): making a new one" }
            if ($RotateIntermediate -or -not $issuerValid) {
                # Date and time: unique even for a second rotation on the same day, so a new key is
                # always made (never the key behind the current issuer).
                $intermediateKeyName = "lab-int-$(Get-Date -Format yyyyMMdd-HHmmss)"
                $intermediateCommonName = "DeployableServer Lab Intermediate CA $(Get-Date -Format yyyy-MM-dd)"
            }
        }
        if (-not $hasIssuer -or -not $issuerValid -or $RotateIntermediate) {
            # The intermediate's key is generated inside OpenBao ("internal"): it is never exported.
            # If an earlier run created the key but failed before the certificate was imported, a new
            # request is made for that same key ("existing").
            $keys = Invoke-LabBao GET "$pkiMount/keys?list=true" -Token $token -AllowNotFound
            $keyExists = $false
            if ($keys) { foreach ($id in $keys.data.keys) { if ($keys.data.key_info.$id.key_name -eq $intermediateKeyName) { $keyExists = $true } } }
            $csrBody = @{ common_name = $intermediateCommonName; exclude_cn_from_sans = $true }
            if ($keyExists) {
                $csrBody.key_ref = $intermediateKeyName
                $csrPem = (Bao POST "$pkiMount/intermediate/generate/existing" $csrBody).data.csr
            }
            else {
                $csrBody.key_type = 'ec'; $csrBody.key_bits = 384; $csrBody.key_name = $intermediateKeyName
                $csrPem = (Bao POST "$pkiMount/intermediate/generate/internal" $csrBody).data.csr
            }
            $csrFile = Join-Path $issuedDir "$intermediateKeyName.csr"
            [IO.File]::WriteAllText($csrFile, $csrPem + "`n")
            $intermediateFile = Join-Path $issuedDir "$intermediateKeyName.crt"
            Invoke-LabRootCaSign -Csr $csrFile -Kind Intermediate -OutFile $intermediateFile
            Remove-Item -Force $csrFile
            $imported = Bao POST "$pkiMount/intermediate/set-signed" @{ certificate = [IO.File]::ReadAllText($intermediateFile) }
            $issuerId = @($imported.data.imported_issuers)[0]
            Bao POST "$pkiMount/issuer/$issuerId" @{
                issuer_name = $intermediateKeyName; leaf_not_after_behavior = 'truncate'
                usage = 'read-only,issuing-certificates,crl-signing,ocsp-signing'
            } | Out-Null
            Bao POST "$pkiMount/config/issuers" @{ default = $intermediateKeyName; default_follows_latest_issuer = $false } | Out-Null
            Write-Host "PKI:         intermediate CA created in OpenBao, signed by the offline root ($intermediateFile)"
        }
        else { Write-Host 'PKI:         intermediate CA present' }
        if (-not $hadIssuer) {
            Write-Host 'PKI:         the new intermediate CA can sign: openbao-config.yml again, for the PKI roles and ACME'
            Invoke-LabRun openbao-config
            if ($LASTEXITCODE -ne 0) { throw "openbao-config.yml failed (exit code $LASTEXITCODE)." }
        }

        # --- SSH: the online SSH CA -------------------------------------------------------------------
        # OpenBao's SSH secrets engine in "CA mode": it signs SSH public keys and returns certificates
        # (scripts\lib\LabSsh.ps1 explains them). One CA key for user and host certificates; the roles keep
        # the two apart (allow_user_certificates / allow_host_certificates), and OpenSSH itself never
        # accepts a host certificate as a user login or the other way round.
        # Audit: OpenBao's audit log normally stores every request and response value only as an HMAC
        # (a keyed hash). For SSH, principals, type, lifetime and serial number are logged in plain
        # text, so a login in a machine's SSH log (it names the serial) can be found in OpenBao's log.
        $sshMount = $script:LabSshMount
        if (-not (Test-Mount $sshMount 'mounts')) { Bao POST "sys/mounts/$sshMount" @{ type = 'ssh'; description = 'Lab SSH CA: user and host certificates' } | Out-Null }
        Bao POST "sys/mounts/$sshMount/tune" @{ max_lease_ttl = '8760h'; audit_non_hmac_request_keys = @('valid_principals', 'cert_type', 'ttl'); audit_non_hmac_response_keys = @('serial_number') } | Out-Null
        # The CA key is generated ONCE. Writing config/ca again would silently replace the CA, and
        # every machine would reject the next certificate - so it is only written when reading it
        # says there is none yet (HTTP 4xx), never on other errors.
        $sshCaExists = $true
        try { [void](Bao GET "$sshMount/config/ca") }
        catch { if ($_.Exception.Message -match '\(HTTP 4\d\d\)') { $sshCaExists = $false } else { throw } }
        if (-not $sshCaExists) {
            Bao POST "$sshMount/config/ca" @{ generate_signing_key = $true; key_type = 'ed25519' } | Out-Null
            Write-Host 'SSH CA:      new SSH CA created inside OpenBao (its key never leaves it)'
        }
        # Roles: every value set explicitly (the defaults are permissive or useless: unset lifetimes
        # fall back to 32 days, an unset key ID names only "approle"). The same table as the offline CA
        # uses, so both issue identical certificates:
        #   key_id_format       <role>-<hash of the public key>: every certificate names its holder in
        #                       the SSH logs
        #   allowed_extensions  "": the requester cannot add extensions; default_extensions apply
        #   not_before_duration valid from 5 minutes ago (a VM whose clock lags a little)
        #   source-address      the certificate works only from the holder's own addresses
        $userPrincipals = Get-LabSshUserPrincipals
        $hostNames = @(Get-LabSshMachines | ForEach-Object { Get-LabSshFqdn $_ })
        foreach ($role in $script:LabSshRoles.Keys) {
            $spec = $script:LabSshRoles[$role]
            $body = @{ key_type = 'ca'; allow_user_key_ids = $false; key_id_format = '{{role_name}}-{{public_key_hash}}'
                allowed_extensions = ''; allow_empty_principals = $false; not_before_duration = '5m'
                ttl = "$($spec.Hours)h"; max_ttl = "$($spec.Hours)h" }
            $extensions = @{}
            foreach ($extension in $spec.Extensions) { $extensions[$extension] = '' }
            $body.default_extensions = $extensions
            if ($spec.Type -eq 'host') {
                # Exactly the lab's host names (no subdomains, no wildcards).
                $body.allow_host_certificates = $true; $body.allow_user_certificates = $false
                $body.allowed_domains = $hostNames -join ','; $body.allow_bare_domains = $true; $body.allow_subdomains = $false
            }
            else {
                $body.allow_user_certificates = $true; $body.allow_host_certificates = $false
                $body.allowed_users = if ($role -eq 'pc') { 'lab-all' } else { $userPrincipals -join ',' }
                $body.allowed_critical_options = 'source-address'
                $body.default_critical_options = @{ 'source-address' = $spec.SourceAddress }
            }
            Bao POST "$sshMount/roles/$role" $body | Out-Null
        }

        # --- 7. End of the bootstrap -----------------------------------------------------------------
        if (Test-LabSecret 'openbao/root-token') {
            Write-Host '== 7/8 Bootstrap: test pc-admin, then revoke the root token =='
            $pcToken = Get-LabBaoToken 'pc-admin'
            $self = Invoke-LabBao GET 'auth/token/lookup-self' -Token $pcToken
            if (@($self.data.policies) -notcontains 'openbao-admin') { throw 'pc-admin login works, but without the openbao-admin policy. Root token kept.' }
            Close-LabBaoToken $pcToken
            $rootToken = Unprotect-LabSecret 'openbao/root-token'
            Invoke-LabBao POST 'auth/token/revoke-self' $null -Token $rootToken | Out-Null
            $rootToken = $null
            Remove-Item -Force (Get-LabSecretPath 'openbao/root-token')
            $token = $null
            Write-Host 'OpenBao:     root token revoked; administration uses the pc-admin AppRole from now on'
        }
        else { Write-Host '== 7/8 Bootstrap: already finished (no root token stored) ==' }
    }
    finally {
        if ($token) { Close-LabBaoToken $token }
    }

    # --- 8. SSH CA in use ---------------------------------------------------------------------------
    Write-Host '== 8/8 SSH CA: every machine trusts OpenBao''s SSH CA =='
    Enable-LabOpenBaoSshCa

    # --- Checks -----------------------------------------------------------------------------------
    # openbao-config.yml has checked the intermediate CA certificate and the ACME directory; what
    # is left is the root CRL, published on port 80 by openbao.yml.
    $crlStatus = (Invoke-WebRequest -UseBasicParsing -Uri "http://$vaultName/pki/root-ca.crl").StatusCode
    if ($crlStatus -ne 200) { throw "The root CRL is not served on http://$vaultName/pki/root-ca.crl (HTTP $crlStatus)." }
    Write-Host 'Check:       root CRL served on port 80'

    Write-Host ''
    Write-Host "OpenBao is ready:  https://${vaultName}:8200/ui/"
    if (Test-LabSecret 'openbao/unseal-c-pending') {
        Write-Host 'PENDING: key share C and the recovery file. Run in your own PowerShell window:  .\lab.ps1 recovery'
    }
    elseif ($kitOutdated) {
        Write-Host 'PENDING: your recovery file has no break-glass login (it was made before that existed). Make a new one in your own PowerShell window:  .\lab.ps1 recovery -Renew'
    }
    elseif (-not (Test-LabSshCaInRecoveryKit)) {
        Write-Host 'PENDING: your recovery file has no copy of the current offline SSH CA. Make a new one in your own PowerShell window:  .\lab.ps1 recovery -Renew'
    }
}

<#
.SYNOPSIS
    Saves a snapshot (backup) of OpenBao's data to this PC (lab.ps1 backup).

.DESCRIPTION
    OpenBao's integrated storage (raft) can export all its data as one snapshot file. The file is
    encrypted by OpenBao's own barrier: without OpenBao's unseal key shares it is useless, so it may
    be stored like any backup, e.g. next to the recovery file (lab.ps1 recovery). Restoring needs
    the key shares that were valid when the snapshot was taken - keep both, but in different places.
    It logs in with the "pc-deploy" AppRole (DPAPI, allowed only from your PC), whose policy may
    read exactly this endpoint, saves keys\openbao\snapshots\vault-<date-time>.snap and keeps the
    newest -Keep files. Restore (onto a rebuilt vault VM, rare): README, "Restore OpenBao from a
    snapshot". The deployments take one after every run.

.PARAMETER Destination
    Also copy the snapshot to this folder (for example a NAS share).

.PARAMETER Keep
    How many snapshots to keep in keys\openbao\snapshots (default 10).
#>
function Backup-LabOpenBao {
    [CmdletBinding()]
    param(
        [string]$Destination,
        [int]$Keep = 10
    )
    $folder = Join-Path $script:LabKeysDir 'openbao\snapshots'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $file = Join-Path $folder ("vault-{0}.snap" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $token = Get-LabBaoToken 'pc-deploy'
    try {
        # The TLS pin must be active before the download (Invoke-WebRequest does not go through
        # Invoke-LabBao): only a certificate under the lab root is accepted for vault.
        Initialize-LabTls
        Invoke-WebRequest -UseBasicParsing -Headers @{ 'X-Vault-Token' = $token } -Uri "$script:LabVaultUrl/v1/sys/storage/raft/snapshot" -OutFile $file
    }
    finally { Close-LabBaoToken $token }
    $size = (Get-Item $file).Length
    if ($size -lt 1024) { throw "The snapshot $file is suspiciously small ($size bytes)." }
    Write-Host "Snapshot: $file ($([int]($size / 1KB)) KB)"
    Get-ChildItem $folder -Filter 'vault-*.snap' | Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item -Force
    if ($Destination) {
        Copy-Item $file $Destination
        Write-Host "Copied to $Destination"
    }
}

<#
.SYNOPSIS
    Opens OpenBao's web UI and puts a login token for it on the clipboard, valid 1 hour (lab.ps1 ui).

.DESCRIPTION
    OpenBao's web UI (https://vault.lab.internal:8200/ui/) shows the lab's secrets (KV mount "lab"),
    policies, AppRoles, the PKI with its certificates and issuers, the SSH CA and the audit devices.
    Nobody has a personal OpenBao account in the lab: every login is a machine login (AppRoles
    pc-admin, pc-deploy, recovery), and the initial root token was revoked. So this makes a
    short-lived token for you: it logs in as pc-admin (DPAPI, only from your PC), creates a token
    through the token role "ui-admin" (administrator policy, at most 1 hour, usable only from your
    PC's address, an orphan so it outlives the pc-admin login), copies it to the clipboard and opens
    the UI. In the UI choose the method "Token", paste it (Ctrl+V) and sign in; "Sign out" revokes it
    at once. Every request is in OpenBao's audit log, under the display name "token-ui".

    Careful: the token has full administrator rights. A change made by hand in the UI is not in the
    repository and is overwritten or lost at the next "lab.ps1 deploy vault" or rebuild (secrets you
    change there are the exception: they live only in OpenBao). The proper way for people is a
    personal login through the company's identity provider (OIDC); for the lab that is on the
    roadmap (Keycloak as login for OpenBao). Windows' clipboard history (Win+V), if you switched it
    on, keeps copied text.

.PARAMETER NoBrowser
    Only copy the token, do not open the browser.
#>
function Open-LabVaultUi {
    [CmdletBinding()]
    param([switch]$NoBrowser)
    $health = Get-LabVaultHealth
    if (-not $health) { throw "OpenBao ($script:LabVaultUrl) is not reachable. Is the vault VM running (.\lab.ps1 up)?" }
    if ($health.sealed) { Unlock-LabVault }
    $admin = Get-LabBaoToken 'pc-admin'
    try {
        # The role belongs to "deploy vault"; applied here too, for a lab deployed before it existed.
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
}

<#
.SYNOPSIS
    Unseals OpenBao on the vault VM after it was started (lab.ps1 unseal).

.DESCRIPTION
    After every start (VM boot, service restart) OpenBao is "sealed": its data stays encrypted until
    enough key shares are presented. This sends key shares A and B, stored with DPAPI on this PC,
    over HTTPS; "lab.ps1 up" does it after starting the VMs. Running it again on an unsealed OpenBao
    does nothing. -Interactive asks for two shares instead (recovery after the PC's DPAPI data was
    lost: share B from the recovery file, see "lab.ps1 recovery -Open", and share C from your copy);
    run that in your own PowerShell window. Until OpenBao is unsealed, nothing that needs it works:
    certificate renewals (ACME), the secrets for deployments, SSH certificates from OpenBao.

.PARAMETER Interactive
    Type two key shares instead of using the ones stored on this PC.
#>
function Invoke-LabUnseal {
    [CmdletBinding()]
    param([switch]$Interactive)
    Unlock-LabVault -Interactive:$Interactive
}

<#
.SYNOPSIS
    Renews what is due (lab.ps1 maintain): OpenBao's TLS certificate, the root CA's revocation
    list, the intermediate CA, Keycloak's certificate.

.DESCRIPTION
    Certificates expire, and they are only renewed when the code that renews them runs.
    Get-LabMaintenanceDue (LabSecrets.ps1) checks what is due - all public, no login needed - and
    this runs the lab.ps1 command that renews it ("deploy vault" or "deploy keycloak"). "lab.ps1 up"
    calls it at its end, after every Windows restart.

.PARAMETER List
    Only show what is due.
#>
function Invoke-LabMaintenance {
    [CmdletBinding()]
    param([switch]$List)
    $due = Get-LabMaintenanceDue
    foreach ($item in $due) { Write-Host "Maintenance: $($item.What) is due -> .\lab.ps1 $($item.Action -join ' ')" }
    if ($due.Count -eq 0) { Write-Host 'Maintenance: no certificate or revocation list is due'; return }
    if ($List) { return }
    foreach ($action in @($due | ForEach-Object { $_.Action -join ' ' } | Select-Object -Unique)) {
        Invoke-LabCommand ($action -split ' ')[0] @(($action -split ' ') | Select-Object -Skip 1)
    }
}
