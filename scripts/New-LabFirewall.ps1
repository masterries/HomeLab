<#
.SYNOPSIS
    Builds the lab firewall: an OPNsense 26.7 VM on Hyper-V, configured from the repository.

.DESCRIPTION
    WHAT THIS IS
    The lab's perimeter firewall is OPNsense (open source, FreeBSD/pf based, web GUI and REST
    API). There is no Vagrant box for OPNsense on Hyper-V, so this script builds the VM itself.
    It runs on the Windows host in an elevated PowerShell and is normally called by
    scripts\Initialize-Lab.ps1 (step 4); it can also be run on its own.

    BUILD STEPS (each one is skipped when its result already exists)
      1. Image: download the official OPNsense "nano" image (already installed, no installer)
         once into a cache on G:, check its SHA-256 against the value pinned below and its
         signature against OPNsense's signing key, unpack it (Git for Windows' bzip2) and turn
         the raw disk image into a VHDX.
      2. Secrets: random passwords for root (GUI login) and ansible, an API key for Ansible,
         encrypted with DPAPI in keys\opnsense\*.dpapi (LabSecrets.ps1: only your Windows
         account can decrypt them). The root password, for the GUI login:
           .\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password
      3. GUI certificate for firewall.lab.internal, signed by the lab's offline root CA
         (New-LabRootCA.ps1, keys\pki), so the GUI opens without a browser warning. The
         firewall exists before OpenBao and its intermediate CA, so the root signs it directly,
         like OpenBao's own certificate.
      4. Configuration: opnsense\config.xml.template + config\lab.json (VMs, published
         addresses, names and ports) -> config.xml, checked and packed into a small ISO. The
         rendered file holds password hashes and the GUI's private key, so it exists only in the
         ISO's staging folder and the ISO, and both are deleted once the firewall has imported
         it.
      5. VM: Generation 1 (the nano image boots with BIOS only), 1 vCPU (the 26.7 kernel can
         panic on Hyper-V with more; fixed in 26.7.7), 3 GB RAM, three network adapters with
         fixed MACs, all still DISCONNECTED, COM1 as a named pipe.
      6. First boot, driven over the serial console like the Unix tool "expect": answer
         OPNsense's configuration importer with the ISO, connect the network adapters, wait
         for the login prompt. With the adapters disconnected until our configuration is in,
         OPNsense's factory default (a DHCP server on its first adapter) never reaches a
         real network.
      7. Over SSH (as ansible, through the new firewall): check the adapter mapping, install
         the split-horizon DNS drop-in, update OPNsense to the latest 26.7.x (the images are
         only released for 26.7; the Hyper-V fixes came in 26.7.6/26.7.7), reboot if needed,
         and renew the GUI certificate in place when it is due (Update-GuiCertificate).
      8. Checks: version, interfaces, DNS answers seen from your PC.

    RE-RUNS
    If the firewall VM already exists (built by this script, recognised by a tag in its Notes),
    nothing is rebuilt: the VM is started if it is off, the DNS drop-in is re-applied, a
    pending update or reboot is finished, the GUI certificate is renewed in place when it
    expires within 30 days or does not come from the lab root CA, and the checks run.
    Changes to opnsense\ or to
    config\lab.json (VMs, "published") are only applied by a rebuild. Use -Rebuild to throw
    it away and build it again from the repository (the "cattle, not pets" idea: servers are
    rebuilt from code instead of being repaired by hand).

    WHAT IS KEPT WHERE
      G:\Vagrant\images\opnsense\26.7\   downloaded image and base VHDX (cache, reused)
      G:\Vagrant\hyperv\firewall\        the VM: configuration, disk, serial console log
      keys\opnsense\                      passwords and API key (DPAPI-encrypted)
      keys\pki\issued\firewall-gui.crt    the GUI certificate (public; its key is only on the
                                          firewall)

.PARAMETER StorageRoot
    Folder for images and VMs. Default: G:\Vagrant (C: stays free).

.PARAMETER TimeZone
    Time zone of the firewall (IANA name). Default: Europe/Berlin.

.PARAMETER Rebuild
    Delete an existing firewall VM and build it again.

.EXAMPLE
    .\scripts\New-LabFirewall.ps1
    .\scripts\New-LabFirewall.ps1 -Rebuild
#>
[CmdletBinding()]
param(
    [string]$StorageRoot = 'G:\Vagrant',
    [string]$TimeZone = 'Europe/Berlin',
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
# DPAPI storage for the secrets and the path of the lab root CA ($script:LabRootCaCert).
. (Join-Path $PSScriptRoot 'LabSecrets.ps1')

# --- Pins and paths ---------------------------------------------------------------------------
# Pinned image: changing the version is a deliberate edit here. The SHA-256 comes from
# OPNsense's signed checksum file and release notes; the key fingerprint identifies the
# OPNsense 26.7 signing key (SHA-256 of the DER-encoded public key).
$opnVersion = '26.7'
$imageName = "OPNsense-$opnVersion-nano-amd64.img"
$imageSha256 = '28d5e2f37e40d87468a924e3006ef10e2ddc6de485b85333d9e3958c84d0cb9d'
$signingKeySha256 = '1c940b2feb8e8c78ba7348a50b11f476929ddca1794ceaa89446be7d515e0d02'
$mirror = "https://pkg.opnsense.org/releases/$opnVersion"
$minimumVersion = [version]'26.7.7'

$projectRoot = Split-Path -Parent $PSScriptRoot
$lab = Get-Content -Raw (Join-Path $projectRoot 'config\lab.json') | ConvertFrom-Json
$cacheDir = Join-Path $StorageRoot "images\opnsense\$opnVersion"
$baseVhdx = Join-Path $cacheDir "nano-$opnVersion-base.vhdx"
$vmName = 'firewall'
$vmRoot = Join-Path $StorageRoot 'hyperv'
$vmDir = Join-Path $vmRoot $vmName
$diskPath = Join-Path $vmDir 'Virtual Hard Disks\firewall.vhdx'
$seedIso = Join-Path $vmDir 'seed\lab-config.iso'
$serialLog = Join-Path $vmDir 'logs\serial-console.log'
$pipeName = 'lab-firewall-com1'
$vmTag = 'managed-by=DeployableServer/scripts/New-LabFirewall.ps1'
$keysDir = Join-Path $projectRoot 'keys'
$secretsDir = Join-Path $keysDir 'opnsense'
$sshConfig = Join-Path $keysDir 'ssh_config'
$knownHosts = Join-Path $keysDir 'known_hosts'
$openssl = Join-Path $env:ProgramFiles 'Git\mingw64\bin\openssl.exe'
$bzip2 = Join-Path $env:ProgramFiles 'Git\mingw64\bin\bzip2.exe'

# Hyper-V adapters in the order FreeBSD will number them (hn0, hn1, hn2); config.xml.template
# binds wan/lan/opt1 to exactly these names. Each adapter is named after its role and has a
# fixed MAC, so the mapping can be checked after boot. 02 = locally administered MAC.
$adapters = @(
    @{ Name = 'WAN';  Switch = 'Default Switch'; Mac = '02000A0A0AFE'; Device = 'hn0' },
    @{ Name = 'LAN';  Switch = 'LabNet';         Mac = '02000A0A0A01'; Device = 'hn1' },
    @{ Name = 'HOST'; Switch = 'LabHost';        Mac = '02000A0A0A02'; Device = 'hn2' }
)

# --- Small helpers ----------------------------------------------------------------------------

# Access only for you (no inherited rights), as for the SSH key: the files hold secrets.
function Protect-File([string]$Path) {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $Path /inheritance:r /grant:r "${me}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed for $Path (exit code $LASTEXITCODE)." }
}

