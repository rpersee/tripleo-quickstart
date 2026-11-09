#!/bin/bash
# Build the TripleO overcloud images (overcloud-full and ironic-python-agent)
# on a CentOS Stream 9 host, producing overcloud-full.tar and
# ironic-python-agent.tar (with .md5 files).
#
# This follows the logic of the (retired) tripleo-ci
# tripleo-buildimage-overcloud-full-centos-9 and
# tripleo-buildimage-ironic-python-agent-centos-9 zuul jobs:
#   tripleo-build-jobs-repos -> repo-setup (live repos on the build host)
#   oooci-build-images       -> openstack overcloud image build (DIB) +
#                               tar + md5sum packaging
# driven through the tripleo-quickstart build-images.yml playbook, which
# uses the build-images role from tripleo-quickstart-extras.
#
# NOTE: in this flow the tqe build-images role only *renders* the repo-setup
# script (repo_run_live: false), so the repos DIB needs (DIB_YUM_REPO_CONF)
# must be installed on the build host beforehand: the delorean trunk repos
# (which also carry python3-tripleo-repos / tripleo-get-hash) and the
# quickstart-centos repos, same as the release file used by repo-setup.
#
# Usage (as root, on the build host):
#   bash ci-scripts/build-images-cs9.sh
#
# Environment:
#   VIRTHOST  host quickstart connects to build the images on.
#             Defaults to 127.0.0.2 (loopback ssh to self, the usual
#             standalone pattern; quickstart refuses 127.0.0.1/localhost).
#             Passwordless ssh as root to $VIRTHOST must work.
#   RELEASE   quickstart release config holding the repo definitions
#             used by the repo-setup role.
set -eux

RELEASE=${RELEASE:-"centosci/CentOS-9/master-current-tripleo"}
VIRTHOST=${VIRTHOST:-127.0.0.2}
export VIRTHOST
export OPT_WORKDIR=${OPT_WORKDIR:-~/.quickstart}

TQ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRUNK_BASE="https://trunk.rdoproject.org/centos9-master"
CENTOS_MIRROR="http://mirror.stream.centos.org/9-stream"
IPA_IMAGE_URL="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2"

# quickstart.sh runs the playbooks/configs installed in $OPT_WORKDIR, not the
# ones from this checkout. On the first run it bootstraps the virtualenv and
# pip-installs the pinned tripleo-quickstart/tripleo-quickstart-extras/
# tripleo-ci content from this checkout (--no-clone), which also installs the
# roles into $OPT_WORKDIR/usr/local/share/ansible/roles.
if [ ! -f "$OPT_WORKDIR/bin/activate" ]; then
    bash "$TQ_DIR/quickstart.sh" --install-deps
    bash "$TQ_DIR/quickstart.sh" -R "$RELEASE" --no-clone -y "$VIRTHOST"
fi

# Keep the installed playbooks/config in sync with this checkout (a no-op
# right after a bootstrap).
cp -f "$TQ_DIR/playbooks/build-images.yml" "$OPT_WORKDIR/playbooks/"
mkdir -p "$OPT_WORKDIR/config/general_config"
cp -f "$TQ_DIR/config/general_config/build_images.yml" "$OPT_WORKDIR/config/general_config/"

# The pinned oooci-build-images role installs "libselinux-python3", a package
# name that does not exist on el9 (it is python3-libselinux there).
OOOCI_MAIN="$OPT_WORKDIR/usr/local/share/ansible/roles/oooci-build-images/tasks/main.yaml"
if [ -f "$OOOCI_MAIN" ] && grep -q "name: libselinux-python3" "$OOOCI_MAIN"; then
    sed -i "s/name: libselinux-python3/name: python3-libselinux/" "$OOOCI_MAIN"
fi

# Delorean trunk repos (component-based current-tripleo), same content as the
# delorean.repo/delorean-deps.repo entries of the release file.
if [ ! -e /etc/yum.repos.d/delorean.repo ]; then
    curl -fso /etc/yum.repos.d/delorean.repo \
        "$TRUNK_BASE/current-tripleo/delorean.repo"
fi
if [ ! -e /etc/yum.repos.d/delorean-deps.repo ]; then
    curl -fso /etc/yum.repos.d/delorean-deps.repo \
        "$TRUNK_BASE/delorean-deps.repo"
fi

# quickstart-centos repos, rendered the same way as the repo-setup role does
# for "generic" repo entries (baseurl + gpgcheck=0). These are the repos
# matched by the DIB_YUM_REPO_CONF "quickstart-*" glob.
write_quickstart_repo() {
    local repo=$1 component=$2
    if [ ! -e "/etc/yum.repos.d/${repo}.repo" ]; then
        cat > "/etc/yum.repos.d/${repo}.repo" <<EOF
[${repo}]
name=${repo}
baseurl=${CENTOS_MIRROR}/${component}/x86_64/os/
gpgcheck=0
enabled=1
EOF
    fi
}
write_quickstart_repo quickstart-centos-base BaseOS
write_quickstart_repo quickstart-centos-appstreams AppStream
write_quickstart_repo quickstart-centos-crb CRB
write_quickstart_repo quickstart-centos-highavailability HighAvailability

# python3-tripleo-repos provides tripleo-get-hash, needed by the repo-setup
# role to resolve the "current-tripleo" hash label.
dnf install -y python3-tripleo-repos

# On a RHEL build host: the CentOS containers-common rpm (pulled into the
# python3-tripleoclient transaction from the delorean repos through the
# tripleo-common/podman dependency chain) ships
# /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release, which also belongs to the
# redhat-release package, so the whole dnf transaction aborts with a file
# conflict. Pre-install it with rpm --replacefiles (the file content is the
# same RHEL release key) so the ansible package task finds it already
# installed and skips it.
if ! grep -q "^ID=\"\?centos\"\?$" /etc/os-release; then
    if ! rpm -q containers-common >/dev/null 2>&1; then
        dnf install -y --downloadonly \
            --destdir=/tmp/containers-common-install containers-common
        rpm -Uvh --replacefiles /tmp/containers-common-install/*.rpm
    fi
fi

# The pinned oooci-build-images role only loads its centos-9 defaults
# (base image, DIB_RELEASE, ...) when the build host is CentOS. On any other
# el9 distro, pass them explicitly and drop /etc/yum.repos.d/centos.repo from
# overcloud_repo_paths since it only exists on CentOS.
EXTRA_VARS=()
if ! grep -q "^ID=\"\?centos\"\?$" /etc/os-release; then
    EXTRA_VARS=(
        -e "tripleo_image_source=$IPA_IMAGE_URL"
        -e "tripleo_image_os=centos9"
        -e "dib_release=9-stream"
        -e "dib_dnf_module_streams="
        -e "overcloud_repo_paths=['/etc/yum.repos.d/delorean*','/etc/yum.repos.d/quickstart-*']"
    )
fi

# Run the image build. Re-running is idempotent: repo-setup skips existing
# repos, the oooci-build-images role re-downloads the base image and
# rebuilds everything from scratch in /var/lib/oooq-images.
bash "$TQ_DIR/quickstart.sh" \
    -R "$RELEASE" \
    --no-clone \
    --tags all \
    -c "$OPT_WORKDIR/config/general_config/build_images.yml" \
    "${EXTRA_VARS[@]}" \
    -p build-images.yml \
    "$VIRTHOST"

echo "Built artifacts:"
ls -l /var/lib/oooq-images/overcloud-full.tar* /var/lib/oooq-images/ironic-python-agent.tar*
