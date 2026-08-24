# Smoke tests

## VM first

The first run against real hardware is where the unverified parts surface: pf
anchor syntax, package names, the rest-server rc.d script name, and whether the
rsync port ships rrsync. Find out on a throwaway box.

    vagrant up          # creates the VM, a second disk, the backup pool, runs the chain
    vagrant reload      # RACCT is a loader tunable, rctl rules need the reboot
    vagrant provision   # second converge: should report changed=0

    vagrant ssh
    vagrant destroy -f

Three things will bite you, none of them bugs in the collection:

- `vagrant destroy` does not remove disks attached via `libvirt.storage`, so the
  next `vagrant up` dies with "storage volume ... exists already". Run
  `sh tests/reset-vm.sh` instead of `vagrant destroy`.
- The first `vagrant provision` after `vagrant up` fails once with a
  privilege-escalation timeout. base enables pf mid-play, which drops the live
  SSH session; the next connection inherits a dead control socket and the one
  after that works. Just run it again.
- Once `ssh_hardening` has run, Vagrant's provisioners cannot reconnect at all
  without a kex they support, because they use Ruby net-ssh rather than the
  OpenSSH binary. The Vagrantfile adds `diffie-hellman-group14-sha256` for this
  reason. `vagrant ssh` and ansible are unaffected.

Test client keys are generated on first `vagrant up` into `tests/files/` and are
gitignored. Tailscale is off in the VM: it cannot authenticate without a key and
there is no tailnet to advertise into. Jail routing does not depend on it.

One gap to keep in mind. No libvirt FreeBSD 15 box is published, so the VM
defaults to 14 while production is 15. Everything structural is the same, but
package names are exactly the kind of thing that can differ between releases, so
a clean VM run is evidence and not proof. With a 15 box available:

    FREEBSD_BOX=generic/freebsd15 vagrant up

`jail_base_version` is empty by default, meaning the jail base tracks the host's
own `freebsd-version -u`, so the VM and erebus each get a matching userland
without anyone editing a pin.

## Then check the things that are quiet when they break

Run the chain, then check the things that are easy to get wrong and quiet when
they are.

## Isolation

    jls -N                                   # three jails, distinct epairs
    jexec borg zfs list                      # "no datasets available"
    jexec borg ls -a /backups/<client>       # no .zfs entry (snapdir=hidden)
    jexec borg ls /backups/<client>/.zfs/snapshot          # names ARE listable
    jexec borg ls /backups/<client>/.zfs/snapshot/<snap>   # Operation not permitted
    jexec borg rm -rf /backups/<client>/.zfs/snapshot/<snap>  # Operation not permitted

## Snapshot ownership

The point of the whole design. Take a snapshot, destroy the data from inside the
jail, confirm the snapshot survives and the jail cannot remove it.

    zfs snapshot backup/borg/<client>@test
    jexec borg sh -c 'rm -rf /backups/<client>/*'
    zfs list -t snapshot backup/borg/<client>   # still there
    zfs rollback backup/borg/<client>@test      # host can, jail cannot

## Append-only

    # from the client, against its own repo:
    borg create ...                          # succeeds
    borg prune ...                           # SUCCEEDS - see below
    restic backup ...                        # succeeds
    restic forget --prune                    # must be refused by rest-server

borg's append-only does not refuse prune or delete. They succeed and the archives
vanish from `borg list`; what it guarantees is that the segments are retained so
the operator can roll back to an earlier transaction. Check the segments, not the
archive list:

    borg prune --keep-last 1 $REPO           # succeeds
    borg list $REPO                          # empty
    find /backup/borg/<client>/repo/data -type f | wc -l   # segments still there
    borg compact $REPO                       # reclaims nothing

## zfs recv confinement

    zfs allow backup/zrecv/<client>          # canmount,create,mount,mountpoint,readonly,receive
                                             # and NOT destroy or rollback
    zfs send ... | ssh -p 2222 zfsrecv@erebus  # succeeds
    zfs send ... | ssh -p 2222 zfsrecv@erebus 'zfs recv -F other/dataset'
                                             # target is ignored: forced command

## Resource limits

    rctl -u jail:borg                        # live accounting (needs the RACCT reboot)

## Quotas

Fill one client's quota and confirm no other client and no host operation is
affected.

## Reporting

    periodic security                        # 520.backup-status and the AIDE check
                                             # appear even on a clean box, both exit 1.
                                             # Nothing else does unless it found
                                             # something. Sane per-client ages.
    sh tests/test-backup-status.sh           # run from the repo root

## Idempotence

A second full run should report `changed=0`.

Watch for tasks that manage permissions on a path something else mounts over.
`/jails/<name>/dev` is a devfs mount and `/jails/<name>/backups/<client>` is a
nullfs mount of the client dataset; setting owner or mode on either writes
straight through onto the mounted filesystem and fights whichever role
legitimately owns it, so both are created as bare mountpoints.

Expect every client to report MISSING until the first zfsnap cron fires: the
freshness check deliberately looks for a snapshot that recorded data, not merely
for a snapshot, so a box with no snapshots yet has nothing to measure.

## Verified on the VM

Everything below was run end to end on FreeBSD 14.3, not just inspected:

| Check | Result |
|---|---|
| borg init/create/list over ssh | works |
| borg prune/delete | **succeed**; archives vanish from listing, segments retained |
| borg cross-client path | refused: `Repository path not allowed` |
| arbitrary command over a borg key | refused by the forced command |
| restic init/backup/snapshots | works |
| restic `forget --prune` | refused by rest-server; both snapshots survived |
| rsync push / read-back | push works, read-back refused (`-wo`) |
| `zfs send` into the listener | lands under `backup/zrecv/<client>/` |
| client-chosen recv target | ignored; forced command's target used |
| `zfs destroy` of a snapshot from a jail | `dataset does not exist` |
| reading or removing a snapshot via `.zfs` from a jail | `Operation not permitted` |
| recovery from `.zfs/snapshot/...` after client wipes everything | full |
| host `borg compact` | reclaims (17 segments to 3) |
| host `borg prune` | impossible: needs the client's passphrase |
