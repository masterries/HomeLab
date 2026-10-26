<?php
// Pure in-memory regression tests. Never loads config.inc or changes a running appliance.
// Run on any host with PHP (the firewall has it):
//   php Test-LabNginxFirewall.php [lab-nginx.php] [lab.json]
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
function routed($pub) {
    foreach ($pub['ports'] as $port) { if (($port['targetVm'] ?? '') === 'nginx') { return true; } }
    return false;
}
// The configuration a freshly built firewall has (scripts/lib/LabFirewall.ps1): every
// publication's VIP, its forwards (routed web ports already to nginx), direct split DNS.
function fresh_firewall($lab) {
    $vms = array_column($lab['vms'], null, 'name');
    $config = [
        'system' => ['unrelated' => 'preserve', 'webgui' => ['interfaces' => 'lan,opt1', 'noantilockout' => '1']],
        'interfaces' => ['lan' => ['enable' => '', 'ipaddr' => $lab['firewall']['lanIp']], 'opt1' => ['enable' => '', 'ipaddr' => $lab['firewall']['hostIp']]],
        'dnsmasq' => ['enable' => '1', 'interface' => 'lan,opt1', 'dhcp' => ['no_interface' => 'opt1'], 'hosts' => [['host' => 'other', 'domain' => $lab['domain'], 'ip' => '10.10.10.70']]],
        'virtualip' => ['vip' => []], 'nat' => ['outbound' => ['mode' => 'automatic'], 'rule' => []],
        'OPNsense' => ['Firewall' => ['Filter' => ['rules' => ['rule' => [['description' => 'Keep lab isolated from PC']]]]]],
    ];
    foreach ($lab['vms'] as $vm) {
        if ($vm['name'] === 'nginx') { continue; }
        $config['dnsmasq']['hosts'][] = lab_nginx_host($vm['name'], $vm['ip'], $lab['domain'], lab_nginx_mac($vm)) + ['descr' => 'Lab VM (DHCP reservation)'];
    }
    $config['dnsmasq']['hosts'][] = lab_nginx_host('firewall', $lab['firewall']['lanIp'] . ',' . $lab['firewall']['hostIp'], $lab['domain']);
    foreach ($lab['published'] as $pub) {
        $config['virtualip']['vip'][] = ['subnet' => $pub['address'], 'mode' => 'ipalias', 'interface' => 'opt1', 'subnet_bits' => explode('/', $lab['hostNetwork'])[1], 'noexpand' => '0', 'nobind' => '1'];
        foreach ($pub['names'] as $alias) {
            $config['dnsmasq']['hosts'][] = lab_nginx_host($alias, $alias === $pub['vm'] ? $pub['address'] : $vms[$pub['vm']]['ip'] . ',' . $pub['address'], $lab['domain']);
        }
        foreach ($pub['ports'] as $port) {
            $config['nat']['rule'][] = [
                'sequence' => (string)(100 + count($config['nat']['rule']) * 10), 'interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => $port['protocol'],
                'source' => ['network' => ($port['source'] ?? 'any') === 'pc' ? $lab['firewall']['pcIp'] : 'any'],
                'destination' => ['network' => $pub['address'], 'port' => (string)$port['port']],
                'target' => $vms[($port['targetVm'] ?? '') === 'nginx' ? 'nginx' : $pub['vm']]['ip'], 'local-port' => (string)$port['port'], 'pass' => 'rule', 'descr' => $pub['vm'] . ': ' . $port['description'],
            ];
        }
    }
    return $config;
}
$vms = array_column($lab['vms'], null, 'name');
$pubs = array_column($lab['published'], null, 'vm');
$nginxIp = $vms['nginx']['ip'];
$base = fresh_firewall($lab);

// --- Bootstrap: adds only nginx's reservation --------------------------------------------------
$bootstrap = lab_nginx_plan($base, $lab, true);
check($bootstrap['nat'] === $base['nat'], 'bootstrap preserves every NAT rule');
$nginxHosts = array_values(array_filter($bootstrap['dnsmasq']['hosts'], fn($host) => ($host['host'] ?? '') === 'nginx'));
check(count($nginxHosts) === 1 && lab_nginx_managed_host($nginxHosts[0], lab_nginx_host('nginx', $nginxIp, $lab['domain'], lab_nginx_mac($vms['nginx']))), 'bootstrap adds the exact nginx DHCP/private DNS reservation');
$withoutNginx = $bootstrap['dnsmasq']['hosts']; array_pop($withoutNginx);
check($withoutNginx === $base['dnsmasq']['hosts'], 'bootstrap changes no existing DNS or DHCP record');
check(lab_nginx_plan($bootstrap, $lab, true) === $bootstrap, 'second bootstrap is unchanged');

