<?php
/* Pure, bounded planning plus an appliance CLI. Bootstrap adds only nginx DHCP/DNS;
 * route atomically migrates the exact managed web ingress and split DNS records.
 * php lab-nginx.php --check|--apply|--status lab.json [--bootstrap]
 */
function lab_nginx_require($condition, $message)
{
    if (!$condition) { throw new RuntimeException($message); }
}

function lab_nginx_equal($actual, $expected)
{
    foreach ($expected as $key => $value) {
        if (is_array($value)) {
            if (!isset($actual[$key]) || !is_array($actual[$key]) || !lab_nginx_equal($actual[$key], $value)) { return false; }
        } elseif ((string)($actual[$key] ?? '') !== (string)$value) { return false; }
    }
    return true;
}

// Inactive model defaults and informational metadata have no packet semantics.
function lab_nginx_safe_normalized_field($key, $value)
{
    if (in_array($key, ['poolopts', 'category', 'tag', 'tagged', 'natreflection', 'associated-rule-id'], true)) { return $value === ''; }
    if ($key === 'log') { return $value === '' || $value === '0'; }
    if ($key === '@attributes') {
        return is_array($value) && array_keys($value) === ['uuid'] && is_string($value['uuid']) && preg_match('/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/iD', $value['uuid']);
    }
    if (in_array($key, ['created', 'updated'], true) && is_array($value)) {
        $keys = array_keys($value); sort($keys);
        return $keys === ['description', 'time', 'username'] && is_string($value['username']) && is_string($value['description']) && is_string($value['time']) && ($value['time'] === '' || ctype_digit($value['time']));
    }
    return false;
}

function lab_nginx_managed_rule($actual, $expected)
{
    if (!lab_nginx_equal($actual, $expected)) { return false; }
    $allowed = array_merge(array_keys($expected), ['sequence', 'disabled', 'nordr', 'nosync']);
    foreach ($actual as $key => $value) {
        if (!in_array($key, $allowed, true) && !lab_nginx_safe_normalized_field($key, $value)) { return false; }
    }
    foreach (['disabled', 'nordr', 'nosync'] as $flag) { if (!empty($actual[$flag])) { return false; } }
    if (isset($actual['sequence']) && !ctype_digit((string)$actual['sequence'])) { return false; }
    foreach (['source', 'destination'] as $side) {
        foreach ($actual[$side] as $key => $value) {
            if (!array_key_exists($key, $expected[$side]) && !($key === 'not' && empty($value)) && !($side === 'source' && $key === 'port' && $value === '')) { return false; }
        }
    }
    return true;
}

// Field names only: never log appliance configuration values.
function lab_nginx_rule_difference($actual, $expected)
{
    $issues = [];
    foreach ($expected as $key => $value) {
        if (is_array($value)) {
            foreach ($value as $child => $wanted) { if ((string)($actual[$key][$child] ?? '') !== (string)$wanted) { $issues[] = 'different ' . $key . '.' . $child; } }
        } elseif ((string)($actual[$key] ?? '') !== (string)$value) { $issues[] = 'different ' . $key; }
    }
    $allowed = array_merge(array_keys($expected), ['sequence', 'disabled', 'nordr', 'nosync']);
    foreach ($actual as $key => $value) {
        if (!in_array($key, $allowed, true) && !lab_nginx_safe_normalized_field($key, $value)) { $issues[] = 'unknown or active ' . $key; }
    }
    foreach (['source', 'destination'] as $side) {
        foreach ($actual[$side] ?? [] as $key => $value) {
            if (!array_key_exists($key, $expected[$side]) && !($key === 'not' && empty($value)) && !($side === 'source' && $key === 'port' && $value === '')) { $issues[] = 'unknown ' . $side . '.' . $key; }
        }
    }
    foreach (['disabled', 'nordr', 'nosync'] as $flag) { if (!empty($actual[$flag])) { $issues[] = 'enabled ' . $flag; } }
    return implode(', ', $issues);
}

