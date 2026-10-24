# ansible-keycloak - a run of playbooks/keycloak.yml: Keycloak's secrets (write-once: "create"
# without "update" adds a missing secret but never changes one), password generation, and
# certificates of the PKI role keycloak.
path "lab/data/keycloak/*"     { capabilities = ["create", "read"] }
path "lab/metadata/keycloak/*" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-24/generate" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-48/generate" { capabilities = ["read"] }
path "pki_int/sign/keycloak"   { capabilities = ["create", "update"] }
