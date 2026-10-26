<#
.SYNOPSIS
    The building blocks of the OPNsense firewall VM: image, secrets, configuration, seed ISO, VM,
    serial console, SSH bootstrap, firmware update, GUI certificate, checks.

.DESCRIPTION
    Not run directly, and not loaded by scripts\lib\Lab.ps1: scripts\commands\firewall.ps1
    ("lab.ps1 firewall") and the firewall tests load it after lib\Lab.ps1, at script level:
        $StorageRoot = 'G:\Vagrant'; $TimeZone = 'Europe/Berlin'   # optional, these are the defaults
        . (Join-Path <project> 'scripts\lib\LabFirewall.ps1')
    It defines script variables of its own ($vmName, $vmDir, $lab, $adapters, ...) that its functions
    use; scripts\commands\firewall.ps1 explains the build steps.
#>
if (-not $StorageRoot) { $StorageRoot = 'G:\Vagrant' }
if (-not $TimeZone) { $TimeZone = 'Europe/Berlin' }

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

$projectRoot = $script:LabProjectRoot
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
# pass them correctly to native programs. Get-LabSshConfig (LabSsh.ps1) renews the PC's SSH
# certificate when it is due. $Options: extra ssh options (a connection pinned to the firewall's
# stored host key, before it has a host certificate).
function Invoke-FirewallSsh([string]$Command, [switch]$AllowFailure, [string[]]$Options = @()) {
    $config = Get-LabSshConfig
    # Remote programs may write to stderr; only the exit code decides (see Invoke-OpenSsl).
    $ErrorActionPreference = 'Continue'
    $output = & ssh -F $config -o LogLevel=ERROR -o ConnectTimeout=10 @Options firewall $Command
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

# For a build: the three secrets, made when missing. The ansible password and the API key are
# only used by the firewall being built (Ansible itself logs in with the SSH key), so if they
# cannot be decrypted any more (another Windows profile, after lab.ps1 recovery -Recover
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
                    throw "keys\opnsense\root-password.dpapi cannot be decrypted by this Windows account. Restore it with .\lab.ps1 recovery -Recover <file> (or delete it to get a new GUI password)."
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
#    made here in a temporary folder, signed by the lab's offline root CA (lib\LabPki.ps1;
#    a copy of the certificate stays in keys\pki\issued). The key is not kept: it goes only into
#    the rendered config.xml, which is deleted after the import. The root signs only this first
#    certificate (the firewall is built before OpenBao exists); a RUNNING firewall gets new ones
#    from OpenBao's intermediate CA, with a key made on the firewall (ansible\playbooks\firewall.yml).
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
        Invoke-LabRootCaSign -Csr $csr -Kind Server -DnsName $name -OutFile $crt
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
    [void](Write-LabSshTrustFiles)
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

    # This is the first-boot configuration. Keep backend DNS, OpenBao's 80/8200 and the GUI
    # direct until nginx is ready: bootstrapping its PROXY-protocol listener needs OpenBao.
    # firewall-nginx's route stage migrates the exact DNS/NAT records together afterward;
    # its bootstrap stage preserves an already-routed appliance rather than rendering over it.
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
            $targetVm = if ($port.targetVm) { [string]$port.targetVm } else { [string]$pub.vm }
            if (-not $vmIp.ContainsKey($targetVm)) { throw "lab.json, published: unknown target VM '$targetVm' for $($pub.vm):$($port.port)." }
            if ($pub.vm -eq 'vault' -and $port.protocol -eq 'tcp' -and [int]$port.port -in @(80, 8200)) {
                $targetVm = 'vault'
            }
            $targetIp = $vmIp[$targetVm]
            # RustFS's API and console are published only to this PC, also on a fresh firewall.
            $sourceNetwork = if ($pub.vm -eq 'rustfs') { $lab.firewall.pcIp } else { 'any' }
            [void]$forwards.Append(@"
    <rule>
      <sequence>$sequence</sequence>
      <interface>opt1</interface>
      <ipprotocol>inet</ipprotocol>
      <protocol>$($port.protocol)</protocol>
      <source>
        <network>$sourceNetwork</network>
      </source>
      <destination>
        <network>$($pub.address)</network>
        <port>$([int]$port.port)</port>
      </destination>
      <target>$targetIp</target>
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
        # The lab's SSH CAs (keys\ssh\firewall_authorized_keys, LabSsh.ps1), so the PC's and
        # ansible-control's certificates work from the very first boot.
        '{{ANSIBLE_AUTHORIZED_KEYS_B64}}' = ConvertTo-Base64 ([IO.File]::ReadAllText($script:LabSshFirewallKeys))
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
#    Returns the fingerprint of the firewall's ed25519 SSH host key as OPNsense prints it on the
#    console right before the login prompt (" SSH:   SHA256 <fingerprint> (ED25519)"): the
#    console is a pipe on this PC that nothing on the network can write to, so this is the
#    trustworthy first sight of the key (Get-FirewallHostKey).
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
        $boot = Wait-SerialText 'login:' 600 'Default interfaces not found|Valid interfaces are'
        Write-Host 'Console:     boot finished (login prompt)'
        $fingerprint = [regex]::Matches($boot, 'SSH:\s+(SHA256) ([A-Za-z0-9+/]{43}) \(ED25519\)') | Select-Object -Last 1
        if (-not $fingerprint) { return $null }
        return "SHA256:$($fingerprint.Groups[2].Value)"
    }
    finally { Close-SerialConsole }
}

