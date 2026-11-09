# AGENT.md — conventions for AI agents working in this repo

This is a checkout of the **retired** `tripleo-quickstart` project
(pinned at `dae1d7d7~1`) with local fixes on top, used to build TripleO
Zed overcloud images and deploy a small Zed-on-CentOS-9 cloud on a single
RHEL 9 lab host. The end-to-end runbook is `QUICKSTART.md` — keep it in
sync with reality when behavior changes.

## Branching and commits

- Work on the current feature branch (e.g. `build-images`). One fix per
  commit, **Angular commit convention**
  (`feat|fix|docs|chore(scope): summary`), with a body that explains the
  WHY: root cause, mechanism, and why this layer. The bodies are the
  session memory — future debugging depends on them (see `git log`).
- Commit fixes as they surface, not in a batch at the end.

## The workdir is a copy — sync it

Executing content lives in `/root/.quickstart` (the "workdir"), NOT in
this checkout:

- Roles/playbooks/config from **this checkout** are installed into the
  workdir at bootstrap (`setup.py install egg_info`, `--no-clone` sets
  `OOOQ_DIR` to this checkout). After committing changes to
  `roles/`, `playbooks/` or `config/`, either re-bootstrap
  (`./quickstart.sh --clean`) or copy the changed files into the workdir
  (`usr/local/share/tripleo-quickstart/roles/`, `playbooks/`,
  `config/`) before re-running.
- tripleo-quickstart-extras / tripleo-ci roles are **pip-pinned**
  (`quickstart-extras-requirements.txt`, tqe @ `4eec311`, tripleo-ci @
  `a45099a`) under `usr/local/share/ansible/roles/`. Do not edit them as
  a fix — instead:
  1. prefer a config-layer override in the release or environment file
     (last `-e @file` wins over `config/environments/default_libvirt.yml`
     which quickstart.sh always appends),
  2. or apply an idempotent patch from our scripts after bootstrap —
     see the `libselinux-python3` sed in `ci-scripts/build-images-cs9.sh`.
- Read-only reference checkouts of the pins are kept under
  `/tmp/opencode/tripleo-quickstart-extras` and `/tmp/opencode/tripleo-ci`
  for grepping/diffing.

## Commands

- Always run quickstart from the repo root as root (relative
  `-e @...` / `--nodes` paths and cwd-relative `roles_path` matter).
- `-y` means `--dry-run` (list tasks) in quickstart.sh — not "yes".
- Deploy command template (1ctlr_1comp Zed lab):

  ```bash
  ./quickstart.sh -R centosci/CentOS-9/zed-current-tripleo --no-clone \
    --tags all --nodes config/nodes/1ctlr_1comp.yml \
    -e @config/environments/custom_flavors_1ctlr_1comp.yml 127.0.0.2
  ```

- Image builds: `RELEASE=centosci/CentOS-9/zed-current-tripleo bash
  ci-scripts/build-images-cs9.sh` → artifacts + md5s in
  `/var/lib/oooq-images/`.

## Debugging playbook

- Filter deploy-log noise: `grep 'FAILED!' LOG | grep -vE
  'pool-uuid|vol-info|vol-delete|domid|pgrep|test -f|virthost_provisioning_interface'`
  (these are existence probes that upstream ignores).
- Undercloud failures: ssh via
  `ssh -F /root/.quickstart/ssh.config.ansible undercloud`; logs
  `/home/stack/undercloud_install.log`, `/home/stack/install-undercloud.log`;
  the deploy-steps task detail is inside
  `/home/stack/tripleo-deploy/undercloud/undercloud-install-*.tar.bzip2`
  (member `undercloud-ansible-*/stdout`; `ansible.log` in there is empty).
- The jsonfile fact cache (`/root/.quickstart/ansible_facts_cache`) has
  `fact_caching_timeout = 0` (never expires) — stale facts from failed
  runs leak into the next run; the tripleo-inventory role here is already
  hardened for the known case, but keep it in mind for new "works on
  first run, fails on re-run" bugs.
- Era-mismatch is THE recurring failure class: frozen 2023 Zed trunk vs
  moving 2026 host/distro/SIG content. When a package/DNS/repo issue
  appears, suspect "moving repo content vs frozen pins" first; fix at the
  narrowest layer (release config → env file → our role → idempotent
  tqe patch).

## House style

- Runbooks in `QUICKSTART.md` must match observed behavior; when a
  command or path in the guide turns out wrong, fix it in the same
  session.
- Don't inflate VM RAM knobs (host has ~23 GiB total, deployment is
  intentionally tight via `config/environments/custom_flavors_1ctlr_1comp.yml`).
