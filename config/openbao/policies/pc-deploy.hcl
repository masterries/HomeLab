# pc-deploy - the PC's everyday login (AppRole pc-deploy): run tokens for Ansible, snapshots, and
# signing the SSH certificates (the PC's own, ansible-control's per run, the hosts'). Only signing:
# the SSH CA and its roles belong to pc-admin.
path "auth/token/create/ansible-run" { capabilities = ["create", "update"] }
path "sys/storage/raft/snapshot"     { capabilities = ["read"] }
path "ssh/sign/pc"                   { capabilities = ["create", "update"] }
path "ssh/sign/ansible-control"      { capabilities = ["create", "update"] }
path "ssh/sign/lab-hosts"            { capabilities = ["create", "update"] }
