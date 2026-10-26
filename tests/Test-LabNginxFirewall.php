<?php
// Pure in-memory regression tests. Never loads config.inc or changes a running appliance.
require $argv[1] ?? __DIR__ . '/../opnsense/lab-nginx.php';
$lab = json_decode(file_get_contents($argv[2] ?? __DIR__ . '/../config/lab.json'), true, 512, JSON_THROW_ON_ERROR);
function check($condition, $label) {
    if (!$condition) { throw new RuntimeException('FAIL: ' . $label); }
    echo 'PASS: ' . $label . "\n";
}
function refused($config, $lab, $label, $bootstrap = false) {
    $before = $config;
    try { lab_nginx_plan($config, $lab, $bootstrap); } catch (RuntimeException $error) {
        check($config === $before, $label . ' refused without partial mutation'); return;
    }
    throw new RuntimeException('FAIL: accepted ' . $label);
}
function rule_index($config, $vip, $port, $protocol = 'tcp') {
    foreach ($config['nat']['rule'] as $index => $rule) {
        if (($rule['destination']['network'] ?? '') === $vip && ($rule['destination']['port'] ?? '') === (string)$port && ($rule['protocol'] ?? '') === $protocol) { return $index; }
    }
    throw new RuntimeException('Fixture rule missing');
}
function host_index($config, $name, $withMac = false) {
    foreach ($config['dnsmasq']['hosts'] as $index => $host) {
        if (($host['host'] ?? '') === $name && (!empty($host['hwaddr'])) === $withMac) { return $index; }
    }
    throw new RuntimeException('Fixture DNS host missing: ' . $name);
}
$vms = array_column($lab['vms'], null, 'name');
$pubs = array_column($lab['published'], null, 'vm');
$base = [
    'system' => ['unrelated' => 'preserve', 'webgui' => ['interfaces' => 'lan,opt1', 'noantilockout' => '1']],
    'interfaces' => ['lan' => ['enable' => '', 'ipaddr' => $lab['firewall']['lanIp']], 'opt1' => ['enable' => '', 'ipaddr' => $lab['firewall']['hostIp']]],
    'dnsmasq' => ['enable' => '1', 'interface' => 'lan,opt1', 'dhcp' => ['no_interface' => 'opt1'], 'hosts' => [['host' => 'other', 'domain' => $lab['domain'], 'ip' => '10.10.10.70']]],
    'virtualip' => ['vip' => []], 'nat' => ['outbound' => ['mode' => 'automatic'], 'rule' => []],
    'OPNsense' => ['Firewall' => ['Filter' => ['rules' => ['rule' => [['description' => 'Keep lab isolated from PC']]]]]],
];
foreach ($lab['vms'] as $vm) {
    if ($vm['name'] === 'nginx') { continue; }
    $base['dnsmasq']['hosts'][] = lab_nginx_host($vm['name'], $vm['ip'], $lab['domain'], lab_nginx_mac($vm)) + ['descr' => 'Lab VM (DHCP reservation)'];
}
$base['dnsmasq']['hosts'][] = lab_nginx_host('firewall', $lab['firewall']['lanIp'] . ',' . $lab['firewall']['hostIp'], $lab['domain']);
foreach ($lab['published'] as $pub) {
    $base['virtualip']['vip'][] = ['subnet' => $pub['address'], 'mode' => 'ipalias', 'interface' => 'opt1', 'subnet_bits' => explode('/', $lab['hostNetwork'])[1], 'noexpand' => '0', 'nobind' => '1'];
    foreach ($pub['names'] as $alias) {
        $base['dnsmasq']['hosts'][] = lab_nginx_host($alias, $alias === $pub['vm'] ? $pub['address'] : $vms[$pub['vm']]['ip'] . ',' . $pub['address'], $lab['domain']);
    }
    foreach ($pub['ports'] as $port) {
        if ($pub['vm'] === 'vault' && (int)$port['port'] === 443) { continue; } // New rule, absent on the original lab.
        $base['nat']['rule'][] = [
            'sequence' => (string)(100 + count($base['nat']['rule']) * 10), 'interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => $port['protocol'],
            'source' => ['network' => $pub['vm'] === 'rustfs' ? $lab['firewall']['pcIp'] : 'any'],
            'destination' => ['network' => $pub['address'], 'port' => (string)$port['port']],
            'target' => $vms[$pub['vm']]['ip'], 'local-port' => (string)$port['port'], 'pass' => 'rule', 'descr' => $pub['vm'] . ': ' . $port['description'],
        ];
    }
}
$bootstrap = lab_nginx_plan($base, $lab, true);
check($bootstrap['nat'] === $base['nat'], 'bootstrap preserves every original NAT rule');
$nginxHosts = array_values(array_filter($bootstrap['dnsmasq']['hosts'], fn($host) => ($host['host'] ?? '') === 'nginx'));
check(count($nginxHosts) === 1 && lab_nginx_managed_host($nginxHosts[0], lab_nginx_host('nginx', $vms['nginx']['ip'], $lab['domain'], lab_nginx_mac($vms['nginx']))), 'bootstrap adds the exact nginx DHCP/private DNS reservation');
$withoutNginx = $bootstrap['dnsmasq']['hosts']; array_pop($withoutNginx);
check($withoutNginx === $base['dnsmasq']['hosts'], 'bootstrap changes no existing DNS or DHCP record');
check(lab_nginx_plan($bootstrap, $lab, true) === $bootstrap, 'second bootstrap is unchanged');
$planned = lab_nginx_plan($bootstrap, $lab);
$targetChanges = 0;
foreach ($bootstrap['nat']['rule'] as $index => $original) {
    $rule = $planned['nat']['rule'][$index];
    if ($rule !== $original) {
        $targetChanges++; check($rule['target'] === $vms['nginx']['ip'], 'migrated rule targets nginx');
        $rule['target'] = $original['target']; check($rule === $original, 'existing source, match, translation, flags and description are preserved');
    }
}
check($targetChanges === 6 && count($planned['nat']['rule']) === count($bootstrap['nat']['rule']) + 2, 'six legacy web targets migrate and only Vault443/GUI443 rules are added');
$vault443 = $planned['nat']['rule'][rule_index($planned, $pubs['vault']['address'], 443)];
$gui443 = $planned['nat']['rule'][rule_index($planned, $lab['firewall']['hostIp'], 443)];
check($vault443['target'] === $vms['nginx']['ip'] && $vault443['source']['network'] === 'any' && $gui443['target'] === $vms['nginx']['ip'] && $gui443['source']['network'] === $lab['firewall']['pcIp'], 'new Vault443 retains Vault publication scope; GUI443 is PC-only');
foreach (['tcp' => 7881, 'udp' => 7882] as $protocol => $port) {
    $index = rule_index($base, $pubs['matrix']['address'], $port, $protocol);
    check($planned['nat']['rule'][$index] === $base['nat']['rule'][$index], 'LiveKit ' . $protocol . ' media remains direct and unchanged');
}
foreach ($pubs as $name => $pub) {
    $reservation = $planned['dnsmasq']['hosts'][host_index($planned, $name . '-backend', true)];
    check($reservation['ip'] === $vms[$name]['ip'] && $reservation['hwaddr'] === lab_nginx_mac($vms[$name]), $name . ' backend reservation retains its IP/MAC');
    foreach ($pub['names'] as $alias) {
        $expected = lab_nginx_host($alias, $vms['nginx']['ip'] . ',' . $pub['address'], $lab['domain']);
        $matches = array_values(array_filter($planned['dnsmasq']['hosts'], fn($host) => ($host['host'] ?? '') === $expected['host'] && ($host['domain'] ?? '') === $expected['domain']));
        check(count($matches) === 1 && lab_nginx_managed_host($matches[0], $expected), $alias . ' has only central LAN and unchanged PC DNS answers');
    }
}
check(lab_nginx_managed_host($planned['dnsmasq']['hosts'][host_index($planned, 'firewall')], lab_nginx_host('firewall', $vms['nginx']['ip'] . ',' . $lab['firewall']['hostIp'], $lab['domain'])), 'firewall web DNS is central internally and keeps the management PC address');
check($planned['dnsmasq']['hosts'][host_index($planned, 'ansible-control', true)] === $base['dnsmasq']['hosts'][host_index($base, 'ansible-control', true)], 'control reservation is unchanged');
check($planned['virtualip'] === $base['virtualip'] && $planned['OPNsense'] === $base['OPNsense'] && $planned['system'] === $base['system'] && $planned['nat']['outbound'] === $base['nat']['outbound'], 'VIPs, filters, GUI bindings, SSH/DNS access and unrelated config are preserved');
check(lab_nginx_plan($planned, $lab) === $planned && lab_nginx_plan($planned, $lab, true) === $planned, 'route and bootstrap are unchanged after full migration');
check(!array_key_exists('no_hosts', $bootstrap['dnsmasq']) && $planned['dnsmasq']['no_hosts'] === '1', 'only route disables automatic system /etc/hosts DNS import');
$dnsApartFromManaged = $planned['dnsmasq']; unset($dnsApartFromManaged['hosts'], $dnsApartFromManaged['no_hosts']);
$originalDnsApartFromManaged = $base['dnsmasq']; unset($originalDnsApartFromManaged['hosts']);
check($dnsApartFromManaged === $originalDnsApartFromManaged && $planned['system'] === $base['system'], 'managed split hosts, DHCP settings and OPNsense system-host generation remain separately preserved');
foreach (['', '0', '1'] as $lookupValue) {
    $lookupFixture = $base; $lookupFixture['dnsmasq']['no_hosts'] = $lookupValue;
    check(lab_nginx_plan($lookupFixture, $lab, true)['dnsmasq']['no_hosts'] === $lookupValue && lab_nginx_plan($lookupFixture, $lab)['dnsmasq']['no_hosts'] === '1', 'normal system-host lookup flag ' . json_encode($lookupValue) . ' is preserved at bootstrap and set only at route');
}
$legacyDescription = $base;
$legacyDescription['nat']['rule'][rule_index($base, $pubs['vault']['address'], 8200)]['descr'] = 'vault: HTTPS (OpenBao API, web UI and ACME directory)';
$legacyDescriptionPlan = lab_nginx_plan($legacyDescription, $lab);
check($legacyDescriptionPlan['nat']['rule'][rule_index($base, $pubs['vault']['address'], 8200)]['descr'] === 'vault: HTTPS (OpenBao API, web UI and ACME directory)' && lab_nginx_plan($legacyDescriptionPlan, $lab) === $legacyDescriptionPlan, 'original Vault8200 description is recognized and preserved exactly');

