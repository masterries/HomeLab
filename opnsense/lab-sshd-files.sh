#!/bin/sh
# opnsense/lab-sshd-files.sh -- installs the firewall's SSH host certificate and the lab's sshd
# drop-in, but only if the complete sshd configuration still passes "sshd -t" afterwards
#
# Where it runs:
#   On the firewall, as root, started over SSH by scripts/commands/firewall.ps1 (Update-FirewallSsh);
#   it is copied to a private /tmp folder together with the two files and deleted afterwards:
#     sh lab-sshd-files.sh <host certificate> <drop-in>
#   Prints "changed" when a file was replaced; the caller then restarts sshd
#   (configctl openssh restart; running sessions survive, OpenSSH 10 runs each session in its own
#   sshd-session process).
#
# Why the check: the firewall is the only way into the lab. A drop-in that sshd cannot parse
# would stop sshd at its next start, and the lab would be reachable only through the firewall's
# console. So the previous files are kept until "sshd -t" has accepted the new ones, and put back
# if it does not.
set -eu

CERT_TARGET=/conf/sshd/ssh_host_ed25519_key-cert.pub
DROPIN_TARGET=/usr/local/etc/ssh/sshd_config.d/20-lab-ssh.conf
changed=0

for pair in "$1:$CERT_TARGET" "$2:$DROPIN_TARGET"; do
    source_file="${pair%%:*}"
    target="${pair#*:}"
    rm -f "$target.lab-previous" "$target.lab-new"
    if ! cmp -s "$source_file" "$target"; then
        # Remember the old file (or that there was none) for the way back.
        if [ -f "$target" ]; then cp -p "$target" "$target.lab-previous"; else touch "$target.lab-new"; fi
        install -m 0644 -o root -g wheel "$source_file" "$target"
        changed=1
    fi
done

if ! /usr/local/sbin/sshd -t -f /usr/local/etc/ssh/sshd_config; then
    for target in "$CERT_TARGET" "$DROPIN_TARGET"; do
        if [ -f "$target.lab-previous" ]; then mv -f "$target.lab-previous" "$target"; fi
        if [ -f "$target.lab-new" ]; then rm -f "$target" "$target.lab-new"; fi
    done
    echo "sshd -t rejected the new files; the previous ones are back in place." >&2
    exit 1
fi
rm -f "$CERT_TARGET.lab-previous" "$CERT_TARGET.lab-new" "$DROPIN_TARGET.lab-previous" "$DROPIN_TARGET.lab-new"
if [ "$changed" = 1 ]; then echo changed; fi
