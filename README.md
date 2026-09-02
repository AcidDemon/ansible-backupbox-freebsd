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

The host schedules `borg compact` to reclaim what a client's prune left behind,
but it cannot run `borg prune` itself, because prune needs the repository
passphrase and these repos are encrypted client-side. Retention is the client's
call; reclaiming the space is the host's.

Both `borg compact` and the `borg check` in `520.backup-status` run inside the
jail as the client, driven from the host by `jexec`. Neither is a read-only
operation: compact rewrites the data segments, index, hints and integrity, and
check rewrites the config to record how far it got. Run either as root and
everything it wrote comes back owned by root, at which point the client cannot
use its own repository and every backup fails.

restic has no equivalent half. Because the delete is refused rather than
recorded, nothing reclaims space and the client's quota fills eventually. The
only way out is to stop refusing for a while, so `restic-maintenance` on the
host opens a bounded window:

    restic-maintenance open 60     # append-only off, at(1) closes it in 60 min
    restic-maintenance status      # exits 1 while a window is open
    restic-maintenance close       # close early

The rc fragment tests for a sentinel file and adds `--append-only` when it is
absent, so a lost or half-written sentinel leaves the server protected rather
than open. An ansible run closes the window too, because the declared state is
append-only. `520.backup-status` reports one that outlived its at(1) job.

This asymmetry is the main reason to prefer borg per host rather than mixing:
borg's retention loop closes with nobody watching, restic's needs an operator.

**Host-owned snapshots.** No jail is ever delegated a ZFS dataset. Backup data
reaches a jail through a nullfs mount, as a plain directory.

`snapdir=hidden` keeps `.zfs` out of directory listings, but be accurate about
what that does and does not do: the snapshot directory is still reachable by
explicit path, so a process in the jail can enumerate snapshot *names*. It cannot
read their contents and it cannot remove them. Verified on the VM: listing
`.zfs/snapshot` returns the names, reading a snapshot returns "Operation not
permitted", and both `zfs destroy` and `rm -rf` against it are refused while the
snapshot survives. The guarantee comes from the jail having no ZFS ioctl at all,
not from hiding the directory. Snapshots are taken and expired by the host on
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
| `backup_network` | Tailscale, jail subnet advertisement |
| `backup_storage` | Dataset tree, per-client quotas, weekly scrub, full-pool headroom |
| `jail_host` | RACCT/RCTL, `jail_enable`, `/etc/rctl.conf`, IPv4 forwarding |
| `jail_base` | Versioned read-only base dataset, weekly `pkg -r` updates |
| `jail_instances` | Per-jail datasets, nullfs fstab, `jail.conf.d` fragments, VNET wiring |
| `backup_borg` | borg jail + sshd, append-only forced commands, host-side compaction |
| `backup_restic` | rest-server jail, append-only, per-client htpasswd, maintenance window |
| `backup_rsync` | rsync/sftp jail + sshd, `rrsync -wo` or chrooted `internal-sftp` |
| `backup_zrecv` | Host-side receive listener on its own sshd instance |
| `backup_logs` | VictoriaLogs jail: syslog in, LogsQL and a Grafana datasource out |
| `backup_snapshots` | sanoid policies: hourly 48, daily 30, monthly 12 |
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

## Logs

`backup_logs` is the one jail that stores nothing a client sent over ssh, so it
works differently from the four ingest paths. It runs `net-mgmt/victoria-logs`,
which is its own syslog server: OPNsense, MikroTik and every FreeBSD or Linux
host point at `10.100.<id>.2:1514` and there is no agent anywhere. Queries and the
built-in web UI answer on `:9428`, which is also what a Grafana instance
elsewhere on the tailnet points the `victoriametrics-logs-datasource` plugin at.

Grafana does not belong on this box. It wants a browser session, a plugin
lifecycle and a login, against a host whose whole design is that nothing is
public and every reboot needs a console unlock. Ingest and store here, render
somewhere else.

The jail is declared like any other, plus a quota:

    jails:
      - name: logs
        id: 4
        quota: 100G

That quota is load-bearing. It is what makes `backup_storage` create
`<pool>/logs` and what makes `jail_instances` nullfs-mount it at `/backups`
inside the jail, which is where `-storageDataPath` points. Without it the jail
still starts and victoria-logs still runs - onto the jail's own dataset in
zroot, unencrypted, unquotaed, and discarded at the next base extraction.

