#!/bin/sh
# Checks the freshness logic in 520.backup-status, which is the one piece of
# non-trivial branching in this collection: it has to distinguish "the scheduler
# took a snapshot" from "the client actually wrote something". Stubs zfs and
# friends, renders the real template, and asserts on the output.
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
    "ssh_key": "ssh-ed25519 AAAA z"}
 ],
 "vault_healthchecks": {}, "backup_monitoring_default_max_age_hours": 26,
 "backup_monitoring_restic_sample": 5
}
JSON

ANSIBLE_LOCALHOST_WARNING=False ansible localhost -c local \
  -m ansible.builtin.template \
  -a "src=$repo/roles/backup_monitoring/templates/520.backup-status.j2 dest=$work/520" \
  -e "@$work/vars.json" >/dev/null

mkdir -p "$work/bin"
# fresh_client: scheduler snapshots with written=0, one real write 1h ago.
# stale_client: scheduler snapshots only since its last real write, ~111h ago.
#               This is the case plain snapshot age would wrongly call healthy.
# empty_client: snapshots exist but none ever recorded data.
cat > "$work/bin/zfs" <<ZFS
#!/bin/sh
case "\$*" in
  *fresh_client*) printf '%s\t0\n%s\t4096\n' "$now" "$fresh" ;;
  *stale_client*) printf '%s\t0\n%s\t0\n%s\t4096\n' "$now" "$(( now - 3600 ))" "$stale" ;;
  *empty_client*) printf '%s\t0\n' "$now" ;;
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
check "client that never wrote is caught"   '^MISSING  backup/borg/empty_client'

if [ "$rc" -eq 0 ]; then
  echo "FAIL exit status should be non-zero when something is stale"; fail=1
else
  echo "ok   non-zero exit status"
fi

[ "$fail" -eq 0 ] || { echo; echo "--- output ---"; printf '%s\n' "$out"; exit 1; }
echo "all checks passed"
