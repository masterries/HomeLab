#!/usr/bin/env bash
# ansible/tests/ssh-cert-check.sh - SSH checks that tests\Test-LabSshCertificates.ps1 runs ON
# ansible-control (as user ansible), so they use ansible-control's ssh client and its host key
# checking (/etc/ssh/ssh_config.d/20-lab.conf). Prints one line per check: "<name> <host> <exit code>".
#
#   ssh-cert-check.sh scope <host> ...       logins with ~/.ssh/id_ed25519 and the certificate the
#                                            test installed next to it
#   ssh-cert-check.sh plainhost <host> ...   the same, but asking for a PLAIN host key (no
#                                            certificate): must fail, nothing trusts plain keys
#   ssh-cert-check.sh key <key file> <host>  a login with another key and its certificate
set -u

try_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=QUIET "$@" true >/dev/null 2>&1
  echo $?
}

mode="$1"
shift
case "$mode" in
  scope)
    for host in "$@"; do echo "scope $host $(try_ssh "$host")"; done ;;
  plainhost)
    for host in "$@"; do echo "plainhost $host $(try_ssh -o HostKeyAlgorithms=ssh-ed25519 "$host")"; done ;;
  key)
    echo "key $2 $(try_ssh -i "$1" -o IdentitiesOnly=yes -o CertificateFile="$1-cert.pub" "$2")" ;;
  *)
    echo "usage: $0 scope|plainhost|key ..." >&2
    exit 2 ;;
esac