Three things about the transport are not preferences:

- **UDP, not TCP.** RouterOS sends syslog over UDP whatever `remote-protocol`
  says; TCP and TLS there apply to CEF only. FreeBSD's base syslogd forwards
  over UDP alone and does not implement the `@@` syntax. Open
  `firewall_allow_udp_svc: [1514]`, never `firewall_allow_udp`, which is the
  public list.
- **1514, not 514.** victoria-logs runs as an unprivileged account and FreeBSD
  refuses a reserved-port bind to anyone but root, so it starts, logs why, and
  exits. Every route around that is worse than a port number:
  `net.inet.ip.portrange.reservedhigh` is per-vnet but has no `CTLFLAG_PRISON`,
  so jailed root cannot write it; `mac_portacl` has an open bug against VNET
  jails; and running the daemon as root would put a parser of untrusted device
  input back at uid 0. Every sender takes a port, so this costs one number per
  config.
- **`-O rfc5424` on FreeBSD senders.** FreeBSD's RFC3164 output currently parses
  wrong in VictoriaLogs: the app name lands in the hostname field. Set
  `syslogd_flags="-s -O rfc5424"`. On MikroTik the equivalent is
  `syslog-time-format=iso8601`, without which messages carry no year and no
  offset.
- **Nothing buffers.** A UDP datagram that arrives while the jail is down is
  gone, and on a box that needs a manual `unlock.sh` after every reboot that
  window is not theoretical. When it starts costing you, the relay belongs on
  OPNsense - which already runs syslog-ng - and not here.

## Three things that will silently break backups

**Tailscale key expiry.** Turn it off for this node in the admin console. The
180-day default drops the box off the tailnet and every backup fails with no
obvious cause.

**Unapproved subnet route.** `backup_network` runs `tailscale set
--advertise-routes`, which only offers the route. Until someone approves
`10.100.0.0/16` on the machine's page in the admin console, no tailnet client
reaches `10.100.x.2` and the play still reports success. Clients need
`tailscale up --accept-routes` too; it is off by default on Linux and macOS.

**Manual unlock.** `erebus` boots into an unencrypted outer UFS base and waits
for `unlock.sh` (see the `freebsd-outerbase` repo). Any reboot - VPS maintenance,
a panic - leaves it there with no `backup` pool and no jails. `520.backup-status`
cannot warn you about this, because it lives on the inner system that is not
running. That is why the primary staleness alarm is client-side healthchecks.io
pings, not this box.

## What arrives in the mail

`520.backup-status` follows the `periodic(8)` exit-status contract that base relies
on: 1 when the report is routine, 3 when a client is stale or missing, a borg repo
fails its check, a restic pack is corrupt, or the restic maintenance window was left
open. base sets `security_show_success=NO`, so a report exiting 0 would be dropped
before it reached you, and 3 is above the range `periodic` can mask at all.

Every section says what empty means for it. No clients configured, no borg repos under
`{backup_root}/borg`, no restic repos under `{backup_root}/restic` are all stated in
words, because a heading with nothing under it reads like a check that broke.

## Run

`site.yml` is a dev entrypoint: it runs this collection alone, which gives you
jails and datasets on a host with no accounts, no pf and no hardening. A real
deploy runs all three collections in order.

    ansible-galaxy collection install -r requirements.yml
    ansible-playbook chain.yml --vault-password-file <file>

where `chain.yml` is the three imports in `tests/chain.yml`. Clients addressing
the box use the jail addresses directly - `borg@10.100.1.2`, `10.100.2.2:8000`,
`10.100.3.2` for rsync and sftp, and the host's tailnet address on 2222 for
`zfs recv`. There is no rdr and no nat, so `borg@erebus` reaches the host sshd
instead.

The first run against a virgin box needs two connection users, because base
creates `acid` and `ansible` and hardening then refuses root logins. Run
`acidnetworks.base_freebsd.site` as root, then the other two as `ansible`.

`inventory/` here is a reference for the dev entrypoint and the VM harness, not
a deploy inventory: it documents every contract var this collection expects, and
carries no clients and no secrets. A real deploy keeps those in a private
orchestrator repo, which is also where the vault lives. Nothing in this repo
should ever hold one.

The vault keys this collection reads are `vault_healthchecks` and
`vault_restic_passwords`, both keyed by client name. `hardening_freebsd` adds
`vault_smtp_user` and `vault_smtp_password`.

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
