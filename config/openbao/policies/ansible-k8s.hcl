# ansible-k8s - a Kubernetes run (ansible/kubernetes/*.yml): the cluster's secrets in lab/k8s/
# (write-once: RKE2's join tokens, Rancher's first admin password), password generation, and the
# TLS certificates of the cluster's web names (Rancher, Hubble UI), signed from a CSR made on
# k8s-server (the private keys never leave the cluster).
path "lab/data/k8s/*"          { capabilities = ["create", "read"] }
path "lab/metadata/k8s/*"      { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-24/generate" { capabilities = ["read"] }
path "sys/policies/password/lab-alnum-64/generate" { capabilities = ["read"] }
path "pki_int/sign/k8s-ingress" { capabilities = ["create", "update"] }
