# Quickstart: TripleO Zed on CentOS 9 from a single lab host

Step-by-step guide for building the TripleO overcloud images and deploying a
small (1 controller + 1 compute) Zed cloud on **CentOS 9** guests, driven
entirely from this `tripleo-quickstart` checkout on a single **RHEL 9** host.

Upstream is retired and several of its hosts are gone, so this guide uses the
pinned, locally working wiring only:

| Dependency | Source | Status |
|---|---|---|
| overcloud / IPA images | **built locally** into `/var/lib/oooq-images` | produced by this guide |
| Zed delorean trunk repos | `https://trunk.rdoproject.org/centos9-zed` (frozen `current-tripleo`) | alive |
| CentOS 9 Stream repos | `http://mirror.stream.centos.org/9-stream/...` | alive |
| Zed container images | `quay.rdoproject.org/tripleozedcentos9:<current-tripleo>` | alive |
| images.rdoproject.org | former image host | **dead, not used** |

The resulting deployment is: one undercloud VM (11 GiB RAM) and two overcloud
VMs — controller (8 GiB) and compute (3 GiB) — created as libvirt guests on
the host itself, with the overcloud deployed through the undercloud via
virtual BMCs, the classic `tripleo-quickstart` way.

For the image build internals see
[doc/source/building-images-cs9.rst](doc/source/building-images-cs9.rst);
this document is the end-to-end runbook.

---

## 1. Requirements

- **Host**: RHEL 9.x, all commands as **root**.
- **Resources**: ~23 GiB RAM and ~60 GiB free disk are enough for the sizes
  used here (a full master-sized build needs more; the build alone peaks
  around 30 GiB of disk).
- **Network**: direct HTTPS to `trunk.rdoproject.org`, `mirror.stream.centos.org`,
  `quay.rdoproject.org` and `cloud.centos.org` (base disk image for the build).
- **RHEL subscription** active on the host (the virthost setup installs
  libvirt/virt-install packages from the RHEL repos).
- **Passwordless ssh to 127.0.0.2 as root** (see next section).

### One-time host prep: loopback ssh to 127.0.0.2

`quickstart.sh` refuses `localhost`/`127.0.0.1` as the virthost and instead
connects over ssh to `127.0.0.2` (the usual standalone pattern). Prepare it:

```bash
ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa   # skip if you already have a key
ssh-copy-id root@127.0.0.2
ssh root@127.0.0.2 true && echo "virthost ssh OK"
```

All the commands below are run **from this checkout**
(`/opt/tripleo-quickstart`) as root, so relative `-e @...` and `--nodes`
paths resolve correctly.

## 2. Bootstrap quickstart (one time)

```bash
./quickstart.sh --install-deps
```

This creates the working directory `/root/.quickstart` with:

- a Python virtualenv (ansible-core 2.11.12) in `/root/.quickstart/bin/`,
- the pinned `tripleo-quickstart`, `tripleo-quickstart-extras` and
  `tripleo-ci` content (playbooks, roles, release configs) this checkout
  references,
- the roles installed under
  `/root/.quickstart/usr/local/share/ansible/roles/`.

Subsequent runs reuse it; the build script keeps the pieces it needs in sync
automatically. Note the workdir holds a **copy** of this checkout's roles,
playbooks and configs (installed at bootstrap): after updating this
checkout, re-run `./quickstart.sh --clean` (or `--install-deps` +
bootstrap) so the workdir picks the changes up. The build script's
tqe-role patches are re-applied automatically on every build run.

## 3. Build the Zed images

```bash
RELEASE=centosci/CentOS-9/zed-current-tripleo bash ci-scripts/build-images-cs9.sh
```

What this does:

1. Bootstraps the workdir if needed (first run only).
2. Syncs `playbooks/build-images.yml`, `config/general_config/build_images.yml`
   and the release config into the workdir.
3. Installs the **Zed** delorean trunk repos (`centos9-zed`) on the host —
   the release to populate the image with is derived from the `RELEASE`
   config name (`zed-current-tripleo` → `RDO_RELEASE=zed`), and the repos are
   re-fetched whenever they don't match, so switching releases re-populates
   them. On RHEL it also applies the two RHEL-specific workarounds
   (`containers-common` replacefiles, explicit image/DIB extra-vars).
4. Runs the `build-images.yml` playbook, which executes the repo-setup role
   and the tripleo-ci `oooci-build-images` role on the virthost — the same
   logic as the retired `tripleo-buildimage-*-centos-9` Zuul jobs: DIB builds
   `overcloud-full` (partition image: qcow2 + initrd + vmlinuz) and
   `ironic-python-agent`, then packs them into tarballs with md5sums.

