#!/bin/sh
# vagrant destroy leaves volumes attached via libvirt.storage behind, so the next
# `vagrant up` dies with "storage volume ... exists already". Clean both.
set -u
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
vagrant destroy -f 2>/dev/null
for v in ansible-backupbox-freebsd_backupbox-sdb.qcow2 ansible-backupbox-freebsd_backupbox.img; do
    virsh -c qemu:///system vol-delete --pool default "$v" 2>/dev/null && echo "deleted $v"
done
echo "clean"
