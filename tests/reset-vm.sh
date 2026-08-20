#!/bin/sh
# vagrant destroy leaves volumes attached via libvirt.storage behind, so the next
# `vagrant up` dies with "storage volume ... exists already".
#
# Match by domain prefix rather than by device name: the suffix follows the bus
# the box uses, so it is -sdb.qcow2 on a scsi box and -vdb.qcow2 on a virtio one.
set -u
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

vagrant destroy -f 2>/dev/null

prefix=$(basename "$PWD")_backupbox
virsh -c qemu:///system vol-list default 2>/dev/null |
    awk -v p="$prefix" '$1 ~ "^" p { print $1 }' |
    while read -r v; do
        virsh -c qemu:///system vol-delete --pool default "$v" >/dev/null 2>&1 &&
            echo "deleted $v"
    done

echo "clean"