function New-RandomBytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return $bytes
}

# Letters and digits only, so the value is safe in any shell, XML file or command line.
function New-RandomText([int]$Length) {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-RandomBytes $Length
    return -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# Runs Git for Windows' OpenSSL (the native mingw64 build, not the MSYS one, which would
# rewrite arguments such as "/CN=..." as if they were paths). OpenSSL writes progress messages
# to stderr; in Windows PowerShell 5.1 that could turn into a terminating error, so success is
# judged by the exit code only. Deliberately simple functions using $args: an "advanced"
# function would try to bind OpenSSL options such as -out to its own parameters
# (-OutVariable), instead of passing them on.
function Invoke-OpenSsl {
    $ErrorActionPreference = 'Continue'
    $output = & $openssl @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "openssl $($args[0]) failed (exit code $LASTEXITCODE): $($output -join ' ')" }
    return $output
}

# Same, for checks such as "openssl verify", where a non-zero exit code is an answer
# ("no"), not an error. Returns $true for exit code 0.
function Test-OpenSsl {
    $ErrorActionPreference = 'Continue'
    & $openssl @args 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# SHA-512-crypt ("$6$salt$hash"), a format OPNsense accepts for passwords and API secrets
# (it checks them with PHP's password_verify). Only the hash goes into config.xml.
# The secret goes to openssl on stdin ("-stdin"), never on its command line: command lines of
# running processes are visible to other programs and can be logged by Windows (process
# auditing, Sysmon, security software). Started through .NET's Process class rather than a
# PowerShell pipe, which would add CR LF; and .NET Framework writes a UTF-8 byte order mark
# into the child's stdin when the console's input encoding is UTF-8, which openssl would hash
# as part of the password - so the input encoding is set to UTF-8 without BOM for the start.
function Get-PasswordHash([string]$Secret, [string]$Salt = (New-RandomText 16)) {
    $psi = New-Object Diagnostics.ProcessStartInfo $openssl, "passwd -6 -salt $Salt -stdin"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $savedEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding $false
        $process = [Diagnostics.Process]::Start($psi)
    }
    finally { [Console]::InputEncoding = $savedEncoding }
    $process.StandardInput.Write("$Secret`n")
    $process.StandardInput.Close()
    $hash = $process.StandardOutput.ReadToEnd().Trim()
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $hash -notmatch '^\$6\$') { throw "openssl passwd failed (exit code $($process.ExitCode)): $errorText" }
    return $hash
}

# OPNsense refers to certificates by a "refid": 13 hex characters.
function New-RefId {
    return (-join ((New-RandomBytes 7) | ForEach-Object { $_.ToString('x2') })).Substring(0, 13)
}

function ConvertTo-Base64([string]$Text) {
    return [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Text))
}

# Run a command on the firewall over SSH, as user ansible (keys\ssh_config: firewall = the
# fixed address 10.10.99.2). No double quotes inside $Command: Windows PowerShell 5.1 does not
# pass them correctly to native programs.
function Invoke-FirewallSsh([string]$Command, [switch]$AllowFailure) {
    # Remote programs may write to stderr; only the exit code decides (see Invoke-OpenSsl).
    $ErrorActionPreference = 'Continue'
    $output = & ssh -F $sshConfig -o LogLevel=ERROR -o ConnectTimeout=10 firewall $Command
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "SSH command on the firewall failed (exit code $LASTEXITCODE): $Command"
    }
    return $output
}

function Wait-TcpPort([string]$Address, [int]$Port, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $connect = $client.ConnectAsync($Address, $Port)
            if ($connect.Wait(3000) -and $client.Connected) { return }
        }
        catch { }
        finally { $client.Close() }
        Start-Sleep -Seconds 3
    }
    throw "Timeout: nothing answers on ${Address}:$Port after $TimeoutSeconds s."
}

# --- Serial console ("expect" in PowerShell) -------------------------------------------------
# Hyper-V connects the VM's COM1 to a named pipe (\\.\pipe\lab-firewall-com1). The OPNsense nano
# image uses the serial port as its main console, so this script can read everything the
# firewall prints at boot and type answers, like a person at a terminal. Every answer is only
# sent after the expected prompt has been read; nothing is typed blind. The whole session is
# logged to G:\Vagrant\hyperv\firewall\logs\serial-console.log for troubleshooting.
$script:serialPipe = $null
$script:serialRead = $null
$script:serialChunk = New-Object byte[] 4096
$script:serialText = New-Object Text.StringBuilder

function Open-SerialConsole([int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName,
            [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $pipe.Connect(1000)
            $script:serialPipe = $pipe
            return
        }
        catch {
            $pipe.Dispose()
            if ((Get-Date) -gt $deadline) { throw "Could not open the serial console pipe \\.\pipe\$pipeName." }
        }
    }
}

# Collects whatever the VM has printed so far (waits at most ~200 ms per call).
function Receive-SerialOutput {
    if (-not $script:serialRead) {
        $script:serialRead = $script:serialPipe.ReadAsync($script:serialChunk, 0, $script:serialChunk.Length)
    }
    while ($script:serialRead.Wait(200)) {
        $count = $script:serialRead.Result
        if ($count -le 0) { throw 'The serial console pipe was closed by Hyper-V.' }
        $text = [Text.Encoding]::ASCII.GetString($script:serialChunk, 0, $count)
        [void]$script:serialText.Append($text)
        [IO.File]::AppendAllText($serialLog, $text)
        $script:serialRead = $script:serialPipe.ReadAsync($script:serialChunk, 0, $script:serialChunk.Length)
    }
}

