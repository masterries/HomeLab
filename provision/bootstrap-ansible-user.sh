#!/usr/bin/env bash
# bootstrap-ansible-user.sh - creates the user "ansible" on a lab VM; Ansible works through it.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (ansible-control, matrix, keycloak, vault), as root. (The firewall's
#   user "ansible" is defined in opnsense/config.xml.template instead.) Vagrant's shell
#   provisioner "ansible-user" (vagrant/Vagrantfile) uploads and runs it with sudo:
#     bootstrap-ansible-user.sh keep-lab-key | retire-lab-key
#   (TRANSITION: whether the PC still has the old lab key; the Vagrantfile decides.)
#
# ITS PLACE IN THE ARCHITECTURE
#   Vagrant uses its own account "vagrant" only to create and provision the VMs. Everything
#   else (Ansible from ansible-control, your SSH logins via Connect-Lab.ps1, the jump through
#   the firewall) uses the dedicated account "ansible". Keeping the automation account separate
#   from the tool that built the machine is how real servers are set up: the account exists
#   the same way no matter how the server was created.
#
# HOW "ansible" LOGS IN
#   With an SSH certificate from one of the lab's SSH CAs - not with a key in authorized_keys.
#   provision/harden-ssh.sh (the next provisioner) installs the CAs and the allowed principals.
#   This script only removes the OLD shared lab key ("ansible@deployableserver-lab") from
#   authorized_keys once it is retired; TRANSITION: while the PC still has keys\ansible_ed25519,
#   the provisioner "lab-key-pub" uploads its public key and it stays usable
#   (scripts\Complete-LabSshMigration.ps1 retires it).
#
# RESULT
#   User "ansible" with passwordless sudo. useradd leaves the password locked, so password
#   logins are impossible; sudo works thanks to NOPASSWD.
#   LAB-ONLY SHORTCUT: passwordless sudo for everything. In an enterprise the automation
#   account usually needs a sudo password (kept in a vault, e.g. Ansible Vault or HashiCorp
#   Vault) or gets privileges just in time from a privileged-access system, sudo use is logged
#   centrally, and accounts come from a directory (LDAP/FreeIPA/Active Directory) instead of
#   being created locally on each machine.
#
# IDEMPOTENT: safe to run any number of times. An existing user is kept, the sudoers file is
# rewritten, and authorized_keys only loses the old lab key's line.
set -euo pipefail

ANSIBLE_USER=ansible
STAGING_DIR=/home/vagrant/ansible-keys
PUB_KEY="$STAGING_DIR/ansible_ed25519.pub"
# The comment of the old shared lab key (scripts/New-LabSshKey.ps1 of earlier versions).
LAB_KEY_COMMENT=ansible@deployableserver-lab

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

# authorized_keys without the old lab key (recognised by its comment, the last field) once it is
# retired; while the transition lasts, the uploaded copy replaces it (or, when only this step is
# re-run without the upload, the file stays as it is). Other entries are left alone.
# The .pub file comes from Windows and may end with CR LF: the comment is compared without a
# trailing CR, and the copy is appended without it.
auth_tmp="$(mktemp)"
if [[ -f "$auth_file" ]]; then
  if [[ "${1:-retire-lab-key}" == retire-lab-key || -f "$PUB_KEY" ]]; then
    awk -v c="$LAB_KEY_COMMENT" '{ last = $NF; sub(/\r$/, "", last) } last != c' "$auth_file" > "$auth_tmp"
  else
    cat "$auth_file" > "$auth_tmp"
  fi
fi
if [[ -f "$PUB_KEY" ]]; then
  tr -d '\r' < "$PUB_KEY" >> "$auth_tmp"
  rm -f "$PUB_KEY"
  rmdir --ignore-fail-on-non-empty "$STAGING_DIR"
fi
if [[ -s "$auth_tmp" ]]; then
  install -m 0600 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$auth_tmp" "$auth_file"
else
  rm -f "$auth_file"
fi
rm -f "$auth_tmp"

echo "User $ANSIBLE_USER is set up ($(grep -c . "$auth_file" 2>/dev/null || echo 0) entries in authorized_keys; logins use SSH certificates)."
