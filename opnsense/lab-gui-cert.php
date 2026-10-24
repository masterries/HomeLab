<?php
/*
 * opnsense/lab-gui-cert.php -- puts a new TLS certificate into the RUNNING firewall's web GUI
 *
 * Where it runs:
 *   On the firewall, as root, started by scripts/New-LabFirewall.ps1 (Update-GuiCertificate)
 *   over SSH; it copies this file to /tmp and deletes it again afterwards:
 *     php lab-gui-cert.php <key file> <certificate file> <CA certificate file>
 *   All three are PEM files. The key was generated on the firewall itself and never left it;
 *   the certificate was signed on the PC by the lab's offline root CA.
 *
 * Why a script: a firewall that was built from the repository gets its GUI certificate in the
 * rendered config.xml. A certificate that expires (or a new CA) should not need a rebuild, so
 * this replaces it in place, like the GUI's System > Trust pages would: OPNsense keeps its
 * configuration in /conf/config.xml, and its PHP library (config.inc) loads that file into the
 * array $config and writes it back with write_config(), which also keeps a backup of the
 * previous version (System > Configuration > History). The certificate the web GUI uses is
 * the <cert> whose refid is system/webgui/ssl-certref; its <caref> points to the <ca> entry
 * that holds the issuing CA's certificate (shown as the chain in the GUI). Both entries are
 * updated in place, so their identifiers (refid, uuid) stay the same.
 *
 * Afterwards the caller restarts the web server (configctl webgui restart).
 */
require_once('config.inc');
require_once('util.inc');

global $config;

if (count($argv) !== 4) {
    fwrite(STDERR, "usage: php {$argv[0]} <key.pem> <cert.pem> <ca.pem>\n");
    exit(2);
}
$key = file_get_contents($argv[1]);
$crt = file_get_contents($argv[2]);
$caCrt = file_get_contents($argv[3]);
if ($key === false || $crt === false || $caCrt === false) {
    fwrite(STDERR, "cannot read the PEM files\n");
    exit(1);
}
// The key must belong to the certificate (openssl_x509_check_private_key compares them).
if (!openssl_x509_check_private_key($crt, $key)) {
    fwrite(STDERR, "the private key does not match the certificate\n");
    exit(1);
}

$certRef = $config['system']['webgui']['ssl-certref'] ?? '';
$caRef = null;
foreach ($config['cert'] ?? [] as $i => $cert) {
    if (($cert['refid'] ?? '') === $certRef) {
        // config.xml stores certificates and keys base64-encoded (of the PEM text).
        $config['cert'][$i]['crt'] = base64_encode($crt);
        $config['cert'][$i]['prv'] = base64_encode($key);
        $caRef = $cert['caref'] ?? '';
    }
}
if ($caRef === null) {
    fwrite(STDERR, "no certificate with refid '$certRef' (system/webgui/ssl-certref) in config.xml\n");
    exit(1);
}
$caFound = false;
foreach ($config['ca'] ?? [] as $i => $ca) {
    if (($ca['refid'] ?? '') === $caRef) {
        $config['ca'][$i]['crt'] = base64_encode($caCrt);
        $config['ca'][$i]['descr'] = trim(openssl_x509_parse($caCrt)['subject']['CN'] ?? 'Lab root CA');
        $caFound = true;
    }
}
if (!$caFound) {
    fwrite(STDERR, "no CA with refid '$caRef' (caref of the web GUI certificate) in config.xml\n");
    exit(1);
}

write_config('DeployableServer: web GUI certificate renewed (scripts/New-LabFirewall.ps1)');
echo "web GUI certificate replaced\n";
