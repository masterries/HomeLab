<# Offline render regression: dummy credentials and public SSH text only; no keys or live VM.
   Loads only New-FirewallConfig's AST, replacing its credential/trust inputs with inert data.
   .\tests\Test-LabRustfsFirewallRender.ps1
#>
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\lib\LabFirewall.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'LabFirewall.ps1 does not parse.' }
$render = $tree.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-FirewallConfig' }, $false)
if (-not $render) { throw 'New-FirewallConfig not found.' }
. ([scriptblock]::Create($render.Extent.Text))
function Write-LabSshTrustFiles { return $false }
function Get-PasswordHash($Value) { return 'inert-test-hash' }
function New-RefId { return [guid]::NewGuid().ToString('N') }
function ConvertTo-Base64($Value) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Value)) }
$lab = Get-Content -Raw (Join-Path $projectRoot 'config\lab.json') | ConvertFrom-Json
$TimeZone = 'Europe/Berlin'
$scratchRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$scratch = Join-Path $scratchRoot "lab-rustfs-render-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $script:LabSshFirewallKeys = Join-Path $scratch 'dummy-public-ca'
    [IO.File]::WriteAllText($script:LabSshFirewallKeys, 'inert public CA fixture')
    $xml = [xml](New-FirewallConfig @{ RootPassword = 'inert'; AnsiblePassword = 'inert'; ApiKey = 'inert'; ApiSecret = 'inert' } @{ CaPem = 'inert'; CrtPem = 'inert'; KeyPem = 'inert' })
    $reservation = @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq 'rustfs' -and $_.hwaddr })
    if ($reservation.Count -ne 1 -or $reservation[0].ip -ne '10.10.10.60' -or $reservation[0].hwaddr -ne '02:00:0a:0a:0a:3c') { throw 'RustFS DHCP reservation is missing or incorrect.' }
    $published = @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq 'rustfs' -and $_.ip -eq '10.10.99.6' -and -not $_.hwaddr })
    if ($published.Count -ne 1) { throw 'RustFS split DNS publication is missing or incorrect.' }
    $console = @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq 'rustfs-console' })
    if ($console.Count -ne 1 -or $console[0].ip -ne '10.10.10.60,10.10.99.6' -or $console[0].hwaddr) { throw 'RustFS console split DNS alias is missing or incorrect.' }
    $vips = @($xml.opnsense.virtualip.vip | Where-Object { $_.subnet -eq '10.10.99.6' })
    if ($vips.Count -ne 1 -or $vips[0].interface -ne 'opt1' -or $vips[0].mode -ne 'ipalias') { throw 'RustFS HOST virtual IP is missing or incorrect.' }
    $rules = @($xml.opnsense.nat.rule | Where-Object { $_.target -eq '10.10.10.60' -or $_.destination.network -eq '10.10.99.6' })
    $nginxIp = ($lab.vms | Where-Object { $_.name -eq 'nginx' }).ip
    if ($rules.Count -ne 1 -or $rules[0].destination.port -ne '443' -or $rules[0].target -ne $nginxIp) { throw 'RustFS must publish only TCP port 443 through central nginx.' }
    foreach ($rule in $rules) {
        if ($rule.source.network -ne $lab.firewall.pcIp -or $rule.interface -ne 'opt1' -or $rule.protocol -ne 'tcp' -or $rule.'local-port' -ne $rule.destination.port -or $rule.pass -ne 'rule') { throw 'RustFS NAT must be PC-only and have its registered filter rule.' }
    }
    $otherRules = @($xml.opnsense.nat.rule | Where-Object { $_.destination.network -ne '10.10.99.6' })
    if (@($otherRules | Where-Object { $_.source.network -ne 'any' }).Count -gt 0) { throw 'A pre-existing publication changed its source policy.' }
    # ssh -G parses a generated configuration without connecting. Inert paths ensure that no
    # real SSH keys, certificates, known_hosts or revocation files are read by this test.
    $sshTree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\lib\LabSsh.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw 'LabSsh.ps1 does not parse.' }
    $sshRender = $sshTree.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-LabSshConfigText' }, $false)
    if (-not $sshRender) { throw 'Get-LabSshConfigText not found.' }
    . ([scriptblock]::Create($sshRender.Extent.Text))
    $script:LabConfig = $lab
    $script:LabSshPcKey = Join-Path $scratch 'inert-key'
    $script:LabSshKnownHosts = Join-Path $scratch 'inert-known-hosts'
    $script:LabSshKrl = Join-Path $scratch 'inert-revocations'
    $sshFile = Join-Path $scratch 'ssh_config'
    [IO.File]::WriteAllText($sshFile, (Get-LabSshConfigText), (New-Object Text.UTF8Encoding $false))
    foreach ($hostName in 'rustfs', "rustfs.$($lab.domain)") {
        $settings = @(& ssh -G -T -F $sshFile $hostName 2>$null)
        if ($LASTEXITCODE -ne 0 -or $settings -notcontains 'hostname 10.10.10.60' -or
            $settings -notcontains "hostkeyalias rustfs.$($lab.domain)" -or
            $settings -notcontains 'proxyjump firewall' -or
            $settings -notcontains 'stricthostkeychecking true' -or
            $settings -notcontains 'hostkeyalgorithms ssh-ed25519-cert-v01@openssh.com') {
            throw "RustFS SSH must use its private transport IP, bastion and strict certificate identity for $hostName."
        }
    }
    $matrixSettings = @(& ssh -G -T -F $sshFile matrix 2>$null)
    if ($LASTEXITCODE -ne 0 -or $matrixSettings -notcontains 'hostname 10.10.10.30' -or $matrixSettings -notcontains "hostkeyalias matrix.$($lab.domain)" -or $matrixSettings -notcontains 'proxyjump firewall') { throw 'Matrix SSH must retain its private transport and certified FQDN.' }
    Write-Host 'PASS: RustFS DHCP, split DNS, VIP, PC-only HTTPS through central nginx and strict SSH identity over its private IP; publication source policies and SSH routing preserved.'
}
finally {
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch -ErrorAction Stop).ProviderPath
    if ((Split-Path -Parent $resolvedScratch).TrimEnd('\', '/') -ne $scratchRoot -or
        (Split-Path -Leaf $resolvedScratch) -notmatch '^lab-rustfs-render-[a-f0-9]{32}$') {
        throw "Refusing to remove a render-test directory outside the intended temporary folder: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
