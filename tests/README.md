# Smoke tests

Run the chain, then check the things that are easy to get wrong and quiet when
they are.

## Isolation

    jls -N                                   # three jails, distinct epairs
    jexec borg zfs list                      # must fail: no ZFS in the jail
    jexec borg ls /backups/../               # must not reach another jail
    ls /backup/borg/<client>/.zfs            # must not exist (snapdir=hidden)

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
    borg prune ...                           # must be REFUSED
    restic backup ...                        # succeeds
    restic forget --prune                    # must be REFUSED

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

    periodic security                        # 520.backup-status in the output,
                                             # sane per-client ages

## Idempotence

A second full run should report `changed=0`.