# Waits until the console output matches $Pattern (a regex) and returns the text up to and
# including the match; that text is then removed from the buffer, so the next wait only looks
# at newer output. $FailPattern aborts early on known error messages.
function Wait-SerialText([string]$Pattern, [int]$TimeoutSeconds, [string]$FailPattern) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Receive-SerialOutput
        $text = $script:serialText.ToString()
        if ($FailPattern -and $text -match $FailPattern) {
            throw "The firewall reported '$($Matches[0])' on its console. Details: $serialLog"
        }
        $match = [regex]::Match($text, $Pattern)
        if ($match.Success) {
            [void]$script:serialText.Remove(0, $match.Index + $match.Length)
            return $text.Substring(0, $match.Index + $match.Length)
        }
    }
    throw "Timeout after $TimeoutSeconds s waiting for '$Pattern' on the firewall console. Details: $serialLog"
}

# Types text on the console. "`r" is the Enter key of a serial terminal.
function Send-SerialText([string]$Text) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
    $script:serialPipe.Write($bytes, 0, $bytes.Length)
    $script:serialPipe.Flush()
}

function Close-SerialConsole {
    if ($script:serialPipe) { $script:serialPipe.Dispose() }
    $script:serialPipe = $null
    $script:serialRead = $null
}

# --- Step functions ---------------------------------------------------------------------------

# 1. Image: download, verify, unpack and convert once; later builds reuse the base VHDX.
function Get-BaseImage {
    if (Test-Path $baseVhdx) { Write-Host "Image:       $baseVhdx (cached)"; return }
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    foreach ($file in "OPNsense-$opnVersion.pub", "OPNsense-$opnVersion-checksums-amd64.sha256",
                      "OPNsense-$opnVersion-checksums-amd64.sha256.sig", "$imageName.sig", "$imageName.bz2") {
        $target = Join-Path $cacheDir $file
        if (-not (Test-Path $target)) {
            Write-Host "Downloading $mirror/$file ..."
            & curl.exe -fsSL --retry 3 -o $target "$mirror/$file"
            if ($LASTEXITCODE -ne 0) { Remove-Item -Force -ErrorAction SilentlyContinue $target; throw "Download of $file failed." }
        }
    }
    Push-Location $cacheDir
    try {
        # Trust chain: the signing key must be the pinned one; it must have signed the checksum
        # file; the image must match both the pinned hash and the signed checksum file; and
        # after unpacking, the image itself must carry a valid signature.
        Invoke-OpenSsl pkey -pubin -in "OPNsense-$opnVersion.pub" -outform DER -out signing-key.der | Out-Null
        if ((Get-FileHash signing-key.der -Algorithm SHA256).Hash.ToLower() -ne $signingKeySha256) { throw 'The OPNsense signing key does not match the pinned fingerprint.' }
        Invoke-OpenSsl base64 -d -in "OPNsense-$opnVersion-checksums-amd64.sha256.sig" -out checksums.sig.bin | Out-Null
        $verify = Invoke-OpenSsl dgst -sha256 -verify "OPNsense-$opnVersion.pub" -signature checksums.sig.bin "OPNsense-$opnVersion-checksums-amd64.sha256"
        if (($verify -join '') -ne 'Verified OK') { throw 'The signature of the checksum file is invalid.' }
        $hash = (Get-FileHash "$imageName.bz2" -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $imageSha256) { throw "SHA-256 of $imageName.bz2 is $hash, expected $imageSha256." }
        if (-not (Select-String -Path "OPNsense-$opnVersion-checksums-amd64.sha256" -SimpleMatch $hash -Quiet)) { throw 'Image hash not found in the signed checksum file.' }
        Write-Host 'Image verified (pinned hash, signed checksums). Unpacking ...'
        # Git for Windows' bzip2: Windows' own tar.exe cannot unpack a single .bz2 file.
        & $bzip2 -d -k -f "$imageName.bz2"
        if ($LASTEXITCODE -ne 0) { throw 'bzip2 failed.' }
        Invoke-OpenSsl base64 -d -in "$imageName.sig" -out image.sig.bin | Out-Null
        $verify = Invoke-OpenSsl dgst -sha256 -verify "OPNsense-$opnVersion.pub" -signature image.sig.bin $imageName
        if (($verify -join '') -ne 'Verified OK') { throw 'The signature of the unpacked image is invalid.' }
        # Raw image -> VHDX without extra tools: a fixed-size VHD is exactly the raw disk data
        # followed by a 512-byte footer. So: create a fixed VHD of the image's size, copy the
        # image over its data part, then let Hyper-V convert it to a dynamic VHDX.
        $length = (Get-Item $imageName).Length
        $fixedVhd = Join-Path $cacheDir 'nano-fixed.vhd'
        Remove-Item -Force -ErrorAction SilentlyContinue $fixedVhd
        New-VHD -Path $fixedVhd -Fixed -SizeBytes $length | Out-Null
        if ((Get-Item $fixedVhd).Length -ne $length + 512) { throw 'Unexpected fixed VHD layout.' }
        $source = [IO.File]::OpenRead((Join-Path $cacheDir $imageName))
        $target = [IO.File]::Open($fixedVhd, 'Open', 'Write')
        try { $source.CopyTo($target, 4MB) } finally { $source.Dispose(); $target.Dispose() }
        Convert-VHD -Path $fixedVhd -DestinationPath $baseVhdx -VHDType Dynamic
        # Keep the downloads (a cache; the .bz2 can be unpacked again), delete the 3 GB raw
        # image, the fixed VHD and the intermediate files of the signature checks.
        Remove-Item -Force $fixedVhd, (Join-Path $cacheDir $imageName), signing-key.der, checksums.sig.bin, image.sig.bin
    }
    finally { Pop-Location }
    Write-Host "Image:       $baseVhdx (built)"
}

# 2. Secrets: generated once, reused by every rebuild (so your GUI password stays the same).
#    Stored with DPAPI (LabSecrets.ps1) as keys\opnsense\<name>.dpapi.
$firewallSecretNames = [ordered]@{ Root = 'opnsense/root-password'; Ansible = 'opnsense/ansible-password'; Api = 'opnsense/api-ansible' }

# The plain-text files of earlier versions (root-password.txt, ansible-password.txt,
# api-ansible.txt) are moved into DPAPI once, with the same values, and deleted. Runs on every
# run and never decrypts anything. If a DPAPI blob exists already, it is the value in use, and
# the old file is only removed.
function Move-OldSecrets {
    $oldFiles = @{ Root = 'root-password.txt'; Ansible = 'ansible-password.txt'; Api = 'api-ansible.txt' }
    foreach ($part in $firewallSecretNames.Keys) {
        $oldFile = Join-Path $secretsDir $oldFiles[$part]
        if (-not (Test-Path $oldFile)) { continue }
        if (-not (Test-LabSecret $firewallSecretNames[$part])) { Protect-LabSecret $firewallSecretNames[$part] ([IO.File]::ReadAllText($oldFile).Trim()) }
        Remove-Item -Force $oldFile
        Write-Host "Secrets:     $($oldFiles[$part]) moved into DPAPI ($($firewallSecretNames[$part]))"
    }
}

