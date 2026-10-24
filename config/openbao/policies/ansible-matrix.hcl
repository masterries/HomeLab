# ansible-matrix - a Matrix run (matrix-prepare.yml, MDAD): the Matrix secrets (write-once), the
# client secret Keycloak created for MAS (read only), password generation.
path "lab/data/matrix/*"       { capabilities = ["create", "read"] }
path "lab/metadata/matrix/*"   { capabilities = ["read"] }
path "lab/data/keycloak/clients/matrix-authentication-service" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-64/generate" { capabilities = ["read"] }