// The previously deployed central proxy already routed four web rules but left Vault and DNS direct.
$partial = $bootstrap;
foreach ($partial['nat']['rule'] as &$rule) {
    if (in_array($rule['destination']['network'], [$pubs['matrix']['address'], $pubs['keycloak']['address'], $pubs['rustfs']['address']], true) && in_array($rule['destination']['port'], ['80', '443'], true)) { $rule['target'] = $vms['nginx']['ip']; }
}
unset($rule);
check(lab_nginx_plan($partial, $lab, true) === $partial, 'bootstrap preserves the previously initialized central proxy');
check(lab_nginx_plan($partial, $lab) === $planned, 'previously initialized central proxy migrates to the same complete plan');
$fresh = $partial;
$vault443['sequence'] = (string)(100 + count($fresh['nat']['rule']) * 10); $fresh['nat']['rule'][] = $vault443;
$freshPlanned = lab_nginx_plan($fresh, $lab);
check(count($freshPlanned['nat']['rule']) === count($fresh['nat']['rule']) + 1 && lab_nginx_plan($freshPlanned, $lab) === $freshPlanned, 'fresh renderer with direct Vault bootstrap and nginx Vault443 needs only GUI rule creation');

$model = $base;
foreach ($model['dnsmasq']['hosts'] as $index => &$host) {
    $host += ['@attributes' => ['uuid' => sprintf('78091c98-34f9-49cf-8840-%012d', $index + 1)], 'local' => '0', 'cnames' => '', 'client_id' => '', 'lease_time' => '', 'ignore' => '0', 'set_tag' => '', 'comments' => '', 'aliases' => ''];
}
unset($host);
foreach ($model['nat']['rule'] as $index => &$rule) {
    $rule += ['disabled' => '0', '@attributes' => ['uuid' => sprintf('78091c98-34f9-49cf-883f-%012d', $index + 1)], 'poolopts' => '', 'log' => '0', 'category' => '', 'tag' => '', 'tagged' => '', 'natreflection' => '', 'associated-rule-id' => '', 'created' => ['username' => '', 'time' => '', 'description' => ''], 'updated' => ['username' => 'root', 'time' => '1792888800', 'description' => 'Informational audit metadata']];
    $rule['source'] += ['port' => '', 'not' => '0']; $rule['destination'] += ['not' => '0'];
}
unset($rule);
$modelPlanned = lab_nginx_plan($model, $lab);
check(lab_nginx_plan($modelPlanned, $lab) === $modelPlanned && lab_nginx_plan($modelPlanned, $lab, true) === $modelPlanned, 'normalized original and routed appliance states are idempotent');
check($modelPlanned['nat']['rule'][0]['@attributes'] === $model['nat']['rule'][0]['@attributes'] && $modelPlanned['nat']['rule'][0]['updated'] === $model['nat']['rule'][0]['updated'], 'NAT UUID and audit metadata are preserved');
check($modelPlanned['dnsmasq']['hosts'][host_index($modelPlanned, 'matrix-backend', true)]['@attributes'] === $model['dnsmasq']['hosts'][host_index($model, 'matrix', true)]['@attributes'], 'normalized DNS UUID and inactive defaults are accepted and preserved');
foreach ([
    'active local DNS option' => fn(&$host) => $host['local'] = '1',
    'ignored DNS record' => fn(&$host) => $host['ignore'] = '1',
    'active CNAME' => fn(&$host) => $host['cnames'] = 'operator.lab.internal',
    'active client ID' => fn(&$host) => $host['client_id'] = 'operator',
    'active DHCP lease option' => fn(&$host) => $host['lease_time'] = '1h',
    'active DHCP tag' => fn(&$host) => $host['set_tag'] = 'operator',
    'DNS alias extension' => fn(&$host) => $host['aliases'] = 'operator.lab.internal',
    'nonempty normalized comments' => fn(&$host) => $host['comments'] = 'Operator-owned setting',
    'invalid DNS UUID' => fn(&$host) => $host['@attributes']['uuid'] = 'invalid',
    'unknown DNS option' => fn(&$host) => $host['unexpected'] = '',
] as $label => $mutate) {
    $bad = $model; $mutate($bad['dnsmasq']['hosts'][host_index($bad, 'matrix', true)]); refused($bad, $lab, $label);
}
foreach ([
    'active poolopts' => fn(&$r) => $r['poolopts'] = 'round-robin', 'active tag' => fn(&$r) => $r['tag'] = 'operator',
    'active tagged match' => fn(&$r) => $r['tagged'] = 'trusted', 'associated filter rule' => fn(&$r) => $r['associated-rule-id'] = 'linked-filter-rule',
    'invalid UUID' => fn(&$r) => $r['@attributes']['uuid'] = 'not-a-uuid', 'unknown UUID metadata' => fn(&$r) => $r['@attributes']['unexpected'] = '1',
    'unknown audit metadata' => fn(&$r) => $r['created']['unexpected'] = '1',
] as $label => $mutate) { $bad = $model; $mutate($bad['nat']['rule'][0]); refused($bad, $lab, $label); }
$rustfsIndex = rule_index($base, $pubs['rustfs']['address'], 443);
foreach ([
    'broad RustFS source' => function(&$c) use($rustfsIndex) { $c['nat']['rule'][$rustfsIndex]['source']['network'] = 'any'; },
    'unexpected target' => fn(&$c) => $c['nat']['rule'][0]['target'] = '10.10.10.66',
    'changed translation port' => fn(&$c) => $c['nat']['rule'][0]['local-port'] = '444',
    'unknown NAT option' => fn(&$c) => $c['nat']['rule'][0]['unexpected'] = '1',
    'inverted source' => fn(&$c) => $c['nat']['rule'][0]['source']['not'] = '1',
    'disabled ingress' => fn(&$c) => $c['nat']['rule'][0]['disabled'] = '1',
    'duplicate managed NAT' => fn(&$c) => $c['nat']['rule'][] = $c['nat']['rule'][0],
    'missing existing NAT' => fn(&$c) => array_pop($c['nat']['rule']),
    'nginx IP DNS collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'ip' => $vms['nginx']['ip']],
    'nginx MAC collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'hwaddr' => lab_nginx_mac($vms['nginx'])],
    'nginx DNS collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'NGINX', 'domain' => strtoupper($lab['domain']), 'ip' => '10.10.10.66'],
    'nginx CNAME collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'cnames' => 'NGINX.' . strtoupper($lab['domain']) . '.'],
    'duplicate managed DNS' => function(&$c) { $c['dnsmasq']['hosts'][] = $c['dnsmasq']['hosts'][host_index($c, 'matrix', false)]; },
    'operator DNS options' => function(&$c) { $c['dnsmasq']['hosts'][host_index($c, 'matrix', false)]['set_tag'] = 'operator'; },
    'missing managed DNS' => function(&$c) { unset($c['dnsmasq']['hosts'][host_index($c, 'matrix', false)]); },
    'backend DNS collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'matrix-backend', 'domain' => $lab['domain'], 'ip' => '10.10.10.66'],
    'managed CNAME collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'cnames' => 'firewall.' . $lab['domain']],
    'missing VIP' => fn(&$c) => array_pop($c['virtualip']['vip']),
    'bound GUI on publication VIP' => fn(&$c) => $c['virtualip']['vip'][0]['nobind'] = '0',
    'unknown system-host lookup mode' => fn(&$c) => $c['dnsmasq']['no_hosts'] = 'custom',
] as $label => $mutate) { $bad = $base; $mutate($bad); refused($bad, $lab, $label); }
$bad = $planned; $bad['nat']['rule'][rule_index($bad, $lab['firewall']['hostIp'], 443)]['source']['network'] = 'any'; refused($bad, $lab, 'broad firewall GUI source');
$bad = $base; $bad['nat']['rule'][] = ['target' => $vms['nginx']['ip'], 'destination' => ['network' => '10.10.99.77', 'port' => '22']]; refused($bad, $lab, 'extra NAT targeting nginx');
$bad = $base; $bad['nat']['rule'][] = ['target' => '10.10.10.77', 'destination' => ['network' => $lab['firewall']['hostIp'], 'port' => '22']]; refused($bad, $lab, 'unknown management-address NAT');
$bad = $base; $bad['OPNsense']['Firewall']['DestinationNat']['rules']['rule'][] = ['target' => $vms['nginx']['ip']]; refused($bad, $lab, 'overlapping modern DestinationNat');
$bad = $base; $bad['OPNsense']['Firewall']['DestinationNat']['rules']['rule'][] = ['destination' => $lab['firewall']['hostIp']]; refused($bad, $lab, 'modern management-address NAT');
$badLab = $lab; $badLab['published'][0]['ports'][2]['targetVm'] = 'nginx'; refused($base, $badLab, 'media override');
$badLab = $lab; $badLab['published'][0]['ports'][0]['targetVm'] = 'vault'; refused($base, $badLab, 'unknown target override');
$badLab = $lab; $badLab['published'][1]['names'][] = 'operator'; refused($base, $badLab, 'unexpected DNS publication alias');
$badLab = $lab; $badLab['centralIngress']['firewallGui'] = false; refused($base, $badLab, 'disabled required GUI feature');
$bad = $planned; unset($bad['dnsmasq']['hosts'][host_index($bad, 'nginx', true)]); $repaired = lab_nginx_plan($bad, $lab, true);
check(count($repaired['dnsmasq']['hosts']) === count($planned['dnsmasq']['hosts']) && $repaired['nat'] === $planned['nat'], 'bootstrap repairs only a missing nginx reservation on an initialized appliance');
echo "nginx firewall plan: all tests passed\n";
