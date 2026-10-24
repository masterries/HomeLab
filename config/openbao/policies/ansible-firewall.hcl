# ansible-firewall - a run of playbooks/firewall.yml: only certificates of the PKI role
# firewall-gui (the firewall's web GUI, the name firewall.<domain> and nothing else).
path "pki_int/sign/firewall-gui" { capabilities = ["create", "update"] }
