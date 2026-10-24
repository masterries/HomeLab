# tests\ - checks of the running lab

Every check that was used to verify the lab is here as a script, so you can see exactly
what was tested and run it again. Run them from the project folder, in PowerShell; they
need a deployed lab (OpenBao, Keycloak, Matrix) unless noted. No test prints a secret.

```powershell
.\lab.ps1 test                                       # all tests that change nothing
.\lab.ps1 test -Name Test-LabCertificates            # one test
.\lab.ps1 test -IncludeStateChanging                 # also Test-LabRecoveryLogin.ps1 (asks first)
.\tests\Invoke-LabTests.ps1                          # the same runner without lab.ps1
.\tests\Test-LabCertificates.ps1                     # or one test directly
```

`.\lab.ps1 test` starts `tests\Invoke-LabTests.ps1` and ends with its exit code: 0 when every
test passed, 1 when one failed - so a script or a scheduled task can use it the way a CI
pipeline uses its test stage.

| Test | What it checks | Changes something? |
|---|---|---|
| `Test-LabLayout.ps1` | the repository and the `lab.ps1` dispatcher: `lab.ps1`'s command list and the command table in `scripts\lib\Lab.ps1` agree, and every command's script or function exists; PowerShell code only in `scripts\lib`, `commands`, `host` and `dev`; every run profile (`config\run-profiles.json`) names an existing playbook or script, valid SSH principals, existing OpenBao policies and a known token role; every playbook has a run profile (or is started by a script that has one) and every policy file is used; no code names a retired script or function, and README.md names them only in its rename table ([Where the old scripts went](../README.md#where-the-old-scripts-went)); every link in README.md, tests\README.md and vendor\README.md resolves; the dispatcher: help lists every command, an unknown command is refused (exit code 1), a command for your own window is refused with redirected output and `breakglass` without a command is refused (exit code 2), `run` without arguments lists the profiles | no, and it needs no lab (it reads files and starts `lab.ps1` in child processes) |
| `Test-LabAnsible.ps1` | the Ansible side, through run profiles on ansible-control: every playbook parses (profile `syntax`, `ansible-playbook --syntax-check`), `checks.yml` passes on every machine, and `base.yml --check` and `firewall.yml --check` report `changed=0` on every host - the VMs' base setup and the firewall's GUI certificate match the repository, so a change made by hand shows up here (drift detection) | no (read-only runs and `--check` runs) |
| `Test-LabCertificates.ps1` | every HTTPS endpoint: issued by the right CA (by key identifier: OpenBao's own certificate by the root; the firewall's GUI, Keycloak and the Matrix names by the current intermediate), valid for more than 30 days, trusted by Windows including the revocation check. A newly built firewall starts with a GUI certificate from the root and fails here until `lab.ps1 deploy firewall` (or the maintenance step of `lab.ps1 up`) has moved it to the intermediate | no |
| `Test-LabTlsPin.ps1` | the PC's OpenBao calls are pinned to the lab root (`LabTlsPin3` in `scripts\lib\LabSecrets.ps1`: only a certificate the root signed directly); other hosts keep Windows' validation; for the pinned host a foreign chain is refused, and so is a lab chain through OpenBao's intermediate (Keycloak's certificate, while keycloak is made the pinned host), which is accepted again once keycloak is not the pinned host - only the root itself may vouch for OpenBao | no (one HTTPS request to www.microsoft.com as the foreign chain) |
| `Test-LabPasswordHash.ps1` | the firewall's password hashing over stdin gives exactly the hash of the command-line form (dummy value, also with a BOM-writing console) | no, local only |
| `Test-LabRetiredDpapi.ps1` | DPAPI secrets in `keys\openbao-retired-*` can be read under their new names | no (a temporary copy, deleted again) |
| `Test-LabRunToken.ps1` | a run token: policies, at most 2 hours, bound to ansible-control, orphan, temp files on tmpfs, revoked and cleaned up after the run (profile `test-run-token`: `ansible\tests\run-token-check.sh` runs on ansible-control) | no |
| `Test-LabOpenBaoConfig.ps1` | OpenBao's configuration plane (`ansible/playbooks/openbao-config.yml`): its token (profile `test-config-token`, `ansible\tests\config-token-check.sh`) has exactly the policy `openbao-config`, lasts at most 30 minutes, is bound to ansible-control, an orphan and revoked after the run; it may configure the engines (mounts, KV settings, password policies, CRL, ACME, PKI roles) but not ACL policies, auth methods, AppRoles, token roles, the SSH CA, choosing or importing a CA, issuing or signing certificates, secrets, snapshots or audit devices (OpenBao is only asked, with `sys/capabilities-self`; nothing is tried); then `openbao-config.yml --check` must report `changed=0`, so nobody changed OpenBao's configuration by hand (in the web UI, say) since the last `lab.ps1 deploy vault` | no (two tokens of the role `ansible-config`, one per run, each revoked after its run; the playbook only in check mode) |
| `Test-LabSecretCreation.ps1` | creating a missing secret: generated by OpenBao, stored once, not stored under `--check`, read (not re-created) on the next run (profile `test-secret-creation`: `ansible\tests\secret-creation.yml`) | a throwaway secret `lab/keycloak/test-generated`, deleted again |
| `Test-LabFirewallRender.ps1` | the firewall's build path (secrets, a new firewall's first GUI certificate from the root, config.xml with the SSH CA lines for user ansible, seed ISO) into a temporary folder | the root signs one extra test certificate; the temporary folder is deleted |
| `Test-LabSshCa.ps1` | the SSH certificate code on the PC: offline signing (`ssh-keygen -P` on Windows OpenSSH), what a user and a host certificate contain (principals, extensions, source-address, lifetime, serial), principals that are refused (empty, wildcards, foreign names, root), the encrypted CA key, the revocation list, the rendered trust files and `keys\ssh_config` | no (two 6-minute certificates for a throwaway key; local only) |
| `Test-LabSshCertificates.ps1` | SSH in the running lab: strict logins everywhere, plain host keys refused (from the PC and from ansible-control), the PC certificate alone and an offline-CA certificate (break-glass) log in, a foreign CA is refused, a run certificate for `host-matrix` opens matrix only, a PC certificate does not work from ansible-control (source-address), a revoked host key is refused, sshd settings, no plain key logs in as ansible (no authorized_keys on the VMs, only cert-authority lines on the firewall); elevated also: KVP host keys and Vagrant's jump (`ansible\tests\ssh-cert-check.sh`, copied to `/tmp/lab-tests` and run on ansible-control) | no (throwaway keys and CAs, short-lived certificates, deleted again) |
| `Test-LabRecoveryLogin.ps1` | the break-glass login (AppRole `recovery`) and the issuing of new PC logins, as `lab.ps1 recovery -Recover` does | **yes**: new pc-admin/pc-deploy logins, and an existing recovery kit's break-glass login stops working (then `lab.ps1 recovery -Renew`); asks first; only with `-IncludeStateChanging` |

