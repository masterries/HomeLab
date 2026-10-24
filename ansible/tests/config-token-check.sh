#!/usr/bin/env bash
# ansible/tests/config-token-check.sh -- run on ansible-control by tests/Test-LabOpenBaoConfig.ps1,
# through bin/openbao-run with a token of the role ansible-config: reports what that token may
# do, without the token.
#
# It only ASKS OpenBao (sys/capabilities-self, allowed for every token by the default policy):
# "which capabilities would this token have on these paths?" - nothing is tried, so a policy that
# allowed too much could not do harm during the test.
#
# Output, one "key=value" per line:
#   token_present, policies, ttl, bound_cidrs, orphan, accessor   (lookup-self)
#   cap:<path>=<capabilities, comma-separated; "deny" = none>      for each path below
set -euo pipefail

paths=(
  # The configuration plane: what the token is for.
  sys/mounts
  sys/mounts/pki_int/tune
  lab/config
  sys/policies/password/lab-alnum-24
  pki_int/config/crl
  pki_int/config/acme
  pki_int/roles/keycloak
  # The identity plane and everything else: must all be "deny".
  sys/policies/acl/openbao-config
  sys/auth/approle
  auth/approle/role/pc-admin/secret-id
  auth/token/roles/ansible-config
  auth/token/create
  auth/token/create/ansible-run
  sys/mounts/ssh
  ssh/config/ca
  ssh/sign/pc
  pki_int/config/issuers
  pki_int/intermediate/set-signed
  pki_int/issue/keycloak
  pki_int/sign/keycloak
  lab/data/keycloak/admin
  sys/storage/raft/snapshot
  sys/audit
)

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
print("accessor=" + d["accessor"])
'
body="$(python3 -c 'import json, sys; print(json.dumps({"paths": sys.argv[1:]}))' "${paths[@]}")"
{ printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN"; printf 'Content-Type: application/json\n'; } \
  | curl -sS --cacert "$VAULT_CACERT" -H @- -X POST --data "$body" "$VAULT_ADDR/v1/sys/capabilities-self" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d.get("data", d)
for path in sys.argv[1:]:
    print("cap:%s=%s" % (path, ",".join(sorted(d.get(path, ["deny"])))))
' "${paths[@]}"
