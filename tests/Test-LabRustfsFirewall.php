<?php
// Pure in-memory regression tests: no config.inc, appliance credentials or live writes.
// php tests/Test-LabRustfsFirewall.php [opnsense/lab-rustfs.php] [config/lab.json]
require $argv[1] ?? __DIR__ . '/../opnsense/lab-rustfs.php';
$lab = json_decode(file_get_contents($argv[2] ?? __DIR__ . '/../config/lab.json'), true, 512, JSON_THROW_ON_ERROR);
function check($condition, $label) {
    if (!$condition) { throw new RuntimeException('FAIL: ' . $label); }
    echo 'PASS: ' . $label . "\n";
}
function refused($config, $lab, $label) {
    $before = $config;
    try { lab_rustfs_plan($config, $lab); } catch (RuntimeException $error) {
        check($config === $before, $label . ' is refused without partial mutation');
        return;
    }
    throw new RuntimeException('FAIL: accepted ' . $label);
}
$base = [
    'system' => ['unrelated' => 'preserve'],
    'interfaces' => ['lan' => ['enable' => '', 'ipaddr' => $lab['firewall']['lanIp']], 'opt1' => ['enable' => '', 'ipaddr' => $lab['firewall']['hostIp']]],
    'dnsmasq' => ['enable' => '1', 'interface' => 'lan,opt1', 'dhcp' => ['no_interface' => 'opt1'], 'hosts' => [['host' => 'other', 'domain' => $lab['domain'], 'ip' => '10.10.10.20']]],
    'virtualip' => ['vip' => [['subnet' => '10.10.99.3', 'mode' => 'ipalias', 'interface' => 'opt1']]],
    'nat' => ['outbound' => ['mode' => 'automatic'], 'rule' => [['sequence' => '170', 'target' => '10.10.10.30', 'destination' => ['network' => '10.10.99.3', 'port' => '443']]]],
    'OPNsense' => ['Firewall' => ['Filter' => ['rules' => ['rule' => [['description' => 'Keep lab isolated from PC']]]]]],
];
$planned = lab_rustfs_plan($base, $lab);
check($planned['system'] === $base['system'] && $planned['OPNsense'] === $base['OPNsense'] && $planned['nat']['outbound'] === $base['nat']['outbound'], 'unrelated configuration is preserved');
check($planned['dnsmasq']['hosts'][0] === $base['dnsmasq']['hosts'][0] && $planned['nat']['rule'][0] === $base['nat']['rule'][0] && $planned['virtualip']['vip'][0] === $base['virtualip']['vip'][0], 'existing DHCP/DNS, virtual IPs and NAT records are preserved');
check(count($planned['dnsmasq']['hosts']) === 4 && $planned['dnsmasq']['hosts'][1]['hwaddr'] === '02:00:0a:0a:0a:3c', 'the existing-name DHCP reservation and published DNS address are added');
check($planned['dnsmasq']['hosts'][3]['host'] === 'rustfs-console' && $planned['dnsmasq']['hosts'][3]['ip'] === '10.10.10.60,10.10.99.6' && !isset($planned['dnsmasq']['hosts'][3]['hwaddr']), 'the console alias has both split-horizon addresses without a DHCP reservation');
check(count($planned['virtualip']['vip']) === 2 && $planned['virtualip']['vip'][1]['subnet'] === '10.10.99.6', 'only the RustFS virtual IP is added');
check(count($planned['nat']['rule']) === 2, 'exactly one NAT rule is added');
foreach (array_slice($planned['nat']['rule'], 1) as $rule) {
    check($rule['source']['network'] === $lab['firewall']['pcIp'] && $rule['protocol'] === 'tcp' && $rule['interface'] === 'opt1' && $rule['destination']['port'] === '443' && $rule['local-port'] === '443', 'only HTTPS is published and restricted to the PC');
}
check(lab_rustfs_plan($planned, $lab) === $planned, 'a second run is unchanged');
$normalized = $planned;
$normalized['nat']['rule'][1]['disabled'] = '0';
check(lab_rustfs_plan($normalized, $lab) === $normalized, 'model-normalized disabled=0 stays idempotent');

// Match exactly the two rules produced by the original onboarding helper or renderer.
$legacy = $planned;
array_pop($legacy['dnsmasq']['hosts']);
array_pop($legacy['nat']['rule']);
foreach ([9000 => 'RustFS S3 API', 9001 => 'RustFS console'] as $port => $service) {
    $legacy['nat']['rule'][] = [
        'sequence' => (string)($port - 8800), 'interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => 'tcp',
        'source' => ['network' => $lab['firewall']['pcIp']],
        'destination' => ['network' => '10.10.99.6', 'port' => (string)$port],
        'target' => '10.10.10.60', 'local-port' => (string)$port, 'pass' => 'rule',
        'descr' => 'rustfs: HTTPS (' . $service . ')',
    ];
}
$migrated = lab_rustfs_plan($legacy, $lab);
check(count($migrated['nat']['rule']) === 2 && $migrated['nat']['rule'][1]['destination']['port'] === '443', 'both exact legacy forwards are replaced by one HTTPS forward');
check($migrated['dnsmasq']['hosts'][1] === $legacy['dnsmasq']['hosts'][1] && $migrated['dnsmasq']['hosts'][2] === $legacy['dnsmasq']['hosts'][2], 'migration preserves the existing RustFS DHCP and DNS records');
check($migrated['nat']['rule'][0] === $legacy['nat']['rule'][0] && $migrated['OPNsense'] === $legacy['OPNsense'], 'migration preserves unrelated NAT and filter configuration');
check(lab_rustfs_plan($migrated, $lab) === $migrated, 'a second migration is unchanged');
$mixed = $legacy;
$mixed['nat']['rule'][] = $planned['nat']['rule'][1];
$reconciled = lab_rustfs_plan($mixed, $lab);
check($reconciled['nat']['rule'] === $planned['nat']['rule'], 'a pre-existing HTTPS forward is retained while exact legacy forwards are removed');
$partial = $legacy;
array_pop($partial['nat']['rule']);
$reconciled = lab_rustfs_plan($partial, $lab);
check(count($reconciled['nat']['rule']) === 2 && $reconciled['nat']['rule'][1]['destination']['port'] === '443', 'a partial earlier installation is migrated idempotently');

