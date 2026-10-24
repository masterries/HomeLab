#!/usr/bin/env bash
# ansible/tests/run-token-check.sh -- run on ansible-control by tests/Test-LabRunToken.ps1,
# through bin/openbao-run: reports what the run token in VAULT_TOKEN may do, without the token.
#
# Output, one "key=value" per line:
#   token_present, policies, ttl, bound_cidrs, orphan, display_name, accessor   (lookup-self)
#   local_temp_on_tmpfs                     ANSIBLE_LOCAL_TEMP is on a RAM file system
#   local_temp                              its path (the test checks it is gone afterwards)
set -euo pipefail

test -n "${VAULT_TOKEN:-}" && echo "token_present=yes" || echo "token_present=no"
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" \
  | curl -sS --cacert "$VAULT_CACERT" -H @- "$VAULT_ADDR/v1/auth/token/lookup-self" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print("policies=" + ",".join(sorted(d["policies"])))
print("ttl=%d" % d["ttl"])
print("bound_cidrs=" + ",".join(d.get("bound_cidrs") or []))
print("orphan=%s" % d["orphan"])
print("display_name=" + d["display_name"])
print("accessor=" + d["accessor"])
'
fs_type="$(stat -f -c %T "${ANSIBLE_LOCAL_TEMP:-/nonexistent}" 2>/dev/null || echo none)"
echo "local_temp_on_tmpfs=$([ "$fs_type" = tmpfs ] && echo yes || echo "no ($fs_type)")"
# The folder of THIS run (other runs may have their own at the same time).
echo "local_temp=${ANSIBLE_LOCAL_TEMP:-}"
