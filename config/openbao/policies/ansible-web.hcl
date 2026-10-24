# ansible-web - hello-nginx.yml, the nginx demo: only certificates of the PKI role web.
path "pki_int/sign/web" { capabilities = ["create", "update"] }