Expect **1.5–3 hours** (dominated by the two DIB runs). The artifacts land in
`/var/lib/oooq-images/`:

```bash
ls -l /var/lib/oooq-images/*.tar*
md5sum -c /var/lib/oooq-images/overcloud-full.tar.md5
md5sum -c /var/lib/oooq-images/ironic-python-agent.tar.md5
tar -tf /var/lib/oooq-images/overcloud-full.tar        # qcow2 + initrd + vmlinuz
tar -tf /var/lib/oooq-images/ironic-python-agent.tar   # initramfs + kernel
```

Notes:

- Re-running the script rebuilds from scratch in place (the role wipes
  `/var/lib/oooq-images` first). Keeping the artifacts untouched and only
  re-deploying is fine too — nothing in the deploy step modifies them.
- Without `RELEASE=...` the script still defaults to the
  `centosci/CentOS-9/master-current-tripleo` (master trunk) build.

## 4. Deploy the 1ctlr_1comp Zed cloud

```bash
./quickstart.sh \
    -R centosci/CentOS-9/zed-current-tripleo \
    --no-clone \
    --tags all \
    --nodes config/nodes/1ctlr_1comp.yml \
    -e @config/environments/custom_flavors_1ctlr_1comp.yml \
    127.0.0.2
```

Piece by piece:

- **`-R centosci/CentOS-9/zed-current-tripleo`** — the release config
  (`config/release/centosci/CentOS-9/zed-current-tripleo.yml`). It points the
  `images:` list at the **local** `file:///var/lib/oooq-images/` tarballs
  built in step 3 (the fetch-images role downloads with `curl`, which
  understands `file://`), uses the Zed delorean repos, and pulls Zed
  containers from `quay.rdoproject.org/tripleozedcentos9`.
- **`--nodes config/nodes/1ctlr_1comp.yml`** — the node layout: 1 controller
  VM on flavor `control`, 1 compute VM on flavor `compute`.
- **`-e @config/environments/custom_flavors_1ctlr_1comp.yml`** — environment
  overrides for the lab:
  - RAM sizing for ~23 GiB hosts: `undercloud_memory: 10240` (default would
    be 12288), `control_memory: 8192`, `compute_memory: 4096` (default
    would be 8192). Note the controller knob is **`control_memory`** —
    a `controller_memory` variable is silently ignored. Compute must stay
    ≥ 4096: the ironic agent handles the ~1.4 GiB qcow2 in the node's
    RAM-backed initramfs, which 3072 MiB cannot fit (deploy fails with
    "No usable temporary directory found").
  - Undercloud DNS: `nameserver_from_virthost: false` plus an explicit
    `undercloud_undercloud_nameservers` read from the host's
    `/etc/resolv.conf` (IPv4 **and** IPv6). The pinned
    tripleo-quickstart-extras derives them with an IPv4-only awk that
    mangles IPv6 nameservers on a dual-stack host, and the mangled entry
    aborts the undercloud install (`netaddr.AddrFormatError` creating the
    `ctlplane-subnet`).
  - Extra-vars win over release/nodes config (this file is passed last), so
    these stick.
