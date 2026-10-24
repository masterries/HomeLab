#!/usr/bin/env bash
# bootstrap-ansible-control.sh - turns the VM into the Ansible control node of the lab.
#
# WHAT A CONTROL NODE IS
#   Ansible is agentless: one machine, the control node, holds the playbooks and connects to
#   the managed machines over SSH to configure them. In this lab every deployment runs from
#   ansible-control, never from your Windows PC. Enterprises do the same with a dedicated
#   automation host, a CI/CD runner, or AWX / Ansible Automation Platform.
#
# WHERE AND HOW IT RUNS
#   Only on ansible-control, as root, through Vagrant's shell provisioner "ansible-control"
#   (vagrant/Vagrantfile); no arguments. It runs after bootstrap-ansible-user.sh and
#   harden-ssh.sh (shared provisioners run before machine-specific ones), so the user "ansible"
#   and its ~/.ssh exist. It expects the PC's keys\ssh\known_hosts and revoked_host_keys, which
#   the file provisioner "lab-ssh-known-hosts" uploads to $STAGING_DIR just before.
#
# RESULT
#   - ansible-control's OWN SSH key, ~ansible/.ssh/id_ed25519, made here once; it never leaves
#     the VM. Before every Ansible run the PC signs a certificate for it
#     (~ansible/.ssh/id_ed25519-cert.pub, valid 2 hours, only for the hosts of that run;
#     Get-LabControlCertificateCommand in scripts/lib/LabSsh.ps1), and the run deletes it at the end.
#     Without a certificate the key opens nothing. Enterprise equivalent: a CI runner or AWX
#     gets short-lived SSH certificates from Vault/OpenBao per job.
#   - Host key checking for every *.lab.internal machine against the lab's SSH CAs
#     (/etc/ssh/ssh_known_hosts with "@cert-authority" lines, /etc/ssh/ssh_config.d/20-lab.conf):
#     a machine without a valid host certificate is refused. This applies to the lab's own
#     playbooks and to matrix-docker-ansible-deploy alike (ssh reads it, whatever ansible.cfg says).
#   - Ansible, a pinned version (ANSIBLE_VERSION below) from PyPI, via pipx, installed globally
#     to /usr/local/bin. It includes the Ansible collections the playbooks use
#     (community.general, community.crypto, community.docker, ...).
#   - git (scripts/dev/Update-LabMdad.ps1 fetches a new version of matrix-docker-ansible-deploy with
#     it; the deployments themselves take MDAD from the repository, vendor/mdad)
# The Ansible project itself lives in the repository under ansible/ (infrastructure as code:
# the repository is the source of truth) and is copied to ~ansible/lab on every run of
# scripts/lib/LabRun.ps1.
#
# IDEMPOTENT: safe to run any number of times. apt-get install is harmless for packages that
# are already installed, the key is made only once (marker file), the SSH files are rewritten,
# and Ansible is installed only if pipx does not list it yet (an existing installation is not
# changed).
#
# Why a pinned version: the same code on every rebuild of ansible-control. An upgrade is a
# deliberate change of ANSIBLE_VERSION, then, on the existing VM:
#   sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force --include-deps ansible==<version>
set -euo pipefail

ANSIBLE_USER=ansible
# The Ansible package (collections bundle) version; ansible 14.5.0 brings ansible-core 2.21.5.
ANSIBLE_VERSION=14.5.0
STAGING_DIR=/home/vagrant/lab-ssh

# No interactive questions from apt/dpkg (there is no terminal during provisioning).
export DEBIAN_FRONTEND=noninteractive
# pipx installs every application into its own Python virtual environment, so Ansible and its
# dependencies do not mix with the Python packages of the operating system (Ubuntu 24.04 does
# not allow "pip install" into the system Python anyway). The pipx 1.4.3 shipped with Ubuntu
# 24.04 has no --global option; these variables give the same effect: environments under
# /opt/pipx and commands in /usr/local/bin, which is in every user's PATH.
export PIPX_HOME=/opt/pipx
export PIPX_BIN_DIR=/usr/local/bin
export PIPX_MAN_DIR=/usr/local/share/man