# For a build: the three secrets, made when missing. The ansible password and the API key are
# only used by the firewall being built (Ansible itself logs in with the SSH key), so if they
# cannot be decrypted any more (another Windows profile, after New-LabRecoveryKit.ps1 -Recover
# with an older recovery file), new ones are made. The root password is your GUI login: if it
# cannot be decrypted, the script stops and says how to get it back.
function Get-Secrets {
    foreach ($part in $firewallSecretNames.Keys) {
        $name = $firewallSecretNames[$part]
        $usable = $false
        if (Test-LabSecret $name) {
            try { [void](Unprotect-LabSecret $name); $usable = $true }
            catch {
                if ($part -eq 'Root') {
                    throw "keys\opnsense\root-password.dpapi cannot be decrypted by this Windows account. Restore it with .\scripts\New-LabRecoveryKit.ps1 -Recover <file> (or delete it to get a new GUI password)."
                }
                Write-Host "Secrets:     $name cannot be decrypted by this Windows account; a new one is made"
            }
        }
        if (-not $usable) {
            if ($part -eq 'Api') {
                # Same format OPNsense uses when it creates a key in the GUI: key and secret are
                # base64 of 60 random bytes, kept as "key=..." and "secret=..." lines.
                $value = "key=$([Convert]::ToBase64String((New-RandomBytes 60)))`nsecret=$([Convert]::ToBase64String((New-RandomBytes 60)))"
            }
            else { $value = New-RandomText 24 }
            Protect-LabSecret $name $value -Force
            $value = $null
        }
    }
    $api = @{}
    (Unprotect-LabSecret $firewallSecretNames.Api) -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $name, $value = $_ -split '=', 2; $api[$name] = $value }
    return @{
        RootPassword    = Unprotect-LabSecret $firewallSecretNames.Root
        AnsiblePassword = Unprotect-LabSecret $firewallSecretNames.Ansible
        ApiKey          = $api['key']
        ApiSecret       = $api['secret']
    }
}

# 3. GUI certificate for a NEW firewall (its config.xml must contain one): key and request
#    made here in a temporary folder, signed by the lab's offline root CA (New-LabRootCA.ps1;
#    a copy of the certificate stays in keys\pki\issued). The key is not kept: it goes only into
#    the rendered config.xml, which is deleted after the import. A RUNNING firewall gets a new
#    certificate in place instead, with a key made on the firewall (Update-GuiCertificate).
#    Only the domain name goes into the certificate, no IP addresses: the root's name
#    constraints allow names under the lab domain only.
function Get-GuiCertificate {
    $name = "firewall.$($lab.domain)"
    $work = Join-Path $secretsDir 'gui-new'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $key = Join-Path $work 'gui.key'
        $csr = Join-Path $work 'firewall-gui.csr'
        Invoke-OpenSsl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $key -subj "/CN=$name" -out $csr | Out-Null
        $crt = Join-Path $keysDir 'pki\issued\firewall-gui.crt'
        & (Join-Path $PSScriptRoot 'New-LabRootCA.ps1') -SignCsr $csr -Kind Server -DnsName $name -OutFile $crt | Out-Null
        return @{
            CaPem  = Get-Content -Raw $script:LabRootCaCert
            CrtPem = Get-Content -Raw $crt
            KeyPem = Get-Content -Raw $key
        }
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
}