Files:

- `Invoke-LabTests.ps1` - the runner that `.\lab.ps1 test` starts: by default every test that
  changes nothing, each in a fresh PowerShell process, then a summary and the exit code
  (`-Name`, `-IncludeStateChanging`)
- `LabTest.ps1` - shared helpers (one PASS/FAIL line per check, a summary, the exit code;
  copying scripts of `ansible\tests` to `/tmp/lab-tests` on ansible-control for a test that runs
  them over a plain SSH session, and removing them again)
- `tools\Export-LabOpenBaoConfig.ps1` - not a test: writes OpenBao's configuration (no secret
  values) to a JSON file, read-only, so that you can compare the state before and after a change
  (for example with `git diff --no-index before.json after.json`)
- `ansible\tests\` (in the Ansible project, not here) - the scripts the tests run on
  ansible-control. Every run copies `ansible\` to `~/lab` on ansible-control, so the tests that
  need an OpenBao token start them through run profiles (`Invoke-LabRun`, the same as
  `lab.ps1 run`: `test-run-token`, `test-config-token`, `test-secret-creation`), and their token
  comes exactly the way a playbook's does; `Test-LabSshCertificates.ps1` copies
  `ssh-cert-check.sh` to `/tmp/lab-tests` for a plain SSH session instead.

The deployment scripts check themselves as well (for example `lab.ps1 deploy matrix`: ACME
certificates, MDAD's self-check, the login path to Keycloak; `lab.ps1 up` runs `checks.yml`);
these tests cover what the deployments do not.
