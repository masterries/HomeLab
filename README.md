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
5. [Everyday operations](#5-everyday-operations), starting with
   [The lab.ps1 commands](#the-labps1-commands)
6. [How to ...](#6-how-to-)
7. [Concepts explained](#7-concepts-explained), among them
   [SSH certificates: user and host CAs](#ssh-certificates-user-and-host-cas)
8. [Repository layout](#8-repository-layout), with
   [Where the old scripts went](#where-the-old-scripts-went)
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
  [scripts/commands/firewall.ps1](scripts/commands/firewall.ps1) builds it from the
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

You operate the whole lab from the PC through one entry point,
`.\lab.ps1 <command>` (`.\lab.ps1 help` lists the commands,
`.\lab.ps1 help <command>` explains one). The PC itself does only what only the
PC can do: drive Hyper-V and Vagrant, build the firewall, keep "secret zero"
and the two offline CAs, check the machines' host keys out of band, and decide
in OpenBao who may do what
(its identities and policies). Everything else, the configuration of the
machines and services, OpenBao's own engines and the firewall's GUI certificate
included, runs as Ansible on ansible-control, started by the PC with credentials
for that one run
([Configuration management with Ansible](#configuration-management-with-ansible)).

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
| Internal PKI | Two levels, as in enterprises: an offline root CA on the PC (its key encrypted, restricted by X.509 name constraints to names under `lab.internal`) signs an intermediate CA inside OpenBao, whose key never leaves it. The intermediate issues the everyday certificates, by signing a CSR (Keycloak, the firewall's GUI) and through ACME (Traefik, renewed automatically). Revocation lists are published over HTTP, so Windows checks revocation. The renewals that are due run whenever `lab.ps1 up` starts the lab again after a Windows restart, and the intermediate itself is replaced by a new one ("rotated") 400 days before it expires. |
| Secrets management | OpenBao as the one store for the services' secrets: values generated by OpenBao, one access policy per consumer that may create a missing secret but never change one, a short-lived, response-wrapped token per Ansible run that works only from the control node, secrets kept off the control node's disk, an audit log of every access; OpenBao's own configuration split in two planes, as in enterprises: identities and policies (policies as files in the repository) set by the PC, the engines' configuration applied by an Ansible playbook whose token cannot hand out rights. |
| Key management and recovery | OpenBao's key split with Shamir's secret sharing (three shares, any two unseal it); Windows DPAPI as "secret zero" for the shares and logins the PC needs; a recovery kit (one share with you; a passphrase-encrypted file somewhere else with a second share and a "break-glass" login) that restores the PC's access after a lost Windows profile; an OpenBao snapshot (backup) after every Keycloak and Matrix deployment. |
| Single sign-on | Keycloak as identity provider; OpenID Connect (OIDC) with the authorization code flow and PKCE; a confidential client with an exact redirect URI; back-channel logout; MAS as the OIDC layer between Matrix clients and Keycloak. |
| Team chat and calls | Matrix (Synapse, Element Web) with `.well-known` delegation; calls through a LiveKit SFU (MatrixRTC, WebRTC) behind NAT. |
| Reverse proxy and TLS | Traefik terminates TLS for several names on one address, gets and renews its certificates itself through ACME, and routes by host name and path; Keycloak and OpenBao terminate TLS themselves. |
| Containers | Keycloak and PostgreSQL as a Docker Compose project; the Matrix services as Docker containers run by systemd units. |
| Configuration management | Ansible inventory, groups, idempotent playbooks, handlers, delegation, secrets read from OpenBao at run time and held only in memory, Keycloak's realm, client and users configured as code through its admin API; check runs (`--check`) that must find nothing to change, as drift detection. |
| Third-party automation | MDAD vendored: its code and its 32 roles kept unchanged in this repository at one Git commit (`vendor\mdad`), copied to the control node for each deployment, with our own configuration next to it (`ansible\matrix\`); container images pinned by tag or by digest; Ansible and the OpenBao package pinned to a version, OpenBao's repository signing key to a fingerprint, the OPNsense image to a SHA-256 hash. |
| Infrastructure as code | One data file ([config/lab.json](config/lab.json)), a Vagrantfile, a firewall configuration template, playbooks and a set of idempotent scripts behind one entry point (`lab.ps1`) rebuild the whole lab from nothing. |
| Appliance automation | A network appliance without cloud-init or Vagrant box: verified image download, configuration imported on the first boot by a script that talks to the serial console, then patched to a pinned minimum version; later an Ansible playbook renews its GUI certificate in place, from OpenBao's intermediate CA, through OPNsense's own PHP configuration library, without a rebuild. |

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
 | firewall: OPNsense 26.7 (FreeBSD + pf), built by lab.ps1 firewall           |
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
  API calls of the PC's scripts such as `lab.ps1 deploy vault`,
  `lab.ps1 secret`, the run tokens for Ansible and the snapshots of
  `lab.ps1 backup`): answer `10.10.99.5` -> TCP 8200 -> port forward ->
  `10.10.10.50:8200`, OpenBao itself, which terminates TLS with a certificate
  signed by the offline root. The PC's scripts accept that certificate only if
  the lab root signed it directly, a chain of exactly two (the certificate and
  the root); a certificate for that name from OpenBao's own intermediate CA is
  refused (certificate pinning, see
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
  `lab.ps1 mdad-upgrade` fetches a new MDAD version): lab VM -> `hn1` (LAN) ->
  outbound NAT to the firewall's WAN address -> `hn0` (WAN) -> Windows NAT ->
  internet. This is double NAT, and that is fine for outbound traffic. The
  firewall's own downloads (OPNsense updates from `pkg.opnsense.org`) leave
  through `hn0` the same way.
- **Ansible**: ansible-control connects over LabNet directly to the matrix,
  keycloak and vault VMs (SSH, with its own key and a certificate for this run
  that names only the hosts the run's profile configures, see
  [Where code runs](#where-code-runs-the-pc-and-ansible-control)), to Keycloak's
  admin API (`https://keycloak.lab.internal`, lab view `10.10.10.40`), to
  OpenBao's API (`https://vault.lab.internal:8200`, lab view `10.10.10.50`;
  secrets and certificate signing, and for `openbao-config.yml` OpenBao's own
  configuration, with a run token that works only from ansible-control's address
  `10.10.10.10`) and to the firewall's LAN address `10.10.10.1` (SSH, for example
  to renew the firewall's GUI certificate).
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
| Firewall: passwords of `root` and `ansible`, REST API key | PC, DPAPI, `keys\opnsense\` (copies in the recovery file) | `lab.ps1 firewall` (the firewall exists before OpenBao) |
| OpenBao: key shares A and B, the PC's logins `pc-admin` and `pc-deploy` | PC, DPAPI, `keys\openbao\` (a copy of share B in the recovery file) | `lab.ps1 deploy vault` (new logins after a lost Windows profile: `lab.ps1 recovery -Recover`) |
| OpenBao: key share C | you: a password manager or paper | `lab.ps1 deploy vault`; handed to you once by `lab.ps1 recovery` |
| OpenBao: the break-glass login `recovery` (administrator rights) | only in the recovery file, encrypted with your passphrase | `lab.ps1 recovery`, a new secret for every kit |
| Root CA private key | PC, `keys\pki\root-ca.key`, encrypted; its passphrase with DPAPI (both also in the recovery file) | its first signature: the first firewall build (`lab.ps1 up`), or `lab.ps1 deploy vault` (`Initialize-LabRootCa` in `lib\LabPki.ps1`) |
| Offline SSH CA private key | PC, `keys\ssh\offline-ca`, encrypted; its passphrase with DPAPI (both also in the recovery file) | `lab.ps1 up` (`Initialize-LabSshCa` in `lib\LabSsh.ps1`) |
| OpenBao's SSH CA private key | OpenBao (mount `ssh`), generated there, never exported | `lab.ps1 deploy vault` |
| The PC's SSH key | PC, `keys\ssh\pc_ed25519`, no passphrase; it opens nothing without its 8-hour certificate, which works only from the PC's addresses | `lab.ps1 up` (`Initialize-LabSshCa` in `lib\LabSsh.ps1`) (the certificate: `Get-LabSshConfig` in `LabSsh.ps1`, on demand) |
| ansible-control's SSH key | only on ansible-control, `~ansible/.ssh/id_ed25519`; it opens nothing without the 2-hour certificate the PC signs for each run | `bootstrap-ansible-control.sh` |

Everything OpenBao holds is also in its **snapshots** (`keys\openbao\snapshots`,
the newest 10): `lab.ps1 deploy keycloak` and `lab.ps1 deploy matrix` take one
after every run, because a first deployment creates secrets that exist nowhere
else, and `lab.ps1 down` takes one before it deletes the vault VM. A snapshot
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
of its own for one run: every run whose profile in
[config/run-profiles.json](config/run-profiles.json) names OpenBao policies
(`lab.ps1 run`, and the runs of `lab.ps1 deploy`), through
`Invoke-LabRun` in [scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1) and
`New-LabRunToken` in [scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1)
(the run itself: [Where code runs](#where-code-runs-the-pc-and-ansible-control)):

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
   policy the run's profile names: `ansible-keycloak` (`keycloak.yml`),
   `ansible-matrix` (`matrix-prepare.yml` and MDAD), `ansible-firewall`
   (`firewall.yml`: only signing the firewall's GUI certificate) or `ansible-web`
   (`hello-nginx.yml`). The one exception is `openbao-config.yml`, OpenBao's
   configuration plane: its token comes through the token role `ansible-config`
   (policy `openbao-config`, 30 minutes at most), and only the administrator
   login `pc-admin` may mint it (during the very first deployment, the initial
   root token), not `pc-deploy`. OpenBao answers with a
   response-wrapped token: instead of the token, a single-use wrapping token
   valid for 120 seconds that can only be exchanged for it.
3. The wrapping token travels to ansible-control on SSH's standard input, never
   on a command line, where [ansible/bin/lab-run](ansible/bin/lab-run) hands it
   on to [ansible/bin/openbao-run](ansible/bin/openbao-run), which exchanges it
   ("unwrap") for the run token. That token works only from ansible-control's
   address and for at most two hours (`ansible-config`: 30 minutes).
   `openbao-run` exports `VAULT_ADDR`, `VAULT_CACERT` and `VAULT_TOKEN`, points
   Ansible's local temporary folder (`ANSIBLE_LOCAL_TEMP`) to a private folder
   in RAM (tmpfs: `XDG_RUNTIME_DIR`, or `/dev/shm`) and starts the playbook.
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

**Who configures OpenBao.** OpenBao's setup is split into two "planes", each
with its own author. The *identity plane* says who may log in and do what: the
ACL policies (one file per policy in
[config/openbao/policies](config/openbao/policies), the file name is the
policy's name), the AppRoles `pc-admin`, `pc-deploy` and `recovery`, the token
roles `ansible-run`, `ansible-config` and `ui-admin`, the SSH CA and its roles,
and the intermediate CA (its key made inside OpenBao, its certificate signed by
the offline root). The PC writes it through the API (`lab.ps1 deploy vault`,
step 6, in [scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1)), and it also
initialises and unseals OpenBao. The *configuration plane* says how the engines
behave: the KV mount `lab` (check-and-set required, 10 versions per secret), the
password policies `lab-alnum-24`, `-48` and `-64`, the intermediate's mount
`pki_int` with its URLs, revocation list and tidying, the PKI roles
(`acme-matrix`, `keycloak`, `firewall-gui`, `web`) and ACME. Ansible writes it
from ansible-control:
[ansible/playbooks/openbao-config.yml](ansible/playbooks/openbao-config.yml),
with the desired values in
[vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml), reads
each object, compares it and writes only what differs (a second run reports
`changed=0`; `.\lab.ps1 run openbao-config --check --diff` shows drift). Its
token (policy `openbao-config`) can write no policy, login, token role or CA,
cannot sign or issue a certificate and cannot read a secret, so the
configuration plane cannot hand out rights
([tests/Test-LabOpenBaoConfig.ps1](tests/Test-LabOpenBaoConfig.ps1) checks
this). On a brand-new OpenBao, `lab.ps1 deploy vault` runs the playbook twice:
before the intermediate exists (mounts, URLs) and after it (PKI roles, ACME).
Enterprise equivalent: separation of duties; an IAM team owns identities and
policies, a platform pipeline owns the configuration of the engines.

**Where the certificates come from.** The PKI has two levels:

```
 DeployableServer Lab Root CA 2026        offline: only on the PC (keys\pki), its key
 EC P-384, 10 years, pathlen 1,           encrypted; every client trusts it; it signs
 only DNS names under lab.internal        only the certificates directly below it
  |
  |-- vault.lab.internal                  OpenBao's own TLS certificate, 397 days
  |-- (firewall.lab.internal)             only the FIRST web GUI certificate of a newly
  |                                       built firewall, 397 days, until Ansible
  |                                       replaces it with one from the intermediate
  |-- DeployableServer Lab Intermediate CA 2026-10-24
  |    the current issuer (OpenBao name lab-int-20261024): EC P-384, 3 years,
  |    inside OpenBao (mount pki_int), its key never exported
  |     |
  |     |-- keycloak.lab.internal         CSR signing, role keycloak, 1 year
  |     |-- firewall.lab.internal         the web GUI: CSR signing, role firewall-gui, 1 year
  |     |-- matrix.lab.internal,          ACME, role acme-matrix, 90 days
  |     |   element.lab.internal,
  |     |   lab.internal
  |     `-- hello.lab.internal            CSR signing, role web (the nginx demo), 1 year
  `-- DeployableServer Lab Intermediate CA 2026
       the first intermediate (lab-int-2026), replaced on 2026-10-24: it issues
       nothing new, but stays in OpenBao and keeps publishing its revocation list
```

**The intermediate is rotated.** A CA must stay valid for longer than the
certificates it issues (Keycloak's: one year). So `lab.ps1 deploy vault` makes a
new intermediate (a new key inside OpenBao, signed by the root on the PC) when
the current one expires within 400 days, or at once with
`.\lab.ps1 deploy vault -RotateIntermediate`, and makes it the default
issuer. The old one stays in OpenBao and keeps publishing its revocation list,
because the certificates it issued remain valid until they expire; Keycloak and
Traefik move to the new one at their next deployment, the firewall's GUI at the
next `lab.ps1 deploy firewall` (which `lab.ps1 up` starts by itself when the
served certificate is not from the current intermediate). This lab's intermediate
was rotated on 2026-10-24, as a test of exactly this path. How it works:
[Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation);
the commands: [Rotate the intermediate CA](#rotate-the-intermediate-ca).

**Renewals.** Each certificate is renewed by whoever uses it: Traefik renews the
Matrix certificates itself through ACME; `lab.ps1 deploy keycloak`,
`lab.ps1 deploy vault` and `lab.ps1 deploy firewall` renew Keycloak's,
OpenBao's and the firewall's certificates when fewer than 30 days are left
(Keycloak's and the firewall's also when they are not from the current
intermediate), and
`lab.ps1 deploy vault` also renews the root CA's revocation list and the
intermediate CA. A renewal happens only when the script that does it runs. So
`lab.ps1 up`, which you run after every Windows restart, checks what is
due (its step 7, *Maintenance*; `lab.ps1 maintain` does the same on its own,
`-List` only shows it) and runs `lab.ps1 deploy vault`, `lab.ps1 deploy keycloak`
and/or `lab.ps1 deploy firewall` for it. Its step 4 runs `lab.ps1 firewall`,
which only reports on the firewall's GUI certificate and no longer renews it.
Every certificate with its lifetime, its renewal rule and the command that
forces a renewal: [Renew certificates](#renew-certificates).

**Who signs what.** The offline root signs as little as possible, because every
signature means unlocking its key on the PC:

| Signer | Signs | How the request reaches it |
|---|---|---|
| Offline root (PC, `lib\LabPki.ps1`) | the intermediate CA | OpenBao makes the key and the request; the PC fetches it over its pinned TLS connection (`lab.ps1 deploy vault`) |
| Offline root | OpenBao's own TLS certificate (`vault.lab.internal`) | key and request made on the vault VM, fetched over the PC's own SSH connection (`lab.ps1 deploy vault`) |
| Offline root | only the FIRST web GUI certificate of a newly built firewall | key and request made on the PC, put into the rendered `config.xml` (`lab.ps1 firewall`, `Get-GuiCertificate` in `lib\LabFirewall.ps1`) |
| Intermediate (in OpenBao, `pki_int`) | Keycloak's certificate (role `keycloak`) | a request made on the keycloak VM, sent by `keycloak.yml` |
| Intermediate | the Matrix names (role `acme-matrix`) | ACME, by Traefik on the matrix VM |
| Intermediate | the firewall's web GUI from then on (role `firewall-gui`) | a request made on the firewall, sent by `firewall.yml` (`lab.ps1 deploy firewall`), which renews it |
| Intermediate | the web demo `hello.lab.internal` (role `web`) | a request made on the demo's VM, sent by `hello-nginx.yml` |

Two certificates come from the root directly because they must not depend on
OpenBao: OpenBao's own (an expired one could otherwise only be renewed through
the server it protects), and the first GUI certificate of a new firewall (the
firewall is built before OpenBao exists, so nothing else could sign it). From
then on the firewall's GUI certificate is an ordinary server certificate like
Keycloak's: [ansible/playbooks/firewall.yml](ansible/playbooks/firewall.yml)
has the firewall make a new key and request, OpenBao's intermediate signs it
(the run's token may sign nothing else), and
[opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php) puts key, certificate
and intermediate into the firewall's `config.xml`, which is what System > Trust
in the GUI does. OpenBao's own certificate must come from the root and never
from the intermediate: the PC accepts only a `vault.lab.internal` certificate
that the root signed directly, otherwise whoever could get one issued by
OpenBao (by changing a PKI role, say) could pose as OpenBao to the PC, which
sends it key shares and logins. Enterprise equivalent: the root is used only
for CAs and a few bootstrap certificates; appliances enrol their certificates
from the issuing CA (ACME, SCEP or an automation job like this one).

Trust: Windows trusts the root for your user (`lab.ps1 trust`), and the
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
that `.\lab.ps1 trust -RemoveRetired` can remove it from your
Windows certificate store.

### Where code runs: the PC and ansible-control

Two machines run the lab's code: your Windows PC (`lab.ps1` and the libraries in
`scripts\lib`) and the VM ansible-control (Ansible). Which of them does what
follows one rule, written down in the header of
[scripts/lib/Lab.ps1](scripts/lib/Lab.ps1):

1. **The PC does only what only the PC can do**: drive Hyper-V and Vagrant, hold
   "secret zero" (DPAPI), operate the two offline CAs, read the host keys that
   reach it out of band (the firewall's serial console, Hyper-V KVP for the
   Ubuntu VMs), own OpenBao's identity plane (who may log in, with which policy;
   see *Who configures OpenBao* above), install the firewall's bootstrap
   contract (what `lab.ps1 firewall` sets up so that Ansible can manage it: its
   SSH trust, the jump-host limits of its sshd, the DNS drop-in, a current
   OPNsense version; `checks.yml` checks it), and look at the lab the way your
   browser and shell see it.
2. **The offline CAs sign only what reaches the PC over its own verified
   channel**: the pinned TLS connection to OpenBao, or the PC's own SSH
   connection to a host whose key was verified out of band. Nothing that passed
   through ansible-control is ever signed offline, because it could have been
   changed there. That is why the firewall's GUI certificate, once Ansible
   renews it, comes from the intermediate (*Who signs what* above).
3. **Everything else is an Ansible run on ansible-control**, started by the PC
   with credentials for that run only. ansible-control keeps no standing
   credential.

**One run.** `Invoke-LabRun` in [scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1)
is the PC's half of every run (`lab.ps1 run`, and the runs of `lab.ps1 up` and
`lab.ps1 deploy`), [ansible/bin/lab-run](ansible/bin/lab-run) the half on
ansible-control:

1. **A fresh copy.** The PC packs the repository's `ansible\` folder,
   `config\lab.json`, `config\run-profiles.json`, `opnsense\lab-gui-cert.php` and
   the PUBLIC files of the lab root CA (no other file from `keys\` goes into this
   copy) and copies them to ansible-control, through the firewall like every SSH
   connection into the lab; a profile with `syncMdad` also gets `vendor\mdad`.
   `lab-run` replaces `~/lab` with this copy (and then `~/mdad` with MDAD's)
   instead of merging it, so files deleted in the repository disappear on the VM
   too, and a quick fix made by hand on the VM cannot silently survive.
2. **An SSH certificate for this run.** The PC signs ansible-control's own key
   (made on the VM, it never leaves it) for 2 hours and only for the principals
   of the run's profile: `host-<vm>` opens only that machine, `lab-all` every
   one; a profile without principals gets no certificate and stays on
   ansible-control. `lab-run` puts the certificate next to the key and deletes it
   when the run ends, whatever happens. It also removes the sockets of SSH
   connections that Ansible keeps open, so no run can reuse a connection of an
   earlier, broader one.
3. **An OpenBao token, if the profile names policies**: exactly those, through
   the profile's token role (`ansible-run` unless it names `ansible-config`),
   handed over wrapped on standard input, as in *How a playbook gets its
   secrets* above.
4. **One run at a time.** A single `ssh` call starts `lab-run`, which takes a
   lock first: a second run while one is active stops at once with exit code 75,
   and `lab.ps1` says so. Then the profile's playbook or command runs in `~/lab`,
   through `bin/openbao-run` when there is a token; its exit code is the run's.

**config/run-profiles.json: every run of the lab.**
[config/run-profiles.json](config/run-profiles.json) lists every run there is,
each with what it starts and the credentials it gets. `.\lab.ps1 run` without
arguments lists them with their rights; `.\lab.ps1 run <profile>` runs one, and
further arguments are added unchanged to the profile's `ansible-playbook` call
(`--check --diff`, `-v`, `-e key=value`). A profile that runs a command gets
them appended to that command instead; `bin/deploy-matrix` refuses them (exit
code 2), because MDAD's install cannot be a dry run and `--check` must not
quietly turn into a real install - single MDAD tags go through the profile
`mdad` (`.\lab.ps1 run mdad --tags=self-check`). `bin/syntax-check` and the
token checks' scripts ignore extra arguments. A playbook's file name works too
(`.\lab.ps1 run keycloak.yml`) and runs with the profile that names it; a
playbook without a profile gets a certificate for every machine and no token,
with a warning.

| Profile | What runs (in `~/lab` on ansible-control) | SSH certificate for | OpenBao token (policies) | Started by |
|---|---|---|---|---|
| `base`, `checks` | `base.yml` (zsh, console autologin), `checks.yml` (read-only checks of every machine) | base: matrix, keycloak, vault (ansible-control itself is managed locally); checks: every machine | none | `lab.ps1 up`; `lab.ps1 test` (`checks`, and `base` with `--check`) |
| `ping` | `ping.yml` | every machine | none | by hand |
| `openbao` | `openbao.yml`: OpenBao's package, configuration file and service, nginx | vault | none | `lab.ps1 deploy vault` (also `lab.ps1 up` / `lab.ps1 maintain` when one of its renewals is due) |
| `openbao-config` | `openbao-config.yml`: OpenBao's configuration plane, through its API | none | `openbao-config`, token role `ansible-config` | `lab.ps1 deploy vault` (as `openbao`); `lab.ps1 test` (`--check`) |
| `firewall` | `firewall.yml`: the firewall's GUI certificate | firewall | `ansible-firewall` | `lab.ps1 deploy firewall`; `lab.ps1 up` / `lab.ps1 maintain` when it is due; `lab.ps1 test` (`--check`) |
| `keycloak` | `keycloak.yml` | keycloak | `ansible-keycloak` | `lab.ps1 deploy keycloak` (also `lab.ps1 up` / `lab.ps1 maintain` when its certificate is due) |
| `matrix-prepare`, `matrix`, `matrix-setup`, `mdad` | `matrix-prepare.yml` (with `syncMdad`: `vendor\mdad` to `~/mdad` first), then `bin/deploy-matrix install-all` (`matrix-setup`: `setup-all`); `mdad` runs an MDAD playbook directly in `~/mdad` | matrix | `ansible-matrix` | `lab.ps1 deploy matrix` (`-Setup`: `matrix-setup`); `mdad` by hand |
| `hello-nginx` | `hello-nginx.yml`, the nginx demo | every machine | `ansible-web` | by hand |
| `syntax`, `test-run-token`, `test-config-token`, `test-secret-creation`, `test-sleep` | `bin/syntax-check` (every playbook), the tests' helpers in `ansible/tests/`, `sleep 20` | none | `test-run-token` and `test-secret-creation`: `ansible-keycloak`; `test-config-token`: `openbao-config` (role `ansible-config`) | `lab.ps1 test` (`test-sleep`: by hand) |

Tokens through `ansible-run` last at most 2 hours and are minted by the PC's
everyday login `pc-deploy`; through `ansible-config` at most 30 minutes, minted
only by the administrator login `pc-admin` (on the very first `lab.ps1 deploy
vault`, whose step 7 ends the bootstrap only after its `openbao-config.yml`
runs, by the initial root token). Enterprise equivalent: job templates
in AWX / Ansible Automation Platform, each with its own machine credential and
secrets lookup, or a CI/CD runner that checks out a reviewed commit and gets
short-lived credentials for each job; the identities those jobs run as belong to
an IAM team, as OpenBao's identity plane here belongs to the PC, not to the
automation that uses them.

### Networks

| Hyper-V switch | Switch type | Subnet | Members | Purpose |
|---|---|---|---|---|
| Default Switch | Built-in, NAT via Windows ICS | Chosen by Windows, changes on every reboot | PC, firewall `hn0` (WAN) | Internet uplink for the lab (the firewall's WAN side) |
| LabHost | Internal (host + VMs) | 10.10.99.0/24 | PC `10.10.99.1`, firewall `hn2` (HOST) `10.10.99.2` and the virtual IPs `10.10.99.3` (matrix), `10.10.99.4` (keycloak) and `10.10.99.5` (vault) | Fixed path from the PC into the lab: SSH to the bastion, DNS and the web GUI on `.2`; the published ports of each published VM on its own address |
| LabNet | Private (VMs only, the PC has no adapter on it) | 10.10.10.0/24 | firewall `hn1` (LAN) `.1`, ansible-control `.10`, matrix `.30`, keycloak `.40`, vault `.50`, DHCP pool `.100`-`.199` | The segmented lab network, reachable only through the firewall |

LabHost is created once by `scripts/host/Initialize-LabHost.ps1`. LabNet is
created by `scripts/commands/up.ps1`. Almost all addresses come from
[config/lab.json](config/lab.json), the main source for the lab's data (domain,
networks, firewall addresses, lab VMs and what is published to your PC). The
Vagrantfile, `lab.ps1 firewall` and `lab.ps1 up` read it;
`lab.ps1 down` reads its `vms` (which leftover Hyper-V folders it may delete);
the libraries in `scripts\lib` (`LabSecrets.ps1` loads the file for all of
them) read its `domain` (OpenBao's URL, the root CA's name constraint, the URLs
of checks and messages), and `lab.ps1 deploy vault` also reads `firewall.pcIp`
and ansible-control's `ip`: the addresses that OpenBao's logins and run tokens
are bound to. Every Ansible run gets a copy of it in `~/lab/config/`, so the
playbooks read the same values (`lab_config` and `lab_domain` in
[group_vars/all.yml](ansible/inventory/group_vars/all.yml); `base.yml`, for
example, takes `consoleAutologin` from it). A few values are repeated by hand and must be
changed together with it: the PC's address, its DNS server and the NRPT
namespace in `lab.ps1 host-setup`; the domain in the host names of
[hosts.ini](ansible/inventory/hosts.ini), in `matrix_domain` and in the Matrix
inventory's host name
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
`lab.ps1 firewall` from the official OPNsense 26.7 "nano" image (a
ready-installed disk image, no installer) and updated to at least 26.7.7 during
the build. So the two kinds of VM are built in two different ways: the Ubuntu
VMs start from a generic image that scripts change step by step, while the
firewall is an appliance handed one complete configuration file.
[An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)
explains why that matters.

| VM | Role | Addresses | DNS names | Size |
|---|---|---|---|---|
| firewall | OPNsense: router/NAT, pf packet filter, dnsmasq DHCP + DNS, SSH bastion, web GUI + REST API | `hn0` WAN: DHCP from the Default Switch (MAC 02:00:0a:0a:0a:fe); `hn1` LAN: 10.10.10.1 (MAC 02:00:0a:0a:0a:01); `hn2` HOST: 10.10.99.2 + virtual IPs 10.10.99.3, 10.10.99.4 and 10.10.99.5 (MAC 02:00:0a:0a:0a:02) | `firewall.lab.internal` (PC gets 10.10.99.2, lab gets 10.10.10.1) | Hyper-V Generation 1, 1 vCPU, 3 GB static RAM, 16 GB disk |
| ansible-control | Ansible control node: runs all playbooks and MDAD; holds the copy of the Ansible project (`~/lab`, replaced by a fresh copy on every run, see [Where code runs](#where-code-runs-the-pc-and-ansible-control)), a copy of the repository's `vendor\mdad` (`~/mdad`, replaced on every `lab.ps1 deploy matrix` run) and the public PKI files (`~/lab-pki`: root certificate and its CRL). No service secrets on disk: each run that needs OpenBao gets a run token from the PC (see [above](#where-secrets-and-certificates-come-from)); its only secret is its own SSH key, which opens nothing without the 2-hour certificate the PC signs for each run | 10.10.10.10 (MAC 02:00:0a:0a:0a:0a, DHCP reservation) | `ansible-control.lab.internal` | 2 vCPU, 2 GB |
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
installs it, run by `lab.ps1 deploy vault`, which also sets up OpenBao's
identities and policies from the PC through its API;
[ansible/playbooks/openbao-config.yml](ansible/playbooks/openbao-config.yml)
configures its engines from ansible-control, see *Who configures OpenBao* in
[Where secrets and certificates come from](#where-secrets-and-certificates-come-from)):

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

The four Ubuntu VMs also get, from Vagrant's provisioning
([provision/](provision/), only what must exist before Ansible can reach a VM):

- user `ansible` with passwordless sudo, which logs in only with an SSH
  certificate from a lab SSH CA, and only from the jump host or ansible-control
- their own SSH host keys, published to the PC through Hyper-V; right after
  provisioning, `lab.ps1 up` installs a host certificate signed for exactly
  that key (`Update-LabVmHostCertificates` in `LabSsh.ps1`)

and then from [ansible/playbooks/base.yml](ansible/playbooks/base.yml)
(profile `base`, run from ansible-control by `lab.ps1 up`):

- zsh with fzf history search (Ctrl+R) and the alias `ll`, with no blue colours,
  because blue is unreadable on the blue background of Windows PowerShell
  (`/etc/zsh/zshrc.lab`, which Ansible owns and overwrites; a user's own
  `~/.zshrc` only has to source it, and is otherwise left to the user)
- console autologin on tty1 ("Connect" in Hyper-V Manager opens a shell
  without asking for a password), except on vault

The vault VM differs in two settings from `config/lab.json`: `"checkpoints":
false` switches Hyper-V checkpoints off for it (the Vagrantfile), and
`"consoleAutologin": false` keeps the normal login prompt on its console
(`base.yml`). The reason is the same for both:
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
`.\lab.ps1 secret -Pc opnsense/root-password` copies the GUI
password to the clipboard. Its console in Hyper-V Manager asks for a login.

### What is allowed where

The firewall rules are in
[opnsense/config.xml.template](opnsense/config.xml.template): the filter rules in
the `<OPNsense><Firewall><Filter>` section. The virtual IPs and the port forwards
are generated by `lab.ps1 firewall` from `published` in
[config/lab.json](config/lab.json) and inserted at the placeholders
`<!--{{VIRTUAL_IPS}}-->` and `<!--{{PORT_FORWARDS}}-->`. In the GUI you find
them under Firewall > Rules, Interfaces > Virtual IPs and Firewall > NAT >
Destination NAT (OPNsense 26.7's page for port forwards; older OPNsense versions
and most tutorials call it Port Forward). Outbound NAT is under Firewall > NAT >
Source NAT. The rules pf actually runs are shown by
`.\lab.ps1 connect firewall 'sudo pfctl -sr'`.

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
the checks at the end of `lab.ps1 deploy vault` show; the full port check was not
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
`root`; `.\lab.ps1 secret -Pc opnsense/root-password` copies the
password to the clipboard, and the console window's Clipboard > Type clipboard
text types it), which no firewall rule can block, or a rebuild from the repository
(`.\lab.ps1 firewall -Rebuild`). Enterprise equivalent: management
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
  and `lib\LabPki.ps1` for the offline root CA, which signs the intermediate
  CA, OpenBao's certificate and a new firewall's first GUI certificate. The
  firewall build also uses its bzip2 (unpacking the image). Both scripts stop
  with a hint if a tool is missing.
- **Windows OpenSSH client** (`ssh`, `scp`, `ssh-keygen`, `ssh-keyscan`),
  `tar.exe` and `curl.exe`. All are part of current Windows 10/11. The lab was
  developed with OpenSSH 8.1. The scripts call `ssh-keygen` and `ssh-keyscan`
  by their path in `C:\Windows\System32\OpenSSH`, and the Vagrantfile names
  that `ssh.exe` in its proxy command: Vagrant and Git for Windows bring
  OpenSSH clients of their own, and the lab is tested with Windows' one.
- **An elevated PowerShell** ("Run as administrator") for everything that
  manages Hyper-V or Windows networking: `lab.ps1 host-setup`,
  `lab.ps1 up`, `lab.ps1 firewall`, `lab.ps1 down` and `vagrant`
  itself. (`lab.ps1 up` on
  its own would also accept membership in the local group "Hyper-V
  Administrators", but the firewall build it calls needs a real elevated shell,
  because of Hyper-V and the VM's serial console pipe; reading the VMs' SSH host
  keys from Hyper-V needs it too.)
  `lab.ps1 connect`, `lab.ps1 run`, `lab.ps1 trust`,
  `lab.ps1 deploy vault`, `lab.ps1 recovery`, `lab.ps1 deploy firewall`,
  `lab.ps1 deploy keycloak`, `lab.ps1 deploy matrix`, `lab.ps1 deploy all`,
  `lab.ps1 maintain`, `lab.ps1 mdad-upgrade`, `lab.ps1 secret`, `lab.ps1 ui`,
  `lab.ps1 unseal`, `lab.ps1 backup` and
  `lab.ps1 ssh-cert` need no administrator rights. The scripts are
  written for Windows PowerShell 5.1, the version built into Windows.
- **One Windows account for everything.** The secrets on the PC are encrypted
  with DPAPI for the Windows account that created them, and only that account
  can decrypt them. "Run as administrator" keeps your account when it is itself
  a member of the Administrators group, so elevated and normal windows share
  the secrets. If elevation asks for the credentials of a different account,
  the secrets created there belong to that account, and your normal windows
  cannot read them.
- **Storage**: by default everything large goes to `G:\Vagrant`. Without a G:
  drive, pass `-StorageRoot`, e.g. `.\lab.ps1 up -StorageRoot D:\Vagrant`.
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
  upgrade MDAD (`lab.ps1 mdad-upgrade` fetches MDAD and its roles from there);
  a deployment takes them from the repository.
- **Free address ranges**: your home network must not already use 10.10.10.0/24
  or 10.10.99.0/24.
- **A browser on the PC**: Edge or Chrome (they use the Windows certificate
  store directly; Firefox needs one setting, see Step 4). For the call test you
  need two separate browser profiles, see Step 8.
- **For the recovery kit** (Step 5): a password manager (or paper) for one
  OpenBao key share, and a place for the recovery file that does not depend on
  this PC alone, such as a NAS share or a USB stick (copies of OpenBao's
  snapshots can go there too: `.\lab.ps1 backup -Destination <folder>`).
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

Every step but the browser test is one command of `.\lab.ps1`, the lab's single
entry point.
`.\lab.ps1 help` lists the commands (and prints the order below in one line),
`.\lab.ps1 help <command>` explains one, and `.\lab.ps1 status` shows at any
time what is running, what is due and the next step; it changes nothing.

The order for a new lab:

| Step | Command | What it does / who runs it | Time |
|---|---|---|---|
| 1 | `.\lab.ps1 host-setup` | creates the host network and the DNS rule; you, once per PC (changes Windows) | seconds |
| 2 | `.\lab.ps1 up` | builds the firewall (and with it the offline root CA) and the Ubuntu VMs | the first run takes longest: it downloads the Vagrant box and the OPNsense image and provisions four VMs; the firewall build alone takes about 4 minutes |
| 3 | `.\lab.ps1 deploy vault` | deploys OpenBao on the vault VM: secrets manager and intermediate CA | a few minutes on the first run (not timed exactly) |
| 4 | `.\lab.ps1 trust` | makes Windows trust the lab's root CA; you, once per PC (changes Windows) | seconds |
| 5 | `.\lab.ps1 recovery -Destination <folder>` | hands you OpenBao key share C and writes the encrypted recovery file (key share B, a break-glass login for OpenBao, the root CA, the offline SSH CA, the firewall's passwords); you, once, in a console window you type into yourself (it shows secrets) | a few minutes |
| 5a | `.\lab.ps1 deploy firewall` | moves the firewall's web GUI certificate from the offline root to OpenBao's intermediate CA (`lab.ps1 up` does it too, when it is due) | not timed yet |
| 6 | `.\lab.ps1 deploy keycloak` | deploys Keycloak, the identity provider | about 1 minute on the first run |
| 7 | `.\lab.ps1 deploy matrix` | deploys the Matrix stack, the chat | about 5 minutes |
| 8 | Browser test: sign in, chat, call | manual test, by you | a few minutes |

Steps 5a, 6 and 7 can also be one command: `.\lab.ps1 deploy all` runs
`deploy vault`, `deploy firewall`, `deploy keycloak` and `deploy matrix`, in this
order, and stops at the first failure. Running `deploy vault` again there is
harmless: each of its steps checks first and acts only if needed. So the
short form of the whole first build is: `host-setup` (your own window) -> `up` ->
`deploy vault` -> `trust` (your own window) -> `recovery` (your own window) ->
`deploy all`.

Steps 1, 4 and 5 are yours on purpose: Steps 1 and 4 change Windows settings
(networking, trusted certificates), and Step 5 shows secrets on the screen. They
run in the same PowerShell window as the others, as long as it is a window you
type into yourself, not another program's. `lab.ps1` enforces this: it refuses
`host-setup`, `trust` and `recovery` (exit code 2, before anything is changed)
when their input or output is redirected (a log file, a tool, an AI
assistant's shell).

### Step 1: create the host network (once, you run it yourself)

```powershell
.\lab.ps1 host-setup
```

This changes Windows network settings, so it is a separate script that you run
on purpose. It:

1. creates the Internal Hyper-V switch `LabHost` (Windows gets the adapter
   `vEthernet (LabHost)`)
2. gives that adapter the fixed IP `10.10.99.1/24`, with no gateway, so your
   internet connection and home network stay unchanged
3. adds an NRPT rule so Windows asks `10.10.99.2` (the firewall) only for
   `lab.internal` and the names below it

Undo everything with `.\lab.ps1 host-setup -Remove`.

### Step 2: build the lab

```powershell
.\lab.ps1 up
```

Without a G: drive, name another folder:
`.\lab.ps1 up -StorageRoot D:\Vagrant`.

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
   ([scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1); it also repairs the
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
   runs [scripts/commands/firewall.ps1](scripts/commands/firewall.ps1).
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
     ([scripts/lib/LabPki.ps1](scripts/lib/LabPki.ps1)), and has it sign
     the GUI certificate for `firewall.lab.internal`. The firewall is built
     before OpenBao exists, so the root signs this certificate itself. The root
     signs only this first certificate of a new firewall (again after a
     rebuild); its successors come from OpenBao's intermediate CA (Step 5a)
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
   - waits until the web GUI answers on port 443 (it starts after SSH) and
     checks the certificate it serves from the PC: its chain must end at the
     lab root, it must name `firewall.lab.internal` and have more than 30 days
     left. This step only reports; it never renews the certificate. If the
     check fails, it warns and names the command that renews it,
     `.\lab.ps1 deploy firewall` (Step 5a). Renewing is a job for Ansible on
     ansible-control, with a key made on the firewall and OpenBao's
     intermediate CA, not for the PC and the offline root

   If the firewall already exists, nothing is rebuilt: a seed ISO left behind
   (the script was killed during the first boot, or deleting it failed) is
   removed, the firewall is started (if it is off), its SSH setup is applied
   again (a new host certificate when the current one is due, the sshd drop-in,
   the SSH CAs that user `ansible` accepts),
   the DNS drop-in is installed again, it is updated only if a part of
   OPNsense is still below 26.7.7, and the GUI certificate is checked (renewed,
   when it is due, by step 7 below). Either way the script ends with DNS checks
   from the PC:
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
   Ansible and an SSH key of its own on the control node). Vagrant's
   provisioning does only this bootstrap, what must exist before Ansible on
   ansible-control can reach a VM; everything else is configuration management
   with Ansible (step 6 and the deployments). Then every VM gets its SSH host
   certificate: signed for exactly the host key the VM published, and installed
   over a connection that accepts only that key. If OpenBao was
   initialised before (a re-run, for example after a Windows restart), it is
   unsealed now with `lab.ps1 unseal`, unless step 4 has done that already;
   on a new lab that comes in Step 3.
   If OpenBao's TLS certificate has fewer than 30 days left, or has already
   expired (after weeks without a run), the script runs `lab.ps1 deploy vault`
   instead: the pinned TLS check would refuse an expired certificate, so the
   unseal itself would fail, and `lab.ps1 deploy vault` renews the certificate
   over SSH first and then unseals.
6. **Checks and base setup**: DNS from the PC, SSH to every VM with the PC's
   certificate, checking every host certificate (the firewall answers with its
   OPNsense version). Then two Ansible runs on ansible-control, each with a
   fresh copy of `ansible\` and an SSH certificate for this run only
   ([scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1), profiles in
   [config/run-profiles.json](config/run-profiles.json)):
   [ansible/playbooks/base.yml](ansible/playbooks/base.yml) gives every Ubuntu
   VM its shared base, zsh with fzf history search and plugins
   (`/etc/zsh/zshrc.lab`) and the console autologin (not on vault:
   `"consoleAutologin": false` in `config/lab.json`); then
   [ansible/playbooks/checks.yml](ansible/playbooks/checks.yml) checks, read-only,
   that ansible-control reaches and manages every machine, the firewall
   included, with its own key and the run's certificate (DNS name, host
   certificate, Python, sudo), that sshd runs with the lab's settings
   everywhere, and that the firewall's bootstrap contract is in place (OPNsense
   version, DNS drop-in, sshd limited to the jump host job). On new VMs,
   Ansible warns once per VM:
   `[WARNING]: Module remote_tmp /root/.ansible/tmp did not exist and was created with a mode of 0700, ...`.
   It appears because pipelining is on (see
   [Where secrets and certificates come from](#where-secrets-and-certificates-come-from)
   and [P48](#p48-ansible-warns-that-it-created-rootansibletmp)),
   and it is harmless: the folder belongs to root, the user the playbooks
   switch to with sudo, and nobody else needs it.
7. **Maintenance**, only once OpenBao has been deployed (so not yet on a new
   lab): renewals that are due. `Get-LabMaintenanceDue` in
   [scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1) checks, from public
   information only (no login): OpenBao's TLS certificate (due 30 days before
   it expires), the root CA's revocation list (60 days before its next update,
   and also when the copy the vault VM serves differs from the PC's:
   `lib\LabPki.ps1` also renews the list whenever it signs something and the
   list has fewer than 60 days left, a new firewall's first GUI certificate for
   example, but only `lab.ps1 deploy vault` publishes it), the
   intermediate CA (400 days before it expires), the firewall's GUI
   certificate (30 days before it expires, and also when it was not issued by
   OpenBao's current intermediate: its authority key identifier is compared
   with the intermediate's subject key identifier, so a new firewall's
   certificate from the root, or one from an intermediate before a rotation,
   is due at once) and Keycloak's certificate (30 days). For each one it prints
   `Maintenance: <what> is due -> .\lab.ps1 <command>` and then runs each of
   these commands once, `lab.ps1 deploy vault`, `lab.ps1 deploy firewall`
   and/or `lab.ps1 deploy keycloak`; otherwise
   `Maintenance: no certificate or revocation list is due`. Traefik renews the
   Matrix certificates itself. The same check and renewal can be run on their
   own with `.\lab.ps1 maintain` (`-List` only shows what is due).

Once OpenBao signs the SSH certificates, a vault VM that does not come up stops
the script with the reason and the ways out: the offline SSH CA does not take
over by itself, so that blocking OpenBao never moves signing out of its audit
log. If OpenBao is really broken, `.\lab.ps1 breakglass up`
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
Certificate: firewall.lab.internal valid (chain to the lab root CA, more than 30 days left)
Check:       firewall.lab.internal -> 10.10.99.2 (PC view)
Check:       matrix.lab.internal -> 10.10.99.3 (PC view, published)
Check:       keycloak.lab.internal -> 10.10.99.4 (PC view, published)
Check:       vault.lab.internal -> 10.10.99.5 (PC view, published)
Firewall ready: https://firewall.lab.internal (user root; password to the clipboard: .\lab.ps1 secret -Pc opnsense/root-password)
```

The GUI user is `root`. Its password is generated once, stored with DPAPI, and
stays the same when the firewall is rebuilt;
`.\lab.ps1 secret -Pc opnsense/root-password` copies it to the
clipboard (this works from now on: it reads the PC's DPAPI store, not OpenBao).

The whole run succeeded when it prints an `SSH ok: ...` line for each of the
five VMs, then two `PLAY RECAP`s, of `base.yml` (ansible-control, keycloak,
matrix and vault) and of `checks.yml` (the same four and the firewall), in
which every machine shows `unreachable=0` and `failed=0`, and finally:

```
Done. Log in with:  .\lab.ps1 connect  (or: .\lab.ps1 connect matrix / keycloak / vault / firewall)
Next: .\lab.ps1 deploy vault (OpenBao), .\lab.ps1 trust (once per PC), .\lab.ps1 recovery (in your own window),
      then .\lab.ps1 deploy keycloak and .\lab.ps1 deploy matrix (Element: https://element.lab.internal)
```

The two `Next:` lines appear only while OpenBao has not been deployed; on later
runs step 7 comes before `Done.` instead. (They name `deploy keycloak` and
`deploy matrix` separately; `.\lab.ps1 deploy all` does both, and Step 5a, in
one command.) At this point the VMs are ready but
empty: OpenBao comes in Step 3, the applications in Steps 6 and 7.

### Step 3: deploy OpenBao (secrets and certificates)

```powershell
.\lab.ps1 deploy vault
```

OpenBao is the open source fork of HashiCorp Vault, maintained under the Linux
Foundation with the MPL 2.0 licence (Vault itself has been under the Business
Source License since 2023). In this lab it is the secrets manager and runs the
intermediate certificate authority, so every later step depends on it: Keycloak
and the Matrix stack get their secrets and their certificates from it. The
script runs on your PC as your user (no administrator rights needed); it talks
to the vault VM over SSH and to OpenBao's API over HTTPS, and it starts the
Ansible runs `openbao.yml` and `openbao-config.yml` on ansible-control
([scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1), `Invoke-LabVaultDeploy`).
It runs eight steps, each of which checks first and then acts only if needed:

1. **Offline root CA**: created if it is missing (normally the firewall build
   has done that in Step 2); its revocation list is renewed when fewer than
   60 days are left ([scripts/lib/LabPki.ps1](scripts/lib/LabPki.ps1)).
2. **OpenBao's own TLS certificate** for `vault.lab.internal`: the key and a CSR
   are made on the vault VM, the root signs the CSR on the PC (397 days), and
   the certificate goes back. The key never leaves the VM. On later runs the
   certificate is renewed the same way when fewer than 30 days are left, and
   the script reloads OpenBao (`systemctl reload`): it reads the new
   certificate without a restart, so it stays unsealed.
3. **Package and configuration**:
   [ansible/playbooks/openbao.yml](ansible/playbooks/openbao.yml), run on
   ansible-control with an SSH certificate for the vault VM only (profile
   `openbao`), installs
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
6. **Configuration**, applied again on every run, so the code stays the
   description of the truth. It is split into two planes with different owners
   (line `== 6/8 Configuration: identities and policies (PC), engines
   (Ansible), intermediate CA (PC) ==`), in this order:
   - **Identity plane, from the PC through the API** (who may do what): one
     access policy per consumer, read from the files in
     [config/openbao/policies](config/openbao/policies) (the file name is the
     policy's name), the AppRoles (logins for machines) `pc-admin`
     and `pc-deploy` for the PC's scripts (credentials stored with DPAPI; a
     missing one gets a new secret, and once that is stored, every older secret
     of that role is destroyed), the break-glass AppRole `recovery` (administrator rights like
     `pc-admin`, but its secret exists only in the recovery file of Step 5), all
     three accepted only from 10.10.99.1, and the token roles `ansible-run`
     (the run tokens of the deployments, at most 2 hours, minted with
     `pc-deploy`), `ansible-config` (the run token of the configuration plane,
     at most 30 minutes, minted with `pc-admin`; until step 7 ends the
     bootstrap, with the initial root token) and `ui-admin`
     (`lab.ps1 ui`).
   - **Configuration plane, by Ansible on ansible-control**:
     [ansible/playbooks/openbao-config.yml](ansible/playbooks/openbao-config.yml)
     (profile `openbao-config`, with a token of the role `ansible-config` for
     this run only) writes the engines and how they behave, with the desired
     values from
     [ansible/playbooks/vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml):
     the secrets engine `lab` (key/value, every write must name the version it
     expects), password policies (OpenBao generates the lab's passwords: letters
     and digits, 24 to 64 characters), the intermediate's mount `pki_int`, its
     CRL, its tidying and the URLs it writes into every certificate, and, once
     an intermediate CA exists, the PKI roles `keycloak`, `acme-matrix`,
     `firewall-gui` and `web` and ACME for the role `acme-matrix` only. Each
     object is read, compared and written only when a value differs (a second
     run reports `changed=0`); nothing is ever deleted. Its token cannot write a
     policy, a login or a CA, so this plane cannot hand out rights.
   - **The intermediate CA, from the PC**: key generated inside OpenBao,
     certificate signed by the offline root on the PC, imported and made the
     default issuer; on an empty OpenBao it is named `lab-int-<year>`,
     "DeployableServer Lab Intermediate CA <year>".
   - **`openbao-config.yml` once more, on a new OpenBao only**: its first run
     found no intermediate CA yet, so the PKI roles and ACME follow now (line
     `PKI: the new intermediate CA can sign: openbao-config.yml again, for the
     PKI roles and ACME`).
   - **SSH, from the PC**: the
     SSH secrets engine `ssh`: an SSH CA whose key is generated inside OpenBao
     (once; it is never replaced by a re-run) and the roles `pc`,
     `ansible-control` and `lab-hosts`, made from the same table the offline SSH
     CA uses (`$LabSshRoles` in [scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1)).

   Why two planes: who may log in, and with which rights, stays with the PC,
   which holds the administrator login and the offline root; how the engines
   behave is ordinary configuration management with a narrow token that lives
   for one run, and `.\lab.ps1 run openbao-config --check --diff` shows any
   drift between OpenBao and the repository. The enterprise equivalent is in
   *Who configures OpenBao* in
   [Where secrets and certificates come from](#where-secrets-and-certificates-come-from).
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
`keys\pki\root-ca.crt`, whatever else Windows trusts, and only when the root
signed it directly (a chain of exactly two: the certificate and the root). A
certificate for `vault.lab.internal` from OpenBao's own intermediate CA is
refused: otherwise whoever could get one issued, for example by changing a PKI
role, which the configuration plane may do, could pose as OpenBao to the PC,
which sends it unseal key shares and AppRole logins. That is why this step
works before Windows trusts the lab root (Step 4). Every other HTTPS address
keeps Windows' normal validation. Why and how:
[Internal PKI](#internal-pki-certificate-authority).

The checks of what clients use are split the same way: `openbao-config.yml`
checks that the intermediate CA's certificate is served and that the ACME
directory
(`https://vault.lab.internal:8200/v1/pki_int/roles/acme-matrix/acme/directory`)
answers, and the PC checks the root CRL on port 80. A successful first run ends
with:

```
Check:       root CRL served on port 80

OpenBao is ready:  https://vault.lab.internal:8200/ui/
PENDING: key share C and the recovery file. Run in your own PowerShell window:  .\lab.ps1 recovery
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
intermediate CA when the current one expires within 400 days. `lab.ps1 up`
starts it by itself when one of these is due (its step 7). To make a new
intermediate now, for example to try the rotation described in
[Rotate the intermediate CA](#rotate-the-intermediate-ca):

```powershell
.\lab.ps1 deploy vault -RotateIntermediate
```

Its `PKI:` line then reads `intermediate CA created in OpenBao, signed by the
offline root (...)`. Afterwards run `lab.ps1 deploy firewall`,
`lab.ps1 deploy keycloak` and `lab.ps1 deploy matrix` (or
`lab.ps1 deploy all`), which move their certificates to the new intermediate.

**OpenBao is sealed after every start of the vault VM.** Its data stays
encrypted, and it does not know the key until two key shares are presented
again. `lab.ps1 up` (for example after a Windows restart) and
`lab.ps1 run` (before a playbook that needs OpenBao) unseal it by
themselves with shares A and B; by hand it is `.\lab.ps1 unseal`.
While it is sealed, nothing that needs it works: deployments, Traefik's
certificate renewals, and the intermediate CA's revocation list on port 80.

On a lab whose vault VM was rebuilt, the script refuses to initialise the new
OpenBao while `keys\openbao` still holds the key shares of the old one: they may
be the only way to restore a snapshot of it. `lab.ps1 down` takes a last
snapshot before it deletes the vault VM, then moves `keys\openbao` (key shares,
logins and snapshots) to `keys\openbao-retired-<yyyyMMdd-HHmmss>` (details in
[Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)). How a
snapshot is restored:
[Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).

### Step 4: trust the lab root CA (once, you run it yourself)

```powershell
.\lab.ps1 trust
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
.\lab.ps1 trust -RemoveRetired
```

On a new lab there is nothing to remove.

Do this before Step 8 and before `.\lab.ps1 test`: the browser, `curl.exe` and
the tests' view of the lab's HTTPS addresses
([tests/Test-LabCertificates.ps1](tests/Test-LabCertificates.ps1)) use the
Windows certificate store. The deployments themselves do not depend on it:
their checks run on ansible-control and the lab VMs, which get the lab root in
their own trust stores from the playbooks, and the PC reaches OpenBao through
the pinned check of Step 3. Windows also checks
revocation for these certificates: every lab certificate names the revocation
list (CRL) of its CA on `http://vault.lab.internal/...`, so `curl.exe` works
with lab sites without `--ssl-no-revoke`.

The firewall's web GUI is now at <https://firewall.lab.internal>. Log in as
`root`; `.\lab.ps1 secret -Pc opnsense/root-password` copies the
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
.\lab.ps1 recovery -Destination Z:\DeployableServer-recovery
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
and `lab.ps1 deploy vault` reminds you with its `PENDING` line. The script has
three more modes, for later:

| Command | When | What it does |
|---|---|---|
| `.\lab.ps1 recovery -Renew -Destination <folder>` | a new recovery file: after a `-Recover`, for a new passphrase, or when the file is lost | the same as above without steps 1 and 5: a new file with a new break-glass secret. Your share C stays valid and is not shown again. Older files can still unseal, but their break-glass login no longer works: keep only the new one |
| `.\lab.ps1 recovery -Open <file>` | to read the file | asks for the passphrase and shows share B, the root CA key's passphrase and the firewall's root password (the root CA files, the offline SSH CA, the break-glass login and the firewall's other secrets stay in the file, for `-Recover`) |
| `.\lab.ps1 recovery -Recover <file>` | after this PC's DPAPI keys were lost, in the same project folder | asks for share C, restores this PC's DPAPI secrets (and the root CA's and the offline SSH CA's files if missing), unseals OpenBao with B and C if needed and, with the break-glass login, issues NEW logins `pc-admin` and `pc-deploy`, so the scripts and `lab.ps1 unseal` work again; step by step in [Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys). Then run `-Renew`: the break-glass secret has been used. (A file made before the break-glass login existed can only unseal) |

To unseal without restoring anything, `.\lab.ps1 unseal -Interactive`
asks for two key shares that you type in (B from `-Open`, and C). The concept
behind the kit is explained in
[Break-glass: the recovery kit](#break-glass-the-recovery-kit); restoring
OpenBao's data from a snapshot is a different procedure, in
[Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).

### Step 5a: move the firewall's GUI certificate to OpenBao

```powershell
.\lab.ps1 deploy firewall
```

The firewall was built in Step 2, before OpenBao existed, so its web GUI still
serves the certificate that the offline root signed for it. From now on it is
an ordinary server certificate, like Keycloak's, and comes from OpenBao's
intermediate CA. The command runs
[ansible/playbooks/firewall.yml](ansible/playbooks/firewall.yml) on
ansible-control (profile `firewall`: an SSH certificate for the firewall only,
and a run token for the policy `ansible-firewall`, which may only have
certificates signed through the PKI role `firewall-gui`). The playbook:

1. reads, from ansible-control, the certificate the web GUI serves, and makes a
   new one only when that expires within 30 days, was not issued by OpenBao's
   current intermediate (its authority key identifier is compared with the
   intermediate's subject key identifier) or does not name
   `firewall.lab.internal`. It prints the reason; on a new lab that is
   `issued by DeployableServer Lab Root CA 2026, not by the current intermediate`.
   Otherwise nothing changes (`changed=0`);
2. has the firewall make the new key and the CSR itself (its own `openssl`, in
   a private temporary folder, with `umask 077`); only the CSR travels, and
   OpenBao signs it, called from ansible-control (role `firewall-gui`, valid for
   1 year);
3. puts the key, the certificate and the intermediate CA into OPNsense's
   configuration with [opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php),
   as code what System > Trust in the GUI does: OPNsense keeps its
   configuration in `/conf/config.xml` and regenerates its files from it, so a
   certificate file written by hand would not last. The intermediate gets a CA
   entry of its own, linked to the root's, and intermediates that nothing uses
   any more are removed. Then the web GUI restarts, the temporary folder (with
   the key) is deleted, and the playbook waits until the GUI serves the new
   certificate. The GUI now sends the chain certificate, intermediate, root.

Why: the fewer signatures the offline root makes, the more rarely its key is
unlocked. From now on it signs only CAs (the intermediate), OpenBao's own TLS
certificate and the first GUI certificate of a newly built firewall.
Enterprise equivalent: an appliance's certificate is enrolled from the issuing
CA (ACME, SCEP or an automation job like this one), never from the root.

You do not have to remember this step: `.\lab.ps1 deploy all` includes it, and
if it was skipped, the maintenance step of `lab.ps1 up` (its step 7) finds the
certificate due and runs it. The same holds after a rotation of the
intermediate or a rebuild of the firewall. `lab.ps1 firewall` only reports on
the certificate, and the tests (`.\lab.ps1 test`) expect it from the
intermediate. `.\lab.ps1 run firewall --check` shows whether a new one is due,
without changing anything; `.\lab.ps1 run firewall -e firewall_gui_renew_before=+400d`
makes one now.

### Step 6: deploy Keycloak (the identity provider)

```powershell
.\lab.ps1 deploy keycloak
```

It needs OpenBao (Step 3). It runs
[ansible/playbooks/keycloak.yml](ansible/playbooks/keycloak.yml) on
ansible-control, the same run as `.\lab.ps1 run keycloak` (profile `keycloak`:
an SSH certificate for the keycloak VM only), with a run token for the
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
([scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1), into
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
  .\lab.ps1 secret keycloak/users/alice     (keycloak/users/bob, keycloak/admin)
```

If the run fails, the script stops with Ansible's error for the failing task;
the usual causes are described in
[P23](#p23-a-task-keyword-between-module-parameters-breaks-the-task) to
[P26](#p26-the-same-image-tag-suddenly-means-a-different-image). A failed read
from OpenBao names the secret's path and the HTTP status: 503 means OpenBao is
sealed (`.\lab.ps1 unseal`), 403 that the run token lacks the
policy or has expired. A secret that exists but lacks the expected field (for
example one written by hand under another field name) is named with its path
and the field. Fix the cause and run the same script again: it is idempotent,
and a failed run loses nothing, because every generated secret is stored in
OpenBao before anything uses it. If the snapshot fails, the script only warns
(`OpenBao snapshot failed: ...`); take one later with
`.\lab.ps1 backup`.

### Step 7: deploy the Matrix stack

```powershell
.\lab.ps1 deploy matrix
```

It needs OpenBao (Step 3) and Keycloak (Step 6): MAS signs users in through
Keycloak with the client secret that Keycloak's deployment stored in OpenBao.
The script ([scripts/commands/deploy.ps1](scripts/commands/deploy.ps1)) checks
the pinned MDAD version, then starts two runs on ansible-control (lines
`== Matrix 1/2 ...` and `== Matrix 2/2 ...`), both with an SSH certificate for
the matrix VM only and a run token for the policy `ansible-matrix`:

1. **The pinned MDAD version**: MDAD's code and its roles are
   kept in the repository at the pinned commit (`vendor\mdad`, see
   [vendor/README.md](vendor/README.md)). The script stops here, before
   anything is copied, when the commit in
   `vendor\mdad\.lab-vendored-commit` and `mdad_version` in `matrix-prepare.yml`
   differ, so the configuration can
   never meet another MDAD version than the one it was written for.
2. **MDAD from the repository, and the preparation** (profile
   `matrix-prepare`, line `== Matrix 1/2: MDAD <commit> to ~/mdad, CA trust,
   checks, inventory, secrets (matrix-prepare.yml) ==`). This run carries
   `vendor\mdad` too: the PC packs it with `tar` and copies it to
   ansible-control with `scp`, next to the fresh copy of `ansible\`, and
   [ansible/bin/lab-run](ansible/bin/lab-run) unpacks it into `~/mdad.new` and
   replaces `~/mdad` with it, the same pattern as for `~/lab`. Nothing is
   downloaded from GitHub. Then
   [ansible/playbooks/matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml)
   runs: the lab root CA in the
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
   OpenBao (`lab.ps1 backup`, line `Snapshot: ...`): on a first run the
   Matrix secrets have just been generated, and OpenBao is the only place they
   exist.
3. **MDAD** (profile `matrix`, line `== Matrix 2/2: MDAD, its self-check,
   mas-cli doctor and matrix-check.yml ... ==`):
   [ansible/bin/deploy-matrix](ansible/bin/deploy-matrix) on ansible-control,
   with a new run token, runs MDAD
   through [ansible/matrix/lab-setup.yml](ansible/matrix/lab-setup.yml)
   in `~/mdad`. MDAD expects its
   secrets as inventory variables; `lab-setup.yml` reads them from OpenBao into
   memory first and then runs MDAD's own `setup.yml`, so they are never written
   to disk on ansible-control (MDAD's own `ansible.cfg` switches pipelining on
   too, and `openbao-run`'s RAM folder applies here as well). It is called with
   the tags of MDAD's recipe `just install-all` (`just` is a command runner,
   similar to `make`; MDAD's `justfile`, in `vendor\mdad`, turns that recipe
   into `ansible-playbook -i inventory/hosts setup.yml --tags=install-all,ensure-matrix-users-created,start`).
   `bin/deploy-matrix` runs that command itself, with `lab-setup.yml` in place
   of `setup.yml`, so `just` is not installed in the lab. With `-Setup`
   (profile `matrix-setup`) it uses
   the tags of `just setup-all`, which also runs the uninstall tasks of
   components you switched off, and is slower. MDAD installs Docker on the
   matrix VM, pulls the images, writes all configuration, creates the systemd
   units `matrix-*.service` and starts them. Traefik then orders its
   certificates from OpenBao through ACME by itself.
4. **Checks**, in the same run, by `bin/deploy-matrix`: MDAD's self-check and
   `mas-cli doctor` (it only reports), then
   [ansible/playbooks/matrix-check.yml](ansible/playbooks/matrix-check.yml) on
   ansible-control, whose three checks can fail the run: Traefik must serve a
   certificate from the
   current intermediate CA for each of the three names, compared by key
   identifier, not by name (it waits up to 3 minutes; until ACME has succeeded,
   Traefik answers with its own self-signed "TRAEFIK DEFAULT CERT"); Synapse's
   `https://matrix.lab.internal/_matrix/client/v1/auth_metadata` must name MAS
   (`https://matrix.lab.internal/auth/`) as issuer, and MAS's
   `/auth/upstream/authorize/<ULID>` must redirect to Keycloak. That redirect
   proves that the MAS container can resolve Keycloak, trusts the lab root CA
   and found the exact issuer. The checks run inside the lab, where
   ansible-control trusts the lab root CA by itself
   (`matrix-prepare.yml` put it into its trust store), so they need nothing of
   Windows. After this run too, also when it failed, the script takes a
   snapshot of OpenBao.

The Matrix secrets are in OpenBao from the moment they are generated, and in
the snapshot taken right after; the certificates' keys stay with Traefik on the
matrix VM (`/matrix/traefik/ssl/acme.json`). The chat's own data (rooms,
messages, files) has no backup yet. If a run fails, the script stops at the
failing task or check, with Ansible's error; the usual causes are
described in [P27](#p27-keycloak-answers-invalid-parameter-redirect_uri) to
[P31](#p31-mdad-cannot-create-matrix-users). Every step is idempotent, so the
same script is simply run again.

A run takes about five minutes. Two things in the output look alarming but are
expected: the self-check prints one `fatal ... 404` for
`/_matrix/federation/v1/version` and marks it `ignored` (federation is off, see
[P33](#p33-the-self-check-shows-a-fatal-404-for-_matrixfederationv1version)),
and `mas-cli doctor` may print warnings: it only reports, its exit code is
always 0 (see [P34](#p34-mas-cli-doctor-reports-problems-but-the-run-succeeds)).
A successful run ends with the result of `matrix-check.yml`, its `PLAY RECAP`,
the snapshot and one line from the PC (the snapshot's name and size differ, and
so does the intermediate's name: on a new lab it carries only the year,
"DeployableServer Lab Intermediate CA 2026"; this lab's current one was made on
2026-10-24). Ansible prints the result as JSON, hence the doubled backslash:

```
TASK [Result] ******************************************************************
ok: [ansible-control] => {
    "msg": [
        "Certificates from DeployableServer Lab Intermediate CA 2026-10-24 for matrix.lab.internal, element.lab.internal, lab.internal",
        "Synapse delegates login to MAS (https://matrix.lab.internal/auth/)",
        "MAS sends logins to Keycloak (https://keycloak.lab.internal/realms/lab/protocol/openid-connect/auth)",
        "Matrix is ready: https://element.lab.internal (homeserver https://matrix.lab.internal). Sign in through Keycloak as alice or bob; password to the clipboard: .\\lab.ps1 secret keycloak/users/alice"
    ]
}
...
Snapshot: C:\path\to\DeployableServer\keys\openbao\snapshots\vault-20261024-131502.snap (64 KB)
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
| Element (through Keycloak) | `alice`, `bob` | `.\lab.ps1 secret keycloak/users/alice` (or `keycloak/users/bob`) |
| Keycloak admin console <https://keycloak.lab.internal/admin/> | `admin` | `.\lab.ps1 secret keycloak/admin` |
| OPNsense GUI <https://firewall.lab.internal> | `root` | `.\lab.ps1 secret -Pc opnsense/root-password` |

`lab.ps1 secret` copies the value to the clipboard; paste it into the login
form. The first two read OpenBao, so it must be unsealed (after a Windows
restart, `lab.ps1 up` does that); the third reads the PC's DPAPI store.
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

### The lab.ps1 commands

Everything on the PC goes through one script in the project folder:
`.\lab.ps1 <command> [arguments]`. It checks the rights the command needs and hands every
further argument on unchanged to the script or library function behind it. The table of
commands is `$LabCommands` in [scripts/lib/Lab.ps1](scripts/lib/Lab.ps1), whose header also
explains which work stays on the PC (Hyper-V and Vagrant, DPAPI, the two offline CAs, OpenBao's
identities) and which is an Ansible run on ansible-control (everything else). Enterprise
equivalent: one command-line tool with subcommands, like `az`, `kubectl` or `gh`.

| Command | What it does | Needs |
|---|---|---|
| `help` | the list of commands; `help <command>` shows the full help of one | |
| `status` | what is running, what is due, and the next step; changes nothing | |
| `up` | build or start the lab and bring it up to date, also after every Windows restart ([After a Windows restart](#after-a-windows-restart)) | elevated |
| `down` | delete the lab VMs, or one (`down matrix`); asks first ([Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)) | elevated |
| `firewall` | build (`-Rebuild`) or check the OPNsense firewall VM | elevated |
| `deploy` | deploy `vault`, `firewall`, `keycloak`, `matrix`, or `all` (these four in this order, stopping at the first failure) ([Run a playbook, re-run a deployment](#run-a-playbook-re-run-a-deployment)) | |
| `run` | one Ansible run on ansible-control: `run <profile>` or `run <playbook.yml>`, then options for `ansible-playbook`; without arguments it lists the run profiles | |
| `maintain` | renew what is due (certificates, revocation lists); `-List` only shows it | |
| `connect` | SSH to a lab machine as `ansible`: `connect [vm] [command]` ([Log in to a VM](#log-in-to-a-vm)) | |
| `secret` | copy a secret to the clipboard (`secret keycloak/users/alice`, `secret -List`) ([Read a password or secret](#read-a-password-or-secret)) | |
| `ui` | open OpenBao's web UI with a 1-hour login token on the clipboard ([Open OpenBao's web UI](#open-openbaos-web-ui)) | |
| `unseal` | unseal OpenBao (`-Interactive`: type two key shares) ([OpenBao after a restart](#openbao-after-a-restart-sealed-and-unsealed)) | |
| `backup` | a snapshot of OpenBao's data to `keys\openbao\snapshots` ([Back up OpenBao](#back-up-openbao)) | |
| `ssh-cert` | renew this PC's 8-hour SSH certificate when it is due (`-Force`: now) and show which CA signed it | |
| `breakglass <command>` | run one command with the offline SSH CA allowed to sign, when OpenBao cannot (`breakglass up`) | what the command needs |
| `test` | run the tests (`-Name <test>`, `-IncludeStateChanging`) ([Run the tests](#run-the-tests)) | |
| `host-setup` | once per PC: the LabHost network and the DNS rule (NRPT) for the lab domain ([Step 1](#step-1-create-the-host-network-once-you-run-it-yourself)) | elevated, your own window |
| `trust` | let Windows trust the lab root CA (`-Remove`, `-RemoveRetired`) ([Step 4](#step-4-trust-the-lab-root-ca-once-you-run-it-yourself)) | your own window |
| `recovery` | the recovery kit (`-Renew`, `-Open <file>`, `-Recover <file>`) ([Step 5](#step-5-make-the-recovery-kit-once-you-run-it-yourself)) | your own window |
| `mdad-upgrade` | take a new matrix-docker-ansible-deploy commit into `vendor\mdad` ([Upgrade MDAD](#upgrade-mdad-and-with-it-the-matrix-components)) | |

An empty "Needs" means any PowerShell window, as your own Windows user, also with the output
redirected to a file.

- **Help.** `.\lab.ps1` alone, or `.\lab.ps1 help`, prints the commands in groups (Overview,
  Build, Deploy, Use, Your own window, Maintainer) and the order for the first time:
  `host-setup` (your own window), `up`, `deploy vault`, `trust` (your own window), `recovery`
  (your own window), `deploy all` ([4. Quick start](#4-quick-start)). `.\lab.ps1 help deploy`
  shows the full built-in help of one command, its parameters and examples: PowerShell reads it
  from the comment block of the command's script or function, so help and code live in the
  same file. `run`, `status` and `help` have no such block yet (for them it shows only the
  function's name and syntax), and `breakglass` prints its line of the overview.
- **Status.** `.\lab.ps1 status` only reads: the Hyper-V state of every VM (in an elevated
  window), whether OpenBao is reachable, sealed or unsealed and whether it signs the SSH
  certificates, until when the PC's SSH certificate is valid and which CA signed it, a pending
  recovery kit, and what the maintenance step would renew. Its last line names the next step,
  for example `Next: .\lab.ps1 up`, or `Next: nothing due`.
- **Tab completion.** The command names are a fixed list (a `ValidateSet` on lab.ps1's only
  parameter), so `.\lab.ps1 de` and Tab completes to `deploy`, and PowerShell itself refuses a
  name that is not in the list. lab.ps1 has no other parameter, so every option after the
  command (`-v`, `--check`, `-WhatIf`, `-Rebuild`) belongs to the command.
  [Test-LabLayout](#run-the-tests) checks that the list and the table name the same commands.
- **Elevated** commands drive Hyper-V and Vagrant: start PowerShell with "Run as
  administrator". In another window they are refused before anything changes.
- **Your own window**: these commands change Windows settings or show secrets, so they refuse to
  run when the input or output of the PowerShell process itself is redirected: in the shell of
  another program (an automation tool, an AI coding assistant), or started as
  `powershell -File .\lab.ps1 <command> > log` from another shell. Nothing secret then ends up in
  that program's transcript or log, and no Windows setting changes without you watching. A
  redirection inside your own window (`*> log`, a pipeline) is not detected, because the console
  itself is not redirected: do not use one with these commands.
  Enterprise equivalent: privileged actions that need the person at an interactive session (a
  just-in-time approval, an MFA prompt) instead of a service account.
- **Break-glass.** `.\lab.ps1 breakglass <command> [arguments]`, for example `breakglass up`,
  `breakglass connect vault` or `breakglass ssh-cert -Force`, runs one command with the offline
  SSH CA allowed to sign SSH certificates when OpenBao cannot (the vault VM is broken). It
  prints a red warning, allows it for that one command only and removes the permission again;
  certificates signed that way carry `breakglass` in their key ID (and are listed in
  `keys\ssh\issued.log` like every certificate). Without it, a failing OpenBao stops the
  command with the reason, so signing never moves outside OpenBao's audit log by accident
  ([SSH certificates](#ssh-certificates-user-and-host-cas)).
- **Exit codes**: 0 done; 1 the command failed (the reason is printed in red) or is unknown;
  2 refused before anything was changed (not elevated, not your own window, `breakglass`
  without a command). `run`, `connect` and `test` end with the exit code of what they ran:
  `ansible-playbook` or the profile's command (75: another run is active on ansible-control),
  `ssh` (255: the connection failed), the tests (1: a test failed). Scripts and schedulers can
  therefore rely on `$LASTEXITCODE`.

### Log in to a VM

```powershell
.\lab.ps1 connect                    # ansible-control (default)
.\lab.ps1 connect matrix
.\lab.ps1 connect keycloak
.\lab.ps1 connect vault              # OpenBao
.\lab.ps1 connect firewall           # OPNsense (FreeBSD), shell /bin/sh
.\lab.ps1 connect firewall 'sudo pfctl -sr'      # run one command: active pf filter rules
.\lab.ps1 connect firewall 'sudo pfctl -s nat'   # active NAT rules (port forwards, outbound NAT)
.\lab.ps1 connect firewall 'opnsense-version'    # installed OPNsense version
```

You log in as `ansible` with the PC's SSH certificate, and ssh checks the host
certificate of every machine on the way (the firewall's, then the VM's). The
script is a thin wrapper around `ssh -F keys\ssh_config <vm>`; the one thing it
adds is the renewal of the certificate: valid for 8 hours, it is renewed first
when fewer than 4 hours are left. Plain `ssh`/`scp` with that config file work
too, while the certificate is valid (`.\lab.ps1 ssh-cert`
renews it when it is due and shows which CA signed it and until when). No
administrator rights are needed. A command in single quotes runs on the VM;
avoid double quotes inside it (Windows PowerShell 5.1 does not pass them on
correctly, see [P11](#p11-windows-powershell-51-quirks)). If OpenBao cannot
sign a new certificate (the vault VM is broken),
`.\lab.ps1 breakglass connect <vm>` lets the offline SSH CA sign it
([SSH certificates](#ssh-certificates-user-and-host-cas)).

On the firewall you get FreeBSD's plain `/bin/sh`: zsh and console autologin are
set up only on the Ubuntu VMs (by `ansible/playbooks/base.yml`, which `lab.ps1 up` runs).
Use the shell to look, not to change things:
OPNsense regenerates its system files from its configuration file
`/conf/config.xml`, so a file edited by hand does not last (see
[An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)
and [P6](#p6-a-firewall-change-has-no-effect-or-is-gone-after-a-rebuild)). Changes
go through the web GUI (<https://firewall.lab.internal>, user `root`, password
with `.\lab.ps1 secret -Pc opnsense/root-password`, next section),
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

[scripts/commands/secret.ps1](scripts/commands/secret.ps1) reads one secret and
copies it to the clipboard, so you can paste it into a login form without it
ever appearing on screen:

```powershell
.\lab.ps1 secret keycloak/users/alice      # alice's password (Element login); bob: keycloak/users/bob
.\lab.ps1 secret keycloak/admin            # Keycloak admin console, user admin
.\lab.ps1 secret -Pc opnsense/root-password   # OPNsense GUI, user root (DPAPI on the PC)
.\lab.ps1 secret -List                     # names of all secrets (DPAPI first, then OpenBao), no values
.\lab.ps1 secret keycloak/admin -Show      # print the value instead of copying it
```

`-List` prints the PC's DPAPI names first, which need no OpenBao: they are also
listed while OpenBao is sealed or gone (it then warns that OpenBao cannot be
read). The other secrets in OpenBao are `keycloak/db`, `keycloak/clients/lab-ansible`,
`keycloak/clients/matrix-authentication-service`, `matrix/generic-secret-key`,
`matrix/postgres` and, only on a lab migrated from before OpenBao,
`matrix/legacy-users/*` (Synapse passwords from before MAS, imported once during that
migration, unused but kept). The path may also be given with a
leading `lab/`. Every
lab secret has a single field, so `-Field` is not needed.

How it works and why:

- The script logs in to OpenBao with the AppRole `pc-admin`, whose credentials
  are stored with DPAPI. OpenBao accepts that login only from your PC's address
  (10.10.99.1), and the token it hands out is revoked again when the script
  ends. So OpenBao must be unsealed (after a restart of the vault VM:
  `.\lab.ps1 unseal`); `-Pc` works without OpenBao.
- The connection to OpenBao is HTTPS with OpenBao's certificate **pinned** to
  the lab root ([Internal PKI](#internal-pki-certificate-authority)): a
  certificate from another CA that Windows happens to trust is refused, and the
  scripts work even before the root is imported into Windows. Only a certificate
  the root signed directly passes, so one for OpenBao's name from the lab's own
  intermediate CA is refused too: whoever could get such a certificate issued
  (by changing a PKI role, say) could otherwise pose as OpenBao to the PC, which
  sends it key shares and logins.
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
they can never change one. Their OpenBao policies
([config/openbao/policies](config/openbao/policies)) grant `create` and `read` on
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

Both are settings of the mount (`lab/config`), and like the password policies below they belong
to OpenBao's configuration plane:
[ansible/playbooks/vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml), applied
by `openbao-config.yml` (see
[Which change is applied by which command](#which-change-is-applied-by-which-command)).

There is no script for writing; the helper functions in
[scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1) do it in a few lines. The
pattern below writes a new secret or a new version of an existing one, with a
value generated by OpenBao from one of the lab's password policies (letters and
digits: `lab-alnum-24` for passwords people type, those of the users and of
Keycloak's `admin`; `lab-alnum-48` for Keycloak's other secrets; `lab-alnum-64`
for Matrix's). Replace the three values in the third line; the how-tos below
show it filled in. Nothing is printed:

```powershell
. .\scripts\lib\Lab.ps1                        # load the lab's libraries into this window
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
.\lab.ps1 ui
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
[scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1), applied by
`lab.ps1 deploy vault`):

| Property | Value | Why |
|---|---|---|
| policy | `openbao-admin` (everything) | to look at and change anything |
| lifetime | 1 hour at most, not renewable | a forgotten browser tab stops working by itself |
| usable from | only your PC (10.10.99.1) | a copied token is useless anywhere else |
| type | orphan | it outlives the short `pc-admin` login that created it |

"Sign out" (top right in the UI) revokes it at once. Every request appears in
OpenBao's audit log with the display name `token-ui`.

Careful with changes in the UI: they are not in the repository. A policy, role
or setting changed by hand is overwritten by the next `lab.ps1 deploy vault`
(which applies its configuration on every run: policies, AppRoles and token roles
in its own step 6 on the PC, the engines' settings such as the KV mount, password
policies, PKI roles, revocation list and ACME through `openbao-config.yml`, which
writes back every value it manages) or lost in a rebuild. A changed engine setting
shows up before that in `.\lab.ps1 run openbao-config --check --diff`, and
[Test-LabOpenBaoConfig](#run-the-tests) fails on it. An object the repository does
not name at all (a PKI role added by hand) is left alone, because that playbook
never deletes anything, but it is gone after a rebuild.
Secrets are the exception: they live only in OpenBao, so a value changed there
stays (see [Write or change a secret](#write-or-change-a-secret-administrator)).

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
.\lab.ps1 connect matrix 'systemctl list-units --type=service --no-pager | grep matrix-'
.\lab.ps1 connect matrix 'sudo journalctl -u matrix-synapse -n 100 --no-pager'
.\lab.ps1 connect matrix 'sudo journalctl -u matrix-authentication-service -n 100 --no-pager'
.\lab.ps1 connect matrix 'sudo journalctl -u matrix-livekit-server -f'    # follow; Ctrl+C ends
.\lab.ps1 connect matrix 'sudo systemctl restart matrix-authentication-service'
.\lab.ps1 connect matrix 'free -m'
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
.\lab.ps1 connect keycloak 'sudo docker compose --project-directory /opt/keycloak-stack ps'
.\lab.ps1 connect keycloak 'sudo docker compose --project-directory /opt/keycloak-stack logs --tail 100 keycloak'
.\lab.ps1 connect keycloak 'sudo docker compose --project-directory /opt/keycloak-stack logs --tail 100 postgres'
```

`ps` shows both containers with `(healthy)` when all is well. Keycloak's
health endpoint is only reachable on the VM itself:
`.\lab.ps1 connect keycloak 'curl -s http://127.0.0.1:9000/health/ready'`.
Users, sessions and the client are easiest to inspect in the admin console
(<https://keycloak.lab.internal/admin/>, realm `lab`). Sessions of a user:
Users > (user) > Sessions.

**OpenBao** (VM vault): the systemd service `openbao`, its configuration in
`/etc/openbao/openbao.hcl`, its data (integrated storage, "raft") in
`/opt/openbao/data`, and nginx on port 80 for the CA certificates and
revocation lists.

```powershell
.\lab.ps1 connect vault 'systemctl status openbao --no-pager'
.\lab.ps1 connect vault 'sudo journalctl -u openbao -n 100 --no-pager'
.\lab.ps1 connect vault 'sudo tail -n 3 /var/log/openbao/audit.log'   # one JSON line per request and response
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
`.\lab.ps1 trust`). `curl.exe` uses Windows' Schannel, which
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
need a deployed lab (OpenBao, Keycloak, Matrix); `Test-LabLayout` needs none. They run in
PowerShell from the project folder, print one `PASS` or `FAIL` line per check and never print
a secret:

```powershell
.\lab.ps1 test                               # all tests that change nothing, then a summary
.\lab.ps1 test -Name Test-LabCertificates    # only this test (file name without .ps1)
.\tests\Test-LabCertificates.ps1             # or one test directly
```

`.\lab.ps1 test` starts [tests/Invoke-LabTests.ps1](tests/Invoke-LabTests.ps1), which you may
also run directly with the same parameters. Without `-Name` it runs twelve tests:

- `Test-LabLayout` (no lab needed): lab.ps1's command list and the command table in
  `scripts\lib\Lab.ps1` agree and every command's script or function exists; every run profile
  names an existing playbook or script, valid SSH principals, existing OpenBao policies and a
  known token role; every playbook has a profile or is started by a script in `ansible\bin`
  (like `matrix-check.yml` by `bin/deploy-matrix`), and every policy file is used; no code names a
  script or function that no longer exists; every link in the READMEs resolves; and the
  dispatcher refuses what it should, with the right exit codes. The cheap first test after a
  rename.
- `Test-LabAnsible`: every playbook parses (profile `syntax`), `checks.yml` passes on every
  machine, and `base.yml` and `firewall.yml` in check mode report `changed=0`: the VMs' base
  setup and the firewall's GUI certificate match the repository (no drift; a change made by
  hand on a VM shows up here).
- `Test-LabCertificates` (every HTTPS endpoint: the right CA, valid for more than 30 days,
  trusted by Windows; the root for OpenBao, the current intermediate for the firewall, Keycloak
  and Matrix), `Test-LabTlsPin` (the PC's pinned connection to OpenBao refuses a foreign chain
  and also a lab chain through the intermediate), `Test-LabPasswordHash`,
  `Test-LabRetiredDpapi`, `Test-LabRunToken`.
- `Test-LabOpenBaoConfig`: the token of the configuration plane has exactly the policy
  `openbao-config`, lasts at most 30 minutes, works only from ansible-control and is revoked
  after the run; OpenBao is asked (`sys/capabilities-self`, nothing is tried) which paths it
  may configure and that it may not touch policies, logins, token roles, the SSH CA, the CAs,
  certificates or secrets; and `openbao-config.yml --check` finds nothing to change, so nobody
  changed OpenBao's configuration by hand.
- `Test-LabSecretCreation`, `Test-LabFirewallRender`,
  `Test-LabSshCa` (the SSH certificate code on the PC: offline signing, what a
  certificate contains, refused principals, the revocation list, the rendered
  trust files) and `Test-LabSshCertificates` (SSH in the running lab: strict
  logins everywhere, plain host keys and a foreign CA refused, a run certificate
  for `host-matrix` opens matrix only, the break-glass CA still accepted; run it
  elevated for the checks of the KVP host keys and Vagrant's jump).

They change nothing the lab uses: `Test-LabAnsible` and `Test-LabOpenBaoConfig`
make only read-only runs (the syntax check, `checks.yml`, the token check) and run
their other playbooks only in check mode (`--check`), `Test-LabSecretCreation` creates a
throwaway secret `lab/keycloak/test-generated` and deletes it again,
`Test-LabFirewallRender` builds the firewall's configuration into a temporary
folder (the root CA signs one extra test certificate for it), the two SSH
tests work with throwaway keys and short-lived certificates (listed in
`keys\ssh\issued.log` like every certificate), and `Test-LabTlsPin` makes one
HTTPS request to `www.microsoft.com` as an example of a foreign certificate
chain.
The script exits with 1 if a test failed. The nine tests from before `Test-LabLayout`,
`Test-LabAnsible` and `Test-LabOpenBaoConfig` all passed on 2026-10-24 (the
two SSH tests right after the move to SSH certificates); `Test-LabLayout` passed on
2026-10-24 too (93 of 93 checks).

One test **changes state** and runs only when you ask for it:
`Test-LabRecoveryLogin.ps1` checks the break-glass login (AppRole `recovery`)
the way `lab.ps1 recovery -Recover` uses it. It issues new `pc-admin`
and `pc-deploy` logins and destroys every secret ID of `recovery`, so the
break-glass login in an existing recovery file stops working; make a new file
afterwards with `.\lab.ps1 recovery -Renew`. It asks before it
starts:

```powershell
.\lab.ps1 test -IncludeStateChanging    # the twelve tests, then Test-LabRecoveryLogin.ps1
```

The deployments check themselves as well (`lab.ps1 deploy matrix`, for
example, the ACME certificates, MDAD's self-check and the login path to
Keycloak); the tests cover what the deployments do not. Some of them run small
scripts on ansible-control, kept in `ansible\tests\`. `Test-LabRunToken`,
`Test-LabOpenBaoConfig` and `Test-LabSecretCreation` start them as run profiles
(`test-run-token`, `test-config-token`, `test-secret-creation`, see
[Run a playbook](#run-a-playbook-re-run-a-deployment)): they reach `~/lab/tests` with the
rest of `ansible\` and get their OpenBao token exactly the way a deployment does.
`Test-LabSshCertificates` needs plain SSH sessions; `LabTest.ps1` copies its script to
`/tmp/lab-tests` on ansible-control and removes it again.

Enterprise equivalent: the same checks as a pipeline stage. A linter and a structure test on
every commit (here `Test-LabLayout`), a dry run against the real environment that must find
no drift (`Test-LabAnsible`, `Test-LabOpenBaoConfig`), and smoke tests after each deployment.

### Run a playbook, re-run a deployment

The deployments (`lab.ps1 deploy <target>`) are the normal way to apply changes to the
services. All are idempotent: run them again after any change, and a run
without changes changes nothing.

```powershell
.\lab.ps1 deploy vault           # OpenBao: openbao.yml, identities and policies (PC), openbao-config.yml, intermediate CA
.\lab.ps1 deploy vault -RotateIntermediate   # the same, and a new intermediate CA now
.\lab.ps1 deploy firewall        # firewall.yml: the GUI certificate from OpenBao's intermediate CA, when due
.\lab.ps1 deploy keycloak        # keycloak.yml (secrets and certificate from OpenBao)
.\lab.ps1 deploy matrix          # vendor\mdad to ~/mdad + matrix-prepare.yml + MDAD (through lab-setup.yml) + checks
.\lab.ps1 deploy matrix -Setup   # the same with the tags of "just setup-all", after REMOVING a component
.\lab.ps1 deploy all             # vault, firewall, keycloak, matrix; stops at the first failure
```

On a brand-new OpenBao, `deploy vault` runs `openbao-config.yml` twice: first for the mounts
and everything that needs no CA yet (the URLs even must exist before the intermediate CA's
first certificate), and again once the PC has made the intermediate CA, for the PKI roles and
ACME, which need it.

`lab.ps1 deploy keycloak` (after its playbook) and `lab.ps1 deploy matrix` (after
`matrix-prepare.yml` and again after MDAD's run) also take a snapshot of OpenBao, on
every run and also when the playbook failed: a first deployment creates secrets that from then on
exist only in OpenBao (see [Back up OpenBao](#back-up-openbao)). A failed
snapshot is only a warning; it does not change the deployment's result.

Any playbook can also run on its own, and so can every other Ansible run of the lab: each one
is a **run profile** in [config/run-profiles.json](config/run-profiles.json), which says what
runs on ansible-control and which credentials it gets:

| Key | Meaning |
|---|---|
| `playbook` | a playbook, relative to `ansible/`, run with `ansible-playbook` in `~/lab` |
| `command` | or a shell command instead, run in `~/lab` (for example `bash bin/deploy-matrix install-all`, which runs MDAD in `~/mdad`) |
| `principals` | the SSH principals of ansible-control's certificate for this run: `host-<vm>` opens that machine only, `lab-all` every one, `[]` none (the run stays on ansible-control) |
| `policies` | the OpenBao policies of the run's token; none = no token |
| `tokenRole` | the token role the token is minted through: `ansible-run` (the default; deployments, at most 2 hours, minted by `pc-deploy`) or `ansible-config` (OpenBao's configuration plane, at most 30 minutes, minted by `pc-admin`) |
| `syncMdad` | also copy `vendor\mdad` from the repository to `~/mdad` first |

```powershell
.\lab.ps1 run                                   # lists the profiles with their credentials
.\lab.ps1 run ping.yml                          # a playbook: runs with the profile that names it
.\lab.ps1 run ping -v                           # the same by profile name, more output
.\lab.ps1 run <profile> --check --diff          # dry run: show what would change
.\lab.ps1 run openbao-config --check --diff     # has OpenBao's configuration drifted from the repository?
.\lab.ps1 run matrix-prepare.yml *> run.log     # log to a file
```

Everything after the profile or playbook goes to `ansible-playbook` (or to the profile's
command) unchanged: `-v`, `--check --diff`, `--tags <tag>`, `-e name=value`. A playbook in
`ansible\playbooks` without a profile still runs, with a certificate for every machine
(`lab-all`) and no OpenBao token; the script says so. Which command starts which profile:
`lab.ps1 up` runs `base` and `checks`; `deploy vault` runs `openbao` and `openbao-config`;
`deploy firewall` runs `firewall`; `deploy keycloak` runs `keycloak`; `deploy matrix` runs
`matrix-prepare` and `matrix` (`matrix-setup` with `-Setup`); the tests run `syntax`, `checks`,
`test-run-token`, `test-config-token`, `test-secret-creation`, and `base`, `firewall` and
`openbao-config` in check mode. `mdad`, `hello-nginx` and `ping` are for you, and `test-sleep`
only waits 20 seconds.
Enterprise equivalent: job templates in AWX / Ansible Automation Platform, each with its own
machine credential and secrets lookup.

What happens on each call of `lab.ps1 run` (`Invoke-LabRun` in
[scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1), and [ansible/bin/lab-run](ansible/bin/lab-run)
on ansible-control; `up` and the deployments start their runs the same way):

1. `ansible\`, `config\lab.json`, `config\run-profiles.json`, the firewall's helper
   `opnsense\lab-gui-cert.php` and the **public** files of the lab's PKI from `keys\pki`
   are packed with `tar` (with `syncMdad`, `vendor\mdad` in a second archive) and copied to
   ansible-control, into a private folder of their own. The root CA's key never leaves the PC.
2. ansible-control gets an **SSH certificate for this run**: the PC signs
   ansible-control's own public key for exactly the principals of the profile
   (below), valid 2 hours.
3. A profile with policies gets a **run token** (below); if OpenBao
   is sealed, the script unseals it first, and if OpenBao does not answer at
   all, it stops and asks whether the vault VM is running and OpenBao has been
   deployed (`.\lab.ps1 deploy vault`).
4. One SSH call starts `bin/lab-run` there. It allows **one run at a time**: a second run
   while one is active stops at once with exit code 75, and the script says so. `~/lab` on
   ansible-control is **replaced completely** with the new copy
   (`chmod -R go-w`, see [P20](#p20-ansible-ignores-ansiblecfg)), and with `syncMdad`
   `~/mdad` the same way. The public PKI files go to `~/lab-pki`: the root CA certificate
   (PEM, which the playbooks put into the VMs' trust stores) and the DER copies of the root
   certificate and its revocation list (which `openbao.yml` publishes on the vault VM).
5. The profile's playbook (`ansible-playbook <playbook> <your extra arguments>`) or command
   runs in `~/lab`, through `bin/openbao-run` when it has a token. Output is in colour when
   you run it in a console window and plain text when you redirect it to a file. The run's
   certificate is deleted again when it ends, whatever its exit code, together with the
   SSH connections Ansible keeps open for a while (ControlPersist), so no later run can reuse
   a connection of an earlier, broader one.

Which runs get a token, and what it allows (one file per policy in
[config/openbao/policies](config/openbao/policies), uploaded by `lab.ps1 deploy vault`; which
profile gets which policy is its `policies` in
[config/run-profiles.json](config/run-profiles.json)):

| Profile (what it runs) | Policy of its run token | The token may |
|---|---|---|
| `keycloak` (`keycloak.yml`) | `ansible-keycloak` | create and read `lab/keycloak/*`, generate passwords (`lab-alnum-24`, `-48`), have OpenBao sign certificates of the PKI role `keycloak` |
| `matrix-prepare` (`matrix-prepare.yml`), and MDAD's runs: `matrix`, `matrix-setup`, `mdad` | `ansible-matrix` | create and read `lab/matrix/*`, read (only) the MAS client secret `lab/keycloak/clients/matrix-authentication-service`, generate passwords (`lab-alnum-64`) |
| `firewall` (`firewall.yml`) | `ansible-firewall` | have OpenBao sign certificates of the PKI role `firewall-gui` (only the name `firewall.<domain>`); no secrets |
| `hello-nginx` (`hello-nginx.yml`) | `ansible-web` | have OpenBao sign certificates of the PKI role `web`; no secrets |
| `openbao-config` (`openbao-config.yml`) | `openbao-config`, through the token role `ansible-config` | configure the engines: the KV mount `lab` and its settings, the password policies, the `pki_int` mount with its URLs, revocation list, tidying, PKI roles and ACME. Never a policy, a login, a token role, the SSH CA, a CA's import or choice, a certificate or a secret; the playbook stops unless its token has exactly this policy |
| `ping`, `base`, `checks`, `openbao`, `syntax` | none | (they need no token: they do not contact OpenBao, except `openbao.yml`, which only calls the unauthenticated health endpoint `sys/health`) |

The test profiles `test-run-token` and `test-secret-creation` get `ansible-keycloak`,
`test-config-token` gets `openbao-config` through `ansible-config`, like the runs they test.

Which machines the run's SSH certificate opens (its principals; principals are
explained in [SSH certificates](#ssh-certificates-user-and-host-cas)):

| Profile | Principals | Opens |
|---|---|---|
| `openbao` | `host-vault` | vault |
| `firewall` | `host-firewall` | firewall |
| `keycloak` | `host-keycloak` | keycloak |
| `base` | `host-matrix`, `host-keycloak`, `host-vault` | matrix, keycloak, vault (ansible-control applies `base.yml` to itself locally, without SSH) |
| `matrix-prepare`, and MDAD's runs: `matrix`, `matrix-setup`, `mdad` | `host-matrix` | matrix |
| `ping`, `checks`, `hello-nginx`, and every playbook without a profile (the script says so) | `lab-all` | every machine, the firewall included |
| `openbao-config`, `syntax`, the `test-*` profiles | none (`[]`) | nothing: no certificate, the run stays on ansible-control (`openbao-config.yml` only talks to OpenBao's API) |

The same idea as the run token's policy: least privilege per run. During a
Matrix deployment, MDAD (third-party code) holds a certificate that opens
matrix, not vault or the firewall. A new playbook gets a profile with the
`host-<vm>` names it needs (`Test-LabLayout` fails for a playbook without one,
unless a script in `ansible\bin` starts it).

How the run token reaches the playbook is drawn step by step in
[Where secrets and certificates come from](#where-secrets-and-certificates-come-from)
and explained in [Secrets management with OpenBao](#secrets-management-with-openbao).
In short: the PC logs in as `pc-deploy` and has OpenBao create a token with only
the policy from the table, valid for at most 2 hours and only from
ansible-control's address (for `openbao-config`: as `pc-admin`, through the token role
`ansible-config`, at most 30 minutes: changing how OpenBao works is an administrator's
decision); it arrives response-wrapped (a single-use wrapping token, valid 120 seconds), on
SSH's stdin, at [ansible/bin/openbao-run](ansible/bin/openbao-run), which unwraps it, runs
the playbook or command and revokes the token when it ends, also after a failure or
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

The exit code of `lab.ps1 run` is the exit code of `ansible-playbook` or of the profile's
command (255 if the SSH connection itself failed, 75 if another run was active). Extra
arguments are joined with spaces into one remote command line, so avoid values that contain
spaces (use `-e name=value`); quotes of any kind are refused.

**Dry runs** (`--check`, with `--diff` to see the differences) work for the
playbooks with a run token too. Tasks that only read (the secrets, OpenBao's CA
certificate) run anyway (`check_mode: false`: without the values nothing else
could be compared), and nothing is written to OpenBao: no missing secret is
created and no certificate is requested. One task always reports `changed`
under `--check`: Keycloak's users, because the `keycloak_user` module cannot
compare passwords there. A real run reports `ok` for them. Three dry runs are worth
knowing, because a clean lab answers them with `changed=0`, so anything else is drift:

- `.\lab.ps1 run openbao-config --check --diff`: every configuration object of OpenBao
  that differs from [ansible/playbooks/vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml)
  is shown with its current and wanted values (a task "Differences in <path>"), nothing is
  written. A real run writes only what differs; `-e openbao_config_force=true` writes every
  object once, even when it matches.
- `.\lab.ps1 run firewall --check`: whether the firewall's GUI certificate is due and why
  (expires within 30 days, not issued by the current intermediate CA, or without the
  firewall's name). `-e firewall_gui_renew_before=+400d` makes any certificate count as due:
  `.\lab.ps1 run firewall -e firewall_gui_renew_before=+400d` gets a new one now.
- `.\lab.ps1 run base --check --diff`: a VM whose zsh setup or console autologin was changed
  by hand.

`Test-LabAnsible` and `Test-LabOpenBaoConfig` run these dry runs (without `--diff`) and
fail unless they report `changed=0` ([Run the tests](#run-the-tests)). Enterprise
equivalent: scheduled drift detection, a pipeline that runs the same code in check mode and
alerts on every difference.

Ansible may print a warning once per VM: "Module remote_tmp /root/.ansible/tmp
did not exist and was created with a mode of 0700". It is a side effect of
pipelining and harmless
([P48](#p48-ansible-warns-that-it-created-rootansibletmp)).

Running `keycloak.yml` or `matrix-prepare.yml` directly is safe: their secrets
come from OpenBao, wherever they run, and a rebuilt ansible-control loses
nothing. The deployments add the snapshot of OpenBao and, for Matrix,
MDAD and the checks (profile `matrix`). (The profile `matrix-prepare` copies `vendor\mdad`
to `~/mdad` first, `syncMdad`, and the playbook checks that copy and stops if it is missing
or holds another commit than its pinned `mdad_version`.) A playbook started by
hand on ansible-control has no token and stops as soon as it needs OpenBao ("No
OpenBao token in the environment").

`lab.ps1 deploy matrix` runs MDAD in `~/mdad` on ansible-control, with MDAD's
own `ansible.cfg` and inventory, in two runs like any other. The first, profile
`matrix-prepare`, copies `vendor\mdad` from the repository there (a second archive, unpacked
into `~/mdad.new`, which then replaces `~/mdad`, as `~/lab` is replaced), so the control node
keeps no MDAD code of its own that could drift. The second, profile `matrix`
([ansible/bin/deploy-matrix](ansible/bin/deploy-matrix)), runs MDAD's install-all, its
self-check, `mas-cli doctor` and `matrix-check.yml` one after the other, with the run token and
the certificate (for matrix only) of that one run. MDAD runs through the lab's entry point
[lab-setup.yml](ansible/matrix/lab-setup.yml)
instead of MDAD's `setup.yml`: it reads the Matrix secrets from OpenBao into
memory, hands them to MDAD as variables and then imports `setup.yml`, with the
same tags as MDAD's `just` recipes.
MDAD's `justfile` would run `setup.yml` directly, without the secrets, which
are no longer in MDAD's inventory; the lab does not use it (`just` is not
installed). To run a single MDAD tag by hand, for example the self-check, use
the profile `mdad` (after at least one `lab.ps1 deploy matrix`
run, so that `~/mdad` exists). Like every Matrix run, its certificate opens only matrix:

```powershell
.\lab.ps1 run mdad --tags=self-check
```

MDAD checks SSH host keys like the lab's own playbooks: its `ansible.cfg` leaves
Ansible's `host_key_checking` at its default (on), and ssh on ansible-control
accepts a lab machine only with a valid host certificate
(`/etc/ssh/ssh_config.d/20-lab.conf`, written by
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh)).

**Edit playbooks and configuration in the repository, never on the VM.** The
repository is the source of truth: `~/lab` is overwritten on the next
run (`lab.ps1 run`, `up` or a deployment) and `~/mdad` on the next
`lab.ps1 deploy matrix`, and `matrix-prepare.yml` copies the MDAD inventory and `lab-setup.yml`
from the repository into `~/mdad` (and generates `lab-shared.yml` there). Do
not edit `vendor\mdad` either: it is MDAD's code exactly as upstream published
it, and it changes only through `lab.ps1 mdad-upgrade`
([Upgrade MDAD](#upgrade-mdad-and-with-it-the-matrix-components)). The lab's
own settings for MDAD belong in `ansible\matrix\`.

### Which change is applied by which command

| You changed | Apply it with |
|---|---|
| `config/lab.json`: `published` (addresses, names, ports) | `.\lab.ps1 firewall -Rebuild` (about 4 minutes; see [Publish a name or a port](#publish-a-name-or-a-port)). If the matrix entry's `address` changes, also set `livekit_server_config_rtc_node_ip` in `vars.yml` to it and run `.\lab.ps1 deploy matrix`, or calls connect without media ([P35](#p35-a-call-connects-but-no-audio-or-video-flows)) |
| `config/lab.json`: a new lab VM | see [Add a VM](#add-a-vm): firewall rebuild, `.\lab.ps1 deploy vault` (OpenBao's SSH roles learn the new name), then `.\lab.ps1 up` |
| `config/lab.json`: an existing VM's `cpus` or `memory` | `vagrant reload <vm>` in the `vagrant` folder (the VM restarts; after a reload of vault, `.\lab.ps1 unseal`) |
| `config/lab.json`: an existing VM's MAC or IP | `.\lab.ps1 down <vm>`, then `.\lab.ps1 firewall -Rebuild` and `.\lab.ps1 up`. For vault this means a new, empty OpenBao (see [Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)) |
| `config/lab.json`: the `firewall` data | `.\lab.ps1 firewall -Rebuild`. If `hostIp` or `pcIp` changes: first update the matching values in `lab.ps1 host-setup` (the PC's 10.10.99.1 and its DNS server 10.10.99.2) and run it, then `.\lab.ps1 down firewall` and `.\lab.ps1 up`, which rewrites `keys\ssh_config` with the new address (step 2) before it builds the firewall (step 4). A plain `-Rebuild` would still try the old address from `keys\ssh_config` for SSH and fail. Note: the PC's OpenBao logins (`pc-admin`, `pc-deploy`, and the break-glass login `recovery` in the recovery file) are bound to the PC's address and stop working after a change of `pcIp`; no script handles that yet. With them OpenBao's signing of SSH certificates stops (its role `pc` also names the old address), so until then the SSH certificates come from the offline SSH CA (`.\lab.ps1 breakglass <command>`) |
| `opnsense/config.xml.template` | `.\lab.ps1 firewall -Rebuild` (or make the same change in the GUI, see [section 6](#6-how-to-)) |
| `opnsense/dnsmasq.conf.d/10-lab.conf` | `.\lab.ps1 firewall` or `.\lab.ps1 up` (the drop-in is installed again on every run) |
| `ansible/playbooks/openbao.yml`, `ansible/templates/openbao/*` | `.\lab.ps1 deploy vault`. A changed `openbao.hcl` is applied with a reload, which does not seal OpenBao; the reload covers the TLS files, the log level and the audit settings. Other settings (listener, storage) need a restart: `.\lab.ps1 connect vault 'sudo systemctl restart openbao'`, then `.\lab.ps1 unseal` |
| OpenBao's identity plane: the ACL policies (`config/openbao/policies/*.hcl`, one file per policy, the file name is its name), the AppRoles `pc-admin`, `pc-deploy`, `recovery` and the token roles `ansible-run`, `ansible-config` (`scripts/lib/LabVault.ps1`), `ui-admin` (`scripts/lib/LabSecrets.ps1`) | `.\lab.ps1 deploy vault`: its step 6 writes them from the PC on every run, so the code is the truth. A run gets a new policy only when its profile names it (`policies` in `config/run-profiles.json`) and its token role allows it (`allowed_policies` of `ansible-run` or `ansible-config`) |
| OpenBao's configuration plane: `ansible/playbooks/vars/openbao-config.yml` (the KV mount `lab` and its settings, the password policies, the `pki_int` mount with its URLs, revocation list, tidying, PKI roles, ACME), `ansible/playbooks/openbao-config.yml`, `ansible/playbooks/tasks/openbao-api.yml` | `.\lab.ps1 run openbao-config`, or `.\lab.ps1 deploy vault`, which runs it too. Preview it with `.\lab.ps1 run openbao-config --check --diff`. Only values that differ are written and nothing is deleted: an object removed from the file stays in OpenBao until you remove it yourself |
| A name in a PKI role (`allowed_domains` in `openbao_pki_roles`, `ansible/playbooks/vars/openbao-config.yml`) | `.\lab.ps1 run openbao-config` (or `.\lab.ps1 deploy vault`), then the deployment of the service that uses the role (see [Publish a name or a port](#publish-a-name-or-a-port)) |
| `ansible/playbooks/firewall.yml`, `opnsense/lab-gui-cert.php`, or the firewall's GUI certificate is due | `.\lab.ps1 deploy firewall` (`deploy all` includes it). `.\lab.ps1 up` runs it in its maintenance step when the certificate expires within 30 days or is not issued by the current intermediate CA (after a firewall rebuild or a rotation). It renews only a due certificate, so a changed playbook takes effect at the next renewal; one now: `.\lab.ps1 run firewall -e firewall_gui_renew_before=+400d`. `.\lab.ps1 firewall` no longer renews it, it only reports on it |
| Nothing, but the intermediate CA should be replaced now (a suspected key compromise, a test) | `.\lab.ps1 deploy vault -RotateIntermediate`, then `.\lab.ps1 deploy firewall`, `.\lab.ps1 deploy keycloak` and `.\lab.ps1 deploy matrix` (see [Rotate the intermediate CA](#rotate-the-intermediate-ca)) |
| `ansible/ansible.cfg`, `ansible/bin/*` (`lab-run`, `openbao-run`, `deploy-matrix`, `syntax-check`), `config/run-profiles.json` | nothing extra: every run of `lab.ps1 run` (also inside `up` and the deployments) copies all of `ansible\` and `config\run-profiles.json` to `~/lab` on ansible-control, and the MDAD runs use `~/lab/bin/openbao-run` and `~/lab/bin/deploy-matrix` from there. A profile's changed principals or policies apply from its next run (a new policy also needs the identity-plane row above) |
| `ansible/playbooks/keycloak.yml`, `ansible/playbooks/vars/keycloak-secrets.yml`, `ansible/templates/keycloak/*` | `.\lab.ps1 deploy keycloak` |
| `ansible/playbooks/tasks/*` (task files shared by several playbooks) | the deployments that include them: `openbao-secrets.yml` by `lab.ps1 deploy keycloak` and `lab.ps1 deploy matrix`, `openbao-certificate.yml` by `lab.ps1 deploy keycloak` and `hello-nginx.yml`, `openbao-api.yml` by `openbao-config.yml` (configuration-plane row above) |
| The Keycloak/MAS values in `ansible/inventory/group_vars/all.yml` | `.\lab.ps1 deploy keycloak`, then `.\lab.ps1 deploy matrix` (both sides must agree). Never change `lab_mas_keycloak_provider_id` |
| `ansible/matrix/` (MDAD inventory, `vars.yml`, `lab-setup.yml`), `ansible/playbooks/matrix-check.yml`, `ansible/playbooks/matrix-prepare.yml` (its pinned MDAD version `mdad_version` only together with `vendor\mdad`, next row) | `.\lab.ps1 deploy matrix`; with `-Setup` after removing a component |
| A new MDAD version (`vendor\mdad`) | `.\lab.ps1 mdad-upgrade -Commit <commit>` (git subtree pull plus the roles, two commits); then `mdad_version` and `vars.yml` as in [Upgrade MDAD](#upgrade-mdad-and-with-it-the-matrix-components), and `.\lab.ps1 deploy matrix` (it refuses while `vendor\mdad` and `mdad_version` differ) |
| `tests/*`, `ansible/tests/*` | nothing: the tests only check ([Run the tests](#run-the-tests)) |
| A secret in OpenBao: a new user's password, a new MAS client secret | written by you as administrator ([Write or change a secret](#write-or-change-a-secret-administrator)), then `.\lab.ps1 deploy keycloak`; for the client secret also `.\lab.ps1 deploy matrix` (see [Rotate the MAS client secret](#rotate-the-mas-client-secret)). Never change `keycloak/db`, `keycloak/admin`, `keycloak/clients/lab-ansible`, `matrix/generic-secret-key` or `matrix/postgres` on a running lab: they are fixed after the first start of their service. A new database password no longer matches the one PostgreSQL keeps, so the service stops working; a new admin password or `lab-ansible` secret is ignored by Keycloak, and with the latter the playbook can no longer log in to the admin API; MDAD derives keys from the Matrix secret key. A new password of an existing user is not applied either (see [Add a Keycloak user](#add-a-keycloak-user)) |
| Other playbooks (`ping.yml`, `checks.yml`, `hello-nginx.yml`) | `.\lab.ps1 run <playbook>` |
| `ansible/playbooks/base.yml`, `ansible/files/base/*` (zsh and its history search, the console autologin), a VM's `consoleAutologin` in `config/lab.json` | `.\lab.ps1 up` (it runs `base.yml` on every run) or, quicker, `.\lab.ps1 run base`; `.\lab.ps1 run base --check --diff` shows first what would change |
| `provision/*.sh` (the bootstrap: user `ansible`, SSH with certificates, Ansible on ansible-control) | `.\lab.ps1 up` (it always re-runs provisioning of the Ubuntu VMs). Exception: a new `ANSIBLE_VERSION` in `bootstrap-ansible-control.sh` reaches an existing ansible-control only with the command below |
| The SSH certificate roles, `$LabSshRoles` in `scripts/lib/LabSsh.ps1` (lifetimes, extensions, source addresses) | `.\lab.ps1 deploy vault`, which makes OpenBao's SSH roles from the same table. Certificates already issued keep their contents until they are renewed: the PC's at once with `.\lab.ps1 ssh-cert -Force`, a run's with the next run, host certificates 30 days before they expire |
| `opnsense/sshd_config.d/20-lab-ssh.conf`, `opnsense/lab-sshd-files.sh`, `opnsense/lab-ssh-trust.php` | `.\lab.ps1 firewall` or `.\lab.ps1 up` (the firewall's SSH setup is applied again on every run, no rebuild) |
| Nothing, but the PC should have a new SSH certificate now | `.\lab.ps1 ssh-cert -Force` (every script renews it by itself when fewer than 4 hours are left) |

Ansible is pinned too: `ANSIBLE_VERSION` in
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh)
(today 14.5.0, the community package with its collections, which brings
ansible-core 2.21.5). The provisioning script installs Ansible only when pipx
does not list it yet, so it never changes an existing installation. To
upgrade, change `ANSIBLE_VERSION` (a rebuilt ansible-control then gets the new
version) and, on the existing VM (`.\lab.ps1 connect` opens a shell
there), install exactly that version:

```
sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install --force --include-deps ansible==<version>
```

### Rebuild one VM or the whole lab

```powershell
.\lab.ps1 down matrix      # one Ubuntu VM (asks for confirmation)
.\lab.ps1 down vault       # OpenBao: a snapshot first, then keys\openbao is moved aside (below)
.\lab.ps1 down firewall    # only the firewall
.\lab.ps1 down             # all VMs, the firewall last
.\lab.ps1 down -WhatIf     # only show what would be deleted
.\lab.ps1 down -Confirm:$false   # no confirmation question
.\lab.ps1 up         # build again

.\lab.ps1 firewall -Rebuild     # delete and rebuild only the firewall, in one step
```

`lab.ps1 down` works from whatever folder you are in. For the Ubuntu VMs it
runs `vagrant destroy`; the VMs and their disks are deleted. It also removes the
Hyper-V folder `G:\Vagrant\hyperv\<vm>` that `vagrant destroy` leaves behind
(only for VMs listed in `config/lab.json`, only a folder named exactly like its
VM, see [P14](#p14-a-removed-vm-leaves-its-hyper-v-folder-behind)). The firewall
is not a Vagrant VM, so the script removes it with the Hyper-V cmdlets, together
with its folder `G:\Vagrant\hyperv\firewall` (disk, configuration, console log).
For safety it touches only a VM whose Notes carry the tag that
`lab.ps1 firewall` writes there.

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
host keys. `lab.ps1 down` (and `lab.ps1 firewall -Rebuild`, and
`lab.ps1 up` when a VM publishes a different key) puts the old key into
the revocation list `keys\ssh\revoked_host_keys` and gives ansible-control the
new list, so a copy of an old key, from a checkpoint or an old disk, can never
pass for the rebuilt machine. The new machine gets its host certificate from
`lab.ps1 up` (the firewall from its build). Once OpenBao signs the SSH
certificates, a firewall rebuild needs the vault VM running: the new firewall's
host certificate comes from OpenBao, through the new firewall's port forward.
`lab.ps1 firewall -Rebuild` starts the vault VM itself, and refuses before it
deletes anything when the vault VM does not exist;
`.\lab.ps1 breakglass firewall -Rebuild` lets the offline SSH CA sign instead.

**OpenBao is a special case.** The vault VM holds the only copy of the
services' secrets, so before `lab.ps1 down` deletes it (`lab.ps1 down
vault`, or `lab.ps1 down` without a name) it takes a fresh snapshot
([Back up OpenBao](#back-up-openbao)). If no fresh snapshot is possible
(OpenBao sealed or broken), it warns and relies on the newest snapshot already
in `keys\openbao\snapshots` (every deployment takes one). Only if there is none
at all while you delete only vault and keycloak or matrix still exist, it stops
and deletes **nothing**: their data depends on those secrets. Start the vault VM
and unseal OpenBao (`.\lab.ps1 up`), then try again. When the
whole lab goes, a failed snapshot is only a warning.

Then the key shares and the PC's logins (`keys\openbao\*.dpapi`), which fit only
the installation they were made for: the script **moves** `keys\openbao` to
`keys\openbao-retired-<yyyyMMdd-HHmmss>`, together with the snapshots in it
(the new one included). A snapshot can be restored only with the key shares of
its time, so neither is thrown away. (`lab.ps1 deploy vault` refuses to
initialise a new OpenBao while `keys\openbao` holds shares of an earlier one.)
OpenBao's SSH CA goes with the deleted installation: the script moves
`keys\ssh\openbao-ca.pub` and `openbao-ca.trusted` into the same retired folder
(`ssh\` in it). The machines stop trusting that CA at the next
`lab.ps1 up`, which renders the SSH trust files without it, and the
offline SSH CA signs again until `lab.ps1 deploy vault` has made the new
OpenBao's SSH CA trusted everywhere (its step 8).
A rebuilt OpenBao is a new installation: new key shares (make a new recovery
kit with `lab.ps1 recovery`; the old share C and recovery file belong to
the old installation), a new intermediate CA (`lab-int-<year>`, signed by the
same root, so nothing changes for Windows) and **no secrets**. What follows
from that:

- Rebuilding vault **together with** keycloak and matrix (or the whole lab) is
  simple: the deployments generate new secrets for the new databases. alice and
  bob get new passwords (`lab.ps1 secret`). Delete keycloak and matrix
  first, or the whole lab at once: while they still exist, `lab.ps1 down
  vault` on its own refuses when it can neither take a snapshot nor find an
  earlier one.
- Rebuilding vault **alone**, while keycloak and matrix keep their data, needs a
  restore: their databases were set up with the old secrets, and new ones would
  not open them. `lab.ps1 deploy keycloak` and `lab.ps1 deploy matrix` notice that
  and refuse ("The service already has data that was set up with the old
  values"). See [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot).
- Keycloak and Matrix keep running without OpenBao (their secrets are in their
  own configuration), but deployments, certificate renewals and the revocation
  list of the intermediate CA need it.

**What is lost: the application data.** There are no backups of the databases
yet (see the [roadmap](#11-roadmap)); OpenBao's own data has snapshots
([Back up OpenBao](#back-up-openbao)), taken by the deployments and by
`lab.ps1 down` itself.

- **Removing matrix** deletes the homeserver's PostgreSQL database and media:
  every room, message, uploaded file and Matrix account. After
  `lab.ps1 up` and `lab.ps1 deploy matrix` you have an empty homeserver
  with the same configuration and the same secrets (from OpenBao); Traefik gets
  new certificates through ACME, and the accounts are created again on the next
  login. Browsers may still hold the old Element session; sign in again (or
  clear the site data of `element.lab.internal`).
- **Removing keycloak** deletes Keycloak's database. After `lab.ps1 up`
  and `lab.ps1 deploy keycloak`, alice and bob exist again with the same
  passwords and the same client secret (from OpenBao), but with new internal
  user IDs. MAS links them to the existing Matrix accounts by user name
  (`on_conflict: replace` in `vars.yml`, a lab trade-off explained in
  [section 10](#10-security-notes)). Users created by hand in the admin console
  are gone.
- **Removing ansible-control** loses nothing that matters: everything on it
  comes back from the repository. Its provisioning installs the pinned Ansible
  version again, `~/lab` and `~/lab-pki` are copied again on the next
  run (`lab.ps1 run`, `up` or a deployment), and `~/mdad` on
  the next `lab.ps1 deploy matrix`, which copies `vendor\mdad` there. It
  holds no secrets and no CA any more; its provisioning makes it a new SSH key
  of its own, which the PC signs for each run like the old one.
- **Removing vault** deletes OpenBao's data: all secrets, the intermediate CA's
  key, the SSH CA's key, the ACME accounts. What that means is described above.

After a rebuild, deploy what the rebuilt VM runs:

| Rebuilt | Then run |
|---|---|
| firewall | `.\lab.ps1 deploy firewall`, or nothing until the next `.\lab.ps1 up`, whose maintenance step runs it: its configuration comes from the repository, and the build gives it a new SSH host certificate (its old host key is revoked) and a first GUI certificate from the root, which `deploy firewall` replaces with one from OpenBao's intermediate CA |
| ansible-control | nothing (the next `lab.ps1 deploy matrix` copies MDAD there again) |
| keycloak | `.\lab.ps1 deploy keycloak` |
| matrix | `.\lab.ps1 deploy matrix` |
| vault, together with keycloak and matrix | `.\lab.ps1 deploy vault`, `.\lab.ps1 recovery` (in your own PowerShell window), `.\lab.ps1 deploy firewall` (its GUI certificate is from the old intermediate CA), `.\lab.ps1 deploy keycloak`, `.\lab.ps1 deploy matrix` (both take a snapshot of the new secrets) |
| vault alone | [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot) |
| the whole lab | `.\lab.ps1 up`, then as for vault together with keycloak and matrix. `lab.ps1 trust` is not needed again: the root CA stayed |

`lab.ps1 firewall -Rebuild` uses `G:\Vagrant` by default; if you built the
lab with another `-StorageRoot`, pass it here too. It renders and checks the new
configuration **before** it deletes the old firewall, so a mistake in
`config/lab.json` or the template stops it while the old firewall keeps
running.

`lab.ps1 firewall` also has `-TimeZone` (an IANA name, default
`Europe/Berlin`), which sets the firewall's clock for its logs.
`lab.ps1 up` does not pass it. The value is written into the firewall's
`config.xml` only when the firewall is built, so to use another zone rebuild
with it, for example `.\lab.ps1 firewall -Rebuild -TimeZone Europe/London`,
and pass it again on every later `-Rebuild`. A plain re-run keeps the zone the
firewall has.

### After a Windows restart

Run `.\lab.ps1 up`. The firewall VM is shut down together with
Windows and is not started automatically; the script starts it first, so that
DHCP, DNS and the jump host are ready before the lab VMs need them. The vault VM
is started right after it, directly in Hyper-V, and **OpenBao is unsealed**
with the key shares stored on the PC (next section), over HTTPS and before any
SSH: the PC's SSH certificate is valid for 8 hours, so after a restart it has
expired, and once OpenBao is deployed it is OpenBao that signs the new one
(`vagrant up` could not start the vault VM yet: it needs SSH). Then the script
checks the firewall: its SSH host certificate, its DNS drop-in, and its GUI
certificate, which it only reports on (a due one is renewed by the maintenance
step at the end, below). Then it starts whatever else is not
running, re-applies the provisioning of the Ubuntu VMs, checks their host
certificates, unseals OpenBao if it is still sealed (if OpenBao's TLS
certificate is due or expired, it runs `lab.ps1 deploy vault` instead, which
renews the certificate first and then unseals; if the certificate has already
expired, the offline SSH CA signs until then, because renewing it needs SSH to
the vault VM and the pinned TLS check refuses an expired certificate), logs in
to every machine from the PC, and has ansible-control apply `base.yml` (zsh,
console autologin) and run the read-only checks of `checks.yml` on every
machine. If OpenBao does not come up at all, the script stops at the first SSH
login with the reason; `.\lab.ps1 breakglass up` lets the offline SSH CA sign
instead ([P53](#p53-ssh-host-key-verification-failed-or-permission-denied-publickey)).
The applications start with their VMs:
MDAD's systemd units are enabled, the Keycloak containers have Docker's restart
policy `unless-stopped`, and the `openbao` service is enabled (it starts
sealed). The Default Switch gets a new subnet on every Windows boot; the
firewall simply gets a new WAN address by DHCP when it boots. LabHost and
LabNet addresses never change, so `keys\ssh_config` and the DNS rule keep
working.

Its last step, **7/7 Maintenance** (once OpenBao is deployed), renews what is
due. A certificate is renewed only when the script that renews it runs, and
`lab.ps1 up` runs after every restart anyway, so it checks:

| What | Due when | Renewed by |
|---|---|---|
| OpenBao's TLS certificate | less than 30 days left | `lab.ps1 deploy vault` |
| The root CA's revocation list | its next update less than 60 days away, or the copy the vault VM serves differs from the PC's (renewed on the PC, not yet published) | `lab.ps1 deploy vault` (it renews and publishes it) |
| The intermediate CA | less than 400 days left | `lab.ps1 deploy vault` (a rotation, see [Rotate the intermediate CA](#rotate-the-intermediate-ca)) |
| The firewall's GUI certificate | less than 30 days left, or not issued by the current intermediate CA (a newly built firewall starts with one from the root; after a rotation it is from the old intermediate) | `lab.ps1 deploy firewall` |
| Keycloak's TLS certificate | less than 30 days left | `lab.ps1 deploy keycloak` |

It prints one line per item that is due and runs each named command once, or
reports that nothing is due. The same step on its own is `.\lab.ps1 maintain`
(`-List` only shows what is due); `.\lab.ps1 status` lists it too. The checks need no login:
they read the certificates that OpenBao, the firewall and Keycloak present, the root CRL on
the PC and on the vault VM, and the intermediate's public certificate, which the firewall's
certificate is compared with by key identifier (`Get-LabMaintenanceDue` in
[scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1)). One kind of certificate is not
on the list because it is renewed elsewhere: the Matrix certificates (Traefik renews
them itself). The SSH certificates are not on it either: the PC's is renewed
by whichever script needs it, and the host certificates (1 year) in steps 4 and
5, 30 days before they expire. If the PC runs for weeks without a restart, run
`lab.ps1 up` at least once a month anyway.

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
or in a password manager, after `lab.ps1 recovery`. Unsealing needs no
input:

```powershell
.\lab.ps1 unseal                  # shares A and B from DPAPI; does nothing if already unsealed
.\lab.ps1 unseal -Interactive     # asks for two shares (recovery, in your own PowerShell window)
curl.exe -s https://vault.lab.internal:8200/v1/sys/health   # "sealed":false, "standby":false when ready
```

You rarely run it yourself: `lab.ps1 up` unseals OpenBao right after
starting the firewall and the vault VM, `lab.ps1 run` does it before
a playbook that needs OpenBao, the scripts do it before OpenBao signs a new SSH
certificate for the PC, and `lab.ps1 deploy vault` in its own step 5. You need
it after the vault VM or the `openbao` service was restarted some other way
(`vagrant reload vault`, a restart on the VM). Right after unsealing, OpenBao's
storage first elects itself leader; until then it answers writes with "cannot
write to readonly storage". The script waits until OpenBao reports itself
active.

`-Interactive` asks for two shares instead of reading them from DPAPI: for the
case where the PC's DPAPI data is lost (a new Windows installation or profile)
and OpenBao only has to be unsealed. Type share B from the recovery file
(`.\lab.ps1 recovery -Open <file>` shows it) and share C from your
copy. It runs only in a real console window, because you type secrets into it.
To restore the PC's access completely (new logins, the shares back in DPAPI),
use `lab.ps1 recovery -Recover`, which unseals by itself
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
.\lab.ps1 backup                                       # keys\openbao\snapshots\vault-<date-time>.snap
.\lab.ps1 backup -Destination Z:\DeployableServer-recovery   # and a copy in that (existing) folder
.\lab.ps1 backup -Keep 20                              # this run keeps 20; the next automatic one prunes to 10
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

- `lab.ps1 deploy keycloak` after its playbook and `lab.ps1 deploy matrix` after
  `matrix-prepare.yml` and after MDAD's run, on every run, also when the playbook failed: a first
  deployment creates secrets that from then on exist only in OpenBao, and the
  deployment that follows a secret you wrote by hand saves that one too.
- `lab.ps1 down` right before it deletes the vault VM. If that fails, it
  relies on the newest snapshot from before, and when there is none while
  keycloak or matrix stay, it deletes nothing
  ([Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)).

Take one yourself after a change that no deployment follows soon: a secret you
wrote by hand and do not deploy yet, or a new intermediate CA from
`lab.ps1 deploy vault` (its key exists only inside OpenBao). Because every Keycloak or
Matrix deployment adds a snapshot (a Matrix deployment two), the 10 kept on the PC may cover
only a few days:
copy one off the PC from time to time (`-Destination`). `-Keep` is no way to
keep more: it applies only to that one run, and the next automatic snapshot
(every Keycloak or Matrix deployment, `lab.ps1 down`) calls the script
without it and prunes the folder back to the newest 10.

**Restore needs the key shares of the snapshot's time.** A snapshot restored
into a new OpenBao brings back the old installation's keyring, so it is
unsealed with the old shares (and the old logins work again); see
[Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot). That is why
`lab.ps1 down` moves `keys\openbao`, snapshots and shares together. Keep a
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
re-run a single step, for example `vagrant provision matrix --provision-with ssh-hardening`.
The names are `lab-ssh-ca`, `ansible-user` and `ssh-hardening` (all VMs);
`lab-ssh-known-hosts`, `lab-ssh-revoked-host-keys` and
`ansible-control` (ansible-control). Vagrant's provisioning is only the bootstrap, what
must exist before Ansible can reach a VM; zsh and the console autologin come from
`ansible/playbooks/base.yml` (`.\lab.ps1 run base`), like everything after the bootstrap
([Configuration management with Ansible](#configuration-management-with-ansible)).

Vagrant logs in through the firewall with the PC's SSH certificate. Before
`vagrant up`, `provision`, `reload`, `ssh`, `ssh-config`, `halt` and `resume`,
the Vagrantfile therefore checks it and runs
`.\lab.ps1 ssh-cert` when it expires within 4 hours (the
lab.ps1 commands renew it themselves, so this matters only for vagrant commands you
type). Its proxy command names Windows' own `ssh.exe`: Vagrant puts an OpenSSH
of its own first in `PATH` for the programs it starts, and the lab is tested
with Windows' client. `vagrant ssh <vm>` logs in as `vagrant` with Vagrant's
per-VM key; sshd on the VMs lets `vagrant` in only through the jump host.
Vagrant alone does not install host certificates (that needs Hyper-V and the
PC's SSH CAs; `lab.ps1 up` does it), so after a VM was created or
rebuilt with `vagrant` alone, run `lab.ps1 up` before you connect to
it. Once OpenBao signs the certificates, a `vagrant` command can renew the
PC's certificate only while the vault VM runs: after a Windows restart, start
with `lab.ps1 up`.

Hyper-V checkpoints are switched off for vault (`"checkpoints": false` in
`config/lab.json`, applied by the Vagrantfile), so `vagrant snapshot` is no way
to back up OpenBao: use [Back up OpenBao](#back-up-openbao). After
`vagrant reload vault` or `vagrant up vault` OpenBao is sealed:
`.\lab.ps1 unseal`.

Use a PowerShell window that has `VAGRANT_HOME` set: the window in which
`lab.ps1 up` ran, or any window opened after its first run. In a window
opened earlier, Vagrant would use `%USERPROFILE%\.vagrant.d` on C: and would
download the box again for a new VM. (`lab.ps1 down` reads the value itself.)

To build or rebuild, prefer `lab.ps1 up`, because it guarantees the
right order (LabNet, then the firewall, then the lab VMs), applies `base.yml` and runs the
checks;
to delete, prefer `lab.ps1 down`, which also cleans up the Hyper-V folder.
The firewall itself is managed with `lab.ps1 firewall`, `lab.ps1 down
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

From each entry `lab.ps1 firewall` generates:

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
.\lab.ps1 firewall -Rebuild
```

That takes about four minutes; passwords and API key stay the same (DPAPI in
`keys\opnsense\`), and the new firewall gets a new GUI certificate from the lab
root CA (a new firewall's first one: the next `.\lab.ps1 deploy firewall`, which
`lab.ps1 up` runs by itself when it is due, replaces it with one from OpenBao's
intermediate CA, see [Renew certificates](#renew-certificates)). The new
configuration is rendered and checked before the old firewall is
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
  Each PKI role in OpenBao lists the names it may certify (`allowed_domains`
  under `openbao_pki_roles` in
  [vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml)): add the
  name to the role and run `.\lab.ps1 run openbao-config` (or
  `.\lab.ps1 deploy vault`, which runs it too; see
  [Change OpenBao's configuration](#change-openbaos-configuration)). Then, for Matrix
  (role `acme-matrix`), the route in MDAD's configuration is enough: Traefik
  orders a certificate through ACME for each host name it routes. For Keycloak
  (role `keycloak`), add the name to `openbao_cert_names` in
  [keycloak.yml](ansible/playbooks/keycloak.yml) and force a new certificate
  (`.\lab.ps1 run keycloak.yml -e tls_renew_before=+400d`):
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
  to the new address and run `.\lab.ps1 deploy matrix`; otherwise calls
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
  `.\lab.ps1 firewall -Rebuild`: slower (about four minutes), but the
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
boot failed, and a later run of `lab.ps1 firewall` removes an ISO left
behind. A comparison of whole files would be noisy anyway: OPNsense fills in
default settings, model version attributes and revision data of its own.)

While rendering, the script checks that the result is well-formed XML and that
no placeholder is left over, and stops if not. With `-Rebuild` this happens
before the old firewall is deleted, so a broken template stops the script while
the old firewall keeps running (the same idea as a deployment pipeline that
validates the new version before it takes the old one down). Check the result
on the running firewall with:

```powershell
.\lab.ps1 connect firewall 'sudo pfctl -s nat'   # port forwards (rdr) and outbound NAT
.\lab.ps1 connect firewall 'sudo pfctl -sr'      # filter rules
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
   the host has the extra RAM. `"consoleAutologin": false` (as on vault) keeps
   the normal login prompt on its Hyper-V console; without it, `base.yml` gives
   the console an autologin as ansible (a lab-only shortcut, explained in the
   header of [base.yml](ansible/playbooks/base.yml)).

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

   The group must also be listed under `[ubuntu:children]` in the same file:
   `base.yml` (zsh, console autologin) and `checks.yml` target the group
   `ubuntu`, and `checks.yml` fails when it does not hold exactly the VMs of
   `config/lab.json`:

   ```ini
   [ubuntu:children]
   control
   matrix_servers
   keycloak_servers
   vault_servers
   web
   ```

   `base.yml` logs in to the VMs with a run certificate for the principals of
   its profile `base` in [config/run-profiles.json](config/run-profiles.json),
   which lists every VM it logs in to (`host-matrix`, `host-keycloak`,
   `host-vault`; ansible-control runs it locally): add `"host-hello"` there,
   or step 6 stops at
   `base.yml` because the certificate does not open the new VM.

4. Give the firewall the new DHCP reservation (MAC -> IP), the DNS name and the
   published address. All of them are part of its configuration, which is
   rendered from `lab.json` only when the firewall is built:

   ```powershell
   .\lab.ps1 firewall -Rebuild
   ```

   Without the reservation the new VM would get a random address from the pool
   and no DNS name. The jump host's list of allowed forwarding targets
   (`PermitOpen` in its sshd drop-in) is rendered from `lab.json` too, so only
   after this step does it let SSH through to the new VM.

5. Once OpenBao is deployed, run `.\lab.ps1 deploy vault`. OpenBao's SSH
   roles are made from `lab.json`: the role `lab-hosts` certifies exactly the
   lab's host names, and the role `ansible-control` knows the principal
   `host-<vm>` of every VM. Until this run, OpenBao refuses a host certificate
   for `hello.lab.internal`.

6. Run `.\lab.ps1 up`. It adds the VM to `keys\ssh_config` and
   to the SSH trust files (both from `lab.json`), creates and provisions the
   VM, signs and installs its host certificate, checks DNS and SSH from the PC,
   and then runs `base.yml` and `checks.yml` from ansible-control, which reach
   the new VM too (step 3).

7. Write or run a playbook for the new group, and give it a run profile in
   [config/run-profiles.json](config/run-profiles.json): the SSH principals of
   its run certificate (for example `["host-hello"]`) and, if it needs OpenBao,
   the policies of its run token. For the demo in the next section:

   ```json
   "hello-nginx": { "playbook": "playbooks/hello-nginx.yml", "principals": ["host-hello"], "policies": ["ansible-web"] }
   ```

   A new policy is a file in [config/openbao/policies](config/openbao/policies),
   and the token role `ansible-run` must allow it (`allowed_policies` in
   [scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1)); `.\lab.ps1 deploy vault`
   applies both ([Change OpenBao's configuration](#change-openbaos-configuration)).
   A playbook without a profile still runs, with a warning, a certificate for
   every machine (`lab-all`) and no OpenBao token. `Test-LabLayout`
   (`.\lab.ps1 test -Name Test-LabLayout`, no lab needed) checks that every
   playbook has a profile and that every profile names an existing playbook,
   principals of machines in `config/lab.json` and existing policies.

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
  [vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml) and run
  `.\lab.ps1 run openbao-config` first.
- **The run token** of this playbook has the policy `ansible-web`: it may have
  certificates of the role `web` signed and nothing else, not even read a
  secret. Its profile `hello-nginx` in
  [config/run-profiles.json](config/run-profiles.json) asks for that policy, and
  today for the SSH principal `lab-all`: `host-hello` is accepted only once a VM
  `hello` is in `config/lab.json` (`Test-LabLayout` checks it). With the VM in
  place, narrow it to `["host-hello"]` (step 7 of [Add a VM](#add-a-vm)).

With the VM `hello` from the previous section (in `[web]`, published with ports
443 and 80), and OpenBao deployed:

```powershell
.\lab.ps1 run hello-nginx.yml
curl.exe https://hello.lab.internal      # expected: <h1>Hello World</h1>
```

The certificate is valid for one year and renewed by the same playbook when
less than 30 days are left or when it does not come from the current
intermediate CA (after a rotation); force a renewal with
`.\lab.ps1 run hello-nginx.yml -e tls_renew_before=+400d`.

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
   first `lab.ps1 deploy keycloak`, the playbook would generate it with the
   policy from step 2.) As administrator (see
   [Write or change a secret](#write-or-change-a-secret-administrator)); `cas = 0`
   refuses if the secret already exists:

   ```powershell
   . .\scripts\lib\Lab.ps1
   $token = Get-LabBaoToken 'pc-admin'
   $value = (Invoke-LabBao GET 'sys/policies/password/lab-alnum-24/generate' -Token $token).data.password
   Invoke-LabBao POST 'lab/data/keycloak/users/carol' @{ options = @{ cas = 0 }; data = @{ password = $value } } -Token $token | Out-Null
   $value = $null; Close-LabBaoToken $token
   ```

5. Run `.\lab.ps1 deploy keycloak`. It reads the new secret and creates
   the user, then takes a snapshot of OpenBao, which now contains her
   password.

6. `.\lab.ps1 secret keycloak/users/carol` copies her password to
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
  lists them (today `alice`); apply a change with `lab.ps1 deploy matrix`.

### Change a Matrix setting

All Matrix settings are MDAD variables in
[ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml).
MDAD has thousands of variables with defaults (in the `defaults/main.yml` of
its roles and in its `group_vars/matrix_servers`, both in `vendor\mdad` in
this repository, and in its copy `~/mdad` on ansible-control); the file sets
only what differs for the lab. Edit it, then:

```powershell
.\lab.ps1 deploy matrix           # adding or changing something
.\lab.ps1 deploy matrix -Setup    # after REMOVING a component (runs the uninstall tasks)
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
Check the result yourself with MDAD's self-check, which `lab.ps1 deploy matrix`
runs, and a login.)

1. **Fetch the new version into the repository.** Take the full commit hash
   (40 characters) from MDAD's
   [commit list](https://github.com/spantaleev/matrix-docker-ansible-deploy/commits/master),
   then, with the lab running and nothing uncommitted in the repository:

   ```powershell
   .\lab.ps1 mdad-upgrade -Commit <40-character commit hash>
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
   to the new commit. `lab.ps1 deploy matrix` refuses to run while it differs
   from `vendor\mdad\.lab-vendored-commit`, and `matrix-prepare.yml` checks the
   copy in `~/mdad` against it again.
4. Raise `matrix_playbook_migration_validated_version` in `vars.yml` to the
   version you read the notes up to. MDAD refuses to run until this matches,
   so nobody upgrades by accident without reading. Adjust other settings in
   `vars.yml` if the changelog says so. Commit these edits.
5. Deploy: `.\lab.ps1 deploy matrix`, or `.\lab.ps1 deploy matrix -Setup`
   if the changelog says that components were removed or renamed (only the
   tags of `setup-all` run the uninstall tasks). It copies the new
   `vendor\mdad` to `~/mdad` and runs it.
6. When everything works: `git push`.

The script prints steps 2 to 6 again when it ends. Going back to the old commit
(`git revert` of the upgrade commits, `mdad_version` back, `lab.ps1 deploy matrix`)
restores MDAD's code, but not necessarily the data: a
newer Synapse or MAS may already have migrated its database to a form that the
older version cannot read. A backup of the matrix VM's data before the upgrade
is the safe way back, and the lab has none yet ([roadmap](#11-roadmap)).

Keycloak is upgraded with a similar deliberate edit, in
[keycloak.yml](ansible/playbooks/keycloak.yml): its image is pinned, not
vendored, and `keycloak_image` holds tag
**and** digest; change both (after reading Keycloak's upgrade notes) and run
`lab.ps1 deploy keycloak`. The PostgreSQL major version (`postgres:18.6`) must not
be raised in place: a new major version cannot read the old data directory
without a dump and restore.

### Change OpenBao's configuration

OpenBao's configuration is code like the rest of the lab, but it lives in two
places, because it has two owners (why, at the end of this section). The PC
writes the **identity plane**: who may log in, and with which rights. Ansible on
ansible-control writes the **configuration plane**: the secrets engines and how
they behave.

| Plane | What | Where | Applied by |
|---|---|---|---|
| Configuration | the mounts `lab` and `pki_int`, the KV settings (check-and-set required, 10 versions), the password policies `lab-alnum-24/48/64`, the PKI's URLs (AIA, CDP), revocation list and tidying, the PKI roles (which names each service may get a certificate for), ACME | [ansible/playbooks/vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml), applied by [openbao-config.yml](ansible/playbooks/openbao-config.yml) on ansible-control | `.\lab.ps1 run openbao-config`, and every `.\lab.ps1 deploy vault` |
| Identity | the ACL policies, one file per policy (the file name is the policy's name) | [config/openbao/policies](config/openbao/policies), `<name>.hcl` | `.\lab.ps1 deploy vault` |
| Identity | the AppRoles `pc-admin`, `pc-deploy` and `recovery`, the token roles `ansible-run` and `ansible-config` (which policies a run token may get, how long it lives), the SSH engine and its roles, the intermediate CA | [scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) (`Invoke-LabVaultDeploy`, step 6; the SSH roles from `$LabSshRoles` in [scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1), the token role `ui-admin` from `Set-LabUiTokenRole` in [scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1)) | `.\lab.ps1 deploy vault` |

**A change of the configuration plane**, for example a new name in a PKI role:
edit the vars file, look at what would change, then write it:

```powershell
.\lab.ps1 run openbao-config --check --diff   # what would change; nothing is written
.\lab.ps1 run openbao-config                  # write it
```

The playbook reads each object, compares the keys the file lists and writes
only the objects that differ ("read-compare-write",
[tasks/openbao-api.yml](ansible/playbooks/tasks/openbao-api.yml)); a second run
reports `changed=0`. That is why the values are written in the form OpenBao
returns on a read (durations in seconds, lists as lists): a value in another
form would differ on every run. `-e openbao_config_force=true` writes every
object once even when it already matches, a harmless way to try each write
request. On a brand-new OpenBao, `deploy vault` runs the playbook twice: before
the intermediate CA exists (mounts, URLs) and after it (PKI roles, ACME).

The run gets a token of its own: token role `ansible-config`, policy
`openbao-config`, 30 minutes, minted only with an administrator login
(`pc-admin`; the initial root token while the bootstrap is not finished), usable
only from ansible-control and revoked when the run ends; the playbook stops if the token
has any other policy. That policy may configure the objects in the table's
first row (the mounts `lab` and `pki_int`, password policies named `lab-*`,
the PKI's configuration and roles) and nothing else. So something beyond these
paths, another secrets engine say, needs two changes: its values in the vars
file and its path in
[config/openbao/policies/openbao-config.hcl](config/openbao/policies/openbao-config.hcl).
`.\lab.ps1 deploy vault` then applies both in the right order: the policies
first, then the playbook.

**A change of the identity plane**: edit the policy file, or the tables in
`LabVault.ps1`, then run `.\lab.ps1 deploy vault`. It writes all policies,
AppRoles and token roles on every run, so the code is the truth. A new policy
for a deployment needs three things that belong together: the file, its name in
`allowed_policies` of the token role `ansible-run`, and a run profile that asks
for it ([config/run-profiles.json](config/run-profiles.json), step 7 of
[Add a VM](#add-a-vm)). `Test-LabLayout` checks that every profile names
existing policy files and that every policy file is used.

**Nothing is deleted.** Neither side removes what is no longer in the code:
`openbao-config.yml` only creates and updates (its policy has no `delete`
anywhere), and `deploy vault` writes the policy files that exist without
removing a policy whose file is gone. Removing a PKI role, a policy or a mount
is a deliberate manual step, as administrator: in the web UI (`.\lab.ps1 ui`)
or through the API with `pc-admin` (as in
[Write or change a secret](#write-or-change-a-secret-administrator)). A removed
mount takes its data with it and a removed PKI role stops the renewals that use
it, so a deletion should be a decision, not the side effect of a missing line.

**Drift.** A change made by hand in the web UI is not in the repository. If it
changes a value that the vars file names, it shows up as drift:
`.\lab.ps1 run openbao-config --check --diff` lists it,
[Test-LabOpenBaoConfig](tests/Test-LabOpenBaoConfig.ps1) (part of
`.\lab.ps1 test`) fails at "nothing to change (no drift)", and the next
`run openbao-config` or `deploy vault` sets it back. Something the file does not
name (a role added by hand, say) is not compared and goes unnoticed: one more
reason to make every change in the file. A hand change to a policy, an AppRole
or a token role is not compared as a whole by any check (the tests only
spot-check the run tokens: their policies, lifetime and address binding, and
what the config token may do), but the next `deploy vault` writes the code's
version back. To compare two states of the whole
configuration, both planes and without secret values, export it before and
after a change with
[tests/tools/Export-LabOpenBaoConfig.ps1](tests/tools/Export-LabOpenBaoConfig.ps1)
and compare the files (`git diff --no-index before.json after.json`).

**Why two planes: separation of duties.** The identity plane decides who may do
what: a policy or a token role that allows too much hands out rights. So it
stays with the PC, which holds the administrator login and the offline root,
and changes only when you run `deploy vault`. The configuration plane changes
more often (a name in a PKI role, a CRL lifetime) and is ordinary configuration
management, like every other service: Ansible applies it from the repository,
with a token for one run. That token can change how certificates are issued,
but it cannot give anyone, itself included, a new right: no policy, login,
token role or CA, no certificate and no secret (`Test-LabOpenBaoConfig` checks
this with `sys/capabilities-self`). The one dangerous thing it could do, allow
`vault.lab.internal` in a PKI role, is defused separately: the PC accepts for
OpenBao only a certificate signed directly by the root, and the root's name
constraints exclude that name for the intermediates made since
([What the CA name constraint protects](#what-the-ca-name-constraint-protects)).
Enterprise equivalent: an IAM or security team owns identities and policies, a
platform team's pipeline owns the configuration of the engines, and neither can
do the other's job alone.

### Renew certificates

The lab has two kinds of certificates. Most come from the **intermediate CA in
OpenBao** and are renewed by whoever uses them, the firewall's GUI included.
One server certificate comes directly from the **offline root on the PC**:
OpenBao's own (an expired OpenBao certificate could otherwise only be renewed
through the server it protects). A new firewall starts with a GUI certificate
from the root too, because it is built before OpenBao exists; the next
`lab.ps1 deploy firewall` replaces it with one from the intermediate. So the
root signs only CAs (the intermediate), OpenBao's TLS certificate and a new
firewall's first GUI certificate: the fewer signatures, the rarer its key is
unlocked. Renewal never needs a rebuild.

| Certificate | Issued by; where its key is made | Valid | Renewed | Force a renewal now |
|---|---|---|---|---|
| Matrix (`matrix`, `element`, `lab.internal`) | intermediate CA through ACME (role `acme-matrix`); key made by Traefik on the matrix VM, kept in `/matrix/traefik/ssl/acme.json` | 90 days | automatically by Traefik after two thirds of its lifetime (about 30 days before it expires); needs an unsealed OpenBao. After a rotation, `matrix-prepare.yml` makes Traefik start over (below) | rarely needed: `.\lab.ps1 connect matrix 'sudo rm /matrix/traefik/ssl/acme.json && sudo systemctl restart matrix-traefik'`, then `.\lab.ps1 deploy matrix`, whose checks wait up to 3 minutes for certificates from the current intermediate CA. This is by hand what `matrix-prepare.yml` does by itself after a rotation |
| Keycloak (`keycloak.lab.internal`) | intermediate CA, CSR signing (role `keycloak`); key made on the keycloak VM, a new one on every renewal | 1 year | by `lab.ps1 deploy keycloak` when less than 30 days are left (`lab.ps1 up` then runs it by itself) or the certificate is not from the current intermediate CA; Keycloak restarts | `.\lab.ps1 run keycloak.yml -e tls_renew_before=+400d` |
| hello demo (`hello.lab.internal`) | intermediate CA, CSR signing (role `web`); key made on the hello VM | 1 year | by `hello-nginx.yml`, same rule (not by `lab.ps1 up`) | `.\lab.ps1 run hello-nginx.yml -e tls_renew_before=+400d` |
| OpenBao (`vault.lab.internal`, port 8200) | offline root; key made on the vault VM and kept across renewals | 397 days | by `lab.ps1 deploy vault` when less than 30 days are left (`lab.ps1 up` then runs it by itself). It reloads OpenBao (`systemctl reload`), which reads the new certificate without sealing | no switch; every run checks the 30 days |
| Firewall GUI (`firewall.lab.internal`) | intermediate CA, CSR signing (role `firewall-gui`); key made on the firewall, a new one on every renewal. A new firewall's first certificate comes from the offline root (397 days), inside its rendered `config.xml` | 1 year | in place by `lab.ps1 deploy firewall` (`firewall.yml`, also part of `deploy all`) when less than 30 days are left, it is not from the current intermediate CA (a new firewall, a rotation) or it does not name `firewall.lab.internal`; `lab.ps1 up` runs it by itself for the first two reasons. `lab.ps1 firewall` only reports on it | `.\lab.ps1 run firewall -e firewall_gui_renew_before=+400d`; `.\lab.ps1 run firewall --check` shows whether one is due |
| Intermediate CA, today "DeployableServer Lab Intermediate CA 2026-10-24" (issuer `lab-int-20261024`) | offline root; key generated inside OpenBao (EC P-384), never exported | 3 years | replaced by a new one (a rotation) by `lab.ps1 deploy vault` when it has less than 400 days left (`lab.ps1 up` then runs it by itself). Certificates it issues never outlive it: OpenBao shortens them to its end date | `.\lab.ps1 deploy vault -RotateIntermediate` ([Rotate the intermediate CA](#rotate-the-intermediate-ca)) |
| Root CA "DeployableServer Lab Root CA 2026" | itself; key encrypted in `keys\pki` | 10 years | never automatically | a new root means trusting it again on every client (`lab.ps1 trust`) |

The SSH certificates are not in this table: they are OpenSSH certificates, not
X.509, and come from the lab's SSH CAs (the PC's for 8 hours, one per Ansible
run for 2 hours, the hosts' for 1 year). Their lifetimes and renewals are in
[SSH certificates](#ssh-certificates-user-and-host-cas).

How the in-place renewals work, in short: Keycloak's and hello's come from
[tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml):
a new key and CSR are made next to the current pair (`<key>.new`), OpenBao
signs the CSR, and key and certificate replace the old pair together, so the
service never sees a key that does not match its certificate. The firewall's
works the same way across machines: [firewall.yml](ansible/playbooks/firewall.yml)
has the firewall make the key and CSR in a private temporary folder, OpenBao
signs the CSR (role `firewall-gui`, requested from ansible-control with the
run's token, whose policy `ansible-firewall` allows nothing else), and
[opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php) installs key, certificate
and the intermediate CA through OPNsense's own configuration code (what
System > Trust does in the GUI); then the web GUI restarts, serving the chain
(certificate, intermediate, root), and the folder is removed. Traefik does all
of it by itself with ACME: it proves to OpenBao that it serves the name (HTTP-01:
OpenBao fetches a token from `http://<name>/.well-known/acme-challenge/` from
the vault VM, over the lab's DNS) and receives the certificate.

**"From the current intermediate CA"** is decided by key identifiers, not by
names: a certificate comes from the current intermediate when its *authority
key identifier* equals the *subject key identifier* of OpenBao's current issuing
CA (`pki_int/ca/pem`). `tasks/openbao-certificate.yml` (Keycloak, hello),
`matrix-prepare.yml` (Traefik), `firewall.yml` (the firewall's GUI), the checks
of `lab.ps1 deploy matrix` and the PC's maintenance check for the firewall
(`Get-LabMaintenanceDue`) all compare this way; why names are not enough is
explained in
[Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation).

**Revocation lists.** Every certificate names where its CA publishes its
revocation list (CRL), served by the vault VM on port 80, and Windows checks
them. Two kinds of list exist:

- **The root's CRL**, valid 400 days. `Update-LabRootCrl` in
  [scripts/lib/LabPki.ps1](scripts/lib/LabPki.ps1) renews it when less than 60
  days are left, also whenever the root signs something (a new firewall's first
  GUI certificate, say); `lab.ps1 deploy vault` calls it in its first step and then
  publishes the list (`openbao.yml` copies `keys\pki\pub\root-ca.crl` to the
  vault VM), and `lab.ps1 up` runs `lab.ps1 deploy vault` when the list is due
  or the copy the vault VM serves differs from the PC's. To renew it earlier by
  hand: `. .\scripts\lib\Lab.ps1; Update-LabRootCrl -Force`, then
  `.\lab.ps1 deploy vault`; renewing alone changes only the PC's copy.
  An expired root CRL breaks revocation checks for every lab certificate:
  `curl.exe` fails, Windows reports the revocation server as offline.
- **One CRL per intermediate CA**, valid 7 days, rebuilt by OpenBao itself
  before it expires, also for an older intermediate that is kept after a
  rotation (`pki_int/config/crl` in
  [vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml)). They
  are served only while OpenBao is unsealed.

The routine that keeps everything valid: `lab.ps1 up` after every
Windows restart, and at least once a month if the PC runs longer. Its
maintenance step (step 7) runs `lab.ps1 deploy vault`, `lab.ps1 deploy keycloak`
and `lab.ps1 deploy firewall` when something of theirs is due
([After a Windows restart](#after-a-windows-restart)); `.\lab.ps1 maintain` runs
the same step on its own (`-List` only shows what is due). Traefik renews
Matrix's by itself. Keep OpenBao unsealed. `lab.ps1 deploy matrix` checks that the three
Matrix certificates come from the current intermediate, but prints no expiry dates;
`.\lab.ps1 test -Name Test-LabCertificates` checks that every HTTPS certificate has more than
30 days left, and the browser shows each one's dates.

Enterprise equivalent: short-lived certificates renewed automatically by an
agent or ACME client on every server (as Traefik does here), expiry monitoring
with alerts, and the offline root used only in a planned ceremony, for example
to sign the next intermediate CA well before the current one expires (the lab
does that 400 days ahead).

### Rotate the intermediate CA

The intermediate CA in OpenBao signs every everyday certificate, so it must
stay valid longer than the longest certificate it issues (Keycloak's and the
firewall's GUI certificate, 1 year).
`lab.ps1 deploy vault` therefore makes a new one when the current one has less
than 400 days left, about 23 months into its 3 years. Replacing a CA this way,
while the old one stays valid, is a **rotation**. Tested in this lab on
2026-10-24 (with `-RotateIntermediate`, then both deployments). To rotate now,
for example after a suspected compromise of its key, or to try it (a real
compromise would also need the old intermediate revoked in the root's CRL,
which no script does yet):

```powershell
.\lab.ps1 deploy vault -RotateIntermediate   # a new intermediate CA, now the default issuer
.\lab.ps1 deploy keycloak                     # Keycloak moves to it (and a snapshot)
.\lab.ps1 deploy matrix                       # Traefik moves to it (and a snapshot)
.\lab.ps1 deploy firewall                     # the firewall's GUI certificate moves to it
```

What `lab.ps1 deploy vault` does:

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
`keycloak.yml` (and `hello-nginx.yml`) requests a new certificate,
`firewall.yml` (`lab.ps1 deploy firewall`) has the firewall's GUI certificate
signed again, and `matrix-prepare.yml` sees that Traefik serves a certificate
from an older lab intermediate, deletes `/matrix/traefik/ssl/acme.json`
(Traefik's ACME account and certificates) and restarts `matrix-traefik`, which
registers again and orders new certificates. `lab.ps1 deploy matrix` then waits
until all three names serve a certificate from the current issuer. The firewall
keeps the intermediate itself in its configuration, to send the chain:
[opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php) adds the new one and
removes the old one from the firewall's trust store (System > Trust in the
GUI) once no certificate points to it any more. Nothing changes for
Windows or the services' trust stores: both intermediates chain to the same
root.

Run the deployments right after a rotation even though nothing forces you
to (the old certificates stay valid until they expire): they move the services
over, and the snapshots of `deploy keycloak` and `deploy matrix` save the new
intermediate's key, which exists only in OpenBao (`deploy firewall` takes none).
After a rotation that `lab.ps1 up` started by itself, run them too; if you do
not, the firewall's GUI certificate follows at the next `lab.ps1 up`, whose
maintenance step sees that it is not from the current intermediate.

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
   . .\scripts\lib\Lab.ps1
   $token = Get-LabBaoToken 'pc-admin'
   $path = 'keycloak/clients/matrix-authentication-service'
   $version = (Invoke-LabBao GET "lab/metadata/$path" -Token $token).data.current_version
   $value = (Invoke-LabBao GET 'sys/policies/password/lab-alnum-48/generate' -Token $token).data.password
   Invoke-LabBao POST "lab/data/$path" @{ options = @{ cas = $version }; data = @{ secret = $value } } -Token $token | Out-Null
   $value = $null; Close-LabBaoToken $token
   ```

2. `.\lab.ps1 deploy keycloak`: the client task sets the new secret in
   Keycloak, and the snapshot at the end of the script saves the new version.
3. `.\lab.ps1 deploy matrix`: `lab-setup.yml` reads the new version, MDAD
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

- a snapshot ([Back up OpenBao](#back-up-openbao)). `lab.ps1 down` takes one
  right before it deletes the vault VM, so after `lab.ps1 down vault` the
  newest one is in `keys\openbao-retired-<date-time>\snapshots`; or a copy
  elsewhere;
- the files of the installation the snapshot came from: its key shares A and B
  and its logins `pc-admin` and `pc-deploy`, all in that same
  `keys\openbao-retired-<date-time>` folder. The scripts use them only from
  `keys\openbao`, so step 3 moves them back. Each one can also be read where it
  is, for example share A for `lab.ps1 unseal -Interactive`:
  `.\lab.ps1 secret -Pc openbao-retired-<date-time>/unseal-a -Show`
  (without `-Show` it goes to the clipboard). DPAPI binds each file to its
  original name `openbao/<name>`, and the scripts map a retired name back to it.

If the vault VM still exists but is broken, so that OpenBao cannot be reached
or unsealed, `lab.ps1 down vault` cannot take a fresh snapshot. It warns,
names the newest snapshot already in `keys\openbao\snapshots` and goes on; that
snapshot moves to `keys\openbao-retired-<date-time>` with the rest, and it is the
one to restore. Only if there is no snapshot at all while keycloak or matrix
exist, it refuses and deletes nothing: OpenBao's data on the VM is then the only
copy of their secrets, so try to bring it up first (`.\lab.ps1 up`).
Only when you are sure that it is lost, delete the VM yourself (in the `vagrant`
folder, elevated: `vagrant destroy -f vault`; then remove its leftover Hyper-V
folder, see [P14](#p14-a-removed-vm-leaves-its-hyper-v-folder-behind)) and run
`.\lab.ps1 down vault`: with the VM gone, it takes no snapshot; it
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
   `lab.ps1 down` if it has run already). Skip `lab.ps1 recovery` for
   this temporary installation (ignore its "PENDING" line), and deploy nothing
   else yet.

   ```powershell
   .\lab.ps1 down vault
   .\lab.ps1 up
   .\lab.ps1 deploy vault
   ```

2. Force the snapshot into it, as the temporary installation's administrator:

   ```powershell
   . .\scripts\lib\Lab.ps1
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
   .\lab.ps1 unseal
   .\lab.ps1 connect vault 'sudo systemctl restart openbao'   # only if it reported "already unsealed"
   .\lab.ps1 unseal
   ```

5. Re-apply the configuration from the code, check, and deploy:

   ```powershell
   .\lab.ps1 up            # the machines stop trusting the temporary SSH CA; the offline SSH CA signs
   .\lab.ps1 deploy vault           # logs in with the restored pc-admin; finds the restored intermediate CA; step 8: the restored SSH CA trusted everywhere
   .\lab.ps1 secret -List      # the secrets are back
   .\lab.ps1 deploy keycloak
   .\lab.ps1 deploy matrix
   ```

6. Make a new recovery file: `.\lab.ps1 recovery -Renew` (in your
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
kit: once the snapshot is restored, `.\lab.ps1 recovery -Recover
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
two `keys\ssh\openbao-ca.*` files aside as in step 3 and run `lab.ps1 up`
before `lab.ps1 deploy vault`, which creates a new SSH CA and makes it trusted.)

Enterprise equivalent: a written and rehearsed restore procedure, snapshots
off-site, the key shares (or recovery keys) held by several custodians who
meet for a recovery, and break-glass credentials that are kept sealed, used
only under four-eyes control and replaced after every use. A replicated standby
cluster makes most restores unnecessary.

### Renew the recovery kit

The recovery kit is made once per OpenBao installation, right after it was
initialised: `.\lab.ps1 recovery` without a switch shows key
share C, writes the recovery file and then deletes the PC's temporary copy of
share C (what the kit is and why:
[Break-glass: the recovery kit](#break-glass-the-recovery-kit)). Run without a
switch again, it refuses and points to `-Renew`, the way to a new recovery file
later:

```powershell
.\lab.ps1 recovery -Renew -Destination E:\                      # a USB stick
.\lab.ps1 recovery -Renew -Destination Z:\DeployableServer-recovery   # a NAS share
.\lab.ps1 recovery -Renew                                       # keys\recovery on the PC
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
`keys\ssh\offline-ca.in-recovery-kit`), so that `lab.ps1 up` and
`lab.ps1 deploy vault` can tell when the file is out of date. Share C is not
shown again: your copy stays valid. A file in
`keys\recovery` does not survive a lost Windows installation; copy it somewhere
else.

**The break-glass login.** Its secret ID exists only in the recovery file:
every kit, `-Renew` included, creates a new one and, once the new file is
written and verified, destroys all older ones (`New-LabAppRoleSecret` and
`Remove-LabAppRoleSecretIds` in [scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1)).
So only the newest file has a working break-glass login. Older files still hold
a valid share B, so they can still unseal together with share C: keep only the
newest, as the script says, and destroy the older ones; one you still keep must
be guarded as well as the newest. Why the lab needs such a login:
[Break-glass: the recovery kit](#break-glass-the-recovery-kit).

Make a new file:

- when `lab.ps1 deploy vault` ends with `PENDING: your recovery file has no
  break-glass login ...`: a file made before that login existed can still
  unseal, but not give the PC its access back. Do it while the PC's DPAPI keys
  still work;
- when `lab.ps1 up` or `lab.ps1 deploy vault` ends with `PENDING: your
  recovery file has no copy of the current offline SSH CA ...`: the file was
  made before the offline SSH CA existed, or the CA is new. `-Renew` adds it;
  without it, a lost Windows profile would also make the SSH CA that every lab
  machine trusts for break-glass unusable (its passphrase is in DPAPI);
- after `-Recover` (next section): the break-glass secret has been used;
- after a restore from a snapshot (previous section);
- when the passphrase should change, or the file was lost or may have been
  copied.

To look into a file, `.\lab.ps1 recovery -Open <file>` asks for
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
in this lab: the steps follow `lab.ps1 recovery` but have not been run
end to end. They assume that the lab's VMs and the project folder with `keys\`
still exist; after a new Windows installation, which loses the VMs' registration
in Hyper-V too, more is needed, and that is not covered here.

1. Start the VMs `firewall` and then `vault` in Hyper-V Manager, if they are not
   running. `-Recover` needs OpenBao to answer, and `lab.ps1 up` cannot
   run yet: it unseals OpenBao with the key shares from DPAPI.
2. Restore the PC's access, in your own PowerShell window:

   ```powershell
   .\lab.ps1 recovery -Recover E:\DeployableServer-recovery-2026-10-24.bin
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
     `lab.ps1 up` stops in its step 2 because the passphrase is
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
     that `lab.ps1 unseal` and `lab.ps1 up` unseal without input
     again. Share B keeps its name, so a renewed recovery file holds share B
     again, and the file and your copy of C stay two different shares.

   A recovery file made before the break-glass login existed is refused with a
   message; with it you can still unseal (`.\lab.ps1 unseal
   -Interactive`), but not administer OpenBao. A file made before the
   firewall's `ansible` password and API key were included restores only its
   root password, and says so: nothing needs the other two on a running
   firewall, and the next `.\lab.ps1 firewall -Rebuild` makes new
   ones.
3. Run `.\lab.ps1 up` as after a Windows restart.
4. Make a new recovery file with `.\lab.ps1 recovery -Renew`
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
[scripts/commands/firewall.ps1](scripts/commands/firewall.ps1),
[scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1) (renders `config.xml`).

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
`lab.ps1 up`, its text from `Get-LabSshConfigText` in
[scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1)) contains `ProxyJump firewall` for
every lab VM. Vagrant uses the same path through `ssh.proxy_command` in the
Vagrantfile. Here the bastion is OPNsense's own SSH server, listening only on
LAN and HOST, open only to members of the `admins` group (OPNsense allows only
the Unix group `wheel` to log in, and only full administrators are put into
it), and locked down to its one job by a drop-in that `lab.ps1 firewall`
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
GUI certificate on the serial console, and `lab.ps1 firewall` reads that
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
Files: [scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1),
[scripts/commands/up.ps1](scripts/commands/up.ps1),
[scripts/commands/connect.ps1](scripts/commands/connect.ps1), [vagrant/Vagrantfile](vagrant/Vagrantfile),
[scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1) (first boot, `Update-FirewallSsh`),
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
`config/lab.json`). `lab.ps1 firewall` turns every VM in that file into a
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
[scripts/commands/firewall.ps1](scripts/commands/firewall.ps1),
[scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1),
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
`lab.ps1 firewall` copies over SSH into `/usr/local/etc/dnsmasq.conf.d/` and
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
[scripts/commands/firewall.ps1](scripts/commands/firewall.ps1),
[scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1) (`Install-DnsDropIn`),
[scripts/host/Initialize-LabHost.ps1](scripts/host/Initialize-LabHost.ps1).

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
|   +-- firewall.lab.internal                        the firewall's web GUI: CSR signing by Ansible, 1 year
|   +-- matrix, element, lab.internal                ACME by Traefik, 90 days, renewed automatically
|   +-- hello.lab.internal                           CSR signing (the nginx demo), 1 year
|
+-- DeployableServer Lab Intermediate CA 2026        the first one (lab-int-2026), replaced on
|                                                    2026-10-24: issues nothing new, its CRL stays
|
+-- vault.lab.internal                               OpenBao's own HTTPS, 397 days
+-- firewall.lab.internal (a new firewall only)      its first GUI certificate, 397 days, until
                                                     lab.ps1 deploy firewall replaces it (below)
```

**The offline root** ([scripts/lib/LabPki.ps1](scripts/lib/LabPki.ps1))
is created once on the PC, with the OpenSSL of Git for Windows: a self-signed
certificate "DeployableServer Lab Root CA 2026" with an EC P-384 key. The key
file `keys\pki\root-ca.key` is encrypted (PKCS#8, AES-256, 600,000 PBKDF2
iterations). Its random passphrase is stored with DPAPI (see
[Secrets management with OpenBao](#secrets-management-with-openbao)) and handed
to openssl in an environment variable, never on a command line (the command
lines of running processes are visible to other programs). "Offline" means: on
no server, and used only for a handful of signatures: the intermediates,
OpenBao's own TLS certificate, the first GUI certificate of a new firewall (the
two at the bottom of the tree), and its own revocation list.

**Why two levels**: the root is what every client imports. A CA that issues
everyday certificates has to be online, and an online CA is exposed. If the
root itself were online and compromised, every client would have to be
touched. A compromised intermediate is revoked by the root and replaced, and
the clients keep trusting the root.

**The intermediate** lives in OpenBao's PKI secrets engine, mounted at
`pki_int`. `lab.ps1 deploy vault` has OpenBao generate the key inside itself
(EC P-384, type "internal": it cannot be exported) together with a CSR; the
root signs the CSR on the PC (3 years), and the signed certificate goes back
into OpenBao as an *issuer*. The *default issuer* issues the everyday
certificates, and none of them can outlive it (`leaf_not_after_behavior:
truncate`). An intermediate is not forever: 400 days before it expires,
`lab.ps1 deploy vault` makes a new one and makes it the default (a rotation, see
[Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation)).
Names in OpenBao must be unique, so the first intermediate's names carry the
year and each rotation's the date (its key and issuer name also the time); the
diagram above shows the current state.

**Who configures the PKI: the PC and Ansible.** The PC makes the intermediate
itself, because only the PC holds the root key: in step 6 of
`lab.ps1 deploy vault` ([scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1)) OpenBao makes the key
and the CSR, the root signs on the PC, and the PC imports the certificate and
sets it as the default issuer. Everything else about the engine (the `pki_int` mount and its
tuning, the AIA and CDP URLs, the CRL settings, auto-tidy, the PKI roles and ACME) is OpenBao's
*configuration plane*, written by Ansible on ansible-control
([openbao-config.yml](ansible/playbooks/openbao-config.yml), profile `openbao-config`, desired
values in [vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml)) with a token that
cannot sign or issue a certificate; the how and why, and the enterprise equivalent, are in
*Two planes* under [Secrets management with OpenBao](#secrets-management-with-openbao).

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
  The intermediates also exclude one name: OpenBao's own, `vault.lab.internal`
  (the intermediate profile in `LabPki.ps1`), so nothing an intermediate issues can
  be valid for it. Only the root vouches for OpenBao. An intermediate signed before
  that exclusion existed lacks it; for those, the PC's TLS pin does the same job
  (*Certificate pinning for OpenBao on the PC*, below): for `vault.lab.internal`
  it accepts only a certificate the root signed directly.
- **PKI roles** in OpenBao narrow it further. A role says what may be issued.
  OpenBao's defaults are permissive (`localhost`, IP addresses, wildcards,
  client certificates), so every lab role states its rules explicitly: exact
  names only (no subdomains, no wildcards, no `localhost`, no IP addresses),
  server certificates only, a fixed lifetime, and always the default issuer
  (`openbao_pki_roles` in [vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml),
  written by `openbao-config.yml`).

| PKI role | Names | Used through | Lifetime |
|---|---|---|---|
| `keycloak` | `keycloak.lab.internal` | CSR signing by `keycloak.yml` (EC P-256 keys only) | 1 year |
| `firewall-gui` | `firewall.lab.internal` | CSR signing by `firewall.yml`, the key made on the firewall (EC P-256 keys only) | 1 year |
| `acme-matrix` | `matrix.lab.internal`, `element.lab.internal`, `lab.internal` | ACME only (Traefik) | 90 days |
| `web` | `hello.lab.internal` | CSR signing by `hello-nginx.yml` (EC P-256 keys only) | 1 year |

**Two ways to get a certificate from the intermediate**:

- **CSR signing** (Keycloak and the nginx demo,
  [tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml);
  the firewall's GUI the same way in [firewall.yml](ansible/playbooks/firewall.yml), below):
  the server makes its own private key and a certificate signing request (CSR:
  the names and the public key, signed with the private key to prove that the
  requester holds it). Only the CSR travels: from ansible-control, which holds
  the run token, to OpenBao (`pki_int/sign/<role>`), and the token's policy
  allows exactly that one role (`ansible-keycloak`: `keycloak`, `ansible-web`:
  `web`, `ansible-firewall`: `firewall-gui`). The certificate comes back and is
  installed followed by the intermediate. The private key never leaves the
  server. Renewal happens during a deployment run, when less than 30 days are
  left or when the certificate was not issued by the current intermediate (its
  *authority key identifier* is compared with the intermediate's *subject key
  identifier*, see [Certificate lifecycle](#certificate-lifecycle-renewal-maintenance-and-rotation)).
  Each renewal makes a new key next to the old one (`tls.key.new`; on the
  firewall in a private temporary folder, below), and key and
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

**Why the root signs OpenBao directly, and a new firewall once.** Both must work
before or without the intermediate:

- **OpenBao's own HTTPS** (`vault.lab.internal:8200`) must serve TLS while
  OpenBao is sealed or not yet initialised, and a certificate from OpenBao
  itself could, once expired, only be renewed through the server it protects.
  `lab.ps1 deploy vault` has the vault VM make a key (kept across renewals) and
  a CSR, signs the CSR with the root on the PC (397 days, renewed when less than
  30 days are left) and installs the certificate. Then it reloads OpenBao
  (`systemctl reload openbao`, a SIGHUP), which reads the new files at once; a
  reload does not seal OpenBao, a restart would. OpenBao also watches the files
  itself (`tls_auto_reload`).
- **The firewall** is built before any other VM, the vault VM gets its address
  and DNS from it, and its GUI is the way in when something else is broken. A
  new firewall gets its first GUI certificate from the root, in its first
  configuration (`Get-GuiCertificate` in
  [scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1)): the key is
  made on the PC in a temporary folder and travels only inside the seed ISO,
  which is deleted on every way out of the build, also when the first boot
  fails ([Automating an appliance's first boot](#automating-an-appliances-first-boot-over-the-serial-console)).
  That is the only time the root signs for the firewall. From then on its GUI
  certificate is an ordinary server certificate from the intermediate, like
  Keycloak's, and renewing it is Ansible's job (next paragraph).

**The firewall's GUI certificate from the intermediate.**
[ansible/playbooks/firewall.yml](ansible/playbooks/firewall.yml) renews it **in place**. It runs as
the profile `firewall`: `.\lab.ps1 deploy firewall`, which `deploy all` includes, and the
maintenance step of `lab.ps1 up` when the certificate is due. The run gets an SSH certificate for
`host-firewall` only and an OpenBao token of the policy `ansible-firewall`, which allows
`pki_int/sign/firewall-gui` and nothing else.

1. It reads the certificate the web GUI serves, from ansible-control, the way a client sees it.
   A new one is due when the served one expires within 30 days, was not issued by the current
   intermediate (its AKI is not the intermediate's SKI: a new firewall's certificate from the root,
   or one from before a rotation), or does not name `firewall.lab.internal`. Otherwise nothing
   changes (`changed=0`).
2. The firewall makes the new key (EC P-256) and a CSR with its own openssl, in a private
   temporary folder (`mktemp`, `umask 077`: only root can read the key). Only the CSR travels, to
   ansible-control, which holds the run token and has OpenBao sign it (PKI role `firewall-gui`,
   1 year).
3. [opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php), run as root on the firewall, checks that
   key and certificate belong together and that the intermediate signed the certificate. Then it
   writes key, certificate and intermediate into `config.xml` through OPNsense's own configuration
   library (`config.inc`, `write_config()`, which also keeps the previous version under System >
   Configuration > History), the way the GUI's System > Trust pages would: the intermediate gets a
   `<ca>` entry of its own (with the `uuid` attribute the Trust pages address entries by), linked
   to the entry of the root, so the GUI serves the chain leaf, intermediate, root; the GUI
   certificate's entry is updated in place; an intermediate that nothing points to any more (after
   a rotation) is removed.
4. The web GUI restarts (`rc.restart_webgui`), the temporary folder is deleted (the key now lives
   only in `config.xml`), and the playbook waits until the GUI serves a certificate from the
   current intermediate. No rebuild is needed.

`.\lab.ps1 run firewall --check` shows whether a renewal is due;
`.\lab.ps1 run firewall -e firewall_gui_renew_before=+400d` forces one. `lab.ps1 firewall` does not
renew the certificate: after a build or check it only reports on it (`Show-GuiCertificate`) and
names `.\lab.ps1 deploy firewall` when it is due.

Enterprise equivalent: the root signs only intermediates, and systems that must
exist before the online CA (the CA's own servers, network devices) get their
certificates from a separate intermediate or a dedicated bootstrap process. The
lab saves itself that third CA, at the price of using the root key a few times
a year. Once the issuing CA runs, an appliance such as the firewall is enrolled
from it (ACME, SCEP or an automation job like `firewall.yml`), never from the root.

**The chain a server sends**: its own certificate followed by the intermediate,
never the root. The client already has the root in its trust store and builds
the chain leaf -> intermediate -> root itself. A server that sent only its own
certificate would fail with clients that cannot fetch a missing intermediate
(OpenSSL, curl on Linux); Windows can, through the AIA URL below. The firewall's
web GUI also sends the root, because OPNsense builds the chain from the `<ca>`
links in `config.xml` (above). That does no harm: a client trusts the root
because it is in its own trust store, never because a server sent it.

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
| Root | 400 days | by `lib\LabPki.ps1` when less than 60 days are left; it runs at the start of every `.\lab.ps1 deploy vault`, which also copies the new list to the vault VM, and before every other signature of the root (a new firewall's first GUI certificate, in `lab.ps1 firewall`), which does not copy it; so `lab.ps1 up` runs `lab.ps1 deploy vault` by itself when the list is due or the copy the vault VM serves differs from the PC's. No `lab.ps1` switch forces it earlier (by hand: `Update-LabRootCrl -Force`, then `.\lab.ps1 deploy vault`); every run checks the 60 days |
| Intermediates | 7 days | by OpenBao itself, 2 days before it expires, for every issuer it holds (the replaced one too). OpenBao builds and serves them only while it is unsealed; Windows caches a CRL it has fetched until the CRL's own expiry |

OpenBao also removes expired certificates from its store once a day
(auto-tidy). The lab publishes CRLs only, no OCSP (an online responder that
answers for one certificate at a time): one service fewer. Revoking a
certificate before it expires is an operation in OpenBao (web UI or API); it
has not been needed in this lab yet.

**Trust distribution.** `.\lab.ps1 trust` imports
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
server. Only public files leave the PC: `lab.ps1 run` copies the
root certificate and its CRL to `~/lab-pki` on ansible-control, and the root
key stays in `keys\pki`. Enterprises distribute their root certificates with
Group Policy or MDM and bake them into their base container images.

**Certificate pinning for OpenBao on the PC.** The PC's scripts send key
shares, logins and tokens to OpenBao, so they check its certificate more
strictly than Windows would: for OpenBao's host name (`vault.lab.internal`), a
certificate is accepted only if the lab root signed it **directly**, a chain of
exactly two (the certificate and `keys\pki\root-ca.crt`, compared by
thumbprint), and the host name matches, whatever else Windows trusts. A root
that is in the Windows store for another reason (the retired first lab CA, or
the root of security software that inspects TLS traffic) is not enough, and
neither is a certificate for that name from OpenBao's own intermediate:
whoever could get one issued (for example by changing a PKI role, which the
configuration plane may do) could otherwise pose as OpenBao to the PC and
receive the unseal key shares and AppRole logins it sends. OpenBao's own
certificate comes from the root anyway (above), so the rule costs nothing; the
name constraint of the intermediates says the same, and the pin also covers
intermediates signed before that constraint. This also works before you have
imported the root into Windows. The check is a .NET callback
([scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1), type `LabTlsPin3`;
[tests/Test-LabTlsPin.ps1](tests/Test-LabTlsPin.ps1) checks that a chain through
the intermediate is refused for the pinned name), and .NET applies such a
callback to every HTTPS request of the PowerShell process, so it is scoped by
host name: other HTTPS addresses
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
`.\lab.ps1 trust` imports only the 2026 root and says so when
Windows still trusts the retired one; taking that trust back is a step you run
yourself: `.\lab.ps1 trust -RemoveRetired`. That is the usual
order for replacing a CA hierarchy: trust the new root everywhere, issue again,
remove the old root last.

Enterprise equivalent: the offline root on an air-gapped machine or in an HSM,
used in a documented key ceremony with several people present; one or more
online issuing CAs (Microsoft AD CS, Vault or OpenBao PKI, smallstep step-ca,
EJBCA) with their keys in HSMs; ACME or certificate agents (cert-manager,
certmonger, Vault Agent) renewing short-lived certificates automatically; CRLs
and OCSP.
Files: [scripts/lib/LabPki.ps1](scripts/lib/LabPki.ps1),
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) (intermediate),
[openbao-config.yml](ansible/playbooks/openbao-config.yml) and
[vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml) (mount, URLs, CRL, roles,
ACME), [tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml),
[vars.yml](ansible/matrix/inventory/host_vars/matrix.lab.internal/vars.yml)
(section "TLS"), [scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1) (a new
firewall's first certificate), [firewall.yml](ansible/playbooks/firewall.yml),
[opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php),
[nginx-pki.conf.j2](ansible/templates/openbao/nginx-pki.conf.j2),
[scripts/host/Install-LabRootCA.ps1](scripts/host/Install-LabRootCA.ps1),
[scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1) (pinning).

### Certificate lifecycle: renewal, maintenance and rotation

Every certificate is valid for a fixed time, and so is every revocation list.
Short lifetimes limit what a stolen key is worth, but only if renewal is
automatic: an expired certificate is one of the most common causes of outages.
In the lab every item has an owner that renews it; the table in
[Renew certificates](#renew-certificates) lists each one with its lifetime, its
renewal rule and the command that forces a renewal. The owners are of two
kinds. Services that run all the time renew by themselves: Traefik its Matrix
certificates through ACME (90 days, renewed 30 days before they expire), OpenBao
the intermediates' revocation lists (7 days). Everything else is renewed only
when its command runs: `lab.ps1 deploy keycloak` Keycloak's certificate and
`lab.ps1 deploy firewall` the firewall's GUI certificate (both Ansible runs on
ansible-control), `lab.ps1 deploy vault` OpenBao's own certificate, the root's
revocation list and the intermediate CA (the PC, which alone holds the root key).

**Maintenance after every Windows restart.** For the second kind,
`lab.ps1 up`, which you run after every Windows restart anyway
([After a Windows restart](#after-a-windows-restart)), ends with step 7/7
"Maintenance" (once OpenBao is deployed): `Get-LabMaintenanceDue`
([scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1)) looks at what is due from
public information only (the certificates the servers present, the root CRL on
the PC and on the vault VM, the CA certificate OpenBao serves without a token),
and the step (`Invoke-LabMaintenance` in
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1)) runs `lab.ps1 deploy vault`,
`lab.ps1 deploy keycloak` and/or `lab.ps1 deploy firewall` for it:

| Due item | Checked | Action |
|---|---|---|
| OpenBao's TLS certificate | expires within 30 days | `deploy vault` |
| The root CA's revocation list | next update within 60 days, or the copy the vault VM serves differs from the PC's | `deploy vault` |
| The intermediate CA | expires within 400 days | `deploy vault` |
| Keycloak's TLS certificate | expires within 30 days | `deploy keycloak` |
| The firewall's GUI certificate | expires within 30 days, **or** not issued by the current intermediate (its AKI is not the intermediate's SKI: a new firewall's first certificate from the root, or one from before a rotation) | `deploy firewall` |

The same list is behind `.\lab.ps1 status` (what is due) and `.\lab.ps1 maintain`
(renew it now; `-List` only shows it). `lab.ps1 firewall` in step 4 only reports on
the firewall's certificate; renewing it is Ansible's job (`firewall.yml`). Nothing
is scheduled beyond that: a PC that runs for weeks without a restart needs a
manual run; the margins of 30 days and more leave time for that.

**Which CA issued this certificate? Key identifiers, not names.** Every
certificate carries a *subject key identifier* (SKI, derived from its own public
key), and every certificate a CA issues carries that CA's SKI as its *authority
key identifier* (AKI). Names are not unique: a rebuilt vault VM makes a new
intermediate with the same name as the one before, and two CAs can simply be
called alike. Comparing the AKI of a server's certificate with the SKI of the
current intermediate (OpenBao serves its certificate at `pki_int/ca/pem`,
without a token) answers exactly one question: was this certificate issued by
the CA that issues today? The lab asks it in these places:
[tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml)
and [firewall.yml](ansible/playbooks/firewall.yml) (a mismatch counts as due, as
an expiry would), [matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml)
(Traefik starts over, below), [matrix-check.yml](ansible/playbooks/matrix-check.yml)
(at the end of `lab.ps1 deploy matrix`, it waits until Traefik serves certificates
of the current issuer), and on the PC `Get-LabMaintenanceDue` (the firewall's
certificate, above) and [tests/Test-LabCertificates.ps1](tests/Test-LabCertificates.ps1),
which expects every certificate from the intermediate, the firewall's included,
to come from the current one.

**Rotating the intermediate.** An intermediate must outlive the certificates it
issues: with `leaf_not_after_behavior: truncate`, a certificate issued less than
a year before the intermediate expires would be cut short. So
`lab.ps1 deploy vault` makes a new intermediate when the default issuer has less
than 400 days left (with 3 years of validity, after about 23 months), or at once
with `.\lab.ps1 deploy vault -RotateIntermediate` (after a suspected key
compromise, or to try it). The old and the new CA overlap:

- The new issuer becomes the default issuer of `pki_int` at once; every new
  certificate comes from it.
- The old issuer stays in OpenBao. Its certificates remain valid until they
  expire, each of them names its own issuer's CRL, and OpenBao keeps
  publishing that CRL.
- The services move over at their next deployment, each recognising an old
  certificate by its AKI. Keycloak and the nginx demo simply get a new
  certificate, and so does the firewall's GUI, also at the next `lab.ps1 up`,
  whose maintenance step sees the old issuer; `lab-gui-cert.php` then removes
  the old intermediate's entry from `config.xml`. Traefik needs a push: it
  would keep its certificates until its regular renewal, and after a rebuild
  of the vault VM the new OpenBao would not even know Traefik's ACME account.
  So `matrix-prepare.yml` deletes Traefik's ACME store and restarts it when
  Traefik serves a certificate from an older lab intermediate (its own
  self-signed default certificate, served while ACME is not finished yet, is no
  reason to start over).
- The clients notice nothing: they trust the root, which signed both
  intermediates.

The steps, the names the new intermediate gets and the commands are in
[Rotate the intermediate CA](#rotate-the-intermediate-ca).

Enterprise equivalent: certificate lifecycle management, that is an inventory of
every certificate, monitoring and alerts before expiry, and renewal by agents or
ACME (cert-manager, Vault Agent, products such as Venafi or Keyfactor); CA
rotations planned with overlapping validity, the new CA issuing while the old
one keeps publishing its CRL until its last certificate has expired.
Files: [scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1) (`Get-LabMaintenanceDue`),
[scripts/commands/up.ps1](scripts/commands/up.ps1) (step 7/7),
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) (steps 2 and 6, `Invoke-LabMaintenance`),
[tasks/openbao-certificate.yml](ansible/playbooks/tasks/openbao-certificate.yml),
[firewall.yml](ansible/playbooks/firewall.yml),
[matrix-prepare.yml](ansible/playbooks/matrix-prepare.yml),
[matrix-check.yml](ansible/playbooks/matrix-check.yml),
[scripts/commands/deploy.ps1](scripts/commands/deploy.ps1).

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
| Key | ed25519, `keys\ssh\offline-ca` on the PC, encrypted with a random 48-character passphrase stored with DPAPI ([scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1)); a copy of both in the recovery file | ed25519, generated inside OpenBao (secrets engine `ssh`, [scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) step 6), never exported |
| Signs | the bootstrap (OpenBao not deployed yet, or its SSH CA not yet trusted everywhere); while OpenBao's own TLS certificate has expired (renewing it needs SSH to the vault VM, so that must not depend on OpenBao); and break-glass, only when you ask for it | everything else: the PC's certificate, each Ansible run's, the host certificates |
| Recorded | in `keys\ssh\issued.log` on the PC, and in each machine's sshd log at login (key ID `offline-...`) | in OpenBao's audit log, in `keys\ssh\issued.log` and in the sshd logs |
| Trusted | by every machine, permanently: a firewall rebuild is always a way back in | by every machine, once `lab.ps1 deploy vault` has pushed it there and proved it |

**Who signs is decided every time** (`Get-LabSshSigner` in
[scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1)). OpenBao signs once
`keys\ssh\openbao-ca.trusted` holds the fingerprint of the CA OpenBao serves.
From then on, an OpenBao that is stopped, cannot be unsealed, serves another SSH
CA, or answers with a TLS certificate that the PC's TLS pin refuses (not signed
directly by the lab root, see [Internal PKI](#internal-pki-certificate-authority)) makes
the scripts **stop**, with the reason and the ways out, instead of falling back
to the offline CA: whoever can block or impersonate OpenBao must not be able to
push the lab into signing outside its audit log. Break-glass is a decision:
`.\lab.ps1 breakglass <command>` runs that one command with the offline CA
allowed to sign, for example `.\lab.ps1 breakglass ssh-cert -Force` (the PC's
certificate), `.\lab.ps1 breakglass connect`, or `.\lab.ps1 breakglass up` and
`.\lab.ps1 breakglass firewall` (host certificates too). It sets
`$env:LAB_SSH_BREAKGLASS = '1'` for that command only and puts the previous value
back afterwards; setting it yourself in a window does the same for everything you
run there. Such a certificate's key ID starts with `offline-breakglass-`, so it
stands out in every log. Both CAs sign from
the same table (`$LabSshRoles` in `LabSsh.ps1`; `lab.ps1 deploy vault` makes
OpenBao's roles `pc`, `ansible-control` and `lab-hosts` from it), every
certificate gets a random serial number, and the PC checks each new certificate
against what it asked for (type, key, CA, principals, lifetime, options) before
it uses it, whichever CA signed it.

**The handover to OpenBao** is step 8 of `lab.ps1 deploy vault`
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
| The PC's | `keys\ssh\pc_ed25519`, made once on the PC, no passphrase | `lab-all` | 8 hours | `source-address`: the PC (10.10.99.1) and the firewall's LAN address (every login to a VM arrives from the jump host); `permit-port-forwarding`, `permit-pty` | by `Get-LabSshConfig`, the entry point of every script that uses ssh, scp or vagrant, when fewer than 4 hours are left (longer than any script runs); for `vagrant` commands you type, by the Vagrantfile; by hand: `.\lab.ps1 ssh-cert` |
| An Ansible run's | ansible-control's own key, made on the VM by [provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh); it never leaves the VM | only those of the run's profile (`principals` in [config/run-profiles.json](config/run-profiles.json): `host-<vm>` opens only that machine, `lab-all` every one; an empty list means no certificate, see [Run a playbook](#run-a-playbook-re-run-a-deployment)) | 2 hours, like a deployment's OpenBao token | `source-address`: ansible-control; `permit-pty` | new for every run: `Invoke-LabRun` ([scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1)) has it signed with the profile's principals, and [ansible/bin/lab-run](ansible/bin/lab-run) installs it next to the key (`~/.ssh/id_ed25519-cert.pub`) and deletes it when the run ends, whatever happens. The sockets of Ansible's kept-open connections (ControlPersist) are removed before and after, so a connection of an earlier run with a broader certificate cannot be reused |
| A host's | the machine's own ed25519 host key | exactly one: its full DNS name | 1 year | none | by `lab.ps1 up` (VMs) and `lab.ps1 firewall` (firewall), 30 days before it expires and at once for a new host key; one from the offline CA is replaced by one from OpenBao once OpenBao signs |

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
  it boots. `lab.ps1 firewall` reads that console (a Hyper-V named pipe on the
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
`lab.ps1 down` deletes. ssh on the PC and on ansible-control refuses such a
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
.\lab.ps1 ssh-cert                   # the PC's certificate: signer, valid until, key ID, serial
ssh-keygen -L -f keys\ssh\pc_ed25519-cert.pub            # all of it: principals, critical options, extensions
.\lab.ps1 connect matrix 'sudo journalctl -u ssh -n 20 --no-pager | grep Accepted'   # logins with key ID and serial
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
  process creation events" is switched on (`Initialize-LabSshCa` in `lib\LabSsh.ps1`,
  run by `lab.ps1 up`, warns about that setting). Without the encrypted key file it is useless.
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

**How the running lab moved over** (2026-10-24, commit `130f75c`): a lab built
before SSH certificates was moved over once. The old key stayed accepted until
the CAs and host certificates were installed, OpenBao had taken over signing
and certificates alone had been proved to log in everywhere; then the key was
removed from every machine. That transition code is gone (a lab still on the
old key would check out `130f75c` for the move): a lab built now never has the
old key, and its logins as `ansible` use certificates only.

Enterprise equivalent: the same split exists everywhere, an offline or
HSM-held root of trust plus an online issuer (HashiCorp Vault's or OpenBao's
SSH secrets engine, Smallstep, Teleport, AWS EC2 Instance Connect). People get
a certificate for their own identity after an SSO login with MFA, with
principals from their IdP groups; automation gets one per job; hosts get theirs
at boot from an agent that proves the instance's identity; logins and
issuance go to a SIEM.
Files: [scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1) (read its header first;
`Initialize-LabSshCa` for `lab.ps1 up`, `Invoke-LabSshCertRenewal` for `lab.ps1 ssh-cert`),
[lab.ps1](lab.ps1) (`breakglass`),
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) (steps 6 and 8),
[scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1) (`Invoke-LabRun`),
[config/run-profiles.json](config/run-profiles.json) (`principals`),
[ansible/bin/lab-run](ansible/bin/lab-run),
[scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1) (`Update-FirewallSsh`),
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
[playbooks/openbao.yml](ansible/playbooks/openbao.yml) installs it;
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) initialises and unseals
it and sets up its identities and policies over its API from the PC, and
[playbooks/openbao-config.yml](ansible/playbooks/openbao-config.yml) configures
its engines from ansible-control (the two planes, below).

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
sign OpenBao's own certificate, and the first GUI certificate of a new
firewall, which is built before OpenBao exists. Later GUI certificates of the
running firewall come from the intermediate
([An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)):
nothing that builds or repairs OpenBao needs the firewall's web GUI.

**Secret zero: DPAPI on the PC.** Every secret system needs a first key that is
not stored in it: to read OpenBao you need a credential, and that credential has
to be kept somewhere. Here that somewhere is your Windows account. The PC's own
secrets are encrypted with DPAPI, the Windows Data Protection
API, for your user: Windows derives the key from your logon, so only programs
running as you on this PC can decrypt them; copies of the files, backups and
other accounts see only ciphertext. Each blob is also bound to its name (DPAPI's
optional "entropy" input), so a file copied under another name does not
decrypt. The one rename the lab makes itself is mapped back: when
`lab.ps1 down` moves `keys\openbao` to `keys\openbao-retired-<date-time>`
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

- `.\lab.ps1 unseal` sends shares A and B over HTTPS, without any
  input. `lab.ps1 up`, `lab.ps1 run` and
  `lab.ps1 deploy vault` unseal the same way when OpenBao is sealed.
  `.\lab.ps1 unseal -Interactive` asks for two shares instead
  (recovery).
- A reload (`systemctl reload openbao`: a new TLS certificate, a rotated audit
  log) does not seal OpenBao; a restart does.
- While OpenBao is unsealed, its key is in the VM's memory. The vault VM
  therefore has Hyper-V checkpoints switched off (a checkpoint of a running VM
  writes its RAM to disk) and no console autologin (`checkpoints` and
  `consoleAutologin` in `config/lab.json`).
- Initialisation also returned a **root token**, an all-powerful login without
  expiry. `lab.ps1 deploy vault` used it only for the first configuration and
  revoked it once the administrator login (`pc-admin`, below) worked.
- The key shares belong to that one installation and its snapshots.
  `lab.ps1 deploy vault` refuses to initialise a new OpenBao while shares of an
  earlier one are in `keys\openbao`, and `lab.ps1 down`, when it deletes the
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
overwrite each other. (The mount and both settings are part of OpenBao's
configuration plane, written by `openbao-config.yml`, below.)

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
(A lab that existed before OpenBao had its old values imported once, unchanged;
a new lab starts without any.)

| Path in `lab/` | Field | What it is | Created by |
|---|---|---|---|
| `keycloak/db` | `password` | Keycloak's database user | `keycloak.yml` |
| `keycloak/admin` | `password` | Keycloak's bootstrap administrator `admin` | `keycloak.yml` |
| `keycloak/clients/lab-ansible` | `secret` | the client Ansible uses for Keycloak's admin API | `keycloak.yml` |
| `keycloak/clients/matrix-authentication-service` | `secret` | the OIDC client secret Keycloak and MAS share | `keycloak.yml` (the Matrix side only reads it) |
| `keycloak/users/alice`, `keycloak/users/bob` | `password` | the lab users' logins | `keycloak.yml` |
| `matrix/generic-secret-key` | `value` | MDAD's master secret (further keys are derived from it) | `matrix-prepare.yml` |
| `matrix/postgres` | `password` | the Matrix PostgreSQL superuser | `matrix-prepare.yml` |
| `matrix/legacy-users/...` | `password` | Synapse passwords from before MAS, unused, kept (older labs only) | imported once, on a lab migrated from before OpenBao |

**Policies: least privilege per playbook.** A policy lists paths and what may be
done there (`create`, `read`, `update`, `delete`, `list`, ...); whatever no
policy allows is denied. Each policy is a file in
[config/openbao/policies](config/openbao/policies), written in HCL, OpenBao's
configuration language: the file name is the policy's name, and its comments
say who uses it and why. `lab.ps1 deploy vault` writes every file to OpenBao on
every run, so a policy changes through a reviewed edit of the repository, like
everything else. Each consumer has its own:

| Policy | Held by | Allows |
|---|---|---|
| `openbao-admin` | AppRoles `pc-admin` (the PC) and `recovery` (break-glass); the web UI's tokens (token role `ui-admin`, `lab.ps1 ui`) | everything: administration, reading secrets by hand |
| `pc-deploy` | AppRole `pc-deploy` (the PC) | creating run tokens through the token role `ansible-run`; taking raft snapshots; signing SSH certificates with the SSH roles `pc`, `ansible-control` and `lab-hosts` (only signing: the SSH CA and its roles are `pc-admin`'s) |
| `ansible-keycloak` | run token of `keycloak.yml` | create and read `keycloak/...`; generate with `lab-alnum-24` and `-48`; sign with the PKI role `keycloak` |
| `ansible-matrix` | run token of `matrix-prepare.yml` and of MDAD | create and read `matrix/...`; read (not create) the MAS client secret; generate with `lab-alnum-64` |
| `ansible-firewall` | run token of `firewall.yml` | sign with the PKI role `firewall-gui` (the firewall's web GUI), nothing else |
| `ansible-web` | run token of `hello-nginx.yml` | sign with the PKI role `web`, nothing else |
| `openbao-config` | token of `openbao-config.yml` (token role `ansible-config`) | OpenBao's configuration plane: the mounts `lab` and `pki_int` and their settings, the password policies, the intermediate's URLs, revocation list and tidying, the PKI roles, ACME; no policies, logins, CAs, certificates or secrets (below) |

The playbook policies grant `create` and `read` on secrets but never `update`: a playbook
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
is issued in two steps ([scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1)):
`New-LabAppRoleSecret` creates a new secret ID, the caller stores it (in DPAPI,
or in the recovery file, which it then decrypts again to verify it), and only
then `Remove-LabAppRoleSecretIds` destroys every other secret ID of the role.
So only the newest login works, a lost or leaked one is useless from then on,
and a failure in between (a full or write-protected USB stick, for example)
leaves the old login working. `lab.ps1 deploy vault` does this when a DPAPI
login is missing (on the first run, or in a new Windows profile);
`lab.ps1 recovery` for every new recovery file and when it restores the
PC's logins. Replacing a credential instead of adding a second valid one is
what rotation should mean.

**Token roles and run tokens.** A playbook on ansible-control needs a token, but
ansible-control keeps no credentials. For each run that needs one, the PC logs
in as `pc-deploy` and creates one token through the **token role**
`ansible-run`, which fixes what such a token can be: only policies from its list
(`ansible-keycloak`, `ansible-matrix`, `ansible-firewall`, `ansible-web`),
usable only from ansible-control's address 10.10.10.10/32, valid at most 2
hours, not renewable, and an *orphan*. Normally a token dies with the token that
created it, and the `pc-deploy` token is revoked seconds later; an orphan has no
parent. Which policies a run gets is written in its run profile in
[config/run-profiles.json](config/run-profiles.json): `keycloak` ->
`ansible-keycloak`; `matrix-prepare`, `matrix` and the other MDAD profiles ->
`ansible-matrix`; `firewall` -> `ansible-firewall`; `hello-nginx` ->
`ansible-web`. A profile without policies (`base`, `checks`, `openbao`, `ping`,
...) gets no token at all
([Configuration management with Ansible](#configuration-management-with-ansible)).
A second token role, `ansible-config`, is for OpenBao's own configuration
(below).

**Response wrapping: handing the token over.** The PC never receives the new
token itself. It asks with the header `X-Vault-Wrap-TTL: 120s`, and OpenBao
returns a **wrapping token** instead: single-use, valid for 2 minutes, and good
for exactly one thing, being exchanged for the real token. The PC sends it to
ansible-control over SSH on stdin, never on a command line (the other users of a
machine can read command lines, for example with `ps`), and
[ansible/bin/openbao-run](ansible/bin/openbao-run) there (started by
`bin/lab-run`, which reads nothing from stdin before it):

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

**Two planes: identities from the PC, the engines' configuration from
Ansible.** OpenBao's own setup is split by what it controls. The **identity
plane** decides who may do what: the ACL policies, the AppRoles, the token
roles, the SSH secrets engine with its CA and roles, and the intermediate CA
itself (its key made inside OpenBao, its signing request signed by the offline
root on the PC, imported and made the default issuer), together with
initialising, unsealing and revoking the root token. That part needs what only
the PC has (the key shares and logins in DPAPI, the offline root), so
`lab.ps1 deploy vault` writes it over the API from the PC
([scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1), steps 4 to 7; the policies,
AppRoles, token roles, the SSH engine and the intermediate in step 6). The
**configuration plane** is how the engines behave: the KV mount `lab` and its
settings (`cas_required`, 10 versions), the password policies `lab-alnum-24`,
`-48` and `-64`, the intermediate's mount `pki_int` and its tuning (the headers
ACME needs), its URLs for the CA certificate and the revocation list (AIA and
CDP), the revocation list itself (valid 7 days, rebuilt automatically),
automatic tidying, the PKI roles `acme-matrix`, `keycloak`, `firewall-gui` and
`web`, and the ACME settings. That is ordinary configuration management, so it
is an Ansible run on ansible-control like any other:
[playbooks/openbao-config.yml](ansible/playbooks/openbao-config.yml), profile
`openbao-config`, with the desired values in
[vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml), through
the same `uri` tasks.

Its token comes from the token role `ansible-config`: only the policy
`openbao-config`, at most 30 minutes, bound to ansible-control's address and
handed over wrapped like a run token, but minted by `pc-admin` (during the very
first deployment by the root token), not by `pc-deploy`, because changing how
OpenBao works is an administrator's decision.
The policy lets it configure the engines but not hand out rights: it cannot
write ACL policies, auth methods, AppRoles or token roles, cannot touch the SSH
CA, cannot import or choose a CA (`config/ca`, `config/issuers`), cannot issue
or sign a certificate, and cannot read or write a secret. Someone who stole the
token during a run could change how certificates are issued (a PKI role, for
example; that is one reason why the PC accepts for `vault.lab.internal` only a
certificate signed directly by the root, see
[Internal PKI](#internal-pki-certificate-authority)), but could not give anyone
a login or a policy. The playbook first checks that its token has exactly the
policy `openbao-config` (a run that got an administrator token by mistake
stops), and [tests/Test-LabOpenBaoConfig.ps1](tests/Test-LabOpenBaoConfig.ps1)
checks the token's policies, lifetime and address binding, asks OpenBao which
capabilities it has on a list of allowed and forbidden paths
(`sys/capabilities-self`: nothing is tried), and checks that it is revoked after
the run.

**Read, compare, write.** Writing every object on every run would work, but a
run could then not tell what it changed, and a dry run could not show what
differs. So each object goes through
[tasks/openbao-api.yml](ansible/playbooks/tasks/openbao-api.yml): read it,
compare the keys the repository sets with what OpenBao returns (the desired
values are written in the form OpenBao returns them, durations in seconds for
example), and write only when one differs. Mounts are only created when
missing, and nothing is ever deleted: an object removed from the vars file stays
in OpenBao until an administrator removes it. So a second run reports
`changed=0`, and `.\lab.ps1 run openbao-config --check --diff` shows what
differs (a setting changed by hand in the web UI, say) without writing anything;
`-e openbao_config_force=true` writes every object once anyway, a harmless way
to try each write request. On a brand-new OpenBao, `lab.ps1 deploy vault` runs
the playbook twice: first before the intermediate exists (the mounts, and the
URLs, which must be set before its first certificate), then again after it, for
the PKI roles and ACME, which need an issuer. Enterprise equivalent: separation
of duties. An IAM or security team owns identities and policies; a platform
team's pipeline owns the engines' configuration, often with Terraform's Vault
provider, which works the same way (`plan` compares, `apply` writes what
differs).

**Audit log.** OpenBao writes every request and response to
`/var/log/openbao/audit.log` on the vault VM, with secret values replaced by
HMAC hashes: the log shows who read or wrote which path and when, but not the
values. It fails closed: if OpenBao cannot write the log, it refuses requests.
logrotate rotates the file daily (14 days are kept) and reloads OpenBao, which
then reopens it. Your own reads with `lab.ps1 secret`
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
nowhere else: after every run of `lab.ps1 deploy keycloak` and
`lab.ps1 deploy matrix`, also a failed one (a first deployment creates the
service's secrets inside OpenBao, and from then on the service's database
depends on them), and in `lab.ps1 down` before it deletes the vault VM. And
`lab.ps1 down` does not delete `keys\openbao` with the VM, it moves it (key
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
Files: [scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1) (DPAPI, the API calls,
pinning, unseal, AppRole secrets, run tokens),
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) (initialisation and the
identity plane: policies, AppRoles, token roles, SSH CA, intermediate CA; also
`backup`, `ui` and `unseal`),
[config/openbao/policies](config/openbao/policies) (the policies),
[playbooks/openbao.yml](ansible/playbooks/openbao.yml),
[openbao.hcl.j2](ansible/templates/openbao/openbao.hcl.j2),
[playbooks/openbao-config.yml](ansible/playbooks/openbao-config.yml),
[vars/openbao-config.yml](ansible/playbooks/vars/openbao-config.yml) and
[tasks/openbao-api.yml](ansible/playbooks/tasks/openbao-api.yml) (the
configuration plane),
[config/run-profiles.json](config/run-profiles.json) (which run gets which
policies),
[ansible/bin/openbao-run](ansible/bin/openbao-run),
[ansible/ansible.cfg](ansible/ansible.cfg),
[tasks/openbao-secrets.yml](ansible/playbooks/tasks/openbao-secrets.yml),
[ansible/matrix/lab-setup.yml](ansible/matrix/lab-setup.yml),
[scripts/commands/secret.ps1](scripts/commands/secret.ps1),
[scripts/commands/down.ps1](scripts/commands/down.ps1),
[tests/Test-LabOpenBaoConfig.ps1](tests/Test-LabOpenBaoConfig.ps1).

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
So the lab prepares a login in advance instead. `lab.ps1 deploy vault` creates
the AppRole `recovery`, with the policy of `pc-admin` (`openbao-admin`), the
same short token lifetime and the same binding to the PC's address
10.10.99.1/32. Its secret ID exists only in the recovery file:
`lab.ps1 deploy vault` never makes one, and `lab.ps1 recovery` makes a new
one for every file it writes and, once the file is written and verified,
destroys all older ones. So only the newest file can log in; an older one can
still help to unseal (it holds share B), nothing more. A used break-glass
login is replaced, like a password after an emergency: after a recovery the
script asks for a new file (`-Renew`).

SSH has a break-glass path of its own: when OpenBao cannot sign SSH
certificates, the offline SSH CA on the PC can, but only when you ask for it
(`.\lab.ps1 breakglass <command>`, for example `.\lab.ps1 breakglass up`), and
every such certificate is marked as such in the logs
([SSH certificates](#ssh-certificates-user-and-host-cas)). The recovery file
keeps a copy of that CA, so the path survives a lost Windows profile too.

**Using the kit.** `lab.ps1 recovery` makes the kit once, right after
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
`lab.ps1 up` (`Initialize-LabSshCa` in `lib\LabSsh.ps1`), and the CAs certify
the new one; OpenBao's snapshots are in
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
Files: [scripts/commands/recovery.ps1](scripts/commands/recovery.ps1),
[scripts/lib/LabVault.ps1](scripts/lib/LabVault.ps1) (the AppRole
`recovery`), [scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1) (the offline SSH
CA, break-glass signing),
[scripts/lib/LabSecrets.ps1](scripts/lib/LabSecrets.ps1) (`New-LabAppRoleSecret`,
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
self-signed "TRAEFIK DEFAULT CERT"; `lab.ps1 deploy matrix` therefore waits up to
3 minutes per name (in `matrix-check.yml`, the last step of its MDAD run, from
ansible-control) and checks that the certificate it is served comes from the
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
from OpenBao by CSR signing whenever `lab.ps1 deploy keycloak` runs (see
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
[matrix-check.yml](ansible/playbooks/matrix-check.yml) (the certificate
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
and the empty `web`, plus `ubuntu`, which holds every VM but the firewall) and
addresses them by DNS name, not by IP (ansible-control manages itself
without SSH: `ansible_connection=local`). Groups are named by role and hosts by
machine, because a group and a host with the same name would be ambiguous
([P22](#p22-ansible-warns-that-a-group-and-a-host-have-the-same-name)). The
firewall is in the inventory too: Ansible reaches it over SSH as `ansible` and
runs its modules with the Python 3 that OPNsense ships, so `ping.yml` tests it
like the other VMs. Its configuration, however, is better changed through
OPNsense's REST API than with modules that edit files, because OPNsense
regenerates its files from `config.xml`. The one change Ansible makes on the
running firewall, its GUI certificate, goes through OPNsense's own
configuration library instead (as the PC's update of the SSH CAs does,
`opnsense/lab-ssh-trust.php`)
([An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)).

**One way to run anything: run profiles.** Every Ansible run of the lab, from
`lab.ps1 up`, a deployment or by hand, goes through the same primitive:
`Invoke-LabRun` in [scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1) on the PC
and [ansible/bin/lab-run](ansible/bin/lab-run) on ansible-control. And every
run is a **profile** in [config/run-profiles.json](config/run-profiles.json):
what runs (a playbook, or a command such as MDAD's), the SSH principals of
ansible-control's certificate for this run (`host-<vm>` opens one machine,
`lab-all` every one, none keeps the run on ansible-control), the OpenBao
policies of its token (none: no token) and the token role it is minted through.
One run:

1. The PC packs `ansible\`, `config\lab.json`, `config\run-profiles.json`,
   `opnsense\lab-gui-cert.php` and the public files of the lab root CA (nothing
   else from `keys\`; with `syncMdad` also `vendor\mdad`) and copies the archive
   to ansible-control.
2. It signs ansible-control's own key for this run: a certificate valid 2 hours,
   only for the profile's principals. A Keycloak run cannot log in to the vault
   VM.
3. If the profile has policies, it mints a token for exactly those, wrapped
   (see [Secrets management with OpenBao](#secrets-management-with-openbao)).
4. One SSH call starts `bin/lab-run`: one run at a time (a lock; a second run
   stops at once with exit code 75), `~/lab` **replaced** by the fresh copy, the
   certificate installed (and SSH connections Ansible kept open from an earlier
   run closed, so no run reuses a broader one's), the playbook or command run
   (through `bin/openbao-run` when there is a token), and the certificate
   deleted again however the run ends.

Replacing `~/lab` instead of updating it means that a file deleted in the
repository disappears on the VM too, and a quick fix made by hand on
ansible-control does not survive the next run: ansible-control holds neither
state of its own nor a standing credential. One run at a time keeps two runs
from replacing `~/lab` or the certificate under each other. `.\lab.ps1 run`
lists the profiles; `.\lab.ps1 run <profile> [options]` (or
`run <playbook>.yml`, which takes that playbook's profile) passes the options on
to `ansible-playbook`
([Run a playbook, re-run a deployment](#run-a-playbook-re-run-a-deployment)). A
playbook without a profile runs with a certificate for every machine and no
token, with a warning. Enterprise equivalent: job templates in AWX / Ansible
Automation Platform, each with its own machine credential and secrets lookup,
run by a runner that checks out a reviewed commit.

**The lab's own playbooks.** Next to the deployments (`openbao.yml`,
`keycloak.yml`, `matrix-prepare.yml`, MDAD, `hello-nginx.yml`), four playbooks
look after the lab itself; each one's header says where it runs and why:

| Playbook (profile) | Run by | What it does |
|---|---|---|
| [base.yml](ansible/playbooks/base.yml) (`base`) | `lab.ps1 up`, right after Vagrant's provisioning | the shared base of the Ubuntu VMs: zsh with fzf history search (Ctrl+R), prefix search with the arrow keys and the plugins for suggestions and syntax highlighting, a system-wide `/etc/zsh/zshrc.lab` that automation owns and a `~/.zshrc` it creates only once and then leaves to the user, and the console autologin as a systemd drop-in for `getty@tty1` (not on vault: `consoleAutologin` false in `config/lab.json`) |
| [checks.yml](ansible/playbooks/checks.yml) (`checks`) | the end of `lab.ps1 up`, or by hand | read-only checks from inside the lab: every machine resolves, accepts the run certificate, runs Python and sudo; the Ubuntu VMs' names, sshd settings, no `authorized_keys`, the lab root in the trust store; the firewall's version, DNS drop-in, sshd limits and `cert-authority` lines; the inventory matches `config/lab.json` |
| [firewall.yml](ansible/playbooks/firewall.yml) (`firewall`) | `lab.ps1 deploy firewall`; `lab.ps1 up` when due | the running firewall's GUI certificate from OpenBao's intermediate, when it is due ([An appliance configured from a versioned config.xml](#an-appliance-configured-from-a-versioned-configxml)) |
| [openbao-config.yml](ansible/playbooks/openbao-config.yml) (`openbao-config`) | `lab.ps1 deploy vault` | OpenBao's configuration plane: mounts, KV settings, password policies, PKI, ACME ([Secrets management with OpenBao](#secrets-management-with-openbao)) |

zsh and the console autologin used to be Vagrant provisioning scripts. They
moved to `base.yml` because they are not bootstrap: nothing about them is needed
before Ansible can reach a VM. As a playbook they run with a certificate for
exactly the Ubuntu VMs, report what they changed, and can be checked for drift
with `--check` like everything else
([Infrastructure as code with Vagrant](#infrastructure-as-code-with-vagrant)).

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
  variables of the include; `openbao-config.yml` includes
  `tasks/openbao-api.yml` once per OpenBao configuration object, in a loop.
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
  `.\lab.ps1 run keycloak.yml --check --diff`) shows what a
  run would change without changing it. Tasks that only read (the OpenBao
  reads, the CA certificate) carry `check_mode: false`, so they run anyway and
  the rest is checked against real values; everything that writes (to OpenBao,
  a new certificate) is skipped. A module that cannot predict its result
  reports "changed", as `keycloak_user` does for every user
  ([P49](#p49---check-reports-the-lab-users-as-changed)).
- **Drift detection**: *drift* is a difference between what the repository
  describes and what runs, for example a setting changed by hand. Because the
  playbooks are idempotent, a `--check` run that reports `changed=0` shows that
  everything the playbook manages matches the repository. The tests use exactly
  that ([Run the tests](#run-the-tests)):
  [Test-LabAnsible.ps1](tests/Test-LabAnsible.ps1) runs the syntax check of
  every playbook and `checks.yml`, then `base.yml` and `firewall.yml` with
  `--check`, which must report `changed=0`;
  [Test-LabOpenBaoConfig.ps1](tests/Test-LabOpenBaoConfig.ps1) does the same
  with `openbao-config.yml`. Enterprise equivalent: scheduled check runs (AWX,
  `terraform plan`) that raise an alert when they find something to change.
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
[config/run-profiles.json](config/run-profiles.json),
[scripts/lib/LabRun.ps1](scripts/lib/LabRun.ps1),
[ansible/bin/lab-run](ansible/bin/lab-run),
[ansible/bin/openbao-run](ansible/bin/openbao-run),
[provision/bootstrap-ansible-control.sh](provision/bootstrap-ansible-control.sh),
[tests/Test-LabAnsible.ps1](tests/Test-LabAnsible.ps1).

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
- **How it is used**: `lab.ps1 deploy matrix` copies `vendor\mdad` to `~/mdad`
  on ansible-control on every run, and `matrix-prepare.yml` checks the marker
  file against `mdad_version`. Nothing is downloaded from GitHub at deployment
  time. `lab.ps1 mdad-upgrade` is the only script that downloads MDAD
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
  `vendor\mdad\.lab-vendored-commit` (`lab.ps1 deploy matrix` refuses
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
- **The OPNsense image by SHA-256**: `lab.ps1 firewall` checks the
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
so `lab.ps1 up` simply re-applies everything on each run.
Vagrant's provisioning keeps only what must exist before Ansible on
ansible-control can reach a VM: the user `ansible`, the VM's own SSH host keys,
the SSH CAs to trust and certificate-only logins, and on ansible-control its own
SSH key and Ansible. That bootstrap is done by Vagrant shell provisioners; the
host certificates come afterwards from `lab.ps1 up`, which can read each
VM's host key from Hyper-V. Everything else is done by Ansible: right after
provisioning, `lab.ps1 up` runs `base.yml` (zsh and the console autologin,
which were provisioning scripts before) and `checks.yml`, and the deployments
install the applications
([Configuration management with Ansible](#configuration-management-with-ansible)).
The line is drawn there on purpose: a shell provisioner has no dry run and does
not report what it changed, while a playbook can be run with `--check` at any
time to find drift, and runs with a short-lived certificate for exactly its
machines. This split is common: a minimal bootstrap creates a machine that
configuration management can reach, and configuration management does the rest.
Files: [vagrant/Vagrantfile](vagrant/Vagrantfile), [provision/](provision/),
[ansible/playbooks/base.yml](ansible/playbooks/base.yml),
[scripts/commands/up.ps1](scripts/commands/up.ps1).

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
  `lab.ps1 firewall` fills in addresses from `config/lab.json`, generates the
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
only until the next rebuild. Two day-2 changes are automated on purpose: the SSH CAs that
user `ansible` accepts, replaced in place whenever the set of CAs changes
(`lab.ps1 firewall` and `lab.ps1 deploy vault`, with `opnsense/lab-ssh-trust.php`), and the
GUI certificate, so that an expiring certificate needs no rebuild. A new firewall
gets its first GUI certificate from the offline root inside the rendered `config.xml` (the
build must work before OpenBao exists). From then on Ansible replaces it in the running
firewall: [playbooks/firewall.yml](ansible/playbooks/firewall.yml)
(`lab.ps1 deploy firewall`, and `lab.ps1 up` when it is due) looks at the
certificate the GUI serves, and when it expires within 30 days, is not issued
by OpenBao's current intermediate, or does not name `firewall.lab.internal`, it
makes a new key and signing request on the firewall (in a private temporary
folder), has the intermediate sign the request (PKI role `firewall-gui`, 1
year), and runs [opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php) on the
firewall. That helper does what the GUI's System > Trust pages would do,
through OPNsense's own PHP configuration library, which loads `config.xml` and
writes it back with a backup of the previous version (System > Configuration >
History):

- In the trust store of `config.xml`, the certificate the GUI uses is a `<cert>`
  entry whose `<caref>` points to the `<ca>` entry of its issuer, and a `<ca>`
  entry can point to its own issuer the same way. OPNsense follows these links
  to build the chain the web server sends.
- So the intermediate gets a `<ca>` entry of its own, with the `uuid` attribute
  by which OPNsense's Trust pages address their entries, linked to the root's
  entry; the GUI
  certificate's entry is updated in place (it keeps its `refid`) and points to
  the intermediate. The firewall then serves leaf, intermediate and root.
- An intermediate that nothing points to any more (after a rotation) is
  removed; a self-signed CA, the root, never is.
- Before it writes anything, it checks that the key belongs to the certificate
  and that the certificate is signed by the given CA.

The playbook then restarts the web GUI and deletes the temporary folder, so the
key exists only in `config.xml`. `--check` shows whether a new certificate is
due without making one. `lab.ps1 firewall` does not change the certificate of a
running firewall; it only reports whether it is still valid (chain to the lab root, its name,
more than 30 days left), not whether it is already from the current intermediate:
`.\lab.ps1 maintain -List` or `.\lab.ps1 status` shows that (see
[Internal PKI](#internal-pki-certificate-authority)). Enterprise equivalent: a
"golden configuration" in version control, deployed by automation through the
device's API (or, for a certificate, enrolled from the issuing CA), with the GUI
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
[scripts/commands/firewall.ps1](scripts/commands/firewall.ps1),
[scripts/lib/LabFirewall.ps1](scripts/lib/LabFirewall.ps1),
[ansible/playbooks/firewall.yml](ansible/playbooks/firewall.yml),
[opnsense/lab-gui-cert.php](opnsense/lab-gui-cert.php).

### Automating an appliance's first boot over the serial console

Cloud images have cloud-init, Vagrant boxes have SSH and a known user. A fresh
OPNsense image has neither: it boots into its factory default configuration.
What it does have is a configuration importer: on a disk without a
configuration it offers, for a few seconds at boot, to load `conf/config.xml`
from another device. `lab.ps1 firewall` uses it:

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
- the firewall VM, which `lab.ps1 firewall` creates directly in
  `G:\Vagrant\hyperv\firewall` (disk, configuration, console log), and its
  image cache in `G:\Vagrant\images\opnsense\26.7`

The container images and the application data live inside the Ubuntu VMs'
disks, so they are on the storage drive too.
Files: [scripts/commands/up.ps1](scripts/commands/up.ps1),
[scripts/commands/firewall.ps1](scripts/commands/firewall.ps1).

---

## 8. Repository layout

```
DeployableServer/
|-- README.md                         this file
|-- lab.ps1                           the single entry point on the PC: .\lab.ps1 <command>
|                                     [arguments], ".\lab.ps1 help" lists the commands; checks the
|                                     rights a command needs (elevated, your own window) and hands
|                                     it to scripts\ with every further argument unchanged; exit
|                                     code 0 done, 1 failed or unknown command, 2 refused
|-- .gitignore                        keeps keys/, keys-old-*/ and .vagrant/ out of version control
|-- .gitattributes                    LF line endings for every text file
|-- config/
|   |-- lab.json                      the lab's data: domain, networks, firewall addresses, lab VMs
|   |                                 (name, MAC, IP, size, checkpoints, console autologin) and
|   |                                 "published" (address, names, ports per VM); read by the
|   |                                 Vagrantfile and the PowerShell scripts, and (a copy in every
|   |                                 run) by the playbooks
|   |-- run-profiles.json             every Ansible run of the lab, one "run profile" each: the
|   |                                 playbook or command, the SSH principals of ansible-control's
|   |                                 certificate for the run, the OpenBao policies and token role
|   |                                 of its token, syncMdad (also copy vendor\mdad); read by
|   |                                 lib\LabRun.ps1 on the PC and by ansible/bin/lab-run
|   `-- openbao/policies/             OpenBao's ACL policies, one file per policy (file name =
|       |                             policy name), written by lab.ps1 deploy vault (identity plane)
|       |-- ansible-firewall.hcl      firewall.yml: only certificates of the PKI role firewall-gui
|       |-- ansible-keycloak.hcl      keycloak.yml: Keycloak's secrets (write-once), password
|       |                             generation, certificates of the PKI role keycloak
|       |-- ansible-matrix.hcl        matrix-prepare.yml and MDAD: the Matrix secrets (write-once),
|       |                             the MAS client secret (read only), password generation
|       |-- ansible-web.hcl           hello-nginx.yml: only certificates of the PKI role web
|       |-- openbao-admin.hcl         full administration: AppRoles pc-admin and recovery, the UI's
|       |                             token role ui-admin
|       |-- openbao-config.hcl        the configuration plane (openbao-config.yml): the mounts lab
|       |                             and pki_int, KV settings, password policies, the
|       |                             intermediate's settings and roles, ACME; no ACL policies,
|       |                             logins, CAs, certificates or secrets
|       `-- pc-deploy.hcl             the PC's everyday login: run tokens (token role ansible-run),
|                                     snapshots, signing SSH certificates
|-- opnsense/                         the firewall's configuration (OPNsense)
|   |-- config.xml.template           golden config: interfaces, dnsmasq, NAT, rules, users, GUI;
|   |                                 VIPs, port forwards and host entries are generated from lab.json
|   |-- lab-gui-cert.php              run as root on the firewall by ansible/playbooks/firewall.yml
|   |                                 (lab.ps1 deploy firewall; lib\LabRun.ps1 packs it into every
|   |                                 run): puts the new GUI certificate, its key and OpenBao's
|   |                                 intermediate (a <ca> entry of its own, linked to the root)
|   |                                 into the running config.xml
|   |-- lab-ssh-trust.php             run as root on the firewall (LabSsh.ps1): the SSH CAs user
|   |                                 ansible accepts (cert-authority lines) into the running config.xml
|   |-- lab-sshd-files.sh             run as root on the firewall by lab.ps1 firewall: installs the
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
|   |                                 - only the bootstrap Ansible needs; zsh and the console
|   |                                 autologin are ansible/playbooks/base.yml
|   |-- bootstrap-ansible-user.sh     user "ansible", passwordless sudo, no authorized_keys (it logs
|   |                                 in with SSH certificates only; the script deletes the file)
|   |-- harden-ssh.sh                 own SSH host keys per VM, published to the PC through Hyper-V
|   |                                 KVP; trust in the lab's SSH CAs, principals, AllowUsers;
|   |                                 certificate logins only, no forwarding, no root login
|   `-- bootstrap-ansible-control.sh  ansible-control's own SSH key, host key checking against the
|                                     lab's SSH CAs (ssh_known_hosts, revocation list,
|                                     ssh_config.d/20-lab.conf), Ansible pinned (ANSIBLE_VERSION) via
|                                     pipx, git (for lab.ps1 mdad-upgrade)
|-- ansible/                          Ansible project (copied to ~/lab on ansible-control per run)
|   |-- ansible.cfg                   inventory, remote user, ansible-control's own SSH key (with the
|   |                                 run's certificate next to it), host key checking on, pipelining
|   |                                 (modules and their arguments go to Python on stdin, not into
|   |                                 temporary files), colours
|   |-- bin/                          the ansible-control half of every run, started by the PC
|   |   |-- lab-run                   every run (lib\LabRun.ps1 starts it over SSH): one run at a
|   |   |                             time (a lock; exit code 75 = another run is active), the fresh
|   |   |                             copy replaces ~/lab (with syncMdad also ~/mdad), the public
|   |   |                             PKI files go to ~/lab-pki, the run's certificate is installed
|   |   |                             and removed again; runs the profile's playbook or command
|   |   |                             (through openbao-run when the run has a token)
|   |   |-- openbao-run               on ansible-control: reads the wrapped run token from stdin,
|   |   |                             unwraps it, exports VAULT_ADDR/VAULT_CACERT/VAULT_TOKEN, puts
|   |   |                             Ansible's local temporary files into RAM (ANSIBLE_LOCAL_TEMP),
|   |   |                             runs one command; on exit it revokes the token and removes
|   |   |                             that folder
|   |   |-- deploy-matrix             profiles matrix and matrix-setup: MDAD in ~/mdad through
|   |   |                             lab-setup.yml (the tags of "just install-all", or setup-all),
|   |   |                             MDAD's self-check, mas-cli doctor, then matrix-check.yml
|   |   `-- syntax-check              profile syntax: ansible-playbook --syntax-check for every
|   |                                 playbook
|   |-- files/
|   |   `-- base/                     files of base.yml
|   |       |-- zshrc.lab             the shared zsh setup (/etc/zsh/zshrc.lab): history, fzf search
|   |       |                         (Ctrl+R), prefix search with the arrow keys, suggestions
|   |       `-- getty-autologin.conf  drop-in for getty@tty1.service: console autologin as ansible
|   |-- inventory/
|   |   |-- hosts.ini                 groups firewalls, control, matrix_servers, keycloak_servers,
|   |   |                             vault_servers, web (empty) and ubuntu (the Ubuntu VMs)
|   |   `-- group_vars/all.yml        lab_pki_dir, lab_vault_url, lab_config (the run's copy of
|   |                                 config/lab.json), lab_domain, the Keycloak/MAS contract (URL,
|   |                                 realm, issuer, client IDs, MAS URL, provider ULID),
|   |                                 keycloak_secrets_dir (only to remove the old folder)
|   |-- playbooks/                    each has a run profile (config/run-profiles.json) or is
|   |   |                             started by one (matrix-check.yml: bin/deploy-matrix)
|   |   |-- ping.yml                  reachability and sudo test for all hosts
|   |   |-- base.yml                  the base of every Ubuntu VM (lab.ps1 up): zsh with fzf and
|   |   |                             plugins (/etc/zsh/zshrc.lab), console autologin on tty1 (not
|   |   |                             on vault: "consoleAutologin": false in lab.json)
|   |   |-- checks.yml                read-only checks of every machine from inside (end of lab.ps1
|   |   |                             up): DNS, SSH with the run's certificate, sudo, sshd settings,
|   |   |                             no authorized_keys, the root CA trusted, the firewall's DNS
|   |   |                             drop-in and sshd, the inventory against lab.json
|   |   |-- openbao.yml               OpenBao on the vault VM: root CA trust, pinned package (signing
|   |   |                             key checked), openbao.hcl, audit log rotation, service, nginx
|   |   |                             on port 80 for CA certificates and CRLs
|   |   |-- openbao-config.yml        OpenBao's configuration plane, on ansible-control against the
|   |   |                             API (lab.ps1 deploy vault; token role ansible-config, 30
|   |   |                             minutes): KV mount lab, password policies, the intermediate's
|   |   |                             mount, URLs, CRL, tidying, PKI roles, ACME; read, compare,
|   |   |                             write only what differs, never delete; --check --diff shows
|   |   |                             drift
|   |   |-- firewall.yml              the firewall's GUI certificate (lab.ps1 deploy firewall, and
|   |   |                             lab.ps1 up when due): key and CSR made on the firewall, signed
|   |   |                             by OpenBao's intermediate (PKI role firewall-gui), put into
|   |   |                             config.xml by opnsense/lab-gui-cert.php; renewed within 30
|   |   |                             days of expiry or when it is not from the current intermediate
|   |   |-- keycloak.yml              Keycloak: secrets from OpenBao, certificate signed by OpenBao,
|   |   |                             Docker, Compose stack, realm "lab", client for MAS, users alice
|   |   |                             and bob
|   |   |-- matrix-prepare.yml        before MDAD (profile matrix-prepare, which copies vendor\mdad
|   |   |                             to ~/mdad first): root CA trust, check that ~/mdad holds the
|   |   |                             pinned commit (mdad_version), inventory, lab-setup.yml and
|   |   |                             lab-shared.yml copied into ~/mdad, Matrix secrets in OpenBao,
|   |   |                             DNS, Keycloak and the ACME directory checked on the VM;
|   |   |                             Traefik's ACME store reset when Traefik serves a certificate
|   |   |                             of an older lab intermediate
|   |   |-- matrix-check.yml          the checks at the end of bin/deploy-matrix (read-only):
|   |   |                             Traefik serves certificates of the current intermediate,
|   |   |                             Synapse delegates logins to MAS, MAS sends them to Keycloak
|   |   |-- hello-nginx.yml           the first demo: nginx + certificate from OpenBao
|   |   |                             (tasks/openbao-certificate.yml, role web: only
|   |   |                             hello.lab.internal; policy ansible-web; group web, empty)
|   |   |-- tasks/                    task files the playbooks include
|   |   |   |-- openbao-api.yml       one OpenBao configuration object: read it, compare the desired
|   |   |   |                         keys, write only when one differs, never delete
|   |   |   |                         (openbao-config.yml)
|   |   |   |-- openbao-secrets.yml   read secrets from OpenBao, create missing ones once (cas=0);
|   |   |   |                         result: the fact lab_secrets, in memory for one run; a secret
|   |   |   |                         without the expected field is reported by path and field
|   |   |   `-- openbao-certificate.yml
|   |   |                             a TLS certificate from the intermediate CA: key and CSR made
|   |   |                             on the server, signed by OpenBao, renewed within 30 days of
|   |   |                             expiry or when it was not issued by the current intermediate
|   |   |                             (authority key identifier)
|   |   `-- vars/
|   |       |-- keycloak-secrets.yml  the vault_* names Keycloak's templates use, mapped to lab_secrets
|   |       `-- openbao-config.yml    the desired configuration of OpenBao's engines (mounts, KV,
|   |                                 password policies, PKI, roles, ACME), written the way OpenBao
|   |                                 returns it on a read
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
|   |-- tests/                        run on ansible-control by the tests in tests\
|   |   |-- config-token-check.sh     for Test-LabOpenBaoConfig.ps1 (profile test-config-token)
|   |   |-- run-token-check.sh        for Test-LabRunToken.ps1 (profile test-run-token)
|   |   |-- secret-creation.yml       for Test-LabSecretCreation.ps1 (profile test-secret-creation)
|   |   `-- ssh-cert-check.sh         for Test-LabSshCertificates.ps1 (copied to /tmp/lab-tests)
|   `-- matrix/                       our files for matrix-docker-ansible-deploy (MDAD)
|       |-- lab-setup.yml             the lab's entry point into MDAD (copied to ~/mdad): reads the
|       |                             Matrix secrets from OpenBao into memory, then imports setup.yml
|       `-- inventory/
|           |-- hosts                 group matrix_servers: matrix.lab.internal
|           `-- host_vars/matrix.lab.internal/
|               `-- vars.yml          our Matrix configuration: TLS through ACME from OpenBao,
|                                     federation off, calls (LiveKit), MAS with Keycloak, no mail,
|                                     no integrations
|-- scripts/                          the PowerShell code behind lab.ps1, on the PC, in these four
|   |                                 folders; you start all of it through lab.ps1
|   |-- lib/                          libraries, loaded with lib\Lab.ps1 (dot-sourced), never run
|   |   |                             directly
|   |   |-- Lab.ps1                   the loader: checks the project folder, loads the libraries
|   |   |                             below, holds lab.ps1's command table ($LabCommands), help and
|   |   |                             status; its header explains WHERE CODE RUNS (the PC does only
|   |   |                             what only the PC can do, everything else is an Ansible run)
|   |   |-- LabSecrets.ps1            shared helpers: DPAPI, OpenBao API (TLS pinned to the lab root
|   |   |                             for OpenBao's host: LabTlsPin3, only a certificate the root
|   |   |                             signed directly), unseal, run tokens (New-LabRunToken,
|   |   |                             wrapped, through the profile's token role), new AppRole logins
|   |   |                             (New-LabAppRoleSecret, then Remove-LabAppRoleSecretIds), the
|   |   |                             maintenance check (Get-LabMaintenanceDue)
|   |   |-- LabSsh.ps1                SSH certificates: the two SSH CAs and who signs (the offline
|   |   |                             CA before OpenBao exists and for lab.ps1 breakglass),
|   |   |                             Initialize-LabSshCa (lab.ps1 up step 2, once: the offline SSH
|   |   |                             CA, this PC's SSH key and the empty revocation list in
|   |   |                             keys\ssh; locks down keys\ and the keys with icacls), the PC's
|   |   |                             certificate (Get-LabSshConfig; lab.ps1 ssh-cert), a run's
|   |   |                             certificate, host keys from KVP and host certificates, the
|   |   |                             trust files, keys\ssh_config, the revocation list
|   |   |-- LabPki.ps1                the offline root CA in keys\pki: created once, CRL kept
|   |   |                             current, signs CSRs (Invoke-LabRootCaSign: the intermediate,
|   |   |                             OpenBao's TLS certificate, a new firewall's first GUI
|   |   |                             certificate)
|   |   |-- LabRun.ps1                Invoke-LabRun, one run on ansible-control for a run profile:
|   |   |                             packs ansible\, config\lab.json, config\run-profiles.json,
|   |   |                             opnsense\lab-gui-cert.php and the public root CA files, signs
|   |   |                             ansible-control's key for the profile's principals (2 hours),
|   |   |                             a wrapped OpenBao token for its policies, then bin/lab-run;
|   |   |                             lab.ps1 run
|   |   |-- LabVault.ps1              OpenBao from the PC. lab.ps1 deploy vault
|   |   |                             (Invoke-LabVaultDeploy): openbao.yml, initialise and unseal
|   |   |                             it, then the identity plane over its API: policies
|   |   |                             (config\openbao\policies), AppRoles (pc-admin, pc-deploy, the
|   |   |                             break-glass login "recovery"), token roles (ansible-run,
|   |   |                             ansible-config, ui-admin), the SSH secrets engine and its
|   |   |                             roles, the intermediate CA (a new one 400 days before expiry,
|   |   |                             or -RotateIntermediate); the configuration plane (KV, password
|   |   |                             policies, PKI roles, ACME) is the run profile openbao-config;
|   |   |                             renews OpenBao's TLS certificate and the root CRL when due;
|   |   |                             step 8 (once): every machine trusts OpenBao's SSH CA, proved
|   |   |                             by a test login, then OpenBao signs. Also lab.ps1 backup
|   |   |                             (snapshot to keys\openbao\snapshots, keeps 10, -Keep,
|   |   |                             -Destination; also after every keycloak and matrix run and
|   |   |                             before lab.ps1 down deletes vault), ui (a 1-hour login token
|   |   |                             on the clipboard), unseal (-Interactive) and maintain (runs
|   |   |                             the lab.ps1 deploy command that renews what is due; -List)
|   |   `-- LabFirewall.ps1           the building blocks of the OPNsense VM: image, secrets, first
|   |                                 GUI certificate (from the root), config.xml, seed ISO, serial
|   |                                 console, SSH bootstrap, firmware update, checks; loaded only
|   |                                 by commands\firewall.ps1 and its tests
|   |-- commands/                     the lab.ps1 commands that have parameters of their own
|   |   |-- up.ps1                    lab.ps1 up: build/update/start firewall and VMs in the right
|   |   |                             order (firewall and vault first, OpenBao unsealed before any
|   |   |                             SSH), SSH CA and host certificates, tests from the PC,
|   |   |                             base.yml and checks.yml on ansible-control, then renew what is
|   |   |                             due (step 7: lab.ps1 maintain)
|   |   |-- down.ps1                  lab.ps1 down: delete all or one VM (vagrant destroy + Hyper-V
|   |   |                             folder; the firewall via Hyper-V) and revoke their SSH host
|   |   |                             keys; with vault: an OpenBao snapshot first, then keys\openbao
|   |   |                             and OpenBao's SSH CA files moved aside
|   |   |-- firewall.ps1              lab.ps1 firewall: build (or start and check) the OPNsense
|   |   |                             firewall VM: its SSH host key checked against the serial
|   |   |                             console, host certificate, sshd drop-in, DNS drop-in, firmware
|   |   |                             update; reports the GUI certificate (firewall.yml renews it);
|   |   |                             -Rebuild
|   |   |-- deploy.ps1                lab.ps1 deploy vault | firewall | keycloak | matrix | all:
|   |   |                             vault through lib\LabVault.ps1, the others as run profiles
|   |   |                             (firewall; keycloak; matrix-prepare, then matrix:
|   |   |                             bin/deploy-matrix, -Setup for setup-all), an OpenBao snapshot
|   |   |                             after keycloak and matrix
|   |   |-- connect.ps1               lab.ps1 connect: SSH as "ansible" to a VM through the jump
|   |   |                             host, with the PC's SSH certificate (renewed first when due)
|   |   |-- secret.ps1                lab.ps1 secret: copy a secret to the clipboard (-Show prints
|   |   |                             it, -List names, -Pc a DPAPI secret on the PC, also one in a
|   |   |                             retired folder)
|   |   `-- recovery.ps1              lab.ps1 recovery, by you, in your own window: key share C to
|   |                                 write down and a passphrase-encrypted recovery file with share
|   |                                 B, the break-glass login, the root CA and the offline SSH CA
|   |                                 (-Destination); -Renew: a new file later; -Open <file>;
|   |                                 -Recover <file> after losing the PC's DPAPI keys
|   |-- host/                         changes to Windows itself: only in your own window
|   |   |-- Initialize-LabHost.ps1    lab.ps1 host-setup, once: LabHost switch, 10.10.99.1, NRPT
|   |   |                             rule (-Remove)
|   |   `-- Install-LabRootCA.ps1     lab.ps1 trust, once: trust the 2026 root CA for your Windows
|   |                                 user (-Remove; -RemoveRetired drops the retired first CA)
|   `-- dev/
|       `-- Update-LabMdad.ps1        lab.ps1 mdad-upgrade -Commit <hash>: git subtree pull of
|                                     another MDAD commit into vendor\mdad, then its roles (two
|                                     commits); the only script that downloads MDAD
|-- tests/                            the lab's tests, run from the project root: .\lab.ps1 test
|   |                                 (tests\README.md; see "Run the tests")
|   |-- README.md                     what each test checks and whether it changes anything
|   |-- Invoke-LabTests.ps1           runs the tests that change nothing, then a summary (-Name;
|   |                                 -IncludeStateChanging adds Test-LabRecoveryLogin.ps1);
|   |                                 .\lab.ps1 test starts it
|   |-- LabTest.ps1                   shared helpers: PASS/FAIL lines, summary, exit code; copies
|   |                                 scripts of ansible\tests to /tmp/lab-tests on ansible-control
|   |                                 for a test that uses a plain SSH session, and removes them
|   |-- Test-LabLayout.ps1            no lab needed: lab.ps1 and the command table agree, the run
|   |                                 profiles name existing playbooks, principals and policies, no
|   |                                 retired names, every README link resolves, the dispatcher
|   |                                 refuses what it should (exit codes)
|   |-- Test-LabAnsible.ps1           every playbook parses, checks.yml passes, base.yml and
|   |                                 firewall.yml --check report changed=0 (no drift)
|   |-- Test-LabCertificates.ps1      HTTPS endpoints: right CA (the firewall's: the intermediate),
|   |                                 valid > 30 days, trusted by Windows
|   |-- Test-LabTlsPin.ps1            the PC's OpenBao calls pinned to the lab root, other hosts
|   |                                 not; for the pinned host a foreign chain and a chain through
|   |                                 the intermediate are refused
|   |-- Test-LabPasswordHash.ps1      the firewall's password hashing over stdin (local only)
|   |-- Test-LabRetiredDpapi.ps1      DPAPI secrets in keys\openbao-retired-* readable under new names
|   |-- Test-LabRunToken.ps1          a run token: policies, lifetime, bound to ansible-control, cleanup
|   |-- Test-LabOpenBaoConfig.ps1     the configuration plane's token: openbao-config only, 30
|   |                                 minutes, bound, revoked after the run, may configure the
|   |                                 engines but not the identity plane; openbao-config.yml --check
|   |                                 changed=0
|   |-- Test-LabSecretCreation.ps1    a missing secret: generated by OpenBao once, not under --check
|   |-- Test-LabFirewallRender.ps1    the firewall's build path (config.xml with the SSH CA lines,
|   |                                 seed ISO) in a temp folder
|   |-- Test-LabSshCa.ps1             the SSH certificate code on the PC: offline signing, contents,
|   |                                 refused principals, revocation list, trust files (local only)
|   |-- Test-LabSshCertificates.ps1   SSH in the running lab: strict logins, refused keys and CAs,
|   |                                 principals, source-address, revocation, sshd settings
|   |-- Test-LabRecoveryLogin.ps1     CHANGES STATE: break-glass login and new PC logins (asks first)
|   `-- tools/
|       `-- Export-LabOpenBaoConfig.ps1
|                                     read-only: OpenBao's configuration (no secret values) as JSON,
|                                     to compare the state before and after a change
|-- vendor/                           third-party code the lab runs, unchanged, at a pinned version
|   |-- README.md                     what is vendored, from where, which version, licence, upgrade
|   `-- mdad/                         MDAD at the pinned commit with its 32 roles (roles\galaxy\),
|                                     unchanged; copied to ~/mdad by the run profile matrix-prepare
|                                     (syncMdad; lab.ps1 deploy matrix)
`-- keys/                             generated, never commit (in .gitignore), readable only by you and
                                      SYSTEM; secrets in it are DPAPI-encrypted (*.dpapi: only your
                                      Windows account on this PC can decrypt them)
    |-- ssh_config                    generated SSH client config: jump host, the PC's key and
    |                                 certificate, host keys only with a host certificate
    |-- ssh/                          SSH certificates (lib\LabSsh.ps1; Initialize-LabSshCa makes it)
    |   |-- offline-ca, offline-ca.pub
    |   |                             the offline SSH CA; its key encrypted with the passphrase in
    |   |                             offline-ca-passphrase.dpapi
    |   |-- offline-ca.in-recovery-kit
    |   |                             the fingerprint of the offline SSH CA the newest recovery file
    |   |                             holds (not secret)
    |   |-- pc_ed25519(.pub)          this PC's SSH key, no passphrase; opens nothing without:
    |   |-- pc_ed25519-cert.pub       its current certificate (8 hours); pc_ed25519-cert.valid-until:
    |   |                             its expiry and CA, read without starting ssh-keygen
    |   |-- openbao-ca.pub            OpenBao's SSH CA public key, cached by lab.ps1 deploy vault
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
    |-- pki/                          the offline root CA (lib\LabPki.ps1)
    |   |-- root-ca.crt               "DeployableServer Lab Root CA 2026" (PEM)
    |   |-- root-ca.key               its private key, PKCS#8, AES-256 encrypted
    |   |-- root-ca-passphrase.dpapi  the key's passphrase
    |   |-- openssl.cnf               extensions and CRL settings (rewritten on every run)
    |   |-- crl/                      OpenSSL's CRL database and the current root CRL (PEM)
    |   |-- pub/                      root-ca.crt and root-ca.crl as DER, served on the vault VM
    |   |                             at http://vault.lab.internal/pki/
    |   `-- issued/                   what the root signed: the intermediates (lab-int-<yyyy>.crt,
    |                                 after a rotation lab-int-<yyyyMMdd-HHmmss>.crt), vault.crt,
    |                                 firewall-gui.crt (a new firewall's first GUI certificate;
    |                                 the renewals come from OpenBao's intermediate)
    |-- openbao/                      the keys of THIS OpenBao installation (lab.ps1 deploy vault)
    |   |-- unseal-a.dpapi, unseal-b.dpapi
    |   |                             two of the three key shares, enough to unseal
    |   |                             (lab.ps1 unseal): A and B; after -Recover, C (as
    |   |                             unseal-a) and B
    |   |-- unseal-c-pending.dpapi    share C, only until lab.ps1 recovery has shown it to you
    |   |-- unseal-c.sha256           the fingerprint of share C (not secret), so that a renewed
    |   |                             recovery file carries it too
    |   |-- root-token.dpapi          the initial root token, only until the bootstrap is finished
    |   |-- pc-admin.dpapi, pc-deploy.dpapi
    |   |                             role_id and secret_id of the PC's two AppRoles (the
    |   |                             break-glass login "recovery" has no file here: its secret
    |   |                             exists only in the recovery file)
    |   `-- snapshots/                vault-<date-time>.snap (lab.ps1 backup, the newest 10)
    |-- openbao-retired-<date-time>/  keys\openbao of a deleted vault VM, moved aside by lab.ps1 down
    |                                 with a last snapshot (and, in ssh\, the public files of its SSH
    |                                 CA); its DPAPI files still open under the new name
    |                                 (lab.ps1 secret -Pc openbao-retired-<date-time>/unseal-a)
    |-- opnsense/                     the firewall's secrets (DPAPI: the firewall exists before OpenBao)
    |   |-- root-password.dpapi       GUI login of "root"
    |   |-- ansible-password.dpapi    password of "ansible", a full administrator (unused by the
    |   |                             scripts; SSH takes only certificates)
    |   `-- api-ansible.dpapi         REST API key and secret of "ansible"
    |-- recovery/                     DeployableServer-recovery-<date>.bin, the recovery file of
    |                                 lab.ps1 recovery without -Destination (copy it off the PC)
    `-- ca/                           the retired first lab CA: only lab-root-ca.crt, kept for
                                      lab.ps1 trust -RemoveRetired
```

And on the VMs (created by the provisioning and the deployments, never edited by
hand):

```
ansible-control  ~/.ssh/id_ed25519      its own SSH key (made on the VM); id_ed25519-cert.pub only
                                        during a run (the run's certificate)
                 /etc/ssh/ssh_known_hosts, /etc/ssh/lab_revoked_host_keys
                                        the lab's SSH CAs for host certificates, the revocation list
                 /etc/ssh/ssh_config.d/20-lab.conf      host certificates required for *.lab.internal
                 ~/lab                  copy of ansible/ with config/lab.json, run-profiles.json and
                                        opnsense/lab-gui-cert.php (replaced on every run: lab.ps1
                                        run, deploy, up; bin/lab-run)
                 ~/.cache/lab-run.lock  the lock: one run at a time (a second one: exit code 75)
                 ~/lab-pki              public files from keys\pki: root-ca.crt, pub/root-ca.{crt,crl}
                 ~/mdad                 a copy of vendor\mdad (replaced on every run of the profile
                                        matrix-prepare, lab.ps1 deploy matrix), plus the lab's
                                        inventory and lab-setup.yml; inventory/ holds our hosts and
                                        vars.yml and the generated lab-shared.yml (no secrets)
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
                 /etc/zsh/zshrc.lab     the shared zsh setup (base.yml; your own settings: ~/.zshrc)
                 /etc/systemd/system/getty@tty1.service.d/autologin.conf
                                        console autologin as ansible (base.yml; not on vault)
firewall         /conf/config.xml       OPNsense's configuration, including the GUI certificate and
                                        its key (renewed by opnsense/lab-gui-cert.php, which adds
                                        OpenBao's intermediate as a CA entry)
                 /conf/sshd/ssh_host_ed25519_key-cert.pub       the firewall's host certificate
                 /usr/local/etc/ssh/sshd_config.d/20-lab-ssh.conf   the jump host's sshd drop-in
```

### Where the old scripts went

Before `lab.ps1`, the repository had one script per task directly in `scripts\`, each with its
own switches (`Initialize-Lab.ps1` built the lab, `Deploy-LabVault.ps1` deployed OpenBao, and so
on), and the PC configured much of the lab itself. Now there is one entry point,
`.\lab.ps1 <command>`, and the code behind it lives in `scripts\lib`, `scripts\commands`,
`scripts\host` and `scripts\dev`. At the same time, the configuration that used to run from the
PC became Ansible runs on ansible-control: OpenBao's engines (`openbao-config.yml`), the
firewall's GUI certificate (`firewall.yml`) and the base setup of the Ubuntu VMs (`base.yml`),
each a run profile in `config\run-profiles.json` with credentials for that run only. The PC keeps
only what only the PC can do (the boundary rule at the top of `scripts\lib\Lab.ps1`). Enterprise
equivalent: one CLI with subcommands (`az`, `kubectl`, `gh`) in front of a control node or
pipeline that applies the repository.

The old files are gone. This table is for old notes, shell histories and older copies of this
README:

| Old script or name | Now | Note |
|---|---|---|
| `Initialize-Lab.ps1` | `.\lab.ps1 up` | `scripts\commands\up.ps1` |
| `New-LabFirewall.ps1` | `.\lab.ps1 firewall` | `scripts\commands\firewall.ps1` with `scripts\lib\LabFirewall.ps1` |
| `Remove-Lab.ps1` | `.\lab.ps1 down` | `scripts\commands\down.ps1` |
| `Deploy-LabVault.ps1` | `.\lab.ps1 deploy vault` | `Invoke-LabVaultDeploy` in `scripts\lib\LabVault.ps1` |
| `Deploy-LabKeycloak.ps1` | `.\lab.ps1 deploy keycloak` | run profile `keycloak` |
| `Deploy-LabMatrix.ps1` | `.\lab.ps1 deploy matrix` | run profiles `matrix-prepare` and `matrix` (`-Setup`: `matrix-setup`) |
| `Connect-Lab.ps1` | `.\lab.ps1 connect` | `scripts\commands\connect.ps1` |
| `Show-LabSecret.ps1` | `.\lab.ps1 secret` | `scripts\commands\secret.ps1` |
| `New-LabRecoveryKit.ps1` | `.\lab.ps1 recovery` | `scripts\commands\recovery.ps1`; your own window |
| `Install-LabRootCA.ps1` (directly in `scripts\`) | `.\lab.ps1 trust` | now `scripts\host\Install-LabRootCA.ps1`; your own window |
| `Install-LabHostNetwork.ps1` | `.\lab.ps1 host-setup` | `scripts\host\Initialize-LabHost.ps1`; elevated, your own window |
| `Invoke-LabPlaybook.ps1` | `.\lab.ps1 run <profile or playbook.yml>` | the profiles in `config\run-profiles.json` (`.\lab.ps1 run` lists them) |
| `Unlock-LabVault.ps1` | `.\lab.ps1 unseal` | `Invoke-LabUnseal` in `scripts\lib\LabVault.ps1` |
| `Backup-LabVault.ps1` | `.\lab.ps1 backup` | `Backup-LabOpenBao` in `scripts\lib\LabVault.ps1` |
| `Open-LabVaultUi.ps1` | `.\lab.ps1 ui` | `Open-LabVaultUi` in `scripts\lib\LabVault.ps1` |
| `Update-LabSshCertificate.ps1` | `.\lab.ps1 ssh-cert` | `Invoke-LabSshCertRenewal` in `scripts\lib\LabSsh.ps1` |
| `Update-LabMdad.ps1` (directly in `scripts\`) | `.\lab.ps1 mdad-upgrade` | now `scripts\dev\Update-LabMdad.ps1` |
| `New-LabSshCa.ps1` | part of `.\lab.ps1 up` | `Initialize-LabSshCa` in `scripts\lib\LabSsh.ps1` |
| `New-LabRootCA.ps1` | part of `.\lab.ps1 up` (the first firewall build creates the root) and `.\lab.ps1 deploy vault` | `scripts\lib\LabPki.ps1` |
| the `-BreakGlass` switch of several scripts | `.\lab.ps1 breakglass <command>` | for example `.\lab.ps1 breakglass up` |
| `Import-LabSecrets.ps1` | removed | it moved the old plain-text `secrets.yml` files into OpenBao once; a lab set up before OpenBao had them imported then, a new lab never has them |
| `Complete-LabSshMigration.ps1` | removed | the move from SSH keys to SSH certificates is finished: certificates only |
| `provision/setup-zsh.sh`, `provision/setup-console-autologin.sh` | `ansible/playbooks/base.yml` | run profile `base`, run by `.\lab.ps1 up` |
| `Invoke-LabRunToken` (function) | `Invoke-LabRun` in `scripts\lib\LabRun.ps1` | one run of a run profile; the token itself comes from `New-LabRunToken` |
| `Update-GuiCertificate` (function: `lab.ps1 firewall` renewed the GUI certificate, signed by the offline root) | `.\lab.ps1 deploy firewall` (`ansible/playbooks/firewall.yml`) | signed by OpenBao's intermediate; `lab.ps1 firewall` only reports (`Show-GuiCertificate`); a new firewall's first certificate still comes from the root |
| `LabTlsPin2` (the PC's TLS pin) | `LabTlsPin3` in `scripts\lib\LabSecrets.ps1` | for OpenBao's host only a certificate the root signed directly |
| `tests\remote\` | `ansible\tests\` | the tests run them through run profiles, or copy them to `/tmp/lab-tests` |
| OpenBao's KV mount, password policies, PKI roles, CRL and ACME, configured from the PC | `ansible/playbooks/openbao-config.yml` | run profile `openbao-config`, token role `ansible-config`; `.\lab.ps1 deploy vault` runs it |
| policies written inline (HCL) in `LabVault.ps1` | `config\openbao\policies\*.hcl` | one file per policy; the PC still writes them (identity plane) |

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
.\lab.ps1 status                                                  # what runs, what is due, the next step
.\lab.ps1 unseal                                                  # unseals OpenBao, or says it already is
.\lab.ps1 secret -List                                            # secrets in OpenBao and on the PC (names only)
.\lab.ps1 maintain -List                                          # renewals due now; lab.ps1 up step 7 runs them
.\lab.ps1 ssh-cert                                                # the PC's SSH certificate: renewed if due, signer and validity
.\lab.ps1 connect firewall 'sudo pfctl -sr'                       # filter rules pf runs
.\lab.ps1 connect firewall 'sudo pfctl -s nat'                    # port forwards and outbound NAT
.\lab.ps1 run ping.yml
.\lab.ps1 run checks                                              # read-only checks of every machine
```

The service checks (units, containers, logs, `curl.exe` against the
`.well-known` files and the issuers) are in
[Look at the services and their logs](#look-at-the-services-and-their-logs).
OpenBao's own log:
`.\lab.ps1 connect vault 'sudo journalctl -u openbao -n 50 --no-pager'`.

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
tokens and secrets in the playbooks (P40-P43), ACME (P44), the commands that
show secrets or run only in your own window (P45), recovery and the deletion
of the vault VM (P46-P47),
Ansible's pipelining and check mode (P48-P49), the Windows console, Windows
path lengths and the vendored MDAD (P50-P52), and SSH certificates (P53).

### P1. The OPNsense image does not boot in a Generation 2 VM

- **Symptom**: a Hyper-V Generation 2 VM (UEFI firmware) does not start the
  OPNsense nano image.
- **Cause**: the nano image (a ready-installed disk image for small appliances)
  boots only with BIOS, and Generation 2 VMs have only UEFI.
- **What the project does**: [scripts/commands/firewall.ps1](scripts/commands/firewall.ps1)
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
  and run `.\lab.ps1 firewall -Rebuild`. A plain re-run treats the
  half-built VM as finished (it already carries the script's tag): it starts it,
  waits up to five minutes for SSH on 10.10.99.2 (if the adapters were never
  connected, it stops with "Timeout: nothing answers on 10.10.99.2:22 after
  300 s."), and never repeats the adapter check. The seed ISO (password hashes,
  GUI private key) is not left behind: the script ejects it and deletes
  `G:\Vagrant\hyperv\firewall\seed\` when the first boot ends, also when it
  failed. If that deletion itself fails (the script warns) or the script was
  killed, the next run of `lab.ps1 firewall`, plain or `-Rebuild`, removes
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
  `.\lab.ps1 firewall` again: it updates whatever is still below
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
  re-run, `lab.ps1 firewall` only starts and checks the existing VM. GUI and
  REST API changes go into `/conf/config.xml` on the VM, never into the
  repository.
- **What the project does**: `config.xml` is the truth. Change the repository
  and run `.\lab.ps1 firewall -Rebuild`, or change the running
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
- **What the project does**: `lab.ps1 firewall` writes `"@"` as host `lab` in
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

- **Symptom**: `lab.ps1 firewall` (or `lab.ps1 up` in its step 4)
  stops with this message. `.\lab.ps1 down firewall` refuses the VM
  too ("tag missing in its Notes").
- **Cause**: both commands touch only a VM whose Notes carry the tag that
  `lab.ps1 firewall` writes there, so they never delete a VM they did not
  create, for example a firewall from an older version of this lab or a VM of
  your own with that name. The tag keeps its old text, which still names the
  script that built the firewall before `lab.ps1` existed:
  `managed-by=DeployableServer/scripts/New-LabFirewall.ps1` (in
  `lib\LabFirewall.ps1` and `commands\down.ps1`). Changing it would make both
  commands refuse every firewall built before the change, so `Test-LabLayout`
  allows exactly this one old name.
- **What to do**: check in Hyper-V Manager what the VM is. If you do not need
  it, delete it there yourself, together with its virtual disk (Hyper-V does
  not delete the disk with the VM), or rename the VM; then run the command again.
  In PowerShell: `Remove-VM -Name firewall -Force`, then delete the VM's folder.

### P11. Windows PowerShell 5.1 quirks

- **Embedded double quotes** in arguments to native programs (ssh, ssh-keygen)
  are not escaped correctly. The scripts avoid double quotes in remote
  commands, including the commands `lab.ps1 firewall` runs on the firewall
  and the command line every run starts on ansible-control (`Invoke-LabRun` in
  `lib\LabRun.ps1` refuses run arguments that contain quotes).
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
  passphrase, so `Initialize-LabSshCa` in
  [scripts/lib/LabSsh.ps1](scripts/lib/LabSsh.ps1) (and `Enable-LabOpenBaoSshCa`
  for its throwaway test key) passes `'""'` (PowerShell 7.3+ gets `''`). The
  same would make `ssh-keygen -n ''` take the next argument as its
  principals, which is one reason why `LabSsh.ps1` refuses to sign for an empty
  list of principals.
- **stderr becomes a terminating error**: with `$ErrorActionPreference = 'Stop'`
  and redirected output (`*> log`), any line a native program writes to stderr
  stops the script. Therefore ssh and scp run with `-o LogLevel=ERROR` (no
  "Permanently added ..." notice; the Vagrantfile's proxy command does the
  same), and `lab.ps1 run` (`Invoke-LabRun`) switches to `Continue` before it
  starts the run on ansible-control and judges success by the exit code instead.
  `lab.ps1 firewall` does the same for OpenSSL, which writes progress
  messages to stderr, and for its SSH commands. For the firmware update it
  also appends `2>&1` to the **remote** command, so the firewall's shell merges
  pkg's notices into stdout before they reach PowerShell; `Invoke-LabRun` and
  `Invoke-LabSsh` (`lib\LabSsh.ps1`) wrap their remote commands in `{ ...; } 2>&1`
  for the same reason (Ansible writes its warnings to stderr).
- **`-v` is swallowed by advanced scripts**: a script with `[CmdletBinding()]`
  treats `-v` as `-Verbose`. `lab.ps1` itself is deliberately not an advanced
  script, and neither is `Invoke-LabRunCli` behind `lab.ps1 run`, so `-v` reaches
  `ansible-playbook` (see the design decision on `lab.ps1` below). `lab.ps1 connect`
  (`commands\connect.ps1`) is a plain script for the same reason: every extra
  argument goes to `ssh`.
- **Advanced functions take over native options**: the same happens inside a
  script. An advanced function would try to bind OpenSSL options such as `-out`
  to its own common parameters (`-OutVariable`) instead of passing them on. The
  OpenSSL wrappers `Invoke-OpenSsl` (`lib\LabFirewall.ps1`, for `lab.ps1 firewall`)
  and `Invoke-LabPkiOpenSsl` (`lib\LabPki.ps1`) are
  therefore simple functions that hand `$args` to `openssl.exe` unchanged.
- **Native exit codes do not stop a script**: `$ErrorActionPreference = 'Stop'`
  reacts only to PowerShell errors, so the scripts check `$LASTEXITCODE`
  explicitly after native programs such as `vagrant`, `ssh`, `scp`, `tar` and
  `curl.exe`.
- **Everything a function outputs is its return value**: a function that runs
  `ssh` and ends with `return $LASTEXITCODE` returns ssh's output lines *and* the
  number, as one array. A check such as `if ($code -ne 0)` then filters that
  array instead of testing the exit code, and the output no longer appears while
  the command runs. `Invoke-LabRun` (`LabRun.ps1`) therefore returns no value of
  its own: the remote output lines pass through as they arrive (to the console,
  or to a test that captures them), and the caller reads `$LASTEXITCODE`
  (75: another run is active). Functions that do return a value pipe everything
  else to `Out-Null`.
- **Piped text arrives with extra bytes**: Windows PowerShell 5.1 appends CRLF
  to text it pipes into a native program, and with a UTF-8 `$OutputEncoding` it
  can also put a byte order mark (BOM) in front. For a token that is harmless:
  `ansible/bin/openbao-run` keeps only the characters a token can contain (see
  [P42](#p42-the-run-token-is-echoed-or-arrives-damaged)). For a password it is
  not: `openssl passwd -stdin` would hash the CR as part of the password, and the
  firewall would never accept the real one. `Get-PasswordHash` in
  `lib\LabFirewall.ps1` (`lab.ps1 firewall`) therefore starts openssl through
  .NET's `Process` class and writes the secret and a plain LF to its stdin
  itself. .NET Framework
  would put a BOM in front of that input when the console's input encoding is
  UTF-8, so the script sets it to UTF-8 without BOM while it starts openssl.
  The secret never appears on openssl's command line, which other programs can
  read.

### P12. Windows OpenSSH quirks

- **"Unprotected private key file" / key ignored**: Windows OpenSSH refuses a
  private key that other users can read. Here, the project folder passes read
  access on to every file inside it (inherited permissions, e.g. for a group
  like `CodexSandboxUsers`). `Initialize-LabSshCa` (`lib\LabSsh.ps1`) uses
  `icacls` to remove inheritance and grant access only to you (the offline SSH CA key and this PC's
  SSH key, on every run); `LabSecrets.ps1` does the same for every DPAPI file it
  writes, `lib\LabPki.ps1` for the root CA key, and `lab.ps1 firewall` for
  the staged `config.xml` and the seed ISO. `Initialize-LabSshCa` also locks the
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
  remote files in one call. The scripts fetch one remote file per call
  (`lab.ps1 mdad-upgrade` fetches the roles archive from ansible-control); several
  local files to one remote folder work (a run's archives for ansible-control, the
  firewall's host certificate with its sshd drop-in and `lab-sshd-files.sh`).
- **ssh_config with a UTF-8 BOM breaks**: ssh cannot parse the first line.
  `lab.ps1 up` writes the file without a BOM and with LF line endings
  (`Write-LabSshConfig` in `LabSsh.ps1`), like every SSH file the lab renders.
- **Paths**: forward slashes in `ssh_config` paths are the safest choice.

### P13. Later vagrant commands hit the lab unexpectedly

- **Symptom**: `vagrant destroy` in another project's folder destroys lab VMs.
- **Cause**: `$env:VAGRANT_CWD` tells Vagrant where the Vagrantfile is. If a
  script set it and left it set, it would stay in your shell and redirect every
  later vagrant command.
- **What the project does**: `lab.ps1 up` and `lab.ps1 down` save the
  old value and restore it in a `finally` block. (`VAGRANT_HOME` is different: it
  is meant to be permanent and global.)

### P14. A removed VM leaves its Hyper-V folder behind

- **Symptom**: after `vagrant destroy` the folder `G:\Vagrant\hyperv\<vm>` still
  exists, with the VM's old Hyper-V configuration files.
- **Cause**: `lab.ps1 up` moves each Ubuntu VM's Hyper-V files
  (configuration, checkpoints, smart paging) into that folder with
  `Move-VMStorage`. `vagrant destroy` deletes the VM and its disk, but not a
  folder that Vagrant did not create.
- **What the project does**: `lab.ps1 down` notes the folders before the
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
  and then times out, although `.\lab.ps1 connect matrix` works. For
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
  scripts renew it: run `.\lab.ps1 ssh-cert` first
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
  no wildcards, no IP addresses, no `localhost`), and `Invoke-LabRootCaSign`
  (`lib\LabPki.ps1`) refuses a name outside the domain before it signs. The
  root is created once
  and never replaced (`lib\LabPki.ps1` stops if `keys\pki` holds the key
  without the certificate), and it lives on the PC, not on a VM: rebuilding any
  VM, even vault, and rotating the intermediate keep Windows' trust, because
  every new intermediate is signed by the same root. Certificates from another
  CA are replaced on the next run: `tasks/openbao-certificate.yml` renews a
  certificate whose authority key identifier does not match the current
  intermediate's subject key identifier (after a rotation, after a rebuilt vault
  VM, or for a certificate of the retired first CA); `matrix-prepare.yml` makes
  Traefik start over with ACME when it serves a certificate of an older lab
  intermediate ([P44](#p44-traefik-serves-traefik-default-cert)); and
  `firewall.yml` (`.\lab.ps1 deploy firewall`, and the maintenance step of
  `lab.ps1 up` when it is due) renews the firewall's GUI certificate when it is
  not issued by the current intermediate (a new firewall starts with one from
  the root). `lab.ps1 firewall` itself only reports on that certificate.
  `lab.ps1 trust` imports only the 2026 root and
  says so when Windows still trusts the retired one. Run
  `.\lab.ps1 trust` once (and
  `.\lab.ps1 trust -RemoveRetired` if Windows still trusts the
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
- **What the project does**: no `--ssl-no-revoke` any more;
  `Test-LabCertificates` (`.\lab.ps1 test`) checks every lab certificate the way
  Windows sees it, with an online revocation check. nginx on the vault VM serves
  the root's certificate and CRL as files and passes only the intermediates' CA and
  CRL paths on to OpenBao. OpenBao rebuilds its CRLs by itself (valid 7 days,
  rebuilt 2 days before they expire). `lib\LabPki.ps1` renews the root's CRL
  when it has less than 60 days left; `lab.ps1 deploy vault` runs it and then
  publishes the file (`openbao.yml`), and `lab.ps1 up` runs
  `lab.ps1 deploy vault` by itself when that is due (step 7). To fix:
  `.\lab.ps1 unseal`
  ([P36](#p36-openbao-is-sealed-after-the-vault-vm-restarts)), then
  `.\lab.ps1 deploy vault`; for a certificate of an old CA, run that
  service's deployment again. `--ssl-no-revoke` is still useful as a diagnosis:
  if a command works with it and fails without it, the CRL is the problem, not
  the certificate.

### P20. Ansible ignores ansible.cfg

- **Symptom**: `[WARNING]: Ansible is being run in a world writable directory ... ignoring it as an ansible.cfg source`,
  followed by "no inventory" / "provided hosts list is empty".
- **Cause**: for security, Ansible ignores an `ansible.cfg` in a world-writable
  directory, and the archive packed on Windows can arrive with such permissions.
- **What the project does**: `ansible/bin/lab-run`, the ansible-control half of
  every run (`lab.ps1 run`, deploy, up), runs `chmod -R go-w` on the freshly
  extracted copy before it replaces `~/lab`.

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

- **Symptom**: `lab.ps1 deploy matrix` fails while rendering the MAS
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
  `lab.ps1 deploy matrix` finally checks that MAS really redirects to Keycloak,
  which MAS does only after it has loaded the discovery document. Look at the
  log with
  `.\lab.ps1 connect matrix 'sudo journalctl -u matrix-authentication-service -n 50 --no-pager'`.

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
  `.\lab.ps1 connect matrix 'sudo systemctl restart matrix-authentication-service matrix-livekit-jwt-service'`.
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

- **Symptom**: during `lab.ps1 deploy matrix`, MDAD's self-check prints a
  `fatal` line with HTTP 404 for `/_matrix/federation/v1/version`, then
  `...ignoring`.
- **Cause**: federation is switched off, so that endpoint does not exist. MDAD
  knows that and marks the failed task as ignored.
- **What the project does**: nothing; the 404 is the expected answer.
  `ansible/bin/deploy-matrix` comments this, and the run continues.

### P34. `mas-cli doctor` reports problems, but the run succeeds

- **Symptom**: `mas-cli doctor` prints warnings or errors, yet
  `lab.ps1 deploy matrix` continues and succeeds.
- **Cause**: `mas-cli doctor` only reports; its exit code is always 0, so no
  script can tell from it whether something is wrong.
- **What the project does**: read its output, but rely on the two hard checks
  after it: Synapse's `auth_metadata` must name MAS as issuer, and MAS's
  upstream authorize URL must redirect to Keycloak. Either failing stops the
  run (`matrix-check.yml`, the last step of `ansible/bin/deploy-matrix`).

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
  reports `"sealed":true`; `lab.ps1 secret` or `lab.ps1 backup` stop
  with `(HTTP 503)`; Traefik cannot get or renew certificates
  ([P44](#p44-traefik-serves-traefik-default-cert)); once Windows' cached copy
  of the intermediate's CRL has expired (after 7 days at most), `curl.exe`
  reports revocation errors ([P19](#p19-curlexe-fails-with-a-revocation-error)).
- **Cause**: OpenBao stores all its data encrypted and holds the key for it
  only in memory. After every start of the service (VM boot,
  `systemctl restart openbao`, a package upgrade) it is "sealed": it needs 2 of
  the 3 key shares to rebuild the key that unlocks its data (Shamir's secret
  sharing). The lab has no auto-unseal ([section 10](#10-security-notes)).
- **What the project does**: `lab.ps1 up` unseals OpenBao right after
  it has started the firewall and the vault VM, before any SSH, because OpenBao
  signs the SSH certificates (once step 8 of `lab.ps1 deploy vault` has made every
  machine trust its SSH CA; until then it unseals an initialised OpenBao only after
  the VMs are up),
  `lab.ps1 run` before
  every run whose profile needs OpenBao, `lab.ps1 ui`, the renewal of the PC's SSH
  certificate when it finds OpenBao sealed, and `lab.ps1 deploy vault` in its step 5.
  `lab.ps1 secret`,
  `lab.ps1 backup` and Traefik do not unseal. After any other restart of
  the vault VM, run `.\lab.ps1 unseal`: it sends the two shares
  stored with DPAPI and needs no input; on an unsealed OpenBao it does nothing.
  `openbao.yml` applies configuration changes with a reload (SIGHUP), which does
  not seal, and so do the audit log rotation and `lab.ps1 deploy vault` after it
  has installed a new TLS certificate. If OpenBao does not answer at all,
  `lab.ps1 run` stops with "OpenBao (...) is not reachable; ... Is the
  vault VM running, and has OpenBao been deployed (.\lab.ps1 deploy vault)?":
  start the VMs with `.\lab.ps1 up`, or deploy OpenBao first.
  An expired TLS certificate of OpenBao looks like no answer to the PC's pinned
  check; the scripts that wait for OpenBao then say so ("OpenBao's TLS
  certificate expired on ... Renew it with .\lab.ps1 deploy vault."), and
  `lab.ps1 up` runs `lab.ps1 deploy vault` by itself instead of only
  unsealing when the certificate is due or expired.
  After a lost Windows profile (the DPAPI files cannot be decrypted any more),
  `.\lab.ps1 unseal -Interactive` unseals with share B from the
  recovery file (`.\lab.ps1 recovery -Open <file>`) and share C
  from your copy; to get the PC's access back as well, use
  `.\lab.ps1 recovery -Recover <file>`
  ([P46](#p46-after-losing-the-pcs-dpapi-keys-nothing-logs-in-to-openbao)).

### P37. "cannot write to readonly storage" right after unsealing

- **Symptom**: right after an unseal, the first writes to OpenBao fail with
  `cannot write to readonly storage`; a few seconds later the same request
  works.
- **Cause**: OpenBao's integrated storage (raft) is built for clusters. Even a
  single node must first win a leader election after it was unsealed; until
  then it is a read-only "standby" (`sys/health` reports `"standby":true`).
- **What the project does**: `Unlock-LabVault` in `LabSecrets.ps1` (used by
  `lab.ps1 unseal` and every script that unseals) waits with
  `Wait-LabVaultActive` until OpenBao reports itself unsealed and not standby,
  for up to 60 seconds, also when it was already unsealed;
  `lab.ps1 recovery -Recover` does the same after its unseal. If you call
  the API yourself right after an unseal, wait for the same state.

### P38. OpenBao's API answers 405 or 404 for a path that exists

- **Symptom**: `GET .../v1/pki_int/issuers` answers `405` (unsupported
  operation); a read of `lab/keycloak/db` answers `404` (with an admin token) or
  `403` (with a token whose policy names `lab/data/...`), although
  `lab.ps1 secret keycloak/db` finds the secret.
- **Cause**: two details of the HTTP API. Listing is an operation of its own
  (`LIST`): over HTTP it is either the method `LIST` or a `GET` with
  `?list=true`, and an endpoint that can only list refuses a plain `GET`. And
  the KV engine version 2 keeps a secret's value under `<mount>/data/<path>` and
  its metadata and version list (also the listing of names) under
  `<mount>/metadata/<path>`; the short form `lab/keycloak/db` is only what the
  `bao` command line shows. Policies must name the full paths too.
- **What the project does**: every list call carries `?list=true`
  (`lab.ps1 deploy vault`, `lab.ps1 secret`, `Remove-LabAppRoleSecretIds` in
  `LabSecrets.ps1`), KV calls use `lab/data/...` and `lab/metadata/...`, and the
  policies in `config\openbao\policies\` (for example `ansible-keycloak.hcl`, written
  by `lab.ps1 deploy vault`) grant on `lab/data/keycloak/*` and
  `lab/metadata/keycloak/*`. `lab.ps1 secret` takes the short form and adds
  the prefixes itself.

### P39. `lab.ps1 deploy vault` refuses to initialise a new OpenBao

- **Symptom**: `lab.ps1 deploy vault` stops in step 4 with "keys\openbao holds key
  shares of an earlier OpenBao. They are not overwritten ..."; before that,
  `lab.ps1 up` may already stop after three minutes with "OpenBao
  (https://vault.lab.internal:8200) does not answer after 180 s." (it tries to
  unseal because it finds the old key shares). Once OpenBao signed the SSH
  certificates, the scripts stop even earlier, at the first SSH certificate they
  need ("OpenBao (10.10.99.5:8200) does not answer ..."): the PC still expects the
  deleted OpenBao to sign.
- **Cause**: the vault VM was rebuilt, so OpenBao is new and uninitialised, but
  `keys\openbao` still holds the key shares, logins and snapshots of the old
  installation. Those shares fit only the old one, and they are the only way to
  restore its snapshots, so the script never overwrites them.
  `lab.ps1 down` takes a last snapshot and moves the folder aside when it
  deletes the vault VM, together with the old OpenBao's SSH CA
  (`keys\ssh\openbao-ca.pub` and `openbao-ca.trusted`); a VM deleted another way
  (`vagrant destroy vault`, Hyper-V Manager) leaves them in place.
- **What to do**: move them aside yourself (without the SSH CA files the offline
  SSH CA signs again until step 8 of `lab.ps1 deploy vault` makes the new OpenBao's
  CA trusted), let `lab.ps1 up` certify the rebuilt VM, then run the
  script again:

  ```powershell
  $retired = "keys\openbao-retired-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Move-Item keys\openbao $retired
  New-Item -ItemType Directory "$retired\ssh" | Out-Null
  Move-Item keys\ssh\openbao-ca.pub, keys\ssh\openbao-ca.trusted "$retired\ssh\" -ErrorAction SilentlyContinue
  .\lab.ps1 up
  .\lab.ps1 deploy vault
  ```

  Use exactly that name pattern: DPAPI binds each file to its name, and
  `Unprotect-LabSecret` (`LabSecrets.ps1`) maps a name under
  `openbao-retired-<yyyyMMdd-HHmmss>/` back to the original one, so the old
  files stay readable where they are, for example the old share A:
  `.\lab.ps1 secret -Pc openbao-retired-<date-time>/unseal-a -Show`.
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
  `vault_*` variable) as soon as a task uses it. Any playbook started by hand
  that logs in to another machine fails there with `UNREACHABLE` and
  `Permission denied (publickey)`.
- **Cause**: ansible-control holds no credential of its own, by design:
  nothing on its disk opens OpenBao or logs in to another machine. Both exist
  only for one run, and only as far as its profile in `config\run-profiles.json`
  allows: the PC signs ansible-control's key for the profile's `principals`
  (2 hours), and for a profile with `policies` it mints a token through the
  profile's token role (`ansible-run`, minted with the AppRole `pc-deploy`, or
  `ansible-config`, minted with `pc-admin`; both logins are accepted only from
  the PC's address) and hands it over wrapped. `ansible/bin/lab-run` installs
  the certificate and deletes it when the run ends; `ansible/bin/openbao-run`
  unwraps the token and revokes it. MDAD's `setup.yml` on its own runs without
  the lab's entry point `lab-setup.yml`, which is where the Matrix secrets come
  in.
- **What to do**: start playbooks from the PC: `.\lab.ps1 run
  <profile>` or `.\lab.ps1 run <playbook>.yml` (`.\lab.ps1 run` alone lists the
  profiles with their rights), or the deployments (`.\lab.ps1 deploy ...`). A
  single MDAD tag runs with the profile `mdad` (MDAD's `lab-setup.yml` in
  `~/mdad`, a token of the policy `ansible-matrix`, a certificate for matrix
  only); further arguments are appended to its command. From the project root
  (`~/mdad` must exist from an earlier `lab.ps1 deploy matrix` run: only the
  profile `matrix-prepare` copies MDAD there):

  ```powershell
  .\lab.ps1 run mdad --tags=self-check
  ```

  A playbook without a profile runs with a certificate for every machine
  (`lab-all`) and no OpenBao token, with a warning. A new playbook that needs
  OpenBao therefore gets a profile in `config\run-profiles.json` (its `playbook`,
  `principals` and `policies`), its policy as a file in
  `config\openbao\policies\` and, for the token role `ansible-run`, a place in
  that role's `allowed_policies` (`$tokenRoles` in `scripts\lib\LabVault.ps1`);
  then run `.\lab.ps1 deploy vault`, which writes policies and token roles.
  `.\lab.ps1 test` (`Test-LabLayout`) checks that every playbook has a profile
  (or is started by a script in `ansible\bin`) and that every policy a profile
  names exists
  ([Run a playbook, re-run a deployment](#run-a-playbook-re-run-a-deployment)).

### P41. A deployment refuses to generate a missing secret

- **Symptom**: `lab.ps1 deploy keycloak` or `lab.ps1 deploy matrix` stops with
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
  MAS belongs to Keycloak and is created by `lab.ps1 deploy keycloak`, which must
  run before `lab.ps1 deploy matrix`. The third means that the secret exists,
  but without the field the playbook reads: it was probably written by hand
  under another field name.
- **What to do**: restore OpenBao from a snapshot taken before. One exists from
  the first deployment on: `lab.ps1 deploy keycloak` and `lab.ps1 deploy matrix`
  take one after every run, also after a failed one, and `lab.ps1 down` takes
  one before it deletes the vault VM. After such a deletion the snapshots and
  the key shares of their time are in `keys\openbao-retired-<date-time>`; see
  [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot). If the
  data does not matter, rebuild that VM instead (`.\lab.ps1 down
  keycloak`, `.\lab.ps1 up`, then its deployment, `.\lab.ps1 deploy keycloak`):
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
- **What the project does**: `Invoke-LabRun` (`LabRun.ps1`) copies the run's
  files and signs its SSH certificate first, and only then mints the wrapped
  token (`New-LabRunToken` in `LabSecrets.ps1`), so the 120 seconds are not
  spent on the preparation. It pipes the wrapping token into `ssh` on stdin,
  never on a command line, and without `-t`; Ansible's colours are switched on
  with `ANSIBLE_FORCE_COLOR=1` instead (`lab-run --color`, only when the output
  is not redirected and the console can show colours, see
  [P50](#p50-ansibles-colours-appear-as-text-such-as-036m)). On ansible-control,
  `ansible/bin/lab-run` reads nothing from stdin itself and starts
  `ansible/bin/openbao-run`, which keeps only the characters a
  token can contain, passes tokens to `curl` on stdin (`-H @-`) because command
  lines are visible to every user of a machine (`ps`, `/proc`), and when the
  command ends, also after a failure, revokes the real token and removes
  Ansible's temporary folder in RAM. The remote command line is put together as
  text, so a run's arguments must not contain quotes (`Invoke-LabRun` refuses them).

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
  self-signed certificate named `TRAEFIK DEFAULT CERT`; `lab.ps1 deploy matrix`
  stops in `matrix-check.yml` at the task "Traefik serves certificates from that
  CA (matrix, element, the domain)" after 3 minutes of retries, and the failed
  item shows the `issuer` of the certificate Traefik serves. If that issuer is a
  lab intermediate, it is an older one: Traefik still serves a certificate from
  before a rotation or a rebuilt vault VM.
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
  registers again and orders new certificates. `lab.ps1 deploy matrix`
  (`matrix-check.yml`) waits up to 3 minutes per name until Traefik serves a
  certificate whose authority key identifier matches the current intermediate
  (a name alone could match an older one). Look at Traefik's log with
  `.\lab.ps1 connect matrix 'sudo journalctl -u matrix-traefik -n 80'`,
  and at the DNS answer the vault VM gets with
  `.\lab.ps1 connect vault 'getent ahostsv4 matrix.lab.internal'`.

### P45. A script that shows secrets stops before it shows anything

- **Symptom**: `lab.ps1 recovery` (like the other commands for your own window,
  `trust` and `host-setup`) is refused with exit code 2 before it starts:
  "'recovery' changes Windows settings or shows secrets: run it yourself in your
  own PowerShell window."; `lab.ps1 secret -Show` or
  `lab.ps1 unseal -Interactive` stops with "... shows secrets on the screen.
  Run it yourself in a PowerShell window, not through another program or with
  redirected output."; or `lab.ps1 recovery -Destination E:\` stops with
  "The drive E:\ does not exist (USB stick not plugged in?)" or "Cannot write to
  E:\... (...). Nothing was changed."; or it reports "Key share C is no longer on
  this PC (the kit was made already)"; or "Could not make the break-glass login
  (AppRole 'recovery'); run .\lab.ps1 deploy vault once first."
- **Cause**: output that is redirected or captured by another program (a log
  file, a tool, an assistant) could store secrets in plain text, and a Windows
  setting should never change without you watching. So `lab.ps1` refuses the
  commands marked "your own window" in `.\lab.ps1 help` (`UserOnly` in the
  command table, `scripts\lib\Lab.ps1`) when input or output is redirected, and
  `secret -Show`, `unseal -Interactive` and `recovery` itself check for a real
  console window too (`Assert-LabInteractiveConsole` in `LabSecrets.ps1`).
  `-Destination` names a drive that does not
  exist, or a folder that cannot be written (a write-protected stick, a
  read-only share); the script checks both before it shows anything.
  Share C is deleted from the PC once you have confirmed that you stored it, so
  the default mode (which shows it) works only once. The break-glass AppRole is
  created by `lab.ps1 deploy vault`; a lab deployed with an earlier version does
  not have it yet.
- **What to do**: open a PowerShell window yourself, go to the project root and
  run the command there. For the recovery kit, plug in the stick, or choose
  another folder (`.\lab.ps1 recovery -Destination Z:\DeployableServer-recovery`
  for a NAS share; a relative path is taken from the current PowerShell
  folder), or leave out `-Destination`: the file then goes to `keys\recovery`,
  and you copy it off the PC yourself. After these drive and folder errors
  nothing was shown or changed, and share C still waits. A kit that exists is
  opened with `.\lab.ps1 recovery -Open <file>`; a new recovery
  file (with a new break-glass secret; your copy of share C stays valid and is
  not shown again) is made with `.\lab.ps1 recovery -Renew`. For
  the break-glass login, run `.\lab.ps1 deploy vault` first. That error
  comes later than the others: in the default mode only after share C was shown
  and the passphrase entered (with `-Renew`, after the passphrase). Nothing was
  changed, share C still waits on the PC, and the script shows it again once
  `lab.ps1 deploy vault` has created the AppRole.

### P46. After losing the PC's DPAPI keys, nothing logs in to OpenBao

- **Symptom**: after a new Windows installation, a lost profile or a password
  reset by an administrator, every script that reads a `.dpapi` file fails to
  decrypt it (`lab.ps1 unseal`, `lab.ps1 secret`, the deployments;
  a firewall build stops with "keys\opnsense\root-password.dpapi cannot be
  decrypted by this Windows account. Restore it with
  .\lab.ps1 recovery -Recover <file> ...");
  the key shares on paper and in the recovery file still unseal OpenBao, but
  `bao operator generate-root` on the vault VM, the classic way to make a new
  root token from key shares, is refused without a token.
- **Cause**: DPAPI files can only be decrypted by the Windows account (and its
  keys) that wrote them. The bootstrap root token was revoked at the end of
  `lab.ps1 deploy vault`. And since OpenBao 2.5.3 the unauthenticated endpoints
  `sys/generate-root/*`, which built a new root token from a quorum of key
  shares alone, are switched off by default (listener setting
  `disable_unauthed_generate_root_endpoints`): anyone who reached the API could
  start or cancel such an attempt. Their replacement, which
  `bao operator generate-root` uses since OpenBao 2.6, needs a token itself. Key
  shares now unseal OpenBao, but they log nobody in.
- **What the project does**: a break-glass login of its own: the AppRole
  `recovery` (`lab.ps1 deploy vault`; policy `openbao-admin`, accepted only from
  the PC's address), whose secret ID exists only in the passphrase-encrypted
  recovery file. `lab.ps1 recovery` makes a new one for every file and
  destroys the older ones. To get back in, run in your own PowerShell window
  (after a new Windows installation the VMs must first be registered in Hyper-V
  again, which this README does not cover, see
  [Recover after losing the PC's DPAPI keys](#recover-after-losing-the-pcs-dpapi-keys);
  then run `.\lab.ps1 host-setup`, because the login works only
  from 10.10.99.1):

  ```powershell
  .\lab.ps1 recovery -Recover <file>   # asks for the passphrase and share C
  .\lab.ps1 recovery -Renew            # then a new file and a new break-glass secret
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
  firewall build (`.\lab.ps1 firewall -Rebuild`) makes new ones when
  the old ones cannot be decrypted. A recovery file made before the break-glass
  login existed stops `-Recover` with "This recovery file has no break-glass
  login (made before it existed)": it can still unseal
  (`.\lab.ps1 unseal -Interactive`), but not log in. Replace such a
  file with `-Renew` while the PC's DPAPI keys still work
  (`lab.ps1 deploy vault` reminds you with a `PENDING` line).

### P47. `lab.ps1 down vault` stops without deleting anything

- **Symptom**: `.\lab.ps1 down vault` stops with "No OpenBao snapshot
  possible (...), and keys\openbao\snapshots has none, while keycloak and matrix
  keep data that depends on its secrets. Start the vault VM and unseal OpenBao
  (.\lab.ps1 up), then try again; nothing was deleted."
- **Cause**: before it deletes the vault VM, `lab.ps1 down` takes a fresh
  snapshot (`lab.ps1 backup`), because OpenBao holds the only copy of the
  secrets that Keycloak's and Matrix's data were set up with. A sealed or
  unreachable OpenBao gives no snapshot. If an earlier snapshot exists in
  `keys\openbao\snapshots` (every deployment takes one), the script only warns
  ("No fresh OpenBao snapshot (...); the newest kept one is ...") and goes on,
  and so it does when the whole lab is deleted (`lab.ps1 down` without a VM
  name). With no snapshot at all while keycloak or matrix stay, deleting the VM
  could leave them with data that nothing can open any more.
- **What to do**: start the vault VM and unseal OpenBao
  (`.\lab.ps1 up`, or `.\lab.ps1 unseal` when the VM
  is running) and run it again. If OpenBao cannot be brought up any more and no
  copy of a snapshot exists elsewhere either (one made with
  `lab.ps1 backup -Destination`), its secrets are lost, and Keycloak and
  Matrix have to start over too
  ([Rebuild one VM or the whole lab](#rebuild-one-vm-or-the-whole-lab)). To
  remove the broken VM, delete it yourself in Hyper-V Manager, on purpose, and
  run `.\lab.ps1 down vault` again: with the VM gone it takes no
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

- **Symptom**: `.\lab.ps1 run keycloak.yml --check` reports
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

- **Symptom**: the output of a deployment (`lab.ps1 deploy keycloak`,
  `lab.ps1 deploy matrix`, or `lab.ps1 run` with a profile that gets
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
  mode; otherwise the console prints the sequences as text. Runs without
  a run token are not affected: `lab.ps1 run` runs them with
  `ssh -t`, and in a terminal session `ssh` prepares the console itself.
- **What the project does**: for a run with a token, `Invoke-LabRun`
  ([LabRun.ps1](scripts/lib/LabRun.ps1)) first calls `Enable-LabConsoleColors`
  ([LabSecrets.ps1](scripts/lib/LabSecrets.ps1)), which switches virtual terminal
  processing on for
  the current console window (the Windows function `SetConsoleMode` with the
  flag `ENABLE_VIRTUAL_TERMINAL_PROCESSING`, Windows 10 and later). Only when
  that worked does it pass `--color` to `ansible/bin/lab-run`, which then sets
  `ANSIBLE_FORCE_COLOR=1` for the run. When the output is
  redirected to a file, or the console refuses, no colours are requested, so a
  log file stays plain text.

### P51. Copying or unpacking `vendor\mdad` fails in a deep project folder

- **Symptom**: a program that copies, packs or unpacks the project reports
  that a path is too long or cannot be found, for a file deep in
  `vendor\mdad\roles\...`: Explorer, a ZIP tool or a Git checkout, or `tar` in
  `lab.ps1 mdad-upgrade` ("Unpacking the roles failed") or when
  `lab.ps1 deploy matrix` packs MDAD for ansible-control (profile
  `matrix-prepare`: "tar of vendor\mdad failed").
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

- **Symptom**: `lab.ps1 connect`, a deployment, `lab.ps1 up` or a
  `vagrant` command stops with `Host key verification failed.` or
  `Permission denied (publickey)`, or with the lab's own message `... Start and
  unseal OpenBao with .\lab.ps1 up, or let the offline CA sign
  (break-glass) ...`; the Vagrantfile stops with `The PC's SSH certificate could
  not be renewed (see above)`.
- **Causes and what to do** (how the certificates work:
  [SSH certificates](#ssh-certificates-user-and-host-cas)):
  - **The PC's certificate has expired, and OpenBao cannot sign a new one.** It
    is valid for 8 hours, so after a Windows restart it has always expired, and
    the vault VM is off then. The scripts do not fall back to the offline SSH CA
    by themselves. Run `.\lab.ps1 up`: it starts the firewall
    and the vault VM in Hyper-V and unseals OpenBao before any SSH. If OpenBao
    stays broken, let the offline SSH CA sign, on purpose, by putting `breakglass`
    in front of one command: `.\lab.ps1 breakglass ssh-cert -Force` or
    `.\lab.ps1 breakglass connect <vm>` (the PC's certificate),
    `.\lab.ps1 breakglass up` or `.\lab.ps1 breakglass firewall` (host
    certificates too). `breakglass` sets `$env:LAB_SSH_BREAKGLASS = '1'` for that
    one command and removes it again afterwards; set it yourself for every
    command in this window, `vagrant`
    included (`Remove-Item Env:LAB_SSH_BREAKGLASS` ends it). A break-glass
    certificate lasts as long as a normal one; once OpenBao works again, the
    next renewal comes from it. `.\lab.ps1 ssh-cert` shows
    which CA signed the current certificate and until when. The message
    `OpenBao serves another SSH CA than the one the machines trust` means a
    restored snapshot: see
    [Restore OpenBao from a snapshot](#restore-openbao-from-a-snapshot), step 3.
  - **The machine has no valid host certificate**: a VM created or rebuilt by
    `vagrant` alone, a host certificate that expired (the PC renews them 30 days
    ahead, but only when `lab.ps1 up` or `lab.ps1 firewall` runs), or
    one from a CA the PC no longer trusts. The PC accepts host keys only with a
    certificate (`HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com`,
    `StrictHostKeyChecking yes`), so ssh answers `Host key verification failed.`
    Run `.\lab.ps1 up` (elevated: it reads the VM's host key from
    Hyper-V) or, for the firewall, `.\lab.ps1 firewall`; both install
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
    If ssh by hand behaves differently from `lab.ps1 connect`, check which one
    runs: `(Get-Command ssh).Source`.
  - **`Permission denied (publickey)` in a playbook run**: the run's certificate
    lacks the principal for that host (a playbook that touches a machine its
    profile in `config\run-profiles.json` does not list under `principals`), or
    the playbook was started by hand on ansible-control, which holds no
    certificate between runs
    ([P40](#p40-a-playbook-run-without-the-pc-has-no-openbao-token)), or SSH comes
    from an address the certificate and the server do not allow (a VM-to-VM
    login other than from ansible-control, or the PC's certificate used from
    ansible-control).
- **What the project does**: it fails closed and says why. Every script renews
  the PC's certificate when fewer than 4 hours are left, so a certificate never
  expires in the middle of a run, and an OpenBao that is down, sealed or not
  genuine never moves signing to the offline CA without a `breakglass` from
  you.

### Other design decisions you will meet in the code

- One entry point, `lab.ps1`, and a plain script on purpose (no
  `[CmdletBinding()]`): its only parameter is the command, checked by
  `ValidateSet` (Tab completes the names, and PowerShell itself refuses an
  unknown one), and everything after the command lands in `$args` and is handed
  on unchanged to the command's script or library function (the table
  `$LabCommands` in `scripts\lib\Lab.ps1`). An advanced script would take `-v`
  for itself (as `-Verbose`) and refuse every argument it does not know,
  `--check` and `-WhatIf` among them (`-WhatIf` exists only with
  `SupportsShouldProcess`) ([P11](#p11-windows-powershell-51-quirks)); the parameter is named
  `_Command` so that no abbreviation a command uses (`-s`, `-c`, `-f` ...) can
  match it. Exit codes: 0 done, 1 failed or unknown command, 2 refused before
  anything changed (not elevated, not your own window); `run`, `connect` and
  `test` pass on the exit code of what they ran. `Test-LabLayout` checks that
  the `ValidateSet` and the table name the same commands. Enterprise equivalent:
  one CLI with subcommands (`az`, `kubectl`, `gh`).
- The PowerShell libraries are plain `.ps1` files, loaded by "dot-sourcing"
  (`. <file>`): `lab.ps1`, every command script and every test load
  `scripts\lib\Lab.ps1` that way, always at script level, never inside a function, and `Lab.ps1`
  dot-sources `LabSecrets.ps1`, `LabSsh.ps1`, `LabPki.ps1`, `LabRun.ps1` and
  `LabVault.ps1`. Dot-sourcing puts their functions and `$script:` variables
  (project root, `keys\`, `config\lab.json`, OpenBao's address) into the
  caller's script scope, where every later call finds them; loaded inside a
  function, they would be gone when that function returns. Before it loads
  anything, `Lab.ps1` checks the project root (`lab.ps1`, `config\lab.json` and
  `vagrant\Vagrantfile` must be there): a wrong root would make every library
  look for `keys\` in the wrong place, and the SSH CA setup would create a new
  offline SSH CA there. `LabFirewall.ps1` is the exception: only
  `scripts\commands\firewall.ps1` and the firewall tests load it, because it
  defines many variables of its own. Enterprise equivalent: a PowerShell module
  (`.psm1`) with a manifest.
- The commands marked "your own window" in `.\lab.ps1 help` (`host-setup`,
  `trust`, `recovery`; `UserOnly` in the command table) are refused with exit
  code 2, before anything runs, when input or output is redirected: they change
  Windows settings or show secrets, and a redirected console means that
  something else reads along (a log file, a tool, an AI assistant's shell). So
  only you, in your own PowerShell window, run them, and changes to Windows'
  network, DNS rule and trust store never happen silently: `lab.ps1 up` only
  checks that the network and the DNS rule exist (and stops if they do not), and
  never touches the trust store
  ([P45](#p45-a-script-that-shows-secrets-stops-before-it-shows-anything)).
  Enterprise equivalent: privileged changes that need a person at an attended
  session, never an unattended pipeline.
- The box `gusztavvargadr/ubuntu-server-2404-lts` is used because
  `bento/ubuntu-24.04` has no Hyper-V image. For OPNsense there is no Hyper-V box
  at all, hence `lab.ps1 firewall`.
- The default `/vagrant` synced folder is disabled because SMB on Hyper-V would
  ask for Windows credentials. Files reach the VMs through Vagrant file
  provisioners and `lab.ps1 run` (tar + scp).
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
- Colours: the zsh prompt, zsh-syntax-highlighting (both in
  `ansible/files/base/zshrc.lab`, installed by `base.yml`) and Ansible's
  `verbose` colour avoid blue, which is unreadable on the blue background of
  Windows PowerShell: `verbose = magenta` in `ansible/ansible.cfg`, and
  `ANSIBLE_COLOR_VERBOSE=magenta` from `ansible/bin/lab-run` for every run, so
  also for MDAD's runs, which use MDAD's own `ansible.cfg`.
- Generated passwords contain only letters and digits (OpenBao's password
  policies `lab-alnum-24`, `lab-alnum-48` and `lab-alnum-64`, written by
  `openbao-config.yml` from `ansible/playbooks/vars/openbao-config.yml`, and the
  PC's own generators): Docker Compose would
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
- OpenBao's own TLS certificate is signed by the offline root, not by OpenBao's
  intermediate: it must work before OpenBao exists or while it is sealed, and a
  certificate OpenBao issued to itself could, once expired, only be renewed
  through the server it protects. The firewall's GUI certificate comes from the
  root only once, at the first boot of a new firewall, which is built before
  OpenBao exists; from then on `firewall.yml` renews it from the intermediate,
  with a key made on the firewall, like Keycloak's. So the root signs only CAs,
  OpenBao's TLS certificate and that one first GUI certificate, and its key is
  unlocked as rarely as possible.
- Ansible talks to OpenBao's HTTP API with `ansible.builtin.uri`, not with the
  `community.hashi_vault` collection: no extra Python library (`hvac`) on
  ansible-control, and every request is visible in the playbooks: mostly in
  `tasks/openbao-secrets.yml`, `tasks/openbao-certificate.yml` and
  `tasks/openbao-api.yml`, plus the few calls a playbook makes itself
  (`firewall.yml`'s signing request, `openbao-config.yml`'s token and mount
  checks, public reads such as `pki_int/ca/pem`).
- OpenBao's configuration plane (`openbao-config.yml`) does not simply send
  every object on every run: `tasks/openbao-api.yml` reads each object, compares
  the keys the repository sets (`ansible/playbooks/vars/openbao-config.yml`,
  written in the form OpenBao returns them on a read) and writes only when one
  differs ("read-compare-write"). So a second run reports `changed=0`, and a
  run that reports a change has found a real difference: a new value in the
  repository, or drift, for example a value changed by hand in the web UI;
  `.\lab.ps1 run openbao-config --check --diff` shows it without writing
  anything, and `Test-LabOpenBaoConfig` fails on drift. Nothing is ever
  deleted: an object the repository does not name stays as it is.
  `-e openbao_config_force=true` writes every object once, to try each write
  request. Enterprise equivalent: a declarative tool with a plan step, such as
  Terraform's Vault provider (`terraform plan` shows the drift before `apply`).
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
- The intermediate CA rotates, the root does not. `lab.ps1 deploy vault` makes a
  new intermediate when the current one expires within 400 days (longer than
  the longest certificate it issues, Keycloak's year) or with
  `-RotateIntermediate`. Key and issuer names in OpenBao must be unique, so a
  rotation names them by date and time (`lab-int-<yyyyMMdd-HHmmss>`, common
  name "DeployableServer Lab Intermediate CA <yyyy-MM-dd>"); the first
  intermediate of an empty OpenBao gets
  the year (`lab-int-<yyyy>`, "... CA <yyyy>"). The old issuer stays in OpenBao
  and keeps publishing its CRL until its certificates have expired; Keycloak,
  Traefik and the firewall's web GUI move to the new one at their next deployment
  (the firewall's also through the maintenance step of `lab.ps1 up`), which
  recognises an old certificate by its authority key identifier, not by the
  CA's name.
- An OpenBao snapshot after every deployment of Keycloak and Matrix, also after
  a failed one: a first deployment creates secrets that exist nowhere but in
  OpenBao, and a failure later in the run does not undo them.
- Renewals run from `lab.ps1 up` (step 7, the same as `.\lab.ps1 maintain`),
  not from a scheduled task:
  the lab runs only while the PC does, and that script already runs after every
  Windows restart. Its check (`Get-LabMaintenanceDue` in `LabSecrets.ps1`) reads
  only public information (the certificates OpenBao, Keycloak and the firewall's
  GUI serve, the root CRL on the PC and on the vault VM, OpenBao's CA
  certificate) and needs no login.
- The PC's TLS pin applies to OpenBao's host name only, and there it accepts
  only a certificate the root signed directly, never one from OpenBao's own
  intermediate
  ([What the CA name constraint protects](#what-the-ca-name-constraint-protects)).

---

## 10. Security notes

### Lab-only shortcuts and their enterprise equivalents

These shortcuts are deliberate, so that the lab stays simple to rebuild. Do not
copy them to production.

| Lab shortcut | Where | Enterprise equivalent |
|---|---|---|
| Passwordless sudo for `ansible`, a local account created on each Ubuntu VM; on the firewall, `ansible` is a full administrator with passwordless sudo too (`sudo_allow_wheel`) | `bootstrap-ansible-user.sh`, `config.xml.template` | Personal admin accounts from a directory (LDAP, FreeIPA, Active Directory), sudo with a password or narrowly scoped rules, privileged access management (PAM), Ansible become passwords from a vault, sudo use logged centrally |
| Console autologin on tty1 (the Ubuntu VMs except vault) | `base.yml`, `config/lab.json` | Console login with credentials (ideally MFA); out-of-band console access is restricted and audited; a break-glass account whose password is kept in a vault |
| The PC signs its own SSH certificates: an 8-hour certificate for every machine (principal `lab-all`), requested from OpenBao with the AppRole `pc-deploy` from DPAPI; the PC's SSH key has no passphrase. No personal identity, no MFA, and every program that runs as you can get such a certificate | `LabSsh.ps1`, `lab.ps1 deploy vault`, `keys\ssh` | People log in to the SSH CA with SSO and MFA (OIDC to Vault or OpenBao, Teleport, Smallstep) and get a short certificate for their own identity, with principals from their IdP groups; keys on hardware tokens (FIDO2) |
| The offline SSH CA lives on your everyday PC: its encrypted key next to its passphrase in DPAPI, every machine trusts it permanently, and the recovery file holds a copy. While it signs, its passphrase is on `ssh-keygen`'s command line (`-P`; OpenSSH 8.1 has no other unattended way), readable for programs running as you or as an administrator and written to the Security event log if process command lines are audited. Its signatures are recorded only in `keys\ssh\issued.log` (and in the sshd logs), not in OpenBao's audit log | `lab.ps1 up` (`Initialize-LabSshCa` in `lib\LabSsh.ps1`), `LabSsh.ps1`, `lab.ps1 recovery` | The SSH root of trust in an HSM or on an air-gapped machine, used only in a documented ceremony; break-glass certificates issued by two people, with an alert and central logging |
| Per-run SSH principals on ansible-control (`host-matrix` for MDAD, `lab-all` for `ping.yml`) share one account `ansible`, one key and passwordless sudo: code that runs during one run and stays on ansible-control could pick up the certificate of a later run. The scoping protects against mistakes and short-lived misuse, not against a persistent compromise of ansible-control | `lab.ps1 run`, `LabSsh.ps1`, `bootstrap-ansible-control.sh` | One identity per automation: each CI/CD or AWX job gets its own short certificate in an ephemeral runner; third-party code such as MDAD in an account of its own without sudo |
| Vagrant's own last hop to each VM (user `vagrant`, Vagrant's per-VM key) does not check the VM's host key; nothing of the lab's trust depends on it | Vagrantfile | Provisioning only over channels whose host identity is known (host keys or certificates from the image build or an attested agent) |
| The SSH host key revocation list is checked only by the clients that matter here, the PC and ansible-control; host certificates are valid for a year | `LabSsh.ps1`, `lab.ps1 down`, `bootstrap-ansible-control.sh` | Short-lived host certificates renewed by an agent on every server, so revocation is rarely needed; where it is, the list distributed to every client by configuration management |
| "Secret zero" on the PC: two of OpenBao's key shares, the PC's two AppRole logins and the passphrases of the root CA key and of the offline SSH CA key are DPAPI files that your Windows account can decrypt, so the PC unseals and administers OpenBao, and signs SSH certificates, without any input. Every program that runs as you can do the same | `LabSecrets.ps1`, `lab.ps1 unseal`, `keys\openbao`, `keys\pki`, `keys\ssh` | Auto-unseal through an HSM or a cloud KMS; unseal and recovery keys split among several people; administrators log in through SSO with MFA; automation authenticates with an identity the platform vouches for (cloud instance identity, Kubernetes service accounts) instead of a stored credential |
| One OpenBao node, sealed after every restart of the vault VM until the PC unseals it; snapshots after every deployment of Keycloak and Matrix, before the vault VM is deleted and when you run `lab.ps1 backup`, kept on the PC (the newest 10); nothing copies them elsewhere unless you use `-Destination` | `lab.ps1 deploy vault`, `lab.ps1 unseal`, `lab.ps1 backup`, `lab.ps1 deploy keycloak`, `lab.ps1 deploy matrix`, `lab.ps1 down` | A 3-5 node raft cluster across failure domains with auto-unseal, scheduled snapshots stored off-site and restore drills, disaster-recovery replication to a second site, monitoring of seal status and leadership |
| OpenBao is administered through AppRoles whose policy `openbao-admin` allows everything, bound only to the PC's address: `pc-admin` for the scripts, and the break-glass login `recovery`, whose secret is only in the recovery file. No personal administrator accounts and no MFA (no login method for people at all). The bootstrap root token is revoked, and key shares alone no longer make a new one (OpenBao 2.5.3 switched the unauthenticated generate-root endpoints off) | `lab.ps1 deploy vault`, `lab.ps1 secret`, `lab.ps1 recovery` | Personal administrators through OIDC (SSO with MFA) with narrowly scoped policies; break-glass credentials sealed and split among several custodians, every use alerted on and followed by a rotation; root tokens only generated in an emergency, by several key holders together, and revoked right after |
| OpenBao's configuration is split in two planes, but one person holds both: the PC writes the identity plane (the ACL policies from `config/openbao/policies/*.hcl`, AppRoles, token roles, the SSH CA, the intermediate CA), and `openbao-config.yml` on ansible-control writes the configuration plane (KV mount, password policies, the intermediate's mount, URLs, revocation list, tidying, PKI roles, ACME) with a 30-minute token of the policy `openbao-config` (token role `ansible-config`). That token cannot write policies, logins or CAs, issue a certificate or read a secret, but it is minted by `pc-admin`, the login that can do everything, and it may change what a PKI role issues; nobody else reviews such a change | `lab.ps1 deploy vault`, `LabVault.ps1`, `openbao-config.yml`, `vars/openbao-config.yml`, `config/openbao/policies/` | Separation of duties: an IAM or security team owns identities and policies, a platform team's pipeline applies the engines' configuration from a reviewed repository (for example the Terraform/OpenTofu Vault provider), each with a credential of its own, every change approved by a second person, drift reported |
| Service secrets in plain text where the services read them: during an Ansible run they are only in memory (pipelining, temporary files in RAM), but on the VMs they are in environment and configuration files (0600 in `/opt/keycloak-stack`; on the matrix VM MDAD's files are readable by the `matrix` user, inside 0750 folders) and in the services' databases. They are static: the policies grant `create` but not `update`, and nothing rotates them | `keycloak.yml`, `lab-setup.yml`, `tasks/openbao-secrets.yml`, MDAD | Services fetch their secrets themselves at start (Vault Agent, a CSI driver, the application's own Vault integration); dynamic, short-lived database credentials (a database secrets engine); rotation on a schedule |
| Recovery kit: you keep key share C (password manager or paper), and one passphrase-encrypted file holds share B, the break-glass login for OpenBao, the encrypted root CA key with its passphrase, the root certificate, the encrypted offline SSH CA key with its passphrase and the firewall's passwords and API key, typically on a NAS or USB stick. With its passphrase, the file alone is administrator access to OpenBao and SSH access to every lab machine (from the PC's address). One person holds everything and can use it alone (`lab.ps1 recovery -Recover`) | `lab.ps1 recovery` | Unseal and recovery shares handed to several key holders (each share encrypted for one person, for example with PGP), kept in separate safes; a documented break-glass procedure that is practised, needs two people and raises an alert; the root CA key backed up in HSMs |
| Keycloak's bootstrap admin `admin` and bootstrap service-account client `lab-ansible` are kept, although Keycloak marks both "temporary"; `lab-ansible` has full admin rights in the `master` realm | `keycloak.env.j2`, `keycloak.yml` | Permanent personal admin accounts with MFA and a dedicated, least-privilege automation client, all created as code; the temporary bootstrap accounts deleted afterwards |
| Keycloak's admin console is on the same host name as the login pages, reachable from the PC | `keycloak.env.j2`, `config/lab.json` | The admin console on a separate host name reachable only from a management network |
| Lab users with generated passwords, no MFA, Keycloak's default password policy (brute-force protection is on, self-registration off) | `keycloak.yml` | MFA (WebAuthn, OTP) and a password policy in the IdP, users from the HR process or a directory, joiners/movers/leavers automated |
| `on_conflict: replace`: when a Matrix account with the same user name exists but is linked to another Keycloak user ID (after a Keycloak rebuild), MAS re-links it instead of refusing the login. Whoever can create a Keycloak user with that name gets the Matrix account | `vars.yml` | Keep MAS's default (refuse), back up Keycloak so user IDs never change, and treat the IdP's user IDs as permanent |
| Matrix admin rights from a list in MAS's policy (`admin_users: [alice]`) | `vars.yml` | Admin rights from an IdP group or role claim, granted through an approval process and reviewed regularly |
| Leavers keep their Matrix sessions: disabling or deleting a user in Keycloak blocks new logins, but Element sessions already signed in keep working (back-channel logout ends only MAS's browser session, `logout_browser_only`); nothing deprovisions Matrix accounts | `vars.yml`, `keycloak.yml` | A leaver process that disables the IdP account and, through SCIM or the application's admin API, ends every session at once; short token lifetimes |
| Backups only for OpenBao (snapshots, taken by the deployments and `lab.ps1 down` or by hand, kept on the PC; restoring one needs the key shares of its time); removing or losing the matrix or keycloak VM loses all messages, media, accounts and Keycloak's database | `lab.ps1 backup`, everywhere else | Scheduled, tested backups (database dumps, media, configuration), stored off the host, with a restore drill |
| Offline root CA on your everyday PC: its key is an encrypted file (PKCS#8, AES-256) on the same disk as its passphrase (DPAPI); the root also signs OpenBao's own TLS certificate directly, because it must work before and without OpenBao, and a new firewall's first GUI certificate, because the firewall is built before OpenBao exists (from then on the firewall's certificates come from the intermediate) | `lib\LabPki.ps1`, `keys\pki`, `lab.ps1 deploy vault`, `lab.ps1 firewall` | The root on an air-gapped machine or in an HSM, used in a documented key ceremony with several people present, signing only intermediate CAs; intermediate keys in HSMs; servers get certificates from an intermediate through ACME or CSR signing (as here) |
| OpenBao's identity rests on a hand-written pin on the PC: for `vault.lab.internal` the PC's scripts accept only a certificate that the offline root signed directly (a chain of exactly two, `LabTlsPin3`), which is why the root still signs a server certificate. ansible-control (`openbao-run`, the playbooks) and the browser trust the lab root for OpenBao and rely on the intermediates' name constraint, which excludes `vault.lab.internal` only in intermediates made since that exclusion exists | `LabSecrets.ps1`, `lib\LabPki.ps1`, `lab.ps1 deploy vault` | The secrets manager's TLS certificate from a CA of its own that issues nothing else, every client trusting exactly that CA for it (a dedicated trust store rather than a pin in code), often mutual TLS |
| Revocation through CRLs only (no OCSP), and no procedure that ever revokes a certificate. Renewals happen only when a script runs, not on a schedule: `lab.ps1 up` (after every Windows restart) checks what is due and runs the script that renews it: OpenBao's own certificate (397 days, renewed 30 days before it expires), the root's CRL (400 days, 60 days before) and the intermediate CA (3 years; a new one 400 days before it expires) through `lab.ps1 deploy vault`, Keycloak's certificate (1 year, 30 days before) through `lab.ps1 deploy keycloak`, the firewall's GUI certificate (1 year from the intermediate, 30 days before, and at once while it does not come from the current intermediate, like a new firewall's first one from the root) through `lab.ps1 deploy firewall`. Only the Matrix certificates (90 days, ACME) renew themselves. No rollover procedure yet for the root (10 years) | `lab.ps1 up`, `LabSecrets.ps1`, `lib\LabPki.ps1`, `lab.ps1 deploy vault`, `tasks/openbao-certificate.yml`, `lab.ps1 deploy firewall`, `firewall.yml` | OCSP or short-lived CRLs published automatically, a revocation process, expiry monitoring with alerts, every certificate renewed automatically on a schedule by an agent or ACME client (cert-manager, certmonger, Vault Agent), planned and rehearsed CA rollovers |
| ACME without external account binding: anything that reaches port 8200 can register an ACME account; only the HTTP-01 challenge (answered on port 80 of the name's lab address) and the three names of the role `acme-matrix` stand between it and a certificate | `vars/openbao-config.yml`, `lab.ps1 deploy vault` | External account binding (EAB), so that only registered clients can order; the ACME directory reachable only from the server networks |
| Self-built SSH bastion without MFA or session recording, running on the perimeter firewall itself (restricted to certificate logins of `ansible` from the PC and ansible-control, and to forwarding to port 22 of the lab VMs) | `keys\ssh_config`, `lab.ps1 connect`, `config.xml.template`, `opnsense/sshd_config.d/20-lab-ssh.conf` | MFA on the bastion, session recording, often a managed product (e.g. Azure Bastion, AWS Systems Manager Session Manager, Teleport); the bastion is a separate host in a management network |
| Firewall administration: the GUI user `root` with a random password; one full-admin account `ansible` serves as SSH jump account and REST API user. These passwords and the API key and secret are DPAPI files on the PC (`keys\opnsense\*.dpapi`, with copies in the recovery file), not in OpenBao, because the firewall exists before OpenBao | `lab.ps1 firewall`, `config.xml.template`, `keys\opnsense\` | Personal admin accounts from central authentication (RADIUS, LDAP) with MFA; the local root password only as a break-glass credential in a vault; a separate, restricted jump account (the lab restricts forwarding with `PermitOpen`, but for its one full-admin account) and a separate least-privilege API user per automation tool, with secrets in a vault |
| Firewall management (GUI, API, SSH, DNS) open to the whole lab network, and on the PC side to 10.10.99.1, your everyday workstation, which also browses the internet | `config.xml.template` | Management interfaces reachable only from a dedicated management network (often out-of-band), never from server networks; administration only from privileged access workstations (PAW) or a management jump host |
| GUI changes on the firewall are not written back to the repository; a permanent change needs a repository edit and a rebuild | `config.xml.template`, `config/lab.json`, `lab.ps1 firewall` | Changes through the firewall's API from reviewed automation code, the GUI used read-only, configuration backups in version control, drift detection |
| The Ansible project and the vendored MDAD are pushed from the PC as archives, from the working folder as it is, not from a reviewed commit (the repository is in Git, github.com/masterries/HomeLab, but nothing enforces that what runs is committed); MDAD and its roles were fetched from GitHub by `git subtree` / `lab.ps1 mdad-upgrade` and are trusted as GitHub delivered them (no signature check), the review is the diff you read yourself | `lab.ps1 run`, `lab.ps1 deploy matrix`, `lab.ps1 mdad-upgrade` | The control node, AWX / Ansible Automation Platform or a CI/CD runner checks out a reviewed Git commit before every run; third-party code from an internal mirror or Ansible Automation Hub, in approved versions, upgrades reviewed as pull requests |
| Ansible is pinned to a package version (`ANSIBLE_VERSION`), but the Python libraries pip resolves for it are not; Docker CE on the Keycloak VM, Ubuntu's own packages and the Vagrant box come in their current version | `bootstrap-ansible-control.sh`, `keycloak.yml`, Vagrantfile | Pinned versions everywhere (lock or constraints files, execution environments, pinned packages from an internal mirror), tested upgrades |
| Container images straight from public registries (Docker Hub, quay.io, ghcr.io); only Keycloak is pinned by digest, the others by tag; no image scanning or signature check | `keycloak.yml`, MDAD | An internal registry that mirrors approved images, vulnerability scanning, signature verification (e.g. cosign), digests everywhere |
| Lab VMs can reach each other on every port (no host firewalls); for example any lab VM can reach Synapse's internal federation port 8448, Keycloak's admin API and OpenBao's API | the network design | Host firewalls or micro-segmentation, so that only the needed flows (MAS -> Keycloak, Keycloak -> MAS, ansible-control and Traefik -> OpenBao) are allowed |
| Router, firewall, DNS and DHCP on one small VM, only one of it; its logs stay on the firewall; the applications' logs and OpenBao's audit log stay on their VMs | `config.xml.template`, `lab.ps1 firewall`, `openbao.hcl.j2` | A redundant firewall pair (OPNsense supports this with CARP), at least two DNS servers, DHCP failover, the address plan in an IPAM tool, central logging (SIEM), monitoring, IDS/IPS |
| Little egress filtering: the lab may reach everything except the LabHost network and the WAN (Default Switch) network with your PC's Default Switch address. That still includes your home network through Windows NAT; only your home devices' own protection stands in the way | `config.xml.template` | Outgoing traffic filtered too (often web access only through a proxy); lab servers allowed to reach only the services they need; a lab or DMZ never has a route into office or home networks |
| Firmware: the firewall is updated only during a build, to the latest 26.7.x, and later runs update only what is below the pinned minimum 26.7.7; nothing patches it on a schedule (GUI: System > Firmware). The image comes straight from the public mirror, trusted through a hash and a signing-key fingerprint pinned by hand in the script; updates come straight from `pkg.opnsense.org`. The Ubuntu VMs are not patched on a schedule either | `lab.ps1 firewall` | Patch management: a defined patch cycle with maintenance windows, alerts on security advisories and vulnerability scanning; updates tested on a staging system first and rolled out to an HA pair one node at a time; images and packages from an internal, vetted mirror or artifact repository |

Some precautions are taken even in the lab:

- `keys/` (the encrypted offline SSH CA key and the PC's SSH key, the encrypted
  root CA key, the DPAPI files, the OpenBao snapshots and a recovery file kept on
  the PC) is in `.gitignore`. The folder itself is readable only by you and
  SYSTEM (`Initialize-LabSshCa` in `lib\LabSsh.ps1`), and the most sensitive files are
  locked down individually (`icacls`). No secret on the PC that opens anything on its own is
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
  you ask for it (`lab.ps1 breakglass <command>`)
  ([SSH certificates](#ssh-certificates-user-and-host-cas)).
- No service secret is stored on ansible-control's disk: the playbooks read
  them from OpenBao into memory for one run (`tasks/openbao-secrets.yml`). With
  pipelining (`ansible.cfg`), modules and their arguments (the run token, secret
  values) reach Python on stdin instead of a temporary file, and Ansible's
  local temporary files (templates rendered before they are copied, such as
  Keycloak's env files) go to a private folder in RAM that `openbao-run`
  removes when the run ends (`ANSIBLE_LOCAL_TEMP`). The values end up only where
  the running services need them, on their own VMs.
- Every run that needs OpenBao gets its own token, with only the policy its
  playbook needs (`ansible-keycloak`, `ansible-matrix`, `ansible-firewall` or
  `ansible-web`, through the token role `ansible-run`), valid for at most two
  hours and only from ansible-control's address; the run of `openbao-config.yml`
  gets the policy `openbao-config` through the token role `ansible-config`, for
  at most 30 minutes, also only from there. It travels response-wrapped (a
  single-use wrapping token, valid for 120 seconds) on stdin, never on a command
  line, and `openbao-run` revokes it when the run ends.
- OpenBao's policies are write-once: a playbook may create a missing secret
  (with check-and-set, `cas=0`) and read it, but never change one (`update` is
  not granted). OpenBao generates the values itself (password policies), and the
  playbooks refuse to generate new ones for a service that already has data.
- OpenBao's bootstrap root token is revoked at the end of `lab.ps1 deploy vault`.
  The PC's AppRoles accept logins only from the PC's address (10.10.99.1/32),
  and their tokens work only from there: `pc-deploy` may do nothing but mint run
  tokens for deployments (`ansible-run`), take snapshots and have SSH
  certificates signed; `pc-admin` and the break-glass login `recovery` are
  administrators; the token of the configuration run (`ansible-config`) is
  minted with `pc-admin` (with the root token while the bootstrap is not
  finished), never with `pc-deploy`. The break-glass secret is stored nowhere
  but in the passphrase-encrypted recovery file, and every new file replaces it. Whenever
  a login is issued again (`New-LabAppRoleSecret`), all older secret IDs of that
  AppRole are destroyed once the new one is stored, so a lost or copied one stops
  working. Every request is
  recorded in OpenBao's audit log on the vault VM (`/var/log/openbao/audit.log`,
  secret values replaced by HMAC hashes).
- OpenBao's configuration plane cannot hand out rights. `openbao-config.yml`
  sets up the engines (the KV mount, password policies, the intermediate's
  mount, URLs, revocation list, tidying, PKI roles and ACME) from ansible-control,
  but its policy `openbao-config` cannot write ACL policies, auth methods,
  AppRoles or token roles, touch the SSH CA, import or choose a CA, issue or sign
  a certificate, or read a secret: that identity plane stays with the PC. The
  playbook stops when its token has any other policy, it never deletes anything,
  and `Test-LabOpenBaoConfig` asks OpenBao (`sys/capabilities-self`) what the
  token may and may not do.
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
- Scripts that show secrets (`lab.ps1 secret -Show`,
  `lab.ps1 recovery`, `lab.ps1 unseal -Interactive`) run only in a
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
  code; only `lab.ps1 mdad-upgrade` fetches MDAD (a `git subtree pull`, a commit
  you can compare with the previous version before it is used).
  `lab.ps1 deploy matrix` refuses to run when the vendored commit and the pinned
  `mdad_version` differ.
- The firewall's `config.xml` stores passwords and the API secret only as
  SHA-512-crypt hashes, made by `openssl passwd -6 -stdin` with the secret on
  stdin. The seed ISO, which carries that file and the GUI's private key, and
  the `config.xml` staged for it exist only during a build: both are removed on
  every exit path, also when the first boot fails, and a later run of
  `lab.ps1 firewall` removes an ISO left behind (for example after the
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
  (`lab.ps1 host-setup`, `lab.ps1 trust`), and each can be
  undone with `-Remove`. `lab.ps1 up` only checks that the network and the
  DNS rule exist, and never touches the trusted root certificates. On
  the Windows side it changes nothing but lab-specific items, and reports each
  one: the Private switch `LabNet` (no host adapter, so your PC's networking is
  untouched), the user variable `VAGRANT_HOME` if it is missing, the
  `vagrant\.vagrant` junction, the Hyper-V file locations of the lab VMs, and
  (through `lab.ps1 firewall`) the firewall VM and its image cache under the
  storage folder.
- The lab root CA is trusted only by your Windows user, not by the whole
  machine. For OpenBao the PC's scripts go further and pin it: they accept
  OpenBao's certificate only when that root signed it directly (a chain of
  exactly two, the certificate and the root, compared by thumbprint) and it
  names the right host, whatever else Windows trusts (a root added by
  TLS-inspecting security software, the retired first lab CA, or a certificate
  for `vault.lab.internal` from OpenBao's own intermediate is not enough), and
  also before you have imported the root
  ([Internal PKI](#internal-pki-certificate-authority),
  [What the CA name constraint protects](#what-the-ca-name-constraint-protects)). On
  ansible-control, `openbao-run` and the playbooks likewise trust only the lab
  root for OpenBao (`--cacert`, `ca_path`), but without the pin: there it is the
  intermediates' name constraint that keeps them from vouching for OpenBao.
- The internal machines are not reachable from the PC except through the
  bastion and the published ports.
- `lab.ps1 down` deletes a VM named `firewall` only if its Notes carry the tag
  that `lab.ps1 firewall` writes there, so it cannot remove a VM it did not
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
certificates, never another CA, and each carries the same name constraints
(those made since OpenBao's own name was excluded carry one more, below), so
it stays limited even if it were ever chained to another root. Because the
extensions are marked critical, a client that does not understand them must
reject the certificate instead of ignoring them. Even a stolen root or
intermediate key therefore cannot be used against real websites. On top of that,
the keys are protected (the root's encrypted on the PC, the intermediates' never
leaving OpenBao), and OpenBao's roles issue only their listed names.

One name needs more than that: `vault.lab.internal`, OpenBao's own. The PC
sends OpenBao its unseal key shares and its AppRole logins, so whoever could
present a valid certificate for that name could pose as OpenBao and collect
them. OpenBao's intermediate must therefore never be able to issue it, also
not when someone changes a PKI role (the configuration plane may change roles,
[Lab-only shortcuts](#lab-only-shortcuts-and-their-enterprise-equivalents)).
Two things close that, one in the certificates and one on the PC:

- **The name constraint.** Every intermediate the root signs carries
  `excluded DNS:vault.lab.internal` (`v3_intermediate` in `lib\LabPki.ps1`), so
  Windows, browsers and OpenSSL reject a certificate for OpenBao's name from it,
  whatever its roles allow. This holds only for intermediates made since that
  exclusion exists: a certificate the root signed cannot be changed afterwards, so
  an intermediate signed before it stays allowed to issue the name until it is
  replaced ([Rotate the intermediate CA](#rotate-the-intermediate-ca)).
- **The TLS pin** (`LabTlsPin3` in `LabSecrets.ps1`). For `vault.lab.internal`
  the PC accepts only a certificate the lab root signed **directly**: a chain of
  exactly two, the certificate and the root, compared by thumbprint. A chain
  through any intermediate is refused, whatever its name constraints say, so the
  pin also covers the older intermediates. OpenBao's own TLS certificate is
  the one server certificate the root keeps signing for that reason
  (`lab.ps1 deploy vault`), and `Test-LabTlsPin` checks that a chain through
  the intermediate is refused for the pinned name.

The pin protects the PC, the side that sends the key shares and logins;
ansible-control and the browser trust the lab root and rely on the name
constraint. Enterprise equivalent: the secrets manager's certificate from a CA
of its own, which clients trust for that one service, so that no general
issuing CA can ever vouch for it.

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
run `.\lab.ps1 deploy vault` once: it adds the break-glass AppRole
`recovery`, and its `PENDING` line says what is still missing. After it,
`.\lab.ps1 deploy firewall` (or the next `.\lab.ps1 up`, which finds it due)
replaces the firewall's GUI certificate from the root with one from the
intermediate. Then these steps are yours, because they change your PC's trust
or show secrets. Run them in a PowerShell window of your own:

```powershell
.\lab.ps1 trust -RemoveRetired                                    # stop trusting the retired first lab CA
.\lab.ps1 recovery -Destination Z:\DeployableServer-recovery         # no kit yet: share C and the recovery file
.\lab.ps1 recovery -Renew -Destination Z:\DeployableServer-recovery  # kit made before: a new file with the break-glass login
```

Without `-Destination`, the recovery file goes to `keys\recovery`; copy it off
the PC yourself ([P45](#p45-a-script-that-shows-secrets-stops-before-it-shows-anything)).
A recovery file made before this version has no break-glass login (and no copy
of the firewall's `ansible` password and API key), so it could unseal OpenBao
but not give the PC its access back
([P46](#p46-after-losing-the-pcs-dpapi-keys-nothing-logs-in-to-openbao)).
(A lab from before OpenBao kept the Keycloak and Matrix secrets in plain files;
they were imported into OpenBao once. A lab built new never has them.)

After the move to SSH certificates, run `.\lab.ps1 recovery -Renew`
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
- **Backups of OpenBao**: raft snapshots (`lab.ps1 backup`), taken
  automatically after every deployment of Keycloak and Matrix and before the
  vault VM is deleted.
- **Break-glass recovery**: key share C on paper, a passphrase-encrypted
  recovery file with share B and a break-glass login, and
  `lab.ps1 recovery -Recover`, which gives the PC its access back after a
  lost Windows profile.
- **Renewals and an intermediate CA rollover**: `lab.ps1 up` renews what
  is due after every Windows restart (step 7), and `lab.ps1 deploy vault` makes a
  new intermediate 400 days before the current one expires (or with
  `-RotateIntermediate`); Keycloak, Traefik and the firewall's GUI move to it by
  themselves. Tried
  on 2026-10-24: the default issuer is now "DeployableServer Lab Intermediate
  CA 2026-10-24" (`lab-int-20261024`), and "DeployableServer Lab Intermediate
  CA 2026" (`lab-int-2026`) stays in OpenBao for its CRL.
- **Everything that runs is in the repository**: MDAD and its roles vendored
  in `vendor\mdad` (upgraded with `lab.ps1 mdad-upgrade`, never downloaded by a
  deployment), Ansible pinned to a version, and the checks used to verify the
  lab kept as scripts in `tests\` (`.\lab.ps1 test`; the nine tests that
  changed nothing at the time passed on 2026-10-24, before `Test-LabLayout`,
  `Test-LabAnsible` and `Test-LabOpenBaoConfig` were added).
- **One entry point, and the configuration in Ansible**: `.\lab.ps1` replaces
  the separate scripts. The PC keeps only what only the PC can do; the rest is
  an Ansible run on ansible-control with credentials for that run only
  (`config\run-profiles.json`): the base setup of the VMs (`base.yml`), the
  checks (`checks.yml`), OpenBao's configuration plane (`openbao-config.yml`,
  with a token that cannot hand out rights) and the firewall's GUI certificate,
  now from the intermediate (`firewall.yml`). The offline root signs only the
  intermediates, OpenBao's own certificate and a new firewall's first one.

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
  `lab.ps1 backup -Destination` copies one, by hand).
- **One SSH identity per automation**: MDAD (third-party code) in an account of
  its own on ansible-control, without sudo there and with its own key, so that
  the per-run SSH principals also hold when something persists on
  ansible-control (today every run shares the account `ansible`, see
  [SSH certificates](#ssh-certificates-user-and-host-cas), "What remains").
- **Single sign-on for OpenBao's web UI**: an OIDC login in OpenBao with
  Keycloak as the identity provider, and a personal administrator with MFA and
  a scoped policy, so that `pc-admin` is left to the scripts and `recovery` to
  emergencies. Until then, `lab.ps1 ui` hands out 1-hour tokens
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
  enterprises manage firewalls at scale. One change already runs from
  ansible-control, without the API: `firewall.yml` renews the GUI certificate
  over SSH, through OPNsense's own PHP configuration library.
- **Root CA rollover**: the intermediate already rotates itself; the root (10
  years) has no procedure yet: a new root next to the old one, trusted by
  Windows, the VMs and the containers' CA bundle, new intermediates below it,
  the certificates moved over, the old root retired, as was done once for the
  first lab CA.
- **Monitoring**: metrics (Keycloak already exposes them on its management
  port; Synapse, Traefik, LiveKit and OpenBao can too) collected by Prometheus
  and shown in Grafana, alerts for a sealed OpenBao, expiring certificates and
  CRLs (today only checked when `lab.ps1 up`, `status` or `maintain` runs), full disks and
  failed units; central logs, OpenBao's audit log among them.
- **Element X through an Android emulator**: the mobile app needs a device with
  a route into the lab, the lab's DNS names and trust in the lab root CA. An
  Android emulator running on the PC could provide all three (its traffic leaves
  through the PC; DNS and the CA have to be set up inside the emulator), which
  would make the MAS-based login and calls testable with Element X.
