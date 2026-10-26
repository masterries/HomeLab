# Offline render test: only the renderer AST, inert credential data and temporary public text.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\lib\LabFirewall.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'LabFirewall.ps1 does not parse.' }
$render = $tree.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-FirewallConfig' }, $false)
. ([scriptblock]::Create($render.Extent.Text))
function Write-LabSshTrustFiles { return $false }
function Get-PasswordHash($Value) { return 'inert-test-hash' }
function New-RefId { return [guid]::NewGuid().ToString('N') }
function ConvertTo-Base64($Value) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Value)) }
$lab = Get-Content -Raw (Join-Path $projectRoot 'config\lab.json') | ConvertFrom-Json
$TimeZone = 'Europe/Berlin'
$scratchRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$scratch = Join-Path $scratchRoot "lab-nginx-render-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $script:LabSshFirewallKeys = Join-Path $scratch 'dummy-public-ca'
    [IO.File]::WriteAllText($script:LabSshFirewallKeys, 'inert public CA fixture')
    $xml = [xml](New-FirewallConfig @{ RootPassword = 'inert'; AnsiblePassword = 'inert'; ApiKey = 'inert'; ApiSecret = 'inert' } @{ CaPem = 'inert'; CrtPem = 'inert'; KeyPem = 'inert' })
    $reservation = @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq 'nginx' })
    if ($reservation.Count -ne 1 -or $reservation[0].ip -ne '10.10.10.20' -or $reservation[0].hwaddr -ne '02:00:0a:0a:0a:14') { throw 'Incorrect nginx DHCP/DNS reservation.' }
    $central = @($xml.opnsense.nat.rule | Where-Object { $_.target -eq '10.10.10.20' })
    if ($central.Count -ne 5) { throw 'Fresh bootstrap must target nginx on five web rules, leaving OpenBao 80/8200 direct.' }
    foreach ($pub in $lab.published) {
        foreach ($port in $pub.ports) {
            $rules = @($xml.opnsense.nat.rule | Where-Object { $_.destination.network -eq $pub.address -and $_.destination.port -eq [string]$port.port -and $_.protocol -eq $port.protocol })
            $targetName = if ($port.targetVm) { $port.targetVm } else { $pub.vm }
            if ($pub.vm -eq 'vault' -and $port.protocol -eq 'tcp' -and [int]$port.port -in @(80, 8200)) { $targetName = 'vault' }
            $targetIp = ($lab.vms | Where-Object name -eq $targetName).ip
            $source = if ($pub.vm -eq 'rustfs') { $lab.firewall.pcIp } else { 'any' }
            if ($rules.Count -ne 1 -or $rules[0].target -ne $targetIp -or $rules[0].source.network -ne $source) { throw "Wrong target/source for $($pub.vm):$($port.port)." }
        }
        $backendReservation = @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq $pub.vm -and $_.hwaddr })
        if ($backendReservation.Count -ne 1 -or $backendReservation[0].ip -ne ($lab.vms | Where-Object name -eq $pub.vm).ip) { throw 'Initial firewall must retain backend DNS until the post-nginx route stage.' }
    }
    $guiNat = @($xml.opnsense.nat.rule | Where-Object { $_.destination.network -eq $lab.firewall.hostIp })
    if ($guiNat.Count -ne 0) { throw 'Fresh firewall GUI must stay direct until nginx is healthy.' }
    $firewallDns = @($xml.opnsense.dnsmasq.hosts | Where-Object { $_.host -eq 'firewall' -and $_.domain -eq $lab.domain })
    if ($firewallDns.Count -ne 1 -or $firewallDns[0].ip -ne "$($lab.firewall.lanIp),$($lab.firewall.hostIp)") { throw 'Fresh firewall DNS must preserve its bootstrap management path.' }
    if ($xml.opnsense.system.webgui.interfaces -ne 'lan,opt1' -or $xml.opnsense.system.webgui.noantilockout -ne '1') { throw 'GUI bindings and explicit access rules must remain intact.' }
    foreach ($portNumber in @(22, 53)) {
        $managementRules = @($xml.opnsense.OPNsense.Firewall.Filter.rules.rule | Where-Object { $_.destination_net -eq $lab.firewall.hostIp -and $_.destination_port -eq [string]$portNumber -and $_.source_net -eq $lab.firewall.pcIp -and $_.action -eq 'pass' })
        if ($managementRules.Count -eq 0) { throw "Direct management port $portNumber must remain allowed for the PC." }
    }
    $lab.published[0].ports[0].targetVm = 'missing-vm'
    $refused = $false
    try { [void](New-FirewallConfig @{ RootPassword = 'inert'; AnsiblePassword = 'inert'; ApiKey = 'inert'; ApiSecret = 'inert' } @{ CaPem = 'inert'; CrtPem = 'inert'; KeyPem = 'inert' }) } catch { $refused = $_.Exception.Message -like '*unknown target VM*' }
    if (-not $refused) { throw 'Unknown targetVm must be refused.' }
    Write-Host 'PASS: fresh firewall nginx reservation, five web targets, direct OpenBao/GUI bootstrap, unchanged backend DNS/media/SSH/DNS policies, PC-only RustFS and unknown-target refusal.'
}
finally {
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ((Split-Path -Parent $resolvedScratch).TrimEnd('\', '/') -ne $scratchRoot -or (Split-Path -Leaf $resolvedScratch) -notmatch '^lab-nginx-render-[a-f0-9]{32}$') { throw "Unsafe temporary path: $resolvedScratch" }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