echo "== Packages =="
# python3-venv: pipx needs it to create the virtual environments.
apt-get update -qq
apt-get install -y -qq git pipx python3-venv >/dev/null

echo "== SSH key of ansible-control =="
home_dir="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
ssh_dir="$home_dir/.ssh"
own_key_marker="$ssh_dir/.lab-own-key"
if [[ ! -f "$own_key_marker" ]]; then
  # Once: replace whatever key is there (earlier versions installed the PC's shared lab key here)
  # with a new key of ansible-control's own, and forget the host keys that ssh learned without
  # checking them (/etc/ssh/ssh_known_hosts below replaces them).
  rm -f "$ssh_dir/id_ed25519" "$ssh_dir/id_ed25519.pub" "$ssh_dir/id_ed25519-cert.pub" "$ssh_dir/known_hosts" "$ssh_dir/known_hosts.old"
  sudo -u "$ANSIBLE_USER" ssh-keygen -q -t ed25519 -N '' -C "$ANSIBLE_USER@ansible-control" -f "$ssh_dir/id_ed25519"
  sudo -u "$ANSIBLE_USER" touch "$own_key_marker"
  echo "New SSH key for ansible-control."
fi
ssh-keygen -lf "$ssh_dir/id_ed25519.pub"

echo "== SSH host key checking =="
# known_hosts: "@cert-authority <the lab's host names> <CA>" lines, rendered on the PC. The
# revocation list names host keys that must not be accepted any more (rebuilt machines).
for file in known_hosts:/etc/ssh/ssh_known_hosts revoked_host_keys:/etc/ssh/lab_revoked_host_keys; do
  source_file="$STAGING_DIR/${file%%:*}"
  target="${file#*:}"
  if [[ -f "$source_file" ]]; then
    install -m 0644 -o root -g root "$source_file" "$target"
    rm -f "$source_file"
  elif [[ ! -f "$target" ]]; then
    echo "ERROR: ${file%%:*} was not uploaded. Run .\lab.ps1 up on the host." >&2
    exit 1
  fi
done
rmdir --ignore-fail-on-non-empty "$STAGING_DIR" 2>/dev/null || true
# Ubuntu's /etc/ssh/ssh_config includes ssh_config.d/*.conf at its top, and ssh keeps the first
# value it finds, so these win for every lab machine:
#   HostKeyAlgorithms   only certified ed25519 host keys (a plain key is never asked for)
#   UserKnownHostsFile  /dev/null: nothing learned "on first use" counts or is stored
#   RevokedHostKeys     keys of rebuilt machines are refused even with a certificate
cat > /etc/ssh/ssh_config.d/20-lab.conf.tmp <<'EOF'
# Managed by provision/bootstrap-ansible-control.sh: lab hosts only with an SSH host certificate.
Host *.lab.internal
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com
    StrictHostKeyChecking yes
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /etc/ssh/ssh_known_hosts
    RevokedHostKeys /etc/ssh/lab_revoked_host_keys
    CheckHostIP no
    UpdateHostKeys no
EOF
install -m 0644 -o root -g root /etc/ssh/ssh_config.d/20-lab.conf.tmp /etc/ssh/ssh_config.d/20-lab.conf
rm -f /etc/ssh/ssh_config.d/20-lab.conf.tmp

echo "== Ansible =="
# "|| true": if pipx list fails, treat it as "nothing installed" instead of aborting (set -e).
installed_apps="$(pipx list --short 2>/dev/null || true)"
if ! grep -q '^ansible ' <<<"$installed_apps"; then
  # The package "ansible" is a collection bundle; the commands (ansible, ansible-playbook, ...)
  # come from its dependency ansible-core, which pipx only exposes with --include-deps.
  pipx install --include-deps "ansible==$ANSIBLE_VERSION"
fi
# Print the first line (the version) as a quick check that the command works.
ansible --version | sed -n 1p
