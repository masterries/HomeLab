#!/usr/bin/env bash
# harden-ssh.sh - SSH on a lab VM: its own host keys, published to the PC through Hyper-V, trust
# in the lab's SSH certificate authorities, and logins with certificates only.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (every VM of config/lab.json), as root, through Vagrant's shell
#   provisioner "ssh-hardening" (vagrant/Vagrantfile):
#     harden-ssh.sh <firewall address in the VM's network> <ansible-control address>
#   The first address is the firewall's LAN address (10.10.10.1) for VMs on LabNet, its segment
#   address (10.10.20.1 on LabK8s) for VMs in a segment: the jump host connects from there.
#   It expects keys\ssh\lab_user_ca.pub from the PC, which the file provisioner "lab-ssh-ca"
#   uploads to $STAGING just before (or an earlier run's copy in /etc/ssh). (The OPNsense
#   firewall is not made from the box; lab.ps1 firewall sets up its SSH.)
#
# WHY: UNIQUE HOST KEYS
#   An SSH host key is the server's identity. The Vagrant box ships with host keys that were
#   generated once when the box was built, so every VM made from it had the SAME keys -- and
#   anyone who downloads the public box has them too. This script deletes the box's keys and
#   generates new ones, once per VM (a marker file prevents regenerating them on every run, which
#   would change the identity each time). Enterprise equivalent: images are "generalised"
#   (sysprep on Windows, cloud-init or virt-sysprep on Linux) so that every instance creates its
#   own keys on first boot.
#
# WHY: THE HOST KEY GOES TO THE PC THROUGH HYPER-V (KVP), NOT OVER THE NETWORK
#   The PC signs a host certificate for this key (scripts\lib\LabSsh.ps1), and clients then trust the
#   VM because of that certificate. So the PC must be sure the key really belongs to this VM. Over
#   the network it cannot be: another machine on LabNet could answer in this VM's place. Hyper-V
#   has a channel per VM instead, KVP ("key-value pair exchange", part of the Hyper-V integration
#   services; the daemon hv-kvp-daemon runs in every Ubuntu VM on Hyper-V): items that root
#   writes into /var/lib/hyperv/.kvp_pool_1 appear on the host as "guest exchange items" of
#   exactly this VM. The item is written only after the new host keys exist, never for the box's
#   shared keys. Enterprise equivalent: clouds print the host key fingerprints to the instance's
#   serial console (AWS "get-console-output"), or register them through an attested agent.
#
# WHY: CERTIFICATES ONLY
#   - TrustedUserCAKeys: a login as "ansible" needs a certificate signed by one of the lab's SSH
#     CAs (the offline CA on the PC, OpenBao's CA), not an entry in authorized_keys.
#   - AuthorizedPrincipalsFile: which certificates may log in as which user. Principals are roles:
#     /etc/ssh/lab_principals/ansible lists "lab-all" and "host-<this VM>"; an Ansible run for
#     matrix gets a certificate for host-matrix only and cannot log in anywhere else. There is no
#     file for root or vagrant, so no certificate logs in as them.
#   - HostCertificate: the VM presents its certificate, clients check it against the lab CAs.
#     (Installed later by the PC; until then sshd logs that the file is missing and carries on.)
#   - Passwords off: the box ships the well-known user/password "vagrant"/"vagrant" with
#     passwordless sudo.
#   - AllowUsers: ansible only from the firewall's address in this VM's network (every login from
#     the PC arrives through the jump host) and from ansible-control; Vagrant's own user "vagrant" (it keeps its
#     per-VM key from Vagrant) only through the jump host. No lateral SSH from one lab VM to
#     another.
#   - No forwarding of any kind on the VMs: only the firewall, as jump host, forwards.
#   The settings live in a drop-in file. sshd reads /etc/ssh/sshd_config.d/*.conf at the top of
#   its configuration in name order and keeps the FIRST value it sees for each option, so
#   "10-lab-hardening.conf" wins over the box's "50-cloud-init.conf" (which enables passwords).
#   Only global options, no "Match" block: a Match in an included file would swallow the rest of
#   the main configuration.
#
# IDEMPOTENT: host keys are regenerated only once; files are rewritten only when their content
# changes; sshd is reloaded only when something changed.
set -euo pipefail

FIREWALL_IP="${1:?usage: harden-ssh.sh <firewall address in this network> <ansible-control address>}"
CONTROL_IP="${2:?usage: harden-ssh.sh <firewall address in this network> <ansible-control address>}"
STAGING=/home/vagrant/lab-ssh
MARKER=/etc/ssh/.lab-host-keys-regenerated
DROPIN=/etc/ssh/sshd_config.d/10-lab-hardening.conf
USER_CA=/etc/ssh/lab_user_ca.pub
PRINCIPALS_DIR=/etc/ssh/lab_principals
changed=""