function lab_nginx_in_network($address, $network)
{
    $bits = explode('/', $network);
    lab_nginx_require(filter_var($address, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false && count($bits) === 2 && filter_var($bits[0], FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false && ctype_digit($bits[1]) && (int)$bits[1] >= 8 && (int)$bits[1] <= 30, 'Invalid IPv4 address or lab network');
    $mask = -1 << (32 - (int)$bits[1]);
    return (ip2long($bits[0]) & $mask) === (ip2long($address) & $mask);
}

function lab_nginx_mac($vm)
{
    lab_nginx_require(preg_match('/^02[0-9a-f]{10}$/iD', $vm['mac'] ?? ''), 'Managed VM needs a locally administered MAC');
    return strtolower(implode(':', str_split($vm['mac'], 2)));
}

function lab_nginx_host($name, $addresses, $domain, $mac = '')
{
    if ($name === '@') { [$name, $domain] = explode('.', $domain, 2); }
    return ['host' => $name, 'domain' => $domain, 'ip' => $addresses, 'hwaddr' => $mac];
}

function lab_nginx_managed_host($actual, $expected)
{
    if (!lab_nginx_equal($actual, $expected)) { return false; }
    foreach ($actual as $key => $value) {
        if (in_array($key, ['host', 'domain', 'ip', 'hwaddr', 'descr'], true)) { continue; }
        if (in_array($key, ['ignore', 'local'], true) && ($value === '' || $value === '0')) { continue; }
        if (in_array($key, ['set_tag', 'client_id', 'cnames', 'lease_time', 'comments', 'aliases'], true) && $value === '') { continue; }
        if ($key === '@attributes' && lab_nginx_safe_normalized_field($key, $value)) { continue; }
        return false;
    }
    return true;
}

function lab_nginx_plan_dns($hosts, $lab, $vms, $bootstrap)
{
    $domain = $lab['domain']; $ip = $vms['nginx']['ip'];
    $nginx = lab_nginx_host('nginx', $ip, $domain, lab_nginx_mac($vms['nginx']));
    $slots = ['nginx' => ['old' => $nginx, 'new' => $nginx, 'optional' => true]];
    if (!$bootstrap) {
        foreach ($lab['published'] as $pub) {
            $vm = $vms[$pub['vm']]; $name = $pub['vm']; $mac = lab_nginx_mac($vm);
            $slots[$name . '-reservation'] = ['old' => lab_nginx_host($name, $vm['ip'], $domain, $mac), 'new' => lab_nginx_host($name . '-backend', $vm['ip'], $domain, $mac)];
            foreach ($pub['names'] as $alias) {
                $slots[$name . '-dns-' . $alias] = [
                    'old' => lab_nginx_host($alias, $alias === $name ? $pub['address'] : $vm['ip'] . ',' . $pub['address'], $domain),
                    'new' => lab_nginx_host($alias, $ip . ',' . $pub['address'], $domain),
                ];
            }
        }
        $slots['firewall'] = ['old' => lab_nginx_host('firewall', $lab['firewall']['lanIp'] . ',' . $lab['firewall']['hostIp'], $domain), 'new' => lab_nginx_host('firewall', $ip . ',' . $lab['firewall']['hostIp'], $domain)];
    }
    $reservedNames = []; $reservedIps = []; $reservedMacs = [];
    foreach ($slots as $slot) {
        foreach (['old', 'new'] as $version) {
            $entry = $slot[$version];
            $reservedNames[] = strtolower($entry['host'] . '.' . $entry['domain']);
            $reservedIps = array_merge($reservedIps, explode(',', $entry['ip']));
            if ($entry['hwaddr'] !== '') { $reservedMacs[] = $entry['hwaddr']; }
        }
    }
    $seen = []; $next = $hosts;
    foreach ($hosts as $index => $host) {
        $fqdn = strtolower(($host['host'] ?? '') . '.' . ($host['domain'] ?? ''));
        $cnames = array_map(fn($name) => strtolower(rtrim($name, '.')), explode(',', $host['cnames'] ?? ''));
        $collision = in_array($fqdn, $reservedNames, true) || count(array_intersect(explode(',', $host['ip'] ?? ''), $reservedIps)) > 0 || count(array_intersect(explode(',', strtolower($host['hwaddr'] ?? '')), $reservedMacs)) > 0 || count(array_intersect($cnames, $reservedNames)) > 0;
        if (!$collision) { continue; }
        // On a routed appliance many names intentionally share nginx's address. Bootstrap
        // owns only its own reservation, so preserve these already-migrated web records.
        if ($bootstrap && $fqdn !== 'nginx.' . $domain && !in_array(lab_nginx_mac($vms['nginx']), explode(',', strtolower($host['hwaddr'] ?? '')), true)) {
            $approved = false;
            foreach ($lab['published'] as $pub) {
                foreach ($pub['names'] as $alias) {
                    if (lab_nginx_managed_host($host, lab_nginx_host($alias, $ip . ',' . $pub['address'], $domain))) { $approved = true; }
                }
            }
            if (lab_nginx_managed_host($host, lab_nginx_host('firewall', $ip . ',' . $lab['firewall']['hostIp'], $domain))) { $approved = true; }
            lab_nginx_require($approved, 'Conflicting nginx DNS address or alias');
            continue;
        }
        $matched = null;
        foreach ($slots as $slotKey => $slot) {
            if (lab_nginx_managed_host($host, $slot['old']) || lab_nginx_managed_host($host, $slot['new'])) { $matched = $slotKey; break; }
        }
        lab_nginx_require($matched !== null && !isset($seen[$matched]), 'Conflicting or duplicate managed DNS/DHCP record');
        $seen[$matched] = true;
        if (!$bootstrap) {
            foreach (['host', 'domain', 'ip'] as $field) { $next[$index][$field] = $slots[$matched]['new'][$field]; }
        }
    }
    foreach ($slots as $slotKey => $slot) {
        if (isset($seen[$slotKey])) { continue; }
        lab_nginx_require(!empty($slot['optional']), 'A managed DNS/DHCP record is missing: ' . $slotKey);
        $entry = $slot['new'];
        if ($entry['hwaddr'] === '') { unset($entry['hwaddr']); }
        $next[] = $entry + ['descr' => 'Lab VM (DHCP reservation)'];
    }
    return $next;
}

function lab_nginx_plan($current, $lab, $bootstrap = false)
{
    $domain = $lab['domain'] ?? '';
    lab_nginx_require(preg_match('/^[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+$/D', $domain), 'Invalid lab domain');
    lab_nginx_require(is_array($lab['centralIngress'] ?? null) && count($lab['centralIngress']) === 2 && ($lab['centralIngress']['firewallGui'] ?? null) === true && ($lab['centralIngress']['internalWebDns'] ?? null) === true, 'Both approved central ingress features must be enabled');
    $vms = []; $usedIps = []; $usedMacs = [];
    foreach ($lab['vms'] ?? [] as $vm) {
        lab_nginx_require(isset($vm['name']) && !isset($vms[$vm['name']]), 'Missing or duplicate VM in lab.json');
        lab_nginx_require(lab_nginx_in_network($vm['ip'] ?? '', $lab['labNetwork'] ?? ''), 'VM lies outside the lab network');
        $mac = lab_nginx_mac($vm);
        lab_nginx_require(!in_array($vm['ip'], $usedIps, true) && !in_array($mac, $usedMacs, true), 'Duplicate VM IP or MAC');
        $vms[$vm['name']] = $vm; $usedIps[] = $vm['ip']; $usedMacs[] = $mac;
    }
    lab_nginx_require(isset($vms['nginx']), 'lab.json must define nginx');
    $ip = $vms['nginx']['ip'];
    foreach (['lanIp', 'hostIp', 'pcIp'] as $key) {
        lab_nginx_require(filter_var($lab['firewall'][$key] ?? '', FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) !== false && !in_array($lab['firewall'][$key], $usedIps, true), 'Firewall/PC address invalid or collides with a VM');
    }
    lab_nginx_require(count(array_unique(array_values($lab['firewall']))) === 3, 'Firewall/PC addresses collide');
    foreach (['lan' => 'lanIp', 'opt1' => 'hostIp'] as $interface => $key) {
        lab_nginx_require(isset($current['interfaces'][$interface]['enable']) && ($current['interfaces'][$interface]['ipaddr'] ?? '') === $lab['firewall'][$key], 'Firewall interface does not match lab.json: ' . $interface);
    }
    lab_nginx_require(($current['dnsmasq']['enable'] ?? '') === '1' && in_array('lan', explode(',', $current['dnsmasq']['interface'] ?? ''), true) && in_array('opt1', explode(',', $current['dnsmasq']['interface'] ?? ''), true), 'Expected lab dnsmasq configuration is missing');
    lab_nginx_require(in_array('opt1', explode(',', $current['dnsmasq']['dhcp']['no_interface'] ?? ''), true), 'DHCP must remain disabled on HOST');
    lab_nginx_require(!array_key_exists('no_hosts', $current['dnsmasq']) || in_array($current['dnsmasq']['no_hosts'], ['', '0', '1'], true), 'Unexpected dnsmasq system-host lookup setting');

    $allowedNames = ['matrix' => ['matrix', 'element', '@'], 'keycloak' => ['keycloak'], 'vault' => ['vault'], 'rustfs' => ['rustfs', 'rustfs-console']];
    $allowedPorts = ['matrix' => ['tcp:443', 'tcp:7881', 'tcp:80', 'udp:7882'], 'keycloak' => ['tcp:443'], 'vault' => ['tcp:443', 'tcp:80', 'tcp:8200'], 'rustfs' => ['tcp:443']];
    $allowedOverrides = ['matrix:tcp:443', 'matrix:tcp:80', 'keycloak:tcp:443', 'vault:tcp:443', 'vault:tcp:80', 'vault:tcp:8200', 'rustfs:tcp:443'];
    $expected = []; $affectedVips = []; $affectedIps = [$ip]; $overrides = []; $publications = [];
    foreach ($lab['published'] ?? [] as $pub) {
        $name = $pub['vm'] ?? '';
        lab_nginx_require(isset($allowedNames[$name], $vms[$name]) && !isset($publications[$name]), 'Unknown or duplicate managed publication');
        lab_nginx_require(($pub['names'] ?? []) === $allowedNames[$name], 'Unexpected managed publication DNS names');
        lab_nginx_require(lab_nginx_in_network($pub['address'] ?? '', $lab['hostNetwork'] ?? '') && !in_array($pub['address'], array_merge($affectedVips, array_values($lab['firewall'])), true), 'Published address invalid or collides');
        $actualPorts = array_map(fn($port) => ($port['protocol'] ?? '') . ':' . ($port['port'] ?? ''), $pub['ports'] ?? []); sort($actualPorts);
        lab_nginx_require($actualPorts === $allowedPorts[$name], 'Unexpected ports on a managed ingress publication');
        $publications[$name] = true; $affectedVips[] = $pub['address']; $affectedIps[] = $vms[$name]['ip'];
        foreach ($pub['ports'] as $port) {
            $key = $name . ':' . $port['protocol'] . ':' . $port['port'];
            if (isset($port['targetVm'])) {
                lab_nginx_require($port['targetVm'] === 'nginx' && in_array($key, $allowedOverrides, true), 'Unsupported ingress target override');
                $overrides[$key] = true;
            }
            $newVaultHttps = $name === 'vault' && $port['protocol'] === 'tcp' && (int)$port['port'] === 443;
            $source = $name === 'rustfs' ? $lab['firewall']['pcIp'] : 'any';
            $ruleKey = $pub['address'] . ':' . $port['protocol'] . ':' . $port['port'];
            $expected[$ruleKey] = [
                'originalTarget' => $newVaultHttps ? $ip : $vms[$name]['ip'], 'newTarget' => isset($port['targetVm']) ? $ip : $vms[$name]['ip'], 'optional' => $newVaultHttps,
                'legacyDescription' => $name === 'vault' && (int)$port['port'] === 8200 ? 'vault: HTTPS (OpenBao API, web UI and ACME directory)' : null,
                'rule' => ['interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => $port['protocol'], 'source' => ['network' => $source], 'destination' => ['network' => $pub['address'], 'port' => (string)$port['port']], 'local-port' => (string)$port['port'], 'pass' => 'rule', 'descr' => $name . ': ' . $port['description']],
            ];
        }
    }
    lab_nginx_require(count($publications) === count($allowedNames), 'Exactly one publication per managed ingress service is required');
    $overrideKeys = array_keys($overrides); sort($overrideKeys); sort($allowedOverrides);
    lab_nginx_require($overrideKeys === $allowedOverrides, 'Exactly the seven approved ingress overrides are required');
    foreach ($affectedVips as $vip) {
        $matches = array_values(array_filter($current['virtualip']['vip'] ?? [], fn($entry) => ($entry['subnet'] ?? '') === $vip));
        lab_nginx_require(count($matches) === 1 && lab_nginx_equal($matches[0], ['interface' => 'opt1', 'mode' => 'ipalias', 'subnet_bits' => explode('/', $lab['hostNetwork'])[1], 'noexpand' => '0', 'nobind' => '1']), 'Missing, duplicate or incompatible managed virtual IP');
    }
    $guiKey = $lab['firewall']['hostIp'] . ':tcp:443';
    $expected[$guiKey] = ['originalTarget' => $ip, 'newTarget' => $ip, 'optional' => true, 'rule' => ['interface' => 'opt1', 'ipprotocol' => 'inet', 'protocol' => 'tcp', 'source' => ['network' => $lab['firewall']['pcIp']], 'destination' => ['network' => $lab['firewall']['hostIp'], 'port' => '443'], 'local-port' => '443', 'pass' => 'rule', 'descr' => 'nginx: HTTPS (OPNsense web GUI and REST API)']];
    $affectedDestinations = array_merge($affectedVips, [$lab['firewall']['hostIp']]);
    foreach ($current['OPNsense']['Firewall']['DestinationNat']['rules']['rule'] ?? [] as $rule) {
        $serialized = json_encode($rule, JSON_THROW_ON_ERROR);
        foreach (array_merge($affectedDestinations, $affectedIps) as $address) {
            lab_nginx_require(strpos($serialized, $address) === false, 'Modern DestinationNat overlaps managed ingress; inspect it first');
        }
    }
    $next = $current; $seen = []; $sequence = 100;
    foreach ($current['nat']['rule'] ?? [] as $index => $rule) {
        $sequence = max($sequence, (int)($rule['sequence'] ?? 0) + 10);
        $vip = $rule['destination']['network'] ?? '';
        if (!in_array($vip, $affectedDestinations, true) && !in_array($rule['target'] ?? '', $affectedIps, true)) { continue; }
        $key = $vip . ':' . ($rule['protocol'] ?? '') . ':' . ($rule['destination']['port'] ?? '');
        lab_nginx_require(isset($expected[$key]) && !isset($seen[$key]), 'Unknown or duplicate managed ingress NAT rule');
        $wanted = $expected[$key];
        lab_nginx_require(in_array($rule['target'] ?? '', [$wanted['originalTarget'], $wanted['newTarget']], true), 'Managed ingress NAT target changed unexpectedly');
        $shape = $wanted['rule'] + ['target' => $rule['target']];
        if (($wanted['legacyDescription'] ?? null) !== null && ($rule['descr'] ?? '') === $wanted['legacyDescription']) { $shape['descr'] = $wanted['legacyDescription']; }
        lab_nginx_require(lab_nginx_managed_rule($rule, $shape), 'Managed ingress NAT options/source differ for ' . $key . ': ' . lab_nginx_rule_difference($rule, $shape));
        $seen[$key] = true;
        if (!$bootstrap) { $next['nat']['rule'][$index]['target'] = $wanted['newTarget']; }
    }
    foreach ($expected as $key => $wanted) {
        if (isset($seen[$key])) { continue; }
        lab_nginx_require($wanted['optional'], 'A managed publication NAT rule is missing; refusing partial cutover');
        if (!$bootstrap) { $next['nat']['rule'][] = ['sequence' => (string)$sequence, 'target' => $wanted['newTarget']] + $wanted['rule']; $sequence += 10; }
    }
    $next['dnsmasq']['hosts'] = lab_nginx_plan_dns($current['dnsmasq']['hosts'] ?? [], $lab, $vms, $bootstrap);
    // OPNsense also publishes its own interface name through /etc/hosts. Stop importing
    // that system file into DNS after cutover, or firewall.<domain> still returns LAN .1.
    // The supported no_hosts setting keeps both generated addn-hosts files (managed
    // split DNS/reservations and DHCP leases); it does not alter the system's /etc/hosts.
    if (!$bootstrap) { $next['dnsmasq']['no_hosts'] = '1'; }
    return $next;
}

if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    try {
        lab_nginx_require((count($argv) === 3 || (count($argv) === 4 && $argv[3] === '--bootstrap')) && in_array($argv[1], ['--check', '--apply', '--status'], true), 'usage: php lab-nginx.php --check|--apply|--status lab.json [--bootstrap]');
        lab_nginx_require($argv[1] !== '--status' || count($argv) === 3, '--status describes the full route stage and takes no --bootstrap flag');
        $lab = json_decode(file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
        require_once('config.inc'); require_once('util.inc'); global $config;
        $next = lab_nginx_plan($config, $lab, count($argv) === 4);
        $changed = $next !== $config;
        if ($argv[1] === '--status') { echo $changed ? "bootstrap\n" : "routed\n"; exit(0); }
        if ($changed && $argv[1] === '--apply') {
            lab_nginx_require(file_put_contents('/var/run/lab-nginx.pending', "pending\n") !== false, 'Cannot record pending activation');
            $config = $next;
            lab_nginx_require(is_array(write_config('DeployableServer: reconcile exact central nginx ingress, private backend reservations and split DNS')), 'OPNsense could not save the configuration');
        }
        echo $changed ? "changed\n" : "unchanged\n";
    } catch (Throwable $error) {
        fwrite(STDERR, 'nginx firewall reconciliation refused: ' . $error->getMessage() . "\n"); exit(1);
    }
}
