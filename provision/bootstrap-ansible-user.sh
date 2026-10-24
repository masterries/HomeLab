#!/usr/bin/env bash
# bootstrap-ansible-user.sh - creates the user "ansible" on a lab VM; Ansible works through it.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (ansible-control, matrix, keycloak, vault), as root. (The firewall's
#   user "ansible" is defined in opnsense/config.xml.template instead.) Vagrant's shell
#   provisioner "ansible-user" (vagrant/Vagrantfile) uploads and runs it with sudo; no arguments.
#
# ITS PLACE IN THE ARCHITECTURE
#   Vagrant uses its own account "vagrant" only to create and provision the VMs. Everything
#   else (Ansible from ansible-control, your SSH logins via lab.ps1 connect, the jump through
#   the firewall) uses the dedicated account "ansible". Keeping the automation account separate
#   from the tool that built the machine is how real servers are set up: the account exists
#   the same way no matter how the server was created.
#
# HOW "ansible" LOGS IN
#   Only with an SSH certificate from one of the lab's SSH CAs (provision/harden-ssh.sh, the next
#   provisioner, installs the CAs and the allowed principals). So ansible has no authorized_keys
#   at all: this script removes the file, also when an old disk or checkpoint brings one back
#   (earlier versions put a shared key there). A plain key in it would never expire, ignore the
#   principals and source addresses of the certificates, and survive removing a CA.
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
# rewritten, and authorized_keys is removed if it exists.
set -euo pipefail

ANSIBLE_USER=ansible

# The login shell becomes zsh later (ansible/playbooks/base.yml); bash is only the starting point.
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

# ~/.ssh with owner and mode set explicitly (0700): ssh refuses keys in a folder that others can
# write to, and on ansible-control this folder holds its own key (bootstrap-ansible-control.sh).
home_dir="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
ssh_dir="$home_dir/.ssh"
auth_file="$ssh_dir/authorized_keys"
install -d -m 0700 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$ssh_dir"

# Certificates only: no plain keys for ansible (see HOW "ansible" LOGS IN).
rm -f "$auth_file"

echo "User $ANSIBLE_USER is set up (no authorized_keys; logins use SSH certificates)."
