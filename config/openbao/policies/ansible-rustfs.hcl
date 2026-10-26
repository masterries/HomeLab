# ansible-rustfs - one RustFS deployment: create missing secrets once, read them,
# ask OpenBao to generate credentials, and sign only the RustFS server certificate.
path "lab/data/rustfs/*"     { capabilities = ["create", "read"] }
path "lab/metadata/rustfs/*" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-24/generate" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-48/generate" { capabilities = ["read"] }
path "pki_int/sign/rustfs"   { capabilities = ["create", "update"] }
