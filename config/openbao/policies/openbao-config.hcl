# openbao-config - OpenBao's CONFIGURATION PLANE, applied by playbooks/openbao-config.yml on
# ansible-control with a token for one run (token role ansible-config, 30 minutes, minted only by
# pc-admin on the PC). It sets up the secrets engines and how they behave: the KV mount "lab", the
# password policies, the intermediate CA's mount, URLs, revocation list, tidying, its roles and ACME.
#
# What it can NOT do (the IDENTITY PLANE, which stays with the PC): write ACL policies, auth methods,
# AppRoles or token roles, touch the SSH CA, import or choose a CA (config/ca, config/issuers), issue
# or sign a certificate, read or write a secret (lab/data). So a stolen token of a run can change how
# certificates are issued, but cannot give anyone new rights.
# Enterprise equivalent: separation of duties - an IAM team owns identities and policies, a
# platform pipeline owns the configuration of the engines.
path "sys/mounts"                  { capabilities = ["read"] }
path "sys/mounts/lab"              { capabilities = ["create", "read", "update"] }
path "sys/mounts/lab/tune"         { capabilities = ["read", "update"] }
path "sys/mounts/pki_int"          { capabilities = ["create", "read", "update"] }
path "sys/mounts/pki_int/tune"     { capabilities = ["read", "update"] }
path "lab/config"                  { capabilities = ["create", "read", "update"] }
path "sys/policies/password/lab-*" { capabilities = ["create", "read", "update"] }
path "pki_int/config/cluster"      { capabilities = ["create", "read", "update"] }
path "pki_int/config/urls"         { capabilities = ["create", "read", "update"] }
path "pki_int/config/crl"          { capabilities = ["create", "read", "update"] }
path "pki_int/config/auto-tidy"    { capabilities = ["create", "read", "update"] }
path "pki_int/config/acme"         { capabilities = ["create", "read", "update"] }
path "pki_int/roles/*"             { capabilities = ["create", "read", "update"] }
path "pki_int/issuer/default"      { capabilities = ["read"] }
