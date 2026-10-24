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
#   (vagrant/Vagrantfile); no arguments. It runs after bootstrap-ansible-user.sh (shared
#   provisioners run before machine-specific ones), so the user "ansible" and its ~/.ssh exist.
#   It expects the private lab key, which the file provisioner "lab-key" uploads to
#   $STAGING_DIR just before.
#
# RESULT
#   - lab key as ~ansible/.ssh/id_ed25519, so Ansible can reach the other VMs as "ansible"
#     LAB-ONLY SHORTCUT: the same passphrase-less key is used by your PC and by Ansible. In an
#     enterprise the automation system has its own credentials, stored in a secrets manager or
#     issued as short-lived SSH certificates.
#   - Ansible, a pinned version (ANSIBLE_VERSION below) from PyPI, via pipx, installed globally
#     to /usr/local/bin. It includes the Ansible collections the playbooks use
#     (community.general, community.crypto, community.docker, ...).
#   - git (scripts/Update-LabMdad.ps1 fetches a new version of matrix-docker-ansible-deploy with
#     it; the deployments themselves take MDAD from the repository, vendor/mdad)
# The Ansible project itself lives in the repository under ansible/ (infrastructure as code:
# the repository is the source of truth) and is copied to ~ansible/lab on every run of
# scripts/Invoke-LabPlaybook.ps1.
#
# IDEMPOTENT: safe to run any number of times. apt-get install is harmless for packages that
# are already installed, an uploaded key overwrites the old one, and Ansible is installed only if
# pipx does not list it yet (an existing installation is not changed).
#
# Why a pinned version: the same code on every rebuild of ansible-control. An upgrade is a
# deliberate change of ANSIBLE_VERSION, then, on the existing VM:
#   sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force --include-deps ansible==<version>
set -euo pipefail

ANSIBLE_USER=ansible
# The Ansible package (collections bundle) version; ansible 14.5.0 brings ansible-core 2.21.5.
ANSIBLE_VERSION=14.5.0
STAGING_DIR=/home/vagrant/ansible-keys
PRIVATE_KEY="$STAGING_DIR/ansible_ed25519"

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

echo "== SSH key =="
ssh_dir="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)/.ssh"
if [[ -f "$PRIVATE_KEY" ]]; then
  # A private key must be readable only by its owner, or ssh refuses to use it.
  install -m 0600 -o "$ANSIBLE_USER" -g "$ANSIBLE_USER" "$PRIVATE_KEY" "$ssh_dir/id_ed25519"
  # Do not leave a copy of the private key in the vagrant user's home.
  rm -f "$PRIVATE_KEY"
  rmdir --ignore-fail-on-non-empty "$STAGING_DIR"
elif [[ ! -f "$ssh_dir/id_ed25519" ]]; then
  echo "ERROR: No private key uploaded. Run scripts/New-LabSshKey.ps1 on the host first." >&2
  exit 1
fi

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
