<?php
/* Reconcile only RustFS's DHCP/DNS, HOST virtual IP and PC-only HTTPS forward.
 * php lab-rustfs.php --check|--apply lab.json
 * Existing configuration is preserved; conflicting records stop the run before write_config().
 * --check reads config.xml without writing it or reloading services. The pure function is also
 * used by tests/Test-LabRustfsFirewall.php with an in-memory configuration (no appliance needed).
 */
function lab_rustfs_require($condition, $message)
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function lab_rustfs_equal($actual, $expected)
{
    foreach ($expected as $key => $value) {
        if (is_array($value)) {
            if (!isset($actual[$key]) || !is_array($actual[$key]) || !lab_rustfs_equal($actual[$key], $value)) {
                return false;
            }
        } elseif ((string)($actual[$key] ?? '') !== (string)$value) {
            return false;
        }
    }
    return true;
}

// Only this helper's exact generated NAT shape may be reused or migrated. Reject extra
// match/translation options rather than deleting an operator's superficially similar rule.
function lab_rustfs_managed_rule($actual, $expected)
{
    if (!lab_rustfs_equal($actual, $expected)) {
        return false;
    }
    $allowed = array_merge(array_keys($expected), ['sequence', 'disabled', 'nordr', 'nosync']);
    foreach ($actual as $key => $value) {
        if (!in_array($key, $allowed, true)) {
            return false;
        }
    }
    foreach (['disabled', 'nordr', 'nosync'] as $flag) {
        if (!empty($actual[$flag])) {
            return false;
        }
    }
    if (isset($actual['sequence']) && !ctype_digit((string)$actual['sequence'])) {
        return false;
    }
    foreach (['source', 'destination'] as $side) {
        foreach ($actual[$side] as $key => $value) {
            if (!array_key_exists($key, $expected[$side]) && !($key === 'not' && empty($value)) && !($side === 'source' && $key === 'port' && $value === '')) {
                return false;
            }
        }
    }
    return true;
}