- **no `-p`** — the default playbook is `quickstart-extras-compat.yml`, the
  full flow plus one tq-layer THT compatibility play (see troubleshooting:
  the frozen zed THT trips over the 2026 host's rsync). It imports the same
  chain as the pinned `quickstart-extras.yml`
  (provision → undercloud → overcloud-prep → overcloud → validate) with
  `quickstart-extras-compat-tht.yml` inserted between the undercloud install
  and the overcloud prep — the only window where a THT patch takes effect
  (THT is installed by the undercloud install, not baked into the images,
  and `openstack overcloud deploy` regenerates config-download from it).
  Pass `-p quickstart-extras.yml` explicitly for the pristine pinned chain.
- **`127.0.0.2`** — the virthost (positional argument, mandatory).

The flow, roughly in order: virthost setup (libvirt, networks) → image fetch
from `file:///var/lib/oooq-images` into
`/var/cache/tripleo-quickstart/images/zed/`, conversion of
`overcloud-full.qcow2` into `undercloud.qcow2`, injection of the overcloud +
IPA images into it → undercloud and overcloud VM creation (UEFI) → undercloud
install (packages from the Zed trunk repos, containers from
`quay.rdoproject.org/tripleozedcentos9`; the release config passes
`--no-validations` — the pre-install validations run ansible against the
undercloud itself before its stack-user ssh keys exist) → `openstack
overcloud deploy` of 1 controller + 1 compute via the virtual BMCs →
post-deploy validation.

Expect **several hours** on lab hardware; the deploy is resumable — re-running
the same command tears down and rebuilds the VMs and continues.

## 5. Verify and use

### List the VMs and get a serial console

The lab VMs run in **stack's libvirt *session* instance**, not the system one
(`sudo virsh` shows nothing — that is expected):

```bash
# as root on the host:
sudo -u stack env XDG_RUNTIME_DIR=/run/user/$(id -u stack) virsh list --all
#  1  undercloud   running
#  8  control_0    running
#  9  compute_0    running

sudo -u stack env XDG_RUNTIME_DIR=/run/user/$(id -u stack) virsh console undercloud
# exit the console with Ctrl-]
```

### ssh to the VMs

The aliases live in `/root/.quickstart/ssh.config.ansible` (keys are
`id_rsa_undercloud` / `id_rsa_overcloud` in the same directory):

```bash
ssh -F /root/.quickstart/ssh.config.ansible undercloud                # user stack
ssh -F /root/.quickstart/ssh.config.ansible overcloud-controller-0    # user tripleo-admin
ssh -F /root/.quickstart/ssh.config.ansible overcloud-compute-0       # (ProxyJump via undercloud)
```

### OpenStack CLI (on the undercloud, as `stack`)

```bash
source ~/stackrc                 # the *undercloud* cloud (ironic, introspection)
openstack baremetal node list    # both nodes should be 'active'
openstack server list            # controller + compute instances

source ~/overcloudrc             # the *overcloud* cloud you just deployed
openstack service list           # overcloud catalog
openstack compute service list   # NOTE: 'hypervisor stats show' is gone in Zed (API 2.88)
```

Overcloud endpoints (from `openstack endpoint list`): admin
`http://172.16.2.128:35357`, internal `http://172.16.2.128:5000`, public
`https://10.0.0.5:13000` (TLS with the undercloud-provided self-signed CA).
They are reachable from the undercloud VM; from the host, ssh to the
undercloud first and work from there.

## 6. Re-runs and teardown

| Action | Command |
|---|---|
| Re-deploy from scratch (keeps images) | re-run the step 4 command |
| Tear down VMs and networks, keep workdir | add `-T all` to the step 4 command |
| Tear down and re-provision just the VMs | `-T nodes` |
| Discard the quickstart workdir (venv + installed configs) | `./quickstart.sh --clean` (next run re-bootstraps) |
| Rebuild images | re-run the step 3 command |

The Zed trunk repos are frozen (`current-tripleo` hash labels stopped moving
when the branch was archived), so image rebuilds are reproducible.

## 7. Troubleshooting

- **`ssh root@127.0.0.2` fails** — quickstart cannot reach the virthost; redo
  the host prep in section 1.
- **Build fails with a `containers-common` file-conflict on RHEL** — the
  script pre-installs it with `rpm --replacefiles`; if it was already pulled
  in broken, `rpm -e --nodeps containers-common` and re-run the build script.
- **Build fails on `libselinux-python3`** — the script patches the installed
  role copy; if you wiped the workdir, re-run the build script (it re-applies
  the patch after bootstrap).
- **Deploy fails in fetch-images** — check that
  `/var/lib/oooq-images/{overcloud-full,ironic-python-agent}.tar` and their
  `.md5` files exist and pass `md5sum -c`; the fetch cache lives in
  `/var/cache/tripleo-quickstart/images/zed/` and can be wiped freely.
- **Undercloud install fails** — logs are on the undercloud VM:
  `ssh -F /root/.quickstart/ssh.config.ansible undercloud`, then
  `/home/stack/undercloud_install.log` (orchestrator) and
  `/home/stack/install-undercloud.log` (deploy). For a failure inside the
  deploy-steps ansible run, extract the config-download bundle
  `/home/stack/tripleo-deploy/undercloud/undercloud-install-*.tar.bzip2`
  and read `undercloud-ansible-*/stdout` — it holds the per-task output and
  the `PLAY RECAP`. `/var/log/containers/` covers container-level issues.
- **Deploy crashes early with `hostvars['undercloud'] is undefined`** — a
  stale ansible fact cache (`/root/.quickstart/ansible_facts_cache`, which
  never expires) left by a previous run; fixed in this checkout's
  `tripleo-inventory` role. If you wiped the workdir, re-run the bootstrap
  so the fixed role is re-installed from this checkout.
- **Introspection times out (both nodes `inspect failed`, never call back)** —
  the IPA initramfs repack workspace (`mktemp -d`) defaults to mode `0700`,
  leaving the initramfs root `/` as `0700`; non-root services such as D-Bus
  (used by NetworkManager) cannot traverse `/`, so NetworkManager never
  brings up the NICs and the agent waits forever for DHCP. Fixed in this
  checkout's `convert-image` role (`ipa_ramdisk_fix.sh.j2`: add `chmod 0755
  "$WORK"` after cpio extraction; commit `df87353f`). If you wiped the
  workdir, re-run the bootstrap so the fixed role is re-installed.
- **Overcloud deploy fails at config-download step 2 with `duplicate
  constraint already exists, use --force to override. Too many tries`** —
  pcs 0.11.12 (2026 host distro) changed `pcs constraint` output: location
  constraints lost their printed IDs (breaking `pcmk_bundle`/`pcmk_resource`
  probes) and colocations print `resource 'X' with resource 'Y'` instead of
  `X with Y` (breaking the `pcmk_constraint` probe). Frozen puppet-pacemaker
  1.5.1 then re-creates existing constraints and pcs rejects the
  duplicates. Fixed in this checkout's `convert-image` role
  (`pacemaker_probe_fix.sh.j2`: rewrite all three providers' probes;
  commits `2ac600ed`, `db15e565`). If you wiped the workdir, re-run the
  bootstrap so the fixed role is re-installed.
- **Overcloud deploy fails at deploy step 1 with `Failed containers:` listing
  most `container-puppet-*` (and later `rabbitmq_wait_bundle` exit 6)** —
  rsync >= 3.2.3 (2026 host distro) rejects `--files-from` entries that
  match an `--exclude` pattern (`rejecting excluded file-list name`,
  protocol incompatibility, rc 2). The frozen zed THT script
  `common/container-puppet.sh` gathers "files modified during the puppet
  run" with a find that only filters `/etc/puppet*`, but its rsync
  excludes (built from `$ro_files`) also cover `/opt/puppetlabs` (the
  shared facter-cache bind mount), `/etc/pki/...`, `/etc/openldap`,
  `/etc/hosts`, ... — any file modified under those during a
  container-puppet run aborts the whole config generation, so most
  service configs never materialize. Fixed in this checkout's
  `playbooks/quickstart-extras-compat-tht.yml` +
  `files/patch_container_puppet_rsync.py` (derives the find filters from
  the same `$ro_files` list; runs against the undercloud THT between the
  undercloud install and the overcloud deploy via the new default
  playbook chain `quickstart-extras-compat.yml`). If you wiped the
  workdir, re-run the bootstrap so the new playbooks are installed, or
  `cp -f playbooks/quickstart-extras-compat*.yml` and
  `playbooks/files/patch_container_puppet_rsync.py` into
  `$OPT_WORKDIR/playbooks/` yourself.
- **Resuming a failed config-download run manually** — use
  `/home/stack/overcloud-deploy/overcloud/config-download/ansible-playbook-command.sh
  --start-at-task 'Set legacy facts'`. Starting later (e.g. at a step 2
  task) skips the fact-gathering plays and dies in `first_found` with
  "No file was found"; task-name needles must match the UNRENDERED Jinja
  form (`--start-at-task 'Run init bundle puppet on the host for
  {{ tripleo_ha_wrapper_service_name }}'`), not the rendered name from
  the logs — otherwise every task is silently skipped (rc=10).
- **Collect a full log bundle**: run the step 4 command with
  `-p collect-logs.yml`; artifacts are placed in the current directory.

## 8. Pinned upstream state

This checkout pins the retired upstream projects it borrows logic from:

- tripleo-quickstart @ `dae1d7d7~1`, tripleo-quickstart-extras @ `4eec311`,
  tripleo-ci @ `a45099a` (installed into the workdir at bootstrap).
- The Zed delorean trunk (`centos9-zed`) was frozen in September 2023;
  `current-tripleo` there is a stable, immutable hash label.
- Image build method: `ci-scripts/build-images-cs9.sh` →
  `config/general_config/build_images.yml` → tripleo-extras
  `build-images` + tripleo-ci `oooci-build-images` roles
  (see `doc/source/building-images-cs9.rst`).