# 4a. Render config.xml from the template and check it. Returns the XML text (it holds password
#     hashes and the GUI key, so it is not written to keys\; New-SeedIso puts it into the ISO).
function New-FirewallConfig($Secrets, $Certificate) {
    $vmIp = @{}
    foreach ($vm in $lab.vms) { $vmIp[$vm.name] = $vm.ip }
    # Text from lab.json that ends up inside XML elements (descriptions) is escaped, so a "&"
    # or "<" in a description cannot break the XML.
    $xmlText = { param($Text) [Security.SecurityElement]::Escape([string]$Text) }

    # DHCP reservations and DNS names, one <hosts> entry each (dnsmasq model). OPNsense writes
    # every address of every entry as one line into a hosts file (/var/etc/dnsmasq-hosts) and a
    # DHCP reservation for every entry with a MAC.
    #   with a MAC  -> DHCP reservation and DNS name (exactly one IPv4 address allowed)
    #   without MAC -> DNS name only, may carry several addresses (split horizon)
    $hosts = New-Object Text.StringBuilder
    $entry = { param($HostName, $Ip, $Mac, $Description, $Domain = $lab.domain)
        $macLine = ''
        if ($Mac) { $macLine = "<hwaddr>$Mac</hwaddr>" }
        [void]$hosts.AppendLine("    <hosts><host>$HostName</host><domain>$Domain</domain><ip>$Ip</ip>$macLine<descr>$(& $xmlText $Description)</descr></hosts>")
    }
    foreach ($vm in $lab.vms) {
        $mac = ($vm.mac -split '(..)' | Where-Object { $_ }) -join ':'
        & $entry $vm.name $vm.ip $mac.ToLower() 'Lab VM (DHCP reservation)'
    }
    & $entry 'firewall' "$($lab.firewall.lanIp),$($lab.firewall.hostIp)" $null 'Firewall: lab address and management address'

    # Published VMs ("published" in lab.json): per VM one virtual IP on the HOST interface, one
    # port forward per listed port (same port number on the VM), and its names with two
    # addresses each (split horizon: the PC gets the published address, the lab the VM's own).
    $vips = New-Object Text.StringBuilder
    $forwards = New-Object Text.StringBuilder
    $sequence = 100
    $prefixLength = ($lab.hostNetwork -split '/')[1]
    $usedAddresses = @($lab.firewall.hostIp, $lab.firewall.pcIp)
    foreach ($pub in $lab.published) {
        if (-not $vmIp.ContainsKey($pub.vm)) { throw "lab.json, published: unknown VM '$($pub.vm)' (not in vms)." }
        if ($usedAddresses -contains $pub.address) { throw "lab.json, published: address $($pub.address) of '$($pub.vm)' is already used." }
        $usedAddresses += $pub.address
        $labIp = $vmIp[$pub.vm]
        foreach ($name in $pub.names) {
            $addresses = "$labIp,$($pub.address)"
            # A VM published under its own name (matrix -> matrix.lab.internal) already has its
            # lab address from the DHCP reservation entry above; only the published one is added.
            if ($name -eq $pub.vm) { $addresses = $pub.address }
            if ($name -eq '@') {
                # "@" (as in DNS zone files) is the domain itself, here lab.internal: Matrix
                # serves https://lab.internal/.well-known/matrix/... there. OPNsense skips host
                # entries with an empty host name, so the name is split at its first dot
                # instead: host "lab" in domain "internal" gives the same full name lab.internal.
                $apexHost, $apexDomain = $lab.domain -split '\.', 2
                if (-not $apexDomain) { throw "lab.json, published: '@' needs a domain with at least two labels, not '$($lab.domain)'." }
                & $entry $apexHost $addresses $null "Published: the domain itself, served by $($pub.vm)" $apexDomain
            }
            else {
                & $entry $name $addresses $null "Published name of $($pub.vm)"
            }
        }
        [void]$vips.Append(@"
    <vip>
      <interface>opt1</interface>
      <mode>ipalias</mode>
      <subnet>$($pub.address)</subnet>
      <subnet_bits>$prefixLength</subnet_bits>
      <noexpand>0</noexpand>
      <nobind>1</nobind>
      <advbase>1</advbase>
      <advskew>0</advskew>
      <nosync>0</nosync>
      <descr>Published address of $(& $xmlText $pub.vm)</descr>
    </vip>

"@)
        foreach ($port in $pub.ports) {
            if ($port.protocol -notin 'tcp', 'udp') { throw "lab.json, published: protocol '$($port.protocol)' for $($pub.vm) must be tcp or udp." }
            [void]$forwards.Append(@"
    <rule>
      <sequence>$sequence</sequence>
      <interface>opt1</interface>
      <ipprotocol>inet</ipprotocol>
      <protocol>$($port.protocol)</protocol>
      <source>
        <network>any</network>
      </source>
      <destination>
        <network>$($pub.address)</network>
        <port>$([int]$port.port)</port>
      </destination>
      <target>$labIp</target>
      <local-port>$([int]$port.port)</local-port>
      <descr>$(& $xmlText "$($pub.vm): $($port.description)")</descr>
      <pass>rule</pass>
    </rule>

"@)
            $sequence += 10
        }
    }

    $values = @{
        '{{DOMAIN}}'                      = $lab.domain
        '{{TIMEZONE}}'                    = $TimeZone
        '{{LAN_IP}}'                      = $lab.firewall.lanIp
        '{{HOST_IP}}'                     = $lab.firewall.hostIp
        '{{PC_IP}}'                       = $lab.firewall.pcIp
        '{{LAN_POOL_START}}'              = ($lab.firewall.lanIp -replace '\.\d+$', '.100')
        '{{LAN_POOL_END}}'                = ($lab.firewall.lanIp -replace '\.\d+$', '.199')
        '{{ROOT_PASSWORD_HASH}}'          = Get-PasswordHash $Secrets.RootPassword
        '{{ANSIBLE_PASSWORD_HASH}}'       = Get-PasswordHash $Secrets.AnsiblePassword
        '{{ANSIBLE_AUTHORIZED_KEYS_B64}}' = ConvertTo-Base64 (Get-Content -Raw (Join-Path $keysDir 'ansible_ed25519.pub')).Trim()
        '{{ANSIBLE_APIKEYS}}'             = "$($Secrets.ApiKey)|$(Get-PasswordHash $Secrets.ApiSecret)"
        '{{CA_REFID}}'                    = New-RefId
        '{{GUI_CERT_REFID}}'              = New-RefId
        '{{CA_CRT_B64}}'                  = ConvertTo-Base64 $Certificate.CaPem
        '{{GUI_CRT_B64}}'                 = ConvertTo-Base64 $Certificate.CrtPem
        '{{GUI_KEY_B64}}'                 = ConvertTo-Base64 $Certificate.KeyPem
    }
    $xml = Get-Content -Raw (Join-Path $projectRoot 'opnsense\config.xml.template')
    $xml = $xml.Replace('<!--{{DNSMASQ_HOSTS}}-->', $hosts.ToString().TrimEnd())
    $xml = $xml.Replace('<!--{{VIRTUAL_IPS}}-->', $vips.ToString().TrimEnd())
    $xml = $xml.Replace('<!--{{PORT_FORWARDS}}-->', $forwards.ToString().TrimEnd())
    foreach ($placeholder in $values.Keys) { $xml = $xml.Replace($placeholder, $values[$placeholder]) }
    if ($xml -match '\{\{[A-Z_0-9]+\}\}') { throw "Unreplaced placeholder in config.xml: $($Matches[0])" }
    [void][xml]$xml   # must be well-formed XML
    Write-Host 'Config:      config.xml rendered and checked'
    # LF line endings, as OPNsense writes the file itself.
    return ($xml -replace "`r`n", "`n")
}

# 4b. Pack the rendered config.xml into an ISO for OPNsense's configuration importer:
#     ISO 9660 + Joliet image containing conf/config.xml, built with Windows' own IMAPI2 COM
#     component. The importer accepts a CD as its source ("cd9660" fallback). The staging folder
#     is deleted right after, the ISO itself after the first boot (Invoke-FirstBoot).
function New-SeedIso([string]$ConfigXml) {
    New-Item -ItemType Directory -Force -Path (Split-Path $seedIso) | Out-Null
    $staging = Join-Path $vmDir 'seed\content'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $staging
    New-Item -ItemType Directory -Force -Path (Join-Path $staging 'conf') | Out-Null
    $stagedConfig = Join-Path $staging 'conf\config.xml'
    if (-not ('LabIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class LabIsoWriter {
    // Copies IMAPI2's result stream (a COM IStream) into a file, block by block.
    public static void Save(object imageStream, string path, int blockSize, int blockCount) {
        IStream source = (IStream)imageStream;
        byte[] buffer = new byte[blockSize];
        using (FileStream target = File.Create(path)) {
            for (int i = 0; i < blockCount; i++) {
                source.Read(buffer, blockSize, IntPtr.Zero);
                target.Write(buffer, 0, blockSize);
            }
        }
    }
}
'@
    }
    try {
        # No BOM, as OPNsense writes the file itself. Readable only by you while it exists.
        [IO.File]::WriteAllText($stagedConfig, $ConfigXml, (New-Object Text.UTF8Encoding $false))
        Protect-File $stagedConfig
        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $image.FileSystemsToCreate = 3   # 1 = ISO 9660, 2 = Joliet (keeps lower-case names)
        $image.VolumeName = 'LABSEED'
        $image.Root.AddTree($staging, $false)
        $result = $image.CreateResultImage()
        [LabIsoWriter]::Save($result.ImageStream, $seedIso, $result.BlockSize, $result.TotalBlocks)
        Protect-File $seedIso
    }
    # The staged config.xml holds the same secrets: removed on every exit path.
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $staging }
    Write-Host "Seed ISO:    $seedIso"
}

# The seed ISO holds password hashes and the GUI's private key. Ejected and deleted once the
# first boot is over - also when it failed, and on a later run that finds one left behind (the
# configuration importer only ever reads it on the very first boot).
# It never throws: it runs in a "finally", where an error would hide the real one (of a failed
# first boot); a later run tries again.
function Remove-SeedIso {
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        try { Set-VMDvdDrive -VMName $vmName -ControllerNumber 1 -ControllerLocation 0 -Path $null }
        catch { Write-Warning "Could not eject the seed ISO: $($_.Exception.Message)" }
    }
    $seedDir = Split-Path $seedIso
    if (Test-Path $seedDir) {
        try { Remove-Item -Recurse -Force $seedDir }
        catch { Write-Warning "$seedDir (password hashes, the GUI key) could not be deleted: $($_.Exception.Message) The next run tries again; or delete it yourself." }
    }
}