# Installs $1 as $2 (root:root 0644) when the content differs; marks the run as changed.
install_if_changed() {
  if ! cmp -s "$1" "$2"; then
    install -m 0644 -o root -g root "$1" "$2"
    changed=1
  fi
}

echo "== SSH host keys =="
if [[ ! -f "$MARKER" ]]; then
  rm -f /etc/ssh/ssh_host_*
  # -A creates every missing default host key type (rsa, ecdsa, ed25519).
  ssh-keygen -A
  touch "$MARKER"
  changed=1
  echo "New host keys generated for $(hostname)."
fi

echo "== Host key for the PC (Hyper-V KVP) =="
if ! systemctl is-active --quiet hv-kvp-daemon.service; then
  echo "ERROR: hv-kvp-daemon is not running; the PC cannot learn this VM's host key." >&2
  exit 1
fi
# The pool file is a sequence of fixed-size records: a 512-byte key and a 2048-byte value, both
# padded with NUL bytes (the format of hv_kvp_daemon, linux/tools/hv). The record is replaced
# under the same file lock the daemon uses (fcntl), keeping every other record.
python3 - "$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" <<'PY'
import fcntl, os, sys
KEY, KEY_SIZE, VALUE_SIZE = b'LabSshHostKeyEd25519', 512, 2048
value = sys.argv[1].encode()
record = KEY.ljust(KEY_SIZE, b'\0') + value.ljust(VALUE_SIZE, b'\0')
size = KEY_SIZE + VALUE_SIZE
fd = os.open('/var/lib/hyperv/.kvp_pool_1', os.O_RDWR | os.O_CREAT, 0o644)
with os.fdopen(fd, 'r+b') as pool:
    fcntl.lockf(pool, fcntl.LOCK_EX)
    data = pool.read()
    records = [data[i:i + size] for i in range(0, len(data) - len(data) % size, size)]
    kept = [r for r in records if r[:KEY_SIZE].rstrip(b'\0') != KEY]
    if record not in records or len(kept) != len(records) - 1:
        pool.seek(0)
        pool.truncate()
        pool.write(b''.join(kept) + record)
        pool.flush()
    fcntl.lockf(pool, fcntl.LOCK_UN)
PY
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

echo "== Trusted SSH certificate authorities =="
if [[ -f "$STAGING/lab_user_ca.pub" ]]; then
  install_if_changed "$STAGING/lab_user_ca.pub" "$USER_CA"
  rm -f "$STAGING/lab_user_ca.pub"
  rmdir --ignore-fail-on-non-empty "$STAGING"
elif [[ ! -s "$USER_CA" ]]; then
  echo "ERROR: no lab_user_ca.pub uploaded. Run .\\lab.ps1 up on the host (it creates keys\\ssh)." >&2
  exit 1
fi
install -d -m 0755 -o root -g root "$PRINCIPALS_DIR"
principals_tmp="$(mktemp)"
printf 'lab-all\nhost-%s\n' "$(hostname -s)" > "$principals_tmp"
install_if_changed "$principals_tmp" "$PRINCIPALS_DIR/ansible"
rm -f "$principals_tmp"
sed 's/^/  /' "$USER_CA"

echo "== Certificate-only SSH logins =="
dropin_tmp="$(mktemp)"
cat > "$dropin_tmp" <<EOF
# Managed by provision/harden-ssh.sh: certificate logins only, no passwords, no forwarding.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
TrustedUserCAKeys $USER_CA
AuthorizedPrincipalsFile $PRINCIPALS_DIR/%u
AllowUsers ansible@$FIREWALL_IP ansible@$CONTROL_IP vagrant@$FIREWALL_IP
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
X11Forwarding no
EOF
install_if_changed "$dropin_tmp" "$DROPIN"
rm -f "$dropin_tmp"

# Check the complete configuration before touching the running daemon: a broken sshd config
# would lock everyone out of the VM except the console. (On a VM that has no host certificate
# yet, sshd reports 'Could not load host certificate': expected, the PC installs it right after
# provisioning - scripts/lib/LabSsh.ps1, Update-LabVmHostCertificates.)
sshd -t
if [[ -n "$changed" ]]; then
  # A reload makes sshd re-read its configuration and host keys. Existing sessions (including
  # the one Vagrant is using right now) keep running.
  systemctl reload-or-restart ssh
fi
sshd -T | grep -E '^(passwordauthentication|permitrootlogin|trustedusercakeys|authorizedprincipalsfile|allowtcpforwarding|allowusers) '
