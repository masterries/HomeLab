# DeployableServer: an enterprise-style home lab on Hyper-V

This repository builds a small, segmented company network on one Windows PC
(Hyper-V) and runs a self-hosted team chat in it: a Matrix homeserver with the
Element web client, single sign-on through the identity provider Keycloak, and
voice and video calls. Five virtual machines take part: an OPNsense firewall and
four Ubuntu 24.04 servers built with Vagrant, all configured with Ansible. It
is a learning project. It uses the same building blocks you find in a company
network (perimeter firewall, bastion host, internal DNS, a two-level internal
certificate authority, a secrets manager, identity provider, reverse proxy,
containers, configuration management, infrastructure as code), scaled down to
fit on one PC.

Start here. The scripts and configuration files have detailed comments that
explain what each part does and why it is written that way. This README gives
the overall picture and tells you which file to read for each topic.

## Contents

1. [What this lab is and what it teaches](#1-what-this-lab-is-and-what-it-teaches)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Quick start](#4-quick-start)
5. [Everyday operations](#5-everyday-operations)
6. [How to ...](#6-how-to-)
7. [Concepts explained](#7-concepts-explained), among them
   [SSH certificates: user and host CAs](#ssh-certificates-user-and-host-cas)
8. [Repository layout](#8-repository-layout)
9. [Pitfalls and troubleshooting](#9-pitfalls-and-troubleshooting)
10. [Security notes](#10-security-notes)
11. [Roadmap](#11-roadmap)

---

## 1. What this lab is and what it teaches

The end result: you open <https://element.lab.internal> in the browser on your
PC, sign in with a central company account (for example `alice`), chat with
another user and start a video call. Behind that page work five VMs:

- **firewall**: an OPNsense firewall (open source, FreeBSD with the pf packet
  filter, web GUI and REST API). It is the only way into the lab: the router and
  NAT gateway to the internet, DHCP and DNS server, SSH jump host, and it
  forwards the published ports of the chat, the login service and the secrets
  manager to their VMs. There is no Vagrant box for OPNsense on Hyper-V, so
  [scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1) builds it from the
  official image and a configuration file kept in this repository.
- **ansible-control** (Ubuntu, built with Vagrant): the Ansible control node.
  Every deployment runs from here. It keeps no service secrets on disk: for
  each run your PC hands it a short-lived OpenBao token and a short-lived SSH
  certificate for only the machines that run configures, and the playbooks hold
  the secrets they read only in memory (even Ansible's temporary files are kept
  in RAM).
- **matrix** (Ubuntu, built with Vagrant): the chat. A Matrix homeserver
  (Synapse) with its PostgreSQL database, the Element Web client, the Matrix
  Authentication Service (MAS) for logins, LiveKit for calls and the reverse
  proxy Traefik, all as Docker containers installed by the community project
  [matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy)
  (MDAD).
- **keycloak** (Ubuntu, built with Vagrant): Keycloak, the identity provider
  (IdP). It owns the user accounts and their passwords and shows the login
  page. Matrix stores no passwords at all: a user signs in with the Keycloak
  account, and the Matrix account is created on the first login.
- **vault** (Ubuntu, built with Vagrant): [OpenBao](https://openbao.org), the
  open source fork of HashiCorp Vault, as the lab's secrets manager and
  certificate authority. It stores the services' secrets (database passwords,
  client secrets, the lab users' passwords) and hands each one only to an
  identity whose policy allows it. It also runs the intermediate certificate
  authority that issues the certificates of Keycloak and of the chat, including
  an ACME server like the one Let's Encrypt runs. After every start it is
  "sealed" until two of its three key shares unlock it.

Your PC has a part of its own: it holds the offline root certificate authority,
which signs only a handful of certificates, the offline SSH certificate
authority, which signs SSH certificates only before OpenBao exists and in an
emergency, the few secrets that must exist before OpenBao runs, encrypted with
Windows DPAPI, and OpenBao's backups (snapshots).

What you learn by building and reading it:

| Topic | What you see in this lab |
|---|---|
| Perimeter firewall | OPNsense (FreeBSD + pf) with a web GUI and a REST API: default deny, stateful rules per interface, outbound NAT, inbound port forwarding (DNAT) to separate "published" addresses, one per published VM. |
| Bastion / jump host | Your PC reaches internal machines only through SSH on the firewall (`ProxyJump`), which forwards nothing but SSH to the lab VMs. Vagrant itself does the same. |
| SSH certificates | No shared SSH key and no "trust on first use": two SSH certificate authorities (an offline one on the PC for the bootstrap and break-glass, OpenBao's SSH secrets engine for everyday signing) issue 8-hour certificates for the PC, 2-hour certificates per Ansible run for only the hosts that run configures, and host certificates for every machine, whose host keys were verified out of band first (serial console, Hyper-V KVP). |
| Network segmentation | Three Hyper-V switches with different trust levels: internet uplink, host network, private lab network. |
| DHCP reservations | Static MAC addresses + DHCP reservations on the firewall (generated from one data file) give every VM a fixed IP without static configuration in the guest. |
| Split-horizon DNS | The same name (`element.lab.internal`) resolves to a different address for your PC (the published address) than for the lab (the VM itself). |
| Conditional DNS forwarding | Windows asks the lab DNS only for `lab.internal` and the names below it (NRPT rule); everything else uses your normal DNS. |
| Internal PKI | Two levels, as in enterprises: an offline root CA on the PC (its key encrypted, restricted by X.509 name constraints to names under `lab.internal`) signs an intermediate CA inside OpenBao, whose key never leaves it. The intermediate issues the everyday certificates, by signing a CSR (Keycloak) and through ACME (Traefik, renewed automatically). Revocation lists are published over HTTP, so Windows checks revocation. The renewals that are due run whenever `Initialize-Lab.ps1` starts the lab again after a Windows restart, and the intermediate itself is replaced by a new one ("rotated") 400 days before it expires. |
| Secrets management | OpenBao as the one store for the services' secrets: values generated by OpenBao, one access policy per consumer that may create a missing secret but never change one, a short-lived, response-wrapped token per Ansible run that works only from the control node, secrets kept off the control node's disk, an audit log of every access. |
| Key management and recovery | OpenBao's key split with Shamir's secret sharing (three shares, any two unseal it); Windows DPAPI as "secret zero" for the shares and logins the PC needs; a recovery kit (one share with you; a passphrase-encrypted file somewhere else with a second share and a "break-glass" login) that restores the PC's access after a lost Windows profile; an OpenBao snapshot (backup) after every Keycloak and Matrix deployment. |
| Single sign-on | Keycloak as identity provider; OpenID Connect (OIDC) with the authorization code flow and PKCE; a confidential client with an exact redirect URI; back-channel logout; MAS as the OIDC layer between Matrix clients and Keycloak. |
| Team chat and calls | Matrix (Synapse, Element Web) with `.well-known` delegation; calls through a LiveKit SFU (MatrixRTC, WebRTC) behind NAT. |
| Reverse proxy and TLS | Traefik terminates TLS for several names on one address, gets and renews its certificates itself through ACME, and routes by host name and path; Keycloak and OpenBao terminate TLS themselves. |
| Containers | Keycloak and PostgreSQL as a Docker Compose project; the Matrix services as Docker containers run by systemd units. |
| Configuration management | Ansible inventory, groups, idempotent playbooks, handlers, delegation, secrets read from OpenBao at run time and held only in memory, Keycloak's realm, client and users configured as code through its admin API. |
| Third-party automation | MDAD vendored: its code and its 32 roles kept unchanged in this repository at one Git commit (`vendor\mdad`), copied to the control node for each deployment, with our own configuration next to it (`ansible\matrix\`); container images pinned by tag or by digest; Ansible and the OpenBao package pinned to a version, OpenBao's repository signing key to a fingerprint, the OPNsense image to a SHA-256 hash. |
| Infrastructure as code | One data file ([config/lab.json](config/lab.json)), a Vagrantfile, a firewall configuration template, playbooks and a set of idempotent scripts rebuild the whole lab from nothing. |
| Appliance automation | A network appliance without cloud-init or Vagrant box: verified image download, configuration imported on the first boot by a script that talks to the serial console, then patched to a pinned minimum version; later its GUI certificate is renewed in place through OPNsense's own PHP configuration library, without a rebuild. |

One principle runs through the whole repository: **every piece of code that
runs in the lab is in this repository**, so you can read exactly what is
executed, and a deployment downloads no automation code from the internet.
That covers the lab's own scripts and playbooks and also the third-party
automation it runs: MDAD and its roles are kept here, unchanged, at one pinned
version ("vendored", in `vendor\mdad`; [vendor/README.md](vendor/README.md)
says what, from where and which version). What the lab installs rather than
executes as automation code (packages, container images, the OPNsense image,
Ansible itself) comes from its publisher instead, pinned by an exact version or
by a hash (digest) of the exact file, written in the repository; the few things
that are not pinned yet are listed in [section 10](#10-security-notes).
[Vendoring and pinning third-party code and images](#vendoring-and-pinning-third-party-code-and-images)
explains both ways. The checks used to verify the lab are here as well, as
scripts in `tests\` ([Run the tests](#run-the-tests)).

This is a learning lab, not a hardened production setup. It takes some shortcuts
on purpose. [Section 10](#10-security-notes) lists each shortcut and the
enterprise practice it replaces.

---

## 2. Architecture

### Network diagram

```
                                     Internet
                                        |
 +--------------------------------------+--------------------------------------+
 | Windows PC (Hyper-V host)  browser: element, keycloak, vault .lab.internal  |
 |  offline root CA (keys\pki) and offline SSH CA (keys\ssh), keys encrypted   |
 |  DPAPI secrets (keys\...\*.dpapi): OpenBao key shares A + B and logins,     |
 |  firewall passwords and API key, the offline SSH CA's passphrase            |
 |  OpenBao snapshots (backups, keys\openbao\snapshots)                        |
 |                                                                             |
 |  vEthernet (Default Switch)                 vEthernet (LabHost)             |
 |  NAT + DHCP by Windows (ICS),               10.10.99.1/24, fixed            |
 |  subnet changes on every reboot             NRPT rule: .lab.internal        |
 |                                               -> DNS at 10.10.99.2          |
 +------------+---------------------------------------------+------------------+
              |                                             |
      [Default Switch]                                  [LabHost]
      Hyper-V built-in NAT switch                       Internal switch
              |                                             |
    hn0 (WAN) | DHCP (address changes)           hn2 (HOST) | 10.10.99.2 management
              |                                             | 10.10.99.3 matrix (VIP)
              |                                             | 10.10.99.4 keycloak (VIP)
              |                                             | 10.10.99.5 vault (VIP)
 +------------+---------------------------------------------+------------------+
 | firewall: OPNsense 26.7 (FreeBSD + pf), built by New-LabFirewall.ps1        |
 |   pf:       default deny, outbound NAT LAN -> WAN, port forwards (DNAT):    |
 |             10.10.99.3 tcp 443, 80, 7881 + udp 7882 -> matrix 10.10.10.30   |
 |             10.10.99.4 tcp 443                      -> keycloak 10.10.10.40 |
 |             10.10.99.5 tcp 8200, 80                 -> vault 10.10.10.50    |
 |   dnsmasq:  DHCP for LabNet, split-horizon DNS for lab.internal             |
 |   web GUI and REST API: https://firewall.lab.internal (10.10.99.2)          |
 |   sshd:     bastion / jump host for the PC and for Vagrant                  |
 +--------------------------------------+--------------------------------------+
                                        | hn1 (LAN) 10.10.10.1/24
                                        |
                          [LabNet] Private switch, 10.10.10.0/24
                                        |
          +-------------------+---------+---------+-------------------+
          |                   |                   |                   |
 +--------+--------+ +--------+--------+ +--------+--------+ +--------+--------+
 | ansible-control | | matrix          | | keycloak        | | vault           |
 | 10.10.10.10     | | 10.10.10.30     | | 10.10.10.40     | | 10.10.10.50     |
 | Ansible,        | | Traefik (ACME), | | Keycloak 26.8,  | | OpenBao 2.7.1:  |
 | copy of MDAD;   | | Synapse, MAS,   | | PostgreSQL 18,  | | KV secrets,     |
 | no service      | | Element Web,    | | Docker Compose  | | intermediate CA |
 | secrets on disk | | LiveKit,        | |                 | | with ACME;      |
 |                 | | PostgreSQL 18   | |                 | | CRLs on port 80 |
 +-----------------+ +-----------------+ +-----------------+ +-----------------+
```

Important traffic paths (terms used here are explained later: *port forward
(DNAT)* and *outbound NAT* in
[NAT: outbound NAT and port forwarding](#nat-outbound-nat-and-port-forwarding),
*ProxyJump* in [Bastion (jump) host](#bastion-jump-host), the *virtual IPs
(VIPs)* 10.10.99.3 to 10.10.99.5 right below the Networks table, the login
terms in [Identity: IdP, OIDC and single sign-on](#identity-idp-oidc-and-single-sign-on),
and OpenBao, tokens and certificates in
[Where secrets and certificates come from](#where-secrets-and-certificates-come-from)):

- **Browser on the PC to Element**: `https://element.lab.internal` -> Windows
  asks the firewall's DNS at `10.10.99.2` (NRPT rule) -> answer `10.10.99.3`,
  the published address of the matrix VM -> TCP 443 to `10.10.99.3` on the
  firewall's HOST interface (`hn2`) -> port forward (DNAT) -> `10.10.10.30:443`,
  Traefik on the matrix VM -> chosen by host name: the Element Web container,
  which delivers the app's files. From then on Element runs in the browser.
- **Element to the homeserver**: Element takes the homeserver's address
  (`https://matrix.lab.internal`, server name `lab.internal`) from its own
  `config.json`, which MDAD writes, and uses
  `https://matrix.lab.internal/_matrix/client/...`; Synapse's
  `/_matrix/client/v1/auth_metadata` tells it that MAS handles logins. It also
  reads `https://lab.internal/.well-known/matrix/client`, which names the call
  service (`rtc_foci`). Both names resolve to `10.10.99.3` for the PC, so the
  requests take the same path to Traefik, which passes them to Synapse (or, for
  `lab.internal`, to a static file server); the login-related endpoints go to
  MAS.
- **Login**: the browser travels between MAS (`10.10.99.3`) and Keycloak
  (`10.10.99.4`), and MAS talks to Keycloak directly inside the lab. Step by step
  in [The login flow](#the-login-flow) below.
- **Keycloak's pages from the PC** (login form, admin console
  `https://keycloak.lab.internal/admin/`): answer `10.10.99.4` -> port forward ->
  `10.10.10.40:443` -> the Keycloak container (port 8443 inside). Keycloak
  terminates TLS itself; there is no reverse proxy in front of it.
- **The PC to OpenBao** (web UI `https://vault.lab.internal:8200/ui/`, and the
  API calls of the PC's scripts such as `Deploy-LabVault.ps1`,
  `Show-LabSecret.ps1`, the run tokens for Ansible and the snapshots of
  `Backup-LabVault.ps1`): answer `10.10.99.5` -> TCP 8200 -> port forward ->
  `10.10.10.50:8200`, OpenBao itself, which terminates TLS with a certificate
  signed by the offline root. The PC's scripts accept that certificate only if
  its chain ends at the lab root (certificate pinning, see
  [Internal PKI](#internal-pki-certificate-authority)). A port forward
  rewrites only the destination, so OpenBao sees the PC's own address
  `10.10.99.1` as the source: the PC's OpenBao logins are accepted only from
  that address.
- **Revocation checks from the PC**: every lab certificate names plain HTTP URLs
  on `vault.lab.internal` where its CA's certificate and revocation list (CRL)
  can be fetched. Windows fetches them when it checks a certificate (so does
  `curl.exe`, which uses Windows' TLS library): TCP 80 to `10.10.99.5` -> port
  forward -> nginx on the vault VM, which serves only these files (the root's
  from disk, the intermediate's from OpenBao) and answers 404 to everything
  else.
- **Calls**: the call's signalling (who is in the call, access tokens) runs over
  HTTPS and a WebSocket through `10.10.99.3:443` and Traefik. The audio and
  video (WebRTC) go from the browser directly to LiveKit: UDP `10.10.99.3:7882`
  (or TCP `7881` as fallback), forwarded unchanged to the matrix VM. Details in
  [Calls: MatrixRTC, SFU, ICE and the node IP](#calls-matrixrtc-sfu-ice-and-the-node-ip).
- **Server to server inside the lab**: MAS on the matrix VM fetches Keycloak's
  discovery document, exchanges login codes for tokens and reads user details;
  Keycloak calls MAS when a user's Keycloak session ends (back-channel logout).
  Inside the lab the names resolve to the VMs' own addresses (`10.10.10.40`,
  `10.10.10.30`), and both VMs are on the same switch, so this traffic never
  passes the firewall.
- **Traefik to OpenBao (ACME)**: Traefik on the matrix VM orders its
  certificates from OpenBao's ACME directory
  (`https://vault.lab.internal:8200/v1/pki_int/roles/acme-matrix/acme/directory`,
  lab view `10.10.10.50`). OpenBao checks each name with an HTTP-01 challenge:
  from the vault VM it fetches `http://<name>/.well-known/acme-challenge/...`,
  which lab DNS resolves to `10.10.10.30`, Traefik's port 80. Both directions
  stay on LabNet.
- **Browser on the PC to the firewall's GUI**: `https://firewall.lab.internal` ->
  answer `10.10.99.2` -> TCP 443 to the OPNsense web GUI itself.
- **SSH from the PC**: `ssh -F keys\ssh_config matrix` -> SSH to the firewall at
  `10.10.99.2` as user `ansible`, logged in with the PC's short-lived SSH
  certificate, the firewall's host certificate checked -> the firewall opens the
  onward connection to `matrix.lab.internal:22` (`ProxyJump`; port 22 of a lab
  VM is the only place it forwards to) and resolves that name itself, to the
  lab address -> through that tunnel the PC logs in to matrix and checks its
  host certificate (see
  [SSH certificates](#ssh-certificates-user-and-host-cas)).
- **Lab VMs to the internet** (Ubuntu packages, PyPI, Docker's and OpenBao's
  package repositories, container images, and GitHub, only when
  `Update-LabMdad.ps1` fetches a new MDAD version): lab VM -> `hn1` (LAN) ->
  outbound NAT to the firewall's WAN address -> `hn0` (WAN) -> Windows NAT ->
  internet. This is double NAT, and that is fine for outbound traffic. The
  firewall's own downloads (OPNsense updates from `pkg.opnsense.org`) leave
  through `hn0` the same way.
- **Ansible**: ansible-control connects over LabNet directly to the matrix,
  keycloak and vault VMs (SSH, with its own key and a certificate for this run
  that names only the hosts the playbook configures), to Keycloak's admin API
  (`https://keycloak.lab.internal`, lab view `10.10.10.40`), to OpenBao's API
  (`https://vault.lab.internal:8200`, lab view `10.10.10.50`; secrets and
  certificate signing, with a run token that works only from ansible-control's
  address `10.10.10.10`) and to the firewall's LAN address `10.10.10.1`.
- **Vagrant**: manages only the four Ubuntu VMs and never talks to the
  firewall's WAN side. It reaches the lab VMs through the firewall:
  `ssh.proxy_command` in the Vagrantfile opens an SSH connection to the firewall
  at `10.10.99.2` as user `ansible` (Windows' own `ssh.exe`, settings and the
  PC's certificate from `keys\ssh_config`) and tunnels it to the VM's LabNet
  address (`-W %h:%p`). Through that tunnel Vagrant logs in to the VM as
  `vagrant`, with its own per-VM key; this last hop does not check the VM's
  host key, and nothing of the lab's trust depends on it.

### The login flow

Signing in to Element involves three parties: Element in the browser, MAS (the
Matrix Authentication Service, at `https://matrix.lab.internal/auth/`) and
Keycloak (realm `lab`). Element is an OAuth 2.0 client of MAS, and MAS is an
OIDC client of Keycloak. The terms used here (IdP, OAuth 2.0 and OIDC, realm,
authorization code, PKCE, confidential client, issuer, redirect URI, ULID,
back-channel logout) are explained in
[Identity: IdP, OIDC and single sign-on](#identity-idp-oidc-and-single-sign-on).
Read this section for the order of events and that one for the reasons.

Why two hops, instead of Element talking to Keycloak directly? Matrix clients
speak one standard API to their homeserver's login service, MAS, whatever IdP
the organisation runs. MAS adds what only Matrix knows (devices, Matrix scopes,
the user ID) and speaks standard OIDC to the IdP, so Keycloak knows a single
client, MAS, however many Matrix clients exist. Enterprise equivalent: an
application's own OAuth server federated with the corporate IdP (identity
brokering).

Before step 1 (not drawn), Element asks Synapse's
`/_matrix/client/v1/auth_metadata`, learns that MAS handles logins, and
registers itself with MAS as a client (dynamic client registration: MAS
publishes a `registration_endpoint`, and Element's `config.json` names no client
ID of its own).

```
 Browser (Element Web)          MAS on matrix               Keycloak on keycloak
 via the firewall               10.10.10.30                 10.10.10.40
       |                              |                              |
  1    |--- authorize (PKCE) -------->|                              |
  2    |<-- to /auth/login, which ----|                              |
       |    answers 303 to /auth/upstream/authorize/<ULID>           |
  3    |<-- 307 to Keycloak ----------|                              |
  4    |--- authorization request (client_id, redirect_uri, PKCE) -->|
  5    |<-- login form; user name and password --------------------->|
  6    |<-- redirect to MAS: /auth/upstream/callback/<ULID>?code= ---|
       |--- (follows the redirect) -->|                              |
  7    |                              |--- code + client secret ---->|
       |                              |    + PKCE verifier           |
       |                              |<-- tokens; then userinfo ----|
  8    |<-- MAS session; redirect ----|                              |
       |    back to Element           |                              |
  9    |--- Element gets its tokens ->|                              |
       |    from MAS, then calls Synapse with its access token       |
```

1. You click "Sign in". Element sends the browser to MAS's authorization
   endpoint (Element's own authorization code flow with PKCE).
2. MAS has no local passwords and exactly one upstream provider, so its login
   page sends the browser straight on to its "upstream authorize" URL for
   Keycloak (`<ULID>` is the provider ID, see
   [group_vars/all.yml](ansible/inventory/group_vars/all.yml)).
3. MAS answers with a redirect to Keycloak's authorization endpoint.
4. The browser asks Keycloak (through `10.10.99.4`) with `client_id`
   `matrix-authentication-service`, the redirect URI
   `https://matrix.lab.internal/auth/upstream/callback/<ULID>` and a PKCE code
   challenge (S256). Keycloak accepts only that exact redirect URI.
5. Keycloak shows its login form. Only here is a password typed in, and only
   Keycloak sees it.
6. Keycloak redirects the browser back to MAS with a short-lived authorization
   code.
7. MAS exchanges the code for tokens **server to server** (the "back channel",
   directly from the matrix VM to the keycloak VM), authenticating with its
   client secret and the PKCE verifier, and fetches the user's details from
   Keycloak's userinfo endpoint.
8. MAS links the Keycloak account to a Matrix account (`@alice:lab.internal`,
   created on the first login), starts its own browser session and sends the
   browser back to Element.
9. Element finishes its own flow with MAS and gets its Matrix access token.
   Synapse asks MAS whether a token is valid; it never sees a password either.

Logout goes the other way: when a Keycloak session ends, Keycloak tells MAS
server to server (back-channel logout,
`https://matrix.lab.internal/auth/upstream/backchannel-logout/<ULID>`).

### Where secrets and certificates come from

No secret of the lab that opens anything on its own is kept in a plain file.
The two SSH keys without a passphrase, the PC's and ansible-control's, open
nothing without a certificate that is valid for a few hours and only from their
own addresses ([SSH certificates](#ssh-certificates-user-and-host-cas)).
Secrets live in two places, and which one holds a secret follows from one
question: is it needed before OpenBao runs, or to open OpenBao?

| Secret | Stored in | Created by |
|---|---|---|
| Keycloak: database password, bootstrap admin `admin`, client secret of `lab-ansible` (Ansible's client for the admin API), client secret of MAS, passwords of `alice` and `bob` | OpenBao, `lab/keycloak/...` | `keycloak.yml` on its first run; OpenBao's password policies generate the values |
| Matrix: MDAD's generic secret key (MDAD derives further keys from it), PostgreSQL password | OpenBao, `lab/matrix/...` | `matrix-prepare.yml` on its first run |
| Firewall: passwords of `root` and `ansible`, REST API key | PC, DPAPI, `keys\opnsense\` (copies in the recovery file) | `New-LabFirewall.ps1` (the firewall exists before OpenBao) |
| OpenBao: key shares A and B, the PC's logins `pc-admin` and `pc-deploy` | PC, DPAPI, `keys\openbao\` (a copy of share B in the recovery file) | `Deploy-LabVault.ps1` (new logins after a lost Windows profile: `New-LabRecoveryKit.ps1 -Recover`) |
| OpenBao: key share C | you: a password manager or paper | `Deploy-LabVault.ps1`; handed to you once by `New-LabRecoveryKit.ps1` |
| OpenBao: the break-glass login `recovery` (administrator rights) | only in the recovery file, encrypted with your passphrase | `New-LabRecoveryKit.ps1`, a new secret for every kit |
| Root CA private key | PC, `keys\pki\root-ca.key`, encrypted; its passphrase with DPAPI (both also in the recovery file) | `New-LabRootCA.ps1` |
| Offline SSH CA private key | PC, `keys\ssh\offline-ca`, encrypted; its passphrase with DPAPI (both also in the recovery file) | `New-LabSshCa.ps1` |
| OpenBao's SSH CA private key | OpenBao (mount `ssh`), generated there, never exported | `Deploy-LabVault.ps1` |
| The PC's SSH key | PC, `keys\ssh\pc_ed25519`, no passphrase; it opens nothing without its 8-hour certificate, which works only from the PC's addresses | `New-LabSshCa.ps1` (the certificate: `Get-LabSshConfig` in `LabSsh.ps1`, on demand) |
| ansible-control's SSH key | only on ansible-control, `~ansible/.ssh/id_ed25519`; it opens nothing without the 2-hour certificate the PC signs for each run | `bootstrap-ansible-control.sh` |

Everything OpenBao holds is also in its **snapshots** (`keys\openbao\snapshots`,
the newest 10): `Deploy-LabKeycloak.ps1` and `Deploy-LabMatrix.ps1` take one
after every run, because a first deployment creates secrets that exist nowhere
else, and `Remove-Lab.ps1` takes one before it deletes the vault VM. A snapshot
is encrypted by OpenBao itself and can only be restored together with the key
shares of its time.

**DPAPI** (the Windows Data Protection API) encrypts with a key that Windows
derives from your logon: only programs running as you, on this PC, can decrypt
the `.dpapi` files. It is the lab's "secret zero", the first key, which cannot
itself be kept in OpenBao. If your Windows profile is lost, the `.dpapi` files
can no longer be decrypted; the recovery kit ([Step 5](#step-5-make-the-recovery-kit-once-you-run-it-yourself))
covers that case. DPAPI does not protect against programs that run as you.
Enterprise equivalent: an HSM or a cloud KMS holds the first key, and OpenBao
unseals itself through it ("auto-unseal").

**How a playbook gets its secrets.** A playbook that needs OpenBao gets a token
of its own for one run (`Invoke-LabPlaybook.ps1`, and `Deploy-LabMatrix.ps1` for
MDAD, through `New-LabRunToken` in [scripts/LabSecrets.ps1](scripts/LabSecrets.ps1)):

```
 PC (your scripts)                OpenBao (vault)                 ansible-control
     |                                    |                              |
  1  |--- AppRole login "pc-deploy" ----->|                              |
     |<-- token (5 minutes) --------------|                              |
  2  |--- run token, role "ansible-run" ->|                              |
     |    (response-wrapped, 120 s)       |                              |
     |<-- single-use wrapping token ------|                              |
  3  |--- wrapping token over SSH, on stdin ---------------------------->|  openbao-run
     |                                    |<-- unwrap -------------------|
     |                                    |--- run token (2 h at most) ->|
  4  |                                    |<-- read secrets, sign CSRs --|  ansible-playbook
  5  |                                    |<-- revoke the token ---------|  (at the end; its
     |                                    |                              |  RAM folder deleted)
```

1. The PC logs in to OpenBao with the AppRole `pc-deploy` (an AppRole is a login
   for machines; its credentials are stored with DPAPI, and OpenBao accepts them
   only from `10.10.99.1`). That token may do nothing but create run tokens,
   take snapshots and have SSH certificates signed.
2. It creates a run token through the token role `ansible-run` with exactly the
   policy the playbook needs: `ansible-keycloak` (`keycloak.yml`),
   `ansible-matrix` (`matrix-prepare.yml` and MDAD) or `ansible-web`
   (`hello-nginx.yml`). OpenBao answers with a response-wrapped token: instead
   of the token, a single-use wrapping token valid for 120 seconds that can only
   be exchanged for it.
3. The wrapping token travels to ansible-control on SSH's standard input, never
   on a command line, where
   [ansible/bin/openbao-run](ansible/bin/openbao-run) exchanges it ("unwrap")
   for the run token. That token works only from ansible-control's address and
   for at most two hours. `openbao-run` exports `VAULT_ADDR`, `VAULT_CACERT` and
   `VAULT_TOKEN`, points Ansible's local temporary folder (`ANSIBLE_LOCAL_TEMP`)
   to a private folder in RAM (tmpfs: `XDG_RUNTIME_DIR`, or `/dev/shm`) and
   starts the playbook.
4. The playbook reads its secrets over OpenBao's HTTP API
   ([tasks/openbao-secrets.yml](ansible/playbooks/tasks/openbao-secrets.yml))
   into memory, and has certificate requests signed. Missing secrets are
   generated by OpenBao and stored only for a new installation; the policies
   allow `create` and `read`, never `update`, so no playbook can overwrite a
   secret. The values are written only where the running services need them:
   into their own configuration files on their VMs. On the way they never touch
   ansible-control's disk: with `pipelining = True` in
   [ansible/ansible.cfg](ansible/ansible.cfg), Ansible hands each module and its
   arguments (which can hold the token or a secret) to the target's Python on
   standard input instead of copying them as a file first, and templates are
   rendered in the RAM folder.
5. When the command ends, also after an error, `openbao-run` revokes the token
   and deletes the RAM folder.

**Where the certificates come from.** The PKI has two levels:

```
 DeployableServer Lab Root CA 2026        offline: only on the PC (keys\pki), its key
 EC P-384, 10 years, pathlen 1,           encrypted; every client trusts it; it signs
 only DNS names under lab.internal        only the certificates directly below it
  |
  |-- vault.lab.internal                  OpenBao's own TLS certificate, 397 days
  |-- firewall.lab.internal               the firewall's web GUI, 397 days
  |-- DeployableServer Lab Intermediate CA 2026-10-24
  |    the current issuer (OpenBao name lab-int-20261024): EC P-384, 3 years,
  |    inside OpenBao (mount pki_int), its key never exported
  |     |
  |     |-- keycloak.lab.internal         CSR signing, role keycloak, 1 year
  |     |-- matrix.lab.internal,          ACME, role acme-matrix, 90 days
  |     |   element.lab.internal,
  |     |   lab.internal
  |     `-- hello.lab.internal            CSR signing, role web (the nginx demo), 1 year
  `-- DeployableServer Lab Intermediate CA 2026
       the first intermediate (lab-int-2026), replaced on 2026-10-24: it issues
       nothing new, but stays in OpenBao and keeps publishing its revocation list
```

**The intermediate is rotated.** A CA must stay valid for longer than the
certificates it issues (Keycloak's: one year). So `Deploy-LabVault.ps1` makes a
new intermediate (a new key inside OpenBao, signed by the root on the PC) when
the current one expires within 400 days, or at once with
`.\scripts\Deploy-LabVault.ps1 -RotateIntermediate`, and makes it the default
issuer. The old one stays in OpenBao and keeps publishing its revocation list,
because the certificates it issued remain valid until they expire; Keycloak and
Traefik move to the new one at their next deployment. This lab's intermediate
was rotated on 2026-10-24, as a test of exactly this path. How it works:
[Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation);
the commands: [Rotate the intermediate CA](#rotate-the-intermediate-ca).

**Renewals.** Each certificate is renewed by whoever uses it: Traefik renews the
Matrix certificates itself through ACME; `Deploy-LabKeycloak.ps1`,
`Deploy-LabVault.ps1` and `New-LabFirewall.ps1` renew Keycloak's, OpenBao's and
the firewall's certificates when fewer than 30 days are left, and
`Deploy-LabVault.ps1` also renews the root CA's revocation list and the
intermediate CA. A renewal happens only when the script that does it runs. So
`Initialize-Lab.ps1`, which you run after every Windows restart, checks what is
due (its step 7, *Maintenance*) and runs `Deploy-LabVault.ps1` and/or
`Deploy-LabKeycloak.ps1` for it; its step 4 runs `New-LabFirewall.ps1`, which
checks the firewall's GUI certificate anyway. Every certificate with its
lifetime, its renewal rule and the command that forces a renewal:
[Renew certificates](#renew-certificates).

Two certificates come from the root directly because they must not depend on
OpenBao: OpenBao's own (an expired one could otherwise only be renewed through
the server it protects), and the firewall's GUI (the firewall is built before
OpenBao exists, and its GUI is a way back in when the lab is broken).

Trust: Windows trusts the root for your user (`Install-LabRootCA.ps1`), and the
playbooks put it into the system trust store of every Ubuntu VM. Containers
bring their own CA lists and get the root separately: Keycloak in its trust
store folder, Traefik as a mounted file named in its ACME settings, MAS and the
LiveKit JWT service as the VM's CA bundle mounted into the container. The
concepts behind all of this (two-level PKI, name constraints, revocation, ACME,
rotation, sealing, response wrapping, break-glass access) are explained in
[section 7](#7-concepts-explained).

SSH logins and SSH host keys use certificates too, of OpenSSH's own, simpler
kind and from two SSH CAs of their own (the offline SSH CA on the PC and
OpenBao's SSH secrets engine), not from this PKI:
[SSH certificates](#ssh-certificates-user-and-host-cas).

The lab's first CA, "DeployableServer Lab CA" (a single level, its key a plain
file), is retired: no lab service uses its certificates any more, and the VMs no
longer trust it. Only its certificate is kept, in `keys\ca\lab-root-ca.crt`, so
that `.\scripts\Install-LabRootCA.ps1 -RemoveRetired` can remove it from your
Windows certificate store.

### Networks

| Hyper-V switch | Switch type | Subnet | Members | Purpose |
|---|---|---|---|---|
| Default Switch | Built-in, NAT via Windows ICS | Chosen by Windows, changes on every reboot | PC, firewall `hn0` (WAN) | Internet uplink for the lab (the firewall's WAN side) |
| LabHost | Internal (host + VMs) | 10.10.99.0/24 | PC `10.10.99.1`, firewall `hn2` (HOST) `10.10.99.2` and the virtual IPs `10.10.99.3` (matrix), `10.10.99.4` (keycloak) and `10.10.99.5` (vault) | Fixed path from the PC into the lab: SSH to the bastion, DNS and the web GUI on `.2`; the published ports of each published VM on its own address |
| LabNet | Private (VMs only, the PC has no adapter on it) | 10.10.10.0/24 | firewall `hn1` (LAN) `.1`, ansible-control `.10`, matrix `.30`, keycloak `.40`, vault `.50`, DHCP pool `.100`-`.199` | The segmented lab network, reachable only through the firewall |

LabHost is created once by `scripts/Install-LabHostNetwork.ps1`. LabNet is
created by `scripts/Initialize-Lab.ps1`. Almost all addresses come from
[config/lab.json](config/lab.json), the main source for the lab's data (domain,
networks, firewall addresses, lab VMs and what is published to your PC). The
Vagrantfile, `New-LabFirewall.ps1` and `Initialize-Lab.ps1` read it;
`Remove-Lab.ps1` reads its `vms` (which leftover Hyper-V folders it may delete);
the `Deploy-*.ps1` scripts and the shared helpers in `LabSecrets.ps1` read its
`domain` (OpenBao's URL, the root CA's name constraint, the URLs of checks and
messages), and `Deploy-LabVault.ps1` also reads `firewall.pcIp` and
ansible-control's `ip`: the addresses that OpenBao's logins and run tokens are
bound to. A few values are repeated by hand and must be changed together
with it: the PC's address, its DNS server and the NRPT namespace in
`Install-LabHostNetwork.ps1`; the domain in `lab_domain`
([group_vars/all.yml](ansible/inventory/group_vars/all.yml)), in `matrix_domain`
and in the Matrix inventory's host name
([vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml));
and the matrix VM's published address as LiveKit's node IP,
`livekit_server_config_rtc_node_ip` in the same `vars.yml`.

**Why several addresses on the HOST side?** `10.10.99.2` is the firewall's
management address (GUI, SSH, DNS). `10.10.99.3` to `10.10.99.5` are virtual
IPs (VIPs: IP aliases on the same interface), one per published VM, listed under
`published` in `config/lab.json`. A port forward is chosen by destination
address **and** port, so `10.10.99.3:443` can lead to the matrix VM and
`10.10.99.4:443` to the keycloak VM, although both services use port 443 (and
`10.10.99.3:80` and `10.10.99.5:80` to two different VMs as well); and it
redirects a packet before any service on the firewall sees it. The VIPs carry
`nobind`, which keeps the firewall's web GUI and SSH server off them. dnsmasq
(DNS, DHCP) and ntpd still listen on every address, the VIPs included: what
keeps them closed there is pf, because the PC rules name only `10.10.99.2` and
nothing else passes to a VIP except the forwarded ports (see
[P8](#p8-the-firewall-answers-dns-on-a-published-address)). Separating the
management address from the service addresses is a common enterprise pattern:
rules for administrators and for users never mix.

### Virtual machines

The four Ubuntu VMs use the Vagrant box `gusztavvargadr/ubuntu-server-2404-lts`
(Ubuntu 24.04 LTS) as Hyper-V linked clones; their names, MACs, IPs and sizes
come from `vms` in `config/lab.json`. The firewall is built by
`New-LabFirewall.ps1` from the official OPNsense 26.7 "nano" image (a
ready-installed disk image, no installer) and updated to at least 26.7.7 during
the build. So the two kinds of VM are built in two different ways: the Ubuntu
VMs start from a generic image that scripts change step by step, while the
firewall is an appliance handed one complete configuration file.
[An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)
explains why that matters.

| VM | Role | Addresses | DNS names | Size |
|---|---|---|---|---|
| firewall | OPNsense: router/NAT, pf packet filter, dnsmasq DHCP + DNS, SSH bastion, web GUI + REST API | `hn0` WAN: DHCP from the Default Switch (MAC 02:00:0a:0a:0a:fe); `hn1` LAN: 10.10.10.1 (MAC 02:00:0a:0a:0a:01); `hn2` HOST: 10.10.99.2 + virtual IPs 10.10.99.3, 10.10.99.4 and 10.10.99.5 (MAC 02:00:0a:0a:0a:02) | `firewall.lab.internal` (PC gets 10.10.99.2, lab gets 10.10.10.1) | Hyper-V Generation 1, 1 vCPU, 3 GB static RAM, 16 GB disk |
| ansible-control | Ansible control node: runs all playbooks and MDAD; holds the copy of the Ansible project (`~/lab`), a copy of the repository's `vendor\mdad` (`~/mdad`, replaced on every `Deploy-LabMatrix.ps1` run) and the public PKI files (`~/lab-pki`: root certificate and its CRL). No service secrets on disk: each run gets a run token from the PC (see [above](#where-secrets-and-certificates-come-from)); its only secret is its own SSH key, which opens nothing without the 2-hour certificate the PC signs for each run | 10.10.10.10 (MAC 02:00:0a:0a:0a:0a, DHCP reservation) | `ansible-control.lab.internal` | 2 vCPU, 2 GB |
| matrix | The Matrix stack (MDAD): Traefik, Synapse, PostgreSQL, MAS, Element Web, LiveKit server and LiveKit JWT service, a static file server for `.well-known`, a Docker socket proxy; 9 systemd units `matrix-*.service` | 10.10.10.30 (MAC 02:00:0a:0a:0a:1e, DHCP reservation) | `matrix.lab.internal`, `element.lab.internal`, `lab.internal` (published: PC gets 10.10.99.3, lab gets 10.10.10.30) | 4 vCPU, 8 GB |
| keycloak | Keycloak 26.8.1 and its PostgreSQL 18.6 as a Docker Compose project in `/opt/keycloak-stack` | 10.10.10.40 (MAC 02:00:0a:0a:0a:28, DHCP reservation) | `keycloak.lab.internal` (published: PC gets 10.10.99.4, lab gets 10.10.10.40) | 2 vCPU, 4 GB |
| vault | OpenBao 2.7.1 (secrets manager and intermediate CA) with its data in `/opt/openbao/data`; nginx on port 80 for the CA certificates and CRLs | 10.10.10.50 (MAC 02:00:0a:0a:0a:32, DHCP reservation) | `vault.lab.internal` (published: PC gets 10.10.99.5, lab gets 10.10.10.50) | 2 vCPU, 2 GB; Hyper-V checkpoints off, no console autologin |

The Matrix stack in detail, as deployed (the versions come with the pinned MDAD
commit, except where the lab pins them itself):

| Component | Version | What it does here |
|---|---|---|
| Traefik | v3.7.16 | Reverse proxy on ports 80/443 (and 8448 inside the lab): TLS with certificates from OpenBao's ACME server (role `acme-matrix`, 90 days, EC P-256 keys made by Traefik), requested and renewed by Traefik itself; routing by host name and path |
| Synapse | v1.163.1 | The homeserver: rooms, messages, the Matrix client API; federation switched off |
| PostgreSQL | 18.6 (MDAD's image) | Database of Synapse and MAS |
| MAS (Matrix Authentication Service) | 1.27.1 | Login, sessions and tokens for Matrix, at `https://matrix.lab.internal/auth/`; Keycloak is its only upstream provider, local passwords are off |
| Element Web | v1.12.32 | The web client at `https://element.lab.internal`, with the OIDC login flow and Element Call for every call |
| LiveKit server | v1.13.10 | The SFU for calls (MatrixRTC); announces 10.10.99.3, UDP 7882 and TCP 7881; TURN off |
| LiveKit JWT service | 0.9.0 | Checks a caller's Matrix identity and hands out LiveKit access tokens |
| Static web server | (MDAD) | Serves `https://lab.internal/.well-known/matrix/...` |

The vault VM in detail ([ansible/playbooks/openbao.yml](ansible/playbooks/openbao.yml)
installs it; `Deploy-LabVault.ps1` configures OpenBao through its API):

| Component | Version | What it does here |
|---|---|---|
| OpenBao | 2.7.1 (pinned; the package is held) | API, web UI (`/ui/`) and ACME directory on port 8200, TLS with a certificate signed by the offline root; secrets engine `lab` (key/value, version 2), PKI mount `pki_int` (the intermediate CA), logins by AppRole (the PC) and by token role (Ansible runs); integrated storage ("raft") in `/opt/openbao/data`; audit log `/var/log/openbao/audit.log` (every request, secret values replaced by HMAC hashes), rotated by logrotate |
| nginx | Ubuntu's package | Port 80: only the CA certificates and CRLs (`/pki/root-ca.crt` and `/pki/root-ca.crl` from disk, the read-only CA and CRL paths of `pki_int` from OpenBao); everything else answers 404, so the API is never reachable without TLS |

The firewall's adapters are added in the order WAN, LAN, HOST, so FreeBSD names
them `hn0`, `hn1`, `hn2` (`hn` is the driver for Hyper-V network adapters). The
OPNsense configuration binds its interfaces `wan`, `lan` and `opt1` (description
"HOST") to exactly these names, and the build checks the mapping by MAC address
after the first boot.

All static MACs start with `02`, which marks a "locally administered" address
that no network card vendor uses, so they cannot clash with real hardware. The
last four bytes of a LabNet MAC are the IP address in hex (`0a0a0a1e` =
10.10.10.30, `0a0a0a28` = 10.10.10.40, `0a0a0a32` = 10.10.10.50; `0a0a0a01` =
10.10.10.1 for the firewall's LAN adapter). The firewall's HOST and WAN MACs
(`...0a:02`, `...0a:fe`) are the exceptions: they are simply fixed, distinct
values, not addresses. This is only a naming convention that makes the
addresses easy to read. Hyper-V writes MACs without separators (`02000A0A0A1E`,
as in `config/lab.json`), OPNsense and dnsmasq with colons
(`02:00:0a:0a:0a:1e`, as in the firewall's `config.xml`).

The four Ubuntu VMs also get:

- user `ansible` with passwordless sudo, which logs in only with an SSH
  certificate from a lab SSH CA, and only from the jump host or ansible-control
- their own SSH host keys, published to the PC through Hyper-V, with a host
  certificate
- zsh with fzf history search (Ctrl+R) and the alias `ll`, with no blue colours,
  because blue is unreadable on the blue background of Windows PowerShell
- console autologin on tty1 ("Connect" in Hyper-V Manager opens a shell
  without asking for a password), except on vault

The vault VM differs in two settings from `config/lab.json`: `"checkpoints":
false` switches Hyper-V checkpoints off for it, and `"consoleAutologin": false`
keeps the normal login prompt on its console. The reason is the same for both:
while OpenBao is unsealed, the key that decrypts all its data is in the VM's
RAM. A checkpoint of a running VM writes that RAM into a file on the storage
drive, unencrypted, and console autologin would give whoever opens the console
in Hyper-V Manager a shell with passwordless sudo next to it. (The console still
accepts the box's well-known login `vagrant`/`vagrant`, which has passwordless
sudo too, see
[P16](#p16-the-ubuntu-vms-all-have-the-same-ssh-host-keys-and-vagrantvagrant-works-over-ssh):
this setting removes the shell without any password, not every way in.) Enterprise
equivalent: secrets servers run on hardened, dedicated hosts whose memory never
ends up in snapshots, with console access restricted and audited.

The firewall has its own two accounts, defined in its configuration: `root` for
the web GUI and the console, and `ansible` for SSH with SSH certificates, from
the PC and ansible-control only (shell `/bin/sh`, passwordless sudo, and an API
key for the REST API). Their passwords
and the API key are random and stored with DPAPI in `keys\opnsense\`;
`.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password` copies the GUI
password to the clipboard. Its console in Hyper-V Manager asks for a login.

### What is allowed where

The firewall rules are in
[opnsense/config.xml.template](opnsense/config.xml.template): the filter rules in
the `<OPNsense><Firewall><Filter>` section. The virtual IPs and the port forwards
are generated by `New-LabFirewall.ps1` from `published` in
[config/lab.json](config/lab.json) and inserted at the placeholders
`<!--{{VIRTUAL_IPS}}-->` and `<!--{{PORT_FORWARDS}}-->`. In the GUI you find
them under Firewall > Rules, Interfaces > Virtual IPs and Firewall > NAT >
Destination NAT (OPNsense 26.7's page for port forwards; older OPNsense versions
and most tutorials call it Port Forward). Outbound NAT is under Firewall > NAT >
Source NAT. The rules pf actually runs are shown by
`.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -sr'`.

| From | To | Allowed? |
|---|---|---|
| PC 10.10.99.1 (LabHost) | firewall 10.10.99.2: SSH 22, HTTPS 443 (web GUI and REST API), DNS 53 (UDP and TCP), ping | yes, one pass rule each on the HOST interface, only from 10.10.99.1 and only to 10.10.99.2 |
| PC 10.10.99.1 (LabHost) | firewall 10.10.99.2: any other port, including HTTP 80 (the GUI's HTTP -> HTTPS redirect is switched off) | no |
| PC (LabHost) | published address 10.10.99.3: TCP 443, TCP 80, TCP 7881, UDP 7882 | yes, forwarded (port forward / DNAT) to the same ports on matrix 10.10.10.30 |
| PC (LabHost) | published address 10.10.99.4: TCP 443 | yes, forwarded to keycloak 10.10.10.40 |
| PC (LabHost) | published address 10.10.99.5: TCP 8200, TCP 80 | yes, forwarded to vault 10.10.10.50: 8200 to OpenBao (API, web UI, ACME), 80 to nginx (CA certificates and CRLs only) |
| PC (LabHost) | published addresses: anything else, including DNS, SSH and Matrix federation 8448 | no |
| PC (LabHost) | ansible-control, matrix, keycloak, vault directly | no. Use SSH through the firewall (jump host) |
| Default Switch (WAN) | firewall | no. There is no pass rule on WAN, so pf's default applies. Vagrant does not use this side |
| Lab VMs (LabNet) | firewall at 10.10.10.1 | yes, every port (DHCP, DNS, SSH and GUI/API for ansible-control; a lab shortcut, see [section 10](#10-security-notes)) |
| Lab VMs (LabNet) | internet | yes, behind the firewall's WAN address (automatic outbound NAT) |
| Lab VMs (LabNet) | HOST network 10.10.99.0/24: the PC at 10.10.99.1 and the firewall's HOST side (.2 to .5) | no, blocked and logged by the first LAN rule |
| Lab VMs (LabNet) | WAN network (the Hyper-V Default Switch subnet), which includes your PC's Default Switch address | no, blocked and logged by the second LAN rule (otherwise the lab could reach Windows services on the PC through outbound NAT) |
| Lab VM | other lab VM (for example MAS on matrix to Keycloak's 443; ansible-control and Traefik to OpenBao's 8200; OpenBao to Traefik's 80 for the ACME challenge) | yes. Same switch, so this traffic never passes the firewall. (SSH logins between lab VMs are refused by sshd itself, except from ansible-control: `AllowUsers` in [provision/harden-ssh.sh](provision/harden-ssh.sh)) |
| firewall itself | internet | yes (upstream DNS, OPNsense updates) |
| Anything else | anything | blocked (pf default deny) |

This state was checked from the PC on 2026-10-23: 10.10.99.2 answers only on
22, 53 and 443; 10.10.99.3 on 80, 443 and 7881 (and UDP 7882); 10.10.99.4 only
on 443; the lab VMs reach neither the PC nor the firewall's HOST side, and they
reach the internet. 10.10.99.5 was added later: it answers on 8200 and 80, as
the checks at the end of `Deploy-LabVault.ps1` show; the full port check was not
repeated for it.

Besides the rules in the template, OPNsense adds some by itself: the DHCP rules
on LAN (`default_fw_rules` in the dnsmasq section) and one filter rule for each
port forward ("register rule", `<pass>rule</pass>`). Ping from the PC works only
to 10.10.99.2. Nothing is forwarded to a lab VM except the published ports, so
ping from the PC to a lab VM or to a published address gets no answer.

The PC rules name the single address 10.10.99.2 as destination, not "HOST
address": in pf that would mean every address on the interface, the published
virtual IPs included, so DNS would answer there too (dnsmasq listens on every
address; the GUI and SSH do not listen on the virtual IPs at all, see
[P8](#p8-the-firewall-answers-dns-on-a-published-address)).

The anti-lockout rule OPNsense normally adds is switched off on purpose
(`noantilockout` in `<webgui>`). That is a hidden rule on the first interface
(here LAN) that passes SSH and HTTPS to every firewall address, ahead of all
other rules, so it would let the lab reach the firewall's HOST side, which the
first LAN rule blocks
([P9](#p9-lab-vms-reach-the-firewalls-management-through-the-anti-lockout-rule)).
Instead, every management path is a visible rule in the template that you can
review. The price: a wrong GUI change to the HOST rules can lock you out of the
GUI and SSH. The way back in is the console (Hyper-V Manager > Connect, user
`root`; `.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password` copies the
password to the clipboard, and the console window's Clipboard > Type clipboard
text types it), which no firewall rule can block, or a rebuild from the repository
(`.\scripts\New-LabFirewall.ps1 -Rebuild`). Enterprise equivalent: management
access is an explicit, reviewed rule, and out-of-band console access is the way
back in when it breaks.

---

## 3. Prerequisites

- **Windows 10 or 11 Pro/Enterprise/Education with Hyper-V enabled.** Windows
  Home has no Hyper-V. Hardware virtualization must be on in the firmware.
- **RAM**: the five VMs use 19 GB together: firewall 3 GB, ansible-control
  2 GB, matrix 8 GB, keycloak 4 GB, vault 2 GB. The sizes are fixed. The Ubuntu
  VMs' sizes (`cpus`, `memory` in MB) are set in [config/lab.json](config/lab.json).
  The firewall has static memory (FreeBSD does not support Hyper-V Dynamic
  Memory); for the Ubuntu VMs the Vagrantfile sets `maxmemory` equal to
  `memory`, so Dynamic Memory gets the same minimum and maximum and a VM never
  takes more host RAM than its size. 32 GB on the host is comfortable; with
  24 GB, little else can run. Measured right after a deployment, the Matrix
  stack used about 1.3 GB of the matrix VM's 8 GB and the keycloak VM about
  1.2 GB of its 4 GB (the Keycloak container is limited to 2 GB, its database
  to 512 MB), so on a smaller host you can lower `memory` for these two in
  `config/lab.json`.
- **Vagrant 2.4.x** on `PATH`, for the four Ubuntu VMs. The lab was developed
  with 2.4.9 and the built-in `hyperv` provider.
- **Git for Windows**, installed in its default folder. The PC's scripts use its
  OpenSSL from `C:\Program Files\Git\mingw64\bin`: the firewall build for the
  image signature check, the password hashes and the first GUI key and request,
  and `New-LabRootCA.ps1` for the offline root CA, which signs the intermediate
  CA, OpenBao's certificate and the firewall's GUI certificate. The firewall
  build also uses its bzip2 (unpacking the image). Both scripts stop with a hint
  if a tool is missing.
- **Windows OpenSSH client** (`ssh`, `scp`, `ssh-keygen`, `ssh-keyscan`),
  `tar.exe` and `curl.exe`. All are part of current Windows 10/11. The lab was
  developed with OpenSSH 8.1. The scripts call `ssh-keygen` and `ssh-keyscan`
  by their path in `C:\Windows\System32\OpenSSH`, and the Vagrantfile names
  that `ssh.exe` in its proxy command: Vagrant and Git for Windows bring
  OpenSSH clients of their own, and the lab is tested with Windows' one.
- **An elevated PowerShell** ("Run as administrator") for everything that
  manages Hyper-V or Windows networking: `Install-LabHostNetwork.ps1`,
  `Initialize-Lab.ps1`, `New-LabFirewall.ps1`, `Remove-Lab.ps1` and `vagrant`
  itself. (`Initialize-Lab.ps1` on
  its own would also accept membership in the local group "Hyper-V
  Administrators", but the firewall build it calls needs a real elevated shell,
  because of Hyper-V and the VM's serial console pipe; reading the VMs' SSH host
  keys from Hyper-V needs it too.)
  `Connect-Lab.ps1`, `Invoke-LabPlaybook.ps1`, `Install-LabRootCA.ps1`,
  `Deploy-LabVault.ps1`, `New-LabRecoveryKit.ps1`, `Deploy-LabKeycloak.ps1`,
  `Deploy-LabMatrix.ps1`, `Update-LabMdad.ps1`, `Show-LabSecret.ps1`,
  `Unlock-LabVault.ps1`, `Backup-LabVault.ps1` and
  `Update-LabSshCertificate.ps1` need no administrator rights. The scripts are
  written for Windows PowerShell 5.1, the version built into Windows.
- **One Windows account for everything.** The secrets on the PC are encrypted
  with DPAPI for the Windows account that created them, and only that account
  can decrypt them. "Run as administrator" keeps your account when it is itself
  a member of the Administrators group, so elevated and normal windows share
  the secrets. If elevation asks for the credentials of a different account,
  the secrets created there belong to that account, and your normal windows
  cannot read them.
- **Storage**: by default everything large goes to `G:\Vagrant`. Without a G:
  drive, pass `-StorageRoot`, e.g. `.\scripts\Initialize-Lab.ps1 -StorageRoot D:\Vagrant`.
  A fully deployed lab used about 20 GB there (Vagrant box cache 3.8 GB,
  OPNsense image cache 2.7 GB, the Ubuntu VMs' disks about 8 GB, the firewall
  and the Hyper-V files about 4.5 GB), measured before the vault VM was added;
  it is one more linked clone of the same box. Plan for at least 30 GB of free
  space: the disks grow with chat data, uploaded files and new container
  images.
- **A short project path without spaces**, for example
  `C:\Users\<name>\Documents\Python\DeployableServer`. The Vagrantfile passes
  the path of `keys/ssh_config` unquoted to `ssh.exe` in its proxy command, and
  the SSH helpers in `LabSsh.ps1` refuse paths with spaces in ssh options
  (Windows PowerShell 5.1 cannot pass the quotes they would need). And the
  longest file path inside `vendor\mdad` is about 140 characters, so the
  project folder's own path should stay below about 100 characters, or Windows'
  260-character path limit can stop the copying and unpacking of `vendor\mdad`
  ([P51](#p51-copying-or-unpacking-vendormdad-fails-in-a-deep-project-folder)).
- **Internet access** for the Vagrant box, Ubuntu packages and PyPI (Ansible);
  for the OPNsense image and updates from `pkg.opnsense.org`; for OpenBao's
  package repository (`pkgs.openbao.org`, signing key from `openbao.org`); and,
  for the applications, Docker's package repository (`download.docker.com`)
  and the container registries Docker Hub, quay.io (Keycloak) and ghcr.io
  (Synapse, MAS, Element, the LiveKit JWT service). GitHub is needed only to
  upgrade MDAD (`Update-LabMdad.ps1` fetches MDAD and its roles from there);
  a deployment takes them from the repository.
- **Free address ranges**: your home network must not already use 10.10.10.0/24
  or 10.10.99.0/24.
- **A browser on the PC**: Edge or Chrome (they use the Windows certificate
  store directly; Firefox needs one setting, see Step 4). For the call test you
  need two separate browser profiles, see Step 8.
- **For the recovery kit** (Step 5): a password manager (or paper) for one
  OpenBao key share, and a place for the recovery file that does not depend on
  this PC alone, such as a NAS share or a USB stick (copies of OpenBao's
  snapshots can go there too: `.\scripts\Backup-LabVault.ps1 -Destination <folder>`).
  Building the lab does not need either; they matter only if your Windows
  profile is ever lost.

If PowerShell refuses to run the scripts because of the execution policy, allow
them for the current window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

---

## 4. Quick start

Open PowerShell as administrator and change to the project folder. Run every
command from there.

```powershell
cd C:\path\to\DeployableServer
```

The order for a new lab:

| Step | Command | What it does / who runs it | Time |
|---|---|---|---|
| 1 | `.\scripts\Install-LabHostNetwork.ps1` | creates the host network and the DNS rule; you, once per PC (changes Windows) | seconds |
| 2 | `.\scripts\Initialize-Lab.ps1` | builds the firewall (and with it the offline root CA) and the Ubuntu VMs | the first run takes longest: it downloads the Vagrant box and the OPNsense image and provisions four VMs; the firewall build alone takes about 4 minutes |
| 3 | `.\scripts\Deploy-LabVault.ps1` | deploys OpenBao on the vault VM: secrets manager and intermediate CA | a few minutes on the first run (not timed exactly) |
| 4 | `.\scripts\Install-LabRootCA.ps1` | makes Windows trust the lab's root CA; you, once per PC (changes Windows) | seconds |
| 5 | `.\scripts\New-LabRecoveryKit.ps1 -Destination <folder>` | hands you OpenBao key share C and writes the encrypted recovery file (key share B, a break-glass login for OpenBao, the root CA, the offline SSH CA, the firewall's passwords); you, once, in a console window you type into yourself (it shows secrets) | a few minutes |
| 6 | `.\scripts\Deploy-LabKeycloak.ps1` | deploys Keycloak, the identity provider | about 1 minute on the first run |
| 7 | `.\scripts\Deploy-LabMatrix.ps1` | deploys the Matrix stack, the chat | about 5 minutes |
| 8 | Browser test: sign in, chat, call | manual test, by you | a few minutes |

Steps 1, 4 and 5 are yours on purpose: Steps 1 and 4 change Windows settings
(networking, trusted certificates), and Step 5 shows secrets on the screen. They
run in the same PowerShell window as the others, as long as it is a window you
type into yourself, not another program's.

### Step 1: create the host network (once, you run it yourself)

```powershell
.\scripts\Install-LabHostNetwork.ps1
```

This changes Windows network settings, so it is a separate script that you run
on purpose. It:

1. creates the Internal Hyper-V switch `LabHost` (Windows gets the adapter
   `vEthernet (LabHost)`)
2. gives that adapter the fixed IP `10.10.99.1/24`, with no gateway, so your
   internet connection and home network stay unchanged
3. adds an NRPT rule so Windows asks `10.10.99.2` (the firewall) only for
   `lab.internal` and the names below it

Undo everything with `.\scripts\Install-LabHostNetwork.ps1 -Remove`.

### Step 2: build the lab

```powershell
.\scripts\Initialize-Lab.ps1
```

Without a G: drive, name another folder:
`.\scripts\Initialize-Lab.ps1 -StorageRoot D:\Vagrant`.

The first run downloads the Vagrant box and the OPNsense image and takes a
while. Before it changes anything, the script checks that it has Hyper-V rights
and that Step 1 is done (switch `LabHost` and the NRPT rule exist); otherwise it
stops with a hint. Then it runs seven steps (`== 1/7 ...` and so on in its
output). You can run it again at any time:

1. **Storage**: sets `VAGRANT_HOME` (box cache) permanently for your user, if it
   is not set yet. It makes `vagrant\.vagrant` a junction to the storage drive
   (VM disks). The junction is only created while no VM exists yet; VMs already
   stored in a real `.vagrant` folder stay there, and the script warns.
2. **SSH**: creates the offline SSH CA (`keys\ssh\offline-ca`, its key
   encrypted, the passphrase with DPAPI) and this PC's SSH key
   (`keys\ssh\pc_ed25519`) if they are missing
   ([scripts/New-LabSshCa.ps1](scripts/New-LabSshCa.ps1); it also repairs the
   file permissions of the keys and of the `keys\` folder with `icacls` on
   every run), renders the files that say which SSH CAs to trust
   (`keys\ssh\lab_user_ca.pub`, `known_hosts`, `firewall_authorized_keys`),
   and writes `keys\ssh_config` (firewall at 10.10.99.2, all other VMs through
   it; logins with the PC's short-lived certificate, host keys accepted only
   with a host certificate). Logins in the lab use SSH certificates instead of
   a shared key, and host keys are checked instead of trusted on first use:
   [SSH certificates](#ssh-certificates-user-and-host-cas).
3. **LabNet**: creates the Private switch `LabNet` if it is missing.
4. **Firewall**: first, if they exist, the firewall and the vault VM are
   started directly in Hyper-V and OpenBao is unsealed, over HTTPS, before any
   SSH: once OpenBao is deployed, it signs the SSH certificates, and after a
   Windows restart the PC's certificate (8 hours) has expired. Then the step
   runs [scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1).
   If the firewall VM does not exist yet, that script builds it:
   - downloads the official OPNsense 26.7 nano image once into
     `G:\Vagrant\images\opnsense\26.7`, checks it against a pinned SHA-256 hash
     and OPNsense's signatures, unpacks it and converts it to a VHDX
   - creates random passwords for `root` and `ansible` and an API key, and
     stores them encrypted with DPAPI in `keys\opnsense\` (see
     [Where secrets and certificates come from](#where-secrets-and-certificates-come-from)).
     The firewall's configuration gets only their SHA-512-crypt hashes, made by
     Git's `openssl passwd -6`; the password goes to OpenSSL on its standard
     input, never on its command line, where other programs on the PC could
     read it
   - creates the lab's offline root CA in `keys\pki` if it does not exist yet
     ([scripts/New-LabRootCA.ps1](scripts/New-LabRootCA.ps1)), and has it sign
     the GUI certificate for `firewall.lab.internal`. The firewall is built
     before OpenBao exists, so the root signs this certificate itself
   - renders the configuration from `opnsense\config.xml.template` and
     `config\lab.json` (DHCP reservations and DNS names of the VMs, and from
     `published`: virtual IPs, port forwards and the published names), checks
     it, and packs it into a small ISO. The rendered file holds password hashes
     and the GUI's private key, so it is never stored in `keys\`: its staging
     folder is deleted as soon as the ISO is written, and the ISO when the first
     boot is over, also when that boot failed (a later run removes one left
     behind)
   - creates the VM (Generation 1, 1 vCPU, 3 GB) with all network adapters
     disconnected, boots it, and answers OPNsense's configuration importer over
     the serial console, so that the firewall starts with the lab configuration;
     only then are the adapters connected (how:
     [Automating an appliance's first boot over the serial console](#automating-an-appliances-first-boot-over-the-serial-console))
   - sets up SSH before anything else is done over it: the host key the
     firewall presents must have the fingerprint that OPNsense printed on its
     serial console during the first boot; that key gets a host certificate,
     and an sshd drop-in limits the jump host to SSH of the lab VMs. From then
     on every connection checks the firewall's host certificate
   - logs in over SSH, checks that `hn0`/`hn1`/`hn2` are the right adapters,
     installs the
     [split-horizon DNS](#split-horizon-dns-and-conditional-forwarding) drop-in,
     and updates OPNsense to at least 26.7.7, with a reboot for the new kernel
   - waits until the web GUI answers on port 443 (it starts after SSH), checks
     the certificate it serves from the PC, and renews it in place when fewer
     than 30 days are left or it does not come from the root CA: the firewall
     makes a new key and a CSR, only the CSR travels to the PC, and the signed
     certificate goes back

   If the firewall already exists, nothing is rebuilt: a seed ISO left behind
   (the script was killed during the first boot, or deleting it failed) is
   removed, the firewall is started (if it is off), its SSH setup is applied
   again (a new host certificate when the current one is due, the sshd drop-in,
   the SSH CAs that user `ansible` accepts),
   the DNS drop-in is installed again, it is updated only if a part of
   OPNsense is still below 26.7.7, and the GUI certificate is renewed in place
   when it is due. Either way the script ends with DNS checks from the PC:
   `firewall.lab.internal` -> 10.10.99.2, and the first name of every published
   entry -> its published address (`matrix.lab.internal` -> 10.10.99.3,
   `keycloak.lab.internal` -> 10.10.99.4, `vault.lab.internal` -> 10.10.99.5).
   If the very first build fails, see
   [P4](#p4-the-configuration-importer-does-not-take-the-lab-configuration): a
   half-built firewall needs `-Rebuild`, not a plain re-run.
5. **Lab VMs**: starts ansible-control, matrix, keycloak and vault with Vagrant
   (the list comes from `config/lab.json`), moves their Hyper-V files, and
   provisions them (user `ansible`; SSH: own host keys, published to the PC
   through Hyper-V KVP, trust in the lab's SSH CAs, certificate logins only;
   console autologin except on vault, zsh, Ansible and an SSH key of its own on
   the control node). Then every VM gets its SSH host certificate: signed for
   exactly the host key the VM published, and installed over a connection that
   accepts only that key. If OpenBao was
   initialised before (a re-run, for example after a Windows restart), it is
   unsealed now with `Unlock-LabVault.ps1`, unless step 4 has done that already;
   on a new lab that comes in Step 3.
   If OpenBao's TLS certificate has fewer than 30 days left, or has already
   expired (after weeks without a run), the script runs `Deploy-LabVault.ps1`
   instead: the pinned TLS check would refuse an expired certificate, so the
   unseal itself would fail, and `Deploy-LabVault.ps1` renews the certificate
   over SSH first and then unseals.
6. **Tests**: DNS from the PC, SSH to every VM with the PC's certificate,
   checking every host certificate (the firewall answers with its OPNsense
   version), and the Ansible playbook `ping.yml` against all hosts, the
   firewall included, which ansible-control reaches with its own key and a
   certificate for this run. On new VMs, Ansible warns once per VM:
   `[WARNING]: Module remote_tmp /root/.ansible/tmp did not exist and was created with a mode of 0700, ...`.
   It appears because pipelining is on (see
   [Where secrets and certificates come from](#where-secrets-and-certificates-come-from)),
   and it is harmless: the folder belongs to root, the user the playbooks
   switch to with sudo, and nobody else needs it.
7. **Maintenance**, only once OpenBao has been deployed (so not yet on a new
   lab): renewals that are due. `Get-LabMaintenanceDue` in
   [scripts/LabSecrets.ps1](scripts/LabSecrets.ps1) checks, from public
   information only (no login): OpenBao's TLS certificate (due 30 days before
   it expires), the root CA's revocation list (60 days before its next update,
   and also when the copy the vault VM serves differs from the PC's: a
   `New-LabRootCA.ps1` call made only to sign something, the firewall's GUI
   certificate for example, also renews the list when it has fewer than 60 days
   left, but only `Deploy-LabVault.ps1` publishes it), the
   intermediate CA (400 days before it expires) and Keycloak's certificate
   (30 days). For each one it prints `Maintenance: <what> is due -> <script>` and
   runs `Deploy-LabVault.ps1` and/or `Deploy-LabKeycloak.ps1`; otherwise
   `Maintenance: no certificate or revocation list is due`. The firewall's GUI
   certificate was checked in step 4, and Traefik renews the Matrix
   certificates itself.

Once OpenBao signs the SSH certificates, a vault VM that does not come up stops
the script with the reason and the ways out: the offline SSH CA does not take
over by itself, so that blocking OpenBao never moves signing out of its audit
log. If OpenBao is really broken, `.\scripts\Initialize-Lab.ps1 -BreakGlass`
lets the offline SSH CA sign for this run (break-glass, see
[SSH certificates](#ssh-certificates-user-and-host-cas)).

Building the firewall takes about four minutes once the image is cached. The
OPNsense image (about 490 MB) is downloaded and converted only once; later
builds reuse it. The progress is printed line by line, and the first boot is
logged in `G:\Vagrant\hyperv\firewall\logs\serial-console.log`. The long
quiet phases follow the `Version:` lines: the package update after the line
ending in `updating packages (this takes a few minutes) ...`, the base system
and kernel after `... updating base system and kernel ...`, and the reboot
after `Version:     rebooting into the new kernel (...) ...`. A line
`Version:     attempt 1 of 3 failed: ...` is an automatic retry, not an error
(see [P5](#p5-the-firmware-update-fails-with-fetch-transfer-timed-out)). A
successful first build of the firewall ends like this (the update lines in the
middle are shortened; versions may be newer):

```
Adapters:    hn0 = WAN, hn1 = LAN, hn2 = HOST (checked by MAC)
DNS:         split-horizon drop-in installed, dnsmasq restarted
Version:     core 26.7, updating packages (this takes a few minutes) ...
...
Version:     core 26.7.7, base 26.7.7, kernel 26.7.7
Certificate: firewall.lab.internal valid (lab root CA, more than 30 days left)
Check:       firewall.lab.internal -> 10.10.99.2 (PC view)
Check:       matrix.lab.internal -> 10.10.99.3 (PC view, published)
Check:       keycloak.lab.internal -> 10.10.99.4 (PC view, published)
Check:       vault.lab.internal -> 10.10.99.5 (PC view, published)
Firewall ready: https://firewall.lab.internal (user root; password to the clipboard: .\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password)
```

The GUI user is `root`. Its password is generated once, stored with DPAPI, and
stays the same when the firewall is rebuilt;
`.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password` copies it to the
clipboard (this works from now on: it reads the PC's DPAPI store, not OpenBao).

The whole run succeeded when it prints an `SSH ok: ...` line for each of the
five VMs, then a `PLAY RECAP` in which ansible-control, firewall, keycloak,
matrix and vault all show `unreachable=0` and `failed=0`, and finally:

```
Done. Log in with:  .\scripts\Connect-Lab.ps1  (or: .\scripts\Connect-Lab.ps1 matrix / keycloak / vault / firewall)
Next: .\scripts\Deploy-LabVault.ps1 (OpenBao), .\scripts\Install-LabRootCA.ps1 (once per PC), .\scripts\New-LabRecoveryKit.ps1 (in your own window),
      then .\scripts\Deploy-LabKeycloak.ps1 and .\scripts\Deploy-LabMatrix.ps1 (Element: https://element.lab.internal)
```

The two `Next:` lines appear only while OpenBao has not been deployed; on later
runs step 7 comes before `Done.` instead. At this point the VMs are ready but
empty: OpenBao comes in Step 3, the applications in Steps 6 and 7.

### Step 3: deploy OpenBao (secrets and certificates)

```powershell
.\scripts\Deploy-LabVault.ps1
```

OpenBao is the open source fork of HashiCorp Vault, maintained under the Linux
Foundation with the MPL 2.0 licence (Vault itself has been under the Business
Source License since 2023). In this lab it is the secrets manager and runs the
intermediate certificate authority, so every later step depends on it: Keycloak
and the Matrix stack get their secrets and their certificates from it. The
script runs on your PC as your user (no administrator rights needed); it talks
to the vault VM over SSH and to OpenBao's API over HTTPS. It runs eight steps,
each of which checks first and then acts only if needed:

1. **Offline root CA**: created if it is missing (normally the firewall build
   has done that in Step 2); its revocation list is renewed when fewer than
   60 days are left ([scripts/New-LabRootCA.ps1](scripts/New-LabRootCA.ps1)).
2. **OpenBao's own TLS certificate** for `vault.lab.internal`: the key and a CSR
   are made on the vault VM, the root signs the CSR on the PC (397 days), and
   the certificate goes back. The key never leaves the VM. On later runs the
   certificate is renewed the same way when fewer than 30 days are left, and
   the script reloads OpenBao (`systemctl reload`): it reads the new
   certificate without a restart, so it stays unsealed.
3. **Package and configuration**:
   [ansible/playbooks/openbao.yml](ansible/playbooks/openbao.yml) installs
   OpenBao 2.7.1 from its package repository (the repository's signing key is
   checked against a pinned fingerprint, the package is held at that version),
   writes its configuration (raft storage, TLS listener, audit log with log
   rotation), and sets up nginx on port 80 for the CA certificates and CRLs.
4. **Initialisation**, only the very first time: OpenBao creates the key that
   encrypts all its data and splits the key that protects it into three key
   shares (Shamir's secret sharing: any two of them unlock it, one alone
   reveals nothing). Shares A and B are stored with DPAPI in `keys\openbao`;
   share C waits there, DPAPI-protected too, until Step 5 hands it to you.
   No key share and no token is printed, only a status line.
5. **Unseal** with shares A and B.
6. **Configuration through the API**, applied again on every run, so the script
   stays the description of the truth: the secrets engine `lab` (key/value,
   every write must name the version it expects), password policies (OpenBao
   generates the lab's passwords: letters and digits, 24 to 64 characters), one
   access policy per consumer, the AppRoles (logins for machines) `pc-admin`
   and `pc-deploy` for the PC's scripts (credentials stored with DPAPI; a
   missing one gets a new secret, and once that is stored, every older secret
   of that role is destroyed), the break-glass AppRole `recovery` (administrator rights like
   `pc-admin`, but its secret exists only in the recovery file of Step 5), all
   three accepted only from 10.10.99.1, the token role `ansible-run` for
   Ansible's run tokens, and the PKI: the intermediate CA (key generated inside
   OpenBao, certificate signed by the offline root; on an empty OpenBao it is
   named `lab-int-<year>`, "DeployableServer Lab Intermediate CA <year>"), its
   CRL and the URLs it writes into every certificate, the roles `keycloak`,
   `acme-matrix` and `web`, and ACME for the role `acme-matrix` only. And the
   SSH secrets engine `ssh`: an SSH CA whose key is generated inside OpenBao
   (once; it is never replaced by a re-run) and the roles `pc`,
   `ansible-control` and `lab-hosts`, made from the same table the offline SSH
   CA uses (`$LabSshRoles` in [scripts/LabSsh.ps1](scripts/LabSsh.ps1)).
7. **End of the bootstrap**: as soon as a `pc-admin` login works, the initial
   root token (OpenBao's all-powerful first token) is revoked and its file
   deleted. From then on nobody holds a root token; administration uses
   `pc-admin`.
8. **SSH CA in use**, once: OpenBao's SSH CA public key goes to every machine
   (the firewall, the VMs, the PC's and ansible-control's `known_hosts`), a
   login with a throwaway 10-minute certificate from OpenBao is tried on each
   of them, and only when all pass does OpenBao take over signing from the
   offline SSH CA (`keys\ssh\openbao-ca.trusted`). Until then the offline CA
   keeps signing, so a machine that is off or misses the new CA locks nobody
   out; the script says which machine failed, and a later run tries again.

**Certificate pinning, for OpenBao's address only.** The PC's scripts accept
OpenBao's certificate only when its chain ends exactly at the lab root in
`keys\pki\root-ca.crt`, whatever else Windows trusts. That is why this step
works before Windows trusts the lab root (Step 4). Every other HTTPS address
keeps Windows' normal validation. Why and how:
[Internal PKI](#internal-pki-certificate-authority).

A successful first run ends with:

```
Check:       intermediate CA served, ACME directory https://vault.lab.internal:8200/v1/pki_int/roles/acme-matrix/acme/directory, root CRL on port 80

OpenBao is ready:  https://vault.lab.internal:8200/ui/
PENDING: key share C and the recovery file. Run in your own PowerShell window:  .\scripts\New-LabRecoveryKit.ps1
```

The `PENDING` line is repeated on every run until Step 5 is done. (On a lab
whose recovery file was made before the break-glass login existed, a different
reminder appears instead and asks for a new file: `PENDING: your recovery file has no break-glass
login ...`, and on a lab whose recovery file holds no copy of the current
offline SSH CA, `PENDING: your recovery file has no copy of the current offline
SSH CA ...`; see [Renew the recovery kit](#renew-the-recovery-kit).) The web UI
opens without a warning after Step 4, but there is no personal login for it
yet: administration goes through the scripts (single sign-on with Keycloak for
the UI is on the [roadmap](#11-roadmap)).

**Running it again** is how OpenBao is maintained: it renews what is due (the
root CA's revocation list, OpenBao's TLS certificate) and makes a new
intermediate CA when the current one expires within 400 days. `Initialize-Lab.ps1`
starts it by itself when one of these is due (its step 7). To make a new
intermediate now, for example to try the rotation described in
[Rotate the intermediate CA](#rotate-the-intermediate-ca):

```powershell
.\scripts\Deploy-LabVault.ps1 -RotateIntermediate
```

Its `PKI:` line then reads `intermediate CA created in OpenBao, signed by the
offline root (...)`. Afterwards run `Deploy-LabKeycloak.ps1` and
`Deploy-LabMatrix.ps1`, which move their certificates to the new intermediate.

**OpenBao is sealed after every start of the vault VM.** Its data stays
encrypted, and it does not know the key until two key shares are presented
again. `Initialize-Lab.ps1` (for example after a Windows restart) and
`Invoke-LabPlaybook.ps1` (before a playbook that needs OpenBao) unseal it by
themselves with shares A and B; by hand it is `.\scripts\Unlock-LabVault.ps1`.
While it is sealed, nothing that needs it works: deployments, Traefik's
certificate renewals, and the intermediate CA's revocation list on port 80.

On a lab whose vault VM was rebuilt, the script refuses to initialise the new
OpenBao while `keys\openbao` still holds the key shares of the old one: they may
be the only way to restore a snapshot of it. `Remove-Lab.ps1` takes a last
snapshot before it deletes the vault VM, then moves `keys\openbao` (key shares,
logins and snapshots) to `keys\openbao-retired-<yyyyMMdd-HHmmss>` (details in
[Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)). How a
snapshot is restored:
[Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).

### Step 4: trust the lab root CA (once, you run it yourself)

```powershell
.\scripts\Install-LabRootCA.ps1
```

This imports `keys\pki\root-ca.crt`, the lab's root certificate "DeployableServer
Lab Root CA 2026", into the trusted root store of **your Windows user** (not the
whole machine). The file exists from Step 2 on: the firewall build created the
root. Windows shows a security warning with the certificate's thumbprint (the
script prints it first, so you can compare); confirm with "Yes". Then restart
the browser. No administrator rights are needed. Trusting the root once is
enough for every lab certificate, including those issued later by the
intermediate CA or, after a rotation, by its successor. Edge and Chrome use
this store directly. Firefox uses it only if
`security.enterprise_roots.enabled` is `true` in `about:config` (the default in
Firefox 120 and later on Windows); otherwise set it, or import
`keys\pki\root-ca.crt` in Firefox itself under Settings > Privacy & Security >
Certificates > View Certificates > Authorities. Undo with `-Remove`.

If you built the lab before its two-level PKI existed, Windows may still trust
the retired first lab CA ("DeployableServer Lab CA"); the script then says so.
Take that trust back with:

```powershell
.\scripts\Install-LabRootCA.ps1 -RemoveRetired
```

On a new lab there is nothing to remove.

Do this before Step 7: `Deploy-LabMatrix.ps1` ends with checks that call
`https://matrix.lab.internal` from the PC with `curl.exe`, which uses the
Windows certificate store. If you skipped it, `Deploy-LabMatrix.ps1` stops with
`Synapse does not report MAS (...) as its issuer (got '')`: `curl.exe` rejected
the certificate without printing why (it runs with `-s`). Run
`Install-LabRootCA.ps1` and start the script again. Windows also checks
revocation for these certificates: every lab certificate names the revocation
list (CRL) of its CA on `http://vault.lab.internal/...`, so `curl.exe` works
with lab sites without `--ssl-no-revoke`.

The firewall's web GUI is now at <https://firewall.lab.internal>. Log in as
`root`; `.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password` copies the
password to the clipboard. Worth a look: Firewall > Rules (the template's filter
rules; choose the interface, LAN, HOST or WAN, in its interface selector),
Interfaces > Virtual IPs (the published addresses), Firewall > NAT > Destination
NAT (the port forwards), Services > Dnsmasq DNS & DHCP > Hosts (reservations and
published names), and System > Firmware (version and updates). Changes you make
in the GUI take effect at once, but they are not written back to this
repository and are lost when the firewall is rebuilt (see
[section 6](#6-how-to-)).

### Step 5: make the recovery kit (once, you run it yourself)

```powershell
.\scripts\New-LabRecoveryKit.ps1 -Destination Z:\DeployableServer-recovery
```

`-Destination` is the folder for the recovery file, for example a NAS share or a
USB stick (a relative path works too; the drive must exist, the folder is
created). Without `-Destination` the file goes to `keys\recovery` on this PC,
and you copy it somewhere else yourself.

**Why.** OpenBao's key shares A and B, the PC's OpenBao logins and the other
secrets on the PC are protected with DPAPI, so by your Windows account. If that
account's keys are lost (Windows reinstalled, the profile lost, the password
reset by an administrator), the `.dpapi` files can no longer be decrypted. Two
things would then be gone: the key shares that unseal OpenBao, and every way to
log in to it as administrator (the initial root token was revoked in Step 3,
and `pc-admin`'s credentials were only in DPAPI). Key shares alone no longer
make anyone an administrator in OpenBao (since version 2.5.3, see
[Break-glass: the recovery kit](#break-glass-the-recovery-kit)), so the lab
keeps its own way back in, the break-glass login. The recovery kit covers the
loss without weakening the daily setup:

- **Key share C**, which you keep: in your password manager, or written down.
- **A recovery file** with key share B, the break-glass login for OpenBao (the
  AppRole `recovery`, with administrator rights, accepted only from your PC's
  address; its secret exists nowhere else), the root CA's key (still encrypted)
  with its passphrase, the root certificate, the offline SSH CA's key (still
  encrypted) with its passphrase, the firewall's passwords and API key, and a
  fingerprint (SHA-256) of share C that catches typing errors later,
  all encrypted with a passphrase you choose (AES-256 with an HMAC-SHA256
  integrity check; the key is derived from the passphrase with PBKDF2, 600,000
  iterations).

Day to day, OpenBao is unsealed with A and B from DPAPI. After a loss, B from
the file and C from you unseal it, and the break-glass login from the file lets
the script issue new logins for the PC. Neither the file nor share C unseals
OpenBao on its own (the file with its passphrase is, however, an administrator
login for a running OpenBao from your PC, and, through the offline SSH CA in it,
SSH access to every lab machine), so keep them in different places,
guard the passphrase as well as the file, and keep the file somewhere that
does not depend on this PC alone (a NAS share or a USB stick; for the lab, a NAS
is fine). Enterprise equivalent: "break-glass" material split between several
people and kept offline in separate places, and an emergency administrator
account whose use is rare, logged and followed by a new credential.

**What happens.** The script refuses to run when its output is redirected or
captured by another program, because it shows secrets: start it yourself in a
PowerShell window. Before it shows anything, it checks that the destination's
drive exists (a USB stick that is not plugged in) and that it can write there (a
write-protected stick, a read-only share), and it reads everything the file will
hold. Then:

1. It shows key share C. Store it, then type its last 6 characters to confirm;
   the screen is cleared.
2. It asks twice for the passphrase of the recovery file (at least 12
   characters). Remember it, or keep it in a third place.
3. It makes a new secret for the break-glass login.
4. It writes `DeployableServer-recovery-<date>.bin` into the destination
   folder, decrypts it again to verify it, and only then destroys every older
   secret of the break-glass login, so only the newest recovery file can log
   in. It shows the file's SHA-256 hash; note the hash next to share C, it
   identifies the right file.
5. After you type `yes`, it deletes the temporary DPAPI copy of share C from the
   PC. From then on share C exists only with you, and the script shows it no
   more.

Until you run it, share C waits on the PC (`keys\openbao\unseal-c-pending.dpapi`),
and `Deploy-LabVault.ps1` reminds you with its `PENDING` line. The script has
three more modes, for later:

| Command | When | What it does |
|---|---|---|
| `.\scripts\New-LabRecoveryKit.ps1 -Renew -Destination <folder>` | a new recovery file: after a `-Recover`, for a new passphrase, or when the file is lost | the same as above without steps 1 and 5: a new file with a new break-glass secret. Your share C stays valid and is not shown again. Older files can still unseal, but their break-glass login no longer works: keep only the new one |
| `.\scripts\New-LabRecoveryKit.ps1 -Open <file>` | to read the file | asks for the passphrase and shows share B, the root CA key's passphrase and the firewall's root password (the root CA files, the offline SSH CA, the break-glass login and the firewall's other secrets stay in the file, for `-Recover`) |
| `.\scripts\New-LabRecoveryKit.ps1 -Recover <file>` | after this PC's DPAPI keys were lost, in the same project folder | asks for share C, restores this PC's DPAPI secrets (and the root CA's and the offline SSH CA's files if missing), unseals OpenBao with B and C if needed and, with the break-glass login, issues NEW logins `pc-admin` and `pc-deploy`, so the scripts and `Unlock-LabVault.ps1` work again; step by step in [Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys). Then run `-Renew`: the break-glass secret has been used. (A file made before the break-glass login existed can only unseal) |

To unseal without restoring anything, `.\scripts\Unlock-LabVault.ps1 -Interactive`
asks for two key shares that you type in (B from `-Open`, and C). The concept
behind the kit is explained in
[Break-glass: the recovery kit](#break-glass-the-recovery-kit); restoring
OpenBao's data from a snapshot is a different procedure, in
[Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).

### Step 6: deploy Keycloak (the identity provider)

```powershell
.\scripts\Deploy-LabKeycloak.ps1
```

It needs OpenBao (Step 3). It runs
[ansible/playbooks/keycloak.yml](ansible/playbooks/keycloak.yml) on
ansible-control through `Invoke-LabPlaybook.ps1`, with a run token for the
policy `ansible-keycloak` (see
[Where secrets and certificates come from](#where-secrets-and-certificates-come-from)).
The playbook:

1. on ansible-control: trusts the lab root CA and reads Keycloak's secrets from
   OpenBao (`lab/keycloak/...`). On the very first run OpenBao generates and
   stores them. If Keycloak's database already exists on the VM but a secret is
   missing in OpenBao, the playbook stops instead: a new database password
   would not open the existing database;
2. on the keycloak VM: trusts the lab root CA, installs Docker CE from Docker's
   repository, gets Keycloak's TLS certificate (`keycloak.lab.internal`) from
   the intermediate CA (the key and the CSR are made on the VM, OpenBao signs
   the CSR, the key never leaves the VM; on later runs only when fewer than
   30 days are left or the certificate is not from the current intermediate),
   writes the Compose project to
   `/opt/keycloak-stack` and starts Keycloak and PostgreSQL, waits until
   Keycloak is ready and checks that it publishes the expected issuer under its
   real name;
3. configures Keycloak through its admin API, as code: the realm `lab`, the
   OIDC client `matrix-authentication-service` for MAS, and the users `alice`
   and `bob`.

After the playbook, also when it failed, the script takes a snapshot of OpenBao
([scripts/Backup-LabVault.ps1](scripts/Backup-LabVault.ps1), into
`keys\openbao\snapshots`, the newest 10 are kept): on a first run the playbook
has just generated Keycloak's secrets, and OpenBao is the only place they
exist. The secret values exist only in OpenBao (and its snapshots), in memory
during the run, and where Keycloak needs them: in the env files on the keycloak
VM and in Keycloak's own database. The first run took about a minute in this
lab; re-runs change nothing (`changed=0`) unless you changed something. It ends
with (date, time and size differ):

```
Snapshot: C:\path\to\DeployableServer\keys\openbao\snapshots\vault-20261024-125721.snap (64 KB)

Keycloak is ready:  https://keycloak.lab.internal/admin/  (admin console, user admin)
Lab users: alice and bob (realm lab). Passwords from OpenBao, copied to the clipboard:
  .\scripts\Show-LabSecret.ps1 keycloak/users/alice     (keycloak/users/bob, keycloak/admin)
Next: .\scripts\Deploy-LabMatrix.ps1
```

If the run fails, the script stops with Ansible's error for the failing task;
the usual causes are described in
[P23](#p23-a-task-keyword-between-module-parameters-breaks-the-task) to
[P26](#p26-the-same-image-tag-suddenly-means-a-different-image). A failed read
from OpenBao names the secret's path and the HTTP status: 503 means OpenBao is
sealed (`.\scripts\Unlock-LabVault.ps1`), 403 that the run token lacks the
policy or has expired. A secret that exists but lacks the expected field (for
example one written by hand under another field name) is named with its path
and the field. Fix the cause and run the same script again: it is idempotent,
and a failed run loses nothing, because every generated secret is stored in
OpenBao before anything uses it. If the snapshot fails, the script only warns
(`OpenBao snapshot failed: ...`); take one later with
`.\scripts\Backup-LabVault.ps1`.

On a lab that still has the plain-text file `keys\keycloak\secrets.yml` from
before OpenBao, the script first imports it unchanged into OpenBao
(`Import-LabSecrets.ps1`); on a new lab there is no such file. The file stays
on the PC until you remove it with `.\scripts\Import-LabSecrets.ps1 -RemovePlaintext`
(the import prints this hint); until then it is a plain-text secret file in
`keys\`, and every deployment imports it again (harmlessly: values
already in OpenBao are only compared).

### Step 7: deploy the Matrix stack

```powershell
.\scripts\Deploy-LabMatrix.ps1
```

It needs OpenBao (Step 3) and Keycloak (Step 6): MAS signs users in through
Keycloak with the client secret that Keycloak's deployment stored in OpenBao.
The script runs five steps:

1. **Secrets from before OpenBao**: only on a lab that still has
   `keys\matrix\secrets.yml` or `keys\keycloak\secrets.yml`; they are imported
   unchanged (`Import-LabSecrets.ps1`). On a new lab there is nothing to do.
   The files stay on the PC, and are imported again on every run, until you
   remove them with `.\scripts\Import-LabSecrets.ps1 -RemovePlaintext`.
2. **MDAD from the repository** (line `MDAD <commit> from the repository
   (vendor\mdad) to ~/mdad on ansible-control`): MDAD's code and its roles are
   kept in the repository at the pinned commit (`vendor\mdad`, see
   [vendor/README.md](vendor/README.md)). The script packs that folder with
   `tar`, copies it to ansible-control with `scp`, unpacks it into
   `~/mdad.new` and replaces `~/mdad` with it, the same pattern
   `Invoke-LabPlaybook.ps1` uses for `~/lab`. Nothing is downloaded from GitHub.
   It stops here, before anything is copied, when the commit in
   `vendor\mdad\.lab-vendored-commit` and `mdad_version` in `matrix-prepare.yml`
   differ, so the configuration can
   never meet another MDAD version than the one it was written for.
3. **Preparation**, [ansible/playbooks/matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml),
   with a run token for the policy `ansible-matrix`: the lab root CA in the
   trust stores of ansible-control and the matrix VM (MAS and the LiveKit JWT
   service are restarted when the VM's CA bundle changes, see
   [P30](#p30-mas-or-the-livekit-jwt-service-does-not-trust-the-lab-root-ca)), a
   check that `~/mdad` holds the pinned commit (its marker file
   `.lab-vendored-commit` must equal `mdad_version`), our inventory and the
   lab's entry point `lab-setup.yml` copied into `~/mdad`, `lab-shared.yml`
   written (issuer, client ID, provider ID and OpenBao's URL; no secrets), and
   the Matrix secrets present in OpenBao (generated on the very first run;
   refused, like Keycloak's, when the installation already exists). Then, from
   the matrix VM: DNS checks, and checks that Keycloak's discovery document and
   OpenBao's ACME directory are reachable and trusted. On a lab where Traefik
   already has certificates, it also compares the certificate Traefik serves
   with OpenBao's current intermediate (authority key identifier against
   subject key identifier). If it comes from an older lab intermediate (after a
   rotation, or after OpenBao was rebuilt), it deletes Traefik's ACME store
   `/matrix/traefik/ssl/acme.json` and restarts `matrix-traefik`, so Traefik
   registers with OpenBao's ACME server again and orders new certificates.
   After the preparation, also when it failed, the script takes a snapshot of
   OpenBao (`Backup-LabVault.ps1`, line `Snapshot: ...`): on a first run the
   Matrix secrets have just been generated, and OpenBao is the only place they
   exist.
4. **MDAD**, through [ansible/matrix/lab-setup.yml](ansible/matrix/lab-setup.yml)
   in `~/mdad` on ansible-control, with a new run token. MDAD expects its
   secrets as inventory variables; `lab-setup.yml` reads them from OpenBao into
   memory first and then runs MDAD's own `setup.yml`, so they are never written
   to disk on ansible-control (MDAD's own `ansible.cfg` switches pipelining on
   too, and `openbao-run`'s RAM folder applies here as well). It is called with
   the tags of MDAD's recipe `just install-all` (`just` is a command runner,
   similar to `make`; MDAD's `justfile`, in `vendor\mdad`, turns that recipe
   into `ansible-playbook -i inventory/hosts setup.yml --tags=install-all,ensure-matrix-users-created,start`).
   The script runs that command itself, with `lab-setup.yml` in place of
   `setup.yml`, so `just` is not installed in the lab. With `-Setup` it uses
   the tags of `just setup-all`, which also runs the uninstall tasks of
   components you switched off, and is slower. MDAD installs Docker on the
   matrix VM, pulls the images, writes all configuration, creates the systemd
   units `matrix-*.service` and starts them. Traefik then orders its
   certificates from OpenBao through ACME by itself.
5. **Checks**: from the PC, that Traefik serves a certificate from the
   current intermediate CA for each of the three names, compared by key
   identifier, not by name (it waits up to 3 minutes; until ACME has succeeded,
   Traefik answers with its own self-signed "TRAEFIK DEFAULT CERT"); MDAD's
   self-check, `mas-cli doctor`, and two further
   checks from the PC that can fail the script: Synapse's
   `https://matrix.lab.internal/_matrix/client/v1/auth_metadata` must name MAS
   (`https://matrix.lab.internal/auth/`) as issuer, and MAS's
   `/auth/upstream/authorize/<ULID>` must redirect to Keycloak. That redirect
   proves that the MAS container can resolve Keycloak, trusts the lab root CA
   and found the exact issuer.

The Matrix secrets are in OpenBao from the moment they are generated, and in
the snapshot taken right after; the certificates' keys stay with Traefik on the
matrix VM (`/matrix/traefik/ssl/acme.json`). The chat's own data (rooms,
messages, files) has no backup yet. If a run fails, the script stops at the
failing task or check (for the certificate and MAS checks it
prints the command that shows the service's log); the usual causes are
described in [P27](#p27-keycloak-answers-invalid-parameter-redirect_uri) to
[P31](#p31-mdad-cannot-create-matrix-users). Every step is idempotent, so the
same script is simply run again.

A run takes about five minutes. Two things in the output look alarming but are
expected: the self-check prints one `fatal ... 404` for
`/_matrix/federation/v1/version` and marks it `ignored` (federation is off, see
[P33](#p33-the-self-check-shows-a-fatal-404-for-_matrixfederationv1version)),
and `mas-cli doctor` may print warnings: it only reports, its exit code is
always 0 (see [P34](#p34-mas-cli-doctor-reports-problems-but-the-run-succeeds)).
A successful run ends with the lines below (the dates differ, and so does the
intermediate's name: on a new lab it carries only the year, "DeployableServer
Lab Intermediate CA 2026"; this lab's current one was made on 2026-10-24):

```
Check: matrix.lab.internal    certificate from DeployableServer Lab Intermediate CA 2026-10-24, valid until 2027-01-22
Check: element.lab.internal   certificate from DeployableServer Lab Intermediate CA 2026-10-24, valid until 2027-01-22
Check: lab.internal           certificate from DeployableServer Lab Intermediate CA 2026-10-24, valid until 2027-01-22
...
Check: Synapse delegates login to MAS (https://matrix.lab.internal/auth/)
Check: MAS sends logins to Keycloak (https://keycloak.lab.internal/realms/lab/protocol/openid-connect/auth)

Matrix is ready:  https://element.lab.internal  (homeserver https://matrix.lab.internal)
Sign in through Keycloak as alice or bob. Password to the clipboard:
  .\scripts\Show-LabSecret.ps1 keycloak/users/alice
alice may use Matrix admin tools (MAS policy admin_users).
```

There is no Matrix password and no "register" step: a Matrix account
(`@alice:lab.internal`) is created when its Keycloak user signs in for the first
time.

### Step 8: sign in, chat and make a call

Where the passwords are (all generated once by OpenBao or the firewall build,
never printed by the deployment scripts):

| Login | User | Password to the clipboard |
|---|---|---|
| Element (through Keycloak) | `alice`, `bob` | `.\scripts\Show-LabSecret.ps1 keycloak/users/alice` (or `keycloak/users/bob`) |
| Keycloak admin console <https://keycloak.lab.internal/admin/> | `admin` | `.\scripts\Show-LabSecret.ps1 keycloak/admin` |
| OPNsense GUI <https://firewall.lab.internal> | `root` | `.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password` |

`Show-LabSecret.ps1` copies the value to the clipboard; paste it into the login
form. The first two read OpenBao, so it must be unsealed (after a Windows
restart, `Initialize-Lab.ps1` does that); the third reads the PC's DPAPI store.
`-Show` prints the value instead, but only in a console window you type into
yourself, and `-List` lists the names of all secrets, without values. Every
read from OpenBao is recorded in its audit log. If you switched on Windows'
clipboard history (Win+V), it keeps what you copied; clear it there if that
matters to you.

**Two users need two separate browser profiles (cookie jars).** A browser
profile holds three sessions for whoever signed in: Element's own session (in
the browser storage of `element.lab.internal`, shared by all its tabs), MAS's
session cookie and Keycloak's SSO cookie (see the sessions table in
[Identity](#identity-idp-oidc-and-single-sign-on)). A second Element tab in the
same profile is therefore simply alice again, and even after alice signs out of
Element, "Sign in" in that profile can lead straight back to alice without a
login form ([P32](#p32-signing-in-as-bob-logs-in-alice-again)). Use one Edge
profile for alice and a second, independent one for bob: another Edge profile
(profile menu > Add profile), an InPrivate window, or Chrome. (Not yet tried in
this lab: to switch users within one profile, sign out in Element, then sign out
of Keycloak in its account console
<https://keycloak.lab.internal/realms/lab/account/>. That ends the SSO session,
and Keycloak's back-channel logout then ends MAS's browser session.)

The test:

1. **bob first.** In the second browser open <https://element.lab.internal> and
   click "Sign in". Element hands the login to MAS, and MAS sends the browser
   straight on to Keycloak's login page. Sign in as `bob`. After Keycloak, MAS
   may show a page asking whether Element may access the account: click
   Continue. That consent is between MAS and its client Element; Keycloak's own
   consent for MAS is switched off (to be confirmed in this test). Expected:
   back in Element, signed in as `@bob:lab.internal`. His Matrix account now
   exists. Element may offer to set up a recovery key for encrypted messages
   (see [end-to-end encryption](#matrix-homeserver-clients-and-well-known-delegation));
   in the lab you can save it or skip it. With an InPrivate window, bob's
   device and keys are gone when the window closes: save the recovery key, or
   use a second Edge profile, if you want to read the conversation again later.
2. **alice.** In Edge, do the same as `alice`.
3. **Chat.** As alice, start a direct message: type the full ID
   `@bob:lab.internal` in the Start chat dialog. A search for `bob` may list
   nobody, because Synapse's user directory shows only users who share a room
   with you or are in a public room (`search_all_users: false`, MDAD's
   default). Send a message; as bob, accept the invitation and answer.
4. **Call.** Before you start the call, open `edge://webrtc-internals` in a new
   tab of each browser (`chrome://webrtc-internals` in Chrome), so it records
   the connection from the beginning. Then, in the direct message, start a
   video call; bob joins. Allow camera and microphone when the browser asks. On
   one PC, wear headphones or mute one side to avoid echo; if the second
   browser cannot get the camera, join with the camera off (audio is enough for
   the media check). Element uses Element Call (built into Element Web) for
   every call, and the media go through the LiveKit SFU on the matrix VM.
5. **Check the media path.** In the `webrtc-internals` tab, expected: a
   candidate pair in state `succeeded` whose remote candidate is `10.10.99.3`,
   port 7882, UDP (or port 7881, TCP, if UDP is blocked). If the call connects
   without audio or video, see
   [P35](#p35-a-call-connects-but-no-audio-or-video-flows).

Status of these checks: up to and including Keycloak's login form, the path was
verified from the PC on 2026-10-23 (issuers of Keycloak and MAS, Synapse's auth
metadata, the `.well-known` files, the login flows `m.login.sso` and
`m.login.token` only, the redirects with PKCE S256 and the correct redirect
URI, Element's OIDC setting, LiveKit's health endpoint and TCP 7881). A complete
login by a person and a real call with media are exactly the manual test above.

Element X, the newer mobile app, needs MAS too, but your phone has no route into
this lab (only your PC is on LabHost), so the lab uses Element Web in the
browser (the [roadmap](#11-roadmap) has an idea for Element X).

---

## 5. Everyday operations

### Log in to a VM

```powershell
.\scripts\Connect-Lab.ps1                    # ansible-control (default)
.\scripts\Connect-Lab.ps1 matrix
.\scripts\Connect-Lab.ps1 keycloak
.\scripts\Connect-Lab.ps1 vault              # OpenBao
.\scripts\Connect-Lab.ps1 firewall           # OPNsense (FreeBSD), shell /bin/sh
.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -sr'      # run one command: active pf filter rules
.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -s nat'   # active NAT rules (port forwards, outbound NAT)
.\scripts\Connect-Lab.ps1 firewall 'opnsense-version'    # installed OPNsense version
```

You log in as `ansible` with the PC's SSH certificate, and ssh checks the host
certificate of every machine on the way (the firewall's, then the VM's). The
script is a thin wrapper around `ssh -F keys\ssh_config <vm>`; the one thing it
adds is the renewal of the certificate: valid for 8 hours, it is renewed first
when fewer than 4 hours are left. Plain `ssh`/`scp` with that config file work
too, while the certificate is valid (`.\scripts\Update-LabSshCertificate.ps1`
renews it when it is due and shows which CA signed it and until when). No
administrator rights are needed. A command in single quotes runs on the VM;
avoid double quotes inside it (Windows PowerShell 5.1 does not pass them on
correctly, see [P11](#p11-windows-powershell-51-quirks)). If OpenBao cannot
sign a new certificate (the vault VM is broken),
`.\scripts\Connect-Lab.ps1 <vm> -BreakGlass` lets the offline SSH CA sign it
([SSH certificates](#ssh-certificates-user-and-host-cas)).

On the firewall you get FreeBSD's plain `/bin/sh`: zsh and console autologin are
provisioned only on the Ubuntu VMs. Use the shell to look, not to change things:
OPNsense regenerates its system files from its configuration file
`/conf/config.xml`, so a file edited by hand does not last (see
[An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)
and [P6](#p6-a-firewall-change-has-no-effect-or-is-gone-after-a-rebuild)). Changes
go through the web GUI (<https://firewall.lab.internal>, user `root`, password
with `.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password`, next section),
the REST API, or the repository and a rebuild.

The vault VM is the one Ubuntu VM without console autologin: "Connect" in
Hyper-V Manager shows a normal login prompt there, because a password-less
shell on that VM (user `ansible`, with sudo) would be one step away from
OpenBao's unsealed key in its memory (see
[OpenBao after a restart](#openbao-after-a-restart-sealed-and-unsealed)). SSH
with the PC's certificate works as on the other VMs.

### Read a password or secret

The lab keeps no secret that opens anything on its own in a plain-text file
(the PC's SSH key has no passphrase, but it opens nothing without its
short-lived certificate, see
[SSH certificates](#ssh-certificates-user-and-host-cas)). Secrets live in two
places:

- **OpenBao** (on the vault VM, KV secrets engine mounted at `lab/`): everything
  the services use. Keycloak's database, admin and client secrets, the
  passwords of the lab users, Matrix's secret key and database password.
- **The PC, encrypted with Windows DPAPI** (`keys\<area>\<name>.dpapi`): what
  must exist before or without OpenBao. The firewall's passwords and API key,
  OpenBao's own unseal key shares and logins, the passphrases of the root CA
  key and of the offline SSH CA key. DPAPI ties the encryption to your Windows
  account: another account, or a copy of the file on another PC, cannot
  decrypt it.

For emergencies there is a third, offline place: the recovery kit, key share C
on paper and a passphrase-encrypted recovery file with share B, the break-glass
login for OpenBao, the root CA key with its passphrase and certificate, the
offline SSH CA key with its passphrase, and the firewall's passwords and API
key
([Step 5](#step-5-make-the-recovery-kit-once-you-run-it-yourself); the concept:
[Break-glass: the recovery kit](#break-glass-the-recovery-kit)).

[scripts/Show-LabSecret.ps1](scripts/Show-LabSecret.ps1) reads one secret and
copies it to the clipboard, so you can paste it into a login form without it
ever appearing on screen:

```powershell
.\scripts\Show-LabSecret.ps1 keycloak/users/alice      # alice's password (Element login); bob: keycloak/users/bob
.\scripts\Show-LabSecret.ps1 keycloak/admin            # Keycloak admin console, user admin
.\scripts\Show-LabSecret.ps1 -Pc opnsense/root-password   # OPNsense GUI, user root (DPAPI on the PC)
.\scripts\Show-LabSecret.ps1 -List                     # names of all secrets (DPAPI first, then OpenBao), no values
.\scripts\Show-LabSecret.ps1 keycloak/admin -Show      # print the value instead of copying it
```

`-List` prints the PC's DPAPI names first, which need no OpenBao: they are also
listed while OpenBao is sealed or gone (it then warns that OpenBao cannot be
read). The other secrets in OpenBao are `keycloak/db`, `keycloak/clients/lab-ansible`,
`keycloak/clients/matrix-authentication-service`, `matrix/generic-secret-key`,
`matrix/postgres` and, only on a lab migrated from before OpenBao,
`matrix/legacy-users/*` (Synapse passwords from before MAS, imported by
`Import-LabSecrets.ps1`, unused but kept). The path may also be given with a
leading `lab/`. Every
lab secret has a single field, so `-Field` is not needed.

How it works and why:

- The script logs in to OpenBao with the AppRole `pc-admin`, whose credentials
  are stored with DPAPI. OpenBao accepts that login only from your PC's address
  (10.10.99.1), and the token it hands out is revoked again when the script
  ends. So OpenBao must be unsealed (after a restart of the vault VM:
  `.\scripts\Unlock-LabVault.ps1`); `-Pc` works without OpenBao.
- The connection to OpenBao is HTTPS with OpenBao's certificate **pinned** to
  the lab root ([Internal PKI](#internal-pki-certificate-authority)): a
  certificate from another CA that Windows happens to trust is refused, and the
  scripts work even before the root is imported into Windows.
- Every read is recorded in OpenBao's audit log (`/var/log/openbao/audit.log`
  on the vault VM): who read which path, when, from which address, with the
  value itself replaced by a hash.
- `-Show` prints the value, but only in a real console window. If the output is
  redirected or captured by another program, the script stops: a log file or a
  tool's transcript would keep the secret in plain text.
- Windows' clipboard history (Win+V), if you switched it on, keeps copied text.
  Clear it there after use if that matters to you.

Enterprise equivalent: people sign in to the secrets manager with their own
account (SSO), and their access is logged per person; humans keep their own
passwords in a password manager. In the lab, `pc-admin` is one machine
identity for the PC, used on your behalf (a personal login through Keycloak is
on the [roadmap](#11-roadmap)).

### Write or change a secret (administrator)

The playbooks create missing secrets themselves on a new installation, but
they can never change one. Their OpenBao policies grant `create` and `read` on
their paths, never `update`: write-once. Changing an existing secret (a
rotation) or adding one to a running installation (a new user's password) is a
deliberate decision of the administrator, made with the `pc-admin` login.

Two details of OpenBao's KV store (version 2) matter here:

- **Versions**: a write creates a new version; the store keeps the last 10
  (`max_versions`), so an older value is still there if you need to go back.
  Reads return the newest one.
- **Check and set**: the mount requires `cas` on every write (`cas_required`).
  `cas = 0` means "only if the secret does not exist yet"; `cas = <n>` means
  "only if the current version is n". Two writers can therefore never overwrite
  each other unnoticed, and a create can never replace an existing secret by
  accident.

There is no script for writing; the helper functions in
[scripts/LabSecrets.ps1](scripts/LabSecrets.ps1) do it in a few lines. The
pattern below writes a new secret or a new version of an existing one, with a
value generated by OpenBao from one of the lab's password policies (letters and
digits: `lab-alnum-24` for passwords people type, those of the users and of
Keycloak's `admin`; `lab-alnum-48` for Keycloak's other secrets; `lab-alnum-64`
for Matrix's). Replace the three values in the third line; the how-tos below
show it filled in. Nothing is printed:

```powershell
. .\scripts\LabSecrets.ps1                     # load the helper functions into this window
$token = Get-LabBaoToken 'pc-admin'
$path = '<path>'; $field = '<field>'; $policy = '<policy>'   # e.g. keycloak/users/carol, password, lab-alnum-24
$meta = Invoke-LabBao GET "lab/metadata/$path" -Token $token -AllowNotFound
$cas = 0; if ($meta) { $cas = $meta.data.current_version }   # 0 = new secret
$value = (Invoke-LabBao GET "sys/policies/password/$policy/generate" -Token $token).data.password
Invoke-LabBao POST "lab/data/$path" @{ options = @{ cas = $cas }; data = @{ $field = $value } } -Token $token | Out-Null
$value = $null; Close-LabBaoToken $token
```

Note the two prefixes: KV version 2 keeps the values under `lab/data/<path>`
and the version history under `lab/metadata/<path>`. A new value only takes
effect when the services are deployed again; the how-tos say which deployment:
[Add a Keycloak user](#add-a-keycloak-user) and
[Rotate the MAS client secret](#rotate-the-mas-client-secret). That deployment
also takes a snapshot of OpenBao with the new value in it; if you do not deploy
right away, take one yourself ([Back up OpenBao](#back-up-openbao)).

The web UI can do the same by hand (Secrets engines > `lab` > the secret >
"Create new version"; it fills in the check-and-set version itself): see
[Open OpenBao's web UI](#open-openbaos-web-ui).

Never change `keycloak/db`, `keycloak/admin`, `keycloak/clients/lab-ansible`,
`matrix/generic-secret-key` or `matrix/postgres` on a running lab: they are
fixed after the first start of their service (see
[Which change is applied by which command](#which-change-is-applied-by-which-command)).

### Open OpenBao's web UI

```powershell
.\scripts\Open-LabVaultUi.ps1
```

opens <https://vault.lab.internal:8200/ui/> in your browser and puts a login
token on the clipboard. In the UI choose the method **Token**, paste it with
`Ctrl+V` and sign in. There you see the lab's secrets (Secrets engines > `lab`),
the PKI (Secrets engines > `pki_int`: issuers, roles, issued certificates),
the policies, the AppRoles and the token roles.

Why a token and not a user name: nobody has a personal OpenBao account in this
lab yet. Every login is a machine login (the AppRoles `pc-admin`, `pc-deploy`,
`recovery`), and the initial root token was revoked at the end of the
bootstrap. So the script logs in as `pc-admin` and creates a token for you
through the token role `ui-admin` (defined in
[scripts/LabSecrets.ps1](scripts/LabSecrets.ps1), applied by
`Deploy-LabVault.ps1`):

| Property | Value | Why |
|---|---|---|
| policy | `openbao-admin` (everything) | to look at and change anything |
| lifetime | 1 hour at most, not renewable | a forgotten browser tab stops working by itself |
| usable from | only your PC (10.10.99.1) | a copied token is useless anywhere else |
| type | orphan | it outlives the short `pc-admin` login that created it |

"Sign out" (top right in the UI) revokes it at once. Every request appears in
OpenBao's audit log with the display name `token-ui`.

Careful with changes in the UI: they are not in the repository. A policy, role
or setting changed by hand is overwritten by the next `Deploy-LabVault.ps1`
(which applies its configuration on every run) or lost in a rebuild. Secrets
are the exception: they live only in OpenBao, so a value changed there stays
(see [Write or change a secret](#write-or-change-a-secret-administrator)).

Enterprise equivalent: people log in to the UI with their own identity through
the company's identity provider (OIDC), with policies per team and no shared
administrator token. For the lab that is on the [roadmap](#11-roadmap):
Keycloak as the login for OpenBao.

### Look at the services and their logs

**Matrix** (VM matrix): MDAD runs every container as a systemd unit, so
`systemctl` and `journalctl` show state and logs. The nine units are
`matrix-traefik`, `matrix-synapse`, `matrix-postgres`,
`matrix-authentication-service`, `matrix-client-element`,
`matrix-livekit-server`, `matrix-livekit-jwt-service`, `matrix-static-files`
and `matrix-container-socket-proxy`.

```powershell
.\scripts\Connect-Lab.ps1 matrix 'systemctl list-units --type=service --no-pager | grep matrix-'
.\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-synapse -n 100 --no-pager'
.\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-authentication-service -n 100 --no-pager'
.\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-livekit-server -f'    # follow; Ctrl+C ends
.\scripts\Connect-Lab.ps1 matrix 'sudo systemctl restart matrix-authentication-service'
.\scripts\Connect-Lab.ps1 matrix 'free -m'
```

Typical places to look: a login problem in MAS's log (for example
`Failed to fetch provider metadata`, see
[P29](#p29-mas-runs-but-cannot-reach-keycloak)), a call problem in the logs of
`matrix-livekit-server` and `matrix-livekit-jwt-service`, a routing or
certificate problem in Traefik's log. MDAD keeps configuration and data under
`/matrix` on the VM (not readable for user `ansible`; use `sudo`).

**Keycloak** (VM keycloak): a Docker Compose project in `/opt/keycloak-stack`
(readable only by root, hence `--project-directory` with `sudo`):

```powershell
.\scripts\Connect-Lab.ps1 keycloak 'sudo docker compose --project-directory /opt/keycloak-stack ps'
.\scripts\Connect-Lab.ps1 keycloak 'sudo docker compose --project-directory /opt/keycloak-stack logs --tail 100 keycloak'
.\scripts\Connect-Lab.ps1 keycloak 'sudo docker compose --project-directory /opt/keycloak-stack logs --tail 100 postgres'
```

`ps` shows both containers with `(healthy)` when all is well. Keycloak's
health endpoint is only reachable on the VM itself:
`.\scripts\Connect-Lab.ps1 keycloak 'curl -s http://127.0.0.1:9000/health/ready'`.
Users, sessions and the client are easiest to inspect in the admin console
(<https://keycloak.lab.internal/admin/>, realm `lab`). Sessions of a user:
Users > (user) > Sessions.

**OpenBao** (VM vault): the systemd service `openbao`, its configuration in
`/etc/openbao/openbao.hcl`, its data (integrated storage, "raft") in
`/opt/openbao/data`, and nginx on port 80 for the CA certificates and
revocation lists.

```powershell
.\scripts\Connect-Lab.ps1 vault 'systemctl status openbao --no-pager'
.\scripts\Connect-Lab.ps1 vault 'sudo journalctl -u openbao -n 100 --no-pager'
.\scripts\Connect-Lab.ps1 vault 'sudo tail -n 3 /var/log/openbao/audit.log'   # one JSON line per request and response
```

`systemctl` reports `active (running)` even while OpenBao is sealed: sealed is
OpenBao's own state, not the service's (check it with the health URL below).
The audit log records every request and its answer, with secret values
replaced by HMAC hashes: it shows who did what, never a value. logrotate
rotates it daily and keeps 14 days. If OpenBao cannot write its audit log, it
refuses requests ("fail closed"), so a full disk on the vault VM stops it.

**Firewall**: blocked packets from the lab to the HOST network are logged (the
first LAN rule); see Firewall > Log Files > Live View in the GUI.
`sudo pfctl -sr` and `sudo pfctl -s nat` (above) show the rules pf runs.

**From the PC**, a few quick health checks (the PC must trust the lab root CA,
`.\scripts\Install-LabRootCA.ps1`). `curl.exe` uses Windows' Schannel, which
also checks revocation: it fetches the revocation lists that the vault VM
serves on port 80, so these checks depend on the vault VM too (see
[OpenBao after a restart](#openbao-after-a-restart-sealed-and-unsealed)).

```powershell
curl.exe -s https://lab.internal/.well-known/matrix/client
curl.exe -s https://matrix.lab.internal/_matrix/client/v1/auth_metadata
curl.exe -s https://keycloak.lab.internal/realms/lab/.well-known/openid-configuration
curl.exe -s https://matrix.lab.internal/livekit-server/       # LiveKit answers: OK
curl.exe -s https://vault.lab.internal:8200/v1/sys/health     # OpenBao: "sealed":false when unsealed
curl.exe -sI http://vault.lab.internal/pki/root-ca.crl        # the root CA's revocation list: HTTP 200
```

### Run the tests

Every check that was used to verify the lab is kept as a script in `tests\`,
so you can read exactly what was tested and run it again;
[tests/README.md](tests/README.md) says what each test checks. Most tests
need a deployed lab (OpenBao, Keycloak, Matrix). They run in PowerShell from
the project folder, print one `PASS` or `FAIL` line per check and never print
a secret:

```powershell
.\tests\Invoke-LabTests.ps1                              # all tests that change nothing, then a summary
.\tests\Invoke-LabTests.ps1 -Name Test-LabCertificates   # only this test (file name without .ps1)
.\tests\Test-LabCertificates.ps1                         # or one test directly
```

Without `-Name`, `Invoke-LabTests.ps1` runs nine tests: `Test-LabCertificates`
(every HTTPS endpoint: the right CA, valid for more than 30 days, trusted by
Windows), `Test-LabTlsPin`, `Test-LabPasswordHash`, `Test-LabRetiredDpapi`,
`Test-LabRunToken`, `Test-LabSecretCreation`, `Test-LabFirewallRender`,
`Test-LabSshCa` (the SSH certificate code on the PC: offline signing, what a
certificate contains, refused principals, the revocation list, the rendered
trust files) and `Test-LabSshCertificates` (SSH in the running lab: strict
logins everywhere, plain host keys and a foreign CA refused, a run certificate
for `host-matrix` opens matrix only, the break-glass CA still accepted; run it
elevated for the checks of the KVP host keys and Vagrant's jump).
They change nothing the lab uses: `Test-LabSecretCreation` creates a
throwaway secret `lab/keycloak/test-generated` and deletes it again,
`Test-LabFirewallRender` builds the firewall's configuration into a temporary
folder (the root CA signs one extra test certificate for it), the two SSH
tests work with throwaway keys and short-lived certificates (listed in
`keys\ssh\issued.log` like every certificate), and `Test-LabTlsPin` makes one
HTTPS request to `www.microsoft.com` as an example of a foreign certificate
chain.
The script exits with 1 if a test failed. All nine passed on 2026-10-24 (the
two SSH tests right after the move to SSH certificates).

One test **changes state** and runs only when you ask for it:
`Test-LabRecoveryLogin.ps1` checks the break-glass login (AppRole `recovery`)
the way `New-LabRecoveryKit.ps1 -Recover` uses it. It issues new `pc-admin`
and `pc-deploy` logins and destroys every secret ID of `recovery`, so the
break-glass login in an existing recovery file stops working; make a new file
afterwards with `.\scripts\New-LabRecoveryKit.ps1 -Renew`. It asks before it
starts:

```powershell
.\tests\Invoke-LabTests.ps1 -IncludeStateChanging    # the nine tests, then Test-LabRecoveryLogin.ps1
```

The deployment scripts check themselves as well (`Deploy-LabMatrix.ps1`, for
example, the ACME certificates, MDAD's self-check and the login path to
Keycloak); the tests cover what the deployments do not. Some of them run small
scripts on ansible-control (`tests\remote\`), which `LabTest.ps1` copies to
`/tmp/lab-tests` there and removes again.

### Run a playbook, re-run a deployment

The three deployment scripts are the normal way to apply changes to the
services. All are idempotent: run them again after any change, and a run
without changes changes nothing.

```powershell
.\scripts\Deploy-LabVault.ps1           # OpenBao: openbao.yml, then its configuration over the API
.\scripts\Deploy-LabVault.ps1 -RotateIntermediate   # the same, and a new intermediate CA now
.\scripts\Deploy-LabKeycloak.ps1        # keycloak.yml (secrets and certificate from OpenBao)
.\scripts\Deploy-LabMatrix.ps1          # vendor\mdad to ~/mdad + matrix-prepare.yml + MDAD (through lab-setup.yml) + checks
.\scripts\Deploy-LabMatrix.ps1 -Setup   # the same with the tags of "just setup-all", after REMOVING a component
```

`Deploy-LabKeycloak.ps1` (after its playbook) and `Deploy-LabMatrix.ps1` (after
`matrix-prepare.yml`) also take a snapshot of OpenBao, on every run and also
when the playbook failed: a first deployment creates secrets that from then on
exist only in OpenBao (see [Back up OpenBao](#back-up-openbao)). A failed
snapshot is only a warning; it does not change the deployment's result.

Any playbook can also run on its own:

```powershell
.\scripts\Invoke-LabPlaybook.ps1 ping.yml
.\scripts\Invoke-LabPlaybook.ps1 ping.yml -v                       # more output
.\scripts\Invoke-LabPlaybook.ps1 <playbook> --check --diff         # dry run: show what would change
.\scripts\Invoke-LabPlaybook.ps1 matrix-prepare.yml *> run.log     # log to a file
```

What happens on each call of `Invoke-LabPlaybook.ps1`:

1. `ansible\` is packed with `tar` and copied to ansible-control.
2. The **public** files of the lab's PKI are copied from `keys\pki` to
   `~/lab-pki`: the root CA certificate (PEM, which the playbooks put into the
   VMs' trust stores) and the DER copies of the root certificate and its
   revocation list (which `openbao.yml` publishes on the vault VM). The root
   CA's key never leaves the PC.
3. `~/lab` on ansible-control is **replaced completely** with the new copy
   (`chmod -R go-w`, see [P20](#p20-ansible-ignores-ansiblecfg)).
4. ansible-control gets an **SSH certificate for this run**: the PC signs
   ansible-control's own public key for exactly the machines the playbook
   needs (below), valid 2 hours, and the certificate is deleted again when the
   playbook ends, whatever its exit code.
5. `ansible-playbook playbooks/<playbook> <your extra arguments>` runs there.
   A playbook that needs OpenBao runs with a **run token** (below); if OpenBao
   is sealed, the script unseals it first, and if OpenBao does not answer at
   all, it stops and asks whether the vault VM is running and OpenBao has been
   deployed (`.\scripts\Deploy-LabVault.ps1`). Output is in colour when you run
   it in a console window and plain text when you redirect it to a file.

Which playbooks get a run token, and what it allows (the policies are defined
in [Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1), the mapping in
`$openBaoPolicies` in [Invoke-LabPlaybook.ps1](scripts/Invoke-LabPlaybook.ps1)):

| Playbook | Policy of its run token | The token may |
|---|---|---|
| `keycloak.yml` | `ansible-keycloak` | create and read `lab/keycloak/*`, generate passwords (`lab-alnum-24`, `-48`), have OpenBao sign certificates of the PKI role `keycloak` |
| `matrix-prepare.yml`, and MDAD's runs by `Deploy-LabMatrix.ps1` | `ansible-matrix` | create and read `lab/matrix/*`, read (only) the MAS client secret `lab/keycloak/clients/matrix-authentication-service`, generate passwords (`lab-alnum-64`) |
| `hello-nginx.yml` | `ansible-web` | have OpenBao sign certificates of the PKI role `web`; no secrets |
| `ping.yml`, `openbao.yml` | none | (they need no token: `ping.yml` does not contact OpenBao, `openbao.yml` only calls the unauthenticated health endpoint `sys/health`) |

Which machines the run's SSH certificate opens (its principals, `$sshPrincipals`
in [Invoke-LabPlaybook.ps1](scripts/Invoke-LabPlaybook.ps1); principals are
explained in [SSH certificates](#ssh-certificates-user-and-host-cas)):

| Playbook | Principals | Opens |
|---|---|---|
| `openbao.yml` | `host-vault` | vault |
| `keycloak.yml` | `host-keycloak` | keycloak |
| `matrix-prepare.yml`, and MDAD's runs by `Deploy-LabMatrix.ps1` | `host-matrix` | matrix |
| `ping.yml`, and every playbook not in the list (today `hello-nginx.yml`; the script says so) | `lab-all` | every machine, the firewall included |

The same idea as the run token's policy: least privilege per run. During a
Matrix deployment, MDAD (third-party code) holds a certificate that opens
matrix, not vault or the firewall. A new playbook gets an entry with the
`host-<vm>` names it needs.

How the run token reaches the playbook is drawn step by step in
[Where secrets and certificates come from](#where-secrets-and-certificates-come-from)
and explained in [Secrets management with OpenBao](#secrets-management-with-openbao).
In short: the PC logs in as `pc-deploy` and has OpenBao create a token with only
the policy from the table, valid for at most 2 hours and only from
ansible-control's address; it arrives response-wrapped, on SSH's stdin, at
[ansible/bin/openbao-run](ansible/bin/openbao-run), which unwraps it, runs
`ansible-playbook` and revokes the token when it ends, also after a failure or
Ctrl+C. The playbooks read their secrets into memory (the fact `lab_secrets`,
[tasks/openbao-secrets.yml](ansible/playbooks/tasks/openbao-secrets.yml)), and
with pipelining (`pipelining = True` in [ansible/ansible.cfg](ansible/ansible.cfg))
and Ansible's local temporary folder in RAM (`ANSIBLE_LOCAL_TEMP`, set by
`openbao-run`), neither the token nor a secret is ever written to
ansible-control's disk.

Why so much effort for one token: each run gets the least privilege it needs,
for the shortest time, usable from one machine only, and nothing long-lived is
stored on the control node. Enterprise equivalent: a CI/CD runner or AWX gets a
short-lived token per job, through its own identity (Vault's JWT/OIDC login for
pipelines, AppRole with response wrapping) or a Vault Agent next to it.

The exit code of the script is the exit code of `ansible-playbook` (255 if the
SSH connection itself failed). Extra arguments are joined with spaces into one
remote command line, so avoid values that contain spaces or quotes (use
`-e name=value`); for the playbooks with a run token, quotes of any kind are
refused.

**Dry runs** (`--check`, with `--diff` to see the differences) work for the
playbooks with a run token too. Tasks that only read (the secrets, OpenBao's CA
certificate) run anyway (`check_mode: false`: without the values nothing else
could be compared), and nothing is written to OpenBao: no missing secret is
created and no certificate is requested. One task always reports `changed`
under `--check`: Keycloak's users, because the `keycloak_user` module cannot
compare passwords there. A real run reports `ok` for them.

Ansible may print a warning once per VM: "Module remote_tmp /root/.ansible/tmp
did not exist and was created with a mode of 0700". It is a side effect of
pipelining and harmless
([P48](#p48-ansible-warns-that-it-created-rootansibletmp)).

Running `keycloak.yml` or `matrix-prepare.yml` directly is safe: their secrets
come from OpenBao, wherever they run, and a rebuilt ansible-control loses
nothing. The deployment scripts add the import of old plain-text secret files
([Import-LabSecrets.ps1](scripts/Import-LabSecrets.ps1); repeated, harmlessly,
until you delete them with `Import-LabSecrets.ps1 -RemovePlaintext`), the
snapshot of OpenBao and, for Matrix, the copy of `vendor\mdad` to `~/mdad`,
MDAD and the checks. (`matrix-prepare.yml` on its own only checks the copy in
`~/mdad` and stops if it is missing or holds another commit.) A playbook started by
hand on ansible-control has no token and stops as soon as it needs OpenBao ("No
OpenBao token in the environment").

`Deploy-LabMatrix.ps1` runs MDAD in `~/mdad` on ansible-control, with MDAD's
own `ansible.cfg` and inventory, not through `Invoke-LabPlaybook.ps1`. First
it copies `vendor\mdad` from the repository there (tar + scp, unpacked into
`~/mdad.new`, which then replaces `~/mdad`, as `Invoke-LabPlaybook.ps1` does
for `~/lab`), so the control node keeps no MDAD code of its own that could
drift. It runs the lab's entry point [lab-setup.yml](ansible/matrix/lab-setup.yml)
instead of MDAD's `setup.yml`: it reads the Matrix secrets from OpenBao into
memory, hands them to MDAD as variables and then imports `setup.yml`, with the
same tags as MDAD's `just` recipes. Each MDAD run gets a run token of its own.
MDAD's `justfile` would run `setup.yml` directly, without the secrets, which
are no longer in MDAD's inventory; the lab does not use it (`just` is not
installed). To run a single MDAD tag by hand, for example the self-check, use
the same helper the script uses (after at least one `Deploy-LabMatrix.ps1`
run, so that `~/mdad` exists). Its fourth argument names the SSH principals of
the run's certificate, here only matrix:

```powershell
. .\scripts\LabSecrets.ps1
Invoke-LabRunToken 'cd ~/mdad && ansible-playbook -i inventory/hosts lab-setup.yml --tags=self-check' @('ansible-matrix') 'mdad' @('host-matrix')
```

MDAD checks SSH host keys like the lab's own playbooks: its `ansible.cfg` leaves
Ansible's `host_key_checking` at its default (on), and ssh on ansible-control
accepts a lab machine only with a valid host certificate
(`/etc/ssh/ssh_config.d/20-lab.conf`, written by
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh)).

**Edit playbooks and configuration in the repository, never on the VM.** The
repository is the source of truth: `~/lab` is overwritten on the next
`Invoke-LabPlaybook.ps1` run and `~/mdad` on the next `Deploy-LabMatrix.ps1`
run, and `matrix-prepare.yml` copies the MDAD inventory and `lab-setup.yml`
from the repository into `~/mdad` (and generates `lab-shared.yml` there). Do
not edit `vendor\mdad` either: it is MDAD's code exactly as upstream published
it, and it changes only through `Update-LabMdad.ps1`
([Upgrade MDAD](#upgrade-mdad-and-with-it-the-matrix-components)). The lab's
own settings for MDAD belong in `ansible\matrix\`.

### Which change is applied by which command

| You changed | Apply it with |
|---|---|
| `config/lab.json`: `published` (addresses, names, ports) | `.\scripts\New-LabFirewall.ps1 -Rebuild` (about 4 minutes; see [Publish a name or a port](#publish-a-name-or-a-port)). If the matrix entry's `address` changes, also set `livekit_server_config_rtc_node_ip` in `vars.yml` to it and run `.\scripts\Deploy-LabMatrix.ps1`, or calls connect without media ([P35](#p35-a-call-connects-but-no-audio-or-video-flows)) |
| `config/lab.json`: a new lab VM | see [Add a VM](#add-a-vm): firewall rebuild, `.\scripts\Deploy-LabVault.ps1` (OpenBao's SSH roles learn the new name), then `.\scripts\Initialize-Lab.ps1` |
| `config/lab.json`: an existing VM's `cpus` or `memory` | `vagrant reload <vm>` in the `vagrant` folder (the VM restarts; after a reload of vault, `.\scripts\Unlock-LabVault.ps1`) |
| `config/lab.json`: an existing VM's MAC or IP | `.\scripts\Remove-Lab.ps1 <vm>`, then `.\scripts\New-LabFirewall.ps1 -Rebuild` and `.\scripts\Initialize-Lab.ps1`. For vault this means a new, empty OpenBao (see [Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)) |
| `config/lab.json`: the `firewall` data | `.\scripts\New-LabFirewall.ps1 -Rebuild`. If `hostIp` or `pcIp` changes: first update the matching values in `Install-LabHostNetwork.ps1` (the PC's 10.10.99.1 and its DNS server 10.10.99.2) and run it, then `.\scripts\Remove-Lab.ps1 firewall` and `.\scripts\Initialize-Lab.ps1`, which rewrites `keys\ssh_config` with the new address (step 2) before it builds the firewall (step 4). A plain `-Rebuild` would still try the old address from `keys\ssh_config` for SSH and fail. Note: the PC's OpenBao logins (`pc-admin`, `pc-deploy`, and the break-glass login `recovery` in the recovery file) are bound to the PC's address and stop working after a change of `pcIp`; no script handles that yet. With them OpenBao's signing of SSH certificates stops (its role `pc` also names the old address), so until then the SSH certificates come from the offline SSH CA (`-BreakGlass`) |
| `opnsense/config.xml.template` | `.\scripts\New-LabFirewall.ps1 -Rebuild` (or make the same change in the GUI, see [section 6](#6-how-to-)) |
| `opnsense/dnsmasq.conf.d/10-lab.conf` | `.\scripts\New-LabFirewall.ps1` or `.\scripts\Initialize-Lab.ps1` (the drop-in is installed again on every run) |
| `ansible/playbooks/openbao.yml`, `ansible/templates/openbao/*`, or OpenBao's configuration in `scripts/Deploy-LabVault.ps1` (policies, AppRoles, the token role, PKI roles, ACME) | `.\scripts\Deploy-LabVault.ps1`. It re-applies the whole configuration on every run, so the code is the truth. A changed `openbao.hcl` is applied with a reload, which does not seal OpenBao; the reload covers the TLS files, the log level and the audit settings. Other settings (listener, storage) need a restart: `.\scripts\Connect-Lab.ps1 vault 'sudo systemctl restart openbao'`, then `.\scripts\Unlock-LabVault.ps1` |
| A name in a PKI role (`allowed_domains` in `Deploy-LabVault.ps1`) | `.\scripts\Deploy-LabVault.ps1`, then the deployment of the service that uses the role (see [Publish a name or a port](#publish-a-name-or-a-port)) |
| Nothing, but the intermediate CA should be replaced now (a suspected key compromise, a test) | `.\scripts\Deploy-LabVault.ps1 -RotateIntermediate`, then `.\scripts\Deploy-LabKeycloak.ps1` and `.\scripts\Deploy-LabMatrix.ps1` (see [Rotate the intermediate CA](#rotate-the-intermediate-ca)) |
| `ansible/ansible.cfg`, `ansible/bin/openbao-run` | nothing extra: every run of `Invoke-LabPlaybook.ps1` (also inside the deployment scripts) copies all of `ansible\` to `~/lab` on ansible-control, and the MDAD runs use `~/lab/bin/openbao-run` from there |
| `ansible/playbooks/keycloak.yml`, `ansible/playbooks/vars/keycloak-secrets.yml`, `ansible/templates/keycloak/*` | `.\scripts\Deploy-LabKeycloak.ps1` |
| `ansible/playbooks/tasks/*` (task files shared by several playbooks) | the deployments that include them: `openbao-secrets.yml` by `Deploy-LabKeycloak.ps1` and `Deploy-LabMatrix.ps1`, `openbao-certificate.yml` by `Deploy-LabKeycloak.ps1` and `hello-nginx.yml` |
| The Keycloak/MAS values in `ansible/inventory/group_vars/all.yml` | `.\scripts\Deploy-LabKeycloak.ps1`, then `.\scripts\Deploy-LabMatrix.ps1` (both sides must agree). Never change `lab_mas_keycloak_provider_id` |
| `ansible/matrix/` (MDAD inventory, `vars.yml`, `lab-setup.yml`), `ansible/playbooks/matrix-prepare.yml` (its pinned MDAD version `mdad_version` only together with `vendor\mdad`, next row) | `.\scripts\Deploy-LabMatrix.ps1`; with `-Setup` after removing a component |
| A new MDAD version (`vendor\mdad`) | `.\scripts\Update-LabMdad.ps1 -Commit <commit>` (git subtree pull plus the roles, two commits); then `mdad_version` and `vars.yml` as in [Upgrade MDAD](#upgrade-mdad-and-with-it-the-matrix-components), and `.\scripts\Deploy-LabMatrix.ps1` (it refuses while `vendor\mdad` and `mdad_version` differ) |
| `tests/*` | nothing: the tests only check ([Run the tests](#run-the-tests)) |
| A secret in OpenBao: a new user's password, a new MAS client secret | written by you as administrator ([Write or change a secret](#write-or-change-a-secret-administrator)), then `.\scripts\Deploy-LabKeycloak.ps1`; for the client secret also `.\scripts\Deploy-LabMatrix.ps1` (see [Rotate the MAS client secret](#rotate-the-mas-client-secret)). Never change `keycloak/db`, `keycloak/admin`, `keycloak/clients/lab-ansible`, `matrix/generic-secret-key` or `matrix/postgres` on a running lab: they are fixed after the first start of their service. A new database password no longer matches the one PostgreSQL keeps, so the service stops working; a new admin password or `lab-ansible` secret is ignored by Keycloak, and with the latter the playbook can no longer log in to the admin API; MDAD derives keys from the Matrix secret key. A new password of an existing user is not applied either (see [Add a Keycloak user](#add-a-keycloak-user)) |
| Other playbooks (`ping.yml`, `hello-nginx.yml`) | `.\scripts\Invoke-LabPlaybook.ps1 <playbook>` |
| `provision/*.sh` | `.\scripts\Initialize-Lab.ps1` (it always re-runs provisioning of the Ubuntu VMs). Exception: a new `ANSIBLE_VERSION` in `bootstrap-ansible-control.sh` reaches an existing ansible-control only with the command below |
| The SSH certificate roles, `$LabSshRoles` in `scripts/LabSsh.ps1` (lifetimes, extensions, source addresses) | `.\scripts\Deploy-LabVault.ps1`, which makes OpenBao's SSH roles from the same table. Certificates already issued keep their contents until they are renewed: the PC's at once with `.\scripts\Update-LabSshCertificate.ps1 -Force`, a run's with the next run, host certificates 30 days before they expire |
| `opnsense/sshd_config.d/20-lab-ssh.conf`, `opnsense/lab-sshd-files.sh`, `opnsense/lab-ssh-trust.php` | `.\scripts\New-LabFirewall.ps1` or `.\scripts\Initialize-Lab.ps1` (the firewall's SSH setup is applied again on every run, no rebuild) |
| Nothing, but the PC should have a new SSH certificate now | `.\scripts\Update-LabSshCertificate.ps1 -Force` (every script renews it by itself when fewer than 4 hours are left) |

Ansible is pinned too: `ANSIBLE_VERSION` in
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh)
(today 14.5.0, the community package with its collections, which brings
ansible-core 2.21.5). The provisioning script installs Ansible only when pipx
does not list it yet, so it never changes an existing installation. To
upgrade, change `ANSIBLE_VERSION` (a rebuilt ansible-control then gets the new
version) and, on the existing VM (`.\scripts\Connect-Lab.ps1` opens a shell
there), install exactly that version:

```
sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force --include-deps ansible==<version>
```

### Rebuild one VM or the whole lab

```powershell
.\scripts\Remove-Lab.ps1 matrix      # one Ubuntu VM (asks for confirmation)
.\scripts\Remove-Lab.ps1 vault       # OpenBao: a snapshot first, then keys\openbao is moved aside (below)
.\scripts\Remove-Lab.ps1 firewall    # only the firewall
.\scripts\Remove-Lab.ps1             # all VMs, the firewall last
.\scripts\Remove-Lab.ps1 -WhatIf     # only show what would be deleted
.\scripts\Remove-Lab.ps1 -Confirm:$false   # no confirmation question
.\scripts\Initialize-Lab.ps1         # build again

.\scripts\New-LabFirewall.ps1 -Rebuild     # delete and rebuild only the firewall, in one step
```

`Remove-Lab.ps1` works from whatever folder you are in. For the Ubuntu VMs it
runs `vagrant destroy`; the VMs and their disks are deleted. It also removes the
Hyper-V folder `G:\Vagrant\hyperv\<vm>` that `vagrant destroy` leaves behind
(only for VMs listed in `config/lab.json`, only a folder named exactly like its
VM, see [P14](#p14-a-removed-vm-leaves-its-hyper-v-folder-behind)). The firewall
is not a Vagrant VM, so the script removes it with the Hyper-V cmdlets, together
with its folder `G:\Vagrant\hyperv\firewall` (disk, configuration, console log).
For safety it touches only a VM whose Notes carry the tag that
`New-LabFirewall.ps1` writes there.

What stays: the Vagrant box cache, the OPNsense image cache, the whole
repository (the scripts, the Ansible project, the vendored MDAD in
`vendor\mdad`), and `keys\`: the offline SSH CA and this PC's SSH key
(`keys\ssh`), the offline root CA (`keys\pki`, its key encrypted, the
passphrase in DPAPI) and the firewall's passwords and API key (DPAPI,
`keys\opnsense\`). Because the root stays, every certificate of a rebuilt lab
chains to the same root, and Windows keeps trusting it; because the SSH CA
stays, the rebuilt machines get host certificates that every client already
trusts; because the firewall's secrets stay, its GUI password does not change.
The one exception is `keys\openbao`.

**SSH host keys of deleted machines are revoked.** A rebuilt machine has new
host keys. `Remove-Lab.ps1` (and `New-LabFirewall.ps1 -Rebuild`, and
`Initialize-Lab.ps1` when a VM publishes a different key) puts the old key into
the revocation list `keys\ssh\revoked_host_keys` and gives ansible-control the
new list, so a copy of an old key, from a checkpoint or an old disk, can never
pass for the rebuilt machine. The new machine gets its host certificate from
`Initialize-Lab.ps1` (the firewall from its build). Once OpenBao signs the SSH
certificates, a firewall rebuild needs the vault VM running: the new firewall's
host certificate comes from OpenBao, through the new firewall's port forward.
`New-LabFirewall.ps1 -Rebuild` starts the vault VM itself, and refuses before it
deletes anything when the vault VM does not exist; `-BreakGlass` lets the
offline SSH CA sign instead.

**OpenBao is a special case.** The vault VM holds the only copy of the
services' secrets, so before `Remove-Lab.ps1` deletes it (`Remove-Lab.ps1
vault`, or `Remove-Lab.ps1` without a name) it takes a fresh snapshot
([Back up OpenBao](#back-up-openbao)). If no fresh snapshot is possible
(OpenBao sealed or broken), it warns and relies on the newest snapshot already
in `keys\openbao\snapshots` (every deployment takes one). Only if there is none
at all while you delete only vault and keycloak or matrix still exist, it stops
and deletes **nothing**: their data depends on those secrets. Start the vault VM
and unseal OpenBao (`.\scripts\Initialize-Lab.ps1`), then try again. When the
whole lab goes, a failed snapshot is only a warning.

Then the key shares and the PC's logins (`keys\openbao\*.dpapi`), which fit only
the installation they were made for: the script **moves** `keys\openbao` to
`keys\openbao-retired-<yyyyMMdd-HHmmss>`, together with the snapshots in it
(the new one included). A snapshot can be restored only with the key shares of
its time, so neither is thrown away. (`Deploy-LabVault.ps1` refuses to
initialise a new OpenBao while `keys\openbao` holds shares of an earlier one.)
OpenBao's SSH CA goes with the deleted installation: the script moves
`keys\ssh\openbao-ca.pub` and `openbao-ca.trusted` into the same retired folder
(`ssh\` in it). The machines stop trusting that CA at the next
`Initialize-Lab.ps1`, which renders the SSH trust files without it, and the
offline SSH CA signs again until `Deploy-LabVault.ps1` has made the new
OpenBao's SSH CA trusted everywhere (its step 8).
A rebuilt OpenBao is a new installation: new key shares (make a new recovery
kit with `New-LabRecoveryKit.ps1`; the old share C and recovery file belong to
the old installation), a new intermediate CA (`lab-int-<year>`, signed by the
same root, so nothing changes for Windows) and **no secrets**. What follows
from that:

- Rebuilding vault **together with** keycloak and matrix (or the whole lab) is
  simple: the deployments generate new secrets for the new databases. alice and
  bob get new passwords (`Show-LabSecret.ps1`). Delete keycloak and matrix
  first, or the whole lab at once: while they still exist, `Remove-Lab.ps1
  vault` on its own refuses when it can neither take a snapshot nor find an
  earlier one.
- Rebuilding vault **alone**, while keycloak and matrix keep their data, needs a
  restore: their databases were set up with the old secrets, and new ones would
  not open them. `Deploy-LabKeycloak.ps1` and `Deploy-LabMatrix.ps1` notice that
  and refuse ("The service already has data that was set up with the old
  values"). See [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).
- Keycloak and Matrix keep running without OpenBao (their secrets are in their
  own configuration), but deployments, certificate renewals and the revocation
  list of the intermediate CA need it.

**What is lost: the application data.** There are no backups of the databases
yet (see the [roadmap](#11-roadmap)); OpenBao's own data has snapshots
([Back up OpenBao](#back-up-openbao)), taken by the deployments and by
`Remove-Lab.ps1` itself.

- **Removing matrix** deletes the homeserver's PostgreSQL database and media:
  every room, message, uploaded file and Matrix account. After
  `Initialize-Lab.ps1` and `Deploy-LabMatrix.ps1` you have an empty homeserver
  with the same configuration and the same secrets (from OpenBao); Traefik gets
  new certificates through ACME, and the accounts are created again on the next
  login. Browsers may still hold the old Element session; sign in again (or
  clear the site data of `element.lab.internal`).
- **Removing keycloak** deletes Keycloak's database. After `Initialize-Lab.ps1`
  and `Deploy-LabKeycloak.ps1`, alice and bob exist again with the same
  passwords and the same client secret (from OpenBao), but with new internal
  user IDs. MAS links them to the existing Matrix accounts by user name
  (`on_conflict: replace` in `vars.yml`, a lab trade-off explained in
  [section 10](#10-security-notes)). Users created by hand in the admin console
  are gone.
- **Removing ansible-control** loses nothing that matters: everything on it
  comes back from the repository. Its provisioning installs the pinned Ansible
  version again, `~/lab` and `~/lab-pki` are copied again on the next
  `Invoke-LabPlaybook.ps1` run (every deployment makes one), and `~/mdad` on
  the next `Deploy-LabMatrix.ps1` run, which copies `vendor\mdad` there. It
  holds no secrets and no CA any more; its provisioning makes it a new SSH key
  of its own, which the PC signs for each run like the old one.
- **Removing vault** deletes OpenBao's data: all secrets, the intermediate CA's
  key, the SSH CA's key, the ACME accounts. What that means is described above.

After a rebuild, deploy what the rebuilt VM runs:

| Rebuilt | Then run |
|---|---|
| firewall | nothing: its configuration comes from the repository, and the build gives it a new GUI certificate from the root and a new SSH host certificate (its old host key is revoked) |
| ansible-control | nothing (the next `Deploy-LabMatrix.ps1` copies MDAD there again) |
| keycloak | `.\scripts\Deploy-LabKeycloak.ps1` |
| matrix | `.\scripts\Deploy-LabMatrix.ps1` |
| vault, together with keycloak and matrix | `.\scripts\Deploy-LabVault.ps1`, `.\scripts\New-LabRecoveryKit.ps1` (in your own PowerShell window), `.\scripts\Deploy-LabKeycloak.ps1`, `.\scripts\Deploy-LabMatrix.ps1` (both take a snapshot of the new secrets) |
| vault alone | [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot) |
| the whole lab | `.\scripts\Initialize-Lab.ps1`, then as for vault together with keycloak and matrix. `Install-LabRootCA.ps1` is not needed again: the root CA stayed |

`New-LabFirewall.ps1 -Rebuild` uses `G:\Vagrant` by default; if you built the
lab with another `-StorageRoot`, pass it here too. It renders and checks the new
configuration **before** it deletes the old firewall, so a mistake in
`config/lab.json` or the template stops it while the old firewall keeps
running.

`New-LabFirewall.ps1` also has `-TimeZone` (an IANA name, default
`Europe/Berlin`), which sets the firewall's clock for its logs.
`Initialize-Lab.ps1` does not pass it. The value is written into the firewall's
`config.xml` only when the firewall is built, so to use another zone rebuild
with it, for example `.\scripts\New-LabFirewall.ps1 -Rebuild -TimeZone Europe/London`,
and pass it again on every later `-Rebuild`. A plain re-run keeps the zone the
firewall has.

### After a Windows restart

Run `.\scripts\Initialize-Lab.ps1`. The firewall VM is shut down together with
Windows and is not started automatically; the script starts it first, so that
DHCP, DNS and the jump host are ready before the lab VMs need them. The vault VM
is started right after it, directly in Hyper-V, and **OpenBao is unsealed**
with the key shares stored on the PC (next section), over HTTPS and before any
SSH: the PC's SSH certificate is valid for 8 hours, so after a restart it has
expired, and once OpenBao is deployed it is OpenBao that signs the new one
(`vagrant up` could not start the vault VM yet: it needs SSH). Then the script
checks the firewall: its SSH host certificate, its DNS drop-in, and its GUI
certificate, renewed in place if it is due. Then it starts whatever else is not
running, re-applies the provisioning of the Ubuntu VMs, checks their host
certificates, unseals OpenBao if it is still sealed (if OpenBao's TLS
certificate is due or expired, it runs `Deploy-LabVault.ps1` instead, which
renews the certificate first and then unseals; if the certificate has already
expired, the offline SSH CA signs until then, because renewing it needs SSH to
the vault VM and the pinned TLS check refuses an expired certificate) and tests
everything. If OpenBao does not come up at all, the script stops at the first
SSH login with the reason; `-BreakGlass` lets the offline SSH CA sign instead
([P53](#p53-ssh-host-key-verification-failed-or-permission-denied-publickey)).
The applications start with their VMs:
MDAD's systemd units are enabled, the Keycloak containers have Docker's restart
policy `unless-stopped`, and the `openbao` service is enabled (it starts
sealed). The Default Switch gets a new subnet on every Windows boot; the
firewall simply gets a new WAN address by DHCP when it boots. LabHost and
LabNet addresses never change, so `keys\ssh_config` and the DNS rule keep
working.

Its last step, **7/7 Maintenance** (once OpenBao is deployed), renews what is
due. A certificate is renewed only when the script that renews it runs, and
`Initialize-Lab.ps1` runs after every restart anyway, so it checks:

| What | Due when | Renewed by |
|---|---|---|
| OpenBao's TLS certificate | less than 30 days left | `Deploy-LabVault.ps1` |
| The root CA's revocation list | its next update less than 60 days away, or the copy the vault VM serves differs from the PC's (renewed on the PC, not yet published) | `Deploy-LabVault.ps1` (it renews and publishes it) |
| The intermediate CA | less than 400 days left | `Deploy-LabVault.ps1` (a rotation, see [Rotate the intermediate CA](#rotate-the-intermediate-ca)) |
| Keycloak's TLS certificate | less than 30 days left | `Deploy-LabKeycloak.ps1` |

It prints one line per item that is due and runs each named script once, or
reports that nothing is due. The checks need no login: they read the
certificates that OpenBao and Keycloak present, the root CRL on the PC and on
the vault VM, and the intermediate's public certificate (`Get-LabMaintenanceDue` in
[scripts/LabSecrets.ps1](scripts/LabSecrets.ps1)). Two certificates are not on
the list because they are handled elsewhere: the firewall's GUI certificate
(step 4, `New-LabFirewall.ps1`) and the Matrix certificates (Traefik renews
them itself). The SSH certificates are not on it either: the PC's is renewed
by whichever script needs it, and the host certificates (1 year) in steps 4 and
5, 30 days before they expire. If the PC runs for weeks without a restart, run
`Initialize-Lab.ps1` at least once a month anyway.

Enterprise equivalent: renewals do not wait for someone to restart a PC. An
agent on each server (an ACME client, cert-manager, certmonger, Vault Agent)
renews continuously, a scheduler runs the rest, and monitoring alerts on every
certificate and revocation list that comes close to its expiry.

### OpenBao after a restart: sealed and unsealed

**What "sealed" means.** After every start of the service (a boot of the vault
VM, `systemctl restart openbao`) OpenBao is **sealed**: it runs and answers, but
it cannot read its own encrypted data until 2 of its 3 **key shares** are
presented. Once unsealed, it keeps the key in memory only, until the next stop.
A `reload` (used for configuration changes, a new TLS certificate and log
rotation) does not seal it. Why it works this way, and why the vault VM
therefore has no Hyper-V checkpoints and no console autologin: "Seal, unseal and
Shamir's key shares" in
[Secrets management with OpenBao](#secrets-management-with-openbao).

**How the lab unseals.** Shares A and B are stored with DPAPI on the PC
(`keys\openbao\unseal-a.dpapi`, `unseal-b.dpapi`); share C is yours, on paper
or in a password manager, after `New-LabRecoveryKit.ps1`. Unsealing needs no
input:

```powershell
.\scripts\Unlock-LabVault.ps1                  # shares A and B from DPAPI; does nothing if already unsealed
.\scripts\Unlock-LabVault.ps1 -Interactive     # asks for two shares (recovery, in your own PowerShell window)
curl.exe -s https://vault.lab.internal:8200/v1/sys/health   # "sealed":false, "standby":false when ready
```

You rarely run it yourself: `Initialize-Lab.ps1` unseals OpenBao right after
starting the firewall and the vault VM, `Invoke-LabPlaybook.ps1` does it before
a playbook that needs OpenBao, the scripts do it before OpenBao signs a new SSH
certificate for the PC, and `Deploy-LabVault.ps1` in its own step 5. You need
it after the vault VM or the `openbao` service was restarted some other way
(`vagrant reload vault`, a restart on the VM). Right after unsealing, OpenBao's
storage first elects itself leader; until then it answers writes with "cannot
write to readonly storage". The script waits until OpenBao reports itself
active.

`-Interactive` asks for two shares instead of reading them from DPAPI: for the
case where the PC's DPAPI data is lost (a new Windows installation or profile)
and OpenBao only has to be unsealed. Type share B from the recovery file
(`.\scripts\New-LabRecoveryKit.ps1 -Open <file>` shows it) and share C from your
copy. It runs only in a real console window, because you type secrets into it.
To restore the PC's access completely (new logins, the shares back in DPAPI),
use `New-LabRecoveryKit.ps1 -Recover`, which unseals by itself
([Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys)).

**While OpenBao is sealed**, the running services keep working: Keycloak and
Matrix have their secrets in their own configuration, so logins, chat and calls
go on. What stops: deployments (no secrets), certificates (Traefik's ACME
renewals, Keycloak's CSR signing), and the intermediate CA's revocation list,
which nginx on the vault VM fetches from OpenBao. Windows caches that list
until it expires (up to 7 days); after that, `curl.exe` against the
Matrix or Keycloak names fails with a revocation error.

Enterprise equivalent: **auto-unseal**. OpenBao asks a key management service
(an HSM, a cloud KMS, or another OpenBao's transit engine) to decrypt its key at
start, so no person and no PC is needed after a restart. The Shamir shares then
become recovery keys, held by several people, each with one share. In the lab,
the PC's DPAPI plays the role of that first key ("secret zero").

### Back up OpenBao

```powershell
.\scripts\Backup-LabVault.ps1                                       # keys\openbao\snapshots\vault-<date-time>.snap
.\scripts\Backup-LabVault.ps1 -Destination Z:\DeployableServer-recovery   # and a copy in that (existing) folder
.\scripts\Backup-LabVault.ps1 -Keep 20                              # this run keeps 20; the next automatic one prunes to 10
```

**What it saves.** OpenBao's integrated storage (raft) exports all of its data
as one **snapshot** file: every secret with its versions, the policies, the
AppRoles, the PKI with the intermediate CA's key, the SSH CA's key, the ACME
accounts. The file
is encrypted by OpenBao's barrier, so it is useless without the key shares, and
it may be stored like any other backup. The script logs in as `pc-deploy`,
whose policy allows only this, creating run tokens and signing SSH
certificates, saves the file under
`keys\openbao\snapshots` and keeps the newest 10 there. `-Destination` copies it
to a folder that must already exist, for example a NAS share or a USB stick.
OpenBao must be unsealed.

**When.** No timer takes snapshots; the scripts take one at the moments that
matter:

- `Deploy-LabKeycloak.ps1` after its playbook and `Deploy-LabMatrix.ps1` after
  `matrix-prepare.yml`, on every run, also when the playbook failed: a first
  deployment creates secrets that from then on exist only in OpenBao, and the
  deployment that follows a secret you wrote by hand saves that one too.
- `Remove-Lab.ps1` right before it deletes the vault VM. If that fails, it
  relies on the newest snapshot from before, and when there is none while
  keycloak or matrix stay, it deletes nothing
  ([Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)).
- `Import-LabSecrets.ps1` after an import.

Take one yourself after a change that no deployment follows soon: a secret you
wrote by hand and do not deploy yet, or a new intermediate CA from
`Deploy-LabVault.ps1` (its key exists only inside OpenBao). Because every
deployment adds a snapshot, the 10 kept on the PC may cover only a few days:
copy one off the PC from time to time (`-Destination`). `-Keep` is no way to
keep more: it applies only to that one run, and the next automatic snapshot
(every deployment, `Remove-Lab.ps1`, `Import-LabSecrets.ps1`) calls the script
without it and prunes the folder back to the newest 10.

**Restore needs the key shares of the snapshot's time.** A snapshot restored
into a new OpenBao brings back the old installation's keyring, so it is
unsealed with the old shares (and the old logins work again); see
[Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot). That is why
`Remove-Lab.ps1` moves `keys\openbao`, snapshots and shares together. Keep a
copy of the snapshots off the PC, but not together with share C: a snapshot,
the recovery file (share B) and share C together open every secret of the lab.
The recovery file with its passphrase is, on its own, also an administrator
login for the running OpenBao: the break-glass login, accepted only from the
PC's address.

What a snapshot does not cover: the databases of Keycloak and Matrix. Their
backups are still on the [roadmap](#11-roadmap).

Enterprise equivalent: scheduled snapshots to off-site storage, monitored, with
regular restore drills; in larger setups also a replicated disaster-recovery
cluster, so a restore is the last resort rather than the plan.

### Using Vagrant directly

Vagrant manages only the four Ubuntu VMs; `vagrant status` does not list the
firewall. Inside the `vagrant` folder (elevated shell), the usual commands work
for them: `vagrant status`, `vagrant halt`, `vagrant up`, `vagrant reload`,
`vagrant ssh matrix`, `vagrant provision`, `vagrant destroy`. The firewall must
be running: the VMs get their address from its DHCP server, and Vagrant reaches
them through it (`ssh.proxy_command`). Every provisioner has a name, so you can
re-run a single step, for example `vagrant provision matrix --provision-with zsh`.
The names are `lab-ssh-ca`, `ansible-user`, `ssh-hardening`,
`console-autologin` and `zsh` (all VMs; on vault, `console-autologin` removes
the autologin again); `lab-ssh-known-hosts`, `lab-ssh-revoked-host-keys` and
`ansible-control` (ansible-control).

Vagrant logs in through the firewall with the PC's SSH certificate. Before
`vagrant up`, `provision`, `reload`, `ssh`, `ssh-config`, `halt` and `resume`,
the Vagrantfile therefore checks it and runs
`scripts\Update-LabSshCertificate.ps1` when it expires within 4 hours (the
scripts renew it themselves, so this matters only for vagrant commands you
type). Its proxy command names Windows' own `ssh.exe`: Vagrant puts an OpenSSH
of its own first in `PATH` for the programs it starts, and the lab is tested
with Windows' client. `vagrant ssh <vm>` logs in as `vagrant` with Vagrant's
per-VM key; sshd on the VMs lets `vagrant` in only through the jump host.
Vagrant alone does not install host certificates (that needs Hyper-V and the
PC's SSH CAs; `Initialize-Lab.ps1` does it), so after a VM was created or
rebuilt with `vagrant` alone, run `Initialize-Lab.ps1` before you connect to
it. Once OpenBao signs the certificates, a `vagrant` command can renew the
PC's certificate only while the vault VM runs: after a Windows restart, start
with `Initialize-Lab.ps1`.

Hyper-V checkpoints are switched off for vault (`"checkpoints": false` in
`config/lab.json`, applied by the Vagrantfile), so `vagrant snapshot` is no way
to back up OpenBao: use [Back up OpenBao](#back-up-openbao). After
`vagrant reload vault` or `vagrant up vault` OpenBao is sealed:
`.\scripts\Unlock-LabVault.ps1`.

Use a PowerShell window that has `VAGRANT_HOME` set: the window in which
`Initialize-Lab.ps1` ran, or any window opened after its first run. In a window
opened earlier, Vagrant would use `%USERPROFILE%\.vagrant.d` on C: and would
download the box again for a new VM. (`Remove-Lab.ps1` reads the value itself.)

To build or rebuild, prefer `Initialize-Lab.ps1`, because it guarantees the
right order (LabNet, then the firewall, then the lab VMs) and runs the tests;
to delete, prefer `Remove-Lab.ps1`, which also cleans up the Hyper-V folder.
The firewall itself is managed with `New-LabFirewall.ps1`, `Remove-Lab.ps1
firewall` or Hyper-V Manager, never with Vagrant.

---

## 6. How to ...

### Publish a name or a port

"Published" means reachable from your PC. Everything that is published is
listed under `published` in [config/lab.json](config/lab.json), one entry per
VM:

```json
"published": [
  {
    "vm": "matrix",
    "address": "10.10.99.3",
    "names": ["matrix", "element", "@"],
    "ports": [
      { "protocol": "tcp", "port": 443, "description": "HTTPS (Traefik: Synapse, MAS, Element, LiveKit signalling)" },
      { "protocol": "tcp", "port": 80, "description": "HTTP (Traefik redirects to HTTPS)" },
      { "protocol": "udp", "port": 7882, "description": "LiveKit media (WebRTC over UDP)" },
      { "protocol": "tcp", "port": 7881, "description": "LiveKit media (WebRTC over TCP, fallback)" }
    ]
  },
  { "vm": "keycloak", "address": "10.10.99.4", "names": ["keycloak"], "ports": [ ... ] },
  { "vm": "vault", "address": "10.10.99.5", "names": ["vault"], "ports": [ ... ] }
]
```

From each entry `New-LabFirewall.ps1` generates:

- **a virtual IP** (`address`) on the firewall's HOST interface. It must be in
  10.10.99.0/24 and unused; the script stops if two entries share an address or
  one uses the firewall's or the PC's address.
- **a port forward per port**, from `address:port` to the same port on the VM's
  lab address, with a registered pass rule. `protocol` is `tcp` or `udp`.
- **a DNS host entry per name** with two addresses (split horizon): your PC gets
  `address`, the lab gets the VM's own IP. `"@"` stands for the domain itself
  (`lab.internal`, as in DNS zone files). A name equal to the VM's name gets
  only the published address added, because the VM's DHCP reservation already
  provides the lab address (both details in
  [P7](#p7-published-host-entries-the-domain-itself-and-a-vms-own-name)).

To publish another name or port, edit the entry (or add one for another VM) and
rebuild the firewall. The data is read only when the firewall is built, so a
plain re-run does not pick it up:

```powershell
.\scripts\New-LabFirewall.ps1 -Rebuild
```

That takes about four minutes; passwords and API key stay the same (DPAPI in
`keys\opnsense\`), and the new firewall gets a new GUI certificate from the lab
root CA. The new configuration is rendered and checked before the old firewall is
deleted. At the end the script checks the first name of every entry from the PC.
Check further names yourself:

```powershell
Clear-DnsClientCache                         # forget an earlier "name not found"
Resolve-DnsName element.lab.internal         # expected: 10.10.99.3
Test-NetConnection 10.10.99.3 -Port 7881     # a published TCP port: TcpTestSucceeded True
```

Inside the lab the names resolve to the VM's own address.

Four things to know:

- **The firewall forwards by address and port, not by name.** Several names on
  one published address share its ports; the service behind it chooses the site
  by the requested host name (name-based virtual hosting; for HTTPS via SNI).
  On the matrix VM, Traefik does that: a new name there also needs a route in
  MDAD's configuration, or Traefik does not know what to serve.
- **HTTPS needs the name in the certificate, and the CA must allow it.** Use
  the full name (never a short name, see
  [P18](#p18-the-browser-or-openssl-rejects-the-certificate-or-windows-stops-trusting-it)).
  Each PKI role in OpenBao lists the names it may certify (`allowed_domains` in
  `$pkiRoles` in [Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1)): add the
  name to the role and run `.\scripts\Deploy-LabVault.ps1`. Then, for Matrix
  (role `acme-matrix`), the route in MDAD's configuration is enough: Traefik
  orders a certificate through ACME for each host name it routes. For Keycloak
  (role `keycloak`), add the name to `openbao_cert_names` in
  [keycloak.yml](ansible/playbooks/keycloak.yml) and force a new certificate
  (`.\scripts\Invoke-LabPlaybook.ps1 keycloak.yml -e tls_renew_before=+400d`):
  the renewal check looks only at the expiry date and the issuing CA, not at
  the names.
- **A published address carries only its own forwards.** A forward redirects
  its packets before any service on the firewall sees them, so the firewall's
  own services never get in the way. They are not reachable there either: the
  web GUI and SSH do not listen on the virtual IPs (`nobind`), and dnsmasq and
  ntpd, which listen on every address, are closed there by pf, because the PC
  rules name only 10.10.99.2 ([P8](#p8-the-firewall-answers-dns-on-a-published-address)).
- **LiveKit announces the matrix address itself.** If you change the matrix
  entry's `address`, also set `livekit_server_config_rtc_node_ip` in
  [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
  to the new address and run `.\scripts\Deploy-LabMatrix.ps1`; otherwise calls
  connect without audio or video
  ([P35](#p35-a-call-connects-but-no-audio-or-video-flows)).

For a quick test without a rebuild, make the same change in the GUI
(Interfaces > Virtual IPs, Firewall > NAT > Destination NAT, Services > Dnsmasq
DNS & DHCP > Hosts). Keep it in `lab.json` too: the GUI change is gone after the
next rebuild, the file is not.

### Open a port on the firewall itself

There are two ways, and it helps to know both:

- **In the GUI** (Firewall > Rules): the change is active as soon as you click
  Apply. Good for trying something out. But it lives only in the running
  firewall's `/conf/config.xml`, not in the repository, so the next rebuild
  removes it.
- **In [opnsense/config.xml.template](opnsense/config.xml.template)**, followed by
  `.\scripts\New-LabFirewall.ps1 -Rebuild`: slower (about four minutes), but the
  change is in the repository, reviewable, and survives every rebuild. This is
  the permanent way. (The enterprise middle way, changes through the REST API
  from Ansible, is on the [roadmap](#11-roadmap).)

For a service on the firewall itself, for the PC, add a pass rule on the HOST
interface. In the GUI: Firewall > Rules, interface HOST, a pass rule for TCP from
10.10.99.1 to the single host 10.10.99.2 and the port. Do not choose "HOST
address" as the destination: in pf that means every address on the interface,
including the published virtual IPs, so a service that listens on every
address (as dnsmasq does) would answer there too
([P8](#p8-the-firewall-answers-dns-on-a-published-address)). In the template:
copy one of the PC rules in `<OPNsense><Firewall><Filter><rules>` (sequence
10-14), give it the next free `<sequence>` (15), and change `<destination_port>`
and `<description>`.

A port forwarded to a lab VM is not written into the template by hand: add it
to the VM's `ports` in `config/lab.json` (previous section).

A good habit is to try a change in the GUI, then write it into the repository
and rebuild once to prove that the repository really describes the firewall. To
see exactly which XML a GUI change produced, open System > Configuration >
History: OPNsense keeps a copy of `config.xml` for every change and shows the
differences between two versions. (The rendered `config.xml` that the build
hands to the firewall is not kept on the PC: it holds password hashes and the
GUI's private key. It exists only while the firewall is built, in the seed ISO
and for a moment in the ISO's staging folder: the staging folder is deleted as
soon as the ISO is written, the ISO when the first boot is over, also when that
boot failed, and a later run of `New-LabFirewall.ps1` removes an ISO left
behind. A comparison of whole files would be noisy anyway: OPNsense fills in
default settings, model version attributes and revision data of its own.)

While rendering, the script checks that the result is well-formed XML and that
no placeholder is left over, and stops if not. With `-Rebuild` this happens
before the old firewall is deleted, so a broken template stops the script while
the old firewall keeps running (the same idea as a deployment pipeline that
validates the new version before it takes the old one down). Check the result
on the running firewall with:

```powershell
.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -s nat'   # port forwards (rdr) and outbound NAT
.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -sr'      # filter rules
```

### Add a VM

As an example, a small VM `hello` for the first demo of this lab (next
section):

1. Add it to `vms` in [config/lab.json](config/lab.json) with a unique MAC and
   an IP in 10.10.10.0/24 outside the DHCP pool (.100-.199) and other than .1
   (the firewall) and not yet taken (.50 is vault). Following the MAC
   convention (0x3C = 60):

   ```json
   { "name": "hello", "mac": "02000A0A0A3C", "ip": "10.10.10.60", "cpus": 1, "memory": 1024 }
   ```

   The Vagrantfile reads this list, so the name becomes the hostname, the
   Hyper-V VM name and the DNS name `hello.lab.internal`. `cpus` and `memory`
   (MB) set the VM's size; without them a VM gets 2 vCPUs and 2048 MB. Make sure
   the host has the extra RAM.

2. If the PC should reach it, publish it (see above), for example:

   ```json
   {
     "vm": "hello",
     "address": "10.10.99.6",
     "names": ["hello"],
     "ports": [
       { "protocol": "tcp", "port": 443, "description": "HTTPS (nginx)" },
       { "protocol": "tcp", "port": 80, "description": "HTTP (nginx redirects to HTTPS)" }
     ]
   }
   ```

3. Add it to the Ansible inventory [ansible/inventory/hosts.ini](ansible/inventory/hosts.ini),
   by DNS name, in a group named by its role. The group name must differ from
   the host name ([P22](#p22-ansible-warns-that-a-group-and-a-host-have-the-same-name)).
   For the demo, the existing group `[web]`:

   ```ini
   [web]
   hello ansible_host=hello.lab.internal
   ```

4. Give the firewall the new DHCP reservation (MAC -> IP), the DNS name and the
   published address. All of them are part of its configuration, which is
   rendered from `lab.json` only when the firewall is built:

   ```powershell
   .\scripts\New-LabFirewall.ps1 -Rebuild
   ```

   Without the reservation the new VM would get a random address from the pool
   and no DNS name. The jump host's list of allowed forwarding targets
   (`PermitOpen` in its sshd drop-in) is rendered from `lab.json` too, so only
   after this step does it let SSH through to the new VM.

5. Once OpenBao is deployed, run `.\scripts\Deploy-LabVault.ps1`. OpenBao's SSH
   roles are made from `lab.json`: the role `lab-hosts` certifies exactly the
   lab's host names, and the role `ansible-control` knows the principal
   `host-<vm>` of every VM. Until this run, OpenBao refuses a host certificate
   for `hello.lab.internal`.

6. Run `.\scripts\Initialize-Lab.ps1`. It adds the VM to `keys\ssh_config` and
   to the SSH trust files (both from `lab.json`), creates and provisions the
   VM, signs and installs its host certificate, and tests DNS, SSH and
   `ping.yml`.

7. Write or run a playbook for the new group. Give it an entry in
   `$sshPrincipals` in [Invoke-LabPlaybook.ps1](scripts/Invoke-LabPlaybook.ps1)
   (for example `@('host-hello')`); without one, its runs get a certificate for
   every machine (`lab-all`).

### Run the hello-nginx demo on a VM of its own

[ansible/playbooks/hello-nginx.yml](ansible/playbooks/hello-nginx.yml) was the
lab's first deployment: nginx serving a "Hello World" page over HTTPS. It is
kept because it shows the classic certificate pattern in its purest form: the
server creates its own private key and a CSR, only the CSR travels, and the
intermediate CA in OpenBao signs it
([tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml),
the same task file Keycloak uses). It targets the group `[web]`, which is empty
today, and refuses to run on a VM where the Matrix stack's Traefik holds ports
80/443. (Not yet tried in this lab since the move to OpenBao.)

Two names have to match:

- **The VM must be called `hello`.** The playbook asks for a certificate for
  `<inventory name>.lab.internal`, so the inventory name must be the VM's name,
  and the PKI role `web` it uses allows exactly `hello.lab.internal`. For a VM
  with another name, add its name to `allowed_domains` of the role `web` in
  [Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) and run
  `.\scripts\Deploy-LabVault.ps1` first.
- **The run token** of this playbook has the policy `ansible-web`: it may have
  certificates of the role `web` signed and nothing else, not even read a
  secret.

With the VM `hello` from the previous section (in `[web]`, published with ports
443 and 80), and OpenBao deployed:

```powershell
.\scripts\Invoke-LabPlaybook.ps1 hello-nginx.yml
curl.exe https://hello.lab.internal      # expected: <h1>Hello World</h1>
```

The certificate is valid for one year and renewed by the same playbook when
less than 30 days are left or when it does not come from the current
intermediate CA (after a rotation); force a renewal with
`.\scripts\Invoke-LabPlaybook.ps1 hello-nginx.yml -e tls_renew_before=+400d`.

### Add a Keycloak user

The users are code: the list `lab_keycloak_users` in the last play of
[ansible/playbooks/keycloak.yml](ansible/playbooks/keycloak.yml), and each
user's password is a secret in OpenBao, `keycloak/users/<name>`. Not yet tried
in this lab: the steps below follow the code in `keycloak.yml` but have not
been run end to end, so check the result yourself by signing in as the new
user. For a user `carol`:

1. Add a line to `lab_keycloak_users`. Email, first and last name are required
   by Keycloak's user profile (without them the first login would stop at an
   "update your profile" page); the user name becomes the Matrix ID
   `@carol:lab.internal` and cannot be changed later:

   ```yaml
   - { username: carol, first_name: Carol, last_name: Lab, email: "carol@{{ lab_domain }}", password_var: vault_keycloak_carol_password }
   ```

2. Add her secret to `keycloak_openbao_secrets` in the first play of the same
   file, so that the playbook reads it from OpenBao:

   ```yaml
   - { path: keycloak/users/carol, field: password, policy: lab-alnum-24 }
   ```

3. Give the value the name that `password_var` refers to, in
   [ansible/playbooks/vars/keycloak-secrets.yml](ansible/playbooks/vars/keycloak-secrets.yml):

   ```yaml
   vault_keycloak_carol_password: "{{ hostvars['ansible-control'].lab_secrets['keycloak/users/carol'] }}"
   ```

4. Create her password in OpenBao yourself. On a lab whose Keycloak database
   already exists, the playbook generates no missing secret at all: it cannot
   tell a new user's password from a lost database password, and a wrong guess
   would lock Keycloak out of its database. (On a brand-new lab, before the
   first `Deploy-LabKeycloak.ps1`, the playbook would generate it with the
   policy from step 2.) As administrator (see
   [Write or change a secret](#write-or-change-a-secret-administrator)); `cas = 0`
   refuses if the secret already exists:

   ```powershell
   . .\scripts\LabSecrets.ps1
   $token = Get-LabBaoToken 'pc-admin'
   $value = (Invoke-LabBao GET 'sys/policies/password/lab-alnum-24/generate' -Token $token).data.password
   Invoke-LabBao POST 'lab/data/keycloak/users/carol' @{ options = @{ cas = 0 }; data = @{ password = $value } } -Token $token | Out-Null
   $value = $null; Close-LabBaoToken $token
   ```

5. Run `.\scripts\Deploy-LabKeycloak.ps1`. It reads the new secret and creates
   the user, then takes a snapshot of OpenBao, which now contains her
   password.

6. `.\scripts\Show-LabSecret.ps1 keycloak/users/carol` copies her password to
   the clipboard. carol signs in to Element; her Matrix account is created on
   that first login.

Good to know:

- The user module does not compare passwords. A password changed later in
  OpenBao is applied only when another attribute of the user changes in the
  same run; change a password deliberately in the admin console (realm
  `lab` > Users > the user > Credentials). Under `--check` the task therefore
  reports every user as `changed`
  ([P49](#p49---check-reports-the-lab-users-as-changed)).
- Removing a line does not delete the user: the playbook only makes sure the
  listed users exist. Disable or delete a user in the admin console. Her Matrix
  account then stays, but she can no longer sign in; Element sessions that are
  already signed in are not ended by that (see back-channel logout in
  [Identity](#identity-idp-oidc-and-single-sign-on)). Her secret stays in
  OpenBao until you delete it there.
- Admin rights in Matrix are not a Keycloak role here: `admin_users` in the MAS
  policy in [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
  lists them (today `alice`); apply a change with `Deploy-LabMatrix.ps1`.

### Change a Matrix setting

All Matrix settings are MDAD variables in
[ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml).
MDAD has thousands of variables with defaults (in the `defaults/main.yml` of
its roles and in its `group_vars/matrix_servers`, both in `vendor\mdad` in
this repository, and in its copy `~/mdad` on ansible-control); the file sets
only what differs for the lab. Edit it, then:

```powershell
.\scripts\Deploy-LabMatrix.ps1           # adding or changing something
.\scripts\Deploy-LabMatrix.ps1 -Setup    # after REMOVING a component (runs the uninstall tasks)
```

A few values are fixed after the first installation and must not be changed on
a running lab (only by starting over with an empty database): `matrix_domain`
(part of every user and room ID), `matrix_homeserver_implementation` and the
secrets in OpenBao, `matrix/generic-secret-key` and `matrix/postgres` (MDAD
derives passwords and keys from the first, MAS's encryption key included).
`devture_systemd_docker_base_ipv6_enabled` is a
different case: the database is not affected, but changing it later means
recreating all of MDAD's container networks, so it is set early.

### Upgrade MDAD (and with it the Matrix components)

MDAD is the GitHub repository
[spantaleev/matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy).
It has no releases or tags: every commit on its `master` branch is a version.
The lab pins one exact commit (today `a52e9876526aa6dcd41075b3a83d5eea7c31887b`)
and keeps MDAD's code at that commit in the repository, in `vendor\mdad`,
together with the 32 roles MDAD needs ([vendor/README.md](vendor/README.md)).
An upgrade is the only time MDAD is downloaded: one script, then a few
deliberate edits. (No upgrade to a newer commit has been made in this lab yet.
Check the result yourself with MDAD's self-check, which `Deploy-LabMatrix.ps1`
runs, and a login.)

1. **Fetch the new version into the repository.** Take the full commit hash
   (40 characters) from MDAD's
   [commit list](https://github.com/spantaleev/matrix-docker-ansible-deploy/commits/master),
   then, with the lab running and nothing uncommitted in the repository:

   ```powershell
   .\scripts\Update-LabMdad.ps1 -Commit <40-character commit hash>
   ```

   `vendor\mdad` is a **git subtree** of MDAD's repository, so the script
   updates it with Git and makes two commits:
   - `git subtree pull --prefix vendor/mdad <MDAD's URL> <commit> --squash`:
     Git fetches the commit from GitHub and merges the upstream changes into
     `vendor\mdad`, as one commit ("--squash": a summary instead of all of
     MDAD's commits since the last pull);
   - MDAD's roles: on ansible-control (it has Ansible and internet access
     through the firewall) `ansible-galaxy install -r requirements.yml` installs
     them at the versions the new `requirements.yml` pins (what MDAD's
     `just roles` does); they replace `vendor\mdad\roles\galaxy` and are
     committed with `git add -f` (MDAD's own `.gitignore` ignores that folder,
     because upstream installs the roles on demand). The marker file
     `.lab-vendored-commit` is updated in the same commit.

   Nothing in the running lab changes yet.
2. **Read what changed.** First as a list of changed files, then in full:

   ```powershell
   git show --stat HEAD~1 HEAD
   git diff HEAD~2 -- vendor/mdad
   ```

   and read MDAD's `vendor\mdad\CHANGELOG.md` from the old commit up to the new
   one. It lists breaking changes and the new migration version.
3. Set `mdad_version` in [matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml)
   to the new commit. `Deploy-LabMatrix.ps1` refuses to run while it differs
   from `vendor\mdad\.lab-vendored-commit`, and `matrix-prepare.yml` checks the
   copy in `~/mdad` against it again.
4. Raise `matrix_playbook_migration_validated_version` in `vars.yml` to the
   version you read the notes up to. MDAD refuses to run until this matches,
   so nobody upgrades by accident without reading. Adjust other settings in
   `vars.yml` if the changelog says so. Commit these edits.
5. Deploy: `.\scripts\Deploy-LabMatrix.ps1`, or `.\scripts\Deploy-LabMatrix.ps1 -Setup`
   if the changelog says that components were removed or renamed (only the
   tags of `setup-all` run the uninstall tasks). It copies the new
   `vendor\mdad` to `~/mdad` and runs it.
6. When everything works: `git push`.

The script prints steps 2 to 6 again when it ends. Going back to the old commit
(`git revert` of the upgrade commits, `mdad_version` back, `Deploy-LabMatrix.ps1`)
restores MDAD's code, but not necessarily the data: a
newer Synapse or MAS may already have migrated its database to a form that the
older version cannot read. A backup of the matrix VM's data before the upgrade
is the safe way back, and the lab has none yet ([roadmap](#11-roadmap)).

Keycloak is upgraded with a similar deliberate edit, in
[keycloak.yml](ansible/playbooks/keycloak.yml): its image is pinned, not
vendored, and `keycloak_image` holds tag
**and** digest; change both (after reading Keycloak's upgrade notes) and run
`Deploy-LabKeycloak.ps1`. The PostgreSQL major version (`postgres:18.6`) must not
be raised in place: a new major version cannot read the old data directory
without a dump and restore.

### Renew certificates

The lab has two kinds of certificates. Most come from the **intermediate CA in
OpenBao** and are renewed by whoever uses them. Two come directly from the
**offline root on the PC**: OpenBao's own (an expired OpenBao certificate could
otherwise only be renewed through the server it protects) and the firewall's
GUI (the firewall exists before OpenBao). Renewal never needs a rebuild.

| Certificate | Issued by; where its key is made | Valid | Renewed | Force a renewal now |
|---|---|---|---|---|
| Matrix (`matrix`, `element`, `lab.internal`) | intermediate CA through ACME (role `acme-matrix`); key made by Traefik on the matrix VM, kept in `/matrix/traefik/ssl/acme.json` | 90 days | automatically by Traefik after two thirds of its lifetime (about 30 days before it expires); needs an unsealed OpenBao. After a rotation, `matrix-prepare.yml` makes Traefik start over (below) | rarely needed: `.\scripts\Connect-Lab.ps1 matrix 'sudo rm /matrix/traefik/ssl/acme.json && sudo systemctl restart matrix-traefik'`, then `.\scripts\Deploy-LabMatrix.ps1`, whose checks wait up to 3 minutes for certificates from the current intermediate CA. This is by hand what `matrix-prepare.yml` does by itself after a rotation |
| Keycloak (`keycloak.lab.internal`) | intermediate CA, CSR signing (role `keycloak`); key made on the keycloak VM, a new one on every renewal | 1 year | by `Deploy-LabKeycloak.ps1` when less than 30 days are left (`Initialize-Lab.ps1` then runs it by itself) or the certificate is not from the current intermediate CA; Keycloak restarts | `.\scripts\Invoke-LabPlaybook.ps1 keycloak.yml -e tls_renew_before=+400d` |
| hello demo (`hello.lab.internal`) | intermediate CA, CSR signing (role `web`); key made on the hello VM | 1 year | by `hello-nginx.yml`, same rule (not by `Initialize-Lab.ps1`) | `.\scripts\Invoke-LabPlaybook.ps1 hello-nginx.yml -e tls_renew_before=+400d` |
| OpenBao (`vault.lab.internal`, port 8200) | offline root; key made on the vault VM and kept across renewals | 397 days | by `Deploy-LabVault.ps1` when less than 30 days are left (`Initialize-Lab.ps1` then runs it by itself). It reloads OpenBao (`systemctl reload`), which reads the new certificate without sealing | no switch; every run checks the 30 days |
| Firewall GUI (`firewall.lab.internal`) | offline root; key made on the firewall | 397 days | in place by `New-LabFirewall.ps1` (also run by `Initialize-Lab.ps1`) when less than 30 days are left or it is not from the root | `.\scripts\New-LabFirewall.ps1 -Rebuild` (a new firewall gets a new certificate) |
| Intermediate CA, today "DeployableServer Lab Intermediate CA 2026-10-24" (issuer `lab-int-20261024`) | offline root; key generated inside OpenBao (EC P-384), never exported | 3 years | replaced by a new one (a rotation) by `Deploy-LabVault.ps1` when it has less than 400 days left (`Initialize-Lab.ps1` then runs it by itself). Certificates it issues never outlive it: OpenBao shortens them to its end date | `.\scripts\Deploy-LabVault.ps1 -RotateIntermediate` ([Rotate the intermediate CA](#rotate-the-intermediate-ca)) |
| Root CA "DeployableServer Lab Root CA 2026" | itself; key encrypted in `keys\pki` | 10 years | never automatically | a new root means trusting it again on every client (`Install-LabRootCA.ps1`) |

The SSH certificates are not in this table: they are OpenSSH certificates, not
X.509, and come from the lab's SSH CAs (the PC's for 8 hours, one per Ansible
run for 2 hours, the hosts' for 1 year). Their lifetimes and renewals are in
[SSH certificates](#ssh-certificates-user-and-host-cas).

How the in-place renewals work, in short: Keycloak's and hello's come from
[tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml):
a new key and CSR are made next to the current pair (`<key>.new`), OpenBao
signs the CSR, and key and certificate replace the old pair together, so the
service never sees a key that does not match its certificate. The firewall's
works the same way across machines: `New-LabFirewall.ps1` has the firewall make
the key and CSR, signs the CSR on the PC with the root, and installs key and
certificate with [opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php) through
OPNsense's own configuration code, then restarts the web GUI. Traefik does all
of it by itself with ACME: it proves to OpenBao that it serves the name (HTTP-01:
OpenBao fetches a token from `http://<name>/.well-known/acme-challenge/` from
the vault VM, over the lab's DNS) and receives the certificate.

**"From the current intermediate CA"** is decided by key identifiers, not by
names: a certificate comes from the current intermediate when its *authority
key identifier* equals the *subject key identifier* of OpenBao's current issuing
CA (`pki_int/ca/pem`). `tasks/openbao-certificate.yml` (Keycloak, hello),
`matrix-prepare.yml` (Traefik) and the checks of `Deploy-LabMatrix.ps1` all
compare this way; why names are not enough is explained in
[Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation).

**Revocation lists.** Every certificate names where its CA publishes its
revocation list (CRL), served by the vault VM on port 80, and Windows checks
them. Two kinds of list exist:

- **The root's CRL**, valid 400 days. `New-LabRootCA.ps1` renews it when less
  than 60 days are left, on every call (also when it signs the firewall's GUI
  certificate); `Deploy-LabVault.ps1` runs that script and then publishes the
  list (`openbao.yml` copies `keys\pki\pub\root-ca.crl` to the vault VM), and
  `Initialize-Lab.ps1` runs `Deploy-LabVault.ps1` when the list is due or the
  copy the vault VM serves differs from the PC's. By hand: `.\scripts\New-LabRootCA.ps1 -RenewCrl`, then
  `.\scripts\Deploy-LabVault.ps1`; renewing alone changes only the PC's copy.
  An expired root CRL breaks revocation checks for every lab certificate:
  `curl.exe` fails, Windows reports the revocation server as offline.
- **One CRL per intermediate CA**, valid 7 days, rebuilt by OpenBao itself
  before it expires, also for an older intermediate that is kept after a
  rotation. They are served only while OpenBao is unsealed.

The routine that keeps everything valid: `Initialize-Lab.ps1` after every
Windows restart, and at least once a month if the PC runs longer. Its
maintenance step runs `Deploy-LabVault.ps1` and `Deploy-LabKeycloak.ps1` when
something of theirs is due ([After a Windows restart](#after-a-windows-restart)),
step 4 renews the firewall's certificate, and Traefik renews Matrix's by
itself. Keep OpenBao unsealed. `Deploy-LabMatrix.ps1` prints the expiry dates of
the three Matrix certificates; for the others, look at the certificate in the
browser.

Enterprise equivalent: short-lived certificates renewed automatically by an
agent or ACME client on every server (as Traefik does here), expiry monitoring
with alerts, and the offline root used only in a planned ceremony, for example
to sign the next intermediate CA well before the current one expires (the lab
does that 400 days ahead).

### Rotate the intermediate CA

The intermediate CA in OpenBao signs every everyday certificate, so it must
stay valid longer than the longest certificate it issues (Keycloak's, 1 year).
`Deploy-LabVault.ps1` therefore makes a new one when the current one has less
than 400 days left, about 23 months into its 3 years. Replacing a CA this way,
while the old one stays valid, is a **rotation**. Tested in this lab on
2026-10-24 (with `-RotateIntermediate`, then both deployments). To rotate now,
for example after a suspected compromise of its key, or to try it (a real
compromise would also need the old intermediate revoked in the root's CRL,
which no script does yet):

```powershell
.\scripts\Deploy-LabVault.ps1 -RotateIntermediate   # a new intermediate CA, now the default issuer
.\scripts\Deploy-LabKeycloak.ps1                     # Keycloak moves to it (and a snapshot)
.\scripts\Deploy-LabMatrix.ps1                       # Traefik moves to it (and a snapshot)
```

What `Deploy-LabVault.ps1` does:

1. OpenBao generates a new key inside itself (EC P-384, never exported) and a
   CSR for it. Key and issuer are named after the moment they were made,
   `lab-int-<yyyyMMdd-HHmmss>` (names in OpenBao must be unique, and a second
   rotation on the same day must not reuse the key behind the current issuer),
   with the common name "DeployableServer Lab Intermediate CA <yyyy-MM-dd>".
   (The first intermediate of an empty OpenBao is named after the year:
   `lab-int-<yyyy>`, "DeployableServer Lab Intermediate CA <yyyy>". The lab's
   current one, `lab-int-20261024`, was made by an earlier version of the
   script, which used the date only.)
2. The offline root on the PC signs the CSR (3 years; a copy of the certificate
   goes to `keys\pki\issued\<name>.crt`), and OpenBao imports the certificate.
3. The new issuer becomes the **default**: every new certificate comes from it,
   by CSR signing and by ACME. The old issuer stays in OpenBao and its CRL
   keeps being published: the certificates it issued remain valid until they
   expire or are replaced. No script removes it.

The services move over by themselves at their next deployment, because each
compares its certificate with the current issuer (AKI and SKI, above):
`keycloak.yml` (and `hello-nginx.yml`) requests a new certificate, and
`matrix-prepare.yml` sees that Traefik serves a certificate from an older lab
intermediate, deletes `/matrix/traefik/ssl/acme.json` (Traefik's ACME account
and certificates) and restarts `matrix-traefik`, which registers again and
orders new certificates. `Deploy-LabMatrix.ps1` then waits until all three names
serve a certificate from the current issuer. Nothing changes for Windows or the
services' trust stores: both intermediates chain to the same root.

Run the two deployments right after a rotation even though nothing forces you
to (the old certificates stay valid until they expire): they move the services
over, and their snapshots save the new intermediate's key, which exists only in
OpenBao. After a rotation that `Initialize-Lab.ps1` started by itself, run them
too.

Today the default issuer is "DeployableServer Lab Intermediate CA 2026-10-24"
(`lab-int-20261024`); the first one, "DeployableServer Lab Intermediate CA 2026"
(`lab-int-2026`), is still in OpenBao for its CRL.

Enterprise equivalent: the same overlap rotation, planned well ahead in the
certificate policy, with the new intermediate signed in a root key ceremony and
the old one revoked or left to expire once nothing depends on it.

### Rotate the MAS client secret

The client secret is the password MAS uses towards Keycloak. It lives in
OpenBao at `keycloak/clients/matrix-authentication-service` (field `secret`),
and both sides read it from there: `keycloak.yml` sets it on Keycloak's client,
and `lab-setup.yml` hands it to MDAD for MAS's configuration. A rotation is a
new version in OpenBao followed by both deployments; logins fail between steps
2 and 3. (Not yet tried in this lab: the steps follow `keycloak.yml`,
`lab-setup.yml` and the OpenBao policies but have not been run end to end;
step 4 is the check.)

Why by hand: the playbooks' policies allow `create` and `read`, never `update`.
`ansible-keycloak` could create this secret on a new installation but never
change it, and `ansible-matrix` may only read it. So no deployment can rotate a
secret by accident; a rotation is an administrator's decision, made with the
`pc-admin` login.

1. Write a new version, generated by OpenBao like the first one (48 letters and
   digits). `cas` is the current version, so the write fails if someone else
   changed the secret in the meantime:

   ```powershell
   . .\scripts\LabSecrets.ps1
   $token = Get-LabBaoToken 'pc-admin'
   $path = 'keycloak/clients/matrix-authentication-service'
   $version = (Invoke-LabBao GET "lab/metadata/$path" -Token $token).data.current_version
   $value = (Invoke-LabBao GET 'sys/policies/password/lab-alnum-48/generate' -Token $token).data.password
   Invoke-LabBao POST "lab/data/$path" @{ options = @{ cas = $version }; data = @{ secret = $value } } -Token $token | Out-Null
   $value = $null; Close-LabBaoToken $token
   ```

2. `.\scripts\Deploy-LabKeycloak.ps1`: the client task sets the new secret in
   Keycloak, and the snapshot at the end of the script saves the new version.
3. `.\scripts\Deploy-LabMatrix.ps1`: `lab-setup.yml` reads the new version, MDAD
   writes MAS's new configuration, and the start step of `install-all` restarts
   the services.
4. Sign in once. The script's checks do not prove the secret: MAS redirects to
   Keycloak before it ever uses the secret (step 7 of
   [The login flow](#the-login-flow)). A wrong secret shows up only as a failed
   login, with an error in MAS's log.

To go back, the previous value is still in OpenBao (the last 10 versions are
kept): read it with
`Invoke-LabBao GET "lab/data/${path}?version=<n>" -Token $token`, write it as a
new version the same way, and run both deployments again.

Enterprise equivalent: the lab now has the secrets-manager part (one place,
versions, an audit log, write-once policies for automation). What it lacks is
the routine: an owner and an expiry date per secret, and rotation on a
schedule. Some IdPs allow two valid client secrets at once, so a rotation causes
no downtime. Even better are client credentials without shared secrets
(`private_key_jwt`: the client signs a token with its own key).

### Restore OpenBao from a snapshot

Manual and advanced, and not yet tried in this lab: the steps follow
OpenBao's API and the lab's scripts but have not been run end to end. You need
it in one situation above all: the vault VM was deleted or broken while
Keycloak and Matrix keep their data. Their databases were set up with the
secrets in OpenBao; new secrets would not open them, so the deployment scripts
refuse to continue until the old OpenBao data is back.

What you need:

- a snapshot ([Back up OpenBao](#back-up-openbao)). `Remove-Lab.ps1` takes one
  right before it deletes the vault VM, so after `Remove-Lab.ps1 vault` the
  newest one is in `keys\openbao-retired-<date-time>\snapshots`; or a copy
  elsewhere;
- the files of the installation the snapshot came from: its key shares A and B
  and its logins `pc-admin` and `pc-deploy`, all in that same
  `keys\openbao-retired-<date-time>` folder. The scripts use them only from
  `keys\openbao`, so step 3 moves them back. Each one can also be read where it
  is, for example share A for `Unlock-LabVault.ps1 -Interactive`:
  `.\scripts\Show-LabSecret.ps1 -Pc openbao-retired-<date-time>/unseal-a -Show`
  (without `-Show` it goes to the clipboard). DPAPI binds each file to its
  original name `openbao/<name>`, and the scripts map a retired name back to it.

If the vault VM still exists but is broken, so that OpenBao cannot be reached
or unsealed, `Remove-Lab.ps1 vault` cannot take a fresh snapshot. It warns,
names the newest snapshot already in `keys\openbao\snapshots` and goes on; that
snapshot moves to `keys\openbao-retired-<date-time>` with the rest, and it is the
one to restore. Only if there is no snapshot at all while keycloak or matrix
exist, it refuses and deletes nothing: OpenBao's data on the VM is then the only
copy of their secrets, so try to bring it up first (`.\scripts\Initialize-Lab.ps1`).
Only when you are sure that it is lost, delete the VM yourself (in the `vagrant`
folder, elevated: `vagrant destroy -f vault`; then remove its leftover Hyper-V
folder, see [P14](#p14-a-removed-vm-leaves-its-hyper-v-folder-behind)) and run
`.\scripts\Remove-Lab.ps1 vault`: with the VM gone, it takes no snapshot; it
revokes vault's old host key (and sends the new revocation list to
ansible-control if it runs) and moves `keys\openbao` aside, together with
OpenBao's SSH CA files `keys\ssh\openbao-ca.pub` and `openbao-ca.trusted` (into
its `ssh` subfolder), so the offline SSH CA signs again.

The idea: the restore is an API call, so it needs a running, unsealed OpenBao
and an administrator token. So a new, temporary OpenBao is set up first, and
the snapshot is then forced into it (`sys/storage/raft/snapshot-force`; the
plain `sys/storage/raft/snapshot` refuses a snapshot of another installation).
This replaces all of its data, including its keyring, with the snapshot's:
from then on the **old** shares unseal it and the old logins work, while the
temporary installation's shares and logins are worthless.

1. A new, empty OpenBao on a rebuilt vault VM (in an elevated PowerShell; skip
   `Remove-Lab.ps1` if it has run already). Skip `New-LabRecoveryKit.ps1` for
   this temporary installation (ignore its "PENDING" line), and deploy nothing
   else yet.

   ```powershell
   .\scripts\Remove-Lab.ps1 vault
   .\scripts\Initialize-Lab.ps1
   .\scripts\Deploy-LabVault.ps1
   ```

2. Force the snapshot into it, as the temporary installation's administrator:

   ```powershell
   . .\scripts\LabSecrets.ps1
   $token = Get-LabBaoToken 'pc-admin'
   $snap = (Resolve-Path 'keys\openbao-retired-<date-time>\snapshots\vault-<date-time>.snap').Path
   Invoke-WebRequest -UseBasicParsing -Method Post -Headers @{ 'X-Vault-Token' = $token } -ContentType 'application/octet-stream' -InFile $snap -Uri 'https://vault.lab.internal:8200/v1/sys/storage/raft/snapshot-force'
   ```

3. Put the old installation's files back in place, and move the temporary
   installation's SSH CA aside:

   ```powershell
   Move-Item keys\openbao keys\openbao-discarded              # shares and logins of the temporary installation
   Move-Item 'keys\openbao-retired-<date-time>' keys\openbao
   New-Item -ItemType Directory keys\openbao-discarded\ssh | Out-Null
   Move-Item keys\ssh\openbao-ca.pub, keys\ssh\openbao-ca.trusted keys\openbao-discarded\ssh\   # the temporary installation's SSH CA
   ```

   The restored OpenBao has the SSH CA of the snapshot's time (or none, for a
   snapshot from before OpenBao signed SSH certificates), not the one step 1
   made every machine trust, and the scripts stop as long as that is so
   ("OpenBao serves another SSH CA than the one the machines trust", or, without
   an SSH CA, "OpenBao GET ssh/public_key failed"). Without
   these two files the offline SSH CA signs again, so SSH keeps working, and
   step 5 makes the restored SSH CA trusted everywhere.

4. Unseal with the **old** shares. If the script reports "already unsealed",
   restart OpenBao first, so that it starts with the restored keyring:

   ```powershell
   .\scripts\Unlock-LabVault.ps1
   .\scripts\Connect-Lab.ps1 vault 'sudo systemctl restart openbao'   # only if it reported "already unsealed"
   .\scripts\Unlock-LabVault.ps1
   ```

5. Re-apply the configuration from the code, check, and deploy:

   ```powershell
   .\scripts\Initialize-Lab.ps1            # the machines stop trusting the temporary SSH CA; the offline SSH CA signs
   .\scripts\Deploy-LabVault.ps1           # logs in with the restored pc-admin; finds the restored intermediate CA; step 8: the restored SSH CA trusted everywhere
   .\scripts\Show-LabSecret.ps1 -List      # the secrets are back
   .\scripts\Deploy-LabKeycloak.ps1
   .\scripts\Deploy-LabMatrix.ps1
   ```

6. Make a new recovery file: `.\scripts\New-LabRecoveryKit.ps1 -Renew` (in your
   own PowerShell window). Your share C fits the restored installation again,
   but its break-glass login is the one of the snapshot's time, which may be
   older than your newest recovery file
   ([Renew the recovery kit](#renew-the-recovery-kit)).

The intermediate CA that step 1 created disappears with the temporary data
(its key existed only there); only its certificate is left on the PC, in
`keys\pki\issued`, and it can sign nothing without its key. The same goes for
the SSH CA that step 1 created.
`keys\openbao-discarded` holds only the temporary installation's shares and
logins and the public files of its SSH CA, which are worthless now.

If the PC's DPAPI data is lost as well (a new Windows installation), the old
installation's files in `keys\openbao-retired-<date-time>` cannot be decrypted,
so steps 3 and 4 do not work as written. The way back in is then the recovery
kit: once the snapshot is restored, `.\scripts\New-LabRecoveryKit.ps1 -Recover
<file>` unseals with share B from the file and share C from your copy, logs in
with the break-glass login and stores new logins with DPAPI
([Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys)).
Use the recovery file that was current when the snapshot was taken: every kit
replaces the break-glass secret, and the restored OpenBao knows only the one of
its time. This combination has not been tried in this lab, and no script guides
it.

To roll the **same** installation back to an earlier state (same shares), the
call in step 2 goes to `sys/storage/raft/snapshot` instead, and steps 1 and 3
are not needed. (Only if the snapshot is older than OpenBao's SSH CA: it has no SSH CA, and the
scripts stop with "OpenBao GET ssh/public_key failed (HTTP ...)". Then move the
two `keys\ssh\openbao-ca.*` files aside as in step 3 and run `Initialize-Lab.ps1`
before `Deploy-LabVault.ps1`, which creates a new SSH CA and makes it trusted.)

Enterprise equivalent: a written and rehearsed restore procedure, snapshots
off-site, the key shares (or recovery keys) held by several custodians who
meet for a recovery, and break-glass credentials that are kept sealed, used
only under four-eyes control and replaced after every use. A replicated standby
cluster makes most restores unnecessary.

### Renew the recovery kit

The recovery kit is made once per OpenBao installation, right after it was
initialised: `.\scripts\New-LabRecoveryKit.ps1` without a switch shows key
share C, writes the recovery file and then deletes the PC's temporary copy of
share C (what the kit is and why:
[Break-glass: the recovery kit](#break-glass-the-recovery-kit)). Run without a
switch again, it refuses and points to `-Renew`, the way to a new recovery file
later:

```powershell
.\scripts\New-LabRecoveryKit.ps1 -Renew -Destination E:\                      # a USB stick
.\scripts\New-LabRecoveryKit.ps1 -Renew -Destination Z:\DeployableServer-recovery   # a NAS share
.\scripts\New-LabRecoveryKit.ps1 -Renew                                       # keys\recovery on the PC
```

Run it yourself, in your own PowerShell window (it reads a passphrase from the
keyboard and refuses to run with redirected output), while OpenBao is unsealed.
Before it asks for anything, it checks that the destination's drive exists (a
USB stick that is not plugged in) and that it can write there; the folder is
created, and a relative path is fine. It asks twice for a passphrase (at least
12 characters), writes `DeployableServer-recovery-<yyyy-MM-dd>.bin` with key
share B, a new break-glass login, the root CA key (still encrypted) with its
passphrase and the root certificate, the offline SSH CA key (still encrypted)
with its passphrase, the firewall's passwords and API key, and the fingerprint
of share C (kept on the PC in `keys\openbao\unseal-c.sha256`), decrypts the
file again to verify it and shows its SHA-256 (note it next to share C). It
also notes which offline SSH CA the file holds (its fingerprint in
`keys\ssh\offline-ca.in-recovery-kit`), so that `Initialize-Lab.ps1` and
`Deploy-LabVault.ps1` can tell when the file is out of date. Share C is not
shown again: your copy stays valid. A file in
`keys\recovery` does not survive a lost Windows installation; copy it somewhere
else.

**The break-glass login.** Its secret ID exists only in the recovery file:
every kit, `-Renew` included, creates a new one and, once the new file is
written and verified, destroys all older ones (`New-LabAppRoleSecret` and
`Remove-LabAppRoleSecretIds` in [scripts/LabSecrets.ps1](scripts/LabSecrets.ps1)).
So only the newest file has a working break-glass login. Older files still hold
a valid share B, so they can still unseal together with share C: keep only the
newest, as the script says, and destroy the older ones; one you still keep must
be guarded as well as the newest. Why the lab needs such a login:
[Break-glass: the recovery kit](#break-glass-the-recovery-kit).

Make a new file:

- when `Deploy-LabVault.ps1` ends with `PENDING: your recovery file has no
  break-glass login ...`: a file made before that login existed can still
  unseal, but not give the PC its access back. Do it while the PC's DPAPI keys
  still work;
- when `Initialize-Lab.ps1` or `Deploy-LabVault.ps1` ends with `PENDING: your
  recovery file has no copy of the current offline SSH CA ...`: the file was
  made before the offline SSH CA existed, or the CA is new. `-Renew` adds it;
  without it, a lost Windows profile would also make the SSH CA that every lab
  machine trusts for break-glass unusable (its passphrase is in DPAPI);
- after `-Recover` (next section): the break-glass secret has been used;
- after a restore from a snapshot (previous section);
- when the passphrase should change, or the file was lost or may have been
  copied.

To look into a file, `.\scripts\New-LabRecoveryKit.ps1 -Open <file>` asks for
its passphrase and shows what a person may need by hand: share B, the root CA
key's passphrase and the firewall's root password. It waits for Enter and then
clears the screen.

### Recover after losing the PC's DPAPI keys

What the PC keeps with DPAPI (key shares A and B, the logins `pc-admin` and
`pc-deploy`, the root CA key's passphrase, the offline SSH CA key's
passphrase, the firewall's passwords and API key) can be decrypted only by your
Windows account on this PC. After a new Windows profile, or a password reset by
an administrator (a normal password change is fine), the `.dpapi` files are
still there but useless: OpenBao can neither be unsealed nor administered from
the PC, the root CA cannot sign, and no SSH certificate can be signed either
(OpenBao signs them for `pc-deploy`, the offline SSH CA needs its passphrase),
so SSH into the lab stops once the PC's current certificate expires.
`-Recover` brings that back from the recovery file and share C. Not yet tried
in this lab: the steps follow `New-LabRecoveryKit.ps1` but have not been run
end to end. They assume that the lab's VMs and the project folder with `keys\`
still exist; after a new Windows installation, which loses the VMs' registration
in Hyper-V too, more is needed, and that is not covered here.

1. Start the VMs `firewall` and then `vault` in Hyper-V Manager, if they are not
   running. `-Recover` needs OpenBao to answer, and `Initialize-Lab.ps1` cannot
   run yet: it unseals OpenBao with the key shares from DPAPI.
2. Restore the PC's access, in your own PowerShell window:

   ```powershell
   .\scripts\New-LabRecoveryKit.ps1 -Recover E:\DeployableServer-recovery-2026-10-24.bin
   ```

   It asks for the file's passphrase and for share C, which it checks against
   the fingerprint in the file (a typing error stops it before anything is
   changed), then:
   - puts `root-ca.key` and `root-ca.crt` back into `keys\pki` if they are
     missing (an existing, different file is left alone, with a warning; for a
     different key, its passphrase is then not replaced either), and the root
     CA key's passphrase and the firewall's passwords and API key back into
     DPAPI;
   - does the same for the offline SSH CA: `keys\ssh\offline-ca` and
     `offline-ca.pub` if they are missing, its passphrase back into DPAPI (not
     when the key on the PC differs from the one in the file). A file made
     before the offline SSH CA existed holds none, and the script says so
     (`This file holds no offline SSH CA`). The offline SSH CA on the PC is
     then unusable (its passphrase was only in DPAPI), and
     `Initialize-Lab.ps1` stops in its step 2 because the passphrase is
     missing. No script covers that case yet (the way the code suggests: a new
     offline SSH CA, and a firewall rebuild so that it is trusted); this is
     why the scripts ask for `-Renew` as soon as the kit lacks the CA;
   - waits up to 60 seconds for OpenBao and, if it is sealed, unseals it with
     shares B and C;
   - logs in with the break-glass login and creates **new** logins for
     `pc-admin` and `pc-deploy`, stored with DPAPI; then all their older secret
     IDs are destroyed, so the lost files are useless even to someone who could
     decrypt them;
   - stores share C as `openbao/unseal-a` and share B as `openbao/unseal-b`,
     the PC's two shares (the old share A is gone with the old DPAPI keys), so
     that `Unlock-LabVault.ps1` and `Initialize-Lab.ps1` unseal without input
     again. Share B keeps its name, so a renewed recovery file holds share B
     again, and the file and your copy of C stay two different shares.

   A recovery file made before the break-glass login existed is refused with a
   message; with it you can still unseal (`.\scripts\Unlock-LabVault.ps1
   -Interactive`), but not administer OpenBao. A file made before the
   firewall's `ansible` password and API key were included restores only its
   root password, and says so: nothing needs the other two on a running
   firewall, and the next `.\scripts\New-LabFirewall.ps1 -Rebuild` makes new
   ones.
3. Run `.\scripts\Initialize-Lab.ps1` as after a Windows restart.
4. Make a new recovery file with `.\scripts\New-LabRecoveryKit.ps1 -Renew`
   (previous section). It also adds the offline SSH CA to a kit that had none.

Enterprise equivalent: the same idea at a larger scale. The secrets manager
unseals itself through an HSM or a cloud KMS, so losing one administrator's PC
loses no key; the break-glass credentials are kept sealed, their use raises an
alert, and they are replaced afterwards.

---

## 7. Concepts explained

One principle applies to every concept below: every piece of code that runs in
the lab is in this repository, the third-party automation included (vendored),
and everything installed from outside is pinned by version or digest. How and
why is in
[Vendoring and pinning third-party code and images](#vendoring-and-pinning-third-party-code-and-images).

### Perimeter firewall and default deny

The firewall VM is the only connection between the networks. OPNsense filters
with pf, the packet filter of FreeBSD (it comes from OpenBSD). Anything that no
rule passes is blocked: default deny. The rules are evaluated per interface,
for traffic coming **in** on that interface, in sequence order; with "quick" the
first matching rule wins. That is why the LAN rules start with the block rule
for the HOST network and only then pass everything else. The rules are stateful
("keep state"): only the first packet of a connection has to match a rule, and
replies are allowed automatically.

OPNsense is a firewall distribution, not a general-purpose server: you describe
interfaces, rules and NAT in its configuration (GUI, API or `config.xml`), and
it generates the pf ruleset from that, adding a few rules of its own (DHCP and
the rules registered by port forwards; its usual anti-lockout rule is switched
off here with `noantilockout`, so management access is an explicit rule like any
other, see [What is allowed where](#what-is-allowed-where)). This is the same
model as commercial firewalls: an interface (zone) based rule base and a NAT
policy, managed through a GUI or an API rather than by editing a ruleset file.
Files: [opnsense/config.xml.template](opnsense/config.xml.template),
[scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1).

### NAT: outbound NAT and port forwarding

*Outbound NAT* (source NAT; "masquerade" on Linux) rewrites the sender address
of lab traffic leaving through the WAN interface (`hn0`) to the firewall's own
WAN address, so the lab can reach the internet without being reachable from it.
OPNsense's "automatic" mode creates these rules for its internal networks by
itself. A *port forward* (destination NAT, DNAT) rewrites the destination of PC
traffic: `10.10.99.3:443` becomes `10.10.10.30:443` (matrix), `10.10.99.4:443`
becomes `10.10.10.40:443` (keycloak), `10.10.99.5:8200` becomes
`10.10.10.50:8200` (vault). Only the destination changes, so the VM sees the
PC's own address 10.10.99.1 as the client (OpenBao relies on that: the PC's
logins there are valid only from 10.10.99.1), and its replies go back
through the firewall, its default gateway, which reverses the translation. Both
kinds are in `<nat>` of the rendered `config.xml`; `sudo pfctl -s nat` shows them
on the firewall (port forwards appear as `rdr` rules).

The port forwards use separate virtual IPs instead of the firewall's management
address, so the GUI and the published services can all use port 443 (see
[Networks](#networks)). The forwards keep the port numbers unchanged. For HTTPS
that is a convenience; for LiveKit's media ports it is required, because LiveKit
tells the browsers which address and port to send media to (see
[Calls](#calls-matrixrtc-sfu-ice-and-the-node-ip)). NAT reflection (letting
internal clients use the published address too) is switched off
(`disablenatreflection`): with split-horizon DNS the lab VMs get the real
address of a published name and never need it.

Enterprise equivalent: published services sit in a DMZ (screened subnet) behind
the perimeter firewall; a public address or VIP on the firewall or a load
balancer forwards to them, often through a reverse proxy or web application
firewall rather than a plain port forward. Outbound traffic leaves through a
small pool of public addresses, often via a proxy.

### Bastion (jump) host

Internal machines have no address your PC can reach. You SSH to the bastion,
and the bastion opens the connection onward. `keys\ssh_config` (written by
`Initialize-Lab.ps1`, its text from `Get-LabSshConfigText` in
[scripts/LabSsh.ps1](scripts/LabSsh.ps1)) contains `ProxyJump firewall` for
every lab VM. Vagrant uses the same path through `ssh.proxy_command` in the
Vagrantfile. Here the bastion is OPNsense's own SSH server, listening only on
LAN and HOST, open only to members of the `admins` group (OPNsense allows only
the Unix group `wheel` to log in, and only full administrators are put into
it), and locked down to its one job by a drop-in that `New-LabFirewall.ps1`
installs ([opnsense/sshd_config.d/20-lab-ssh.conf](opnsense/sshd_config.d/20-lab-ssh.conf)):

- **Who**: only `ansible`, only from the PC and from ansible-control
  (`AllowUsers`), and only with a certificate from a lab SSH CA (the
  `cert-authority` lines in the authorized keys of `ansible`).
- **Where to**: forwarding only to port 22 of the lab VMs, by address (Vagrant's
  `ssh -W <ip>:22`) and by name (`ProxyJump`): `AllowTcpForwarding local` with
  a `PermitOpen` list rendered from `config/lab.json`. No remote forwarding, no
  agent forwarding, no tunnels. A login may forward at all only because the
  PC's certificate carries the extension `permit-port-forwarding`.
- **Checked twice**: the PC checks the firewall's host certificate on the
  first hop, and then, end to end through the tunnel, the host certificate of
  the VM. The bastion never sees the PC's private key.

In an enterprise, the bastion is the one place where you enforce MFA and log
every session, and it is usually a dedicated host in a management network
rather than the perimeter firewall itself.

Even the very first connection to a new firewall is verified. At the end of its
boot, OPNsense prints its SSH host key fingerprints and the fingerprint of its
GUI certificate on the serial console, and `New-LabFirewall.ps1` reads that
console during the first boot: it certifies the firewall's host key only after
comparing it with the printed fingerprint
([SSH certificates](#ssh-certificates-user-and-host-cas)). The first boot is
saved in the log, so you can repeat the comparison by hand with the key the PC
stored:

```powershell
Select-String -CaseSensitive -Pattern '^ *(SSH|HTTPS): ' G:\Vagrant\hyperv\firewall\logs\serial-console.log -Context 0,1
ssh-keygen -lf keys\ssh\hosts\firewall.pub
```

Checking a fingerprint over a second, trusted channel (here the serial console)
is out-of-band verification; the lab automates it and then hands the result to
every client as a host certificate.
Files: [scripts/LabSsh.ps1](scripts/LabSsh.ps1),
[scripts/Initialize-Lab.ps1](scripts/Initialize-Lab.ps1),
[scripts/Connect-Lab.ps1](scripts/Connect-Lab.ps1), [vagrant/Vagrantfile](vagrant/Vagrantfile),
[opnsense/sshd_config.d/20-lab-ssh.conf](opnsense/sshd_config.d/20-lab-ssh.conf).

### Network segmentation with Hyper-V switch types

- **External**: bridged to a physical NIC. Not used here.
- **Internal**: VMs plus one host adapter (LabHost). The PC can talk to VMs on it.
- **Private**: VMs only (LabNet). The PC has no adapter there, so it cannot
  bypass the firewall.
- **Default Switch**: a Windows-managed Internal switch with NAT and DHCP.
  Convenient for internet access, but its subnet changes on every reboot.

Note that segmentation controls traffic **between** networks. VMs on the same
switch talk to each other directly: MAS reaches Keycloak, and any lab VM could
reach Synapse's internal port 8448, without the firewall seeing it. Enterprises
add host firewalls or micro-segmentation for that.

### DHCP reservations with static MACs

Hyper-V gives each lab VM a fixed MAC (`h.mac` in the Vagrantfile, taken from
`config/lab.json`). `New-LabFirewall.ps1` turns every VM in that file into a
host entry of the firewall's DHCP/DNS service (dnsmasq) with its MAC address: a
DHCP reservation (MAC -> IP) and a DNS name in one. The guests stay on plain
DHCP, and the addresses are managed in one place. DHCP runs only on LAN, with a
pool (`.100`-`.199`) for anything without a reservation.

The firewall's own adapters also have static MACs. FreeBSD numbers them in the
order Hyper-V presents them (`hn0`, `hn1`, `hn2`), and OPNsense's configuration
refers to these names. So the script adds the adapters in a fixed order, the
configuration binds WAN, LAN and HOST to those names, and after the first boot
the script compares each name's MAC with the expected one.

Enterprise equivalent: reservations in a central DHCP/IPAM system (Windows DHCP,
ISC Kea, Infoblox), fed from the IPAM or CMDB by automation rather than from a
JSON file.
Files: [config/lab.json](config/lab.json), [vagrant/Vagrantfile](vagrant/Vagrantfile),
[scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1),
[opnsense/config.xml.template](opnsense/config.xml.template).

### Split-horizon DNS and conditional forwarding

dnsmasq on the firewall serves the zone `lab.internal` on LAN (for the lab) and
HOST (for the PC). Names under `lab.internal` are answered locally and never
forwarded; all other names go to the upstream DNS servers the firewall learns on
WAN. Some names have two addresses: the firewall itself (`10.10.10.1` and
`10.10.99.2`) and every published name (the VM's real IP and its published
address). The dnsmasq option `localise-queries` makes dnsmasq answer each client
with the address from the subnet the query arrived on:

| Name | PC asks (HOST side) | Lab VM asks (LAN side) |
|---|---|---|
| `firewall.lab.internal` | 10.10.99.2 | 10.10.10.1 |
| `matrix.lab.internal`, `element.lab.internal`, `lab.internal` (published) | 10.10.99.3, forwarded by the firewall | 10.10.10.30 |
| `keycloak.lab.internal` (published) | 10.10.99.4, forwarded by the firewall | 10.10.10.40 |
| `vault.lab.internal` (published) | 10.10.99.5, forwarded by the firewall (TCP 8200 and 80) | 10.10.10.50 |
| `ansible-control.lab.internal` (not published) | 10.10.10.10, not reachable from the PC (expected) | 10.10.10.10 |

This is what makes the same URL work everywhere: the issuer
`https://keycloak.lab.internal/realms/lab` reaches Keycloak through the firewall
when your browser uses it and directly over LabNet when MAS uses it, and both
see the same certificate and the same issuer string. The same holds for
OpenBao: the PC and the lab VMs all use `https://vault.lab.internal:8200`, and
OpenBao's ACME checks of `http://matrix.lab.internal/...`, made from the vault
VM, reach the matrix VM directly over LabNet. From the PC you reach
unpublished VMs only through the jump host, and the jump host resolves the name
itself.

OPNsense's GUI has no field for `localise-queries`, so the option lives in a
drop-in file,
[opnsense/dnsmasq.conf.d/10-lab.conf](opnsense/dnsmasq.conf.d/10-lab.conf), which
`New-LabFirewall.ps1` copies over SSH into `/usr/local/etc/dnsmasq.conf.d/` and
activates by restarting dnsmasq. Such drop-ins are not part of `config.xml`, so
the script installs it again on every run. The host entries themselves are
generated from `config/lab.json` (two special cases, the domain itself and a VM
published under its own name, in
[P7](#p7-published-host-entries-the-domain-itself-and-a-vms-own-name)).

Enterprise equivalent: separate internal and external views of the same zone
(BIND views, Windows DNS policies for split-brain DNS, DNS views in IPAM
products); `localise-queries` is the small-scale form of "answer by client
subnet".

On Windows, an NRPT rule (Name Resolution Policy Table) sends only queries for
the namespace `.lab.internal` to the firewall; it covers the names below
`lab.internal` and, as checked in this lab, `lab.internal` itself (which
serves the `.well-known` files). This is the client-side form of
what enterprises do with conditional forwarders in their DNS servers.
Files: [opnsense/dnsmasq.conf.d/10-lab.conf](opnsense/dnsmasq.conf.d/10-lab.conf),
[config/lab.json](config/lab.json),
[scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1),
[scripts/Install-LabHostNetwork.ps1](scripts/Install-LabHostNetwork.ps1).

### Internal PKI (certificate authority)

Public CAs certify only names in public DNS, so the lab's names under
`lab.internal` need a CA of their own: a private PKI (public key
infrastructure). It has two levels, as in enterprises:

```
DeployableServer Lab Root CA 2026                    OFFLINE: only on the PC (keys\pki), key encrypted
|  EC P-384, 10 years, pathlen:1, name constraints
|
+-- DeployableServer Lab Intermediate CA 2026-10-24  ONLINE: in OpenBao on the vault VM (pki_int),
|   |  EC P-384, 3 years, pathlen:0                  issuer lab-int-20261024, the default issuer;
|   |                                                key generated there, never exported
|   +-- keycloak.lab.internal                        CSR signing by Ansible, 1 year
|   +-- matrix, element, lab.internal                ACME by Traefik, 90 days, renewed automatically
|   +-- hello.lab.internal                           CSR signing (the nginx demo), 1 year
|
+-- DeployableServer Lab Intermediate CA 2026        the first one (lab-int-2026), replaced on
|                                                    2026-10-24: issues nothing new, its CRL stays
|
+-- vault.lab.internal                               OpenBao's own HTTPS, 397 days
+-- firewall.lab.internal                            the firewall's web GUI, 397 days
```

**The offline root** ([scripts/New-LabRootCA.ps1](scripts/New-LabRootCA.ps1))
is created once on the PC, with the OpenSSL of Git for Windows: a self-signed
certificate "DeployableServer Lab Root CA 2026" with an EC P-384 key. The key
file `keys\pki\root-ca.key` is encrypted (PKCS#8, AES-256, 600,000 PBKDF2
iterations). Its random passphrase is stored with DPAPI (see
[Secrets management with OpenBao](#secrets-management-with-openbao)) and handed
to openssl in an environment variable, never on a command line (the command
lines of running processes are visible to other programs). "Offline" means: on
no server, and used only for a handful of signatures: the intermediates, the
two certificates at the bottom of the tree, and its own revocation list.

**Why two levels**: the root is what every client imports. A CA that issues
everyday certificates has to be online, and an online CA is exposed. If the
root itself were online and compromised, every client would have to be
touched. A compromised intermediate is revoked by the root and replaced, and
the clients keep trusting the root.

**The intermediate** lives in OpenBao's PKI secrets engine, mounted at
`pki_int`. `Deploy-LabVault.ps1` has OpenBao generate the key inside itself
(EC P-384, type "internal": it cannot be exported) together with a CSR; the
root signs the CSR on the PC (3 years), and the signed certificate goes back
into OpenBao as an *issuer*. The *default issuer* issues the everyday
certificates, and none of them can outlive it (`leaf_not_after_behavior:
truncate`). An intermediate is not forever: 400 days before it expires,
`Deploy-LabVault.ps1` makes a new one and makes it the default (a rotation, see
[Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation)).
Names in OpenBao must be unique, so the first intermediate's names carry the
year and each rotation's the date (its key and issuer name also the time); the
diagram above shows the current state.

**Constraints that limit the damage of a stolen key.** They are marked
critical: a client that does not understand such an extension must reject the
certificate instead of ignoring it.

- `pathlen:1` on the root, `pathlen:0` on the intermediates: at most one CA
  level below the root, and an intermediate cannot create further CAs.
- Name constraints on the root and the intermediates: only DNS names under
  `lab.internal`, and no IP addresses at all (every IPv4 and IPv6 range is
  excluded). Windows, browsers and OpenSSL reject any certificate below this
  root for another name. Hence every name in a lab certificate must be a full
  name under `lab.internal`
  ([P18](#p18-the-browser-or-openssl-rejects-the-certificate-or-windows-stops-trusting-it);
  more in [What the CA name constraint protects](#what-the-ca-name-constraint-protects)).
- **PKI roles** in OpenBao narrow it further. A role says what may be issued.
  OpenBao's defaults are permissive (`localhost`, IP addresses, wildcards,
  client certificates), so every lab role states its rules explicitly: exact
  names only (no subdomains, no wildcards, no `localhost`, no IP addresses),
  server certificates only, a fixed lifetime, and always the default issuer.

| PKI role | Names | Used through | Lifetime |
|---|---|---|---|
| `keycloak` | `keycloak.lab.internal` | CSR signing by `keycloak.yml` (EC P-256 keys only) | 1 year |
| `acme-matrix` | `matrix.lab.internal`, `element.lab.internal`, `lab.internal` | ACME only (Traefik) | 90 days |
| `web` | `hello.lab.internal` | CSR signing by `hello-nginx.yml` (EC P-256 keys only) | 1 year |

**Two ways to get a certificate from the intermediate**:

- **CSR signing** (Keycloak and the nginx demo,
  [tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml)):
  the server makes its own private key and a certificate signing request (CSR:
  the names and the public key, signed with the private key to prove that the
  requester holds it). Only the CSR travels: from ansible-control, which holds
  the run token, to OpenBao (`pki_int/sign/<role>`), and the token's policy
  allows exactly that one role (`ansible-keycloak`: `keycloak`, `ansible-web`:
  `web`). The certificate comes back and is installed followed by the
  intermediate. The private key never leaves the server. Renewal happens during
  a deployment run, when less than 30 days are left or when the certificate was
  not issued by the current intermediate (its *authority key identifier* is
  compared with the intermediate's *subject key identifier*, see
  [Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation)).
  Each renewal makes a new key next to the old one (`tls.key.new`), and key and
  certificate replace the old pair only together, so the service never sees a
  key that does not match its certificate.
- **ACME** (the three Matrix names): Traefik on the matrix VM is an ACME client.
  It makes its own key, orders a certificate from OpenBao's ACME directory,
  proves that it controls each name (HTTP-01: OpenBao fetches a token from
  `http://<name>/.well-known/acme-challenge/...`) and renews by itself, with no
  token and no Ansible run: proving control of the name *is* the authorisation.
  ACME is switched on for the role `acme-matrix` only; OpenBao's role-less
  default directory is closed (`forbid`), and none of the deployment policies
  allows signing with that role directly. No external account binding (EAB: a
  key the CA hands to registered clients beforehand) is required in the
  isolated lab. Step by step in
  [Reverse proxy and TLS termination](#reverse-proxy-and-tls-termination).

Why both: Traefik has an ACME client built in, Keycloak has none. ACME is the
pattern to aim for (no orchestrator in the loop, short-lived certificates,
renewal that nobody has to remember); CSR signing is how software without ACME
support gets its certificates, and it shows every step on its own.

**Why the root signs OpenBao and the firewall directly.** Both must work before
or without the intermediate:

- **OpenBao's own HTTPS** (`vault.lab.internal:8200`) must serve TLS while
  OpenBao is sealed or not yet initialised, and a certificate from OpenBao
  itself could, once expired, only be renewed through the server it protects.
  `Deploy-LabVault.ps1` has the vault VM make a key (kept across renewals) and
  a CSR, signs the CSR with the root on the PC (397 days, renewed when less than
  30 days are left) and installs the certificate. Then it reloads OpenBao
  (`systemctl reload openbao`, a SIGHUP), which reads the new files at once; a
  reload does not seal OpenBao, a restart would. OpenBao also watches the files
  itself (`tls_auto_reload`).
- **The firewall** is built before any other VM, the vault VM gets its address
  and DNS from it, and its GUI is the way in when something else is broken. A
  new firewall gets its GUI certificate in its first configuration: the key is
  made on the PC in a temporary folder and travels only inside the seed ISO,
  which is deleted on every way out of the build, also when the first boot
  fails ([Automating an appliance's first boot](#automating-an-appliances-first-boot-over-the-serial-console)).
  A running firewall's certificate is renewed **in place** by
  `New-LabFirewall.ps1` (which `Initialize-Lab.ps1` runs as its step 4) when
  less than 30 days are left or it does not chain to the root. The script first
  waits until the web GUI answers on port 443 (it starts after SSH), so that only
  a certificate that is actually served and found wanting is a reason for a new
  key. The firewall makes the new key and a CSR, only the CSR comes to the PC,
  the root signs it, and [opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php),
  run as root on the firewall, writes key and certificate into `config.xml`
  through OPNsense's own configuration library (`config.inc`, `write_config()`,
  which also keeps the previous version under System > Configuration >
  History), the way the GUI's System > Trust pages would. Then the web GUI
  restarts (`rc.restart_webgui`). No rebuild is needed.

Enterprise equivalent: the root signs only intermediates, and systems that must
exist before the online CA (the CA's own servers, network devices) get their
certificates from a separate intermediate or a dedicated bootstrap process. The
lab saves itself that third CA, at the price of using the root key a few times
a year.

**The chain a server sends**: its own certificate followed by the intermediate,
never the root. The client already has the root in its trust store and builds
the chain leaf -> intermediate -> root itself. A server that sent only its own
certificate would fail with clients that cannot fetch a missing intermediate
(OpenSSL, curl on Linux); Windows can, through the AIA URL below.

**Revocation, and plain HTTP on port 80.** Every certificate names two URLs of
its issuer: *AIA* (authority information access: where to download the
issuer's certificate) and *CDP* (CRL distribution point: where the issuer
publishes its certificate revocation list, the CRL). For the root these are
static files, `http://vault.lab.internal/pki/root-ca.crt` and `.../root-ca.crl`;
for an intermediate, OpenBao's own paths for that one issuer
(`http://vault.lab.internal/v1/pki_int/issuer/<id>/der` and `.../crl/der`), so a
certificate keeps pointing at the CA that issued it, also after a rotation.
nginx on the vault VM serves exactly these on port 80, from an allow-list
([nginx-pki.conf.j2](ansible/templates/openbao/nginx-pki.conf.j2)): the static
files itself, the OpenBao paths by passing them on to OpenBao over HTTPS on the
VM. Everything else answers 404, so OpenBao's API is never reachable without
TLS. Plain HTTP is on purpose (RFC 5280): checking a TLS certificate must not
itself need TLS, and a CRL is signed by its CA, so it needs no protection in
transit. Windows checks the CRL of every CA in a chain, so the lab's sites pass
Windows' online revocation checks, and `curl.exe` (Schannel, which fails when
the revocation status is unknown) works without `--ssl-no-revoke`. The lists
must stay current:

| CRL | Valid | Renewed |
|---|---|---|
| Root | 400 days | by `New-LabRootCA.ps1` when less than 60 days are left; it runs at the start of every `.\scripts\Deploy-LabVault.ps1`, which also copies the new list to the vault VM, and `Initialize-Lab.ps1` runs `Deploy-LabVault.ps1` by itself when the list is due. To renew now: `.\scripts\New-LabRootCA.ps1 -RenewCrl`, then `.\scripts\Deploy-LabVault.ps1` |
| Intermediates | 7 days | by OpenBao itself, 2 days before it expires, for every issuer it holds (the replaced one too). OpenBao builds and serves them only while it is unsealed; Windows caches a CRL it has fetched until the CRL's own expiry |

OpenBao also removes expired certificates from its store once a day
(auto-tidy). The lab publishes CRLs only, no OCSP (an online responder that
answers for one certificate at a time): one service fewer. Revoking a
certificate before it expires is an operation in OpenBao (web UI or API); it
has not been needed in this lab yet.

**Trust distribution.** `.\scripts\Install-LabRootCA.ps1` imports
`keys\pki\root-ca.crt` into the root store of your Windows user (Edge and Chrome
use it; for Firefox see the script). The playbooks put the same file into the
system trust store of every Ubuntu VM
(`/usr/local/share/ca-certificates/lab-root-ca-2026.crt`,
`update-ca-certificates`). Containers are a separate world: an image brings its
own CA list. Keycloak gets the root in its `conf/truststores` folder; MAS and
the LiveKit JWT service get the VM's CA bundle mounted read-only
([P30](#p30-mas-or-the-livekit-jwt-service-does-not-trust-the-lab-root-ca)), and
`matrix-prepare.yml` restarts both when the bundle changes (a bind mount of a
single file keeps showing the file it was made with); Traefik gets the root
file mounted and named in its ACME settings, so that it trusts OpenBao's ACME
server. Only public files leave the PC: `Invoke-LabPlaybook.ps1` copies the
root certificate and its CRL to `~/lab-pki` on ansible-control, and the root
key stays in `keys\pki`. Enterprises distribute their root certificates with
Group Policy or MDM and bake them into their base container images.

**Certificate pinning for OpenBao on the PC.** The PC's scripts send key
shares, logins and tokens to OpenBao, so they check its certificate more
strictly than Windows would: for OpenBao's host name (`vault.lab.internal`), a
certificate is accepted only if its chain ends exactly at `keys\pki\root-ca.crt`
(compared by thumbprint) and the host name matches, whatever else Windows
trusts. A root that is in the Windows store for another reason (the retired
first lab CA, or the root of security software that inspects TLS traffic) is not
enough. This also works before you have imported the root into Windows. The
check is a .NET callback ([scripts/LabSecrets.ps1](scripts/LabSecrets.ps1),
type `LabTlsPin2`), and .NET applies such a callback to every HTTPS request of
the PowerShell process, so it is scoped by host name: other HTTPS addresses
called from the same PowerShell session keep Windows' normal validation.
(A type added with `Add-Type` cannot be replaced within a session, hence the
version number in its name.) On ansible-control the same idea is simpler: curl
and Ansible's `uri` tasks are given `~/lab-pki/root-ca.crt` as the only CA for
OpenBao (`--cacert`, `ca_path`). Enterprise equivalent: pinning a private CA
(not a single server certificate, which would break at every renewal) for the
connections to the secrets manager, as Vault Agent and the Vault CLI do with
`VAULT_CACERT`.

**The retired first CA.** Before this PKI, a single-level CA, "DeployableServer
Lab CA" (`pathlen:0`, its key a plain file on ansible-control and on the PC),
issued every lab certificate. It is retired: every certificate was issued again
from the new PKI (the renewal checks treat a certificate from another CA as
due), the playbooks removed the old CA from all trust stores and deleted
`~/lab-ca`, and only its certificate is left, `keys\ca\lab-root-ca.crt`.
`.\scripts\Install-LabRootCA.ps1` imports only the 2026 root and says so when
Windows still trusts the retired one; taking that trust back is a step you run
yourself: `.\scripts\Install-LabRootCA.ps1 -RemoveRetired`. That is the usual
order for replacing a CA hierarchy: trust the new root everywhere, issue again,
remove the old root last.

Enterprise equivalent: the offline root on an air-gapped machine or in an HSM,
used in a documented key ceremony with several people present; one or more
online issuing CAs (Microsoft AD CS, Vault or OpenBao PKI, smallstep step-ca,
EJBCA) with their keys in HSMs; ACME or certificate agents (cert-manager,
certmonger, Vault Agent) renewing short-lived certificates automatically; CRLs
and OCSP.
Files: [scripts/New-LabRootCA.ps1](scripts/New-LabRootCA.ps1),
[scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) (intermediate, roles,
ACME), [tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml),
[vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
(section "TLS"), [scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1),
[opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php),
[nginx-pki.conf.j2](ansible/templates/openbao/nginx-pki.conf.j2),
[scripts/Install-LabRootCA.ps1](scripts/Install-LabRootCA.ps1),
[scripts/LabSecrets.ps1](scripts/LabSecrets.ps1) (pinning).

### Certificate lifecycle: renewal, maintenance and rotation

Every certificate is valid for a fixed time, and so is every revocation list.
Short lifetimes limit what a stolen key is worth, but only if renewal is
automatic: an expired certificate is one of the most common causes of outages.
In the lab every item has an owner that renews it; the table in
[Renew certificates](#renew-certificates) lists each one with its lifetime, its
renewal rule and the command that forces a renewal. The owners are of two
kinds. Services that run all the time renew by themselves: Traefik its Matrix
certificates through ACME (90 days, renewed 30 days before they expire), OpenBao
the intermediates' revocation lists (7 days). The PC's scripts renew only when
they run: `Deploy-LabKeycloak.ps1` Keycloak's certificate, `Deploy-LabVault.ps1`
OpenBao's own certificate, the root's revocation list and the intermediate CA,
`New-LabFirewall.ps1` the firewall's GUI certificate.

**Maintenance after every Windows restart.** For the second kind,
`Initialize-Lab.ps1`, which you run after every Windows restart anyway
([After a Windows restart](#after-a-windows-restart)), ends with step 7/7
"Maintenance" (once OpenBao is deployed): `Get-LabMaintenanceDue`
([scripts/LabSecrets.ps1](scripts/LabSecrets.ps1)) looks at what is due from
public information only (the certificates the servers present, the root CRL on
the PC and on the vault VM, the CA certificate OpenBao serves without a token),
and the step runs `Deploy-LabVault.ps1` and/or `Deploy-LabKeycloak.ps1` for it.
The firewall's certificate is checked earlier in the same run, by
`New-LabFirewall.ps1` in step 4. Nothing is scheduled beyond that: a PC that
runs for weeks without a restart needs a manual run; the margins of 30 days and
more leave time for that.

**Which CA issued this certificate? Key identifiers, not names.** Every
certificate carries a *subject key identifier* (SKI, derived from its own public
key), and every certificate a CA issues carries that CA's SKI as its *authority
key identifier* (AKI). Names are not unique: a rebuilt vault VM makes a new
intermediate with the same name as the one before, and two CAs can simply be
called alike. Comparing the AKI of a server's certificate with the SKI of the
current intermediate (OpenBao serves its certificate at `pki_int/ca/pem`,
without a token) answers exactly one question: was this certificate issued by
the CA that issues today? The lab asks it in three places:
[tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml)
(a mismatch counts as due, as an expiry would),
[matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml) (Traefik starts over,
below) and [scripts/Deploy-LabMatrix.ps1](scripts/Deploy-LabMatrix.ps1) (it
waits until Traefik serves certificates of the current issuer).

**Rotating the intermediate.** An intermediate must outlive the certificates it
issues: with `leaf_not_after_behavior: truncate`, a certificate issued less than
a year before the intermediate expires would be cut short. So
`Deploy-LabVault.ps1` makes a new intermediate when the default issuer has less
than 400 days left (with 3 years of validity, after about 23 months), or at once
with `.\scripts\Deploy-LabVault.ps1 -RotateIntermediate` (after a suspected key
compromise, or to try it). The old and the new CA overlap:

- The new issuer becomes the default issuer of `pki_int` at once; every new
  certificate comes from it.
- The old issuer stays in OpenBao. Its certificates remain valid until they
  expire, each of them names its own issuer's CRL, and OpenBao keeps
  publishing that CRL.
- The services move over at their next deployment, each recognising an old
  certificate by its AKI. Keycloak and the nginx demo simply get a new
  certificate. Traefik needs a push: it would keep its certificates until its
  regular renewal, and after a rebuild of the vault VM the new OpenBao would not
  even know Traefik's ACME account. So `matrix-prepare.yml` deletes Traefik's
  ACME store and restarts it when Traefik serves a certificate from an older lab
  intermediate (its own self-signed default certificate, served while ACME is
  not finished yet, is no reason to start over).
- The clients notice nothing: they trust the root, which signed both
  intermediates.

The steps, the names the new intermediate gets and the commands are in
[Rotate the intermediate CA](#rotate-the-intermediate-ca).

Enterprise equivalent: certificate lifecycle management, that is an inventory of
every certificate, monitoring and alerts before expiry, and renewal by agents or
ACME (cert-manager, Vault Agent, products such as Venafi or Keyfactor); CA
rotations planned with overlapping validity, the new CA issuing while the old
one keeps publishing its CRL until its last certificate has expired.
Files: [scripts/LabSecrets.ps1](scripts/LabSecrets.ps1) (`Get-LabMaintenanceDue`),
[scripts/Initialize-Lab.ps1](scripts/Initialize-Lab.ps1) (step 7/7),
[scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) (steps 2 and 6),
[tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml),
[matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml),
[scripts/Deploy-LabMatrix.ps1](scripts/Deploy-LabMatrix.ps1).

### SSH certificates: user and host CAs

SSH has a trust model of its own, separate from the X.509 PKI above. With plain
keys, trust is managed key by key: every server lists the public keys that may
log in (`authorized_keys`), and every client lists the host keys it believes
(`known_hosts`), usually learned on the first connection ("trust on first use":
whatever answers first is believed). Such a key never expires, and whoever holds
a copy can use it until someone finds and removes it everywhere. Earlier
versions of this lab worked exactly like that: one key without a passphrase
(`keys\ansible_ed25519`) for the PC, ansible-control and every machine, host
keys accepted on first contact (`StrictHostKeyChecking accept-new`) and not
checked at all by Ansible (`host_key_checking = False`). Now SSH runs on
certificates.

**What an SSH certificate is.** A public key signed by an SSH certificate
authority (CA), together with

- a validity period (here 8 hours for the PC, 2 hours per Ansible run, 1 year
  for hosts),
- **principals**, for whom it is valid: role names such as `lab-all` or
  `host-matrix` in a user certificate, the host's full DNS name in a host
  certificate,
- a key ID and a serial number, which every server writes into its log at each
  login,
- critical options and extensions: `source-address` (usable only from these
  addresses), `permit-port-forwarding` (may use the jump host), `permit-pty`
  (gets a terminal); everything else, agent and X11 forwarding for example,
  stays off.

It is OpenSSH's own, simple format, not X.509: no chains, no intermediates, no
URLs for revocation lists; a CA is just a key pair. A **user certificate** lets
its holder log in, a **host certificate** proves a server's identity, and
OpenSSH never accepts the one as the other. Servers trust the CA instead of
single keys (`TrustedUserCAKeys`, or a `cert-authority` line in
`authorized_keys`), and clients trust the CA for host keys (an
`@cert-authority` line in `known_hosts`). A rebuilt VM with new host keys
simply gets a new certificate and is trusted at once: no "REMOTE HOST
IDENTIFICATION HAS CHANGED", and no blind "yes".

**Two CAs.** As with the X.509 PKI, an offline key on the PC and an online
issuer in OpenBao, but not as a chain: every machine trusts both side by side.

| | Offline SSH CA | OpenBao's SSH CA |
|---|---|---|
| Key | ed25519, `keys\ssh\offline-ca` on the PC, encrypted with a random 48-character passphrase stored with DPAPI ([scripts/New-LabSshCa.ps1](scripts/New-LabSshCa.ps1)); a copy of both in the recovery file | ed25519, generated inside OpenBao (secrets engine `ssh`, [scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) step 6), never exported |
| Signs | the bootstrap (OpenBao not deployed yet, or its SSH CA not yet trusted everywhere); while OpenBao's own TLS certificate has expired (renewing it needs SSH to the vault VM, so that must not depend on OpenBao); and break-glass, only when you ask for it | everything else: the PC's certificate, each Ansible run's, the host certificates |
| Recorded | in `keys\ssh\issued.log` on the PC, and in each machine's sshd log at login (key ID `offline-...`) | in OpenBao's audit log, in `keys\ssh\issued.log` and in the sshd logs |
| Trusted | by every machine, permanently: a firewall rebuild is always a way back in | by every machine, once `Deploy-LabVault.ps1` has pushed it there and proved it |

**Who signs is decided every time** (`Get-LabSshSigner` in
[scripts/LabSsh.ps1](scripts/LabSsh.ps1)). OpenBao signs once
`keys\ssh\openbao-ca.trusted` holds the fingerprint of the CA OpenBao serves.
From then on, an OpenBao that is stopped, cannot be unsealed, serves another SSH
CA, or answers with a TLS certificate that does not chain to the lab root makes
the scripts **stop**, with the reason and the ways out, instead of falling back
to the offline CA: whoever can block or impersonate OpenBao must not be able to
push the lab into signing outside its audit log. Break-glass is a decision:
`-BreakGlass` on `Update-LabSshCertificate.ps1`, `Connect-Lab.ps1`,
`Initialize-Lab.ps1` and `New-LabFirewall.ps1`, or
`$env:LAB_SSH_BREAKGLASS = '1'` in a window. Such a certificate's key ID starts
with `offline-breakglass-`, so it stands out in every log. Both CAs sign from
the same table (`$LabSshRoles` in `LabSsh.ps1`; `Deploy-LabVault.ps1` makes
OpenBao's roles `pc`, `ansible-control` and `lab-hosts` from it), every
certificate gets a random serial number, and the PC checks each new certificate
against what it asked for (type, key, CA, principals, lifetime, options) before
it uses it, whichever CA signed it.

**The handover to OpenBao** is step 8 of `Deploy-LabVault.ps1`
(`Enable-LabOpenBaoSshCa`): OpenBao's CA public key is cached as
`keys\ssh\openbao-ca.pub`, the trust files are rendered with both CAs and pushed
to every machine, and then a throwaway key gets a 10-minute certificate from
OpenBao and logs in to every machine, through the jump host, with a temporary
`ssh_config` that offers only that key. Only when every login works is
`openbao-ca.trusted` written. A failed rollout locks nobody out: the offline CA
simply keeps signing.

**The certificates of the lab:**

| Certificate | Its key | Principals | Valid | Options | Renewed |
|---|---|---|---|---|---|
| The PC's | `keys\ssh\pc_ed25519`, made once on the PC, no passphrase | `lab-all` | 8 hours | `source-address`: the PC (10.10.99.1) and the firewall's LAN address (every login to a VM arrives from the jump host); `permit-port-forwarding`, `permit-pty` | by `Get-LabSshConfig`, the entry point of every script that uses ssh, scp or vagrant, when fewer than 4 hours are left (longer than any script runs); for `vagrant` commands you type, by the Vagrantfile; by hand: `.\scripts\Update-LabSshCertificate.ps1` |
| An Ansible run's | ansible-control's own key, made on the VM by [provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh); it never leaves the VM | only what the playbook needs (`$sshPrincipals` in `Invoke-LabPlaybook.ps1`, see [Run a playbook](#run-a-playbook-re-run-a-deployment)) | 2 hours, like the run's OpenBao token | `source-address`: ansible-control; `permit-pty` | new for every run: installed next to the key (`~/.ssh/id_ed25519-cert.pub`) and deleted when the run ends. The sockets of Ansible's kept-open connections (ControlPersist) are removed before and after, so a connection of an earlier run with a broader certificate cannot be reused |
| A host's | the machine's own ed25519 host key | exactly one: its full DNS name | 1 year | none | by `Initialize-Lab.ps1` (VMs) and `New-LabFirewall.ps1` (firewall), 30 days before it expires and at once for a new host key; one from the offline CA is replaced by one from OpenBao once OpenBao signs |

**Principals are roles, not user names.** Every machine accepts, for the
account `ansible`, the principals `lab-all` and `host-<its own name>`: the
Ubuntu VMs through `AuthorizedPrincipalsFile` (`/etc/ssh/lab_principals/ansible`,
written by [provision/harden-ssh.sh](provision/harden-ssh.sh)), the firewall
through `principals="lab-all,host-firewall"` in its `cert-authority` lines.
There is no principals file for `root` or `vagrant`, so no certificate logs in
as them. A certificate for `host-keycloak` opens keycloak and nothing else: the
same least privilege per run as the run token's policy, so during a Matrix
deployment, MDAD's third-party code holds a certificate that opens neither vault
nor the firewall. The PC refuses to sign for an empty list (OpenSSH accepts a
host certificate without principals for every host name), for wildcards and for
names that are not in `config/lab.json`.

**What the servers check.**

- **The Ubuntu VMs** (drop-in `/etc/ssh/sshd_config.d/10-lab-hardening.conf`,
  from `harden-ssh.sh`): `TrustedUserCAKeys` with both CAs, the principals
  file, their own `HostCertificate`, `AllowUsers` (`ansible` from the
  firewall's LAN address and from ansible-control, `vagrant` from the firewall's
  LAN address only), no passwords, no root login, no forwarding of any kind.
  `ansible` has no `authorized_keys` at all
  ([provision/bootstrap-ansible-user.sh](provision/bootstrap-ansible-user.sh)
  removes it), so no plain key logs in as `ansible`.
- **The firewall**: the authorized keys of `ansible` are one line per CA,
  `cert-authority,principals="lab-all,host-firewall",from="<PC>,<ansible-control>" ssh-ed25519 AAAA...`.
  A new firewall gets them in its `config.xml`; a running one through
  [opnsense/lab-ssh-trust.php](opnsense/lab-ssh-trust.php), which writes them
  with OPNsense's own configuration code, as the GUI would. The sshd drop-in
  that restricts the jump host is described in
  [Bastion (jump) host](#bastion-jump-host).

A copied user certificate is therefore limited three times: by its lifetime, by
its `source-address`, and by the server's `from=` and `AllowUsers`.

**What the clients check**: `keys\ssh_config` on the PC, and
`/etc/ssh/ssh_config.d/20-lab.conf` on ansible-control for every
`*.lab.internal` name, which applies to the lab's playbooks and to MDAD alike.
`HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com` asks a server only for its
certified key, `StrictHostKeyChecking yes` refuses anything else, and
`known_hosts` holds nothing but `@cert-authority` lines for the exact names of
the lab's machines (no wildcard: a name that is not in `config/lab.json` is
never accepted). On ansible-control nothing learned "on first use" counts or is
stored (`UserKnownHostsFile /dev/null`). Ansible checks host keys again
(`host_key_checking = True` in [ansible/ansible.cfg](ansible/ansible.cfg)).

**First contact: how the PC learns a host key before it certifies it.** A host
certificate is only as good as the check of the key it certifies, so the PC
never takes a host key from the network unverified:

- **The firewall** prints its host key fingerprints on its serial console when
  it boots. `New-LabFirewall.ps1` reads that console (a Hyper-V named pipe on the
  PC, which nothing on the network can write to) and compares the fingerprint
  with the key the firewall then presents (`ssh-keyscan`). An impostor on the
  LabHost network cannot fake that.
- **The Ubuntu VMs**: `harden-ssh.sh` publishes the VM's host key through
  Hyper-V KVP ("key-value pair exchange", part of Hyper-V's integration
  services: items exchanged over VMBus, the VM's private channel to its host,
  which only root inside that VM can write). The PC reads it from Hyper-V
  (`Get-LabKvpHostKey`, which needs an elevated shell). No other VM can write
  there.

The PC keeps the verified keys in `keys\ssh\hosts\`, refuses a key that another
machine already has (two VMs made from the same image), and installs each
certificate over a connection pinned to exactly that stored key, so this also
repairs a machine whose certificate is missing or expired; `sshd -t` checks the
configuration before sshd reloads. Enterprise equivalent: clouds print host key
fingerprints to the instance's console output (AWS `get-console-output`), or an
agent that proves the instance's identity gets its host certificate at boot.

**Revocation.** User certificates are not revoked: they expire within hours.
Host keys that must never be accepted again go into a key revocation list
(KRL, made with `ssh-keygen -k`), `keys\ssh\revoked_host_keys`: the old key of a
rebuilt firewall, of a VM that publishes a different key, and of every machine
`Remove-Lab.ps1` deletes. ssh on the PC and on ansible-control refuses such a
key even with a valid certificate, so a copy from a checkpoint or an old disk
cannot pass for the machine. ansible-control, when it is running, usually gets
the new list right away from the script that revoked the key, and in any case
at its next provisioning.

**Audit.** Every login names its certificate in the target's sshd log: key ID,
serial number and signing CA. OpenBao's audit log normally stores every request
value only as an HMAC; for the `ssh` mount the principals, the certificate
type, the lifetime and the serial number are logged in plain text, so a login
can be traced to its signing request. `keys\ssh\issued.log` on the PC lists
every certificate either CA signed (time, signer, role, key ID, serial,
principals, expiry, key fingerprint), and nothing secret. To look:

```powershell
.\scripts\Update-LabSshCertificate.ps1                   # the PC's certificate: signer, valid until, key ID, serial
ssh-keygen -L -f keys\ssh\pc_ed25519-cert.pub            # all of it: principals, critical options, extensions
.\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u ssh -n 20 --no-pager | grep Accepted'   # logins with key ID and serial
```

**What remains, honestly:**

- **Code that runs as you on the PC** can do what the scripts do: decrypt
  DPAPI, sign with the offline CA, log in to OpenBao as `pc-deploy` and get a
  certificate for every machine. That is the power the old lab key gave, but
  now every login names its certificate, and every certificate expires.
- **The offline CA's passphrase is on `ssh-keygen`'s command line** while it
  signs (`-P`: OpenSSH 8.1 reads passphrases only from the console, never from
  stdin, so there is no other unattended way). It is a deliberate exception to
  the lab's rule "no secrets on command lines". The process is started through
  .NET, so PowerShell's own logging never sees the value, but programs running
  as you or as an administrator can read it while `ssh-keygen` runs, and
  Windows writes it into the Security event log if "Include command line in
  process creation events" is switched on (`New-LabSshCa.ps1` warns about that
  setting). Without the encrypted key file it is useless.
- **Vagrant's own last hop** (user `vagrant`, Vagrant's per-VM key) does not
  check the VM's host key. Nothing depends on it: the PC never takes a host key
  from there, and that hop carries no secret of the lab.
- **Per-run principals rest on one shared account.** Every run on
  ansible-control uses the same user `ansible` with the same key and
  passwordless sudo. Code that runs during one run and plants something on
  ansible-control could pick up the certificate of a later run (`ping.yml`
  gets `lab-all`). The scoping protects against mistakes and short-lived
  misuse, not against a persistent compromise of ansible-control; that would
  need one account per automation, for example MDAD in an account of its own
  without sudo ([roadmap](#11-roadmap)).
- **Only the PC and ansible-control check the revocation list.** They are the
  only SSH clients in the lab that matter, but a revoked key is refused only
  there.
- **Offline signatures are recorded only on the PC**, in
  `keys\ssh\issued.log` (and in the sshd logs of the machines they are used
  on), not in OpenBao's audit log.
- **The recovery file now also opens SSH**: with its passphrase, the offline
  SSH CA in it can sign a certificate for every machine (usable from the PC's
  addresses). Guard it like the break-glass login it already held.

**How the running lab moved over** (2026-10-24, commit `130f75c`): that commit
kept the old key accepted while `keys\ansible_ed25519` existed, so its first run
could not lock itself out. `Initialize-Lab.ps1` installed the CAs and host
certificates, `Deploy-LabVault.ps1` handed signing to OpenBao, and the one-time
`Complete-LabSshMigration.ps1` proved that certificates alone log in
everywhere, then removed the key from every machine and moved its files aside.
The next commit removed that transition code; a lab still on the old key would
check out `130f75c` for the move.

Enterprise equivalent: the same split exists everywhere, an offline or
HSM-held root of trust plus an online issuer (HashiCorp Vault's or OpenBao's
SSH secrets engine, Smallstep, Teleport, AWS EC2 Instance Connect). People get
a certificate for their own identity after an SSO login with MFA, with
principals from their IdP groups; automation gets one per job; hosts get theirs
at boot from an agent that proves the instance's identity; logins and
issuance go to a SIEM.
Files: [scripts/LabSsh.ps1](scripts/LabSsh.ps1) (read its header first),
[scripts/New-LabSshCa.ps1](scripts/New-LabSshCa.ps1),
[scripts/Update-LabSshCertificate.ps1](scripts/Update-LabSshCertificate.ps1),
[scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) (steps 6 and 8),
[scripts/Invoke-LabPlaybook.ps1](scripts/Invoke-LabPlaybook.ps1) (`$sshPrincipals`),
[scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1) (`Update-FirewallSsh`),
[provision/harden-ssh.sh](provision/harden-ssh.sh),
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh),
[opnsense/lab-ssh-trust.php](opnsense/lab-ssh-trust.php),
[opnsense/lab-sshd-files.sh](opnsense/lab-sshd-files.sh),
[opnsense/sshd_config.d/20-lab-ssh.conf](opnsense/sshd_config.d/20-lab-ssh.conf),
[tests/Test-LabSshCa.ps1](tests/Test-LabSshCa.ps1),
[tests/Test-LabSshCertificates.ps1](tests/Test-LabSshCertificates.ps1).

### Secrets management with OpenBao

A **secrets manager** is a server that keeps secrets encrypted, hands each one
only to identities whose policy allows it, records every access, and can
generate secrets itself. The lab runs **OpenBao** 2.7.1 on the VM `vault`
(10.10.10.50, 2 vCPUs, 2 GB), published to the PC as `vault.lab.internal`
(10.10.99.5): TCP 8200 for the API, the web UI
(<https://vault.lab.internal:8200/ui/>) and the ACME directory, TCP 80 for CA
certificates and revocation lists only. OpenBao is the open source fork of
HashiCorp Vault (Linux Foundation, MPL 2.0), started after Vault moved to the
Business Source License in 2023. Its API and concepts are Vault's, down to
header names such as `X-Vault-Token`, so what you learn here applies to Vault
too. OpenBao also holds the lab's intermediate CA
([Internal PKI](#internal-pki-certificate-authority)).
[playbooks/openbao.yml](ansible/playbooks/openbao.yml) installs it, and
[scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) initialises and
configures it over its API from the PC.

Before OpenBao, the generated secrets were plain YAML files on ansible-control,
with backups on the PC. Now no secret that opens anything on its own is stored
in plain text anywhere: the PC's and ansible-control's SSH keys have no
passphrase, but without a certificate that lasts a few hours they open nothing
([SSH certificates](#ssh-certificates-user-and-host-cas)). A service secret exists in OpenBao (and in
its encrypted snapshots), in memory during a deployment, and in the
configuration of the running service that uses it. Which secret is kept where,
and what creates it, is listed in
[Where secrets and certificates come from](#where-secrets-and-certificates-come-from).
What protects each place: OpenBao's encryption, policies and audit log for the
services' secrets (KV mount `lab`); DPAPI, that is your Windows account, for the
PC's own secrets (`keys\<area>\<name>.dpapi`); you, for key share C; the
passphrase, for the recovery file and the break-glass login in it; AES-256 with
a passphrase in DPAPI, for the root CA key and the offline SSH CA key; OpenBao
itself, which never exports them, for the intermediate CAs' keys and its SSH
CA's key; and file permissions plus the certificates' short lifetimes and
source addresses for the two SSH keys without a passphrase.

Why the firewall's secrets are not in OpenBao: the firewall exists before
OpenBao, and the vault VM depends on it (its address, DNS, the only way in from
the PC). What is needed to build or repair something must not live in, or
behind, that something. The same rule makes the root, not the intermediate,
sign the certificates of OpenBao and the firewall.

**Secret zero: DPAPI on the PC.** Every secret system needs a first key that is
not stored in it: to read OpenBao you need a credential, and that credential has
to be kept somewhere. Here that somewhere is your Windows account. The PC's own
secrets are encrypted with DPAPI, the Windows Data Protection
API, for your user: Windows derives the key from your logon, so only programs
running as you on this PC can decrypt them; copies of the files, backups and
other accounts see only ciphertext. Each blob is also bound to its name (DPAPI's
optional "entropy" input), so a file copied under another name does not
decrypt. The one rename the lab makes itself is mapped back: when
`Remove-Lab.ps1` moves `keys\openbao` to `keys\openbao-retired-<date-time>`
(below), `Unprotect-LabSecret` still uses the original name for the entropy, so
the files there can be read under their new names. DPAPI does not protect
against programs that run as you. And it cannot help when your Windows profile
is lost or an administrator resets your password (a normal password change is
fine): then the files cannot be decrypted any more, which is what the recovery
kit is for. Enterprise equivalent: an HSM or a cloud key management service
(KMS) holds the first key, the secrets manager unseals itself with it
(auto-unseal), and machines prove who they are through their platform (cloud
IAM, Kubernetes service accounts) instead of a stored password.

**Seal, unseal and Shamir's key shares.** OpenBao encrypts everything it stores
(integrated "raft" storage in `/opt/openbao/data`): the data keys are encrypted
by a root key, and the root key by the unseal key. After every start OpenBao is
**sealed**: it does not know the unseal key and answers nearly every request
with HTTP 503. When OpenBao was initialised, the unseal key was split with
Shamir's secret sharing into 3 key shares, any 2 of which rebuild it; a single
share reveals nothing about it. Shares A and B are stored with DPAPI, share C
goes on paper. So someone with a copy of the VM's disk, or of a snapshot, has
only ciphertext.

- `.\scripts\Unlock-LabVault.ps1` sends shares A and B over HTTPS, without any
  input. `Initialize-Lab.ps1`, `Invoke-LabPlaybook.ps1` and
  `Deploy-LabVault.ps1` unseal the same way when OpenBao is sealed.
  `.\scripts\Unlock-LabVault.ps1 -Interactive` asks for two shares instead
  (recovery).
- A reload (`systemctl reload openbao`: a new TLS certificate, a rotated audit
  log) does not seal OpenBao; a restart does.
- While OpenBao is unsealed, its key is in the VM's memory. The vault VM
  therefore has Hyper-V checkpoints switched off (a checkpoint of a running VM
  writes its RAM to disk) and no console autologin (`checkpoints` and
  `consoleAutologin` in `config/lab.json`).
- Initialisation also returned a **root token**, an all-powerful login without
  expiry. `Deploy-LabVault.ps1` used it only for the first configuration and
  revoked it once the administrator login (`pc-admin`, below) worked.
- The key shares belong to that one installation and its snapshots.
  `Deploy-LabVault.ps1` refuses to initialise a new OpenBao while shares of an
  earlier one are in `keys\openbao`, and `Remove-Lab.ps1`, when it deletes the
  vault VM, moves that folder aside, together with the snapshots (see
  **Backups** below).

**KV version 2: versions and check-and-set.** The secrets are in a key/value
secrets engine, version 2, mounted at `lab/`. A secret is a path with fields,
for example `keycloak/users/alice` with the field `password`. KV v2 keeps the
last 10 versions of every secret and splits its API in two: the values at
`lab/data/<path>`, versions and names at `lab/metadata/<path>` (a list of names
needs `?list=true`). The mount requires **check-and-set** (`cas_required`):
every write must name the version it expects to replace, and `cas=0` means
"only if the secret does not exist yet". So two writers can never silently
overwrite each other.

**Generated by OpenBao, written once.** The playbooks read their secrets with
[tasks/openbao-secrets.yml](ansible/playbooks/tasks/openbao-secrets.yml). A
missing one is generated by OpenBao from a password policy (`lab-alnum-24`,
`-48` or `-64`: that many letters and digits, at least one of each kind) and
stored with `cas=0`; Ansible never invents a value. A secret is created only for
a **new** installation: if the service already has data (Keycloak's database
volume or `/matrix/postgres` exists), a missing secret stops the run, because a
new database password would not open the existing database. A secret that
exists but lacks the field the playbook expects (written by hand under another
field name, for example) stops the run too, with its path and the field name.
On a lab built before OpenBao, the old values were moved in unchanged, once, by
`Import-LabSecrets.ps1`; a new lab has none.

| Path in `lab/` | Field | What it is | Created by |
|---|---|---|---|
| `keycloak/db` | `password` | Keycloak's database user | `keycloak.yml` |
| `keycloak/admin` | `password` | Keycloak's bootstrap administrator `admin` | `keycloak.yml` |
| `keycloak/clients/lab-ansible` | `secret` | the client Ansible uses for Keycloak's admin API | `keycloak.yml` |
| `keycloak/clients/matrix-authentication-service` | `secret` | the OIDC client secret Keycloak and MAS share | `keycloak.yml` (the Matrix side only reads it) |
| `keycloak/users/alice`, `keycloak/users/bob` | `password` | the lab users' logins | `keycloak.yml` |
| `matrix/generic-secret-key` | `value` | MDAD's master secret (further keys are derived from it) | `matrix-prepare.yml` |
| `matrix/postgres` | `password` | the Matrix PostgreSQL superuser | `matrix-prepare.yml` |
| `matrix/legacy-users/...` | `password` | Synapse passwords from before MAS, unused, kept (only on a lab migrated from before OpenBao) | `Import-LabSecrets.ps1` |

**Policies: least privilege per playbook.** A policy lists paths and what may be
done there (`create`, `read`, `update`, `delete`, `list`, ...); whatever no
policy allows is denied. Each consumer has its own:

| Policy | Held by | Allows |
|---|---|---|
| `openbao-admin` | AppRoles `pc-admin` (the PC) and `recovery` (break-glass) | everything: administration, reading secrets by hand |
| `pc-deploy` | AppRole `pc-deploy` (the PC) | creating run tokens through the token role `ansible-run`; taking raft snapshots; signing SSH certificates with the SSH roles `pc`, `ansible-control` and `lab-hosts` (only signing: the SSH CA and its roles are `pc-admin`'s) |
| `ansible-keycloak` | run token of `keycloak.yml` | create and read `keycloak/...`; generate with `lab-alnum-24` and `-48`; sign with the PKI role `keycloak` |
| `ansible-matrix` | run token of `matrix-prepare.yml` and of MDAD | create and read `matrix/...`; read (not create) the MAS client secret; generate with `lab-alnum-64` |
| `ansible-web` | run token of `hello-nginx.yml` | sign with the PKI role `web`, nothing else |

The playbook policies grant `create` and `read` but never `update`: a playbook
can add a missing secret but cannot change an existing one, not even by
mistake. Changing a secret (rotation) is an administrator's decision. And
`keycloak.yml` cannot read Matrix's secrets, nor can a Matrix run change
Keycloak's.

**AppRole: logins for machines.** AppRole is OpenBao's login method for
programs: a *role ID* (like a user name) and a *secret ID* (like a password)
give a token with the role's policies and lifetime. The PC has three roles; two
for daily use, because a deployment needs far less than an administrator, and
one for emergencies:

| AppRole | Policy | Tokens valid | Secret ID kept |
|---|---|---|---|
| `pc-admin` | `openbao-admin` | 30 minutes, at most 1 hour | DPAPI on the PC |
| `pc-deploy` | `pc-deploy` | 5 minutes, at most 10 | DPAPI on the PC |
| `recovery` | `openbao-admin` | 30 minutes, at most 1 hour | only in the recovery file ([break-glass](#break-glass-the-recovery-kit)) |

For all three, both the secret ID and the tokens are bound to the PC's address,
10.10.99.1/32: stolen credentials do not work from any other machine. This works
through the firewall because a port forward changes only the destination address
([NAT](#nat-outbound-nat-and-port-forwarding)), so OpenBao sees the PC's real
address. The scripts revoke their token as soon as they are done. A new login
is issued in two steps ([scripts/LabSecrets.ps1](scripts/LabSecrets.ps1)):
`New-LabAppRoleSecret` creates a new secret ID, the caller stores it (in DPAPI,
or in the recovery file, which it then decrypts again to verify it), and only
then `Remove-LabAppRoleSecretIds` destroys every other secret ID of the role.
So only the newest login works, a lost or leaked one is useless from then on,
and a failure in between (a full or write-protected USB stick, for example)
leaves the old login working. `Deploy-LabVault.ps1` does this when a DPAPI
login is missing (on the first run, or in a new Windows profile);
`New-LabRecoveryKit.ps1` for every new recovery file and when it restores the
PC's logins. Replacing a credential instead of adding a second valid one is
what rotation should mean.

**Token roles and run tokens.** A playbook on ansible-control needs a token, but
ansible-control keeps no credentials. For each run the PC logs in as
`pc-deploy` and creates one token through the **token role** `ansible-run`,
which fixes what such a token can be: only policies from its list
(`ansible-keycloak`, `ansible-matrix`, `ansible-web`), usable only from
ansible-control's address 10.10.10.10/32, valid at most 2 hours, not renewable,
and an *orphan*. Normally a token dies with the token that created it, and the
`pc-deploy` token is revoked seconds later; an orphan has no parent.
`Invoke-LabPlaybook.ps1` asks for exactly the policy the playbook needs
(`keycloak.yml` -> `ansible-keycloak`, `matrix-prepare.yml` ->
`ansible-matrix`, `hello-nginx.yml` -> `ansible-web`), and
`Deploy-LabMatrix.ps1` asks for `ansible-matrix` for its MDAD runs.

**Response wrapping: handing the token over.** The PC never receives the new
token itself. It asks with the header `X-Vault-Wrap-TTL: 120s`, and OpenBao
returns a **wrapping token** instead: single-use, valid for 2 minutes, and good
for exactly one thing, being exchanged for the real token. The PC sends it to
ansible-control over SSH on stdin, never on a command line (the other users of a
machine can read command lines, for example with `ps`), and
[ansible/bin/openbao-run](ansible/bin/openbao-run) there:

1. reads it from stdin and keeps only token characters (Windows PowerShell may
   add a carriage return or a byte order mark when it pipes text);
2. unwraps it with curl, the header again on stdin (`-H @-`), checking
   OpenBao's certificate against `~/lab-pki/root-ca.crt`;
3. exports `VAULT_ADDR`, `VAULT_CACERT` and `VAULT_TOKEN`, the standard names
   that the `bao`/`vault` CLI and Ansible's `community.hashi_vault` use, points
   Ansible's temporary folder into RAM (below) and runs the playbook;
4. when the command ends, also after a failure or Ctrl+C (`trap ... EXIT`),
   revokes the token and removes that temporary folder.

The real token never travels between machines. If someone intercepted the
wrapping token and used it first, the unwrap would fail: the theft cannot go
unnoticed. One detail: this ssh call has no `-t`. With a pseudo-terminal the
remote side echoes its input, and the token would appear in the output;
Ansible's colours are switched on with `ANSIBLE_FORCE_COLOR` instead, when the
console can show them
([P50](#p50-ansibles-colours-appear-as-text-such-as-036m)).

**Nothing on ansible-control's disk: pipelining and a temporary folder in
RAM.** A secret that lives only in memory can still be written to disk by the
tool that handles it. By default Ansible does that twice: it copies every
module, together with its arguments, as a file into `~/.ansible/tmp` on the
target before running it, and it renders templates into a local temporary
folder before copying them to the server. The plays that talk to OpenBao run on
ansible-control itself, and their module arguments hold the run token (the
`X-Vault-Token` header of the `uri` tasks) and secret values (the users'
passwords for `keycloak_user`, for example); the rendered templates include the
env files with Keycloak's passwords. Deleted files can survive in free disk
blocks, in backups or after a crash. Two settings avoid both:

- `pipelining = True` (section `[connection]` of
  [ansible/ansible.cfg](ansible/ansible.cfg)): Ansible hands the module and its
  arguments to the target's Python on stdin instead of writing a file first. It
  is faster too, and needs sudo without `requiretty` (Ubuntu's default). MDAD's
  own `ansible.cfg` switches it on as well.
- `openbao-run` sets `ANSIBLE_LOCAL_TEMP` to a private folder (`mktemp -d`) on
  tmpfs, a file system in RAM: the session's `XDG_RUNTIME_DIR`, or `/dev/shm`.
  It removes the folder on exit, together with revoking the token.

So module arguments (tokens, secrets) and rendered templates never land on
ansible-control's disk; the only files with secrets are those a service needs,
on that service's VM. One visible side effect is a harmless warning once per
VM ([P48](#p48-ansible-warns-that-it-created-rootansibletmp)). Enterprise equivalent: automation runners with no persistent disk
(ephemeral containers or VMs per job), and secrets injected into memory or
`tmpfs` only.

**Ansible speaks HTTP: `ansible.builtin.uri` instead of hvac.** Ansible's usual
integration, the `community.hashi_vault` collection, needs the Python library
hvac on the control node. The lab calls OpenBao's HTTP API with plain
`ansible.builtin.uri` tasks instead: nothing extra to install and pin, and every
request is visible in the task file (a URL, the token header, JSON).
`tasks/openbao-secrets.yml` returns the values as the fact `lab_secrets`, in
memory for this run only; `keycloak.yml` maps them to the `vault_*` names its
templates use ([vars/keycloak-secrets.yml](ansible/playbooks/vars/keycloak-secrets.yml)).
Every task that carries the token or a value has `no_log: true`. Because that
also hides the task's error message, each one is followed by an `assert` that
reports only paths, field names and HTTP status codes (403: the token's policy
does not allow it; 503: OpenBao is sealed). The reads are marked
`check_mode: false`: a read changes nothing, and without the values nothing else
could be checked, so a dry run with `--check` works and writes nothing to
OpenBao. MDAD expects its secrets as inventory variables, so the lab runs it
through [ansible/matrix/lab-setup.yml](ansible/matrix/lab-setup.yml), which
reads them first, hands them to the Matrix host with `set_fact` and then imports
MDAD's `setup.yml`.

**Audit log.** OpenBao writes every request and response to
`/var/log/openbao/audit.log` on the vault VM, with secret values replaced by
HMAC hashes: the log shows who read or wrote which path and when, but not the
values. It fails closed: if OpenBao cannot write the log, it refuses requests.
logrotate rotates the file daily (14 days are kept) and reloads OpenBao, which
then reopens it. Your own reads with `Show-LabSecret.ps1`
([Read a password or secret](#read-a-password-or-secret)) are in it too.

**Where the values still end up.** OpenBao removes the copies on ansible-control
and on the PC, but a service still needs its secrets in its own form:
Keycloak's in `keycloak.env` and `postgres.env` (mode 0600, root) on the keycloak
VM, MDAD's in the configuration it writes under `/matrix` on the matrix VM, and
both in their databases. Whoever is root on a service VM can read that
service's secrets; OpenBao does not change that. Enterprises go further:

- **Vault Agent** (OpenBao has the same, `bao agent`) runs on the server, logs
  in by itself, renders the configuration files from templates and restarts the
  service when a secret changes. No deployment run carries secrets at all.
- On Kubernetes, the **Secrets Store CSI driver** (or the External Secrets
  Operator) puts the secrets into a pod as files when it starts.
- **Dynamic secrets**: the database secrets engine (in Vault and OpenBao) creates
  a database user with a short lease for each consumer and deletes it when the
  lease ends. There is no long-lived database password left to steal or to
  rotate.

**Backups: snapshots, taken automatically.** A raft snapshot holds all of
OpenBao's data in one file, encrypted like the storage itself: useless without
key shares, and it needs the shares that were valid when it was taken. So the
scripts take one by themselves whenever OpenBao may hold something that exists
nowhere else: after every run of `Deploy-LabKeycloak.ps1` and
`Deploy-LabMatrix.ps1`, also a failed one (a first deployment creates the
service's secrets inside OpenBao, and from then on the service's database
depends on them), and in `Remove-Lab.ps1` before it deletes the vault VM. And
`Remove-Lab.ps1` does not delete `keys\openbao` with the VM, it moves it (key
shares, logins and snapshots) to `keys\openbao-retired-<yyyyMMdd-HHmmss>`, so
every snapshot stays next to the key shares it needs. How to take and keep
snapshots: [Back up OpenBao](#back-up-openbao); how to restore one onto a
rebuilt vault VM: [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).

Enterprise equivalent: a cluster of 3 to 5 OpenBao or Vault nodes on raft,
spread over failure domains and unsealed automatically through an HSM or a
cloud KMS, with disaster-recovery replication or at least scheduled snapshots
kept off-site and restores that are tested; the audit log shipped to a SIEM;
machines authenticated by their platform (Kubernetes, cloud IAM, a CI system's
OIDC token) wherever possible; personal administrator logins through the
company's IdP with MFA instead of a shared admin AppRole. Other products for the
same job: CyberArk Conjur, Azure Key Vault, AWS Secrets Manager, Google Secret
Manager.
Files: [scripts/LabSecrets.ps1](scripts/LabSecrets.ps1) (DPAPI, the API calls,
pinning, unseal, AppRole secrets, run tokens),
[scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) (initialisation,
engines, policies, AppRoles, token role),
[playbooks/openbao.yml](ansible/playbooks/openbao.yml),
[openbao.hcl.j2](ansible/templates/openbao/openbao.hcl.j2),
[ansible/bin/openbao-run](ansible/bin/openbao-run),
[ansible/ansible.cfg](ansible/ansible.cfg),
[tasks/openbao-secrets.yml](ansible/playbooks/tasks/openbao-secrets.yml),
[ansible/matrix/lab-setup.yml](ansible/matrix/lab-setup.yml),
[scripts/Show-LabSecret.ps1](scripts/Show-LabSecret.ps1),
[scripts/Backup-LabVault.ps1](scripts/Backup-LabVault.ps1),
[scripts/Remove-Lab.ps1](scripts/Remove-Lab.ps1).

### Break-glass: the recovery kit

**Break-glass** access is the emergency way in when the normal way is broken:
prepared in advance, kept apart from daily use, and used rarely and on purpose
(the name comes from the fire alarm behind a pane of glass).

In this lab the normal way runs through DPAPI, that is, through your Windows
account: OpenBao's key shares A and B, the PC's OpenBao logins, the root CA
key's passphrase, the offline SSH CA key's passphrase, the firewall's passwords.
If that account's keys are lost
(Windows reinstalled, the profile damaged, the password reset by an
administrator), OpenBao could neither be unsealed nor administered again (every
secret in it lost, and with them the existing Keycloak and Matrix
installations), and the root CA could sign nothing more (every client would have
to trust a new root). The recovery kit covers that case without weakening the
daily setup. It has two parts, kept in different places:

| Part | Holds | Protected by |
|---|---|---|
| Key share C | one of OpenBao's three key shares | where you keep it: on paper or in your password manager |
| The recovery file, `DeployableServer-recovery-<date>.bin` | key share B; the break-glass login (below); the root CA key (still encrypted with its own passphrase), that passphrase and the root certificate; the offline SSH CA key (still encrypted) and its passphrase; the firewall's passwords and API key; a fingerprint (SHA-256) of share C | a passphrase you choose: AES-256 against reading, an HMAC-SHA256 against changes, both keys derived from the passphrase with PBKDF2 (600,000 iterations), which makes guessing it slow |

Any two key shares unseal OpenBao: normally A + B from DPAPI, after a loss B from
the file and C from your copy. Neither part alone unseals OpenBao, and the file
is useless without its passphrase. That is the point of keeping the pieces
apart: whoever finds only one of them, without the passphrase, has nothing.
With its passphrase, the file alone is also an administrator login for an
unsealed OpenBao, from the PC's address (the break-glass login), and SSH
access to every lab machine (the offline SSH CA in it signs a certificate for
any of them), so guard the passphrase as well as the file. The fingerprint of
share C in the file lets the recovery catch a typing error in the share you
type in, and it reveals
nothing about the share: a random 256-bit value cannot be guessed back from its
hash. After a recovery the PC keeps B and C (A is gone), and the next recovery
file holds B again, so the file and your copy of C stay two different shares.

**The break-glass login.** Unsealing is not administering: after a loss of
DPAPI the PC's AppRole logins are gone too. Vault and older OpenBao versions
offer a way back for exactly that case: whoever presents a quorum of unseal key
shares can have a new root token generated (`sys/generate-root`, called without
a token). Since 2.5.3, OpenBao switches these unauthenticated endpoints off by
default: an API that hands out root tokens without a login is attack surface.
So the lab prepares a login in advance instead. `Deploy-LabVault.ps1` creates
the AppRole `recovery`, with the policy of `pc-admin` (`openbao-admin`), the
same short token lifetime and the same binding to the PC's address
10.10.99.1/32. Its secret ID exists only in the recovery file:
`Deploy-LabVault.ps1` never makes one, and `New-LabRecoveryKit.ps1` makes a new
one for every file it writes and, once the file is written and verified,
destroys all older ones. So only the newest file can log in; an older one can
still help to unseal (it holds share B), nothing more. A used break-glass
login is replaced, like a password after an emergency: after a recovery the
script asks for a new file (`-Renew`).

SSH has a break-glass path of its own: when OpenBao cannot sign SSH
certificates, the offline SSH CA on the PC can, but only when you ask for it
(`-BreakGlass`), and every such certificate is marked as such in the logs
([SSH certificates](#ssh-certificates-user-and-host-cas)). The recovery file
keeps a copy of that CA, so the path survives a lost Windows profile too.

**Using the kit.** `New-LabRecoveryKit.ps1` makes the kit once, right after
OpenBao was initialised ([Step 5](#step-5-make-the-recovery-kit-once-you-run-it-yourself));
`-Renew` writes a new recovery file later and `-Open` shows what a person may
need by hand ([Renew the recovery kit](#renew-the-recovery-kit)); `-Recover`
restores the PC's access after a loss of DPAPI, in one command with the file
and your copy of share C: it puts the PC's secrets back into DPAPI, unseals
OpenBao with B and C if it is sealed, logs in with the break-glass login and issues new logins
for the PC's scripts
([Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys)).
The script shows secrets, so it runs only in a console window you type into
yourself.

The kit restores what DPAPI protected, plus the files of the root CA and of the
offline SSH CA. It is not a backup of the whole `keys\` folder (this PC's SSH
key, for example, is not in it: a lost one is simply made again by
`New-LabSshCa.ps1`, and the CAs certify the new one; OpenBao's snapshots are in
`keys\openbao\snapshots`). A full recovery on a new Windows installation has
not been rehearsed in this lab yet.

The lab is pragmatic here: one person holds all three shares, a password manager
or a sheet of paper is a fine place for share C, and a NAS share or a USB stick
for the file. The only rules are that the two are not stored together and that
neither depends on this Windows installation alone.

Enterprise equivalent: the key shares (with auto-unseal, the recovery keys) go to
several named key custodians, each share encrypted to its holder's PGP key at
initialisation, so that no single person holds a quorum; the root CA key sits in
an HSM or on an air-gapped machine in a safe and is used only in a ceremony with
witnesses; break-glass accounts such as the firewall's root or an emergency
administrator login for the secrets manager are kept in a vault with check-out,
an alert on every use and a new credential afterwards; and the recovery
procedure is rehearsed.
Files: [scripts/New-LabRecoveryKit.ps1](scripts/New-LabRecoveryKit.ps1),
[scripts/Deploy-LabVault.ps1](scripts/Deploy-LabVault.ps1) (the AppRole
`recovery`), [scripts/Unlock-LabVault.ps1](scripts/Unlock-LabVault.ps1),
[scripts/LabSecrets.ps1](scripts/LabSecrets.ps1) (`New-LabAppRoleSecret`,
`Remove-LabAppRoleSecretIds`).

### Matrix: homeserver, clients and .well-known delegation

Matrix is an open protocol for chat and calls. Its parts in this lab:

- **The homeserver** (Synapse) stores the rooms and their events (messages,
  membership, state) in PostgreSQL and offers the client-server API
  (`/_matrix/client/...`). Every user and room belongs to a **server name**,
  here `lab.internal`: user IDs look like `@alice:lab.internal`. The server
  name is part of every ID in the database, so it can never change.
- **Clients** such as Element Web are just apps that talk to that API. Element
  Web is a static web application (HTML and JavaScript) served by its own small
  container; everything it does happens in your browser.
- **Delegation with `.well-known`**: the server name (`lab.internal`) does not
  have to be the host that runs the server (`matrix.lab.internal`). Clients
  fetch `https://lab.internal/.well-known/matrix/client`, which here says:
  homeserver `https://matrix.lab.internal`, login service (MAS)
  `https://matrix.lab.internal/auth/`, and the call service (a LiveKit
  "focus"). Element Web in this lab already knows the homeserver from its own
  `config.json` and asks Synapse for the login service, so for Element the file
  matters mainly for the call focus; a client that knows only the server name
  (Element X, for example) needs all of it. Servers, and the LiveKit JWT
  service, fetch `https://lab.internal/.well-known/matrix/server`
  (`matrix.lab.internal:8448`). Normally a company's main web site serves these
  two small files; here MDAD serves them itself (a static file server behind
  Traefik), which is why `lab.internal` is a published name and needs a
  certificate (Traefik gets it through ACME, like those of the other two names).
- **Federation**, the server-to-server API between homeservers, is switched off:
  the lab is isolated. Synapse still keeps its federation port 8448 open inside
  the lab, with only the `openid` resource, because the LiveKit JWT service
  uses it to check who a caller is. The firewall does not forward 8448.
- **MAS** takes over everything around login from Synapse (see
  [Identity: IdP, OIDC and single sign-on](#identity-idp-oidc-and-single-sign-on)).
- **End-to-end encryption (E2EE) and devices**: Element encrypts direct
  messages and private rooms by default. The keys live on each signed-in
  device (every Element session is a "device"), not on the server: Synapse
  stores the message content only as ciphertext (who talks to whom and when
  stays visible to it), so even alice as administrator cannot read other users'
  messages. A new device of the same user gets the keys from another, verified
  device, or from the server-side key backup, which the recovery key unlocks.
  Lose every device and the recovery key, and old messages stay unreadable
  ("Unable to decrypt"). That is why Element asks you to set up a recovery key
  and to verify new devices. Enterprise equivalent: E2EE versus archiving and
  eDiscovery is a policy decision; organisations enforce key backup and device
  verification, or switch E2EE off where compliance requires it.

Enterprise equivalent: Element Server Suite, Element's own packaging of the same
components (Synapse, MAS, Element Web, MatrixRTC) for Kubernetes; organisations
that run Matrix connect it to their IdP the same way.
Files: [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml),
[ansible/matrix/inventory/hosts](ansible/matrix/inventory/hosts).

### Reverse proxy and TLS termination

A **reverse proxy** accepts the connections of the clients and forwards each
request to the right backend. On the matrix VM, Traefik owns ports 80 and 443:
it terminates TLS (decrypts) with certificates it obtains itself through ACME
(below), then routes by host name and path: `element.lab.internal` to Element
Web, `matrix.lab.internal/_matrix` to Synapse (the login endpoints to MAS),
`matrix.lab.internal/auth` to MAS, `/livekit-jwt-service` and `/livekit-server`
to the call services, `lab.internal/.well-known` to the static file server.
Port 80 redirects to HTTPS, except for the ACME challenges
(`/.well-known/acme-challenge/`), which Traefik answers there itself. With
**SNI** (Server Name Indication) the browser names the host already in the TLS
handshake, so one address and one port can serve many names, each with its own
certificate. MDAD configures the routes as labels on the containers, which
Traefik reads through a socket proxy that exposes only the parts of the Docker
API it needs.

**Certificates through ACME, from the lab's own CA.** ACME (Automatic
Certificate Management Environment, RFC 8555) is the protocol Let's Encrypt
made the standard: a client creates an account and a key, orders a certificate
for some names, proves that it controls each name, receives the certificate,
and renews it by itself before it expires. Let's Encrypt cannot certify names
under `lab.internal`, so Traefik is pointed at OpenBao's ACME server instead,
the intermediate CA's role `acme-matrix`
([Internal PKI](#internal-pki-certificate-authority)):

```
https://vault.lab.internal:8200/v1/pki_int/roles/acme-matrix/acme/directory
```

For each of `matrix.lab.internal`, `element.lab.internal` and `lab.internal`:

1. Traefik orders a certificate. OpenBao answers with an HTTP-01 challenge:
   serve this token at `http://<name>/.well-known/acme-challenge/<token>`.
2. OpenBao fetches that URL from the vault VM. The lab DNS answers with the
   matrix VM's own address, 10.10.10.30 (split horizon), so the request goes
   over LabNet straight to Traefik's port 80, without passing the firewall.
3. The answer matches, and OpenBao issues a certificate from the default issuer,
   the current intermediate: 90 days, and only for names the role allows.
4. Traefik keeps its ACME account, keys and certificates in
   `/matrix/traefik/ssl/acme.json` (the private keys are made there and never
   leave the VM) and renews 30 days before expiry, without any deployment run.

The settings are in
[vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml),
section "TLS": the ACME server (`traefik_config_certificatesResolvers_acme_caServer`);
the lab root, which Traefik's container image does not know, mounted into the
container and named in `caCertificates`, so that Traefik trusts OpenBao's HTTPS;
`keyType: EC256` (P-256 keys like the other lab certificates, instead of
Traefik's default RSA 4096); and `certificatesDuration: 2160`, the real lifetime
in hours, from which Traefik computes when to renew. `matrix-prepare.yml`
checks beforehand that the ACME directory is reachable and trusted from the
matrix VM. Until the first certificate arrives, Traefik answers with its own
self-signed "TRAEFIK DEFAULT CERT"; `Deploy-LabMatrix.ps1` therefore waits up to
3 minutes per name and checks that the certificate it is served comes from the
*current* intermediate (its authority key identifier must equal the
intermediate's subject key identifier; a name alone would not tell an older
intermediate apart). Renewal needs OpenBao unsealed, but with 30 days of margin
a sealed OpenBao for a day or two does no harm.

**After a new intermediate**, Traefik would keep its certificates until their
regular renewal, and after a rebuild of the vault VM it would not even get any:
the new OpenBao does not know Traefik's ACME account. So `matrix-prepare.yml`
compares the certificate Traefik serves with OpenBao's current issuer; if it
comes from an older lab intermediate, it deletes `acme.json` and restarts
`matrix-traefik`, which registers again and orders new certificates from the
current one
([Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation)).

HTTP/3 is switched off: it would need UDP 443, which the firewall does not
forward.

**Keycloak terminates TLS itself** (port 8443 in the container, 443 on the VM),
with no proxy in front. Keycloak has no ACME client, so its certificate comes
from OpenBao by CSR signing whenever `Deploy-LabKeycloak.ps1` runs (see
[Internal PKI](#internal-pki-certificate-authority)). Its public URL is fixed
with `KC_HOSTNAME=https://keycloak.lab.internal`: Keycloak builds every link,
redirect and its issuer from it, whoever asks. Because nothing rewrites the
requests, no proxy headers need to be trusted. Its management port 9000
(health and metrics) is bound to `127.0.0.1` on the VM only.

Enterprise equivalent: a load balancer or ingress controller (often with a web
application firewall) in front of every web application, certificates from an
internal or public ACME CA renewed automatically (by the proxy's own ACME client,
or cert-manager on Kubernetes), and the IdP behind the same kind of proxy with
its admin console on a separate, internal host name.
Files: [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
(section "TLS"), [matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml)
(the reset after a new intermediate),
[scripts/Deploy-LabMatrix.ps1](scripts/Deploy-LabMatrix.ps1) (the certificate
checks).

### Identity: IdP, OIDC and single sign-on

**Identity provider (IdP)**: the one system that owns the user accounts,
checks passwords (and in a company, MFA) and states to applications who a user
is. Here Keycloak, realm `lab`. Applications never see a password; they trust
signed statements from the IdP. One account per person, one place to disable
it: that is single sign-on (SSO).

**Realm**: Keycloak's unit of separation, comparable to a tenant. Each realm
has its own users, clients, login settings and issuer URL. The realm `master`
exists only to administer Keycloak itself (the bootstrap admin `admin` and the
automation client `lab-ansible` live there); the lab's users and the client for
MAS live in the realm `lab`. Enterprise equivalent: a tenant in Entra ID or
Okta, with separate tenants or realms for staff, customers and testing.

**OAuth 2.0 and OIDC**: OAuth 2.0 is about authorization. A client gets an
**access token** to call an API on a user's behalf, plus a longer-lived
**refresh token** to get new access tokens without asking the user again.
OpenID Connect (OIDC), built on OAuth 2.0, adds authentication: an **ID token**
says who signed in, when and at which IdP. In this lab Element uses OAuth 2.0
towards MAS mainly for API access (Matrix scopes), MAS uses OIDC towards
Keycloak (it needs to know who the user is), and Ansible uses OAuth 2.0's
client credentials grant towards Keycloak's admin API (no user at all, see
[Configuration as code for Keycloak](#configuration-as-code-for-keycloak)).

**OIDC in more detail**: OIDC is the standard for the IdP's statements about a
user. An IdP publishes a **discovery document** at
`<issuer>/.well-known/openid-configuration` with its endpoints (authorization,
token, userinfo, keys). It issues an **ID token** (a signed JWT about the user)
and access tokens; the **userinfo** endpoint returns the user's claims (user
name, name, email). **Scopes** say what the client asks for, here
`openid profile email`.

**Authorization code flow**: the browser only carries a short-lived code; the
client (MAS) exchanges it for tokens server to server, so tokens never pass
through the browser's address bar ([The login flow](#the-login-flow), steps
4-7). The Keycloak client allows only this flow (standard flow on; implicit
flow, password grant and service account off). The implicit flow returned
tokens in the address bar (browser history, logs, `Referer` headers), and the
password grant shows the user's password to the client; OAuth 2.1 drops both.

**PKCE** (Proof Key for Code Exchange, "pixy"): before the redirect, the client
invents a random secret (code verifier) and sends only its SHA-256 hash (code
challenge, method `S256`). Only who knows the verifier can redeem the code, so a
stolen code is useless. MAS always uses PKCE (`pkce_method: always`), and the
Keycloak client requires S256.

**Confidential client**: a client that can keep a secret, because it runs on a
server. MAS authenticates to Keycloak with its client secret
(`client_secret_basic`). A browser app or mobile app cannot keep a secret; it is
a **public client** and relies on PKCE alone. Element is such a public client of
MAS: it registers itself with MAS at runtime.

**Issuer**: the IdP's identity, a URL. Clients compare it character by
character with the discovery document and with every token. Keycloak's issuer is
`https://keycloak.lab.internal/realms/lab` (no trailing slash); MAS's own issuer
is `https://matrix.lab.internal/auth/` (with one). Split-horizon DNS and a fixed
`KC_HOSTNAME` make the issuer identical for the browser and for MAS.

**Redirect URI allow-list**: the IdP sends the code only to an address
registered for the client, compared exactly. MAS's address is
`https://matrix.lab.internal/auth/upstream/callback/<ULID>`. `<ULID>` is MAS's
ID for the upstream provider, a ULID (Universally Unique Lexicographically
Sortable Identifier, 26 characters), chosen once in
[group_vars/all.yml](ansible/inventory/group_vars/all.yml). It is part of the
redirect URI, and MAS stores every account link under it, so it must never
change. Without the allow-list an attacker could start a login with their own
address and collect the code
([P27](#p27-keycloak-answers-invalid-parameter-redirect_uri)).

**Back-channel logout**: when a Keycloak session ends (sign-out in Keycloak, an
administrator ending a session), Keycloak sends a signed logout token directly
to MAS. MAS then ends its browser session for that user
(`on_backchannel_logout: logout_browser_only`); devices already signed in to
Matrix keep working until they sign out themselves. Front-channel logout, the
alternative, loads each application's logout URL in hidden frames in the
browser, which the blocking of third-party cookies often breaks. The
back-channel call needs no browser, so the Keycloak client has front-channel
logout switched off.

**SSO session and application sessions**: there are three sessions, and they
live independently:

| Session | Kept by | Ends when |
|---|---|---|
| Keycloak SSO session | a cookie of `keycloak.lab.internal` in your browser | you sign out in Keycloak, it times out, or an admin ends it |
| MAS browser session | a cookie of `matrix.lab.internal` | you sign out in MAS (its account page `https://matrix.lab.internal/auth/account/`), or Keycloak reports a logout (back-channel) |
| Matrix session ("device") | Element, with MAS's access and refresh tokens, in the browser storage of `element.lab.internal` | you sign out in Element or remove the device |

Signing out of Element ends the Matrix session (the device). It does not end
Keycloak's SSO session, and most likely not MAS's browser session either: MAS
publishes no end-session endpoint and Element is configured with no logout
redirect, so Element's sign-out can only revoke its own tokens (not yet
confirmed by a test in this lab). The next "Sign in"
in the same browser profile can therefore pass without a password. When the MAS
browser session ends through a sign-out in MAS, MAS asks Keycloak to show the
login form again (`prompt=login`) for a sign-in shortly afterwards (MAS's
`logged_out` flag, a window of about five minutes); without that, Keycloak's
still valid SSO session would sign the user straight back in. All this is why
two users need two browser profiles
([P32](#p32-signing-in-as-bob-logs-in-alice-again)).

**MAS, the OIDC layer for Matrix**: Matrix clients speak OAuth 2.0 / OIDC with
MAS (the Matrix OAuth 2.0 API, "next-generation auth"); MAS speaks OIDC with the
upstream IdP; Synapse asks MAS whether an access token is valid. MAS adds what
is Matrix-specific (devices, Matrix scopes, the user's localpart) and lets any
standard IdP be plugged in. Here MAS has no passwords of its own and exactly one
upstream provider, so it sends every login straight to Keycloak. The mapping on
the first login (**just-in-time provisioning**): Keycloak's `sub` (stable user
ID) is the link, `preferred_username` becomes the localpart (`alice` ->
`@alice:lab.internal`), name and email are copied, there is no confirmation
page (`skip_confirmation`), and user details come from the userinfo endpoint
(`fetch_userinfo`). Who is a Matrix administrator is declared in MAS's policy
(`admin_users: [alice]`). Administrator here means that MAS lets alice, and
only her, request admin access to Synapse's admin API, which admin tools need.
Element does not request it, so alice's Element looks exactly like bob's (the
roadmap item Element Admin would use it).

Enterprise equivalent: Microsoft Entra ID, Okta or Keycloak (often federated
with Active Directory) as the IdP, MFA and conditional access there, applications
connected by OIDC or SAML, accounts provisioned just in time or by SCIM, and
admin rights derived from IdP groups instead of a list in an application's
configuration.
Files: [keycloak.yml](ansible/playbooks/keycloak.yml),
[group_vars/all.yml](ansible/inventory/group_vars/all.yml) (the shared values of
both sides), [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
(section "Login").

### Calls: MatrixRTC, SFU, ICE and the node IP

Calls in Element use **MatrixRTC**: who is in a call is recorded in the Matrix
room, and the media go through a **focus**, here a LiveKit server. The focus is
announced in `.well-known/matrix/client` (`rtc_foci`). Element Web contains the
Element Call interface and uses it for every call, 1:1 calls in direct messages
included (`use_exclusively`); the older peer-to-peer calls, which would need a
TURN server, are not used.

- **SFU** (selective forwarding unit): every participant sends its audio and
  video once to the server, which forwards them to the others without mixing.
  It scales better than everyone sending to everyone (mesh) and costs much less
  CPU than mixing (MCU).
- **LiveKit JWT service**: Element asks Synapse for a Matrix *OpenID token*
  that proves the user's Matrix ID and gives it to the JWT service. Despite the
  name, this is not an OIDC ID token: it is a short-lived token from Synapse's
  own `openid/request_token` endpoint, not issued by MAS or Keycloak. The JWT
  service checks it with the homeserver (over the federation port's `openid`
  resource, found through `https://lab.internal/.well-known/matrix/server`) and
  returns a LiveKit access token and the LiveKit URL. Both run over HTTPS
  through Traefik, like LiveKit's signalling WebSocket.
- **WebRTC and ICE**: the browser and LiveKit exchange **candidates** (address
  and port pairs where each side can be reached) and test them in pairs; the
  first working pair carries the media, encrypted with DTLS-SRTP. LiveKit
  offers one UDP port for all media (7882) and a TCP port (7881) as fallback.
- **Media encryption**: DTLS-SRTP protects each hop, here browser to LiveKit,
  and an SFU can decrypt what it forwards. Element Call is designed to add
  end-to-end media encryption in encrypted rooms (keys exchanged over Matrix),
  so that LiveKit forwards frames it cannot read; this has not been checked in
  this lab yet (look for the call's encryption indicator during the test).
  Enterprise equivalent: ask of every meeting product whether its media are
  encrypted end to end or only hop by hop.
- **The node IP**: LiveKit runs behind the firewall's port forward, so it must
  announce the address the browser can reach, not its own. By default it asks a
  public **STUN** server (Session Traversal Utilities for NAT: a server that
  tells a client from which public address and port its packets arrive) for
  its public IP; in the lab that would be your home router's internet address,
  a path that leads nowhere. So
  `livekit_server_config_rtc_use_external_ip: false` and
  `livekit_server_config_rtc_node_ip: 10.10.99.3` make it announce the published
  address, and the firewall forwards UDP 7882 and TCP 7881 there unchanged
  ([P35](#p35-a-call-connects-but-no-audio-or-video-flows)).
- **TURN** (a relay for clients behind restrictive networks) is off: your PC
  reaches the SFU directly, and TURN would need more forwarded ports.

Enterprise equivalent: the SFU in a DMZ with a public address (or behind a load
balancer that passes UDP), TURN servers (often on TCP/TLS 443) for clients in
locked-down networks, and capacity planning for bandwidth and CPU.
Files: [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
(section "Calls"), [config/lab.json](config/lab.json) (the published ports).

### Containers on the lab VMs

Both applications run as Docker containers, managed in two different ways:

- **Keycloak: Docker Compose.** [compose.yml.j2](ansible/templates/keycloak/compose.yml.j2)
  describes two services (Keycloak and PostgreSQL), their private network, a
  named volume for the database, health checks, start order ("start Keycloak
  only when the database is healthy"), memory limits and the restart policy
  `unless-stopped`. `keycloak.yml` renders it to `/opt/keycloak-stack` and runs
  `docker compose up` through the module `docker_compose_v2` with `wait`, so the
  play continues only when both containers are healthy. Settings come from
  environment files (`keycloak.env`, `postgres.env`, mode 0600 because they
  contain secrets, rendered from the values in OpenBao on every deployment).
  Docker CE itself comes from Docker's own APT repository,
  with log rotation configured in `/etc/docker/daemon.json`.
- **Matrix: containers as systemd units.** MDAD writes one systemd unit per
  container: `matrix-synapse.service`, for example, creates the Synapse
  container (`docker create`) and runs it attached (`docker start --attach`),
  so its output lands in the journal. The services are started, stopped and
  logged like any Linux service (`systemctl`, `journalctl`), and the units
  declare their dependencies (Synapse requires `matrix-postgres` and
  `matrix-authentication-service`; Traefik requires the socket proxy).

Containers make an application's dependencies part of an image that is the same
everywhere; the configuration and the data stay outside (environment, mounted
files, volumes), which is why a container can be replaced at any time. That is
also why the database volumes matter: they are the data
([P25](#p25-postgresql-18-does-not-start-with-the-old-volume-path)).

Enterprise equivalent: Kubernetes, with Helm charts or operators (there is a
Keycloak operator, and Element Server Suite for Matrix), images from an internal
registry, and persistent volumes with backups.

### Configuration management with Ansible

ansible-control is the single place that changes servers. The inventory
([ansible/inventory/hosts.ini](ansible/inventory/hosts.ini)) groups hosts by role
(`firewalls`, `control`, `matrix_servers`, `keycloak_servers`, `vault_servers`
and the empty `web`) and addresses them by DNS name, not by IP (ansible-control manages itself
without SSH: `ansible_connection=local`). Groups are named by role and hosts by
machine, because a group and a host with the same name would be ambiguous
([P22](#p22-ansible-warns-that-a-group-and-a-host-have-the-same-name)). The
firewall is in the inventory too: Ansible reaches it over SSH as `ansible` and
runs its modules with the Python 3 that OPNsense ships, so `ping.yml` tests it
like the other VMs. Its configuration, however, is better changed through
OPNsense's REST API than with modules that edit files, because OPNsense
regenerates its files from `config.xml`.

Patterns worth looking for in the playbooks:

- **Idempotence**: a second run reports no changes. Handlers restart a service
  only when its configuration or certificate changed; `meta: flush_handlers`
  runs them early where the next task depends on it (a new CA bundle before the
  containers start).
- **Several plays on several hosts** in one playbook: `keycloak.yml` prepares on
  ansible-control (its secrets from OpenBao), deploys on the keycloak VM, and
  configures Keycloak's API from ansible-control again. `delegate_to` runs one
  task elsewhere: in
  [tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml)
  the key and the CSR are made on the server, but the signing request goes to
  OpenBao from ansible-control, which holds the run token.
- **Reusable task files**: `include_tasks` pulls the same steps into several
  playbooks, `tasks/openbao-secrets.yml` (secrets) and
  `tasks/openbao-certificate.yml` (certificates), each with its inputs as
  variables of the include.
- **Secrets created once, kept out of the output**: the secrets come from
  OpenBao at run time and stay in memory (the fact `lab_secrets`); a missing
  one is generated by OpenBao and stored create-only (see
  [Secrets management with OpenBao](#secrets-management-with-openbao)).
  `no_log: true` and `diff: false` keep the values out of the output, even with
  `--diff`. Because `no_log` also hides error messages, an `assert` after each
  such task reports what failed, by path, field name and HTTP status only.
- **Secrets kept off the disk**: `pipelining = True` in `ansible.cfg` hands
  each module and its arguments to the target's Python on stdin instead of
  writing them to a file first, and `bin/openbao-run` puts Ansible's local
  temporary files (rendered templates) into a folder in RAM that it removes at
  the end (see [Secrets management with OpenBao](#secrets-management-with-openbao)).
  A harmless side effect is one warning per VM
  ([P48](#p48-ansible-warns-that-it-created-rootansibletmp)).
- **Dry runs**: `--check` (with `--diff`, for example
  `.\scripts\Invoke-LabPlaybook.ps1 keycloak.yml --check --diff`) shows what a
  run would change without changing it. Tasks that only read (the OpenBao
  reads, the CA certificate) carry `check_mode: false`, so they run anyway and
  the rest is checked against real values; everything that writes (to OpenBao,
  a new certificate) is skipped. A module that cannot predict its result
  reports "changed", as `keycloak_user` does for every user
  ([P49](#p49---check-reports-the-lab-users-as-changed)).
- **Shared values defined once**: the "contract" between Keycloak and MAS
  (issuer, client ID, provider ID, MAS's public URL) is in
  [group_vars/all.yml](ansible/inventory/group_vars/all.yml); both playbooks
  read it (`matrix-prepare.yml` hands it to MDAD as `lab-shared.yml`, next to
  `vars.yml`), so the two sides cannot drift apart.
- **Checks as tasks**: `assert` and `uri` tasks with `failed_when` turn
  assumptions (DNS answers, the issuer, Keycloak's readiness) into failures with
  a clear message instead of a vague error later.
- **A third-party playbook**: MDAD is a separate Ansible project with its own
  inventory and `ansible.cfg`, kept unchanged in the repository
  (`vendor\mdad`) and copied to `~/mdad` on ansible-control for each
  deployment. The lab keeps its configuration apart (`ansible/matrix/`) and
  runs MDAD through a small entry point of its own,
  [lab-setup.yml](ansible/matrix/lab-setup.yml): it reads MDAD's secrets from
  OpenBao, hands them to the Matrix host as facts, and then imports MDAD's
  `setup.yml`, run with `ansible-playbook` and the tags of MDAD's `just`
  recipes (`--tags=install-all,ensure-matrix-users-created,start` is what
  `just install-all` would run; `just` itself is not installed). Wrapping a
  third-party playbook instead of editing it keeps its upgrades simple.

The project lives in the repository and is copied for each run, so the
repository is always the source of truth.
Files: [ansible/](ansible/), [ansible/ansible.cfg](ansible/ansible.cfg),
[scripts/Invoke-LabPlaybook.ps1](scripts/Invoke-LabPlaybook.ps1),
[ansible/bin/openbao-run](ansible/bin/openbao-run),
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh).

### Configuration as code for Keycloak

An IdP is normally clicked together in its admin console, and then nobody knows
exactly how it is set up. In this lab the realm, the client and the users are
tasks in [keycloak.yml](ansible/playbooks/keycloak.yml), using the
`community.general.keycloak_*` modules, which talk to Keycloak's admin REST API:

- They log in with the OAuth 2.0 **client credentials** grant as the client
  `lab-ansible`, a service account (no person's password involved). Keycloak
  creates it, together with the admin user `admin`, on its very first start
  from the `KC_BOOTSTRAP_ADMIN_*` settings and marks both as temporary
  (a lab shortcut, see [section 10](#10-security-notes)).
- `module_defaults` sets the connection once for all `keycloak_*` tasks.
- Each run compares the desired state with Keycloak's and changes only what
  differs. Settings changed by hand in the console that the playbook manages are
  set back on the next run; settings it does not mention stay as they are.
- Limits: the user module does not compare passwords (a password changed later
  in OpenBao reaches Keycloak only when another attribute of the user changes in
  the same run), and under `--check` it therefore reports every user as
  "changed" ([P49](#p49---check-reports-the-lab-users-as-changed)). `force: true` would delete and re-create
  a user, giving it a new internal ID (`sub`), which breaks the link MAS keeps.
  The tasks never use it.

Enterprise alternatives for the same idea: realm exports imported at start,
keycloak-config-cli, a Terraform provider, or the Keycloak operator's realm
import on Kubernetes.

### Vendoring and pinning third-party code and images

The lab runs a lot of other people's work: MDAD and its roles, Ansible and its
collections, container images, packages and the OPNsense image. The lab's
principle is that **every piece of code that runs in the lab is in this
repository**, and everything else it installs is pinned by the repository to
one exact version. Three reasons: you can see exactly what runs
(transparency), every deployment and every rebuild uses exactly what was
tested (reproducibility), and an upgrade is a visible change that can be
reviewed before it is used. There are two ways to get there.

**Vendoring: the code itself in the repository.** To vendor a dependency means
to keep a copy of it, at one pinned version and unchanged, inside your own
repository, instead of downloading it when it is needed. The lab vendors
MDAD, in [vendor/mdad](vendor/README.md):

- **What is there**: MDAD's repository
  ([spantaleev/matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy))
  at commit `a52e9876526aa6dcd41075b3a83d5eea7c31887b`, plus its 32 external
  roles in `vendor\mdad\roles\galaxy\` (Docker, Traefik, PostgreSQL and others,
  each kept in a repository of its own, all but the Docker role by MDAD's
  authors and their related projects), each at the version
  MDAD pins in its `requirements.yml`. They were installed with
  `ansible-galaxy install -r requirements.yml -p roles/galaxy/ --force`, which
  is what MDAD's `just roles` does; `ansible-galaxy` adds a small
  `meta\.galaxy_install_info` (install date and version) to each role. The
  marker file `vendor\mdad\.lab-vendored-commit` names the commit.
- **How it stays linked to the source: a git subtree.** `vendor\mdad` was
  added with `git subtree add --prefix vendor/mdad <MDAD's URL> <commit> --squash`.
  Its files are ordinary files of this repository (no second repository, no
  submodule pointer: whoever clones this repository has all of it), and the
  subtree commits record the upstream commit (`git-subtree-split: ...` in their
  messages, see `git log -- vendor/mdad`). The next version comes with
  `git subtree pull`, which merges only what changed upstream. "--squash" keeps
  one summary commit per update instead of MDAD's whole history. Alternatives:
  a **submodule** stores only a pointer to the other repository (the code is
  then not in this one), a **GitHub fork** is a second repository on GitHub
  with a "Sync fork" button (useful to contribute changes back, but again
  another place than this one).
- **The roles are tracked although MDAD ignores them**: MDAD's own
  `vendor\mdad\.gitignore` ignores `roles/galaxy/`, because upstream installs
  the roles on demand. Here they were added with `git add -f`; once tracked, a
  file stays tracked whatever `.gitignore` says. MDAD's files are unchanged.
- **What is not used**: MDAD's `inventory\` (the lab's own configuration lives
  in `ansible\matrix\`). The few symbolic links, only in MDAD's molecule test
  folders, are checked out on Windows as small text files naming their target;
  no deployment reads them.
- **Licence**: MDAD is free software under the AGPL-3.0-or-later
  (`vendor\mdad\LICENSE`; some files MIT or CC0, marked in `.license` files).
  The licence allows passing on unchanged copies as long as the copyright and
  licence notices stay intact, which they do here.
- **How it is used**: `Deploy-LabMatrix.ps1` copies `vendor\mdad` to `~/mdad`
  on ansible-control on every run, and `matrix-prepare.yml` checks the marker
  file against `mdad_version`. Nothing is downloaded from GitHub at deployment
  time. `Update-LabMdad.ps1` is the only script that downloads MDAD
  ([Upgrade MDAD](#upgrade-mdad-and-with-it-the-matrix-components)).
- **Why vendored and not cloned at deployment time** (as the lab did before):
  MDAD is automation code that runs with root rights on the matrix VM, so it
  matters most to know what it is. A clone at deployment time also depends on
  GitHub and on 32 other repositories being reachable and unchanged; most
  roles are pinned by Git tags (four by commit hash), and a tag, like an image
  tag, can be moved to other code. With the code in the repository every
  deployment uses the same files, and an upgrade is one commit of one folder
  that you can compare file by file (`git show --stat`, `git diff`).
- **The cost**: about 2,900 more files in the repository, and an upgrade is a
  deliberate step instead of a side effect. Container images and packages are
  not vendored: they are large binaries, and their registries and package
  repositories already offer a precise way to fetch one exact artefact.

**Pinning: an exact version or hash, written in the repository.** For what is
downloaded, the repository names the exact version, or better a hash of the
exact file:

- **MDAD's commit**: `mdad_version` in
  [matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml), which must equal
  `vendor\mdad\.lab-vendored-commit` (`Deploy-LabMatrix.ps1` refuses
  otherwise). MDAD has no releases or tags; a commit hash is the exact version.
  `matrix_playbook_migration_validated_version` in `vars.yml` makes you confirm
  that you read MDAD's changelog.
- **The Matrix images** by the versions MDAD's vendored roles pin in their
  defaults (Synapse, MAS, Element, Traefik, ...): they come with the commit.
- **Keycloak by digest**: `quay.io/keycloak/keycloak:26.8.1@sha256:...`. A tag
  is only a name that its publisher can point at a new image (the 26.8.1 tag
  was re-pushed on 2026-10-23); a digest is the hash of the image itself and
  cannot change ([P26](#p26-the-same-image-tag-suddenly-means-a-different-image)).
- **Exact tags** elsewhere: `postgres:18.6` for Keycloak's database. Never
  `latest` for a database.
- **Ansible by package version**: `ANSIBLE_VERSION=14.5.0` in
  [bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh), the
  community package with its collections, which brings ansible-core 2.21.5,
  installed with pipx from PyPI. The Python libraries pip resolves for it
  (Jinja2, PyYAML and others) are not pinned.
- **OpenBao by package version and signing key** (`openbao_version` in
  [openbao.yml](ansible/playbooks/openbao.yml)): OpenBao comes from its official
  APT repository, but only after the repository's signing key has been compared
  with a fingerprint pinned in the playbook (on a mismatch the repository is
  removed again and nothing is installed). The package is installed at exactly
  2.7.1 and put on `hold`, so a general `apt upgrade` leaves it alone.
- **The OPNsense image by SHA-256**: `New-LabFirewall.ps1` checks the
  downloaded image against a hash pinned in the script and OPNsense's
  signatures against a pinned fingerprint of its signing key
  ([An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)).

Not pinned yet, and listed in [section 10](#10-security-notes): Ubuntu's own
packages (git, pipx, nginx, ...) and Docker CE on the Keycloak VM come in
their current version from Ubuntu's and Docker's repositories, and the Vagrant
box in the newest version in Vagrant's box cache (the Vagrantfile names no
`box_version`).

Enterprise equivalent: nothing in production is fetched straight from the
internet. Third-party code and artefacts come from an internal mirror or
artifact repository (a Git mirror, Artifactory, Nexus; Ansible Automation Hub
or a private Galaxy server for collections and roles, execution environments
with fixed versions of Ansible and its libraries), only in versions that were
reviewed and approved; images are scanned and their signatures verified.
Upgrades are proposed as pull requests (by people, or by tools such as
Renovate and Dependabot), reviewed like the team's own code and promoted
through test environments.

### Infrastructure as code with Vagrant

The Vagrantfile describes the Ubuntu VMs, their network and their provisioning;
their names, MACs, IPs and sizes come from `config/lab.json`, which the firewall
build reads too. Every provisioning script is idempotent ("safe to run again"),
so `Initialize-Lab.ps1` simply re-applies everything on each run.
Bootstrapping (user, SSH host keys and the SSH CAs to trust, ansible-control's
own SSH key, shell) is done by Vagrant shell provisioners; the host
certificates come afterwards from `Initialize-Lab.ps1`, which can read each
VM's host key from Hyper-V. Application deployment is done by Ansible. This
split is common: a minimal bootstrap creates a machine that configuration
management can reach, and configuration management does the rest.
Files: [vagrant/Vagrantfile](vagrant/Vagrantfile), [provision/](provision/),
[scripts/Initialize-Lab.ps1](scripts/Initialize-Lab.ps1).

### An appliance configured from a versioned config.xml

The lab builds its machines in two different ways, and the difference is worth
understanding:

- **Vagrant box + provisioning** (the Ubuntu VMs): start from a generic image,
  then change the running system step by step with scripts. The scripts are the
  code; the result is whatever they leave behind, so they must be idempotent and
  are simply run again to apply changes.
- **Appliance + configuration file** (the firewall): OPNsense keeps its entire
  configuration in one file, `/conf/config.xml`. The GUI, the REST API and the
  console all read and write that file, and OPNsense generates everything else
  (pf rules, dnsmasq and sshd configuration, ...) from it. So the repository
  holds a template of that file,
  [opnsense/config.xml.template](opnsense/config.xml.template), and
  `New-LabFirewall.ps1` fills in addresses from `config/lab.json`, generates the
  virtual IPs, port forwards and DNS host entries from its `vms` and
  `published`, adds password hashes, keys and certificates, and hands the result
  to OPNsense on the first boot. Passwords and the API secret go in only as
  SHA-512-crypt hashes (`$6$<salt>$<hash>`, the format of Linux's
  `/etc/shadow`), made with `openssl passwd -6 -stdin`. The secret reaches
  openssl on stdin, never on its command line, which other programs can read and
  Windows can log (how the script keeps PowerShell from adding bytes to it:
  [P11](#p11-windows-powershell-51-quirks)). The file *is* the desired state
  (declarative), and a change means a new firewall built from the changed file
  ("cattle, not pets"). Model version attributes are left out of the template on purpose:
  OPNsense migrates older or version-less sections to its current format at
  every boot.

The consequence for day-2 changes: a GUI or API change modifies only the running
firewall's `config.xml`; it is not written back to the repository and lasts
only until the next rebuild. One day-2 change is automated on purpose:
`New-LabFirewall.ps1` renews the GUI certificate of a running firewall in place
([opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php), see
[Internal PKI](#internal-pki-certificate-authority)), so that an expiring
certificate needs no rebuild. Enterprise equivalent: a "golden configuration" in
version control, deployed by automation through the device's API, with the GUI
used read-only and drift between the two detected and fixed.

The image itself is handled like any supply-chain input: the version is pinned
in the script (26.7), the download is checked against a pinned SHA-256 hash and
against OPNsense's signatures (with a pinned fingerprint of the signing key),
and only then converted to a VHDX. (A fixed-size VHD is exactly the raw disk
data plus a 512-byte footer, so the conversion needs no extra tools.) Because an
image is always older than the latest patches, the build updates the new
firewall right away, to at least the pinned minimum 26.7.7: packages first, then
base system and kernel, then a reboot if the running kernel (`uname -r`) differs
from the installed one (`freebsd-version -k`). Later runs update only if
something is below that minimum, so they never change a working firewall by
surprise; regular patching is a separate decision (GUI: System > Firmware).
Because the image is always below the minimum, every `-Rebuild` installs the
latest 26.7.x: in this lab, rebuilding is also a way to patch.
Enterprise equivalent: golden images from an internal, verified repository, new
machines patched before they go into service, and patching in planned
maintenance windows.
Files: [opnsense/config.xml.template](opnsense/config.xml.template),
[scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1).

### Automating an appliance's first boot over the serial console

Cloud images have cloud-init, Vagrant boxes have SSH and a known user. A fresh
OPNsense image has neither: it boots into its factory default configuration.
What it does have is a configuration importer: on a disk without a
configuration it offers, for a few seconds at boot, to load `conf/config.xml`
from another device. `New-LabFirewall.ps1` uses it:

1. It packs the rendered `config.xml` as `conf/config.xml` into a small ISO
   (volume `LABSEED`), built with Windows' own IMAPI2 component, and puts it in
   the VM's DVD drive.
2. Hyper-V connects the VM's serial port COM1 to a named pipe,
   `\\.\pipe\lab-firewall-com1`. OPNsense uses the serial port as its main
   console, so the script can read everything the firewall prints and type
   answers, like the Unix tool `expect`: it waits for
   "Press any key to start the configuration importer", presses a key, reads
   the device list, chooses the CD drive (`cd0`), and waits for
   "Restoring config.xml...done". Nothing is typed blind, and known error
   messages stop the build with a pointer to the log
   (`G:\Vagrant\hyperv\firewall\logs\serial-console.log`).
3. Only now are the network adapters connected (they were created
   disconnected, see [P3](#p3-a-new-opnsense-would-run-a-dhcp-server-on-the-wrong-network)),
   and the script waits for the `login:` prompt.
4. It ejects and deletes the ISO, because it contains password hashes and the
   GUI's private key. That happens on every way out of the build (a
   `try`/`finally` around the first boot), also when the first boot fails, and
   a later run removes an ISO that was left behind (after a power cut, for
   example); the staging folder with the plain `config.xml` from which the ISO
   was built is deleted as soon as the ISO exists. From here on everything
   happens over SSH.

Enterprise equivalent: zero-touch provisioning of network devices (a device
fetches its configuration on first boot), configuration drives for VMs, and
console servers that give out-of-band access to every device's serial console.

### Keeping C: free

Vagrant and Hyper-V write to C: by default. The lab moves or places these on
the storage drive:

- the box cache via `VAGRANT_HOME` (`G:\Vagrant\home`)
- the VM disks via the junction `vagrant\.vagrant` -> `G:\Vagrant\machines\<project>\vagrant`
- Hyper-V configuration, checkpoints and smart paging files of the Ubuntu VMs
  via `Move-VMStorage` (`G:\Vagrant\hyperv\<vm>`, for example
  `G:\Vagrant\hyperv\matrix`)
- the firewall VM, which `New-LabFirewall.ps1` creates directly in
  `G:\Vagrant\hyperv\firewall` (disk, configuration, console log), and its
  image cache in `G:\Vagrant\images\opnsense\26.7`

The container images and the application data live inside the Ubuntu VMs'
disks, so they are on the storage drive too.
Files: [scripts/Initialize-Lab.ps1](scripts/Initialize-Lab.ps1),
[scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1).

---

## 8. Repository layout

```
DeployableServer/
|-- README.md                         this file
|-- .gitignore                        keeps keys/, keys-old-*/ and .vagrant/ out of version control
|-- .gitattributes                    LF line endings for every text file
|-- config/
|   `-- lab.json                      the lab's data: domain, networks, firewall addresses, lab VMs
|                                     (name, MAC, IP, size, checkpoints, console autologin) and
|                                     "published" (address, names, ports per VM); read by the
|                                     Vagrantfile and the PowerShell scripts
|-- opnsense/                         the firewall's configuration (OPNsense)
|   |-- config.xml.template           golden config: interfaces, dnsmasq, NAT, rules, users, GUI;
|   |                                 VIPs, port forwards and host entries are generated from lab.json
|   |-- lab-gui-cert.php              run as root on the firewall by New-LabFirewall.ps1: puts a
|   |                                 renewed GUI certificate into the running config.xml
|   |-- lab-ssh-trust.php             run as root on the firewall (LabSsh.ps1): the SSH CAs user
|   |                                 ansible accepts (cert-authority lines) into the running config.xml
|   |-- lab-sshd-files.sh             run as root on the firewall by New-LabFirewall.ps1: installs the
|   |                                 SSH host certificate and the sshd drop-in, only if sshd -t passes
|   |-- sshd_config.d/
|   |   `-- 20-lab-ssh.conf           sshd drop-in: host certificate, AllowUsers, forwarding only to
|   |                                 port 22 of the lab VMs (PermitOpen, rendered from lab.json)
|   `-- dnsmasq.conf.d/
|       `-- 10-lab.conf               dnsmasq drop-in: localise-queries (split horizon)
|-- vagrant/
|   |-- Vagrantfile                   the Ubuntu VMs from lab.json: box, network, MACs, size,
|   |                                 checkpoints, provisioners
|   `-- .vagrant                      junction to G:\Vagrant\machines\... (VM disks, Vagrant state)
|-- provision/                        shell provisioners run by Vagrant as root on the Ubuntu VMs (all idempotent)
|   |-- bootstrap-ansible-user.sh     user "ansible", passwordless sudo, no authorized_keys (it logs
|   |                                 in with SSH certificates only; the script deletes the file)
|   |-- harden-ssh.sh                 own SSH host keys per VM, published to the PC through Hyper-V
|   |                                 KVP; trust in the lab's SSH CAs, principals, AllowUsers;
|   |                                 certificate logins only, no forwarding, no root login
|   |-- bootstrap-ansible-control.sh  ansible-control's own SSH key, host key checking against the
|   |                                 lab's SSH CAs (ssh_known_hosts, revocation list,
|   |                                 ssh_config.d/20-lab.conf), Ansible pinned (ANSIBLE_VERSION) via
|   |                                 pipx, git (for Update-LabMdad.ps1)
|   |-- setup-zsh.sh                  zsh, fzf history search, prompt without blue
|   `-- setup-console-autologin.sh    tty1 autologin for the Hyper-V console (--remove: off, for vault)
|-- ansible/                          Ansible project (copied to ~/lab on ansible-control per run)
|   |-- ansible.cfg                   inventory, remote user, ansible-control's own SSH key (with the
|   |                                 run's certificate next to it), host key checking on, pipelining
|   |                                 (modules and their arguments go to Python on stdin, not into
|   |                                 temporary files), colours
|   |-- bin/
|   |   `-- openbao-run               on ansible-control: reads the wrapped run token from stdin,
|   |                                 unwraps it, exports VAULT_ADDR/VAULT_CACERT/VAULT_TOKEN, puts
|   |                                 Ansible's local temporary files into RAM (ANSIBLE_LOCAL_TEMP),
|   |                                 runs one command; on exit it revokes the token and removes
|   |                                 that folder
|   |-- inventory/
|   |   |-- hosts.ini                 groups firewalls, control, matrix_servers, keycloak_servers,
|   |   |                             vault_servers, web (empty)
|   |   `-- group_vars/all.yml        lab_pki_dir, lab_vault_url, lab_domain, the Keycloak/MAS
|   |                                 contract (URL, realm, issuer, client IDs, MAS URL, provider
|   |                                 ULID), keycloak_secrets_dir (only to remove the old folder)
|   |-- playbooks/
|   |   |-- ping.yml                  reachability and sudo test for all hosts
|   |   |-- openbao.yml               OpenBao on the vault VM: root CA trust, pinned package (signing
|   |   |                             key checked), openbao.hcl, audit log rotation, service, nginx
|   |   |                             on port 80 for CA certificates and CRLs
|   |   |-- keycloak.yml              Keycloak: secrets from OpenBao, certificate signed by OpenBao,
|   |   |                             Docker, Compose stack, realm "lab", client for MAS, users alice
|   |   |                             and bob
|   |   |-- matrix-prepare.yml        before MDAD: root CA trust, check that ~/mdad holds the pinned
|   |   |                             commit (mdad_version), inventory, lab-setup.yml and
|   |   |                             lab-shared.yml copied into ~/mdad, Matrix secrets in
|   |   |                             OpenBao, DNS, Keycloak and the ACME directory checked on the VM;
|   |   |                             Traefik's ACME store reset when Traefik serves a certificate of
|   |   |                             an older lab intermediate
|   |   |-- hello-nginx.yml           the first demo: nginx + certificate from OpenBao
|   |   |                             (tasks/openbao-certificate.yml, role web: only
|   |   |                             hello.lab.internal; policy ansible-web; group web, empty)
|   |   |-- tasks/                    task files the playbooks include
|   |   |   |-- openbao-secrets.yml   read secrets from OpenBao, create missing ones once (cas=0);
|   |   |   |                         result: the fact lab_secrets, in memory for one run; a secret
|   |   |   |                         without the expected field is reported by path and field
|   |   |   `-- openbao-certificate.yml
|   |   |                             a TLS certificate from the intermediate CA: key and CSR made
|   |   |                             on the server, signed by OpenBao, renewed within 30 days of
|   |   |                             expiry or when it was not issued by the current intermediate
|   |   |                             (authority key identifier)
|   |   `-- vars/
|   |       `-- keycloak-secrets.yml  the vault_* names Keycloak's templates use, mapped to lab_secrets
|   |-- templates/
|   |   |-- keycloak/
|   |   |   |-- compose.yml.j2        Keycloak + PostgreSQL as a Docker Compose project
|   |   |   |-- keycloak.env.j2       Keycloak settings: database, hostname, TLS, health, bootstrap admin
|   |   |   `-- postgres.env.j2       database initialisation (first start only)
|   |   |-- openbao/
|   |   |   |-- openbao.hcl.j2        OpenBao's configuration: raft storage, TLS listener, audit log
|   |   |   |-- nginx-pki.conf.j2     nginx on port 80: allow-list of CA certificate and CRL paths,
|   |   |   |                         404 for everything else
|   |   |   `-- logrotate.j2          daily rotation of the audit log (reload, which does not seal)
|   |   `-- hello-nginx.conf.j2       nginx site of the demo: HTTP -> HTTPS redirect, TLS
|   `-- matrix/                       our files for matrix-docker-ansible-deploy (MDAD)
|       |-- lab-setup.yml             the lab's entry point into MDAD (copied to ~/mdad): reads the
|       |                             Matrix secrets from OpenBao into memory, then imports setup.yml
|       `-- inventory/
|           |-- hosts                 group matrix_servers: matrix.lab.internal
|           `-- host_vars/matrix.lab.internal/
|               `-- vars.yml          our Matrix configuration: TLS through ACME from OpenBao,
|                                     federation off, calls (LiveKit), MAS with Keycloak, no mail,
|                                     no integrations
|-- scripts/                          PowerShell entry points, run from the project root
|   |-- Install-LabHostNetwork.ps1    once, by you: LabHost switch, 10.10.99.1, NRPT rule (-Remove)
|   |-- Initialize-Lab.ps1            build/update/start firewall and VMs in the right order (firewall
|   |                                 and vault first, OpenBao unsealed before any SSH), SSH CA and
|   |                                 host certificates, test, then renew what is due (step 7: runs
|   |                                 Deploy-LabVault.ps1 and/or Deploy-LabKeycloak.ps1); -BreakGlass
|   |-- New-LabFirewall.ps1           build (or start and check) the OPNsense firewall VM: its SSH
|   |                                 host key checked against the serial console, host certificate,
|   |                                 sshd drop-in; renew its GUI certificate in place when due;
|   |                                 -Rebuild, -BreakGlass
|   |-- New-LabRootCA.ps1             the offline root CA in keys\pki: created once, CRL kept current
|   |                                 (-RenewCrl), signs CSRs (-SignCsr, -Kind, -DnsName, -OutFile)
|   |-- Deploy-LabVault.ps1           deploy OpenBao (openbao.yml), initialise and unseal it, configure
|   |                                 it over its API: KV, policies, AppRoles (pc-admin, pc-deploy,
|   |                                 the break-glass login "recovery"), intermediate CA (a new one
|   |                                 400 days before expiry, or -RotateIntermediate), ACME, the SSH
|   |                                 secrets engine and its roles; renews OpenBao's TLS certificate
|   |                                 and the root CRL when due; step 8 (once): every machine trusts
|   |                                 OpenBao's SSH CA, proved by a test login, then OpenBao signs
|   |-- Install-LabRootCA.ps1         once, by you: trust the 2026 root CA for your Windows user
|   |                                 (-Remove; -RemoveRetired drops the retired first CA)
|   |-- New-LabRecoveryKit.ps1        by you, in your own window: key share C to write down and a
|   |                                 passphrase-encrypted recovery file with share B, the
|   |                                 break-glass login, the root CA and the offline SSH CA
|   |                                 (-Destination); -Renew: a new file later; -Open <file>;
|   |                                 -Recover <file> after losing the PC's DPAPI keys
|   |-- Deploy-LabKeycloak.ps1        deploy Keycloak (keycloak.yml with a run token), then an
|   |                                 OpenBao snapshot
|   |-- Deploy-LabMatrix.ps1          deploy the Matrix stack (vendor\mdad copied to ~/mdad,
|   |                                 matrix-prepare.yml, an OpenBao snapshot, then MDAD through
|   |                                 lab-setup.yml), checks; -Setup
|   |-- Update-LabMdad.ps1            -Commit <hash>: git subtree pull of another MDAD commit into
|   |                                 vendor\mdad, then its roles (two commits); the only script
|   |                                 that downloads MDAD
|   |-- Unlock-LabVault.ps1           unseal OpenBao with the two key shares in DPAPI (-Interactive:
|   |                                 you type two shares instead)
|   |-- Backup-LabVault.ps1           OpenBao snapshot to keys\openbao\snapshots, keeps 10 (-Keep,
|   |                                 -Destination for a copy elsewhere); also run by the two
|   |                                 deployments above, Import-LabSecrets.ps1 and Remove-Lab.ps1
|   |-- Show-LabSecret.ps1            copy a secret to the clipboard (-Show prints it, -List names,
|   |                                 -Pc a DPAPI secret on the PC, also one in a retired folder)
|   |-- Open-LabVaultUi.ps1           open OpenBao's web UI, a 1-hour login token on the clipboard
|   |-- Connect-Lab.ps1               SSH as "ansible" to a VM through the jump host, with the PC's
|   |                                 SSH certificate (renewed first when due; -BreakGlass)
|   |-- Invoke-LabPlaybook.ps1        sync ansible/ and the public PKI files to ansible-control and
|   |                                 run a playbook, with an SSH certificate for only the hosts it
|   |                                 needs ($sshPrincipals) and a run token if it needs OpenBao
|   |-- New-LabSshCa.ps1              once (Initialize-Lab.ps1 step 2): the offline SSH CA, this PC's
|   |                                 SSH key and the empty revocation list in keys\ssh; locks down
|   |                                 keys\ and the keys (icacls)
|   |-- Update-LabSshCertificate.ps1  this PC's SSH certificate: renew it when due and show signer and
|   |                                 validity (-Force: now; -BreakGlass: offline CA if OpenBao fails)
|   |-- Import-LabSecrets.ps1         one-time migration of the old secrets.yml files into OpenBao
|   |                                 (-RemovePlaintext)
|   |-- LabSecrets.ps1                shared helpers, dot-sourced by the others: DPAPI, OpenBao API
|   |                                 (TLS pinned to the lab root for OpenBao's host), unseal, run
|   |                                 tokens (Invoke-LabRunToken, with console colours switched on by
|   |                                 Enable-LabConsoleColors), new AppRole logins
|   |                                 (New-LabAppRoleSecret, then Remove-LabAppRoleSecretIds), the
|   |                                 maintenance check (Get-LabMaintenanceDue); loads LabSsh.ps1
|   |-- LabSsh.ps1                    SSH certificates (loaded by LabSecrets.ps1): the two SSH CAs and
|   |                                 who signs, the PC's certificate (Get-LabSshConfig), a run's
|   |                                 certificate, host keys from KVP and host certificates, the trust
|   |                                 files, keys\ssh_config, the revocation list
|   `-- Remove-Lab.ps1                delete all or one VM (vagrant destroy + Hyper-V folder; the
|                                     firewall via Hyper-V) and revoke their SSH host keys; with
|                                     vault: an OpenBao snapshot first, then keys\openbao and
|                                     OpenBao's SSH CA files moved aside
|-- tests/                            checks of the running lab, run from the project root
|   |                                 (tests\README.md; see "Run the tests")
|   |-- README.md                     what each test checks and whether it changes anything
|   |-- Invoke-LabTests.ps1           runs the tests that change nothing, then a summary (-Name;
|   |                                 -IncludeStateChanging adds Test-LabRecoveryLogin.ps1)
|   |-- LabTest.ps1                   shared helpers: PASS/FAIL lines, summary, exit code, remote\
|   |                                 copied to /tmp/lab-tests on ansible-control and removed again
|   |-- Test-LabCertificates.ps1      HTTPS endpoints: right CA, valid > 30 days, trusted by Windows
|   |-- Test-LabTlsPin.ps1            the PC's OpenBao calls pinned to the lab root, other hosts not
|   |-- Test-LabPasswordHash.ps1      the firewall's password hashing over stdin (local only)
|   |-- Test-LabRetiredDpapi.ps1      DPAPI secrets in keys\openbao-retired-* readable under new names
|   |-- Test-LabRunToken.ps1          a run token: policies, lifetime, bound to ansible-control, cleanup
|   |-- Test-LabSecretCreation.ps1    a missing secret: generated by OpenBao once, not under --check
|   |-- Test-LabFirewallRender.ps1    the firewall's build path (config.xml with the SSH CA lines,
|   |                                 seed ISO) in a temp folder
|   |-- Test-LabSshCa.ps1             the SSH certificate code on the PC: offline signing, contents,
|   |                                 refused principals, revocation list, trust files (local only)
|   |-- Test-LabSshCertificates.ps1   SSH in the running lab: strict logins, refused keys and CAs,
|   |                                 principals, source-address, revocation, sshd settings
|   |-- Test-LabRecoveryLogin.ps1     CHANGES STATE: break-glass login and new PC logins (asks first)
|   `-- remote/                       run on ansible-control by the tests
|       |-- run-token-check.sh        for Test-LabRunToken.ps1
|       |-- secret-creation.yml       for Test-LabSecretCreation.ps1
|       `-- ssh-cert-check.sh         for Test-LabSshCertificates.ps1
|-- vendor/                           third-party code the lab runs, unchanged, at a pinned version
|   |-- README.md                     what is vendored, from where, which version, licence, upgrade
|   `-- mdad/                         MDAD at the pinned commit with its 32 roles (roles\galaxy\),
|                                     unchanged; copied to ~/mdad by Deploy-LabMatrix.ps1
`-- keys/                             generated, never commit (in .gitignore), readable only by you and
                                      SYSTEM; secrets in it are DPAPI-encrypted (*.dpapi: only your
                                      Windows account on this PC can decrypt them)
    |-- ssh_config                    generated SSH client config: jump host, the PC's key and
    |                                 certificate, host keys only with a host certificate
    |-- ssh/                          SSH certificates (New-LabSshCa.ps1, LabSsh.ps1)
    |   |-- offline-ca, offline-ca.pub
    |   |                             the offline SSH CA; its key encrypted with the passphrase in
    |   |                             offline-ca-passphrase.dpapi
    |   |-- offline-ca.in-recovery-kit
    |   |                             the fingerprint of the offline SSH CA the newest recovery file
    |   |                             holds (not secret)
    |   |-- pc_ed25519(.pub)          this PC's SSH key, no passphrase; opens nothing without:
    |   |-- pc_ed25519-cert.pub       its current certificate (8 hours); pc_ed25519-cert.valid-until:
    |   |                             its expiry and CA, read without starting ssh-keygen
    |   |-- openbao-ca.pub            OpenBao's SSH CA public key, cached by Deploy-LabVault.ps1
    |   |-- openbao-ca.trusted        its fingerprint, written once every machine accepted a test
    |   |                             login: from then on OpenBao signs
    |   |-- lab_user_ca.pub           rendered: the CAs for logins (TrustedUserCAKeys on the VMs)
    |   |-- known_hosts               rendered: @cert-authority lines for the lab's exact host names
    |   |-- firewall_authorized_keys  rendered: the cert-authority lines of user ansible on the firewall
    |   |-- revoked_host_keys         the revocation list (KRL) of retired host keys
    |   |-- hosts/                    <name>.pub: each machine's verified host key; <name>-cert.pub:
    |   |                             its host certificate; retired/: replaced and revoked keys
    |   |-- issued.log                one line per certificate signed: time, signer, role, key ID,
    |   |                             serial, principals, expiry (no secrets)
    |   `-- tmp/                      short-lived work folders (public material only)
    |-- pki/                          the offline root CA (New-LabRootCA.ps1)
    |   |-- root-ca.crt               "DeployableServer Lab Root CA 2026" (PEM)
    |   |-- root-ca.key               its private key, PKCS#8, AES-256 encrypted
    |   |-- root-ca-passphrase.dpapi  the key's passphrase
    |   |-- openssl.cnf               extensions and CRL settings (rewritten on every run)
    |   |-- crl/                      OpenSSL's CRL database and the current root CRL (PEM)
    |   |-- pub/                      root-ca.crt and root-ca.crl as DER, served on the vault VM
    |   |                             at http://vault.lab.internal/pki/
    |   `-- issued/                   what the root signed: the intermediates (lab-int-<yyyy>.crt,
    |                                 after a rotation lab-int-<yyyyMMdd-HHmmss>.crt), vault.crt,
    |                                 firewall-gui.crt
    |-- openbao/                      the keys of THIS OpenBao installation (Deploy-LabVault.ps1)
    |   |-- unseal-a.dpapi, unseal-b.dpapi
    |   |                             two of the three key shares, enough to unseal
    |   |                             (Unlock-LabVault.ps1): A and B; after -Recover, C (as
    |   |                             unseal-a) and B
    |   |-- unseal-c-pending.dpapi    share C, only until New-LabRecoveryKit.ps1 has shown it to you
    |   |-- unseal-c.sha256           the fingerprint of share C (not secret), so that a renewed
    |   |                             recovery file carries it too
    |   |-- root-token.dpapi          the initial root token, only until the bootstrap is finished
    |   |-- pc-admin.dpapi, pc-deploy.dpapi
    |   |                             role_id and secret_id of the PC's two AppRoles (the
    |   |                             break-glass login "recovery" has no file here: its secret
    |   |                             exists only in the recovery file)
    |   `-- snapshots/                vault-<date-time>.snap (Backup-LabVault.ps1, the newest 10)
    |-- openbao-retired-<date-time>/  keys\openbao of a deleted vault VM, moved aside by Remove-Lab.ps1
    |                                 with a last snapshot (and, in ssh\, the public files of its SSH
    |                                 CA); its DPAPI files still open under the new name
    |                                 (Show-LabSecret.ps1 -Pc openbao-retired-<date-time>/unseal-a)
    |-- opnsense/                     the firewall's secrets (DPAPI: the firewall exists before OpenBao)
    |   |-- root-password.dpapi       GUI login of "root"
    |   |-- ansible-password.dpapi    password of "ansible", a full administrator (unused by the
    |   |                             scripts; SSH takes only certificates)
    |   `-- api-ansible.dpapi         REST API key and secret of "ansible"
    |-- recovery/                     DeployableServer-recovery-<date>.bin, the recovery file of
    |                                 New-LabRecoveryKit.ps1 without -Destination (copy it off the PC)
    `-- ca/                           the retired first lab CA: only lab-root-ca.crt, kept for
                                      Install-LabRootCA.ps1 -RemoveRetired
```

And on the VMs (created by the provisioning and the deployments, never edited by
hand):

```
ansible-control  ~/.ssh/id_ed25519      its own SSH key (made on the VM); id_ed25519-cert.pub only
                                        during a run (the run's certificate)
                 /etc/ssh/ssh_known_hosts, /etc/ssh/lab_revoked_host_keys
                                        the lab's SSH CAs for host certificates, the revocation list
                 /etc/ssh/ssh_config.d/20-lab.conf      host certificates required for *.lab.internal
                 ~/lab                  copy of ansible/ (replaced on every Invoke-LabPlaybook.ps1 run)
                 ~/lab-pki              public files from keys\pki: root-ca.crt, pub/root-ca.{crt,crl}
                 ~/mdad                 a copy of vendor\mdad (replaced on every Deploy-LabMatrix.ps1
                                        run), plus the lab's inventory and lab-setup.yml;
                                        inventory/ holds our hosts and vars.yml and the generated
                                        lab-shared.yml (no secrets)
                 $XDG_RUNTIME_DIR/ansible-local.*       Ansible's local temporary files during one
                                        run (RAM; /dev/shm without a login session), removed at its end
matrix           /matrix                MDAD's configuration and data (Synapse, PostgreSQL, MAS, Traefik, ...)
                 /matrix/traefik/ssl/acme.json          Traefik's ACME account, keys and certificates
                                        (removed by matrix-prepare.yml after a change of intermediate)
                 /etc/systemd/system/matrix-*.service   the nine units
keycloak         /opt/keycloak-stack    compose.yml, keycloak.env, postgres.env, tls/, truststores/
                 Docker volume keycloak_pgdata          Keycloak's database
vault            /etc/openbao/openbao.hcl               OpenBao's configuration
                 /opt/openbao/tls       tls.key (made on the VM), tls.crt (signed by the offline root)
                 /opt/openbao/data      raft storage, encrypted (readable only by an unsealed OpenBao)
                 /var/log/openbao/audit.log             audit log (values HMAC-hashed), rotated daily
                 /var/www/pki           root-ca.crt and root-ca.crl (DER), served by nginx on port 80
every Ubuntu VM  /usr/local/share/ca-certificates/lab-root-ca-2026.crt   the root in the trust store
                 /etc/ssh/lab_user_ca.pub               the lab's SSH CAs for logins (TrustedUserCAKeys)
                 /etc/ssh/lab_principals/ansible        lab-all and host-<vm>: the principals that log in
                 /etc/ssh/ssh_host_ed25519_key-cert.pub the VM's host certificate (installed by the PC)
                 /etc/ssh/sshd_config.d/10-lab-hardening.conf   certificate logins only, AllowUsers
firewall         /conf/sshd/ssh_host_ed25519_key-cert.pub       the firewall's host certificate
                 /usr/local/etc/ssh/sshd_config.d/20-lab-ssh.conf   the jump host's sshd drop-in
```

---

## 9. Pitfalls and troubleshooting

### Quick checks

```powershell
Get-VMSwitch | Select-Object Name, SwitchType                     # LabHost Internal, LabNet Private
Get-VM | Select-Object Name, State, ProcessorCount                 # firewall, ansible-control, matrix, keycloak, vault
Get-VMNetworkAdapter -VMName firewall | Select-Object Name, SwitchName, MacAddress   # WAN, LAN, HOST
Get-DnsClientNrptRule                                             # .lab.internal -> 10.10.99.2
Resolve-DnsName firewall.lab.internal                             # expected: 10.10.99.2
Resolve-DnsName element.lab.internal                              # expected: 10.10.99.3
Resolve-DnsName lab.internal                                      # expected: 10.10.99.3
Resolve-DnsName keycloak.lab.internal                             # expected: 10.10.99.4
Resolve-DnsName vault.lab.internal                                # expected: 10.10.99.5
Test-NetConnection 10.10.99.2 -Port 22                            # SSH (jump host)
Test-NetConnection 10.10.99.2 -Port 443                           # web GUI
Test-NetConnection 10.10.99.3 -Port 443                           # Traefik on matrix
Test-NetConnection 10.10.99.3 -Port 7881                          # LiveKit (TCP fallback)
Test-NetConnection 10.10.99.4 -Port 443                           # Keycloak
Test-NetConnection 10.10.99.5 -Port 8200                          # OpenBao (API, web UI, ACME)
Test-NetConnection 10.10.99.5 -Port 80                            # CA certificates and CRLs
curl.exe -s https://vault.lab.internal:8200/v1/sys/health         # expected: "initialized":true,"sealed":false
.\scripts\Unlock-LabVault.ps1                                     # unseals OpenBao, or says it already is
.\scripts\Show-LabSecret.ps1 -List                                # secrets in OpenBao and on the PC (names only)
. .\scripts\LabSecrets.ps1; Get-LabMaintenanceDue                 # renewals due now (none: empty); Initialize-Lab.ps1 step 7 runs them
.\scripts\Update-LabSshCertificate.ps1                            # the PC's SSH certificate: renewed if due, signer and validity
.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -sr'               # filter rules pf runs
.\scripts\Connect-Lab.ps1 firewall 'sudo pfctl -s nat'            # port forwards and outbound NAT
.\scripts\Invoke-LabPlaybook.ps1 ping.yml
```

The service checks (units, containers, logs, `curl.exe` against the
`.well-known` files and the issuers) are in
[Look at the services and their logs](#look-at-the-services-and-their-logs).
OpenBao's own log:
`.\scripts\Connect-Lab.ps1 vault 'sudo journalctl -u openbao -n 50 --no-pager'`.

If the firewall does not answer at all, look at its console: Hyper-V Manager >
Connect shows its video console, and the log of the first boot is in
`G:\Vagrant\hyperv\firewall\logs\serial-console.log`.

Use `Resolve-DnsName`, not `nslookup`, to test lab names. `nslookup` asks your
default DNS server directly and ignores the NRPT rule, so it fails even when
everything works. A browser that uses its own DNS-over-HTTPS resolver can bypass
the rule in the same way.

Each item below follows the pattern **symptom -> cause -> what the project
does**. The comments in the named files go into more detail. The items are
grouped: the firewall (P1-P10), Windows, SSH and Vagrant (P11-P17),
certificates (P18-P19), Ansible (P20-P23), Keycloak and containers (P24-P26),
login (P27-P32), MDAD's checks (P33-P34), calls (P35), OpenBao (P36-P39), run
tokens and secrets in the playbooks (P40-P43), ACME (P44), the scripts that
show secrets (P45), recovery and the deletion of the vault VM (P46-P47),
Ansible's pipelining and check mode (P48-P49), the Windows console, Windows
path lengths and the vendored MDAD (P50-P52), and SSH certificates (P53).

### P1. The OPNsense image does not boot in a Generation 2 VM

- **Symptom**: a Hyper-V Generation 2 VM (UEFI firmware) does not start the
  OPNsense nano image.
- **Cause**: the nano image (a ready-installed disk image for small appliances)
  boots only with BIOS, and Generation 2 VMs have only UEFI.
- **What the project does**: [scripts/New-LabFirewall.ps1](scripts/New-LabFirewall.ps1)
  creates a Generation 1 VM (BIOS, IDE disk, the seed ISO in an IDE DVD drive)
  and boots from the disk first.

### P2. The firewall panics with several vCPUs

- **Symptom**: the firewall VM crashes with a kernel panic on Hyper-V.
- **Cause**: OPNsense 26.7 before 26.7.7 could panic on Hyper-V with several
  virtual CPUs; the Hyper-V fixes came with 26.7.6/26.7.7. Installation images
  are only released for 26.7, so every new firewall starts with an affected
  kernel.
- **What the project does**: the VM has 1 vCPU, which is plenty for a lab
  firewall, and the build updates base system and kernel to at least 26.7.7
  (`$minimumVersion`) right after the first boot.

### P3. A new OPNsense would run a DHCP server on the wrong network

- **Symptom**: an unplanned DHCP server appears on a network the firewall is
  connected to (for example the Default Switch, where `hn0` is) and competes
  with the real one.
- **Cause**: until it has a configuration, OPNsense boots with its factory
  default, which runs a DHCP server on its first network adapter.
- **What the project does**: all three adapters are created **disconnected**.
  They are connected only after the serial console has shown that the lab
  configuration was imported ("Restoring config.xml...done"), so the factory
  default never reaches a real network. Enterprise equivalent: new appliances are
  staged on an isolated network before they go live.

### P4. The configuration importer does not take the lab configuration

- **Symptom**: the build stops with "No CD drive in the importer's device list"
  or with a message from the firewall's console, or the firewall stops at an
  interactive interface assignment.
- **Cause**: the importer lists the disks with all their FreeBSD device names,
  for example `<Msft Virtual CD/ROM 1.0> at scbus1 target 0 lun 0 (pass0,cd0)`.
  Only `cd0` is the name to import from (`pass0` is the raw pass-through device
  of the same drive). The importer expects the file at `conf/config.xml` and
  offers itself only for a few seconds at boot. And if an interface named in
  `config.xml` (`hn0`, `hn1`, `hn2`) does not exist, OPNsense asks for an
  interface assignment instead of booting on.
- **What the project does**: the seed ISO contains `conf/config.xml`. The script
  waits for the importer's prompt before it presses a key, picks the `cdN` name
  from the device list with a regular expression, and stops on known error
  messages (for example "could not be mounted", "Bootstrapping config.xml",
  "Valid interfaces are") instead of waiting forever. Everything the console
  printed is in `G:\Vagrant\hyperv\firewall\logs\serial-console.log`.

  If the build stops before it prints
  `Adapters:    hn0 = WAN, hn1 = LAN, hn2 = HOST (checked by MAC)`, fix the cause
  and run `.\scripts\New-LabFirewall.ps1 -Rebuild`. A plain re-run treats the
  half-built VM as finished (it already carries the script's tag): it starts it,
  waits up to five minutes for SSH on 10.10.99.2 (if the adapters were never
  connected, it stops with "Timeout: nothing answers on 10.10.99.2:22 after
  300 s."), and never repeats the adapter check. The seed ISO (password hashes,
  GUI private key) is not left behind: the script ejects it and deletes
  `G:\Vagrant\hyperv\firewall\seed\` when the first boot ends, also when it
  failed. If that deletion itself fails (the script warns) or the script was
  killed, the next run of `New-LabFirewall.ps1`, plain or `-Rebuild`, removes
  the folder. A failure after that line, for
  example in the firmware update
  ([P5](#p5-the-firmware-update-fails-with-fetch-transfer-timed-out)), is
  finished by a plain re-run.

### P5. The firmware update fails with "fetch: transfer timed out"

- **Symptom**: `opnsense-update` stops with `fetch: transfer timed out`, and the
  build prints "attempt 1 of 3 failed".
- **Cause**: the firewall downloads from `pkg.opnsense.org` through Windows NAT
  (Default Switch). Downloads there sometimes stall, and `opnsense-update` gives
  up after 30 seconds without data.
- **What the project does**: each update step (packages, then base system and
  kernel) is retried up to 3 times; the commands are idempotent, so what is
  already installed is not downloaded again. If all attempts fail, run
  `.\scripts\New-LabFirewall.ps1` again: it updates whatever is still below
  26.7.7, and it finishes a pending kernel switch by comparing the running
  kernel (`uname -r`) with the installed one (`freebsd-version -k`) and
  rebooting if they differ.

### P6. A firewall change has no effect, or is gone after a rebuild

- **Symptom**: a new name or port under `published` in `config/lab.json` does
  not resolve or is not forwarded; an edit of `opnsense/config.xml.template` or
  of the firewall data in `config/lab.json` changes nothing; a file edited by
  hand on the firewall is back to its old content; a rule added in the GUI is
  missing after a rebuild.
- **Cause**: OPNsense keeps its whole configuration in `/conf/config.xml` and
  regenerates its system files from it, so hand-edited files are overwritten.
  The repository files are read only when the firewall is **built**; on a
  re-run, `New-LabFirewall.ps1` only starts and checks the existing VM. GUI and
  REST API changes go into `/conf/config.xml` on the VM, never into the
  repository.
- **What the project does**: `config.xml` is the truth. Change the repository
  and run `.\scripts\New-LabFirewall.ps1 -Rebuild`, or change the running
  firewall through the GUI or the REST API (and, if it should survive a
  rebuild, make the same change in the repository). Do not edit files on the
  firewall. The one exception is the dnsmasq drop-in `10-lab.conf`, which is not
  part of `config.xml`; the script installs it again on every run.

### P7. Published host entries: the domain itself and a VM's own name

- **Symptom**: `lab.internal` itself (the `"@"` name) does not resolve, although
  the configuration contains a host entry for it. Then calls fail (Element
  finds no call focus, and the LiveKit JWT service cannot read
  `https://lab.internal/.well-known/matrix/server`), MDAD's self-check of the
  `.well-known` files fails, and clients that know only the server name (for
  example Element X) cannot find the homeserver.
- **Cause**: OPNsense skips dnsmasq host entries with an empty host name, which
  is the natural way to write "the domain itself". A second special case: a VM
  published under its own name (`matrix` -> `matrix.lab.internal`) already has a
  host entry with its lab address, the DHCP reservation; a published entry with
  both addresses would list the lab address a second time.
- **What the project does**: `New-LabFirewall.ps1` writes `"@"` as host `lab` in
  domain `internal`, which gives the same full name `lab.internal` (it stops if
  the domain has only one label). For a name equal to the VM's name it adds only
  the published address; the reservation entry supplies the lab address.

### P8. The firewall answers DNS on a published address

- **Symptom**: `Resolve-DnsName element.lab.internal -Server 10.10.99.3` gets an
  answer: the firewall's DNS answers on a published address, although only the
  published ports should be open there.
- **Cause**: a rule whose destination is "HOST address" (`opt1ip` in
  `config.xml`) becomes `(hn2)` in pf, which means **every** address on the
  interface, the virtual IPs included. The PC rules would then open the
  firewall's DNS on the published addresses too: dnsmasq listens on every
  address. (`nobind` keeps only the web GUI and the SSH server off the virtual
  IPs; ntpd listens on them too, but no rule passes its port.)
- **What the project does**: the PC rules in
  [config.xml.template](opnsense/config.xml.template) name the single
  management address `{{HOST_IP}}` (10.10.99.2) as destination. Verified from
  the PC: 10.10.99.2 answers on 22, 53 and 443 only, the published addresses
  only on their forwarded ports.

### P9. Lab VMs reach the firewall's management through the anti-lockout rule

- **Symptom**: from a lab VM, SSH or HTTPS to the firewall's HOST address
  10.10.99.2 works, although the first LAN rule blocks the whole HOST network.
- **Cause**: OPNsense's hidden anti-lockout rule on its first interface (LAN)
  passes SSH and HTTPS to every firewall address, ahead of all user rules.
- **What the project does**: `<noantilockout>1</noantilockout>` in `<webgui>`
  switches it off; every management path is an explicit rule instead (see
  [What is allowed where](#what-is-allowed-where), also for the way back in
  after a lockout).

### P10. "A VM named 'firewall' exists that this script did not build"

- **Symptom**: `New-LabFirewall.ps1` (or `Initialize-Lab.ps1` in its step 4)
  stops with this message. `.\scripts\Remove-Lab.ps1 firewall` refuses the VM
  too ("tag missing in its Notes").
- **Cause**: both scripts touch only a VM whose Notes carry the tag that
  `New-LabFirewall.ps1` writes there, so they never delete a VM they did not
  create, for example a firewall from an older version of this lab or a VM of
  your own with that name.
- **What to do**: check in Hyper-V Manager what the VM is. If you do not need
  it, delete it there yourself, together with its virtual disk (Hyper-V does
  not delete the disk with the VM), or rename the VM; then run the script again.
  In PowerShell: `Remove-VM -Name firewall -Force`, then delete the VM's folder.

### P11. Windows PowerShell 5.1 quirks

- **Embedded double quotes** in arguments to native programs (ssh, ssh-keygen)
  are not escaped correctly. The scripts avoid double quotes in remote
  commands, including the commands `New-LabFirewall.ps1` runs on the firewall
  and the commands the deployment scripts run on ansible-control.
- **`Set-Content -NoNewline` with positional arguments did not write the
  intended file** (met while writing the firewall's secret files): instead a new
  file appeared in the current folder, named after the value (a generated
  password) and containing the target path. A secret ended up as a file name
  outside `keys\`, where `.gitignore` does not protect it. The scripts write
  files with `[IO.File]::WriteAllText`/`WriteAllLines` instead (the DPAPI files
  and OpenSSL's configuration too), which is also the way to get UTF-8 without a
  BOM (as for `keys\ssh_config`, the SSH trust files and the `config.xml` in the
  seed ISO).
- **Empty-string arguments are dropped**. `ssh-keygen -N ''` would lose the empty
  passphrase, so [scripts/New-LabSshCa.ps1](scripts/New-LabSshCa.ps1) (and
  `LabSsh.ps1` for its throwaway test key) passes `'""'` (PowerShell 7.3+ gets
  `''`). The same would make `ssh-keygen -n ''` take the next argument as its
  principals, which is one reason why `LabSsh.ps1` refuses to sign for an empty
  list of principals.
- **stderr becomes a terminating error**: with `$ErrorActionPreference = 'Stop'`
  and redirected output (`*> log`), any line a native program writes to stderr
  stops the script. Therefore ssh and scp run with `-o LogLevel=ERROR` (no
  "Permanently added ..." notice; the Vagrantfile's proxy command does the
  same), and `Invoke-LabPlaybook.ps1` switches to `Continue` before it runs
  `ansible-playbook` and judges success by the exit code instead.
  `New-LabFirewall.ps1` does the same for OpenSSL, which writes progress
  messages to stderr, and for its SSH commands. For the firmware update it
  also appends `2>&1` to the **remote** command, so the firewall's shell merges
  pkg's notices into stdout before they reach PowerShell; the deployment
  scripts wrap their remote commands in `{ ...; } 2>&1` for the same reason
  (Ansible writes its warnings to stderr).
- **`-v` is swallowed by advanced scripts**: a script with `[CmdletBinding()]`
  treats `-v` as `-Verbose`. `Invoke-LabPlaybook.ps1` is deliberately not an
  advanced script, so `-v` reaches `ansible-playbook`. `Connect-Lab.ps1` is a
  plain script for the same reason: every extra argument goes to `ssh`.
- **Advanced functions take over native options**: the same happens inside a
  script. An advanced function would try to bind OpenSSL options such as `-out`
  to its own common parameters (`-OutVariable`) instead of passing them on. The
  OpenSSL wrappers in `New-LabFirewall.ps1` and `New-LabRootCA.ps1` are
  therefore simple functions that hand `$args` to `openssl.exe` unchanged.
- **Native exit codes do not stop a script**: `$ErrorActionPreference = 'Stop'`
  reacts only to PowerShell errors, so the scripts check `$LASTEXITCODE`
  explicitly after native programs such as `vagrant`, `ssh`, `scp`, `tar` and
  `curl.exe`.
- **Everything a function outputs is its return value**: a function that runs
  `ssh` and ends with `return $LASTEXITCODE` returns ssh's output lines *and* the
  number, as one array. A check such as `if ($code -ne 0)` then filters that
  array instead of testing the exit code, and the output no longer appears while
  the command runs. `Invoke-LabRunToken` (`LabSecrets.ps1`) therefore returns
  nothing: the remote output goes straight to the console, and the caller reads
  `$LASTEXITCODE`. Functions that do return a value pipe everything else to
  `Out-Null`.
- **Piped text arrives with extra bytes**: Windows PowerShell 5.1 appends CRLF
  to text it pipes into a native program, and with a UTF-8 `$OutputEncoding` it
  can also put a byte order mark (BOM) in front. For a token that is harmless:
  `ansible/bin/openbao-run` keeps only the characters a token can contain (see
  [P42](#p42-the-run-token-is-echoed-or-arrives-damaged)). For a password it is
  not: `openssl passwd -stdin` would hash the CR as part of the password, and the
  firewall would never accept the real one. `Get-PasswordHash` in
  `New-LabFirewall.ps1` therefore starts openssl through .NET's `Process` class
  and writes the secret and a plain LF to its stdin itself. .NET Framework
  would put a BOM in front of that input when the console's input encoding is
  UTF-8, so the script sets it to UTF-8 without BOM while it starts openssl.
  The secret never appears on openssl's command line, which other programs can
  read.

### P12. Windows OpenSSH quirks

- **"Unprotected private key file" / key ignored**: Windows OpenSSH refuses a
  private key that other users can read. Here, the project folder passes read
  access on to every file inside it (inherited permissions, e.g. for a group
  like `CodexSandboxUsers`). `New-LabSshCa.ps1` uses `icacls` to remove
  inheritance and grant access only to you (the offline SSH CA key and this PC's
  SSH key, on every run); `LabSecrets.ps1` does the same for every DPAPI file it
  writes, `New-LabRootCA.ps1` for the root CA key, and `New-LabFirewall.ps1` for
  the staged `config.xml` and the seed ISO. `New-LabSshCa.ps1` also locks the
  `keys\` folder itself (only you and SYSTEM, inherited by everything inside), so
  new files such as the OpenBao snapshots and the recovery file in
  `keys\recovery` are protected from the start.
- **`ssh-keygen` reads passphrases only from the console**, not from stdin, so a
  script cannot hand it the offline SSH CA's passphrase there; `LabSsh.ps1` uses
  `-P` instead and accepts the price
  ([SSH certificates](#ssh-certificates-user-and-host-cas), "What remains").
- **`ssh-keygen -L` prints a certificate's validity in local time**, which is
  ambiguous for an hour every autumn. `LabSsh.ps1` runs it with `TZ=UTC0`, so it
  prints UTC.
- **scp with two remote sources fails**: Windows scp refuses to copy several
  remote files in one call. The scripts fetch one remote file per call (the
  firewall's certificate request); several local files to one remote folder
  work (the public PKI files, the GUI certificate with the root and
  `lab-gui-cert.php`).
- **ssh_config with a UTF-8 BOM breaks**: ssh cannot parse the first line.
  `Initialize-Lab.ps1` writes the file without a BOM and with LF line endings
  (`Write-LabSshConfig` in `LabSsh.ps1`), like every SSH file the lab renders.
- **Paths**: forward slashes in `ssh_config` paths are the safest choice.

### P13. Later vagrant commands hit the lab unexpectedly

- **Symptom**: `vagrant destroy` in another project's folder destroys lab VMs.
- **Cause**: `$env:VAGRANT_CWD` tells Vagrant where the Vagrantfile is. If a
  script set it and left it set, it would stay in your shell and redirect every
  later vagrant command.
- **What the project does**: `Initialize-Lab.ps1` and `Remove-Lab.ps1` save the
  old value and restore it in a `finally` block. (`VAGRANT_HOME` is different: it
  is meant to be permanent and global.)

### P14. A removed VM leaves its Hyper-V folder behind

- **Symptom**: after `vagrant destroy` the folder `G:\Vagrant\hyperv\<vm>` still
  exists, with the VM's old Hyper-V configuration files.
- **Cause**: `Initialize-Lab.ps1` moves each Ubuntu VM's Hyper-V files
  (configuration, checkpoints, smart paging) into that folder with
  `Move-VMStorage`. `vagrant destroy` deletes the VM and its disk, but not a
  folder that Vagrant did not create.
- **What the project does**: `Remove-Lab.ps1` notes the folders before the
  destroy and deletes them afterwards, but only for VMs listed in
  `config/lab.json`, only a folder named exactly like its VM, and only if the
  VM is really gone.

### P15. Addresses on the Default Switch stop working after a Windows reboot

- **Symptom**: an address or `<host>.mshome.net` name on the Default Switch that
  worked yesterday points nowhere.
- **Cause**: the Default Switch gets a new subnet on every Windows boot, and its
  `<host>.mshome.net` names go stale.
- **What the project does**: the PC uses only the fixed LabHost network
  (10.10.99.1 <-> 10.10.99.2, .3, .4 and .5); nothing in the lab depends on a
  Default Switch address. `keys\ssh_config` addresses the firewall by IP, so SSH
  works even when its DNS is down (`HostKeyAlias firewall.lab.internal` makes
  ssh check its host certificate for its name all the same). The firewall VM is
  shut down (not saved) together with Windows, so it boots fresh and gets a new
  WAN lease in the new subnet.

### P16. The Ubuntu VMs all have the same SSH host keys, and `vagrant`/`vagrant` works over SSH

- **Symptom**: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints the
  same fingerprint on every Ubuntu VM; `ssh vagrant@<vm>` accepts the password
  `vagrant`.
- **Cause**: the Vagrant box was built once, with its host keys and the
  well-known default password baked into the image. Every VM made from it is a
  copy, and anyone who downloads the public box has the same keys.
- **What the project does**: [provision/harden-ssh.sh](provision/harden-ssh.sh)
  generates new host keys once per VM (a marker file stops it from doing that on
  every run), publishes the new ed25519 key to the PC through Hyper-V KVP (never
  the box's shared keys), and switches SSH to certificate logins only, without
  passwords, with a drop-in in `/etc/ssh/sshd_config.d/`. The console in
  Hyper-V Manager is not affected. The firewall is not made from the box; a newly
  built firewall has new host keys, and SSH on it accepts only certificates.

### P17. `ssh matrix.lab.internal` does not reach the VM

- **Symptom**: SSH to the full name without the lab's jump-host setting hangs
  and then times out, although `.\scripts\Connect-Lab.ps1 matrix` works. For
  example `ssh -i keys\ssh\pc_ed25519 ansible@matrix.lab.internal` (without
  `-F keys\ssh_config`), or another SSH client set up with the full name
  (PuTTY, VS Code Remote-SSH).
- **Cause**: split-horizon DNS. Without a jump host, your PC resolves
  `matrix.lab.internal` itself and gets `10.10.99.3`, the published address,
  where only the published ports (80, 443, 7881, UDP 7882) are forwarded. pf
  drops everything else there without an answer, hence a timeout rather than
  "connection refused".
- **What the project does**: the generated `keys\ssh_config` routes every
  `*.lab.internal` name except the firewall's through `ProxyJump firewall`, so the
  firewall resolves the name to the lab address, and
  `ssh -F keys\ssh_config matrix.lab.internal` works as well. For your own SSH
  client, copy the `Host` blocks from `keys\ssh_config` (the `Host *` block names
  the PC's certificate and the lab's `known_hosts`), or call ssh with
  `-F keys\ssh_config`. The certificate lasts 8 hours, and only the lab's
  scripts renew it: run `.\scripts\Update-LabSshCertificate.ps1` first
  ([P53](#p53-ssh-host-key-verification-failed-or-permission-denied-publickey)).

### P18. The browser or OpenSSL rejects the certificate, or Windows stops trusting it

- **Symptom**: a certificate error such as `permitted subtree violation` or
  `excluded subtree violation`; a trust warning for every lab site; a warning
  for the firewall's GUI opened by IP; a lab service that still presents a
  certificate of the retired first lab CA.
- **Cause**: the lab root "DeployableServer Lab Root CA 2026" and every
  intermediate CA below it carry the critical X.509 name constraint
  `permitted DNS:lab.internal`, and they exclude every IPv4 and IPv6 address.
  **Every** name in a certificate (SAN) must be a full name under
  `lab.internal`, and no certificate below the root may contain an IP address. A
  single short name like `matrix`, or one IP address, makes the whole
  certificate invalid. The GUI certificate names only `firewall.lab.internal`
  (an IP address is not allowed in it), so `https://10.10.99.2` gets a warning.
  Windows trusts only roots you imported yourself (a browser that was already
  running may need a restart to notice). The retired first CA ("DeployableServer
  Lab CA") is no longer in the VMs' trust stores, and after `-RemoveRetired` no
  longer in yours either, so a certificate it issued fails.
- **What the project does**: the playbooks and scripts request only full
  names. The OpenBao roles allow only their listed names (no other subdomains,
  no wildcards, no IP addresses, no `localhost`), and `New-LabRootCA.ps1 -SignCsr`
  refuses a name outside the domain before it signs. The root is created once
  and never replaced (`New-LabRootCA.ps1` stops if `keys\pki` holds the key
  without the certificate), and it lives on the PC, not on a VM: rebuilding any
  VM, even vault, and rotating the intermediate keep Windows' trust, because
  every new intermediate is signed by the same root. Certificates from another
  CA are replaced on the next run: `tasks/openbao-certificate.yml` renews a
  certificate whose authority key identifier does not match the current
  intermediate's subject key identifier (after a rotation, after a rebuilt vault
  VM, or for a certificate of the retired first CA); `matrix-prepare.yml` makes
  Traefik start over with ACME when it serves a certificate of an older lab
  intermediate ([P44](#p44-traefik-serves-traefik-default-cert)); and
  `New-LabFirewall.ps1` renews the GUI certificate in place when it does not
  chain to the root. `Install-LabRootCA.ps1` imports only the 2026 root and
  says so when Windows still trusts the retired one. Run
  `.\scripts\Install-LabRootCA.ps1` once (and
  `.\scripts\Install-LabRootCA.ps1 -RemoveRetired` if Windows still trusts the
  old CA), restart the browser, and open the GUI by name:
  <https://firewall.lab.internal>.

### P19. `curl.exe` fails with a revocation error

- **Symptom**: `curl.exe https://element.lab.internal` fails with
  `CRYPT_E_REVOCATION_OFFLINE (0x80092013)` or
  `CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`, while the page opens in the
  browser.
- **Cause**: curl.exe on Windows uses Schannel, which checks the revocation
  status of every certificate in the chain and treats "status unknown" as an
  error. Every lab certificate names where its CA publishes its revocation list
  (CRL): `http://vault.lab.internal/pki/root-ca.crl` for the root, an OpenBao
  path on the same port 80 for the intermediate that issued it. The check fails
  when Windows cannot get a current CRL: the vault VM is off; OpenBao is sealed
  (the intermediate's CRL comes from OpenBao itself, through nginx; Windows can
  still use a cached copy until it expires after 7 days); the root's CRL has
  expired (400 days); or the certificate comes from a CA that no longer
  publishes one (the retired first lab CA, or the intermediate of a deleted
  vault VM, until the certificate is renewed). An intermediate replaced by a
  rotation is not such a case: it stays in OpenBao and keeps publishing its CRL.
  Browsers do not fail hard on this.
- **What the project does**: no `--ssl-no-revoke` any more; the checks in
  `Deploy-LabMatrix.ps1` run plain `curl.exe`. nginx on the vault VM serves the
  root's certificate and CRL as files and passes only the intermediates' CA and
  CRL paths on to OpenBao. OpenBao rebuilds its CRLs by itself (valid 7 days,
  rebuilt 2 days before they expire). `New-LabRootCA.ps1` renews the root's CRL
  when it has less than 60 days left; `Deploy-LabVault.ps1` runs it and then
  publishes the file (`openbao.yml`), and `Initialize-Lab.ps1` runs
  `Deploy-LabVault.ps1` by itself when that is due (step 7). To fix:
  `.\scripts\Unlock-LabVault.ps1`
  ([P36](#p36-openbao-is-sealed-after-the-vault-vm-restarts)), then
  `.\scripts\Deploy-LabVault.ps1`; for a certificate of an old CA, run that
  service's deployment again. `--ssl-no-revoke` is still useful as a diagnosis:
  if a command works with it and fails without it, the CRL is the problem, not
  the certificate.

### P20. Ansible ignores ansible.cfg

- **Symptom**: `[WARNING]: Ansible is being run in a world writable directory ... ignoring it as an ansible.cfg source`,
  followed by "no inventory" / "provided hosts list is empty".
- **Cause**: for security, Ansible ignores an `ansible.cfg` in a world-writable
  directory, and the archive packed on Windows can arrive with such permissions.
- **What the project does**: `Invoke-LabPlaybook.ps1` runs `chmod -R go-w` after
  extracting the project on ansible-control.

### P21. `pipx install --global` does not exist

- **Symptom**: `pipx: error: unrecognized arguments: --global`.
- **Cause**: Ubuntu 24.04 ships pipx 1.4.3, which predates `--global`.
- **What the project does**: [provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh)
  installs Ansible system-wide with `PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin`.

### P22. Ansible warns that a group and a host have the same name

- **Symptom**: `[WARNING]: Found both group and host with same name: matrix`.
- **Cause**: groups and hosts share one namespace in host patterns, so
  `hosts: matrix` would be ambiguous: the group or the host?
- **What the project does**: groups are named by role (`matrix_servers`,
  `keycloak_servers`), hosts by machine (`matrix`, `keycloak`), see
  [hosts.ini](ansible/inventory/hosts.ini). The old demo group `web` and a host
  in it follow the same rule.

### P23. A task keyword between module parameters breaks the task

- **Symptom**: a playbook stops with a YAML syntax error, or with
  `Unsupported parameters for (...) module: no_log` (or `diff`).
- **Cause**: `no_log`, `diff`, `become`, `when` and so on are **task**
  keywords. They belong at the indentation of the module name, not among the
  module's parameters; placed between them, they either break the YAML
  structure or are passed to the module as unknown parameters.
- **What the project does**: task keywords stand after the module's parameters,
  at task level (see the OpenBao tasks in `tasks/openbao-secrets.yml`, where
  `no_log: true` and `check_mode: false` follow the module's parameters).

### P24. Keycloak cannot read its TLS key

- **Symptom**: the Keycloak container does not become healthy, and its log says
  the key file cannot be read; or, after a certificate renewal, Keycloak keeps
  presenting the old certificate.
- **Cause**: the Keycloak image runs as user ID 1000 with group 0 (root). A key
  file with mode 0600 owned by root is unreadable for it. And a bind mount of a
  single file keeps showing the old file when a renewal replaces it.
- **What the project does**: the key is `0640 root:root` (readable by group
  root, so by Keycloak, and by nobody else on the VM), and whole folders are
  mounted (`./tls`, `./truststores`), not single files. Keycloak re-reads its
  certificate hourly, and the playbook restarts it when the files change.

### P25. PostgreSQL 18 does not start with the old volume path

- **Symptom**: the `postgres:18` container refuses to start with its data volume
  mounted at `/var/lib/postgresql/data`, the path almost every older example
  uses.
- **Cause**: from version 18 the official image keeps its data below
  `/var/lib/postgresql` in a version-specific folder and expects the volume
  there.
- **What the project does**: [compose.yml.j2](ansible/templates/keycloak/compose.yml.j2)
  mounts the volume at `/var/lib/postgresql`. The health check also connects
  over TCP, because during the first initialisation the image runs a temporary
  server on the Unix socket only, and a socket check would report "healthy" too
  early.

### P26. The same image tag suddenly means a different image

- **Symptom**: a rebuild pulls a different Keycloak image than the last one,
  although the tag `26.8.1` did not change.
- **Cause**: a tag is a movable name; its publisher can push a new image under
  it, and the `26.8.1` tag was re-pushed on 2026-10-23.
- **What the project does**: `keycloak_image` in `keycloak.yml` names tag and
  digest (`...:26.8.1@sha256:...`). Docker then pulls exactly that image; the
  tag is only for humans. An upgrade changes both.

### P27. Keycloak answers "Invalid parameter: redirect_uri"

- **Symptom**: instead of the login form, Keycloak shows an error page with
  "Invalid parameter: redirect_uri".
- **Cause**: Keycloak compares the redirect URI of the request exactly with the
  client's registered list. MAS's URI contains its path prefix and the
  provider's ULID:
  `https://matrix.lab.internal/auth/upstream/callback/01M5MXJ0M87K1Q6HEADGFT47CR`.
  Without `/auth`, or with another ULID, it does not match.
- **What the project does**: both sides build the URI from the same values in
  [group_vars/all.yml](ansible/inventory/group_vars/all.yml)
  (`lab_mas_public_base`, `lab_mas_keycloak_provider_id`). The ULID must never
  change: MAS stores every account link under it.

### P28. Ansible breaks the MAS claim templates

- **Symptom**: `Deploy-LabMatrix.ps1` fails while rendering the MAS
  configuration, typically with an error that `user` is undefined.
- **Cause**: MAS's claim mapping uses templates in the same `{{ ... }}` syntax
  as Ansible (`{{ user.preferred_username }}`). Ansible renders every value in
  `vars.yml` and tries to fill them in itself.
- **What the project does**: the MAS templates in `vars.yml` are wrapped in
  `{% raw %} ... {% endraw %}`, so Ansible passes them on unchanged and MAS fills
  them in at login time.

### P29. MAS runs, but cannot reach Keycloak

- **Symptom**: all services run and MDAD's self-check passes, but signing in
  fails; MAS's log shows `Failed to fetch provider metadata` or
  `Failed to refresh provider metadata`.
- **Cause**: MAS starts even when it cannot load Keycloak's discovery document;
  it only logs the error. The reasons are usually DNS (the container cannot
  resolve `keycloak.lab.internal`), trust (the container does not know the lab
  root CA, [P30](#p30-mas-or-the-livekit-jwt-service-does-not-trust-the-lab-root-ca)) or
  an issuer that differs by a single character.
- **What the project does**: `matrix-prepare.yml` fetches Keycloak's discovery
  document from the matrix VM and compares the issuer before MDAD runs, and
  `Deploy-LabMatrix.ps1` finally checks that MAS really redirects to Keycloak,
  which MAS does only after it has loaded the discovery document. Look at the
  log with
  `.\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-authentication-service -n 50 --no-pager'`.

### P30. MAS or the LiveKit JWT service does not trust the lab root CA

- **Symptom**: TLS errors in the logs of `matrix-authentication-service`
  (towards Keycloak) or `matrix-livekit-jwt-service` (towards `lab.internal`
  and `matrix.lab.internal`), although the VM itself trusts the lab root CA.
- **Cause**: both images are minimal ("distroless" or built from scratch): no
  shell, no `update-ca-certificates`, only the public CA list compiled into the
  image. The VM's trust store does not reach into a container. And
  `update-ca-certificates` writes a **new** bundle file: a container that has the
  old file bind-mounted keeps seeing the old content, and both services read the
  bundle only when they start.
- **What the project does**: [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
  mounts the VM's `/etc/ssl/certs/ca-certificates.crt` (which contains the lab
  root, installed by `matrix-prepare.yml` before MDAD runs) read-only into both
  containers, and points MAS's TLS library at it with `SSL_CERT_FILE`. Whenever
  the bundle changes (for example when the 2026 root was added and the retired
  CA removed), the handler in `matrix-prepare.yml` restarts both services, if
  they are already running. Only after a change made outside the playbook,
  restart them yourself:
  `.\scripts\Connect-Lab.ps1 matrix 'sudo systemctl restart matrix-authentication-service matrix-livekit-jwt-service'`.
  Traefik gets the root file itself mounted, for OpenBao's ACME server
  (`caCertificates` in `vars.yml`). A new intermediate needs none of this: the
  containers trust the root, and every intermediate is signed by it.

### P31. MDAD cannot create Matrix users

- **Symptom**: MDAD's `register-user` recipe (in its `justfile`; the lab does
  not install `just`), or a user listed for MDAD's automatic user creation,
  fails.
- **Cause**: both create users with a password, and the lab switched local
  passwords off in MAS (`matrix_authentication_service_config_passwords_enabled: false`):
  Keycloak is the only way to sign in.
- **What the project does**: nothing creates Matrix users. A Matrix account is
  created on a user's first login through Keycloak; new users are added in
  Keycloak ([Add a Keycloak user](#add-a-keycloak-user)). Matrix admin rights
  come from MAS's policy (`admin_users`).

### P32. Signing in as bob logs in alice again

- **Symptom**: a second tab or window of the same browser profile already shows
  alice; or, after alice signed out of Element, "Sign in" goes straight
  through without a login form and you are alice again.
- **Cause**: one browser profile holds the sessions of one user. A second tab
  shares Element's own session (the browser storage of `element.lab.internal`).
  A sign-out in Element ends only the Matrix session: Keycloak's SSO session
  (and most likely MAS's browser session, see the sessions table in
  [Identity](#identity-idp-oidc-and-single-sign-on)) for alice is still valid,
  so the login confirms "this is alice" without asking. That is single sign-on working as designed. (After a sign-out in MAS,
  MAS asks Keycloak for the login form again, but only for a few minutes.)
- **What the project does**: nothing to fix. Use separate cookie jars for
  separate users: a second Edge profile, an InPrivate window, or another
  browser (see [Step 8](#step-8-sign-in-chat-and-make-a-call)).

### P33. The self-check shows a fatal 404 for /_matrix/federation/v1/version

- **Symptom**: during `Deploy-LabMatrix.ps1`, MDAD's self-check prints a
  `fatal` line with HTTP 404 for `/_matrix/federation/v1/version`, then
  `...ignoring`.
- **Cause**: federation is switched off, so that endpoint does not exist. MDAD
  knows that and marks the failed task as ignored.
- **What the project does**: nothing; the 404 is the expected answer. The
  script comments this, and the run continues.

### P34. `mas-cli doctor` reports problems, but the run succeeds

- **Symptom**: `mas-cli doctor` prints warnings or errors, yet
  `Deploy-LabMatrix.ps1` continues and succeeds.
- **Cause**: `mas-cli doctor` only reports; its exit code is always 0, so no
  script can tell from it whether something is wrong.
- **What the project does**: read its output, but rely on the two hard checks
  after it: Synapse's `auth_metadata` must name MAS as issuer, and MAS's
  upstream authorize URL must redirect to Keycloak. Either failing stops the
  script.

### P35. A call connects, but no audio or video flows

- **Symptom**: the call screen opens and shows the participants, but there is
  no picture or sound; `edge://webrtc-internals` shows no candidate pair in state
  `succeeded`, or LiveKit's candidates carry an address your PC cannot reach
  (for example your home router's public IP).
- **Cause**: LiveKit runs behind the firewall's port forward and must announce
  the address the browser can reach. By default it asks a public STUN server
  for its public IP. Also possible: the media ports are not forwarded, or they
  are forwarded to different port numbers (LiveKit announces its own ports).
- **What the project does**: `livekit_server_config_rtc_use_external_ip: false`
  and `livekit_server_config_rtc_node_ip: 10.10.99.3` in `vars.yml`; UDP 7882
  and TCP 7881 are published with unchanged port numbers in `config/lab.json`;
  TURN and HTTP/3 are off, so nothing announces ports that are not forwarded.
  Check from the PC: `Test-NetConnection 10.10.99.3 -Port 7881`, and look at
  `matrix-livekit-server`'s log.

### P36. OpenBao is sealed after the vault VM restarts

- **Symptom**: OpenBao's web UI (<https://vault.lab.internal:8200/ui/>) asks for
  unseal keys; `curl.exe -s https://vault.lab.internal:8200/v1/sys/health`
  reports `"sealed":true`; `Show-LabSecret.ps1` or `Backup-LabVault.ps1` stop
  with `(HTTP 503)`; Traefik cannot get or renew certificates
  ([P44](#p44-traefik-serves-traefik-default-cert)); once Windows' cached copy
  of the intermediate's CRL has expired (after 7 days at most), `curl.exe`
  reports revocation errors ([P19](#p19-curlexe-fails-with-a-revocation-error)).
- **Cause**: OpenBao stores all its data encrypted and holds the key for it
  only in memory. After every start of the service (VM boot,
  `systemctl restart openbao`, a package upgrade) it is "sealed": it needs 2 of
  the 3 key shares to rebuild the key that unlocks its data (Shamir's secret
  sharing). The lab has no auto-unseal ([section 10](#10-security-notes)).
- **What the project does**: `Initialize-Lab.ps1` unseals OpenBao right after
  it has started the firewall and the vault VM, before any SSH, because OpenBao
  signs the SSH certificates (once step 8 of `Deploy-LabVault.ps1` has made every
  machine trust its SSH CA; until then it unseals an initialised OpenBao only after
  the VMs are up),
  `Invoke-LabPlaybook.ps1` before
  every playbook that needs OpenBao, the renewal of the PC's SSH certificate
  when it finds OpenBao sealed, and `Deploy-LabVault.ps1` in its step 5.
  `Show-LabSecret.ps1`,
  `Backup-LabVault.ps1` and Traefik do not unseal. After any other restart of
  the vault VM, run `.\scripts\Unlock-LabVault.ps1`: it sends the two shares
  stored with DPAPI and needs no input; on an unsealed OpenBao it does nothing.
  `openbao.yml` applies configuration changes with a reload (SIGHUP), which does
  not seal, and so do the audit log rotation and `Deploy-LabVault.ps1` after it
  has installed a new TLS certificate. If OpenBao does not answer at all,
  `Invoke-LabPlaybook.ps1` stops with "OpenBao (...) is not reachable; ... Is the
  vault VM running, and has OpenBao been deployed (.\scripts\Deploy-LabVault.ps1)?":
  start the VMs with `.\scripts\Initialize-Lab.ps1`, or deploy OpenBao first.
  An expired TLS certificate of OpenBao looks like no answer to the PC's pinned
  check; the scripts that wait for OpenBao then say so ("OpenBao's TLS
  certificate expired on ... Renew it with .\scripts\Deploy-LabVault.ps1."), and
  `Initialize-Lab.ps1` runs `Deploy-LabVault.ps1` by itself instead of only
  unsealing when the certificate is due or expired.
  After a lost Windows profile (the DPAPI files cannot be decrypted any more),
  `.\scripts\Unlock-LabVault.ps1 -Interactive` unseals with share B from the
  recovery file (`.\scripts\New-LabRecoveryKit.ps1 -Open <file>`) and share C
  from your copy; to get the PC's access back as well, use
  `.\scripts\New-LabRecoveryKit.ps1 -Recover <file>`
  ([P46](#p46-after-losing-the-pcs-dpapi-keys-nothing-logs-in-to-openbao)).

### P37. "cannot write to readonly storage" right after unsealing

- **Symptom**: right after an unseal, the first writes to OpenBao fail with
  `cannot write to readonly storage`; a few seconds later the same request
  works.
- **Cause**: OpenBao's integrated storage (raft) is built for clusters. Even a
  single node must first win a leader election after it was unsealed; until
  then it is a read-only "standby" (`sys/health` reports `"standby":true`).
- **What the project does**: `Unlock-LabVault` in `LabSecrets.ps1` (used by
  `Unlock-LabVault.ps1` and every script that unseals) waits with
  `Wait-LabVaultActive` until OpenBao reports itself unsealed and not standby,
  for up to 60 seconds, also when it was already unsealed;
  `New-LabRecoveryKit.ps1 -Recover` does the same after its unseal. If you call
  the API yourself right after an unseal, wait for the same state.

### P38. OpenBao's API answers 405 or 404 for a path that exists

- **Symptom**: `GET .../v1/pki_int/issuers` answers `405` (unsupported
  operation); a read of `lab/keycloak/db` answers `404` (with an admin token) or
  `403` (with a token whose policy names `lab/data/...`), although
  `Show-LabSecret.ps1 keycloak/db` finds the secret.
- **Cause**: two details of the HTTP API. Listing is an operation of its own
  (`LIST`): over HTTP it is either the method `LIST` or a `GET` with
  `?list=true`, and an endpoint that can only list refuses a plain `GET`. And
  the KV engine version 2 keeps a secret's value under `<mount>/data/<path>` and
  its metadata and version list (also the listing of names) under
  `<mount>/metadata/<path>`; the short form `lab/keycloak/db` is only what the
  `bao` command line shows. Policies must name the full paths too.
- **What the project does**: every list call carries `?list=true`
  (`Deploy-LabVault.ps1`, `Show-LabSecret.ps1`, `Remove-LabAppRoleSecretIds` in
  `LabSecrets.ps1`), KV calls use `lab/data/...` and `lab/metadata/...`, and the
  policies in `Deploy-LabVault.ps1` grant on `lab/data/keycloak/*` and
  `lab/metadata/keycloak/*`. `Show-LabSecret.ps1` takes the short form and adds
  the prefixes itself.

### P39. `Deploy-LabVault.ps1` refuses to initialise a new OpenBao

- **Symptom**: `Deploy-LabVault.ps1` stops in step 4 with "keys\openbao holds key
  shares of an earlier OpenBao. They are not overwritten ..."; before that,
  `Initialize-Lab.ps1` may already stop after three minutes with "OpenBao
  (https://vault.lab.internal:8200) does not answer after 180 s." (it tries to
  unseal because it finds the old key shares). Once OpenBao signed the SSH
  certificates, the scripts stop even earlier, at the first SSH certificate they
  need ("OpenBao (10.10.99.5:8200) does not answer ..."): the PC still expects the
  deleted OpenBao to sign.
- **Cause**: the vault VM was rebuilt, so OpenBao is new and uninitialised, but
  `keys\openbao` still holds the key shares, logins and snapshots of the old
  installation. Those shares fit only the old one, and they are the only way to
  restore its snapshots, so the script never overwrites them.
  `Remove-Lab.ps1` takes a last snapshot and moves the folder aside when it
  deletes the vault VM, together with the old OpenBao's SSH CA
  (`keys\ssh\openbao-ca.pub` and `openbao-ca.trusted`); a VM deleted another way
  (`vagrant destroy vault`, Hyper-V Manager) leaves them in place.
- **What to do**: move them aside yourself (without the SSH CA files the offline
  SSH CA signs again until step 8 of `Deploy-LabVault.ps1` makes the new OpenBao's
  CA trusted), let `Initialize-Lab.ps1` certify the rebuilt VM, then run the
  script again:

  ```powershell
  $retired = "keys\openbao-retired-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Move-Item keys\openbao $retired
  New-Item -ItemType Directory "$retired\ssh" | Out-Null
  Move-Item keys\ssh\openbao-ca.pub, keys\ssh\openbao-ca.trusted "$retired\ssh\" -ErrorAction SilentlyContinue
  .\scripts\Initialize-Lab.ps1
  .\scripts\Deploy-LabVault.ps1
  ```

  Use exactly that name pattern: DPAPI binds each file to its name, and
  `Unprotect-LabSecret` (`LabSecrets.ps1`) maps a name under
  `openbao-retired-<yyyyMMdd-HHmmss>/` back to the original one, so the old
  files stay readable where they are, for example the old share A:
  `.\scripts\Show-LabSecret.ps1 -Pc openbao-retired-<date-time>/unseal-a -Show`.
  The root CA stays (`keys\pki`), so the new intermediate is signed by the same
  root and Windows keeps trusting the lab. The new OpenBao is empty: Keycloak
  and Matrix with their old data then need the old secrets
  ([P41](#p41-a-deployment-refuses-to-generate-a-missing-secret)).

### P40. A playbook run without the PC has no OpenBao token

- **Symptom**: `ansible-playbook playbooks/keycloak.yml`, started by hand on
  ansible-control, stops at "OpenBao run token present" with "No OpenBao token
  in the environment"; MDAD's own playbook started by hand in `~/mdad`
  (`ansible-playbook -i inventory/hosts setup.yml ...`, what MDAD's `just`
  recipes would run) stops with
  `'vault_matrix_homeserver_generic_secret_key' is undefined` (or another
  `vault_*` variable) as soon as a task uses it.
- **Cause**: ansible-control holds no OpenBao credential of its own, by design:
  nothing on its disk opens OpenBao. A token exists only for one run: the PC
  mints it (AppRole `pc-deploy`, accepted only from the PC's address) and hands
  it to `ansible/bin/openbao-run`. MDAD's `setup.yml` on its own runs without
  the lab's entry point `lab-setup.yml`, which is where the Matrix secrets come
  in.
- **What to do**: start playbooks from the PC: `.\scripts\Invoke-LabPlaybook.ps1
  <playbook>` or the `Deploy-*.ps1` scripts. A single MDAD tag runs with a run
  token like this, from the project root (OpenBao unsealed, `~/lab` present
  from an earlier `Invoke-LabPlaybook.ps1` run and `~/mdad` from an earlier
  `Deploy-LabMatrix.ps1` run):

  ```powershell
  . .\scripts\LabSecrets.ps1
  Invoke-LabRunToken 'cd ~/mdad && ansible-playbook -i inventory/hosts lab-setup.yml --tags=self-check' @('ansible-matrix') 'mdad' @('host-matrix')
  ```

  The fourth argument is the SSH principals of the run's certificate
  (`host-matrix`: matrix only); without it, ansible-control gets no certificate
  and can reach no other machine. A new playbook that needs OpenBao needs an
  entry in `$openBaoPolicies` in `Invoke-LabPlaybook.ps1`, and its policy in
  `Deploy-LabVault.ps1` (also in the token role's `allowed_policies`); then run
  `.\scripts\Deploy-LabVault.ps1`. Its SSH principals go into `$sshPrincipals`
  in the same script.

### P41. A deployment refuses to generate a missing secret

- **Symptom**: `Deploy-LabKeycloak.ps1` or `Deploy-LabMatrix.ps1` stops with
  "Not in OpenBao: ... The service already has data that was set up with the old
  values, so new values are NOT generated", or with "... belongs to another part
  of the lab and is created there"; or with "Missing after reading OpenBao:
  lab/<path> (field <field>)".
- **Cause**: the playbooks create a missing secret only for a **new**
  installation. Keycloak's database volume (`keycloak_pgdata`) or MDAD's
  `/matrix/postgres` already exists, so the service was set up with values a
  newly generated secret would not match: Keycloak could not open its database,
  and MDAD derives Synapse's and MAS's keys from its generic secret key. This
  happens when OpenBao was rebuilt (empty) while the Keycloak or matrix VM kept
  its data. The second message means the order was wrong: the client secret for
  MAS belongs to Keycloak and is created by `Deploy-LabKeycloak.ps1`, which must
  run before `Deploy-LabMatrix.ps1`. The third means that the secret exists,
  but without the field the playbook reads: it was probably written by hand
  under another field name.
- **What to do**: restore OpenBao from a snapshot taken before. One exists from
  the first deployment on: `Deploy-LabKeycloak.ps1` and `Deploy-LabMatrix.ps1`
  take one after every run, also after a failed one, and `Remove-Lab.ps1` takes
  one before it deletes the vault VM. After such a deletion the snapshots and
  the key shares of their time are in `keys\openbao-retired-<date-time>`; see
  [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot). If the
  data does not matter, rebuild that VM instead (`.\scripts\Remove-Lab.ps1
  keycloak`, `.\scripts\Initialize-Lab.ps1`, then its `Deploy-*.ps1` script):
  it starts empty and gets new secrets. For a wrong field name, write the value
  under the expected field
  ([Write or change a secret](#write-or-change-a-secret-administrator)). The
  playbooks never guess or overwrite here, on purpose.

### P42. The run token is echoed, or arrives damaged

- **Symptom**: `openbao-run: unwrapping the run token failed (expired, already
  used, or OpenBao sealed?)`, although the PC has just created the token; or,
  with a pseudo-terminal, the token would appear in the console output and in
  every log of it.
- **Cause**: three properties of the handover. A pseudo-terminal (`ssh -t`)
  echoes whatever arrives on stdin. Windows PowerShell 5.1 adds CRLF, and
  possibly a byte order mark, to text it pipes into `ssh`
  ([P11](#p11-windows-powershell-51-quirks)). And the wrapping token can be
  used once, within 120 seconds; the error also appears when OpenBao is sealed
  or the SSH connection took too long.
- **What the project does**: `Invoke-LabRunToken` (`LabSecrets.ps1`) pipes the
  wrapping token into `ssh` on stdin, never on a command line, and without `-t`;
  Ansible's colours are switched on with `ANSIBLE_FORCE_COLOR=1` instead (only
  when the output is not redirected and the console can show colours, see
  [P50](#p50-ansibles-colours-appear-as-text-such-as-036m)). `openbao-run` keeps only the characters a
  token can contain, passes tokens to `curl` on stdin (`-H @-`) because command
  lines are visible to every user of a machine (`ps`, `/proc`), and when the
  command ends, also after a failure, revokes the real token and removes
  Ansible's temporary folder in RAM. The remote command is put in single quotes,
  so it must not contain quotes itself (`Invoke-LabRunToken` refuses it).

### P43. A colon in a Jinja expression breaks the YAML

- **Symptom**: a playbook does not even start; Ansible reports a YAML syntax
  error such as `mapping values are not allowed here`, pointing at a message
  like `fail_msg: ... (HTTP {{ r.status }}{{ (': ' ~ ...) }})`.
- **Cause**: in a plain (unquoted) YAML value, a colon followed by a space
  starts a key-value pair. YAML is parsed before Jinja runs, so a `': '` inside
  `{{ ... }}` counts too.
- **What the project does**: such messages are folded block scalars (`>-`), in
  which `: ` is ordinary text; `>-` joins the lines with spaces and drops the
  final line break (see the checks in `tasks/openbao-secrets.yml` and
  `tasks/openbao-certificate.yml`).

### P44. Traefik serves "TRAEFIK DEFAULT CERT"

- **Symptom**: the browser warns on <https://element.lab.internal> about a
  self-signed certificate named `TRAEFIK DEFAULT CERT`; `Deploy-LabMatrix.ps1`
  stops with "Traefik does not serve a certificate from OpenBao for ...
  (issuer: '...')". If the issuer in that message is a lab intermediate, it is an
  older one: Traefik still serves a certificate from before a rotation or a
  rebuilt vault VM.
- **Cause**: Traefik answers with its own built-in certificate until the ACME
  order for a name has succeeded. An order fails when OpenBao is sealed or not
  reachable ([P36](#p36-openbao-is-sealed-after-the-vault-vm-restarts)), when
  Traefik does not trust the lab root (then it cannot talk to the ACME
  directory), when OpenBao cannot fetch the challenge from
  `http://<name>/.well-known/acme-challenge/...` (it asks from the vault VM, so
  the lab DNS must give the matrix VM's address 10.10.10.30, port 80), or when
  the name is not in the role `acme-matrix`. A certificate of an older
  intermediate would otherwise stay until its regular renewal, and a rebuilt
  OpenBao does not even know Traefik's ACME account any more.
- **What the project does**: `matrix-prepare.yml` checks the names' DNS and the
  ACME directory from the matrix VM before MDAD runs. It also compares the
  certificate Traefik serves with OpenBao's current intermediate: when it comes
  from an older lab intermediate (its authority key identifier is not the
  current CA's subject key identifier), it deletes
  `/matrix/traefik/ssl/acme.json` and restarts `matrix-traefik`, so Traefik
  registers again and orders new certificates. `Deploy-LabMatrix.ps1` waits up
  to 3 minutes per name until Traefik serves a certificate whose authority key
  identifier matches the current intermediate (a name alone could match an
  older one). Look at Traefik's log with
  `.\scripts\Connect-Lab.ps1 matrix 'sudo journalctl -u matrix-traefik -n 80'`,
  and at the DNS answer the vault VM gets with
  `.\scripts\Connect-Lab.ps1 vault 'getent ahostsv4 matrix.lab.internal'`.

### P45. A script that shows secrets stops before it shows anything

- **Symptom**: `New-LabRecoveryKit.ps1`, `Show-LabSecret.ps1 -Show` or
  `Unlock-LabVault.ps1 -Interactive` stops with "... shows secrets on the screen.
  Run it yourself in a PowerShell window, not through another program or with
  redirected output."; or `New-LabRecoveryKit.ps1 -Destination E:\` stops with
  "The drive E:\ does not exist (USB stick not plugged in?)" or "Cannot write to
  E:\... (...). Nothing was changed."; or it reports "Key share C is no longer on
  this PC (the kit was made already)"; or "Could not make the break-glass login
  (AppRole 'recovery'); run .\scripts\Deploy-LabVault.ps1 once first."
- **Cause**: output that is redirected or captured by another program (a log
  file, a tool, an assistant) could store secrets in plain text, so these scripts
  run only in a real console window. `-Destination` names a drive that does not
  exist, or a folder that cannot be written (a write-protected stick, a
  read-only share); the script checks both before it shows anything.
  Share C is deleted from the PC once you have confirmed that you stored it, so
  the default mode (which shows it) works only once. The break-glass AppRole is
  created by `Deploy-LabVault.ps1`; a lab deployed with an earlier version does
  not have it yet.
- **What to do**: open a PowerShell window yourself, go to the project root and
  run the script there. For the recovery kit, plug in the stick, or choose
  another folder (`.\scripts\New-LabRecoveryKit.ps1 -Destination Z:\DeployableServer-recovery`
  for a NAS share; a relative path is taken from the current PowerShell
  folder), or leave out `-Destination`: the file then goes to `keys\recovery`,
  and you copy it off the PC yourself. After these drive and folder errors
  nothing was shown or changed, and share C still waits. A kit that exists is
  opened with `.\scripts\New-LabRecoveryKit.ps1 -Open <file>`; a new recovery
  file (with a new break-glass secret; your copy of share C stays valid and is
  not shown again) is made with `.\scripts\New-LabRecoveryKit.ps1 -Renew`. For
  the break-glass login, run `.\scripts\Deploy-LabVault.ps1` first. That error
  comes later than the others: in the default mode only after share C was shown
  and the passphrase entered (with `-Renew`, after the passphrase). Nothing was
  changed, share C still waits on the PC, and the script shows it again once
  `Deploy-LabVault.ps1` has created the AppRole.

### P46. After losing the PC's DPAPI keys, nothing logs in to OpenBao

- **Symptom**: after a new Windows installation, a lost profile or a password
  reset by an administrator, every script that reads a `.dpapi` file fails to
  decrypt it (`Unlock-LabVault.ps1`, `Show-LabSecret.ps1`, the deployments;
  a firewall build stops with "keys\opnsense\root-password.dpapi cannot be
  decrypted by this Windows account. Restore it with
  .\scripts\New-LabRecoveryKit.ps1 -Recover <file> ...");
  the key shares on paper and in the recovery file still unseal OpenBao, but
  `bao operator generate-root` on the vault VM, the classic way to make a new
  root token from key shares, is refused without a token.
- **Cause**: DPAPI files can only be decrypted by the Windows account (and its
  keys) that wrote them. The bootstrap root token was revoked at the end of
  `Deploy-LabVault.ps1`. And since OpenBao 2.5.3 the unauthenticated endpoints
  `sys/generate-root/*`, which built a new root token from a quorum of key
  shares alone, are switched off by default (listener setting
  `disable_unauthed_generate_root_endpoints`): anyone who reached the API could
  start or cancel such an attempt. Their replacement, which
  `bao operator generate-root` uses since OpenBao 2.6, needs a token itself. Key
  shares now unseal OpenBao, but they log nobody in.
- **What the project does**: a break-glass login of its own: the AppRole
  `recovery` (`Deploy-LabVault.ps1`; policy `openbao-admin`, accepted only from
  the PC's address), whose secret ID exists only in the passphrase-encrypted
  recovery file. `New-LabRecoveryKit.ps1` makes a new one for every file and
  destroys the older ones. To get back in, run in your own PowerShell window
  (after a new Windows installation the VMs must first be registered in Hyper-V
  again, which this README does not cover, see
  [Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys);
  then run `.\scripts\Install-LabHostNetwork.ps1`, because the login works only
  from 10.10.99.1):

  ```powershell
  .\scripts\New-LabRecoveryKit.ps1 -Recover <file>   # asks for the passphrase and share C
  .\scripts\New-LabRecoveryKit.ps1 -Renew            # then a new file and a new break-glass secret
  ```

  `-Recover` restores the PC's DPAPI secrets, unseals OpenBao with B and C if
  needed and issues new logins for `pc-admin` and `pc-deploy`, step by step in
  [Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys).
  Afterwards everything works as before.
  The break-glass secret you just used stays valid until `-Renew` replaces it;
  from then on older recovery files can still unseal, but their break-glass
  login no longer works. A recovery file made before the firewall's `ansible`
  password and API key were included restores only the root password, with a
  warning: no script uses the other two on a running firewall, and the next
  firewall build (`.\scripts\New-LabFirewall.ps1 -Rebuild`) makes new ones when
  the old ones cannot be decrypted. A recovery file made before the break-glass
  login existed stops `-Recover` with "This recovery file has no break-glass
  login (made before it existed)": it can still unseal
  (`.\scripts\Unlock-LabVault.ps1 -Interactive`), but not log in. Replace such a
  file with `-Renew` while the PC's DPAPI keys still work
  (`Deploy-LabVault.ps1` reminds you with a `PENDING` line).

### P47. `Remove-Lab.ps1 vault` stops without deleting anything

- **Symptom**: `.\scripts\Remove-Lab.ps1 vault` stops with "No OpenBao snapshot
  possible (...), and keys\openbao\snapshots has none, while keycloak and matrix
  keep data that depends on its secrets. Start the vault VM and unseal OpenBao
  (.\scripts\Initialize-Lab.ps1), then try again; nothing was deleted."
- **Cause**: before it deletes the vault VM, `Remove-Lab.ps1` takes a fresh
  snapshot (`Backup-LabVault.ps1`), because OpenBao holds the only copy of the
  secrets that Keycloak's and Matrix's data were set up with. A sealed or
  unreachable OpenBao gives no snapshot. If an earlier snapshot exists in
  `keys\openbao\snapshots` (every deployment takes one), the script only warns
  ("No fresh OpenBao snapshot (...); the newest kept one is ...") and goes on,
  and so it does when the whole lab is deleted (`Remove-Lab.ps1` without a VM
  name). With no snapshot at all while keycloak or matrix stay, deleting the VM
  could leave them with data that nothing can open any more.
- **What to do**: start the vault VM and unseal OpenBao
  (`.\scripts\Initialize-Lab.ps1`, or `.\scripts\Unlock-LabVault.ps1` when the VM
  is running) and run it again. If OpenBao cannot be brought up any more and no
  copy of a snapshot exists elsewhere either (one made with
  `Backup-LabVault.ps1 -Destination`), its secrets are lost, and Keycloak and
  Matrix have to start over too
  ([Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)). To
  remove the broken VM, delete it yourself in Hyper-V Manager, on purpose, and
  run `.\scripts\Remove-Lab.ps1 vault` again: with the VM gone it takes no
  snapshot, removes Vagrant's leftovers and moves `keys\openbao` aside. With a
  snapshot copy, follow
  [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).

### P48. Ansible warns that it created `/root/.ansible/tmp`

- **Symptom**: `[WARNING]: Module remote_tmp /root/.ansible/tmp did not exist and
  was created with a mode of 0700, this may cause issues when running as another
  user. ...`, once per VM (ansible-control included): on the first run against
  a new VM, or the first run with pipelining switched on.
- **Cause**: pipelining (`pipelining = True` in `ansible/ansible.cfg`): Ansible
  hands each module to the target's Python on stdin instead of copying it into a
  temporary folder first, so nothing has created the temporary folder of the
  `become` user (root) before the first module runs. The module creates it
  itself, private to root, and reports that.
- **What the project does**: nothing; the warning is harmless and does not come
  back once the folder exists. Pipelining stays on because module arguments,
  which can carry the run token and secret values, then never land in a file
  (see `ansible/ansible.cfg` and `ansible/bin/openbao-run`).

### P49. `--check` reports the lab users as changed

- **Symptom**: `.\scripts\Invoke-LabPlaybook.ps1 keycloak.yml --check` reports
  `changed` for both items of the task "Lab users" (`censored due to no_log`),
  although a real run right afterwards reports `ok`.
- **Cause**: in check mode, modules only predict what they would do.
  `keycloak_user` cannot compare a password there (Keycloak never returns
  one), so it reports the users as changed; a real run compares only the other
  attributes and reports `ok`.
- **What the project does**: nothing; read the `--check` result of
  `keycloak.yml` with that in mind. Otherwise `--check` works for the playbooks
  that use OpenBao: the tasks that only read (the secrets, OpenBao's CA
  certificate, the certificate Traefik serves) run anyway (`check_mode: false`),
  and nothing is written to OpenBao, no secret is created and no certificate is
  renewed.

### P50. Ansible's colours appear as text such as `[0;36m`

- **Symptom**: the output of a deployment (`Deploy-LabKeycloak.ps1`,
  `Deploy-LabMatrix.ps1`, or `Invoke-LabPlaybook.ps1` with a playbook that gets
  a run token) is full of fragments such as `[0;32mok: [matrix.lab.internal][0m`
  or `[0;36m`, instead of green and cyan text.
- **Cause**: Ansible colours its output with ANSI escape sequences: the
  invisible character ESC, then for example `[0;32m` for green and `[0m` to
  go back to normal. A run with a run token uses `ssh` without a
  pseudo-terminal (no `-t`, so that the token on stdin is not echoed, see
  [P42](#p42-the-run-token-is-echoed-or-arrives-damaged)), and then Windows'
  `ssh.exe` passes these bytes through unchanged. The classic Windows console
  (the window Windows PowerShell 5.1 runs in) interprets them only when its
  "virtual terminal processing" mode is on, and a program has to ask for that
  mode; otherwise the console prints the sequences as text. Playbooks without
  a run token are not affected: `Invoke-LabPlaybook.ps1` runs them with
  `ssh -t`, and in a terminal session `ssh` prepares the console itself.
- **What the project does**: `Invoke-LabRunToken`
  ([LabSecrets.ps1](scripts/LabSecrets.ps1)) first calls
  `Enable-LabConsoleColors`, which switches virtual terminal processing on for
  the current console window (the Windows function `SetConsoleMode` with the
  flag `ENABLE_VIRTUAL_TERMINAL_PROCESSING`, Windows 10 and later), and sets
  `ANSIBLE_FORCE_COLOR=1` for the run only when that worked. When the output is
  redirected to a file, or the console refuses, no colours are requested, so a
  log file stays plain text.

### P51. Copying or unpacking `vendor\mdad` fails in a deep project folder

- **Symptom**: a program that copies, packs or unpacks the project reports
  that a path is too long or cannot be found, for a file deep in
  `vendor\mdad\roles\...`: Explorer, a ZIP tool or a Git checkout, or `tar` in
  `Update-LabMdad.ps1` ("Unpacking the roles failed") or in step 2 of
  `Deploy-LabMatrix.ps1` ("tar failed").
- **Cause**: many Windows programs still accept paths of at most 260
  characters (`MAX_PATH`), drive letter, folders and file name together. The
  longest path inside `vendor\mdad` is about 140 characters
  (`roles\custom\matrix-synapse\templates\synapse\ext\s3-storage-provider\systemd\...`).
  With the project at `C:\Users\<name>\Documents\Python\DeployableServer`
  (about 50 characters with a short user name) the longest full path is about
  200 characters: well below the limit. A
  project folder whose own path is longer than about 100 characters can cross
  it.
- **What to do**: keep the project in a short folder, such as
  `C:\Users\<name>\Documents\Python\DeployableServer` or
  `C:\Lab\DeployableServer`. The vendored files keep the names upstream gave
  them, on purpose: `vendor\mdad` is an unchanged copy.

### P52. MDAD stops at "Get local git hash" in its vendored copy

- **Symptom**: MDAD's run stops at the task "Get local git hash" (role
  `playbook_state_preserver`) with `fatal: not a git repository`, followed by
  "Error when trying to get the git hash".
- **Cause**: MDAD records which version of itself configured a server: it runs
  `git describe` in its own folder on ansible-control and writes the answer to
  `/matrix/git_hash.yml` on the matrix VM. That works in a clone of MDAD's own
  repository. The lab's `~/mdad` is a copy of `vendor\mdad` (a subtree inside
  this project's repository, copied without any `.git`), so `git describe`
  fails there, and MDAD stops instead of guessing.
- **What the project does**:
  [vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
  sets `devture_playbook_state_preserver_commit_hash_preservation_enabled: false`.
  The version is known anyway, from the repository: `mdad_version` in
  `matrix-prepare.yml` and `vendor\mdad\.lab-vendored-commit`. The other half
  of the same role stays on: MDAD still keeps a copy of `vars.yml` on the
  server (`/matrix/vars.yml`), which shows how a server was configured.

### P53. SSH: "Host key verification failed" or "Permission denied (publickey)"

- **Symptom**: `Connect-Lab.ps1`, a deployment, `Initialize-Lab.ps1` or a
  `vagrant` command stops with `Host key verification failed.` or
  `Permission denied (publickey)`, or with the lab's own message `... Start and
  unseal OpenBao with .\scripts\Initialize-Lab.ps1, or let the offline CA sign
  (break-glass) ...`; the Vagrantfile stops with `The PC's SSH certificate could
  not be renewed (see above)`.
- **Causes and what to do** (how the certificates work:
  [SSH certificates](#ssh-certificates-user-and-host-cas)):
  - **The PC's certificate has expired, and OpenBao cannot sign a new one.** It
    is valid for 8 hours, so after a Windows restart it has always expired, and
    the vault VM is off then. The scripts do not fall back to the offline SSH CA
    by themselves. Run `.\scripts\Initialize-Lab.ps1`: it starts the firewall
    and the vault VM in Hyper-V and unseals OpenBao before any SSH. If OpenBao
    stays broken, let the offline SSH CA sign, on purpose: `-BreakGlass` on
    `Update-LabSshCertificate.ps1` or `Connect-Lab.ps1` (the PC's certificate),
    `Initialize-Lab.ps1` or `New-LabFirewall.ps1` (host certificates too), or
    `$env:LAB_SSH_BREAKGLASS = '1'` for every command in this window, `vagrant`
    included (`Remove-Item Env:LAB_SSH_BREAKGLASS` ends it). A break-glass
    certificate lasts as long as a normal one; once OpenBao works again, the
    next renewal comes from it. `.\scripts\Update-LabSshCertificate.ps1` shows
    which CA signed the current certificate and until when. The message
    `OpenBao serves another SSH CA than the one the machines trust` means a
    restored snapshot: see
    [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot), step 3.
  - **The machine has no valid host certificate**: a VM created or rebuilt by
    `vagrant` alone, a host certificate that expired (the PC renews them 30 days
    ahead, but only when `Initialize-Lab.ps1` or `New-LabFirewall.ps1` runs), or
    one from a CA the PC no longer trusts. The PC accepts host keys only with a
    certificate (`HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com`,
    `StrictHostKeyChecking yes`), so ssh answers `Host key verification failed.`
    Run `.\scripts\Initialize-Lab.ps1` (elevated: it reads the VM's host key from
    Hyper-V) or, for the firewall, `.\scripts\New-LabFirewall.ps1`; both install
    the certificate over a connection pinned to the verified key, which works
    whatever certificate the machine has. If ssh reports the host key as
    **revoked**, the machine presents a key that was retired (a restored
    checkpoint, an old disk): that is the revocation list doing its job, and the
    way out is a rebuild.
  - **Another ssh than Windows' own.** Vagrant puts an OpenSSH of its own (an
    MSYS2 build) first in `PATH` for the programs it starts, and Git for Windows
    brings one too. The lab is built and tested with Windows' client: the
    Vagrantfile names `C:\Windows\System32\OpenSSH\ssh.exe` in its proxy
    command, and the scripts call `ssh-keygen` and `ssh-keyscan` from that
    folder by their full path.
    If ssh by hand behaves differently from `Connect-Lab.ps1`, check which one
    runs: `(Get-Command ssh).Source`.
  - **`Permission denied (publickey)` in a playbook run**: the run's certificate
    lacks the principal for that host (a playbook that touches a machine it is
    not listed for in `$sshPrincipals` in `Invoke-LabPlaybook.ps1`), or SSH comes
    from an address the certificate and the server do not allow (a VM-to-VM
    login other than from ansible-control, or the PC's certificate used from
    ansible-control).
- **What the project does**: it fails closed and says why. Every script renews
  the PC's certificate when fewer than 4 hours are left, so a certificate never
  expires in the middle of a run, and an OpenBao that is down, sealed or not
  genuine never moves signing to the offline CA without a `-BreakGlass` from
  you.

### Other design decisions you will meet in the code

- The box `gusztavvargadr/ubuntu-server-2404-lts` is used because
  `bento/ubuntu-24.04` has no Hyper-V image. For OPNsense there is no Hyper-V box
  at all, hence `New-LabFirewall.ps1`.
- The default `/vagrant` synced folder is disabled because SMB on Hyper-V would
  ask for Windows credentials. Files reach the VMs through Vagrant file
  provisioners and `Invoke-LabPlaybook.ps1` (tar + scp).
- After a rebuild, VMs have new SSH host keys (each Ubuntu VM generates its own,
  see [P16](#p16-the-ubuntu-vms-all-have-the-same-ssh-host-keys-and-vagrantvagrant-works-over-ssh)).
  Nobody has to learn them: the PC verifies each new key out of band (serial
  console, Hyper-V KVP), signs a host certificate for it and revokes the old
  key, and every client trusts the CA, not the key
  ([SSH certificates](#ssh-certificates-user-and-host-cas)). So host key
  checking stays on everywhere, for MDAD too.
- Two SSH CAs instead of one: OpenBao signs every day and records it in its
  audit log, but OpenBao runs on a VM that is reached over SSH; the offline SSH
  CA on the PC is the way in that does not depend on it (the bootstrap,
  OpenBao's expired TLS certificate, and break-glass on request). The scripts
  never switch to it silently when OpenBao fails.
- The firewall uses OPNsense's dnsmasq for both DHCP and DNS; Unbound, its
  other DNS server, stays off: one DNS server is simpler to follow.
- WAN has no "block private networks" setting, because the Default Switch
  itself uses private addresses; nothing is allowed in on WAN anyway.
- The rendered `config.xml` is written with LF line endings and without a BOM,
  as OPNsense writes it itself.
- `.gitattributes` keeps every text file on LF line endings. With CRLF (the
  Git for Windows default on checkout) the shell scripts and the dnsmasq drop-in
  would break on the Linux VMs and the FreeBSD firewall.
- Colours: the zsh prompt, zsh-syntax-highlighting, Ansible's `verbose` colour
  and MDAD's runs (`ANSIBLE_COLOR_VERBOSE=magenta`) avoid blue, which is
  unreadable on the blue background of Windows PowerShell.
- Generated passwords contain only letters and digits (OpenBao's password
  policies `lab-alnum-24`, `lab-alnum-48` and `lab-alnum-64` from
  `Deploy-LabVault.ps1`, and the PC's own generators): Docker Compose would
  interpret a `$` in its environment files, and plain values are safe in every
  shell, YAML file and URL.
- MAS's encryption key is not a separate secret: it is derived from MDAD's
  generic secret key (`vars.yml`), so there is one fewer value in OpenBao, and
  like that key it must never change.
- Element shows no integration manager, room directory of matrix.org or bug
  report link: those defaults point to public services the lab cannot and should
  not reach. No mail relay either: there is nothing to deliver mail to.
- OpenBao, not HashiCorp Vault: OpenBao is the open-source fork of Vault (MPL
  2.0, under the Linux Foundation), made after Vault moved to the Business
  Source License in 2023. API, policies and concepts are Vault's, so what you
  learn here carries over.
- OpenBao's own TLS certificate and the firewall's GUI certificate are signed by
  the offline root, not by OpenBao's intermediate: both must work before OpenBao
  exists or while it is sealed, and a certificate OpenBao issued to itself could,
  once expired, only be renewed through the server it protects.
- Ansible talks to OpenBao's HTTP API with `ansible.builtin.uri`, not with the
  `community.hashi_vault` collection: no extra Python library (`hvac`) on
  ansible-control, and every request is visible in `tasks/openbao-secrets.yml`
  and `tasks/openbao-certificate.yml`.
- The vault VM has Hyper-V checkpoints disabled and keeps the normal login
  prompt on its console (`"checkpoints": false`, `"consoleAutologin": false` in
  `config/lab.json`): a checkpoint can save the running VM's memory, with the
  unsealed OpenBao's keys in it, unencrypted to `G:`, and an autologin console
  would be a root shell on the unsealed server for anyone who opens it.
- The way back into OpenBao after a lost Windows profile is a break-glass
  AppRole (`recovery`) whose secret exists only in the recovery file, not a root
  token generated from key shares: OpenBao switched the unauthenticated
  generate-root endpoints off by default in 2.5.3, and the lab leaves them off
  ([P46](#p46-after-losing-the-pcs-dpapi-keys-nothing-logs-in-to-openbao)).
  Whenever a login of an AppRole is issued again (`New-LabAppRoleSecret` in
  `LabSecrets.ps1`), all its older secret IDs are destroyed
  (`Remove-LabAppRoleSecretIds`), so only the newest one works; that happens
  only after the new one is stored, so a failed write never leaves a role
  without a working login.
- The intermediate CA rotates, the root does not. `Deploy-LabVault.ps1` makes a
  new intermediate when the current one expires within 400 days (longer than
  the longest certificate it issues, Keycloak's year) or with
  `-RotateIntermediate`. Key and issuer names in OpenBao must be unique, so a
  rotation names them by date and time (`lab-int-<yyyyMMdd-HHmmss>`, common
  name "DeployableServer Lab Intermediate CA <yyyy-MM-dd>"); the first
  intermediate of an empty OpenBao gets
  the year (`lab-int-<yyyy>`, "... CA <yyyy>"). The old issuer stays in OpenBao
  and keeps publishing its CRL until its certificates have expired; Keycloak
  and Traefik move to the new one at their next deployment, which recognises an
  old certificate by its authority key identifier, not by the CA's name.
- An OpenBao snapshot after every deployment of Keycloak and Matrix, also after
  a failed one: a first deployment creates secrets that exist nowhere but in
  OpenBao, and a failure later in the run does not undo them.
- Renewals run from `Initialize-Lab.ps1` (step 7), not from a scheduled task:
  the lab runs only while the PC does, and that script already runs after every
  Windows restart. Its check (`Get-LabMaintenanceDue` in `LabSecrets.ps1`) reads
  only public information (the certificates OpenBao and Keycloak serve, the root
  CRL on the PC and on the vault VM, OpenBao's CA certificate) and needs no
  login.
- The PC's TLS pin applies to OpenBao's host name only
  ([Internal PKI](#internal-pki-certificate-authority)).

---

## 10. Security notes

### Lab-only shortcuts and their enterprise equivalents

These shortcuts are deliberate, so that the lab stays simple to rebuild. Do not
copy them to production.

| Lab shortcut | Where | Enterprise equivalent |
|---|---|---|
| Passwordless sudo for `ansible`, a local account created on each Ubuntu VM; on the firewall, `ansible` is a full administrator with passwordless sudo too (`sudo_allow_wheel`) | `bootstrap-ansible-user.sh`, `config.xml.template` | Personal admin accounts from a directory (LDAP, FreeIPA, Active Directory), sudo with a password or narrowly scoped rules, privileged access management (PAM), Ansible become passwords from a vault, sudo use logged centrally |
| Console autologin on tty1 (the Ubuntu VMs except vault) | `setup-console-autologin.sh`, `config/lab.json` | Console login with credentials (ideally MFA); out-of-band console access is restricted and audited; a break-glass account whose password is kept in a vault |
| The PC signs its own SSH certificates: an 8-hour certificate for every machine (principal `lab-all`), requested from OpenBao with the AppRole `pc-deploy` from DPAPI; the PC's SSH key has no passphrase. No personal identity, no MFA, and every program that runs as you can get such a certificate | `LabSsh.ps1`, `Deploy-LabVault.ps1`, `keys\ssh` | People log in to the SSH CA with SSO and MFA (OIDC to Vault or OpenBao, Teleport, Smallstep) and get a short certificate for their own identity, with principals from their IdP groups; keys on hardware tokens (FIDO2) |
| The offline SSH CA lives on your everyday PC: its encrypted key next to its passphrase in DPAPI, every machine trusts it permanently, and the recovery file holds a copy. While it signs, its passphrase is on `ssh-keygen`'s command line (`-P`; OpenSSH 8.1 has no other unattended way), readable for programs running as you or as an administrator and written to the Security event log if process command lines are audited. Its signatures are recorded only in `keys\ssh\issued.log` (and in the sshd logs), not in OpenBao's audit log | `New-LabSshCa.ps1`, `LabSsh.ps1`, `New-LabRecoveryKit.ps1` | The SSH root of trust in an HSM or on an air-gapped machine, used only in a documented ceremony; break-glass certificates issued by two people, with an alert and central logging |
| Per-run SSH principals on ansible-control (`host-matrix` for MDAD, `lab-all` for `ping.yml`) share one account `ansible`, one key and passwordless sudo: code that runs during one run and stays on ansible-control could pick up the certificate of a later run. The scoping protects against mistakes and short-lived misuse, not against a persistent compromise of ansible-control | `Invoke-LabPlaybook.ps1`, `LabSsh.ps1`, `bootstrap-ansible-control.sh` | One identity per automation: each CI/CD or AWX job gets its own short certificate in an ephemeral runner; third-party code such as MDAD in an account of its own without sudo |
| Vagrant's own last hop to each VM (user `vagrant`, Vagrant's per-VM key) does not check the VM's host key; nothing of the lab's trust depends on it | Vagrantfile | Provisioning only over channels whose host identity is known (host keys or certificates from the image build or an attested agent) |
| The SSH host key revocation list is checked only by the clients that matter here, the PC and ansible-control; host certificates are valid for a year | `LabSsh.ps1`, `Remove-Lab.ps1`, `bootstrap-ansible-control.sh` | Short-lived host certificates renewed by an agent on every server, so revocation is rarely needed; where it is, the list distributed to every client by configuration management |
| "Secret zero" on the PC: two of OpenBao's key shares, the PC's two AppRole logins and the passphrases of the root CA key and of the offline SSH CA key are DPAPI files that your Windows account can decrypt, so the PC unseals and administers OpenBao, and signs SSH certificates, without any input. Every program that runs as you can do the same | `LabSecrets.ps1`, `Unlock-LabVault.ps1`, `keys\openbao`, `keys\pki`, `keys\ssh` | Auto-unseal through an HSM or a cloud KMS; unseal and recovery keys split among several people; administrators log in through SSO with MFA; automation authenticates with an identity the platform vouches for (cloud instance identity, Kubernetes service accounts) instead of a stored credential |
| One OpenBao node, sealed after every restart of the vault VM until the PC unseals it; snapshots after every deployment of Keycloak and Matrix, before the vault VM is deleted and when you run `Backup-LabVault.ps1`, kept on the PC (the newest 10); nothing copies them elsewhere unless you use `-Destination` | `Deploy-LabVault.ps1`, `Unlock-LabVault.ps1`, `Backup-LabVault.ps1`, `Deploy-LabKeycloak.ps1`, `Deploy-LabMatrix.ps1`, `Remove-Lab.ps1` | A 3-5 node raft cluster across failure domains with auto-unseal, scheduled snapshots stored off-site and restore drills, disaster-recovery replication to a second site, monitoring of seal status and leadership |
| OpenBao is administered through AppRoles whose policy `openbao-admin` allows everything, bound only to the PC's address: `pc-admin` for the scripts, and the break-glass login `recovery`, whose secret is only in the recovery file. No personal administrator accounts and no MFA (no login method for people at all). The bootstrap root token is revoked, and key shares alone no longer make a new one (OpenBao 2.5.3 switched the unauthenticated generate-root endpoints off) | `Deploy-LabVault.ps1`, `Show-LabSecret.ps1`, `New-LabRecoveryKit.ps1` | Personal administrators through OIDC (SSO with MFA) with narrowly scoped policies; break-glass credentials sealed and split among several custodians, every use alerted on and followed by a rotation; root tokens only generated in an emergency, by several key holders together, and revoked right after |
| Service secrets in plain text where the services read them: during an Ansible run they are only in memory (pipelining, temporary files in RAM), but on the VMs they are in environment and configuration files (0600 in `/opt/keycloak-stack`; on the matrix VM MDAD's files are readable by the `matrix` user, inside 0750 folders) and in the services' databases. They are static: the policies grant `create` but not `update`, and nothing rotates them | `keycloak.yml`, `lab-setup.yml`, `tasks/openbao-secrets.yml`, MDAD | Services fetch their secrets themselves at start (Vault Agent, a CSI driver, the application's own Vault integration); dynamic, short-lived database credentials (a database secrets engine); rotation on a schedule |
| Recovery kit: you keep key share C (password manager or paper), and one passphrase-encrypted file holds share B, the break-glass login for OpenBao, the encrypted root CA key with its passphrase, the root certificate, the encrypted offline SSH CA key with its passphrase and the firewall's passwords and API key, typically on a NAS or USB stick. With its passphrase, the file alone is administrator access to OpenBao and SSH access to every lab machine (from the PC's address). One person holds everything and can use it alone (`New-LabRecoveryKit.ps1 -Recover`) | `New-LabRecoveryKit.ps1` | Unseal and recovery shares handed to several key holders (each share encrypted for one person, for example with PGP), kept in separate safes; a documented break-glass procedure that is practised, needs two people and raises an alert; the root CA key backed up in HSMs |
| Keycloak's bootstrap admin `admin` and bootstrap service-account client `lab-ansible` are kept, although Keycloak marks both "temporary"; `lab-ansible` has full admin rights in the `master` realm | `keycloak.env.j2`, `keycloak.yml` | Permanent personal admin accounts with MFA and a dedicated, least-privilege automation client, all created as code; the temporary bootstrap accounts deleted afterwards |
| Keycloak's admin console is on the same host name as the login pages, reachable from the PC | `keycloak.env.j2`, `config/lab.json` | The admin console on a separate host name reachable only from a management network |
| Lab users with generated passwords, no MFA, Keycloak's default password policy (brute-force protection is on, self-registration off) | `keycloak.yml` | MFA (WebAuthn, OTP) and a password policy in the IdP, users from the HR process or a directory, joiners/movers/leavers automated |
| `on_conflict: replace`: when a Matrix account with the same user name exists but is linked to another Keycloak user ID (after a Keycloak rebuild), MAS re-links it instead of refusing the login. Whoever can create a Keycloak user with that name gets the Matrix account | `vars.yml` | Keep MAS's default (refuse), back up Keycloak so user IDs never change, and treat the IdP's user IDs as permanent |
| Matrix admin rights from a list in MAS's policy (`admin_users: [alice]`) | `vars.yml` | Admin rights from an IdP group or role claim, granted through an approval process and reviewed regularly |
| Leavers keep their Matrix sessions: disabling or deleting a user in Keycloak blocks new logins, but Element sessions already signed in keep working (back-channel logout ends only MAS's browser session, `logout_browser_only`); nothing deprovisions Matrix accounts | `vars.yml`, `keycloak.yml` | A leaver process that disables the IdP account and, through SCIM or the application's admin API, ends every session at once; short token lifetimes |
| Backups only for OpenBao (snapshots, taken by the deployments and `Remove-Lab.ps1` or by hand, kept on the PC; restoring one needs the key shares of its time); removing or losing the matrix or keycloak VM loses all messages, media, accounts and Keycloak's database | `Backup-LabVault.ps1`, everywhere else | Scheduled, tested backups (database dumps, media, configuration), stored off the host, with a restore drill |
| Offline root CA on your everyday PC: its key is an encrypted file (PKCS#8, AES-256) on the same disk as its passphrase (DPAPI); the root also signs OpenBao's own and the firewall's GUI certificates directly, because both must work before or without OpenBao | `New-LabRootCA.ps1`, `keys\pki`, `Deploy-LabVault.ps1`, `New-LabFirewall.ps1` | The root on an air-gapped machine or in an HSM, used in a documented key ceremony with several people present, signing only intermediate CAs; intermediate keys in HSMs; servers get certificates from an intermediate through ACME or CSR signing (as here) |
| Revocation through CRLs only (no OCSP), and no procedure that ever revokes a certificate. Renewals happen only when a script runs, not on a schedule: `Initialize-Lab.ps1` (after every Windows restart) checks what is due and runs the script that renews it: OpenBao's own certificate (397 days, renewed 30 days before it expires), the root's CRL (400 days, 60 days before) and the intermediate CA (3 years; a new one 400 days before it expires) through `Deploy-LabVault.ps1`, Keycloak's certificate (1 year, 30 days before) through `Deploy-LabKeycloak.ps1`, the firewall's GUI certificate (397 days) through `New-LabFirewall.ps1`, which it runs every time. Only the Matrix certificates (90 days, ACME) renew themselves. No rollover procedure yet for the root (10 years) | `Initialize-Lab.ps1`, `LabSecrets.ps1`, `New-LabRootCA.ps1`, `Deploy-LabVault.ps1`, `tasks/openbao-certificate.yml`, `New-LabFirewall.ps1` | OCSP or short-lived CRLs published automatically, a revocation process, expiry monitoring with alerts, every certificate renewed automatically on a schedule by an agent or ACME client (cert-manager, certmonger, Vault Agent), planned and rehearsed CA rollovers |
| ACME without external account binding: anything that reaches port 8200 can register an ACME account; only the HTTP-01 challenge (answered on port 80 of the name's lab address) and the three names of the role `acme-matrix` stand between it and a certificate | `Deploy-LabVault.ps1` | External account binding (EAB), so that only registered clients can order; the ACME directory reachable only from the server networks |
| Self-built SSH bastion without MFA or session recording, running on the perimeter firewall itself (restricted to certificate logins of `ansible` from the PC and ansible-control, and to forwarding to port 22 of the lab VMs) | `keys\ssh_config`, `Connect-Lab.ps1`, `config.xml.template`, `opnsense/sshd_config.d/20-lab-ssh.conf` | MFA on the bastion, session recording, often a managed product (e.g. Azure Bastion, AWS Systems Manager Session Manager, Teleport); the bastion is a separate host in a management network |
| Firewall administration: the GUI user `root` with a random password; one full-admin account `ansible` serves as SSH jump account and REST API user. These passwords and the API key and secret are DPAPI files on the PC (`keys\opnsense\*.dpapi`, with copies in the recovery file), not in OpenBao, because the firewall exists before OpenBao | `New-LabFirewall.ps1`, `config.xml.template`, `keys\opnsense\` | Personal admin accounts from central authentication (RADIUS, LDAP) with MFA; the local root password only as a break-glass credential in a vault; a separate, restricted jump account (the lab restricts forwarding with `PermitOpen`, but for its one full-admin account) and a separate least-privilege API user per automation tool, with secrets in a vault |
| Firewall management (GUI, API, SSH, DNS) open to the whole lab network, and on the PC side to 10.10.99.1, your everyday workstation, which also browses the internet | `config.xml.template` | Management interfaces reachable only from a dedicated management network (often out-of-band), never from server networks; administration only from privileged access workstations (PAW) or a management jump host |
| GUI changes on the firewall are not written back to the repository; a permanent change needs a repository edit and a rebuild | `config.xml.template`, `config/lab.json`, `New-LabFirewall.ps1` | Changes through the firewall's API from reviewed automation code, the GUI used read-only, configuration backups in version control, drift detection |
| The Ansible project and the vendored MDAD are pushed from the PC as archives, from the working folder as it is, not from a reviewed commit (the repository is in Git, github.com/masterries/HomeLab, but nothing enforces that what runs is committed); MDAD and its roles were fetched from GitHub by `git subtree` / `Update-LabMdad.ps1` and are trusted as GitHub delivered them (no signature check), the review is the diff you read yourself | `Invoke-LabPlaybook.ps1`, `Deploy-LabMatrix.ps1`, `Update-LabMdad.ps1` | The control node, AWX / Ansible Automation Platform or a CI/CD runner checks out a reviewed Git commit before every run; third-party code from an internal mirror or Ansible Automation Hub, in approved versions, upgrades reviewed as pull requests |
| Ansible is pinned to a package version (`ANSIBLE_VERSION`), but the Python libraries pip resolves for it are not; Docker CE on the Keycloak VM, Ubuntu's own packages and the Vagrant box come in their current version | `bootstrap-ansible-control.sh`, `keycloak.yml`, Vagrantfile | Pinned versions everywhere (lock or constraints files, execution environments, pinned packages from an internal mirror), tested upgrades |
| Container images straight from public registries (Docker Hub, quay.io, ghcr.io); only Keycloak is pinned by digest, the others by tag; no image scanning or signature check | `keycloak.yml`, MDAD | An internal registry that mirrors approved images, vulnerability scanning, signature verification (e.g. cosign), digests everywhere |
| Lab VMs can reach each other on every port (no host firewalls); for example any lab VM can reach Synapse's internal federation port 8448, Keycloak's admin API and OpenBao's API | the network design | Host firewalls or micro-segmentation, so that only the needed flows (MAS -> Keycloak, Keycloak -> MAS, ansible-control and Traefik -> OpenBao) are allowed |
| Router, firewall, DNS and DHCP on one small VM, only one of it; its logs stay on the firewall; the applications' logs and OpenBao's audit log stay on their VMs | `config.xml.template`, `New-LabFirewall.ps1`, `openbao.hcl.j2` | A redundant firewall pair (OPNsense supports this with CARP), at least two DNS servers, DHCP failover, the address plan in an IPAM tool, central logging (SIEM), monitoring, IDS/IPS |
| Little egress filtering: the lab may reach everything except the LabHost network and the WAN (Default Switch) network with your PC's Default Switch address. That still includes your home network through Windows NAT; only your home devices' own protection stands in the way | `config.xml.template` | Outgoing traffic filtered too (often web access only through a proxy); lab servers allowed to reach only the services they need; a lab or DMZ never has a route into office or home networks |
| Firmware: the firewall is updated only during a build, to the latest 26.7.x, and later runs update only what is below the pinned minimum 26.7.7; nothing patches it on a schedule (GUI: System > Firmware). The image comes straight from the public mirror, trusted through a hash and a signing-key fingerprint pinned by hand in the script; updates come straight from `pkg.opnsense.org`. The Ubuntu VMs are not patched on a schedule either | `New-LabFirewall.ps1` | Patch management: a defined patch cycle with maintenance windows, alerts on security advisories and vulnerability scanning; updates tested on a staging system first and rolled out to an HA pair one node at a time; images and packages from an internal, vetted mirror or artifact repository |

Some precautions are taken even in the lab:

- `keys/` (the encrypted offline SSH CA key and the PC's SSH key, the encrypted
  root CA key, the DPAPI files, the OpenBao snapshots and a recovery file kept on
  the PC) is in `.gitignore`. The folder itself is readable only by you and
  SYSTEM (`New-LabSshCa.ps1`), and the most sensitive files are locked down
  individually (`icacls`). No secret on the PC that opens anything on its own is
  plain text: DPAPI binds each `.dpapi` file to your Windows account (and to its
  own name), the root CA key is encrypted with a passphrase (PKCS#8, AES-256,
  600,000 PBKDF2 iterations), and so is the offline SSH CA key (OpenSSH's own
  format, 100 bcrypt rounds); the PC's SSH key has no passphrase, but opens
  nothing without its 8-hour certificate, which works only from the PC's
  addresses.
- SSH runs on certificates: short-lived user certificates (8 hours for the PC,
  2 hours per Ansible run for only the hosts that run needs), each with the
  addresses it may be used from, and host certificates for every machine. No
  host key is trusted on first use: the PC verifies each one out of band (the
  firewall's serial console, Hyper-V KVP for the VMs) before it certifies it,
  and every client accepts host keys only with a certificate. Once OpenBao
  signs, every certificate is in its audit log; the offline SSH CA takes over
  only for the bootstrap, while OpenBao's TLS certificate has expired, or when
  you ask for it (`-BreakGlass`)
  ([SSH certificates](#ssh-certificates-user-and-host-cas)).
- No service secret is stored on ansible-control's disk: the playbooks read
  them from OpenBao into memory for one run (`tasks/openbao-secrets.yml`). With
  pipelining (`ansible.cfg`), modules and their arguments (the run token, secret
  values) reach Python on stdin instead of a temporary file, and Ansible's
  local temporary files (templates rendered before they are copied, such as
  Keycloak's env files) go to a private folder in RAM that `openbao-run`
  removes when the run ends (`ANSIBLE_LOCAL_TEMP`). The values end up only where
  the running services need them, on their own VMs.
- Every run gets its own token, with only the policy its playbook needs
  (`ansible-keycloak`, `ansible-matrix` or `ansible-web`), valid for at most two
  hours and only from ansible-control's address. It travels response-wrapped (a
  single-use wrapping token, valid for 120 seconds) on stdin, never on a command
  line, and `openbao-run` revokes it when the run ends.
- OpenBao's policies are write-once: a playbook may create a missing secret
  (with check-and-set, `cas=0`) and read it, but never change one (`update` is
  not granted). OpenBao generates the values itself (password policies), and the
  playbooks refuse to generate new ones for a service that already has data.
- OpenBao's bootstrap root token is revoked at the end of `Deploy-LabVault.ps1`.
  The PC's AppRoles accept logins only from the PC's address (10.10.99.1/32),
  and their tokens work only from there: `pc-deploy` may do nothing but mint run
  tokens, take snapshots and have SSH certificates signed; `pc-admin` and the
  break-glass login `recovery` are
  administrators. The break-glass secret is stored nowhere but in the
  passphrase-encrypted recovery file, and every new file replaces it. Whenever
  a login is issued again (`New-LabAppRoleSecret`), all older secret IDs of that
  AppRole are destroyed once the new one is stored, so a lost or copied one stops
  working. Every request is
  recorded in OpenBao's audit log on the vault VM (`/var/log/openbao/audit.log`,
  secret values replaced by HMAC hashes).
- OpenBao's API is reachable only over HTTPS (port 8200). Port 80 serves an
  allow-list of public files (CA certificates and CRLs) and answers everything
  else with 404; `openbao.yml` checks that.
- The vault VM has no Hyper-V checkpoints (one could save its memory, with the
  unsealed keys, unencrypted to `G:`) and no console autologin.
- The private keys of the lab's certificates are made on the machine that uses
  them and never copied: Keycloak's on the Keycloak VM, those of the Matrix names
  by Traefik on the matrix VM, OpenBao's on the vault VM, a renewed GUI key on the
  firewall. Each intermediate CA's key was generated inside OpenBao and is never
  exported. (One exception: the first GUI key of a newly built firewall is made
  on the PC, in a temporary folder, and travels only in the seed ISO.)
- Scripts that show secrets (`Show-LabSecret.ps1 -Show`,
  `New-LabRecoveryKit.ps1`, `Unlock-LabVault.ps1 -Interactive`) run only in a
  real console window, never with redirected output. Passphrases, tokens and
  passwords to be hashed reach `openssl` and `curl` through environment
  variables or stdin, never as command-line arguments, which other programs
  could read.
- No password ever reaches Matrix: Matrix has no passwords at all, and only
  Keycloak sees the users' passwords. The Keycloak admin credentials never reach
  the Matrix configuration: the Matrix run gets only issuer, client ID and
  provider ID (`lab-shared.yml`) and the client secret, the one Keycloak secret
  the `ansible-matrix` policy may read.
- The OIDC client is narrow: authorization code flow only (no implicit flow, no
  password grant), PKCE S256 required, one exact redirect URI, no web origins,
  "full scope" off (no Keycloak roles in its tokens). Keycloak's consent screen
  is off for it because MAS is the organisation's own application: the usual
  choice for first-party apps, a convenience rather than a security gain.
- The Keycloak realm accepts HTTPS only (`ssl_required: all`), has
  self-registration off and brute-force protection on.
- Generated secrets are kept out of Ansible's output (`no_log`, `diff: false`);
  each task with `no_log` is followed by a check that reports only paths, field
  names and HTTP status codes, so errors stay readable.
- Keycloak's management port 9000 (health, metrics) listens on 127.0.0.1 only;
  neither PostgreSQL database has a port outside its VM. Matrix federation is
  off, and its port 8448 is not forwarded to the PC.
- The OPNsense image is checked before it is used: a pinned SHA-256 hash, and
  OPNsense's signatures on the checksum file and on the image, verified against
  a pinned fingerprint of the signing key. OpenBao comes from its own package
  repository, whose signing key is checked against a pinned fingerprint, at a
  pinned version that `apt` holds.
- Every piece of code that runs in the lab is in the repository, where you can
  read it: the lab's own scripts and playbooks and the third-party automation,
  MDAD with its 32 roles (`vendor\mdad`). A deployment downloads no automation
  code; only `Update-LabMdad.ps1` fetches MDAD (a `git subtree pull`, a commit
  you can compare with the previous version before it is used).
  `Deploy-LabMatrix.ps1` refuses to run when the vendored commit and the pinned
  `mdad_version` differ.
- The firewall's `config.xml` stores passwords and the API secret only as
  SHA-512-crypt hashes, made by `openssl passwd -6 -stdin` with the secret on
  stdin. The seed ISO, which carries that file and the GUI's private key, and
  the `config.xml` staged for it exist only during a build: both are removed on
  every exit path, also when the first boot fails, and a later run of
  `New-LabFirewall.ps1` removes an ISO left behind (for example after the
  script was killed). The firewall's network adapters stay disconnected until
  the lab configuration is in place. The rendered file is not kept anywhere
  else.
- SSH on the firewall accepts only certificates from the lab's SSH CAs, only
  for `ansible` and only from the PC and ansible-control, listens only on LAN
  and HOST, does not accept `root`, and forwards only to port 22 of the lab VMs.
  On the Ubuntu VMs, sshd accepts `ansible` only with a certificate and only
  from the jump host and ansible-control, never `root`, and forwards nothing.
  No connection is allowed in on WAN.
- No hidden anti-lockout rule: every way into the firewall's management is an
  explicit rule in `config.xml.template`.
- Changes to Windows (network, DNS rule, trusted root certificates) are never
  made silently by the build. They are separate scripts that you run yourself
  (`Install-LabHostNetwork.ps1`, `Install-LabRootCA.ps1`), and each can be
  undone with `-Remove`. `Initialize-Lab.ps1` only checks that they exist. On
  the Windows side it changes nothing but lab-specific items, and reports each
  one: the Private switch `LabNet` (no host adapter, so your PC's networking is
  untouched), the user variable `VAGRANT_HOME` if it is missing, the
  `vagrant\.vagrant` junction, the Hyper-V file locations of the lab VMs, and
  (through `New-LabFirewall.ps1`) the firewall VM and its image cache under the
  storage folder.
- The lab root CA is trusted only by your Windows user, not by the whole
  machine. For OpenBao the PC's scripts go further and pin it: they accept
  OpenBao's certificate only when its chain ends at exactly that root (compared
  by thumbprint) and it names the right host, whatever else Windows trusts (a
  root added by TLS-inspecting security software, or the retired first lab CA,
  is not enough), and also before you have imported the root
  ([Internal PKI](#internal-pki-certificate-authority)). On
  ansible-control, `openbao-run` and the playbooks likewise trust only the lab
  root for OpenBao (`--cacert`, `ca_path`).
- The internal machines are not reachable from the PC except through the
  bastion and the published ports.
- `Remove-Lab.ps1` deletes a VM named `firewall` only if its Notes carry the tag
  that `New-LabFirewall.ps1` writes there, so it cannot remove a VM it did not
  build, and it deletes only Hyper-V folders of VMs listed in `config/lab.json`.
  Before it deletes the vault VM, it takes an OpenBao snapshot (when that is not
  possible and no earlier snapshot exists while Keycloak or Matrix stay, it
  deletes nothing); afterwards it moves `keys\openbao` aside instead of deleting
  it.

### What the CA name constraint protects

Trusting a root CA normally lets it vouch for **any** website. If the key of a
self-made CA leaked, an attacker could forge certificates for your bank. The
lab root "DeployableServer Lab Root CA 2026" carries a critical name constraint
that limits it to `lab.internal` and its subdomains (`permitted DNS:lab.internal`)
and excludes every IP address (`excluded IP:0.0.0.0/0.0.0.0` and `IP:::/::`, all
of IPv4 and IPv6). Windows, browsers and OpenSSL check it for every certificate
below the root, whichever CA in between signed it: a certificate for another
name, or with any IP address in it, is rejected.

The IP exclusion closes a gap. A name constraint applies only to the name types
it lists: a constraint with DNS names alone says nothing about IP addresses, so
a certificate below it with the IP of a real server would still be accepted.

`pathlen:1` allows exactly one CA level below the root: the intermediates in
OpenBao (after a rotation there are several; only the newest issues
certificates). Each has `pathlen:0` and can sign only end-entity (server)
certificates, never another CA, and each carries the same name constraints, so
it stays limited even if it were ever chained to another root. Because the
extensions are marked critical, a client that does not understand them must
reject the certificate instead of ignoring them. Even a stolen root or
intermediate key therefore cannot be used against real websites. On top of that,
the keys are protected (the root's encrypted on the PC, the intermediates' never
leaving OpenBao), and OpenBao's roles issue only their listed names.

The price is the rule from
[P18](#p18-the-browser-or-openssl-rejects-the-certificate-or-windows-stops-trusting-it):
every name in every certificate must be a full name under `lab.internal`, and no
certificate can contain an IP address (open the firewall's GUI by name, not as
`https://10.10.99.2`).

---

## 11. Roadmap

The lab does what it set out to do: a segmented network, a chat with single
sign-on and calls, the secrets in a secrets manager and a two-level PKI with
ACME, all rebuilt from the repository.

If you brought an existing lab up to this version (instead of building it new),
run `.\scripts\Deploy-LabVault.ps1` once: it adds the break-glass AppRole
`recovery`, and its `PENDING` line says what is still missing. Then these steps
are yours, because they change your PC's trust, delete secret files or show
secrets. Run them in a PowerShell window of your own:

```powershell
.\scripts\Install-LabRootCA.ps1 -RemoveRetired                                    # stop trusting the retired first lab CA
.\scripts\Import-LabSecrets.ps1 -RemovePlaintext                                   # only if keys\keycloak\secrets.yml or keys\matrix\secrets.yml still exist
.\scripts\New-LabRecoveryKit.ps1 -Destination Z:\DeployableServer-recovery         # no kit yet: share C and the recovery file
.\scripts\New-LabRecoveryKit.ps1 -Renew -Destination Z:\DeployableServer-recovery  # kit made before: a new file with the break-glass login
```

Without `-Destination`, the recovery file goes to `keys\recovery`; copy it off
the PC yourself ([P45](#p45-a-script-that-shows-secrets-stops-before-it-shows-anything)).
A recovery file made before this version has no break-glass login (and no copy
of the firewall's `ansible` password and API key), so it could unseal OpenBao
but not give the PC its access back
([P46](#p46-after-losing-the-pcs-dpapi-keys-nothing-logs-in-to-openbao)).

After the move to SSH certificates, run `.\scripts\New-LabRecoveryKit.ps1 -Renew`
in your own PowerShell window: it adds the offline SSH CA to your recovery file
(the scripts remind you with a `PENDING` line until it does). The folder
`keys\lab-key-retired-<date-time>` with the old, now useless key can be deleted.

Done since the first version of this roadmap:

- **A secrets manager**: OpenBao on its own VM holds every service secret; the
  playbooks get a short-lived, response-wrapped token per run, and no secret
  that opens anything on its own is a plain file any more.
- **SSH without a shared key and without trust on first use**: SSH
  certificates from two SSH CAs (an offline one on the PC, OpenBao's SSH
  secrets engine), 8 hours for the PC, 2 hours per Ansible run for only the
  hosts it configures, host certificates for every machine whose host keys are
  verified out of band (serial console, Hyper-V KVP), a revocation list for
  retired host keys, and host key checking on everywhere, MDAD included
  ([SSH certificates](#ssh-certificates-user-and-host-cas)).
- **An internal ACME CA**: OpenBao's intermediate CA below an offline root.
  Traefik requests and renews the Matrix certificates itself, every private key
  is made where it is used, and those certificates are short-lived (90 days).
- **Backups of OpenBao**: raft snapshots (`Backup-LabVault.ps1`), taken
  automatically after every deployment of Keycloak and Matrix and before the
  vault VM is deleted.
- **Break-glass recovery**: key share C on paper, a passphrase-encrypted
  recovery file with share B and a break-glass login, and
  `New-LabRecoveryKit.ps1 -Recover`, which gives the PC its access back after a
  lost Windows profile.
- **Renewals and an intermediate CA rollover**: `Initialize-Lab.ps1` renews what
  is due after every Windows restart (step 7), and `Deploy-LabVault.ps1` makes a
  new intermediate 400 days before the current one expires (or with
  `-RotateIntermediate`); Keycloak and Traefik move to it by themselves. Tried
  on 2026-10-24: the default issuer is now "DeployableServer Lab Intermediate
  CA 2026-10-24" (`lab-int-20261024`), and "DeployableServer Lab Intermediate
  CA 2026" (`lab-int-2026`) stays in OpenBao for its CRL.
- **Everything that runs is in the repository**: MDAD and its roles vendored
  in `vendor\mdad` (upgraded with `Update-LabMdad.ps1`, never downloaded by a
  deployment), Ansible pinned to a version, and the checks used to verify the
  lab kept as scripts in `tests\` (`Invoke-LabTests.ps1`; the nine tests that
  change nothing passed on 2026-10-24).

Natural next steps, each a topic of its own:

- **Backups of the applications** (the most important gap). Database dumps with
  `pg_dump` of the three databases: Synapse and MAS (in MDAD's PostgreSQL on the
  matrix VM) and Keycloak (in its own PostgreSQL), plus Synapse's media store, on
  a schedule, copied off the VM (for example to the PC or a backup share), and a
  restore test into a rebuilt VM. The secrets these databases were set up with
  are in OpenBao, so a restore also needs an OpenBao snapshot that contains them
  (any snapshot taken after the first deployment; the deployments take one
  after every run). With Keycloak backed up, user IDs survive a rebuild, and
  `on_conflict` in MAS could go back to its safe default. The OpenBao snapshots
  themselves should leave the PC on a schedule too (today only
  `Backup-LabVault.ps1 -Destination` copies one, by hand).
- **One SSH identity per automation**: MDAD (third-party code) in an account of
  its own on ansible-control, without sudo there and with its own key, so that
  the per-run SSH principals also hold when something persists on
  ansible-control (today every run shares the account `ansible`, see
  [SSH certificates](#ssh-certificates-user-and-host-cas), "What remains").
- **Single sign-on for OpenBao's web UI**: an OIDC login in OpenBao with
  Keycloak as the identity provider, and a personal administrator with MFA and
  a scoped policy, so that `pc-admin` is left to the scripts and `recovery` to
  emergencies. Until then, `Open-LabVaultUi.ps1` hands out 1-hour tokens
  ([Open OpenBao's web UI](#open-openbaos-web-ui)). The same login could then
  give a person an SSH certificate for their own identity, instead of the PC
  signing its own.
- **Auto-unseal**: OpenBao unseals itself with a key held elsewhere (in an
  enterprise an HSM or a cloud KMS), so a restart of the vault VM no longer needs
  the PC.
- **Element Admin**: a web interface for Matrix administration (users, rooms,
  media) for `alice`, using the admin rights MAS's policy already grants her.
  Check which admin tools the pinned MDAD version can deploy.
- **Permanent Keycloak administrators with MFA**: personal admin accounts and a
  least-privilege automation client created as code, the temporary bootstrap
  admin and client deleted, MFA (WebAuthn or OTP) required in both realms.
- **Day-2 changes to the firewall through OPNsense's REST API**, from Ansible
  playbooks on ansible-control with the API key of user `ansible` (today a DPAPI
  secret on the PC, `opnsense/api-ansible`; a playbook would need it in
  OpenBao): published names (dnsmasq host entries), virtual IPs and port
  forwards first. A change then needs neither a rebuild nor a click in the GUI,
  and it is still code in the repository, reviewed like code. This is how
  enterprises manage firewalls at scale.
- **Root CA rollover**: the intermediate already rotates itself; the root (10
  years) has no procedure yet: a new root next to the old one, trusted by
  Windows, the VMs and the containers' CA bundle, new intermediates below it,
  the certificates moved over, the old root retired, as was done once for the
  first lab CA.
- **Monitoring**: metrics (Keycloak already exposes them on its management
  port; Synapse, Traefik, LiveKit and OpenBao can too) collected by Prometheus
  and shown in Grafana, alerts for a sealed OpenBao, expiring certificates and
  CRLs (today only checked when `Initialize-Lab.ps1` runs), full disks and
  failed units; central logs, OpenBao's audit log among them.
- **Element X through an Android emulator**: the mobile app needs a device with
  a route into the lab, the lab's DNS names and trust in the lab root CA. An
  Android emulator running on the PC could provide all three (its traffic leaves
  through the PC; DNS and the CA have to be set up inside the emulator), which
  would make the MAS-based login and calls testable with Element X.