// --- Route: routed publications to nginx, direct ones (vault) unchanged -----------------------
$planned = lab_nginx_plan($bootstrap, $lab);
check($planned['nat']['rule'] === array_merge($bootstrap['nat']['rule'], [$planned['nat']['rule'][count($planned['nat']['rule']) - 1]]) && count($planned['nat']['rule']) === count($bootstrap['nat']['rule']) + 1, 'route keeps the fresh forwards and adds only the GUI rule');
$gui443 = $planned['nat']['rule'][rule_index($planned, $lab['firewall']['hostIp'], 443)];
check($gui443['target'] === $nginxIp && $gui443['source']['network'] === $lab['firewall']['pcIp'], 'GUI443 goes to nginx and is PC-only');
foreach ($lab['published'] as $pub) {
    foreach ($pub['ports'] as $port) {
        $rule = $planned['nat']['rule'][rule_index($planned, $pub['address'], $port['port'], $port['protocol'])];
        $wanted = ($port['targetVm'] ?? '') === 'nginx' ? $nginxIp : $vms[$pub['vm']]['ip'];
        check($rule['target'] === $wanted, $pub['vm'] . ' ' . $port['protocol'] . '/' . $port['port'] . ' targets ' . (($port['targetVm'] ?? '') === 'nginx' ? 'nginx' : 'its VM'));
    }
    $vm = $vms[$pub['vm']];
    if (routed($pub) && in_array($pub['vm'], $pub['names'], true)) {
        $reservation = $planned['dnsmasq']['hosts'][host_index($planned, $pub['vm'] . '-backend', true)];
        check($reservation['ip'] === $vm['ip'] && $reservation['hwaddr'] === lab_nginx_mac($vm), $pub['vm'] . ' backend reservation retains its IP/MAC');
    } else {
        $reservation = $planned['dnsmasq']['hosts'][host_index($planned, $pub['vm'], true)];
        check($reservation['ip'] === $vm['ip'], $pub['vm'] . (routed($pub) ? ' is routed under other names only and keeps its own reservation name' : ' is direct and keeps its own reservation name'));
    }
    foreach ($pub['names'] as $alias) {
        $expected = routed($pub) ? lab_nginx_host($alias, $nginxIp . ',' . $pub['address'], $lab['domain'])
            : lab_nginx_host($alias, $alias === $pub['vm'] ? $pub['address'] : $vm['ip'] . ',' . $pub['address'], $lab['domain']);
        $matches = array_values(array_filter($planned['dnsmasq']['hosts'], fn($host) => ($host['host'] ?? '') === $expected['host'] && ($host['domain'] ?? '') === $expected['domain'] && empty($host['hwaddr'])));
        check(count($matches) === 1 && lab_nginx_managed_host($matches[0], $expected), $alias . (routed($pub) ? ' resolves to nginx in the lab' : ' stays direct in the lab') . ', the PC keeps its published address');
    }
}
check(isset($pubs['vault']) && !routed($pubs['vault']), 'OpenBao (vault) is published directly');
check(lab_nginx_managed_host($planned['dnsmasq']['hosts'][host_index($planned, 'firewall')], lab_nginx_host('firewall', $nginxIp . ',' . $lab['firewall']['hostIp'], $lab['domain'])), 'firewall web DNS is central internally and keeps the management PC address');
check($planned['dnsmasq']['hosts'][host_index($planned, 'ansible-control', true)] === $base['dnsmasq']['hosts'][host_index($base, 'ansible-control', true)], 'control reservation is unchanged');
check($planned['virtualip'] === $base['virtualip'] && $planned['OPNsense'] === $base['OPNsense'] && $planned['system'] === $base['system'] && $planned['nat']['outbound'] === $base['nat']['outbound'], 'VIPs, filters, GUI bindings, SSH/DNS access and unrelated config are preserved');
check(lab_nginx_plan($planned, $lab) === $planned && lab_nginx_plan($planned, $lab, true) === $planned, 'route and bootstrap are unchanged after full migration');
check(!array_key_exists('no_hosts', $bootstrap['dnsmasq']) && $planned['dnsmasq']['no_hosts'] === '1', 'only route disables automatic system /etc/hosts DNS import');
$dnsApartFromManaged = $planned['dnsmasq']; unset($dnsApartFromManaged['hosts'], $dnsApartFromManaged['no_hosts']);
$originalDnsApartFromManaged = $base['dnsmasq']; unset($originalDnsApartFromManaged['hosts']);
check($dnsApartFromManaged === $originalDnsApartFromManaged, 'DHCP settings and other dnsmasq options remain preserved');
foreach (['', '0', '1'] as $lookupValue) {
    $lookupFixture = $base; $lookupFixture['dnsmasq']['no_hosts'] = $lookupValue;
    check(lab_nginx_plan($lookupFixture, $lab, true)['dnsmasq']['no_hosts'] === $lookupValue && lab_nginx_plan($lookupFixture, $lab)['dnsmasq']['no_hosts'] === '1', 'normal system-host lookup flag ' . json_encode($lookupValue) . ' is preserved at bootstrap and set only at route');
}
$oldDescription = $base; $oldIndex = rule_index($base, $pubs['vault']['address'], 8200);
$oldDescription['nat']['rule'][$oldIndex]['descr'] = 'vault: HTTPS (an older description)';
check(lab_nginx_plan($oldDescription, $lab)['nat']['rule'][$oldIndex]['descr'] === $base['nat']['rule'][$oldIndex]['descr'], 'an older description of a generated forward follows lab.json');

