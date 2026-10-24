<?php
/*
 * opnsense/lab-ssh-trust.php -- sets the SSH keys that may log in as user "ansible" on the
 * RUNNING firewall
 *
 * Where it runs:
 *   On the firewall, as root, started over SSH by scripts/lib/LabSsh.ps1 (Set-LabFirewallSshTrust,
 *   used by lab.ps1 firewall and lab.ps1 deploy vault); it is copied to a private /tmp folder
 *   and deleted again afterwards:
 *     php lab-ssh-trust.php <authorized_keys file>
 *   The file is keys\ssh\firewall_authorized_keys from the PC: one line per lab SSH CA,
 *     cert-authority,principals="lab-all,host-firewall",from="<PC>,<ansible-control>" ssh-ed25519 AAAA...
 *   "cert-authority" makes the line accept CERTIFICATES signed by that CA instead of one key;
 *   principals= says which certificate principals log in here, from= from which addresses.
 *
 * Why a script: OPNsense keeps every user's authorized keys in /conf/config.xml (base64, in
 * <authorizedkeys>) and writes ~/.ssh/authorized_keys from there. A new firewall gets the lines
 * in its rendered config.xml; a running one gets them here whenever the set of CAs changes
 * (OpenBao's CA added after lab.ps1 deploy vault, removed when the vault VM is rebuilt) - without a
 * rebuild. The same as pasting the keys into System > Access > Users in the GUI: write_config()
 * keeps a backup of the previous version (System > Configuration > History), and
 * local_user_set() (OPNsense's own function) writes ~ansible/.ssh/authorized_keys again.
 *
 * Prints "changed" when config.xml was changed.
 */
require_once('config.inc');
require_once('auth.inc');

global $config;

if (count($argv) !== 2) {
    fwrite(STDERR, "usage: php {$argv[0]} <authorized_keys file>\n");
    exit(2);
}
$text = file_get_contents($argv[1]);
if ($text === false) {
    fwrite(STDERR, "cannot read {$argv[1]}\n");
    exit(1);
}
$lines = array_values(array_filter(array_map('trim', preg_split('/\r?\n/', $text)), 'strlen'));
if (count($lines) === 0) {
    fwrite(STDERR, "no keys: refusing to lock user ansible out\n");
    exit(1);
}
foreach ($lines as $line) {
    // Only CA lines with principals and source addresses: no plain key ever logs in as ansible.
    if (!preg_match('/^cert-authority,principals="[a-z0-9,.-]+",from="[0-9.,\/]+" ssh-ed25519 [A-Za-z0-9+\/]+=* [a-z0-9-]+$/', $line)) {
        fwrite(STDERR, "refusing an unexpected line: {$line}\n");
        exit(1);
    }
}
$wanted = base64_encode(implode("\n", $lines) . "\n");

$found = false;
foreach ($config['system']['user'] ?? [] as $i => $user) {
    if (($user['name'] ?? '') !== 'ansible') {
        continue;
    }
    $found = true;
    if (($user['authorizedkeys'] ?? '') !== $wanted) {
        $config['system']['user'][$i]['authorizedkeys'] = $wanted;
        write_config('DeployableServer: SSH CAs of user ansible (scripts/lib/LabSsh.ps1)');
        echo "changed\n";
    }
    // Writes ~ansible/.ssh/authorized_keys from config.xml, also when nothing changed (repairs a
    // file that was edited by hand).
    local_user_set($config['system']['user'][$i]);
}
if (!$found) {
    fwrite(STDERR, "no user 'ansible' in config.xml\n");
    exit(1);
}
