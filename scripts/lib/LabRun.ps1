<#
.SYNOPSIS
    Runs on ansible-control: the PC half of every Ansible run of the lab ("lab.ps1 run", and the
    deploy and up commands).

.DESCRIPTION
    Not run directly: scripts\lib\Lab.ps1 loads it. The lab's configuration is applied by Ansible
    on the VM ansible-control, never from the Windows PC. One run, for one profile of
    config\run-profiles.json:

      1. Pack the repository's ansible\ folder, config\lab.json and config\run-profiles.json, the
         firewall's helper opnsense\lab-gui-cert.php and the PUBLIC files of the lab root CA into
         one archive, and copy it to ansible-control (scp through the firewall, like every SSH
         connection into the lab). A profile's "vendor" list adds those folders of vendor\ to
         the archive (~/lab/vendor/<name>: the Rancher chart, for example). With "syncMdad" also
         vendor\mdad, which lives on in ~/mdad.
      2. Sign ansible-control's own key for this run: an SSH certificate valid 2 hours, only for the
         principals of the profile (LabSsh.ps1, Get-LabControlCertificate).
      3. If the profile needs OpenBao: a token for exactly its policies, through the profile's
         token role (ansible-run: 2 hours; ansible-config: 30 minutes), bound to ansible-control's
         address, handed over WRAPPED on stdin (New-LabRunToken in LabSecrets.ps1;
         ansible\bin\openbao-run unwraps it and revokes it at the end).
      4. One SSH call starts ansible\bin\lab-run there: it replaces ~/lab with the fresh copy,
         installs the certificate, runs the playbook, and removes the certificate again.

    PATTERN: "THE REPOSITORY IS THE SOURCE OF TRUTH, THE CONTROL NODE GETS A FRESH COPY"
    The desired state of the lab lives in version-controlled files, and the machine that applies
    it keeps no state of its own that could drift: ~/lab is replaced rather than merged, so files
    deleted in the repository also disappear on the VM, and a quick fix made directly on the VM
    cannot silently survive. ansible-control keeps no standing credential either: every run gets
    its own short-lived certificate and token. Enterprise equivalent: AWX / Ansible Automation
    Platform or a CI/CD runner that checks out a reviewed commit and receives short-lived
    credentials per job.
#>

$script:LabRunProfilesFile = Join-Path $script:LabProjectRoot 'config\run-profiles.json'

function Get-LabRunProfiles {
    return (Get-Content -Raw $script:LabRunProfilesFile | ConvertFrom-Json).profiles
}

# The archive for one run: ansible\, the run's data from config\, the firewall's GUI helper and the
# public PKI files (an explicit list: nothing else from keys\ ever leaves the PC), and the folders
# of vendor\ the profile names.
function New-LabSyncArchive([string]$Path, [string[]]$Vendor = @()) {
    $stage = Join-Path ([IO.Path]::GetTempPath()) "lab-sync-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        Copy-Item -Recurse (Join-Path $script:LabProjectRoot 'ansible') $stage
        New-Item -ItemType Directory -Force -Path (Join-Path $stage 'config'), (Join-Path $stage 'opnsense') | Out-Null
        Copy-Item (Join-Path $script:LabProjectRoot 'config\lab.json'), $script:LabRunProfilesFile (Join-Path $stage 'config')
        Copy-Item (Join-Path $script:LabProjectRoot 'config\nginx.json') (Join-Path $stage 'config')
        foreach ($name in $Vendor) {
            if ($name -notmatch '^[a-z0-9-]+$' -or $name -eq 'mdad') { throw "run-profiles.json: vendor '$name' is not a vendor\ folder for ~/lab (mdad has syncMdad)." }
            $source = Join-Path $script:LabProjectRoot "vendor\$name"
            if (-not (Test-Path $source)) { throw "vendor\$name is missing." }
            New-Item -ItemType Directory -Force -Path (Join-Path $stage 'vendor') | Out-Null
            Copy-Item -Recurse $source (Join-Path $stage "vendor\$name")
        }
        foreach ($helper in 'lab-gui-cert.php', 'lab-rustfs.php', 'lab-nginx.php') {
            Copy-Item (Join-Path $script:LabProjectRoot "opnsense\$helper") (Join-Path $stage 'opnsense')
        }
        if (Test-Path $script:LabRootCaCert) {
            New-Item -ItemType Directory -Force -Path (Join-Path $stage '.pki\pub') | Out-Null
            Copy-Item $script:LabRootCaCert (Join-Path $stage '.pki')
            foreach ($file in 'root-ca.crt', 'root-ca.crl') {
                $source = Join-Path $script:LabKeysDir "pki\pub\$file"
                if (Test-Path $source) { Copy-Item $source (Join-Path $stage '.pki\pub') }
            }
        }
        # tar.exe is part of Windows 10 (version 1803 and later).
        & tar -czf $Path -C $stage .
        if ($LASTEXITCODE -ne 0) { throw "tar failed (exit code $LASTEXITCODE)." }
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage }
}

