# ansible-matrix - a Matrix run (matrix-prepare.yml, MDAD): the Matrix secrets (write-once), the
# client secret Keycloak created for MAS (read only), password generation.
path "lab/data/matrix/*"       { capabilities = ["create", "read"] }
path "lab/metadata/matrix/*"   { capabilities = ["read"] }
path "lab/data/keycloak/clients/matrix-authentication-service" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-64/generate" { capabilities = ["read"] }

# ACME external account binding (eab_policy always-required, vars/openbao-config.yml): a binding
# key for Traefik's next ACME account, minted only when Traefik needs one (matrix-prepare.yml), and
# the replaced key of an earlier attempt that Traefik never used deleted again. Keys are single-use;
# a key that was used is gone already.
path "pki_int/roles/acme-matrix/acme/new-eab" { capabilities = ["update"] }
path "pki_int/eab/*"                          { capabilities = ["delete"] }