# 5. Create the VM. Network adapters stay disconnected until our configuration is imported.
function New-FirewallVm {
    New-Item -ItemType Directory -Force -Path (Split-Path $diskPath), (Split-Path $serialLog) | Out-Null
    Copy-Item $baseVhdx $diskPath
    # Grow the disk before the first boot: the nano image enlarges its partition and file
    # system to the disk size only once, on its first boot.
    Resize-VHD -Path $diskPath -SizeBytes 16GB
    $vm = New-VM -Name $vmName -Generation 1 -MemoryStartupBytes 3GB -VHDPath $diskPath -Path $vmRoot
    # FreeBSD supports no dynamic memory; ShutDown (not Save) on Windows shutdown, so the
    # firewall boots fresh and gets a new WAN lease when the Default Switch changes its subnet.
    Set-VM -VM $vm -ProcessorCount 1 -StaticMemory -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -Notes $vmTag
    Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter
    foreach ($adapter in $adapters) {
        Add-VMNetworkAdapter -VM $vm -Name $adapter.Name -StaticMacAddress $adapter.Mac
    }
    Set-VMComPort -VM $vm -Number 1 -Path "\\.\pipe\$pipeName"
    if (-not (Get-VMDvdDrive -VM $vm)) { Add-VMDvdDrive -VM $vm -ControllerNumber 1 -ControllerLocation 0 }
    Set-VMDvdDrive -VMName $vmName -ControllerNumber 1 -ControllerLocation 0 -Path $seedIso
    Set-VMBios -VM $vm -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy')
    Write-Host "VM:          $vmName created (Gen 1, 1 vCPU, 3 GB, disk $diskPath)"
}

# 6. First boot: answer the configuration importer, then connect the network adapters.
function Invoke-FirstBoot {
    New-Item -ItemType Directory -Force -Path (Split-Path $serialLog) | Out-Null
    [IO.File]::WriteAllText($serialLog, "=== First boot $(Get-Date -Format s) ===`n")
    Start-VM -Name $vmName
    Open-SerialConsole 60
    try {
        # The importer offers itself for 7 seconds on a fresh disk (the nano image ships no
        # /conf/config.xml). Any key starts it.
        Wait-SerialText 'Press any key to start the configuration importer' 300 | Out-Null
        Send-SerialText ' '
        # It lists the disks (camcontrol devlist); the seed ISO is the CD drive, e.g.
        # "<Msft Virtual CD/ROM 1.0>  at scbus1 target 0 lun 0 (pass0,cd0)".
        $listing = Wait-SerialText 'Select device to import from[^:]*:' 60
        $cd = [regex]::Match($listing, '[(,](cd\d+)[,)]')
        if (-not $cd.Success) { throw "No CD drive in the importer's device list. Details: $serialLog" }
        Send-SerialText "$($cd.Groups[1].Value)`r"
        Wait-SerialText 'Restoring config\.xml\.\.\.done' 60 'No known partition layout|could not be mounted|could not be found|Bootstrapping config\.xml' | Out-Null
        Write-Host "Console:     configuration imported from $($cd.Groups[1].Value)"
        # Our configuration is active from here on: now the adapters may meet real networks.
        foreach ($adapter in $adapters) {
            Connect-VMNetworkAdapter -VMName $vmName -Name $adapter.Name -SwitchName $adapter.Switch
        }
        # Boot continues with our config.xml. If an interface named in it did not exist,
        # OPNsense would stop at an interactive interface assignment instead.
        Wait-SerialText 'login:' 600 'Default interfaces not found|Valid interfaces are' | Out-Null
        Write-Host 'Console:     boot finished (login prompt)'
    }
    finally { Close-SerialConsole }
}

# 7a. The adapters must have come up as hn0/hn1/hn2 in the order they were added.
function Test-AdapterMapping {
    $text = (Invoke-FirewallSsh 'for i in hn0 hn1 hn2; do echo $i $(ifconfig $i ether | grep -o -E ..:..:..:..:..:..); done') -join "`n"
    foreach ($adapter in $adapters) {
        $mac = (($adapter.Mac -split '(..)' | Where-Object { $_ }) -join ':').ToLower()
        if ($text -notmatch "$($adapter.Device) $mac") {
            throw "Adapter mapping differs: expected $($adapter.Device) = $mac ($($adapter.Name)). Firewall reports:`n$text"
        }
    }
    Write-Host 'Adapters:    hn0 = WAN, hn1 = LAN, hn2 = HOST (checked by MAC)'
}

# 7b. Split-horizon DNS drop-in (not part of config.xml, so it is installed on every run).
function Install-DnsDropIn {
    $dropIn = Join-Path $projectRoot 'opnsense\dnsmasq.conf.d\10-lab.conf'
    & scp -q -F $sshConfig -o LogLevel=ERROR $dropIn 'firewall:/tmp/10-lab.conf'
    if ($LASTEXITCODE -ne 0) { throw 'Copying the DNS drop-in to the firewall failed.' }
    Invoke-FirewallSsh 'sudo mkdir -p /usr/local/etc/dnsmasq.conf.d && sudo install -m 0644 /tmp/10-lab.conf /usr/local/etc/dnsmasq.conf.d/10-lab.conf && rm -f /tmp/10-lab.conf && sudo configctl dnsmasq restart' | Out-Null
    Write-Host 'DNS:         split-horizon drop-in installed, dnsmasq restarted'
}

