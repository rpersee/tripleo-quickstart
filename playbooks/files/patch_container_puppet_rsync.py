#!/usr/bin/env python3
"""Patch THT's common/container-puppet.sh for rsync >= 3.2.3.

rsync >= 3.2.3 aborts with "rejecting excluded file-list name" when an
entry passed via --files-from matches one of the --exclude patterns.
The frozen zed container-puppet.sh gathers "files modified during the
puppet run" with a find that only filters /etc/puppet*, while the rsync
exclude list is built from $ro_files (which also covers /opt/puppetlabs
-- the shared facter-cache bind mount --, /etc/pki/..., /etc/openldap,
/etc/hosts, ...). Any file modified under one of those paths during a
container-puppet run then kills the whole config generation (rsync rc 2
-> "Failed containers" for most container-puppet-* at deploy step 1).

Fix: derive the find filters from the same $ro_files list the rsync
excludes use, keeping both in lockstep. An array keeps each pattern a
single find argument, and the quoted "${find_args[@]}" expansion keeps
the `*` patterns from being pathname-expanded against the live
filesystem (an unquoted expansion turns /etc/puppet* into the existing
/etc/puppet and /etc/puppetlabs directories and corrupts the find
command line).

Idempotent: exits 0 without touching the file when the patch is already
in place. Exits 1 when the anchor line is missing (upstream layout
changed) so callers fail loudly instead of deploying a broken config
path. Prints SKIP and exits 0 when THT is not installed (flows without
an undercloud install).
"""
import sys

TARGET = "/usr/share/openstack-tripleo-heat-templates/common/container-puppet.sh"
ANCHOR = "    find $rsync_srcs -newer $origin_of_time -not -path '/etc/puppet*' -print0\n"
MARKER = 'find_args+=(-not -path'
FIX = '''    # rsync >= 3.2.3 rejects file-list entries that match an
    # exclude ("rejecting excluded file-list name"). The find
    # below feeds --files-from, so every ro_files entry must be
    # filtered out here (not just /etc/puppet*) or any ro-mounted
    # path modified during the puppet run (e.g. the shared
    # /opt/puppetlabs facter cache) aborts the whole config
    # generation (rsync rc 2). An array keeps each pattern a
    # single find argument, and the quoted "${find_args[@]}"
    # expansion keeps the patterns from being pathname-expanded
    # against the live filesystem (an unquoted expansion turns
    # /etc/puppet* into the existing /etc/puppet and
    # /etc/puppetlabs directories and corrupts the find command).
    find_args=()
    for ro in $ro_files; do
        find_args+=(-not -path "${ro%/}*")
    done
    find $rsync_srcs -newer $origin_of_time -not -path '/etc/puppet*' "${find_args[@]}" -print0
'''


def main():
    try:
        with open(TARGET) as f:
            s = f.read()
    except OSError as e:
        print("SKIP: %s not readable (%s)" % (TARGET, e))
        return 0
    if MARKER in s and '"${find_args[@]}"' in s:
        print("already patched: %s" % TARGET)
        return 0
    if ANCHOR not in s:
        print("ERROR: anchor line not found in %s (THT layout changed?)" % TARGET)
        return 1
    with open(TARGET, "w") as f:
        f.write(s.replace(ANCHOR, FIX))
    print("patched: %s" % TARGET)
    return 0


if __name__ == "__main__":
    sys.exit(main())
