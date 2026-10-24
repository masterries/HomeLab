# openbao-admin - full administration (AppRoles pc-admin and recovery, the UI token role ui-admin).
path "*" { capabilities = ["create", "read", "update", "patch", "delete", "list", "scan", "sudo"] }