foreach ([
    'a broad legacy source' => fn(&$rule) => $rule['source']['network'] = 'any',
    'a changed legacy target' => fn(&$rule) => $rule['target'] = '10.10.10.61',
    'a changed legacy translation port' => fn(&$rule) => $rule['local-port'] = '9002',
    'a changed legacy description' => fn(&$rule) => $rule['descr'] = 'operator-managed RustFS',
    'an inverted legacy source' => fn(&$rule) => $rule['source']['not'] = '1',
    'an inverted legacy destination' => fn(&$rule) => $rule['destination']['not'] = '1',
    'a legacy source port constraint' => fn(&$rule) => $rule['source']['port'] = '12345',
    'a disabled legacy rule' => fn(&$rule) => $rule['disabled'] = '1',
    'an unrecognized legacy rule option' => fn(&$rule) => $rule['poolopts'] = 'round-robin',
    'an unrecognized legacy source option' => fn(&$rule) => $rule['source']['address'] = 'any',
] as $label => $mutate) {
    $bad = $legacy;
    $mutate($bad['nat']['rule'][1]);
    refused($bad, $lab, $label);
}
$bad = $legacy;
$bad['nat']['rule'][] = $bad['nat']['rule'][1];
refused($bad, $lab, 'a duplicate legacy rule');
$bad = $base;
$bad['dnsmasq']['hosts'][] = ['host' => 'impostor', 'ip' => '10.10.10.60'];
refused($bad, $lab, 'IP collision');
$bad = $base;
$bad['dnsmasq']['hosts'][] = ['host' => 'rustfs', 'domain' => $lab['domain'], 'ip' => '10.10.10.66'];
refused($bad, $lab, 'DNS name collision');
$bad = $base;
$bad['dnsmasq']['hosts'][] = ['host' => 'RustFS-Console', 'domain' => strtoupper($lab['domain']), 'ip' => '10.10.10.66'];
refused($bad, $lab, 'case-insensitive console DNS name collision');
$bad = $base;
$bad['dnsmasq']['hosts'][] = ['host' => 'other', 'ip' => '10.10.10.66', 'cnames' => 'RustFS-Console.' . strtoupper($lab['domain']) . '.'];
refused($bad, $lab, 'console CNAME collision');
$bad = $planned;
$bad['dnsmasq']['hosts'][] = $bad['dnsmasq']['hosts'][3];
refused($bad, $lab, 'duplicate console DNS record');
$bad = $base;
$bad['dnsmasq']['hosts'][] = ['host' => 'other', 'hwaddr' => '02:00:0a:0a:0a:3c'];
refused($bad, $lab, 'MAC collision');
$bad = $base;
$bad['virtualip']['vip'][] = ['subnet' => '10.10.99.6', 'mode' => 'carp', 'interface' => 'wan'];
refused($bad, $lab, 'virtual IP collision');
$bad = $planned;
$bad['nat']['rule'][1]['source']['network'] = 'any';
refused($bad, $lab, 'overly broad NAT source');
$bad = $planned;
$bad['nat']['rule'][1]['source']['not'] = '1';
refused($bad, $lab, 'inverted NAT source');
$bad = $planned;
$bad['nat']['rule'][1]['disabled'] = '1';
refused($bad, $lab, 'disabled NAT rule');
$bad = $planned;
$bad['nat']['rule'][1]['poolopts'] = 'round-robin';
refused($bad, $lab, 'unrecognized HTTPS NAT option');
$bad = $planned;
$bad['nat']['rule'][] = $bad['nat']['rule'][1];
refused($bad, $lab, 'duplicate NAT rule');
$bad = $base;
$bad['nat']['rule'][] = ['target' => '10.10.10.60', 'destination' => ['network' => '10.10.99.6', 'port' => '22']];
refused($bad, $lab, 'extra published RustFS SSH port');
$modern = $base;
$modern['OPNsense']['Firewall']['DestinationNat']['rules']['rule'] = [['destination_net' => '10.10.99.3', 'target' => '10.10.10.30']];
$reconciled = lab_rustfs_plan($modern, $lab);
check($reconciled['OPNsense'] === $modern['OPNsense'], 'unrelated modern DestinationNat configuration is preserved');
foreach (['destination_net' => '10.10.99.6', 'target' => '10.10.10.60'] as $field => $address) {
    $bad = $modern;
    $bad['OPNsense']['Firewall']['DestinationNat']['rules']['rule'][] = [$field => $address];
    refused($bad, $lab, 'modern DestinationNat ' . $field . ' overlap');
}
$badLab = $lab;
foreach ($badLab['published'] as &$entry) {
    if ($entry['vm'] === 'rustfs') { $entry['ports'][] = ['protocol' => 'tcp', 'port' => 22]; }
}
unset($entry);
refused($base, $badLab, 'additional requested public port');
$badLab = $lab;
$badLab['published'][0]['names'][] = 'rustfs-console';
refused($base, $badLab, 'console name used by another publication');
echo "RustFS firewall plan: all tests passed\n";