// --- A firewall that still routes OpenBao through nginx (the previous design) ------------------
// Vault 8200 and 80 went to nginx, an extra 443 forward existed, and vault's lab DNS named nginx.
$previous = $planned;
foreach ([8200 => 'vault: HTTPS (OpenBao API compatibility and ACME directory through central nginx)', 80 => null] as $port => $descr) {
    $index = rule_index($previous, $pubs['vault']['address'], $port);
    $previous['nat']['rule'][$index]['target'] = $nginxIp;
    if ($descr !== null) { $previous['nat']['rule'][$index]['descr'] = $descr; }
}
$previous['nat']['rule'][] = ['sequence' => '990', 'interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => 'tcp', 'source' => ['network' => 'any'], 'destination' => ['network' => $pubs['vault']['address'], 'port' => '443'], 'target' => $nginxIp, 'local-port' => '443', 'pass' => 'rule', 'descr' => 'vault: HTTPS (OpenBao UI and API through central nginx)'];
$previous['dnsmasq']['hosts'][host_index($previous, 'vault', true)]['host'] = 'vault-backend';
$previous['dnsmasq']['hosts'][host_index($previous, 'vault', false)]['ip'] = $nginxIp . ',' . $pubs['vault']['address'];
check(lab_nginx_plan($previous, $lab, true) === $previous, 'bootstrap leaves a previously routed OpenBao as it is');
check(lab_nginx_plan($previous, $lab) === $planned, 'route moves OpenBao back to direct: forwards to the VM, the extra 443 forward removed, its own DNS and reservation name');

// --- The earlier partial central proxy: four web rules routed, DNS direct -----------------------
$partial = $bootstrap;
check(lab_nginx_plan($partial, $lab, true) === $partial, 'bootstrap preserves a fresh appliance with routed web forwards');
check(lab_nginx_plan($partial, $lab) === $planned, 'a fresh appliance migrates to the same complete plan');

// --- Generated forwards for ports lab.json no longer lists ----------------------------------------
$stale = $planned;
$stale['nat']['rule'][] = ['sequence' => '995', 'interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => 'tcp', 'source' => ['network' => 'any'], 'destination' => ['network' => $pubs['keycloak']['address'], 'port' => '8443'], 'target' => $vms['keycloak']['ip'], 'local-port' => '8443', 'pass' => 'rule', 'descr' => 'keycloak: an old port'];
check(lab_nginx_plan($stale, $lab, true) === $stale, 'bootstrap keeps a stale generated forward');
check(lab_nginx_plan($stale, $lab) === $planned, 'route removes a stale generated forward');
$foreign = $stale; $foreign['nat']['rule'][count($foreign['nat']['rule']) - 1]['descr'] = 'Operator: keycloak debugging';
refused($foreign, $lab, 'a forward on a managed address that this lab did not generate');

// --- Normalised appliance fields -------------------------------------------------------------------
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

// --- Refusals ----------------------------------------------------------------------------------------
$rustfsIndex = rule_index($base, $pubs['rustfs']['address'], 443);
foreach ([
    'broad RustFS source' => function(&$c) use($rustfsIndex) { $c['nat']['rule'][$rustfsIndex]['source']['network'] = 'any'; },
    'unexpected target' => fn(&$c) => $c['nat']['rule'][0]['target'] = '10.10.10.66',
    'changed translation port' => fn(&$c) => $c['nat']['rule'][0]['local-port'] = '444',
    'unknown NAT option' => fn(&$c) => $c['nat']['rule'][0]['unexpected'] = '1',
    'inverted source' => fn(&$c) => $c['nat']['rule'][0]['source']['not'] = '1',
    'disabled ingress' => fn(&$c) => $c['nat']['rule'][0]['disabled'] = '1',
    'foreign description on a managed forward' => fn(&$c) => $c['nat']['rule'][0]['descr'] = 'Operator rule',
    'duplicate managed NAT' => fn(&$c) => $c['nat']['rule'][] = $c['nat']['rule'][0],
    'missing existing NAT' => fn(&$c) => array_pop($c['nat']['rule']),
    'nginx IP DNS collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'ip' => $GLOBALS['nginxIp']],
    'nginx MAC collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'hwaddr' => lab_nginx_mac($GLOBALS['vms']['nginx'])],
    'nginx DNS collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'NGINX', 'domain' => strtoupper($GLOBALS['lab']['domain']), 'ip' => '10.10.10.66'],
    'nginx CNAME collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'cnames' => 'NGINX.' . strtoupper($GLOBALS['lab']['domain']) . '.'],
    'duplicate managed DNS' => function(&$c) { $c['dnsmasq']['hosts'][] = $c['dnsmasq']['hosts'][host_index($c, 'matrix', false)]; },
    'operator DNS options' => function(&$c) { $c['dnsmasq']['hosts'][host_index($c, 'matrix', false)]['set_tag'] = 'operator'; },
    'missing managed DNS' => function(&$c) { unset($c['dnsmasq']['hosts'][host_index($c, 'matrix', false)]); },
    'backend DNS collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'matrix-backend', 'domain' => $GLOBALS['lab']['domain'], 'ip' => '10.10.10.66'],
    'managed CNAME collision' => fn(&$c) => $c['dnsmasq']['hosts'][] = ['host' => 'other', 'cnames' => 'firewall.' . $GLOBALS['lab']['domain']],
    'missing VIP' => fn(&$c) => array_pop($c['virtualip']['vip']),
    'bound GUI on publication VIP' => fn(&$c) => $c['virtualip']['vip'][0]['nobind'] = '0',
    'unknown system-host lookup mode' => fn(&$c) => $c['dnsmasq']['no_hosts'] = 'custom',
] as $label => $mutate) { $bad = $base; $mutate($bad); refused($bad, $lab, $label); }
$bad = $planned; $bad['nat']['rule'][rule_index($bad, $lab['firewall']['hostIp'], 443)]['source']['network'] = 'any'; refused($bad, $lab, 'broad firewall GUI source');
$bad = $base; $bad['nat']['rule'][] = ['target' => $nginxIp, 'destination' => ['network' => '10.10.99.77', 'port' => '22']]; refused($bad, $lab, 'extra NAT targeting nginx');
$bad = $base; $bad['nat']['rule'][] = ['target' => '10.10.10.77', 'destination' => ['network' => $lab['firewall']['hostIp'], 'port' => '22']]; refused($bad, $lab, 'unknown management-address NAT');
$bad = $base; $bad['OPNsense']['Firewall']['DestinationNat']['rules']['rule'][] = ['target' => $nginxIp]; refused($bad, $lab, 'overlapping modern DestinationNat');
$bad = $base; $bad['OPNsense']['Firewall']['DestinationNat']['rules']['rule'][] = ['destination' => $lab['firewall']['hostIp']]; refused($bad, $lab, 'modern management-address NAT');
$badLab = $lab; $badLab['published'][0]['ports'][2]['targetVm'] = 'nginx'; refused($base, $badLab, 'media port to nginx');
$badLab = $lab; $badLab['published'][0]['ports'][0]['targetVm'] = 'vault'; refused($base, $badLab, 'target other than nginx');
$badLab = $lab; $badLab['published'][1]['names'][] = 'Bad_Name'; refused($base, $badLab, 'invalid published name');
$badLab = $lab; $badLab['published'][1]['names'][] = 'matrix'; refused($base, $badLab, 'a name published twice');
$badLab = $lab; $badLab['published'][1]['ports'][0]['source'] = 'lan'; refused($base, $badLab, 'unknown source policy');
$badLab = $lab; $badLab['published'][1]['vm'] = 'nginx'; refused($base, $badLab, 'publishing nginx itself');
$badLab = $lab; $badLab['centralIngress']['firewallGui'] = false; refused($base, $badLab, 'disabled required GUI feature');
$bad = $planned; unset($bad['dnsmasq']['hosts'][host_index($bad, 'nginx', true)]); $repaired = lab_nginx_plan($bad, $lab, true);
check(count($repaired['dnsmasq']['hosts']) === count($planned['dnsmasq']['hosts']) && $repaired['nat'] === $planned['nat'], 'bootstrap repairs only a missing nginx reservation on an initialized appliance');

// --- Labs this helper did not know when it was written ---------------------------------------------
// VMs in a further segment (Kubernetes, for example) and new routed publications: one under the
// VM's own name (app), one under another name only (seg-node as seg-web, like k8s-server as
// rancher), whose VM keeps its own reservation name.
$segmentLab = $lab;
$segmentLab['segments'][] = ['name' => 'seg', 'cidr' => '10.10.30.0/24'];
$segmentLab['vms'][] = ['name' => 'seg-node', 'network' => 'seg', 'mac' => '02000A0A1E3C', 'ip' => '10.10.30.60'];
$segmentLab['vms'][] = ['name' => 'app', 'mac' => '02000A0A0A46', 'ip' => '10.10.10.70'];
$segmentLab['published'][] = ['vm' => 'app', 'address' => '10.10.99.29', 'names' => ['app'], 'ports' => [['protocol' => 'tcp', 'port' => 443, 'targetVm' => 'nginx', 'description' => 'HTTPS (a new web service)']]];
$segmentLab['published'][] = ['vm' => 'seg-node', 'address' => '10.10.99.30', 'names' => ['seg-web'], 'ports' => [['protocol' => 'tcp', 'port' => 443, 'targetVm' => 'nginx', 'description' => 'HTTPS (a web service in the segment)']]];
$segmentBase = fresh_firewall($segmentLab);
$segmentBase['dnsmasq']['hosts'] = array_values(array_filter($segmentBase['dnsmasq']['hosts'], fn($host) => ($host['host'] ?? '') !== 'other'));
$segmentPlanned = lab_nginx_plan(lab_nginx_plan($segmentBase, $segmentLab, true), $segmentLab);
check($segmentPlanned['nat']['rule'][rule_index($segmentPlanned, '10.10.99.29', 443)]['target'] === $nginxIp && lab_nginx_plan($segmentPlanned, $segmentLab) === $segmentPlanned, 'a new routed publication and a VM in a further segment are accepted');
check($segmentPlanned['nat']['rule'][rule_index($segmentPlanned, '10.10.99.30', 443)]['target'] === $nginxIp, 'the routed port of a segment VM goes to nginx');
check($segmentPlanned['dnsmasq']['hosts'][host_index($segmentPlanned, 'seg-node', true)]['ip'] === '10.10.30.60', 'a VM published under another name only keeps its own reservation name');
check(lab_nginx_managed_host($segmentPlanned['dnsmasq']['hosts'][host_index($segmentPlanned, 'seg-web')], lab_nginx_host('seg-web', $nginxIp . ',10.10.99.30', $lab['domain'])), 'its published name resolves to nginx in the lab');
check(lab_nginx_managed_host($segmentPlanned['dnsmasq']['hosts'][host_index($segmentPlanned, 'app-backend', true)], lab_nginx_host('app-backend', '10.10.10.70', $lab['domain'], lab_nginx_mac(['mac' => '02000A0A0A46']))), 'a VM published under its own name moves to <vm>-backend');
$outside = $segmentLab; $outside['vms'][] = ['name' => 'stray', 'mac' => '02000A0A280A', 'ip' => '10.10.40.10'];
refused($segmentBase, $outside, 'a VM outside every lab network');
$nginxElsewhere = $segmentLab; foreach ($nginxElsewhere['vms'] as &$vm) { if ($vm['name'] === 'nginx') { $vm['ip'] = '10.10.30.20'; } } unset($vm);
refused($segmentBase, $nginxElsewhere, 'nginx outside the lab network');
echo "nginx firewall plan: all tests passed\n";
