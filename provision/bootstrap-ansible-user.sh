#!/usr/bin/env bash
# bootstrap-ansible-user.sh - creates the user "ansible" on a lab VM; Ansible works through it.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (ansible-control, matrix, keycloak), as root. (The firewall's user
#   "ansible" is defined in opnsense/config.xml.template instead.) Vagrant's shell provisioner
#   "ansible-user" (vagrant/Vagrantfile) uploads and runs it with sudo; no arguments.
#   It expects the public lab key from scripts/New-LabSshKey.ps1, which the file provisioner
#   "lab-key-pub" uploads to $STAGING_DIR just before. The "vagrant" user cannot write to
#   another user's home directory, hence the detour through a staging folder.
#
# ITS PLACE IN THE ARCHITECTURE
#   Vagrant uses its own account "vagrant" only to create and provision the VMs. Everything
#   else (Ansible from ansible-control, your SSH logins via Connect-Lab.ps1, the jump through
#   the firewall) uses the dedicated account "ansible". Keeping the automation account separate
#   from the tool that built the machine is how real servers are set up: the account exists
#   the same way no matter how the server was created.
#
# RESULT
#   User "ansible" with passwordless sudo, login only with the lab key. useradd leaves the
#   password locked, so password logins are impossible; sudo works thanks to NOPASSWD.
#   LAB-ONLY SHORTCUT: passwordless sudo for everything. In an enterprise the automation
#   account usually needs a sudo password (kept in a vault, e.g. Ansible Vault or HashiCorp
#   Vault) or gets privileges just in time from a privileged-access system, sudo use is logged
#   centrally, and accounts come from a directory (LDAP/FreeIPA/Active Directory) instead of
#   being created locally on each machine.
#
# IDEMPOTENT: safe to run any number of times. An existing user is kept, the sudoers file is
# rewritten, and the lab key is replaced in authorized_keys instead of being added twice.
set -euo pipefail

ANSIBLE_USER=ansible
STAGING_DIR=/home/vagrant/ansible-keys
PUB_KEY="$STAGING_DIR/ansible_ed25519.pub"

# The login shell becomes zsh later (setup-zsh.sh); bash is only the starting point.
if ! id "$ANSIBLE_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ANSIBLE_USER"
fi
# sudo rule: write it to a temporary file and check its syntax with visudo before installing
# it. A syntax error in a file under /etc/sudoers.d can break sudo for every user, including
# Vagrant's own provisioning, which also runs through sudo.
# sudo also expects these files to be owned by root and not writable (mode 0440).
sudoers_tmp="$(mktemp)"
echo "$ANSIBLE_USER ALL=(ALL) NOPASSWD:ALL" > "$sudoers_tmp"
visudo -cqf "$sudoers_tmp"
install -m 0440 -o root -g root "$sudoers_tmp" "/etc/sudoers.d/90-$ANSIBLE_USER"
rm -f "$sudoers_tmp"

# SSH refuses keys whose ~/.ssh or authorized_keys are writable by others, so set owner and
# modes explicitly (0700 for the directory, 0600 for the file).
home_dir="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
ssh_dir="$home_dir/.ssh"
auth_file="$ssh_dir/authorized_keys"
install -d -m 0700 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$ssh_dir"

if [[ -f "$PUB_KEY" ]]; then
  # Replace the lab key in authorized_keys. It is recognised by its comment (the third field of
  # the .pub file, 'ansible@deployableserver-lab'), so after a key rotation
  # (New-LabSshKey.ps1 -Force) the old key is removed; other entries are left alone.
  key_comment="$(awk '{print $3}' "$PUB_KEY")"
  auth_tmp="$(mktemp)"
  if [[ -f "$auth_file" ]]; then
    # Keep every line whose last field is not the lab key's comment.
    awk -v c="$key_comment" '$NF != c' "$auth_file" > "$auth_tmp"
  fi
  cat "$PUB_KEY" >> "$auth_tmp"
  install -m 0600 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$auth_tmp" "$auth_file"
  # Remove the uploaded copy; the staging folder only if it is empty now.
  rm -f "$auth_tmp" "$PUB_KEY"
  rmdir --ignore-fail-on-non-empty "$STAGING_DIR"
elif [[ ! -s "$auth_file" ]]; then
  # No key uploaded and none installed earlier: nobody could log in as "ansible".
  echo "ERROR: No key uploaded. Run scripts/New-LabSshKey.ps1 on the host first." >&2
  exit 1
fi

echo "User $ANSIBLE_USER is set up."