# 7. SSH, before anything else is done over it.
#
# The firewall's verified host key (keys\ssh\hosts\firewall.pub). On first contact it is the key
# the firewall presents (ssh-keyscan) - but only if its fingerprint equals the one the firewall
# printed on its serial console when it booted ($FirstBootFingerprint, or the serial console log
# of an earlier first boot). An impostor on the LabHost network cannot fake that, so no host key
# is ever trusted "on first use".
function Get-FirewallHostKey([string]$FirstBootFingerprint) {
    if (Test-Path (Get-LabSshHostKeyFile 'firewall')) { return }
    $expected = $FirstBootFingerprint
    if (-not $expected -and (Test-Path $serialLog)) {
        $line = Select-String -Path $serialLog -Pattern 'SSH:\s+SHA256 ([A-Za-z0-9+/]{43}) \(ED25519\)' | Select-Object -Last 1
        if ($line) { $expected = "SHA256:$($line.Matches[0].Groups[1].Value)" }
    }
    if (-not $expected) { throw "The firewall's SSH host key fingerprint is not in its serial console log ($serialLog), so its key cannot be verified. Rebuild it: .\lab.ps1 firewall -Rebuild" }
    $ErrorActionPreference = 'Continue'
    $scan = @(& $script:LabSshKeyscan -t ed25519 $lab.firewall.hostIp 2>$null)
    $ErrorActionPreference = 'Stop'
    $line = $scan | Where-Object { $_ -match '^\S+ ssh-ed25519 [A-Za-z0-9+/]+=*$' } | Select-Object -First 1
    if (-not $line) { throw "ssh-keyscan got no ed25519 host key from $($lab.firewall.hostIp)." }
    $key = (($line -split ' ')[1..2]) -join ' '
    $actual = Get-LabSshFingerprint $key
    if ($actual -ne $expected) { throw "The SSH host key at $($lab.firewall.hostIp) ($actual) is not the one the firewall printed on its console ($expected). Is another machine answering on that address?" }
    Save-LabSshHostKey 'firewall' $key
    Write-Host "SSH:         firewall host key $actual (matches its serial console)"
}