function lab_rustfs_plan($current, $lab)
{
    $vms = array_values(array_filter($lab['vms'] ?? [], fn($vm) => ($vm['name'] ?? '') === 'rustfs'));
    $pubs = array_values(array_filter($lab['published'] ?? [], fn($pub) => ($pub['vm'] ?? '') === 'rustfs'));
    lab_rustfs_require(count($vms) === 1 && count($pubs) === 1, 'lab.json must define exactly one RustFS VM and publication');
    $vm = $vms[0];
    $pub = $pubs[0];
    $ip = $vm['ip'] ?? '';
    $vip = $pub['address'] ?? '';
    $pc = $lab['firewall']['pcIp'] ?? '';
    $domain = $lab['domain'] ?? '';
    lab_rustfs_require(preg_match('/^[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+$/D', $domain), 'Invalid lab domain');
    foreach ([$ip, $vip, $pc] as $address) {
        lab_rustfs_require(filter_var($address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false, 'Invalid IPv4 address in lab.json');
    }
    lab_rustfs_require(count(array_unique([$ip, $vip, $pc, $lab['firewall']['hostIp'], $lab['firewall']['lanIp']])) === 5, 'RustFS addresses collide with firewall or PC');
    lab_rustfs_require(preg_match('/^02[0-9a-f]{10}$/iD', $vm['mac'] ?? ''), 'RustFS needs a locally administered MAC');
    $mac = strtolower(implode(':', str_split($vm['mac'], 2)));
    $hostBits = explode('/', $lab['hostNetwork'] ?? '');
    $labBits = explode('/', $lab['labNetwork'] ?? '');
    foreach ([[$hostBits, $vip], [$labBits, $ip]] as [$network, $address]) {
        lab_rustfs_require(count($network) === 2 && filter_var($network[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false && ctype_digit($network[1]) && (int)$network[1] >= 8 && (int)$network[1] <= 30, 'Invalid lab network');
        $mask = -1 << (32 - (int)$network[1]);
        lab_rustfs_require((ip2long($network[0]) & $mask) === (ip2long($address) & $mask), 'RustFS address lies outside its lab network');
    }
    foreach ($lab['vms'] as $other) {
        if ($other['name'] !== 'rustfs') {
            lab_rustfs_require($other['ip'] !== $ip && strcasecmp($other['mac'], $vm['mac']) !== 0, 'RustFS VM address or MAC collides in lab.json');
            lab_rustfs_require(!in_array($other['name'], ['rustfs', 'rustfs-console'], true), 'RustFS DNS name collides with a VM in lab.json');
        }
    }
    foreach ($lab['published'] as $other) {
        lab_rustfs_require($other['vm'] === 'rustfs' || $other['address'] !== $vip, 'RustFS publication collides in lab.json');
        lab_rustfs_require($other['vm'] === 'rustfs' || !array_intersect($other['names'] ?? [], ['rustfs', 'rustfs-console']), 'RustFS DNS name collides with a publication in lab.json');
    }
    lab_rustfs_require(($pub['names'] ?? []) === ['rustfs', 'rustfs-console'], 'This helper publishes only rustfs.<domain> and rustfs-console.<domain>');
    $ports = array_map(fn($port) => ($port['protocol'] ?? '') . ':' . ($port['port'] ?? ''), $pub['ports'] ?? []);
    sort($ports);
    lab_rustfs_require($ports === ['tcp:443'], 'Only RustFS TCP port 443 may be published');
    foreach (['lan' => 'lanIp', 'opt1' => 'hostIp'] as $interface => $key) {
        lab_rustfs_require(isset($current['interfaces'][$interface]['enable']) && ($current['interfaces'][$interface]['ipaddr'] ?? '') === $lab['firewall'][$key], 'Firewall interface does not match lab.json: ' . $interface);
    }
    lab_rustfs_require(($current['dnsmasq']['enable'] ?? '') === '1' && in_array('lan', explode(',', $current['dnsmasq']['interface'] ?? ''), true) && in_array('opt1', explode(',', $current['dnsmasq']['interface'] ?? ''), true), 'Expected lab dnsmasq configuration is missing');
    lab_rustfs_require(in_array('opt1', explode(',', $current['dnsmasq']['dhcp']['no_interface'] ?? ''), true), 'DHCP must remain disabled on HOST');

    // Modern DestinationNat rules coexist with legacy nat/rule entries. This helper owns
    // only the latter; refuse overlaps in the modern model rather than shadowing a rule.
    foreach ($current['OPNsense']['Firewall']['DestinationNat']['rules']['rule'] ?? [] as $rule) {
        $serialized = json_encode($rule, JSON_THROW_ON_ERROR);
        lab_rustfs_require(strpos($serialized, $ip) === false && strpos($serialized, $vip) === false, 'Modern DestinationNat rule mentions a RustFS address; inspect it before migration');
    }

    // Plan on a copy. No partial mutation survives a later validation error.
    $next = $current;
    $wantedHosts = [
        ['host' => 'rustfs', 'domain' => $domain, 'ip' => $ip, 'hwaddr' => $mac],
        ['host' => 'rustfs', 'domain' => $domain, 'ip' => $vip, 'hwaddr' => ''],
        ['host' => 'rustfs-console', 'domain' => $domain, 'ip' => $ip . ',' . $vip, 'hwaddr' => ''],
    ];
    $foundHosts = array_fill(0, count($wantedHosts), false);
    foreach ($current['dnsmasq']['hosts'] ?? [] as $host) {
        $addresses = explode(',', $host['ip'] ?? '');
        $macs = explode(',', strtolower($host['hwaddr'] ?? ''));
        $sameName = in_array(strtolower($host['host'] ?? ''), $pub['names'], true) && strtolower($host['domain'] ?? '') === $domain;
        $cnames = array_map(fn($name) => strtolower(rtrim($name, '.')), explode(',', $host['cnames'] ?? ''));
        $collision = $sameName || in_array($ip, $addresses, true) || in_array($vip, $addresses, true) || in_array($mac, $macs, true) || count(array_intersect($cnames, array_map(fn($name) => $name . '.' . $domain, $pub['names']))) > 0;
        if (!$collision) {
            continue;
        }
        $matched = false;
        foreach ($wantedHosts as $i => $wanted) {
            if (lab_rustfs_equal($host, $wanted) && empty($host['ignore']) && empty($host['client_id']) && empty($host['cnames']) && empty($host['set_tag'])) {
                lab_rustfs_require(!$foundHosts[$i], 'Duplicate RustFS DNS/DHCP record');
                $foundHosts[$i] = $matched = true;
            }
        }
        lab_rustfs_require($matched, 'Existing DNS/DHCP record conflicts with RustFS; inspect it before onboarding');
    }
    foreach ($wantedHosts as $i => $wanted) {
        if (!$foundHosts[$i]) {
            if ($wanted['hwaddr'] === '') {
                unset($wanted['hwaddr']);
            }
            $wanted['descr'] = $i === 0 ? 'Lab VM (DHCP reservation)' : 'Published name of rustfs';
            $next['dnsmasq']['hosts'][] = $wanted;
        }
    }
    $wantedVip = ['interface' => 'opt1', 'mode' => 'ipalias', 'subnet' => $vip, 'subnet_bits' => $hostBits[1], 'noexpand' => '0', 'nobind' => '1'];
    $foundVip = false;
    foreach ($current['virtualip']['vip'] ?? [] as $existing) {
        if (($existing['subnet'] ?? '') === $vip) {
            lab_rustfs_require(!$foundVip && lab_rustfs_equal($existing, $wantedVip), 'Existing virtual IP conflicts with RustFS');
            $foundVip = true;
        }
    }
    if (!$foundVip) {
        $next['virtualip']['vip'][] = $wantedVip + ['advbase' => '1', 'advskew' => '0', 'nosync' => '0', 'descr' => 'Published address of rustfs'];
    }
    $ruleForPort = fn($port) => ['interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => 'tcp', 'source' => ['network' => $pc], 'destination' => ['network' => $vip, 'port' => (string)$port], 'target' => $ip, 'local-port' => (string)$port, 'pass' => 'rule'];
    $wantedRules = [443 => $ruleForPort(443) + ['descr' => 'rustfs: HTTPS (RustFS S3 API and console)']];
    $legacyRules = [];
    foreach ([9000 => 'RustFS S3 API', 9001 => 'RustFS console'] as $port => $service) {
        $legacyRules[$port] = $ruleForPort($port) + ['descr' => 'rustfs: HTTPS (' . $service . ')'];
    }
    $foundRules = [];
    $foundLegacyRules = [];
    $sequence = 100;
    foreach ($current['nat']['rule'] ?? [] as $index => $rule) {
        $sequence = max($sequence, (int)($rule['sequence'] ?? 0) + 10);
        if (($rule['target'] ?? '') !== $ip && ($rule['destination']['network'] ?? '') !== $vip) {
            continue;
        }
        $port = $rule['destination']['port'] ?? '';
        if (isset($legacyRules[$port])) {
            lab_rustfs_require(!isset($foundLegacyRules[$port]) && lab_rustfs_managed_rule($rule, $legacyRules[$port]), 'Existing legacy NAT rule is not the exact managed PC-only RustFS forward; inspect it before migration');
            $foundLegacyRules[$port] = true;
            unset($next['nat']['rule'][$index]);
            continue;
        }
        lab_rustfs_require(isset($wantedRules[$port]) && !isset($foundRules[$port]) && lab_rustfs_managed_rule($rule, $wantedRules[$port]), 'Existing NAT rule conflicts with RustFS or permits a source other than the PC');
        $foundRules[$port] = true;
    }
    if ($foundLegacyRules) {
        $next['nat']['rule'] = array_values($next['nat']['rule']);
    }
    foreach ($wantedRules as $port => $wanted) {
        if (!isset($foundRules[$port])) {
            $next['nat']['rule'][] = ['sequence' => (string)$sequence] + $wanted;
            $sequence += 10;
        }
    }
    return $next;
}

if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    try {
        lab_rustfs_require(count($argv) === 3 && in_array($argv[1], ['--check', '--apply'], true), 'usage: php lab-rustfs.php --check|--apply lab.json');
        $lab = json_decode(file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
        require_once('config.inc');
        require_once('util.inc');
        global $config;
        $next = lab_rustfs_plan($config, $lab);
        $changed = $next !== $config;
        if ($changed && $argv[1] === '--apply') {
            // A failed service reload leaves this marker, so a retry also activates an already
            // written configuration. write_config() retains OPNsense's normal config history.
            lab_rustfs_require(file_put_contents('/var/run/lab-rustfs.pending', "pending\n") !== false, 'Cannot record pending activation');
            $config = $next;
            // stable/26.7 config.inc returns the normalized config array after a successful
            // save, false for a read-only user and -1 when Config::save() fails.
            $saved = write_config('DeployableServer: reconcile RustFS DNS, virtual IP and PC-only HTTPS; migrate managed backend forwards');
            lab_rustfs_require(is_array($saved), 'OPNsense could not save the configuration');
        }
        echo $changed ? "changed\n" : "unchanged\n";
    } catch (Throwable $error) {
        fwrite(STDERR, 'RustFS onboarding refused: ' . $error->getMessage() . "\n");
        exit(1);
    }
}