# An OPNsense installation has three separately versioned parts:
#   core     the OPNsense packages (web GUI, configd, scripts, plugins) - "opnsense-version -v"
#   base     the FreeBSD userland (libc, sh, ssh, pf tools ...)
#   kernel   the FreeBSD kernel, including the Hyper-V drivers
# Returns them as a hashtable, e.g. @{ core = 26.7.7; base = 26.7.7; kernel = 26.7 }.
function Get-FirewallVersions {
    $lines = Invoke-FirewallSsh 'for p in core base kernel; do echo $p $(opnsense-version -v $p); done'
    $versions = @{}
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^(\w+) (\d+(\.\d+)+)')
        if ($match.Success) { $versions[$match.Groups[1].Value] = [version]$match.Groups[2].Value }
    }
    foreach ($part in 'core', 'base', 'kernel') {
        if (-not $versions[$part]) { throw "Unexpected opnsense-version output: $($lines -join ' | ')" }
    }
    return $versions
}

# Runs one update command, up to 3 times. The firewall downloads from pkg.opnsense.org through
# Windows NAT (Default Switch); a stalled download makes opnsense-update give up after 30 s
# without data ("fetch: transfer timed out"), and simply trying again usually works. The
# commands are idempotent: what is already installed is not downloaded again.
# "2>&1" runs on the firewall: it sends the remote stderr into the captured output, so pkg's
# notices do not show up as red PowerShell errors, and on failure the last lines are shown.
function Invoke-FirewallUpdateStep([string]$Command) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $output = Invoke-FirewallSsh "$Command 2>&1" -AllowFailure
        if ($LASTEXITCODE -eq 0) { return }
        $lastLines = ($output | Select-Object -Last 3) -join ' / '
        Write-Host "Version:     attempt $attempt of 3 failed: $lastLines"
        Start-Sleep -Seconds 10
    }
    throw "Firmware update on the firewall failed 3 times: $Command"
}

# 7c. Firmware update, the same steps the GUI's update button runs
#     (/usr/local/opnsense/scripts/firmware/update.sh): packages first, then base system and
#     kernel, then a reboot so the new kernel runs.
# The image on the mirror is the release (26.7); fixes come as updates (26.7.x). Updating right
# after the first boot is standard practice: an image or template is always older than the
# latest patches, so a new machine is patched before it goes into service.
# Only updates while something is below $minimumVersion, so a later run of this script does not
# change a working firewall by surprise; regular patching is a decision of its own (GUI:
# System > Firmware > Updates).
function Update-Firewall {
    $versions = Get-FirewallVersions
    if ($versions.core -lt $minimumVersion) {
        Write-Host "Version:     core $($versions.core), updating packages (this takes a few minutes) ..."
        Invoke-FirewallUpdateStep 'sudo opnsense-update -pt opnsense'
        # The web GUI process still runs the old code until it is restarted.
        Invoke-FirewallSsh 'sudo /usr/local/etc/rc.restart_webgui 2>&1' | Out-Null
    }
    if ($versions.base -lt $minimumVersion -or $versions.kernel -lt $minimumVersion) {
        Write-Host "Version:     base $($versions.base), kernel $($versions.kernel), updating base system and kernel ..."
        Invoke-FirewallUpdateStep 'sudo opnsense-update -bk'
    }
    # The new kernel is installed on disk but only runs after a reboot. "uname -r" names the
    # running kernel, "freebsd-version -k" the installed one; if they differ, a reboot is
    # pending. Checking this (instead of "did we just update?") also finishes an earlier run
    # that installed the kernel but stopped before the reboot.
    $kernels = Invoke-FirewallSsh 'uname -r; freebsd-version -k'
    if ($kernels[0] -ne $kernels[1]) {
        Write-Host "Version:     rebooting into the new kernel ($($kernels[0]) -> $($kernels[1])) ..."
        Invoke-FirewallSsh 'sudo shutdown -r now 2>&1' -AllowFailure | Out-Null
        # SSH may still answer for a few seconds while the firewall shuts down.
        Start-Sleep -Seconds 20
        Wait-TcpPort $lab.firewall.hostIp 22 600
        # sshd is among the first services to start; give the rest (dnsmasq, GUI) a moment.
        Start-Sleep -Seconds 15
    }
    $versions = Get-FirewallVersions
    foreach ($part in 'core', 'base', 'kernel') {
        if ($versions[$part] -lt $minimumVersion) {
            throw "The firewall's $part is $($versions[$part]) after the update, expected at least $minimumVersion."
        }
    }
    Write-Host "Version:     core $($versions.core), base $($versions.base), kernel $($versions.kernel)"
}

# 7d. The GUI certificate of the RUNNING firewall, seen from your PC: valid when its chain ends
#     at the lab root CA (keys\pki\root-ca.crt, compared by thumbprint), it names
#     firewall.<domain> and it is valid for more than 30 more days.
function Test-GuiCertificate {
    $name = "firewall.$($lab.domain)"
    try {
        $tcp = New-Object Net.Sockets.TcpClient($lab.firewall.hostIp, 443)
        try {
            # Accept any certificate for the handshake: it is checked below, against the lab root.
            $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
            $ssl.AuthenticateAsClient($name)
            $served = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate
        }
        finally { $tcp.Close() }
    }
    catch { return $false }
    $root = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $script:LabRootCaCert
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    [void]$chain.ChainPolicy.ExtraStore.Add($root)
    $chained = $chain.Build($served) -and $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint -eq $root.Thumbprint
    return ($chained -and $served.NotAfter -gt (Get-Date).AddDays(30) -and $served.GetNameInfo('DnsName', $false) -eq $name)
}