# One run on ansible-control. $Name is a profile of config\run-profiles.json, or the file name of
# a playbook in ansible\playbooks (it then runs with the profile that names that playbook; a
# playbook without a profile runs with a certificate for every machine and no OpenBao token, with
# a warning). $ExtraArgs go to ansible-playbook (or the command) unchanged: -v, --check --diff,
# --tags x, -e key=value. They must not contain quotes: the remote command line is put together as
# text, and Windows PowerShell 5.1 does not pass embedded double quotes to native programs.
# The run's output goes to the pipeline as it arrives (callers either let it show or capture it,
# as the tests do); its exit code is left in $LASTEXITCODE - 75 means "another run is active".
function Invoke-LabRun([string]$Name, [string[]]$ExtraArgs = @()) {
    $profiles = Get-LabRunProfiles
    $profileArg = $Name
    $runProfile = $profiles.$Name
    if (-not $runProfile -and $Name -like '*.yml') {
        $file = $Name -replace '^playbooks[\\/]', ''
        foreach ($property in $profiles.PSObject.Properties) {
            if ($property.Value.playbook -eq "playbooks/$file") { $runProfile = $property.Value; $profileArg = $property.Name }
        }
        if (-not $runProfile) {
            if (-not (Test-Path (Join-Path $script:LabProjectRoot "ansible\playbooks\$file"))) { throw "Playbook not found: ansible\playbooks\$file" }
            Write-Host "Run:         $file has no profile in config\run-profiles.json: SSH certificate for every machine (lab-all), no OpenBao token"
            $runProfile = [pscustomobject]@{ principals = @('lab-all') }
            $profileArg = "file:playbooks/$file"
        }
    }
    if (-not $runProfile) { throw "No run profile '$Name' (config\run-profiles.json). .\lab.ps1 run lists them." }
    foreach ($argument in $ExtraArgs) {
        if ($argument -match "[`"']") { throw 'Arguments for a run must not contain quotes.' }
    }
    $policies = @($runProfile.policies | Where-Object { $_ })
    $principals = @($runProfile.principals | Where-Object { $_ })
    $sshConfig = Get-LabSshConfig
    if ($policies.Count -gt 0) {
        $health = Get-LabVaultHealth
        if (-not $health) { throw "OpenBao ($script:LabVaultUrl) is not reachable; this run needs it. Is the vault VM running, and has OpenBao been deployed (.\lab.ps1 deploy vault)?" }
        if ($health.sealed) { Unlock-LabVault }
    }

    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $archive = Join-Path ([IO.Path]::GetTempPath()) "lab-sync-$id.tgz"
    $mdadArchive = Join-Path ([IO.Path]::GetTempPath()) "lab-mdad-$id.tgz"
    $options = @()
    try {
        New-LabSyncArchive $archive @($runProfile.vendor | Where-Object { $_ })
        $files = @($archive)
        if ($runProfile.syncMdad) {
            & tar -czf $mdadArchive -C (Join-Path $script:LabProjectRoot 'vendor\mdad') .
            if ($LASTEXITCODE -ne 0) { throw "tar of vendor\mdad failed (exit code $LASTEXITCODE)." }
            $files += $mdadArchive
            $options += "--mdad /tmp/lab-mdad-$id.tgz"
        }
        Copy-LabSshFile $files 'ansible-control:/tmp/' -ConfigFile $sshConfig
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue $archive, $mdadArchive }

    # The certificate first: the wrapping token below is valid for 120 seconds only.
    if ($principals.Count -gt 0) { $options += "--cert $(Get-LabControlCertificate $principals)" }
    $extra = ($ExtraArgs | ForEach-Object { "$_" }) -join ' '
    $unpack = "mkdir -p -m 700 ~/.lab-incoming && mkdir -m 700 ~/.lab-incoming/$id && tar -xzf /tmp/lab-sync-$id.tgz -C ~/.lab-incoming/$id && rm -f /tmp/lab-sync-$id.tgz"
    $after = "rc=`$?; rm -rf ~/.lab-incoming/$id /tmp/lab-mdad-$id.tgz /tmp/lab-sync-$id.tgz; exit `$rc"
    $ErrorActionPreference = 'Continue'
    if ($policies.Count -gt 0) {
        # A wrapped token on stdin, so no pseudo-terminal (-t would echo stdin). Colour is switched
        # on with ANSIBLE_FORCE_COLOR instead, when this console can show it.
        if (Enable-LabConsoleColors) { $options += '--color' }
        $tokenRole = if ($runProfile.tokenRole) { $runProfile.tokenRole } else { 'ansible-run' }
        $wrapped = New-LabRunToken $policies $profileArg $tokenRole
        $wrapped | & ssh -F $sshConfig -o LogLevel=ERROR ansible-control "{ $unpack && bash ~/.lab-incoming/$id/bin/lab-run $id $profileArg $($options -join ' ') --token -- $extra; $after; } 2>&1"
        $wrapped = $null
    }
    else {
        # -t: a pseudo-terminal, so ansible-playbook prints colours - unless the output is
        # redirected (a log file would get escape codes and ssh's "Connection closed").
        $tty = @(); if (-not [Console]::IsOutputRedirected) { $tty = @('-t') }
        & ssh -F $sshConfig -o LogLevel=ERROR @tty ansible-control "{ $unpack && bash ~/.lab-incoming/$id/bin/lab-run $id $profileArg $($options -join ' ') -- $extra; $after; } 2>&1"
    }
    if ($LASTEXITCODE -eq 75) { Write-Host 'Another run is active on ansible-control (one at a time); try again when it has finished.' }
}

# ".\lab.ps1 run [<profile>|<playbook.yml>] [arguments for ansible-playbook]". Without arguments it
# lists the profiles. The exit code of the run is passed on.
function Invoke-LabRunCli {
    if ($args.Count -eq 0) {
        Write-Host 'Run profiles (config\run-profiles.json):  .\lab.ps1 run <profile> [ansible-playbook options]'
        foreach ($property in (Get-LabRunProfiles).PSObject.Properties) {
            $p = $property.Value
            $what = if ($p.playbook) { $p.playbook } else { $p.command }
            $rights = @()
            $principals = @($p.principals | Where-Object { $_ })
            $policies = @($p.policies | Where-Object { $_ })
            if ($principals.Count -gt 0) { $rights += "SSH: $($principals -join ',')" }
            if ($policies.Count -gt 0) { $rights += "OpenBao: $($policies -join ',')$(if ($p.tokenRole) { " via $($p.tokenRole)" })" }
            Write-Host ("  {0,-22} {1}  ({2})" -f $property.Name, $what, $(if ($rights) { $rights -join '; ' } else { 'no credentials' }))
        }
        return
    }
    $name = "$($args[0])"
    $extra = @()
    if ($args.Count -gt 1) { $extra = @($args[1..($args.Count - 1)] | ForEach-Object { "$_" }) }
    Invoke-LabRun $name $extra
}
