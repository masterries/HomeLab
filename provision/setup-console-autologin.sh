#!/usr/bin/env bash
# setup-console-autologin.sh - logs USER in automatically on the console (tty1), so "Connect"
# in Hyper-V Manager shows a shell right away instead of a login prompt.
#
# WHERE AND HOW IT RUNS
#   On the Ubuntu lab VMs (ansible-control, matrix, keycloak), as root, through Vagrant's shell
#   provisioner "console-autologin" (vagrant/Vagrantfile passes "ansible"). Can also be run
#   by hand:
#     setup-console-autologin.sh USER
#
# HOW IT WORKS
#   The console login prompt on tty1 is the systemd service getty@tty1.service, which runs
#   agetty. Instead of editing the unit file shipped by the package, the script adds a
#   "drop-in" (/etc/systemd/system/getty@tty1.service.d/autologin.conf). systemd merges
#   drop-ins with the original unit; they survive package updates and can simply be deleted
#   to undo the change. Changing service settings through drop-ins is standard practice.
#
# IDEMPOTENT: safe to run any number of times. The drop-in is only written, and the console
# only restarted, when its content would change.
#
# LAB-ONLY SHORTCUT: whoever can open the VM console (an administrator on the Windows host)
# gets a shell without a password, and for the user ansible that means root through
# passwordless sudo. SSH is not affected and still needs the key. In an enterprise, console
# access (hypervisor console, iLO/iDRAC/IPMI) requires authentication, ideally with MFA, is
# logged, and an emergency ("break-glass") account has a password kept in a vault.
#
# "--remove" undoes it (the normal login prompt comes back). The Vagrantfile uses it for VMs
# with "consoleAutologin": false in config/lab.json, such as vault: whoever opens the console
# of the unsealed OpenBao VM should not get a root shell for free.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 USER | --remove" >&2
  exit 1
fi

dropin_dir=/etc/systemd/system/getty@tty1.service.d
dropin="$dropin_dir/autologin.conf"

if [[ "$1" == "--remove" ]]; then
  if [[ -f "$dropin" ]]; then
    rm -f "$dropin"
    systemctl daemon-reload
    systemctl restart getty@tty1.service
    echo "Console autologin removed."
  else
    echo "No console autologin set up; nothing to remove."
  fi
  exit 0
fi

user="$1"
if ! id "$user" >/dev/null 2>&1; then
  echo "ERROR: User $user does not exist." >&2
  exit 1
fi
dropin_tmp="$(mktemp)"
# Same as the Ubuntu default (see: systemctl cat getty@tty1.service), plus --autologin and
# login's -f option (the user counts as already authenticated). agetty adds -f by itself for
# --autologin only when no -o is given; with -o the login options must contain it.
# The empty "ExecStart=" first clears the ExecStart of the original unit; without it systemd
# would see two commands and refuse to start the service.
# Escaping, layer by layer: this heredoc is unquoted, so bash expands ${user} now, turns
# "\\\\u" into "\\u" and "\$TERM" into "$TERM". systemd then turns "\\u" into "\u" and
# expands $TERM when it starts the service, and agetty replaces "\u" with the user name.
cat > "$dropin_tmp" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\\\u' --noclear --autologin ${user} - \$TERM
EOF

install -d -m 0755 "$dropin_dir"
if cmp -s "$dropin_tmp" "$dropin"; then
  echo "Console autologin for $user is already set up."
else
  install -m 0644 "$dropin_tmp" "$dropin"
  # Make systemd read the changed unit configuration.
  systemctl daemon-reload
  # Restarts the console; a session open there is ended.
  systemctl restart getty@tty1.service
  echo "Console autologin for $user set up."
fi
rm -f "$dropin_tmp"
