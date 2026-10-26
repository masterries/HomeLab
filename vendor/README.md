# vendor\ - third-party code that runs in the lab, kept in this repository

Everything the lab executes is in this repository, so you can read exactly what runs
and nothing is fetched from the internet behind your back at deployment time. Code
the lab did not write itself lives here, unchanged, at one pinned version
("vendoring").

## vendor\mdad - matrix-docker-ansible-deploy (MDAD)

| | |
|---|---|
| What | The Ansible playbook that installs and wires the Matrix stack (Synapse, MAS, Element Web, LiveKit, Traefik, PostgreSQL, ...) |
| Upstream | <https://github.com/spantaleev/matrix-docker-ansible-deploy> |
| Version | commit `a52e9876526aa6dcd41075b3a83d5eea7c31887b` (also in `mdad\.lab-vendored-commit`), [browse it](https://github.com/spantaleev/matrix-docker-ansible-deploy/tree/a52e9876526aa6dcd41075b3a83d5eea7c31887b) |
| How | a **git subtree**: MDAD's files are ordinary files of this repository, and the subtree commits (`git log -- vendor/mdad`; their messages carry `git-subtree-split: <upstream commit>`) record which upstream commit they came from. "--squash": one commit per update instead of MDAD's whole history |
| Roles | MDAD's 32 external roles in `mdad\roles\galaxy\` are not in MDAD's repository: its `requirements.yml` pins them (most by Git tag, a few by commit). They were installed with `ansible-galaxy install -r requirements.yml` (what MDAD's `just roles` does) and committed with `git add -f`, because MDAD's own `.gitignore` ignores that folder. `ansible-galaxy` adds a small `meta\.galaxy_install_info` to each role (install date and version) |
| Licence | AGPL-3.0-or-later, see `mdad\LICENSE` and `mdad\LICENSES\` (some files MIT or CC0, marked in `.license` files) |
| Changed | nothing in MDAD's files. Not used here: MDAD's `inventory\` (the lab's own configuration lives in `ansible\matrix\`; `matrix-prepare.yml` adds it to the copy on ansible-control). Symbolic links (only in MDAD's molecule test folders) are checked out on Windows as small text files that name their target; nothing in a deployment reads them |
| Used by | `.\lab.ps1 deploy matrix` (`scripts\commands\deploy.ps1`, which first checks that `mdad\.lab-vendored-commit` and `mdad_version` in `ansible\playbooks\matrix-prepare.yml` name the same commit). Its first run is the run profile `matrix-prepare` (`config\run-profiles.json`), which has `syncMdad`: `scripts\lib\LabRun.ps1` packs `vendor\mdad` into an archive of its own for that run, and `ansible\bin\lab-run` replaces `~/mdad` on ansible-control with it (like `~/lab`: nothing of an earlier copy survives). Then `matrix-prepare.yml` checks the pinned commit and adds the lab's inventory and its entry point `lab-setup.yml`; the profile `matrix` (or `matrix-setup` with `-Setup`) runs MDAD in `~/mdad` through `ansible\bin\deploy-matrix` |
| Upgrade | `.\lab.ps1 mdad-upgrade -Commit <sha>`: `git subtree pull` for MDAD, then its roles at the new versions, two commits; then read MDAD's CHANGELOG.md and follow the steps the script prints |

## vendor\rancher - the Rancher Manager Helm chart

| | |
|---|---|
| What | The Helm chart that installs Rancher Manager (SUSE's web UI and API for Kubernetes) on the lab's cluster: Kubernetes manifest templates (`chart\templates\`), default values (`chart\values.yaml`), the hook scripts (`chart\scripts\`) |
| Upstream | the community Helm repository <https://releases.rancher.com/server-charts/stable>, file `rancher-<version>.tgz`; source <https://github.com/rancher/rancher/tree/v2.15.2/chart> |
| Version | 2.15.2 (Rancher v2.15.2). `rancher\.lab-vendored-version` names it with the SHA-256 of the downloaded `.tgz`, `855cb9be954f65a31b9a8c77f7aebce125c2d7797425257d21d35e3380816ac8`, the `digest` of that version in the repository's `index.yaml`. Rancher publishes no signature (no `.prov` file), so this hash is the trust anchor |
| How | `rancher\chart\` is the unpacked archive (its folder `rancher`), unchanged. No Git history to link: the archive is the release |
| Licence | Rancher is Apache-2.0 (<https://github.com/rancher/rancher/blob/v2.15.2/LICENSE>). The chart's own README opens with a notice that installing it means accepting SUSE's End User License Agreement (<https://www.suse.com/licensing/eula/>) |
| Changed | nothing |
| Used by | `.\lab.ps1 deploy k8s`: the run profiles `k8s` and `k8s-rancher` list it under `vendor` (`config\run-profiles.json`), so `scripts\lib\LabRun.ps1` copies it to `~/lab/vendor/rancher` for that run. `ansible\kubernetes\rancher.yml` checks that `.lab-vendored-version` names `rancher_chart_version` (`ansible\kubernetes\vars\kubernetes.yml`), packs `chart\` reproducibly into a `.tgz` and hands it to RKE2's Helm controller inside a HelmChart object (`chartContent`): no Helm repository is contacted at deployment time |
| Upgrade | `.\lab.ps1 rancher-upgrade -Version <v> -Sha256 <hash>` (`scripts\dev\Update-LabRancherChart.ps1`): downloads the `.tgz`, refuses it unless its SHA-256 matches, replaces `rancher\chart` and the marker. Then check the chart's `kubeVersion` against RKE2's version, set `rancher_chart_version`, commit, `.\lab.ps1 deploy k8s` |

## fleet\ - vendored sources that Fleet deploys

Two third-party sources live outside this folder, under `fleet\`: Fleet (Rancher's GitOps
controller, [GitOps with Fleet](../README.md#gitops-with-fleet-apache-airflow-on-the-cluster))
deploys from this repository on GitHub and reads only the files inside a bundle's own folder, so a
chart or a manifest must sit next to its `fleet.yaml`. They follow the same rules as everything
here: unchanged, one pinned version, a `.lab-vendored-version` marker with the hash, one script that
takes a new version.

### fleet\airflow\chart - the Apache Airflow Helm chart

| | |
|---|---|
| What | The official Helm chart of Apache Airflow: api-server, scheduler, dag-processor, triggerer, Celery workers, and as subcharts Bitnami's PostgreSQL (`chart\charts\postgresql`) and Redis as a plain StatefulSet |
| Upstream | <https://downloads.apache.org/airflow/helm-chart/1.22.0/airflow-1.22.0.tgz> (index: <https://airflow.apache.org/index.yaml>); source <https://github.com/apache/airflow/tree/helm-chart/1.22.0/chart> |
| Version | chart 1.22.0 (Airflow 3.2.2). `airflow\.lab-vendored-version` names it with the SHA-256 of the `.tgz`, `1f7d1dfe3d58e2c54899950aba907a43625a18c8b6fb3c54760c21592129a5b6`. Apache signs every release: the `.tgz` matches its published `airflow-1.22.0.tgz.sha512`, and `airflow-1.22.0.tgz.asc` verifies with the release managers' keys in <https://downloads.apache.org/airflow/KEYS> (`gpg --import KEYS`, `gpg --verify airflow-1.22.0.tgz.asc airflow-1.22.0.tgz`). Checked when it was vendored: a good signature by Jarek Potiuk (Apache), primary key `8BA8 D21B B4A2 350A 4368 0A74 6618 7A61 A0A7 E894` |
| How | `airflow\chart\` is the unpacked archive (its folder `airflow`), unchanged, including the subchart in `chart\charts\` (so `fleet.yaml` sets `disableDependencyUpdate`: nothing is fetched) |
| Licence | Apache-2.0 (`airflow\chart\LICENSE`); the PostgreSQL subchart is Apache-2.0 as well (Bitnami) |
| Changed | nothing. The lab's settings are the `values` in `fleet\airflow\fleet.yaml` |
| Used by | Fleet, from GitHub (bundle `fleet/airflow`, the GitRepo of `ansible\kubernetes\fleet.yml`); `.\lab.ps1 deploy fleet` creates the secrets the values name |
| Upgrade | `.\lab.ps1 fleet-upgrade -Component airflow -Version <v> -Sha256 <hash>` (`scripts\dev\Update-LabFleetSource.ps1`; the hash is the version's `digest` in `index.yaml`): downloads, refuses unless the SHA-256 matches, replaces `airflow\chart` and the marker. Then compare `fleet.yaml`'s values with the new `chart\values.yaml` and the chart's release notes, commit, `git push` |

### fleet\local-path\local-path-storage.yaml - Rancher's local-path-provisioner

| | |
|---|---|
| What | A small provisioner that answers a volume claim with a directory on the node the pod runs on (`/opt/local-path-provisioner`): the StorageClass `local-path`, its Deployment, RBAC and configuration |
| Upstream | <https://github.com/rancher/local-path-provisioner/blob/v0.0.37/deploy/local-path-storage.yaml> |
| Version | v0.0.37. `local-path\.lab-vendored-version` names it with the SHA-256 of the file, `9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65` (the release has no signed assets: the tag in Git is the anchor) |
| How | the manifest as the tag has it, unchanged |
| Licence | Apache-2.0 (<https://github.com/rancher/local-path-provisioner/blob/v0.0.37/LICENSE>) |
| Changed | nothing in the file. `local-path\kustomization.yaml` patches it at deployment: no Namespace of its own (Fleet creates `local-path-storage`), the StorageClass as the cluster's default, the provisioner's image and the helper image (busybox) pinned by digest |
| Used by | Fleet, from GitHub (bundle `fleet/local-path`; Airflow's bundle depends on it) |
| Upgrade | `.\lab.ps1 fleet-upgrade -Component local-path -Version <tag> -Sha256 <hash>`: then put the new image's digest into `kustomization.yaml`, commit, `git push` |

Why vendored and not cloned at deployment time:

- **Transparency**: the code that runs is the code you can read here.
- **Reproducibility**: every deployment uses exactly the same files, even if GitHub,
  a role's repository or a tag disappears or changes.
- **Review**: an upgrade is a commit of this folder, which you can compare with the
  previous version file by file (`git show --stat`, `git diff HEAD~2 -- vendor/mdad`).
- **Still linked to the source**: the subtree keeps the upstream address and commit, so
  pulling the next version is one command, not a manual copy.

Enterprise equivalent: an internal mirror or artifact repository (Git mirror, Artifactory,
Nexus, Ansible Automation Hub) with reviewed, pinned versions; production never pulls
straight from the internet.
