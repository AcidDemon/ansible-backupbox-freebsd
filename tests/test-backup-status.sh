#!/bin/sh
# Checks the freshness logic in 520.backup-status, which is the one piece of
# non-trivial branching in this collection: it has to distinguish "the scheduler
# took a snapshot" from "the client actually wrote something". Stubs zfs and
# friends, renders the real template, and asserts on the output.
#
# Also pins the periodic(8) exit-status contract the report depends on. base sets
# security_show_success=NO, so a report that exited 0 would never be mailed.
#
# Run from the repo root:  sh tests/test-backup-status.sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
now=$(date +%s)
fresh=$(( now - 3600 ))        # 1h ago  -> ok    (limit 26h)
stale=$(( now - 400000 ))      # ~111h   -> STALE (limit 26h)

cat > "$work/vars.json" <<JSON
{
 "backup_pool": "backup", "backup_root": "$work/backup",
 "backup_clients": [
   {"name": "fresh_client", "uid": 5001, "services": ["borg"], "quota": "1G", "max_age_hours": 26,
    "ssh_key": "ssh-ed25519 AAAA x"},
   {"name": "stale_client", "uid": 5002, "services": ["borg"], "quota": "1G", "max_age_hours": 26,
    "ssh_key": "ssh-ed25519 AAAA y"},
   {"name": "empty_client", "uid": 5003, "services": ["borg"], "quota": "1G", "max_age_hours": 26,
    "ssh_key": "ssh-ed25519 AAAA z"},
   {"name": "nosnap_client", "uid": 5004, "services": ["borg"], "quota": "1G", "max_age_hours": 26,
    "ssh_key": "ssh-ed25519 AAAA w"}
 ],
 "vault_healthchecks": {}, "backup_monitoring_default_max_age_hours": 26,
 "backup_monitoring_restic_sample": 5, "backup_monitoring_empty_bytes": 1048576
}
JSON

ANSIBLE_LOCALHOST_WARNING=False ansible localhost -c local \
  -m ansible.builtin.template \
  -a "src=$repo/roles/backup_monitoring/templates/520.backup-status.j2 dest=$work/520" \
  -e "@$work/vars.json" >/dev/null

mkdir -p "$work/bin"
# fresh_client:  scheduler snapshots with written=0, one real write 1h ago.
# stale_client:  scheduler snapshots only since its last real write, ~111h ago.
#                This is the case plain snapshot age would wrongly call healthy.
# empty_client:  dataset still holds nothing but its own metadata.
# nosnap_client: real data on disk, but no snapshot has ever recorded any.
#
# `zfs get` and `zfs list` answer separately: has_data() reads used from get, and
# a stub that replied to both with the snapshot table made every client look
# empty.
cat > "$work/bin/zfs" <<ZFS
#!/bin/sh
case "\$1" in
  get)
    case "\$*" in
      *empty_client*) echo 1024 ;;
      *) echo 4194304 ;;
    esac ;;
  list)
    case "\$*" in
      *fresh_client*) printf '%s\t0\n%s\t4096\n' "$now" "$fresh" ;;
      *stale_client*) printf '%s\t0\n%s\t0\n%s\t4096\n' "$now" "$(( now - 3600 ))" "$stale" ;;
      *empty_client*) printf '%s\t0\n' "$now" ;;
      *nosnap_client*) printf '%s\t0\n' "$now" ;;
    esac ;;
esac
ZFS
printf '#!/bin/sh\nexit 0\n' > "$work/bin/zpool"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/fetch"
chmod +x "$work/bin"/* "$work/520"
mkdir -p "$work/backup/borg" "$work/backup/restic"

set +e
out=$(PATH="$work/bin:$PATH" sh "$work/520" 2>&1)
rc=$?
set -e

fail=0
check() {
  if printf '%s' "$out" | grep -q "$2"; then
    echo "ok   $1"
  else
    echo "FAIL $1 (expected to match: $2)"; fail=1
  fi
}
check "fresh client passes"                 '^ok       backup/borg/fresh_client'
check "stale client is caught"              '^STALE    backup/borg/stale_client'
check "empty dataset is caught"              '^MISSING  backup/borg/empty_client'
check "client that never wrote is caught"   '^MISSING  backup/borg/nosnap_client'
check "empty borg section says so"          'no borg repositories under'
check "empty restic section says so"        'no restic repositories under'

if [ "$rc" -eq 3 ]; then
  echo "ok   exit 3 when something is stale"
else
  echo "FAIL exit should be 3 (unmaskable) when something is stale, got $rc"; fail=1
fi

# Second render on the shipped default. An empty client list is not an alarm, so
# it has to leave the report at 1 while still saying that the list is empty.
cat > "$work/empty.json" <<JSON
{
 "backup_pool": "backup", "backup_root": "$work/backup", "backup_clients": [],
 "vault_healthchecks": {}, "backup_monitoring_default_max_age_hours": 26,
 "backup_monitoring_restic_sample": 5, "backup_monitoring_empty_bytes": 1048576
}
JSON

ANSIBLE_LOCALHOST_WARNING=False ansible localhost -c local \
  -m ansible.builtin.template \
  -a "src=$repo/roles/backup_monitoring/templates/520.backup-status.j2 dest=$work/520empty" \
  -e "@$work/empty.json" >/dev/null
chmod +x "$work/520empty"

set +e
out=$(PATH="$work/bin:$PATH" sh "$work/520empty" 2>&1)
rc=$?
set -e

check "no clients is stated, not implied"   'no backup clients are configured'
if [ "$rc" -eq 1 ]; then
  echo "ok   exit 1 on a clean run"
else
  echo "FAIL exit should be 1 on a clean run, got $rc"; fail=1
fi

[ "$fail" -eq 0 ] || { echo; echo "--- output ---"; printf '%s\n' "$out"; exit 1; }
echo "all checks passed"
