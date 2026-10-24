#!/usr/bin/env bash
# harden-ssh.sh - gives each lab VM its own SSH host keys and allows key-based SSH logins only.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (ansible-control, matrix, keycloak), as root, through Vagrant's shell
#   provisioner "ssh-hardening" (vagrant/Vagrantfile); no arguments. (The OPNsense firewall
#   is not made from the box; it generates its own host keys and its sshd accepts keys only,
#   see opnsense/config.xml.template.) Apply it with .\scripts\Initialize-Lab.ps1 rather
#   than a bare "vagrant provision": Initialize-Lab.ps1 first throws away keys\known_hosts on
#   the PC, so the new host keys are learned cleanly.
#
# WHY: UNIQUE HOST KEYS
#   An SSH host key is the server's identity: on the first connection the client stores it
#   (known_hosts, "trust on first use"), and later connections are only accepted if the server
#   proves it still holds the same key. That protects against someone impersonating the server
#   (man in the middle). The Vagrant box ships with host keys that were generated once when the
#   box was built, so every VM made from it had the SAME keys -- and anyone who downloads the
#   public box has them too. Host key checking could then neither tell the lab VMs apart nor
#   detect an impostor. This script deletes the box's keys and generates new ones, once per VM
#   (a marker file prevents regenerating them on every run, which would change the identity
#   each time). Enterprise equivalent: images are "generalised" (sysprep on Windows, cloud-init
#   or virt-sysprep on Linux) so that every instance creates its own keys on first boot; some
#   environments also sign host keys with an SSH certificate authority.
#
# WHY: KEY-ONLY LOGINS
#   The box also ships the well-known user/password "vagrant"/"vagrant", and that user has
#   passwordless sudo. With password logins enabled, anything that can reach a VM's SSH port
#   could become root with a password that is printed in every Vagrant tutorial. Logins with a
#   key (Vagrant's own per-VM key, the lab key for user "ansible") are not affected. The console
#   in Hyper-V Manager is not affected either: it is a local login, not SSH.
#   The setting lives in a drop-in file. sshd reads /etc/ssh/sshd_config.d/*.conf at the top
#   of its configuration in name order and keeps the FIRST value it sees for each option, so
#   "10-lab-hardening.conf" wins over the box's "50-cloud-init.conf" (which enables passwords).
#
# IDEMPOTENT: host keys are regenerated only once; the drop-in is rewritten only when its
# content changes; sshd is reloaded only when something changed.
set -euo pipefail

MARKER=/etc/ssh/.lab-host-keys-regenerated
DROPIN=/etc/ssh/sshd_config.d/10-lab-hardening.conf
changed=""

echo "== SSH host keys =="
if [[ ! -f "$MARKER" ]]; then
  rm -f /etc/ssh/ssh_host_*
  # -A creates every missing default host key type (rsa, ecdsa, ed25519).
  ssh-keygen -A
  touch "$MARKER"
  changed=1
  echo "New host keys generated for $(hostname)."
fi

echo "== Key-only SSH logins =="
dropin_tmp="$(mktemp)"
cat > "$dropin_tmp" <<'EOF'
# Managed by provision/harden-ssh.sh: SSH logins with keys only, no passwords.
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
if ! cmp -s "$dropin_tmp" "$DROPIN"; then
  install -m 0644 "$dropin_tmp" "$DROPIN"
  changed=1
fi
rm -f "$dropin_tmp"

# Check the complete configuration before touching the running daemon: a broken sshd config
# would lock everyone out of the VM except the console.
sshd -t
if [[ -n "$changed" ]]; then
  # A reload makes sshd re-read its configuration and host keys. Existing sessions (including
  # the one Vagrant is using right now) keep running.
  systemctl reload-or-restart ssh
fi
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication) '