# 7e. Renew the GUI certificate in place when Test-GuiCertificate says so. The usual way to get a
#     certificate without moving the private key: the firewall makes a new key and a
#     certificate signing request (CSR) in a private temporary folder; only the CSR comes to the
#     PC, the offline root CA signs it, and the certificate goes back. opnsense\lab-gui-cert.php
#     (run as root on the firewall) puts key and certificate into config.xml, then the web server
#     restarts. The same thing as uploading a certificate under System > Trust in the GUI, as
#     code. No rebuild needed, for example when the certificate expires (397 days).
function Update-GuiCertificate {
    $name = "firewall.$($lab.domain)"
    # The web GUI starts after sshd (after a boot, the script has only waited for port 22). Only
    # a certificate that is actually served and found wanting is a reason for a new key; a port
    # that does not answer at all is reported as such.
    Wait-TcpPort $lab.firewall.hostIp 443 120
    if (Test-GuiCertificate) { Write-Host "Certificate: $name valid (lab root CA, more than 30 days left)"; return }
    Write-Host "Certificate: $name is due; new key on the firewall, signed by the lab root CA ..."
    # openssl genpkey writes the key in PKCS#8; umask 077 makes the folder and files private.
    $answer = Invoke-FirewallSsh "umask 077 && d=`$(mktemp -d /tmp/lab-gui.XXXXXX) && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out `$d/gui.key 2>/dev/null && openssl req -new -key `$d/gui.key -subj /CN=$name -out `$d/firewall-gui.csr && echo `$d"
    $remote = "$(@($answer)[-1])".Trim()
    if ($remote -notmatch '^/tmp/lab-gui\.[A-Za-z0-9]+$') { throw "Unexpected answer from the firewall: $remote" }
    $local = Join-Path $secretsDir 'gui-request'
    try {
        New-Item -ItemType Directory -Force -Path $local | Out-Null
        $csr = Join-Path $local 'firewall-gui.csr'
        & scp -q -F $sshConfig -o LogLevel=ERROR "firewall:$remote/firewall-gui.csr" $csr
        if ($LASTEXITCODE -ne 0) { throw 'Copying the certificate request from the firewall failed.' }
        $crt = Join-Path $keysDir 'pki\issued\firewall-gui.crt'
        & (Join-Path $PSScriptRoot 'New-LabRootCA.ps1') -SignCsr $csr -Kind Server -DnsName $name -OutFile $crt | Out-Null
        $php = Join-Path $projectRoot 'opnsense\lab-gui-cert.php'
        & scp -q -F $sshConfig -o LogLevel=ERROR $crt $script:LabRootCaCert $php "firewall:$remote/"
        if ($LASTEXITCODE -ne 0) { throw 'Copying the certificate to the firewall failed.' }
        Invoke-FirewallSsh "sudo /usr/local/bin/php $remote/lab-gui-cert.php $remote/gui.key $remote/firewall-gui.crt $remote/root-ca.crt 2>&1 && sudo /usr/local/etc/rc.restart_webgui 2>&1" | Out-Null
    }
    finally {
        # The key file goes too: from now on it exists only in the firewall's config.xml.
        Invoke-FirewallSsh "rm -rf $remote" -AllowFailure | Out-Null
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $local
    }
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-GuiCertificate)) {
        if ((Get-Date) -gt $deadline) { throw "The firewall's web GUI does not serve the new certificate after 60 s." }
        Start-Sleep -Seconds 3
    }
    Write-Host "Certificate: $name renewed in place (key made on the firewall, signed by the lab root CA)"
}

# 8. Checks from your PC's point of view.
function Test-Firewall {
    Clear-DnsClientCache
    $fwName = "firewall.$($lab.domain)"
    $answer = @(Resolve-DnsName -Name $fwName -Type A -DnsOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    if (($answer -join ',') -ne $lab.firewall.hostIp) { throw "DNS: $fwName resolves to '$($answer -join ', ')' for the PC, expected $($lab.firewall.hostIp)." }
    Write-Host "Check:       $fwName -> $($answer -join ', ') (PC view)"
    # One name per published VM: the PC must get that VM's published address, and only that
    # (split horizon: the lab address would be unreachable for the PC).
    foreach ($pub in $lab.published) {
        $firstName = @($pub.names)[0]
        $published = "$firstName.$($lab.domain)"
        if ($firstName -eq '@') { $published = $lab.domain }
        $answer = @(Resolve-DnsName -Name $published -Type A -DnsOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        if (($answer -join ',') -ne $pub.address) { throw "DNS: $published resolves to '$($answer -join ', ')' for the PC, expected $($pub.address) (split-horizon drop-in?)." }
        Write-Host "Check:       $published -> $($answer -join ', ') (PC view, published)"
    }
}

# --- Main -------------------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Please run in an elevated PowerShell ("Run as administrator"): Hyper-V and its serial console pipe need it.'
}
foreach ($tool in $openssl, $bzip2) {
    if (-not (Test-Path $tool)) { throw "$tool is missing. It comes with Git for Windows." }
}
foreach ($switch in 'Default Switch', 'LabNet', 'LabHost') {
    if (-not (Get-VMSwitch -Name $switch -ErrorAction SilentlyContinue)) {
        throw "Hyper-V switch '$switch' is missing (LabNet: Initialize-Lab.ps1, LabHost: Install-LabHostNetwork.ps1)."
    }
}
if (-not (Test-Path $sshConfig)) { throw "keys\ssh_config is missing. Run .\scripts\Initialize-Lab.ps1." }

$existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($existing -and $existing.Notes -ne $vmTag) {
    # Remove-Lab.ps1 refuses untagged VMs too (on purpose: neither script deletes a VM it did
    # not create), so the way out is a deliberate manual step.
    throw "A VM named '$vmName' exists that this script did not build (an old Vagrant firewall?). Check what it is, then delete it yourself in Hyper-V Manager or with: Remove-VM -Name $vmName -Force (and its disk folder)."
}
# Also on re-runs: moves plain-text secrets of earlier versions into DPAPI.
Move-OldSecrets
if ($existing -and -not $Rebuild) {
    # Left behind by an earlier first boot that failed?
    Remove-SeedIso
    if ($existing.State -ne 'Running') { Start-VM -VM $existing; Write-Host "VM:          $vmName started" }
    Wait-TcpPort $lab.firewall.hostIp 22 300
}
else {
    # Everything that depends on the repository's content (image, secrets, certificate, the
    # rendered template) is prepared BEFORE an existing firewall is deleted. A typo in
    # config.xml.template or config\lab.json then stops the script while the old
    # firewall keeps running, instead of leaving the lab without one. Same idea as a deployment
    # pipeline that builds and validates the new version before it takes the old one down.
    Get-BaseImage
    $secrets = Get-Secrets
    $certificate = Get-GuiCertificate
    $configXml = New-FirewallConfig $secrets $certificate
    if ($existing) {
        Write-Host "Rebuild:     removing the existing $vmName VM"
        Stop-VM -VM $existing -TurnOff -Force
        Remove-VM -VM $existing -Force
        if (Test-Path $vmDir) { Remove-Item -Recurse -Force $vmDir }
    }
    try {
        New-SeedIso $configXml
        $configXml = $null
        New-FirewallVm
        Invoke-FirstBoot
    }
    finally { Remove-SeedIso }
    # A new firewall has new SSH host keys; this file only records lab hosts, so start fresh.
    Remove-Item -Force -ErrorAction SilentlyContinue $knownHosts
    Wait-TcpPort $lab.firewall.hostIp 22 300
    Test-AdapterMapping
}
Install-DnsDropIn
Update-Firewall
Update-GuiCertificate
# Files of earlier versions: the rendered config.xml (password hashes, GUI key) and the GUI
# certificate with its key, issued by the retired first lab CA. Neither is needed any more.
foreach ($old in 'rendered', 'gui.key', 'gui.crt') {
    $oldPath = Join-Path $secretsDir $old
    if (Test-Path $oldPath) { Remove-Item -Recurse -Force $oldPath; Write-Host "Cleanup:     keys\opnsense\$old removed (no longer used)" }
}
Test-Firewall
Write-Host "Firewall ready: https://firewall.$($lab.domain) (user root; password to the clipboard: .\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password)"