# Everything SSH on the firewall: host key (above), host certificate (signed when due), the sshd
# drop-in from opnsense\sshd_config.d (jump host limited to SSH of the lab VMs) and the SSH CAs
# that user ansible accepts (opnsense\lab-ssh-trust.php). It works over a connection pinned to
# the stored host key, so it also repairs a firewall whose certificate is missing or expired.
# Ends with a fully checked connection; every later SSH call relies on that.
function Update-FirewallSsh([string]$FirstBootFingerprint) {
    Get-FirewallHostKey $FirstBootFingerprint
    [void](Update-LabSshHostCertificateFile 'firewall')
    [void](Write-LabSshTrustFiles)
    $controlIp = ($lab.vms | Where-Object { $_.name -eq 'ansible-control' }).ip
    $permitOpen = @($lab.vms | ForEach-Object { "$($_.ip):22"; "$($_.name).$($lab.domain):22" })
    $dropIn = [IO.File]::ReadAllText((Join-Path $projectRoot 'opnsense\sshd_config.d\20-lab-ssh.conf'))
    $dropIn = $dropIn.Replace('{{ALLOW_USERS}}', "ansible@$($lab.firewall.pcIp) ansible@$controlIp").Replace('{{PERMIT_OPEN}}', ($permitOpen -join ' '))
    if ($dropIn -match '\{\{[A-Z_]+\}\}') { throw "Unreplaced placeholder in 20-lab-ssh.conf: $($Matches[0])" }
    $work = New-LabSshTempDir
    try {
        $pinned = Get-LabSshPinnedOptions 'firewall' $work
        [void](Write-LabSshFile (Join-Path $work '20-lab-ssh.conf') $dropIn.Split("`n"))
        $remote = "$(@(Invoke-FirewallSsh 'mktemp -d /tmp/lab-sshd.XXXXXX' -Options $pinned)[-1])".Trim()
        if ($remote -notmatch '^/tmp/lab-sshd\.[A-Za-z0-9]+$') { throw "Unexpected answer from the firewall: $remote" }
        try {
            Copy-LabSshFile @((Join-Path $script:LabSshHostsDir 'firewall-cert.pub'), (Join-Path $work '20-lab-ssh.conf'), (Join-Path $projectRoot 'opnsense\lab-sshd-files.sh')) "firewall:$remote/" -Options $pinned
            $answer = Invoke-FirewallSsh "sudo /bin/sh $remote/lab-sshd-files.sh $remote/firewall-cert.pub $remote/20-lab-ssh.conf 2>&1" -Options $pinned
            if ("$answer" -match 'changed') {
                # Restarts only the listening sshd (OPNsense's own service command); this session and
                # all others keep running, and the new certificate and drop-in apply to new logins.
                Invoke-FirewallSsh 'sudo configctl openssh restart 2>&1' -Options $pinned | Out-Null
                Start-Sleep -Seconds 2
                Wait-TcpPort $lab.firewall.hostIp 22 60
                Write-Host 'SSH:         host certificate and sshd drop-in installed, sshd restarted'
            }
        }
        finally { Invoke-FirewallSsh "rm -rf $remote" -Options $pinned -AllowFailure | Out-Null }
        Set-LabFirewallSshTrust -Options $pinned
    }
    finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work }
    if (-not (Test-LabSshStrictLogin 'firewall')) { throw 'The firewall does not pass the strict SSH check (host certificate, PC certificate) after its SSH setup.' }
    Write-Host 'SSH:         firewall checked: host certificate valid, certificate login works'
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
    $sshConfig = Get-LabSshConfig
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
#     firewall.<domain> and it is valid for more than 30 more days. The chain may run through
#     OpenBao's intermediate CA (Windows fetches it from the address in the certificate, AIA).
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

# 7e. Report on the GUI certificate. It is RENEWED by Ansible, not here: ansible\playbooks\firewall.yml
#     (.\lab.ps1 deploy firewall) has the firewall make a new key and a signing request, OpenBao's
#     intermediate CA signs it, and opnsense\lab-gui-cert.php puts both into config.xml - like
#     uploading a certificate under System > Trust, as code. lab.ps1 up runs it when the
#     certificate is due or not yet from the intermediate (Get-LabMaintenanceDue in LabSecrets.ps1).
#     Only a new firewall's first certificate comes from the offline root (Get-GuiCertificate).
function Show-GuiCertificate {
    $name = "firewall.$($lab.domain)"
    # The web GUI starts after sshd (after a boot, the script has only waited for port 22).
    Wait-TcpPort $lab.firewall.hostIp 443 120
    if (Test-GuiCertificate) { Write-Host "Certificate: $name valid (chain to the lab root CA, more than 30 days left)" }
    else { Write-Warning "The firewall's GUI certificate ($name) is due or not under the lab root CA. Renew it: .\lab.ps1 deploy firewall" }
}

# 8. Checks from your PC's point of view.
function Test-Firewall([switch]$DeferRustfsCheck) {
    Clear-DnsClientCache
    $fwName = "firewall.$($lab.domain)"
    $answer = @(Resolve-DnsName -Name $fwName -Type A -DnsOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
    if (($answer -join ',') -ne $lab.firewall.hostIp) { throw "DNS: $fwName resolves to '$($answer -join ', ')' for the PC, expected $($lab.firewall.hostIp)." }
    Write-Host "Check:       $fwName -> $($answer -join ', ') (PC view)"
    # One name per published VM: the PC must get that VM's published address, and only that
    # (split horizon: the lab address would be unreachable for the PC).
    foreach ($pub in $lab.published) {
        if ($DeferRustfsCheck -and $pub.vm -eq 'rustfs') { continue }
        $firstName = @($pub.names)[0]
        $published = "$firstName.$($lab.domain)"
        if ($firstName -eq '@') { $published = $lab.domain }
        $answer = @(Resolve-DnsName -Name $published -Type A -DnsOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        if (($answer -join ',') -ne $pub.address) { throw "DNS: $published resolves to '$($answer -join ', ')' for the PC, expected $($pub.address) (split-horizon drop-in?)." }
        Write-Host "Check:       $published -> $($answer -join ', ') (PC view, published)"
    }
}
