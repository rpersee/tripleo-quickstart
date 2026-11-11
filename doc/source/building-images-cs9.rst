===============================================
Building the overcloud images on CentOS Stream 9
===============================================

This how-to reproduces, on a single CentOS Stream 9 host, the image build
performed by the (now decommissioned) RDO/TripleO CI to produce the
published artifacts:

- ``overcloud-full.tar`` + ``overcloud-full.tar.md5``
- ``ironic-python-agent.tar`` + ``ironic-python-agent.tar.md5``

The tarballs contain the qcow2 plus the deployment kernel/initrd::

    $ tar tf overcloud-full.tar
    overcloud-full.qcow2
    overcloud-full.initrd
    overcloud-full.vmlinuz

    $ tar tf ironic-python-agent.tar
    ironic-python-agent.initramfs
    ironic-python-agent.kernel

Which logic is followed
=======================

The last published images were built by the ``tripleo-buildimage-*-centos-9``
zuul jobs in the ``tripleo-ci`` repo.  Their chain is:

1. ``tripleo-build-jobs-repos`` — installs ``tripleo-repos`` (which provides
   the ``tripleo-get-hash`` binary) and runs the ``repo-setup`` role from this
   repo, rendering and executing ``repo_setup.sh`` from the release file
   (delorean + quickstart-centos repos on the build host).
2. ``oooci-build-images`` (``pre``) — creates a virtualenv and pip-installs
   ``diskimage-builder``, ``tripleo-common``, ``tripleo-ansible`` and
   ``python-tripleoclient`` from source, pinned by
   ``requirements/upper-constraints.txt``.
3. ``oooci-build-images`` (``main``) — downloads a CentOS Stream 9
   GenericCloud qcow2, installs ``python3-tripleoclient`` (rpm), renders
   ``build_images.sh`` and runs
   ``openstack overcloud image build`` with:

   - ``--config-file .../image-yaml/overcloud-images-python3.yaml``
   - ``--config-file .../image-yaml/overcloud-images-centos9.yaml``
   - ``DIB_LOCAL_IMAGE`` (the downloaded qcow2), ``NODE_DIST=centos``,
     ``DIB_RELEASE=9-stream``, ``DIB_YUM_REPO_CONF`` (the delorean +
     quickstart repos) and ``DIB_DNF_MODULE_STREAMS=""``.
4. Packaging — archives ``overcloud-full.qcow2/initrd/vmlinuz`` into
   ``overcloud-full.tar`` and ``ironic-python-agent.initramfs/kernel`` into
   ``ironic-python-agent.tar``, each with an ``md5sum`` file.

The ``build-images`` role of ``tripleo-quickstart-extras`` drives exactly the
steps 3-4 (in "direct" mode) through this repo's
``playbooks/build-images.yml`` playbook; the playbook used to reference a
stale ``image-build`` role name and has been fixed to ``build-images``.

One command
===========

On the CentOS Stream 9 host, as root::

    bash ci-scripts/build-images-cs9.sh

Artifacts end up in ``/var/lib/oooq-images``.  Re-running the script rebuilds
from scratch (the working directory is wiped each run).

Behind the scenes
=================

The script performs the following steps, which can also be done manually:

1. Bootstrap quickstart (first run only) — creates ``~/.quickstart``, installs
   the pinned dependencies and roles::

       ./quickstart.sh --install-deps
       ./quickstart.sh -R centosci/CentOS-9/master-current-tripleo --no-clone -y 127.0.0.2

2. Sync the fixed playbook/config into ``~/.quickstart`` (quickstart always
   runs the *installed* copies)::

       cp -f playbooks/build-images.yml ~/.quickstart/playbooks/
       cp -f config/general_config/build_images.yml ~/.quickstart/config/general_config/

3. Apply the el9 fixups:

   - the pinned ``oooci-build-images`` role installs ``libselinux-python3``,
     a package that does not exist on el9 (it is ``python3-libselinux``)::

         sed -i "s/name: libselinux-python3/name: python3-libselinux/" \
           ~/.quickstart/usr/local/share/ansible/roles/oooci-build-images/tasks/main.yaml

   - install the RDO trunk repos and ``python3-tripleo-repos`` (provides
     ``tripleo-get-hash``, needed by the ``repo-setup`` role to resolve the
     ``current-tripleo`` label)::

         curl -o /etc/yum.repos.d/delorean.repo \
           https://trunk.rdoproject.org/centos9-master/current-tripleo/delorean.repo
         curl -o /etc/yum.repos.d/delorean-deps.repo \
           https://trunk.rdoproject.org/centos9-master/delorean-deps.repo
         dnf install -y python3-tripleo-repos

4. Run the build::

       bash quickstart.sh \
         -R centosci/CentOS-9/master-current-tripleo \
         --no-clone --tags all \
         -c ~/.quickstart/config/general_config/build_images.yml \
         -p build-images.yml 127.0.0.2

Notes
=====

- ``127.0.0.2`` is the canonical way to target the local host (quickstart
  refuses ``127.0.0.1``/``localhost``); passwordless root ssh to it is
  required.  Any other reachable build host can be used instead, as long as
  it runs CentOS Stream 9.
- Running from an el9 host that is *not* CentOS (e.g. RHEL) also works, but
  the ``oooci-build-images`` role only loads its centos-9 defaults when
  ``ansible_distribution == "CentOS"``, so the base-image and DIB facts must
  be passed explicitly, and the image's own ``centos.repo`` does not exist::

      -e tripleo_image_source=https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2
      -e tripleo_image_os=centos9 -e dib_release=9-stream -e dib_dnf_module_streams=
      -e overcloud_repo_paths="['/etc/yum.repos.d/delorean*','/etc/yum.repos.d/quickstart-*']"
- The release file ``centosci/CentOS-9/master-current-tripleo.yml`` defines
  the repos used for the build (delorean + quickstart-centos BaseOS,
  AppStream, CRB, HighAvailability).  The RDO trunk repos for
  ``centos9-master`` are frozen at the pre-decommission state, which matches
  the pinned commits of this repo and its dependencies.
- The build knobs are in ``config/general_config/build_images.yml``:
  ``build_image_isolated: false`` (direct build, the isolated mode is a
  CentOS 7 era leftover), ``build_undercloud: false`` (only the two
  tarballs; set to ``true`` to also produce an ``undercloud.qcow2``),
  ``whole_disk_images: false`` (partition image = ``overcloud-full``),
  ``image_sanity: false`` (`bug 1950453
  <https://bugs.launchpad.net/tripleo/+bug/1950453>`_).
- Build logs land in ``/var/lib/oooq-images/logs/``, the DIB log per image
  in ``/var/lib/oooq-images/<image>.log`` and
  ``/var/lib/oooq-images/build.log``.
- Verify the artifacts with ``md5sum -c overcloud-full.tar.md5``.
