<?php
/*
 * opnsense/lab-gui-cert.php -- puts a new TLS certificate into the RUNNING firewall's web GUI
 *
 * Where it runs:
 *   On the firewall, as root, started by ansible/playbooks/firewall.yml (".\lab.ps1 deploy
 *   firewall"), which copies it into a private temporary folder and deletes that afterwards:
 *     php lab-gui-cert.php <key file> <certificate file> <issuing CA certificate file>
 *   All three are PEM files. The key was generated on the firewall itself and never left it; the
 *   certificate was signed by OpenBao's intermediate CA, which is the issuing CA.
 *
 * Why a script: a firewall that was built from the repository gets its first GUI certificate,
 * signed by the offline root, in the rendered config.xml. Renewing it (and moving it to the
 * intermediate CA) should not need a rebuild, so this replaces it in place, like the GUI's
 * System > Trust pages would: OPNsense keeps its configuration in /conf/config.xml, and its PHP
 * library (config.inc) loads that file into the array $config and writes it back with
 * write_config(), which also keeps a backup of the previous version (System > Configuration >
 * History).
 *
 * The trust store in config.xml: the certificate the web GUI uses is the <cert> whose refid is
 * system/webgui/ssl-certref; its <caref> points to the <ca> entry of the CA that issued it, and a
 * <ca> entry can point to ITS issuer the same way. OPNsense follows these links to build the chain
 * the web server sends (certificate, intermediate, root). So:
 *   - the issuing CA gets its own <ca> entry (found by its fingerprint, or added, linked to the
 *     entry of its own issuer - the lab root), and the GUI certificate points to it;
 *   - the GUI certificate's entry is updated in place, so its identifier (refid) stays the same;
 *   - intermediates nothing points to any more (after a rotation of the intermediate) are
 *     removed. A self-signed CA (the root) is never removed.
 *
 * Afterwards the caller restarts the web server (/usr/local/etc/rc.restart_webgui).
 */
require_once('config.inc');
require_once('util.inc');

global $config;

if (count($argv) !== 4) {
    fwrite(STDERR, "usage: php {$argv[0]} <key.pem> <cert.pem> <issuing-ca.pem>\n");
    exit(2);
}
$key = file_get_contents($argv[1]);
$crt = file_get_contents($argv[2]);
$caCrt = file_get_contents($argv[3]);
if ($key === false || $crt === false || $caCrt === false) {
    fwrite(STDERR, "cannot read the PEM files\n");
    exit(1);
}
// The key must belong to the certificate (openssl_x509_check_private_key compares them), and the
// certificate must be issued by the given CA (openssl_x509_verify checks the signature).
if (!openssl_x509_check_private_key($crt, $key)) {
    fwrite(STDERR, "the private key does not match the certificate\n");
    exit(1);
}
if (openssl_x509_verify($crt, openssl_pkey_get_public($caCrt)) !== 1) {
    fwrite(STDERR, "the certificate is not signed by the given CA certificate\n");
    exit(1);
}
$caInfo = openssl_x509_parse($caCrt);
$caFingerprint = openssl_x509_fingerprint($caCrt, 'sha256');

// config.xml stores certificates and keys base64-encoded (of the PEM text).
function lab_parse_entry($entry)
{
    $pem = base64_decode($entry['crt'] ?? '');
    return $pem ? openssl_x509_parse($pem) : false;
}

// OPNsense's Trust pages (its MVC model) address entries by a uuid attribute (<ca uuid="...">;
// "@attributes" in the $config array). A random (version 4) UUID, as OPNsense makes them.
function lab_uuid()
{
    $bytes = random_bytes(16);
    $bytes[6] = chr((ord($bytes[6]) & 0x0f) | 0x40);
    $bytes[8] = chr((ord($bytes[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($bytes), 4));
}

// 1. The <ca> entry of the issuing CA: an existing one with the same certificate, or a new one.
$config['ca'] = $config['ca'] ?? [];
$caRef = null;
foreach ($config['ca'] as $i => $ca) {
    $pem = base64_decode($ca['crt'] ?? '');
    if ($pem && openssl_x509_fingerprint($pem, 'sha256') === $caFingerprint) {
        $caRef = $ca['refid'];
        if (empty($ca['@attributes']['uuid'])) {
            $config['ca'][$i]['@attributes']['uuid'] = lab_uuid();
        }
    }
}
if ($caRef === null) {
    $entry = [
        '@attributes' => ['uuid' => lab_uuid()],
        'refid' => uniqid(),
        'descr' => trim($caInfo['subject']['CN'] ?? 'Lab issuing CA'),
        'crt' => base64_encode($caCrt),
    ];
    // Linked to the entry of its own issuer (the lab root), so the chain reaches the root.
    foreach ($config['ca'] as $ca) {
        $parsed = lab_parse_entry($ca);
        if ($parsed && $parsed['subject'] == $caInfo['issuer']) {
            $entry['caref'] = $ca['refid'];
        }
    }
    $config['ca'][] = $entry;
    $caRef = $entry['refid'];
}

// 2. The web GUI's certificate, updated in place.
$certRef = $config['system']['webgui']['ssl-certref'] ?? '';
$found = false;
foreach ($config['cert'] ?? [] as $i => $cert) {
    if (($cert['refid'] ?? '') === $certRef) {
        $config['cert'][$i]['crt'] = base64_encode($crt);
        $config['cert'][$i]['prv'] = base64_encode($key);
        $config['cert'][$i]['caref'] = $caRef;
        $found = true;
    }
}
if (!$found) {
    fwrite(STDERR, "no certificate with refid '$certRef' (system/webgui/ssl-certref) in config.xml\n");
    exit(1);
}

// 3. Intermediates nothing points to any more.
$used = [];
foreach (array_merge($config['cert'] ?? [], $config['ca']) as $entry) {
    if (!empty($entry['caref'])) {
        $used[$entry['caref']] = true;
    }
}
foreach ($config['ca'] as $i => $ca) {
    $parsed = lab_parse_entry($ca);
    $selfSigned = $parsed && $parsed['subject'] == $parsed['issuer'];
    if (!$selfSigned && empty($ca['prv']) && !isset($used[$ca['refid']])) {
        echo "removed the unused CA entry " . ($ca['descr'] ?? $ca['refid']) . "\n";
        unset($config['ca'][$i]);
    }
}
$config['ca'] = array_values($config['ca']);

write_config('DeployableServer: web GUI certificate renewed (ansible/playbooks/firewall.yml)');
echo "web GUI certificate replaced, issued by " . trim($caInfo['subject']['CN'] ?? '?') . "\n";
