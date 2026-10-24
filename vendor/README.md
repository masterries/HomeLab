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
| Used by | `scripts\commands\deploy.ps1`: copies `vendor\mdad` to `~/mdad` on ansible-control on every run (the copy there is replaced, like `~/lab`), then `ansible\playbooks\matrix-prepare.yml` adds the lab's inventory and its entry point `lab-setup.yml` |
| Upgrade | `.\lab.ps1 mdad-upgrade -Commit <sha>`: `git subtree pull` for MDAD, then its roles at the new versions, two commits; then read MDAD's CHANGELOG.md and follow the steps the script prints |

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
