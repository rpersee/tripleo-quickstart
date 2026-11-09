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
automatically.

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
- **`-e @config/environments/custom_flavors_1ctlr_1comp.yml`** — RAM sizing
  for ~23 GiB hosts:
  - `undercloud_memory: 11264` (default would be 12288),
  - `control_memory: 8192`, `compute_memory: 3072` (defaults would be 8192
    each). Note the controller knob is **`control_memory`** — a
    `controller_memory` variable is silently ignored.
  - Extra-vars win over release/nodes config, so these stick.
- **no `-p`** — the default playbook is `quickstart-extras.yml`, the full
  flow. (`playbooks/quickstart.yml` alone would only provision the VMs and
  stop before installing the undercloud.)
- **`127.0.0.2`** — the virthost (positional argument, mandatory).

The flow, roughly in order: virthost setup (libvirt, networks) → image fetch
from `file:///var/lib/oooq-images` into
`/var/cache/tripleo-quickstart/images/zed/`, conversion of
`overcloud-full.qcow2` into `undercloud.qcow2`, injection of the overcloud +
IPA images into it → undercloud and overcloud VM creation (UEFI) → undercloud
install (packages from the Zed trunk repos, containers from
`quay.rdoproject.org/tripleozedcentos9`) → `openstack overcloud deploy` of
1 controller + 1 compute via the virtual BMCs → post-deploy validation.

Expect **several hours** on lab hardware; the deploy is resumable — re-running
the same command tears down and rebuilds the VMs and continues.

## 5. Verify and use

```bash
# as root on the host:
ssh -F /root/.quickstart/ssh.config.ansible undercloud
```

On the undercloud (as the `stack` user):

```bash
source ~/stackrc
openstack baremetal node list     # both nodes should be 'active'
openstack server list             # controller + compute instances

source ~/overcloudrc
openstack service list            # overcloud catalog
openstack compute service list
```

The overcloud endpoints are reachable from the undercloud VM; to reach them
from the host, the undercloud VM's IP is in the inventory
(`/root/.quickstart/undercloud` files) and works with the same ssh config
(`ssh -F /root/.quickstart/ssh.config.ansible undercloud ...`).

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
- **Undercloud install fails** — the full log is on the undercloud VM:
  `ssh -F /root/.quickstart/ssh.config.ansible undercloud`, then
  `/home/stack/.instack/install-undercloud.log` and
  `/var/log/containers/` for container-level issues.
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
