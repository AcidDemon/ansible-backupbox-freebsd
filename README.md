# ansible-backupbox-freebsd

Ansible collection that turns a FreeBSD 15.1 host into a hardened backup target:
one VNET jail per ingest protocol, host-side `zfs recv`, RCTL resource caps, and
ZFS snapshots the jails have no way to reach.

Chains between the two generic collections:

    acidnetworks.base_freebsd.site  ->  acidnetworks.backupbox_freebsd.backupbox  ->  acidnetworks.hardening_freebsd.harden

## The problem it solves

A backup client can be compromised, and when it is, its credentials are still
valid. The threat is not someone breaking in - it is someone who already holds a
client's key deciding to destroy that client's backups. Two mechanisms answer it:

**Append-only at the protocol.** borg runs behind
`borg serve --append-only --restrict-to-path`, restic behind
`rest-server --append-only --private-repos`, rsync behind `rrsync -wo`.

Be precise about what borg's append-only actually buys, because it is weaker than
it sounds. It does **not** refuse `prune` or `delete`. Those commands succeed, the
archives disappear from `borg list`, and the client sees an apparently pruned
repository. What append-only guarantees is that the removal is not destructive:
the data segments stay on disk and the operator can roll the repository back to an
earlier transaction. Verified on the test VM, where after a client-side prune and
delete the archive listing was empty while every segment remained, and a
client-side `borg compact` added segments rather than reclaiming any.

So a compromised borg client can make its backups *look* gone, and getting them
back is a manual operator action. That is exactly why the host-owned snapshots
below are the real guarantee rather than a second line of defence.

restic is the stronger of the two. `rest-server --append-only` refuses the delete
outright: on the test VM `restic forget --keep-last 1 --prune` reported what it
would keep and then left both snapshots in place.

The host runs `borg compact` on a schedule to reclaim what a client's prune left
behind, but it cannot run `borg prune` itself, because prune needs the repository
passphrase and these repos are encrypted client-side. Retention is the client's
call; reclaiming the space is the host's.

**Host-owned snapshots.** No jail is ever delegated a ZFS dataset. Backup data
reaches a jail through a nullfs mount, as a plain directory, with `snapdir=hidden`
so `.zfs` is not reachable either. Snapshots are taken and expired by the host on
a schedule the jails cannot see. rsync and sftp clients have no append-only
protection at all, so for them this is the only line of defence - which is why
retention runs to a year.

`zfs recv` is the exception that proves the rule: receiving into a jail would
require delegating the dataset, which hands that jail `zfs destroy` over its own
snapshots. So it runs on the host instead, behind a forced command that derives
the target dataset from which key authenticated, and a delegation that excludes
`destroy` and `rollback` (without `rollback`, `zfs recv -F` fails).

## Layout

| Role | What it does |
|---|---|
| `backup_network` | Tailscale, jail subnet advertisement, IPv4 forwarding |
| `backup_storage` | Dataset tree, per-client quotas, weekly scrub, full-pool headroom |
| `jail_host` | RACCT/RCTL, `jail_enable`, `/etc/rctl.conf` |
| `jail_base` | Versioned read-only base dataset, weekly `pkg -r` updates |
| `jail_instances` | Per-jail datasets, nullfs fstab, `jail.conf.d` fragments, VNET wiring |
| `backup_borg` | borg jail + sshd, append-only forced commands, host-side compaction |
| `backup_restic` | rest-server jail, append-only, per-client htpasswd |
| `backup_rsync` | rsync/sftp jail + sshd, `rrsync -wo` or chrooted `internal-sftp` |
| `backup_zrecv` | Host-side receive listener on its own sshd instance |
| `backup_snapshots` | zfsnap policies: hourly 48, daily 30, monthly 12 |
| `backup_monitoring` | `520.backup-status` in `periodic security` |

## Networking

Every jail gets its own `/24` on a routed epair - not a shared bridge. Bridged
jails can reach each other without host pf ever seeing the packets, and these
jails have no reason to talk to each other.

They also have no reason to talk to anything else: package installs use `pkg -r`,
which installs into the jail root over the *host's* network. (`pkg -j` would not:
it attaches into the jail and uses the jail's own network.) So no pf
rule ever passes traffic arriving on an epair. A jail can answer a connection
(floating state from the inbound pass rule covers the reply) but cannot open
one. The default route in each jail exists only so replies reach tailnet clients.

The host advertises the jail subnet as a Tailscale subnet router. Nothing is
public; `firewall_allow_tcp` is empty and stays that way.

## Two things that will silently break backups

**Tailscale key expiry.** Turn it off for this node in the admin console. The
180-day default drops the box off the tailnet and every backup fails with no
obvious cause.

**Manual unlock.** `erebus` boots into an unencrypted outer UFS base and waits
for `unlock.sh` (see the `freebsd-outerbase` repo). Any reboot - VPS maintenance,
a panic - leaves it there with no `backup` pool and no jails. `520.backup-status`
cannot warn you about this, because it lives on the inner system that is not
running. That is why the primary staleness alarm is client-side healthchecks.io
pings, not this box.

## Run

    ansible-galaxy collection install -r requirements.yml
    ansible-playbook -i inventory/hosts.yml site.yml --vault-password-file <file>

Client definitions and contract vars live in `inventory/group_vars/all/main.yml`;
secrets in `vault.yml` beside it.

## Client uids

Every `backup_clients` entry needs a pinned, unique `uid`. Jail users exist only
inside their jail, so the host chowns their data numerically. A uid derived from
list position would silently reassign one client's backups to another the first
time the list is reordered. The playbook refuses to run without them.

## RACCT needs a reboot

`kern.racct.enable=1` is a loader tunable, so the rules in `/etc/rctl.conf` do
nothing until the next boot - which on this box means an unlock round trip. The
play says so rather than failing.

`memoryuse` ships as `log`, not `deny`, on purpose: rctl deny does not OOM-kill
cleanly, it makes allocations fail inside the jail, and borg and restic die
untidily under that. Watch `rctl -u jail:borg` for a few weeks, then set a number
you have actually observed.
