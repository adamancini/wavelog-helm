#!/usr/bin/env bash
# Scheduled MariaDB backups: a manual Job writes a dump, retention keeps only
# the newest N completed dumps, and the newest dump restores a deleted QSO
# into the bundled database.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCENARIO=backup
VALUES="$E2E_DIR/values-backup.yaml"
API_KEY=wlE2Ebackupkey001
CRONJOB="$E2E_FULLNAME-backup"
PVC="$E2E_FULLNAME-backup"
SHELL_POD=bk-shell

post_qso() {
  local url=$1 call=$2 body code
  body=$(printf '{"key":"%s","station_profile_id":"1","type":"adif","string":"<call:5>%s<band:3>20m<mode:3>FT8<qso_date:8>20260101<time_on:6>120000<eor>"}' "$API_KEY" "$call")
  code=$(curl -s -o "$E2E_TMP/qso.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "$body" "$url/index.php/api/qso")
  [[ $code == 200 || $code == 201 ]] || e2e_die "POST /api/qso returned $code: $(cat "$E2E_TMP/qso.json")"
  grep -q '"status":"created"\|"status":"ok"' "$E2E_TMP/qso.json" \
    || e2e_die "POST /api/qso status not ok: $(cat "$E2E_TMP/qso.json")"
}

run_backup() {
  local name=$1
  k create job --from="cronjob/$CRONJOB" "$name" >/dev/null
  if ! k wait --for=condition=complete "job/$name" --timeout=5m >/dev/null; then
    k logs "job/$name" --all-containers --tail=100 >&2 || true
    e2e_die "backup job $name did not complete"
  fi
}

# bk_shell_up: a sleeping pod that mounts the backup PVC read-only and can talk
# to the database as the Wavelog user (the restore command lives here too).
bk_shell_up() {
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $SHELL_POD
spec:
  securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999}
  containers:
    - name: sh
      image: docker.io/library/mariadb:11.8
      command: [sleep, "600"]
      env:
        - {name: DB_HOST, value: "$E2E_FULLNAME-mariadb"}
        - name: MYSQL_PWD
          valueFrom: {secretKeyRef: {name: "$E2E_FULLNAME-mariadb", key: mariadb-password}}
      volumeMounts: [{name: backup, mountPath: /backup}]
  volumes:
    - name: backup
      persistentVolumeClaim: {claimName: "$PVC"}
YAML
  k wait --for=condition=Ready "pod/$SHELL_POD" --timeout=3m >/dev/null
}
bk_shell_down() { k delete pod "$SHELL_POD" --wait=true --now >/dev/null; }
bk_exec() { k exec "$SHELL_POD" -c sh -- sh -c "$1"; }

e2e_namespace "$SCENARIO"
k create secret generic wl-apikey --from-literal=api-key="$API_KEY" >/dev/null
# The backup PVC stays Pending until its first consumer (WaitForFirstConsumer
# on local-path and kind), and `helm --wait` blocks on unbound PVCs. So install
# without helm's wait, then wait for the workloads ourselves.
e2e_install "$SCENARIO" --wait=hookOnly -f "$VALUES"
k rollout status "statefulset/$E2E_FULLNAME-mariadb" --timeout=10m >/dev/null
k rollout status "deployment/$E2E_FULLNAME" --timeout=10m >/dev/null

url=$(e2e_url)
post_qso "$url" K1ABC
assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM TABLE_HRD_CONTACTS_V01 WHERE COL_CALL='K1ABC'")" "QSO seeded"

# One backup: a completed dump exists, no temp leftovers, and it is a valid gzip.
run_backup b1
bk_shell_up
assert_eq 1 "$(bk_exec 'ls -A /backup | wc -l')" "one entry after first backup"
assert_eq 1 "$(bk_exec 'ls /backup/wavelog-????????T??????Z.sql.gz | wc -l')" "dump named wavelog-<timestamp>.sql.gz"
bk_exec 'gzip -t /backup/wavelog-*.sql.gz' || e2e_die "dump is not valid gzip"
bk_shell_down

# Retention 2: eight runs leave exactly the two newest completed dumps.
for n in 2 3 4 5 6 7 8; do run_backup "b$n"; done
bk_shell_up
assert_eq 2 "$(bk_exec 'ls -A /backup | wc -l')" "retention keeps exactly 2 entries"
assert_eq 2 "$(bk_exec 'ls /backup/wavelog-*.sql.gz | wc -l')" "retention keeps exactly 2 dumps"

# Restore the newest dump into the bundled database.
e2e_sql "DELETE FROM TABLE_HRD_CONTACTS_V01 WHERE COL_CALL='K1ABC'"
assert_eq 0 "$(e2e_sql "SELECT COUNT(*) FROM TABLE_HRD_CONTACTS_V01 WHERE COL_CALL='K1ABC'")" "QSO deleted"
# shellcheck disable=SC2016 # expanded inside the pod
bk_exec 'gunzip -c "$(ls -1 /backup/wavelog-*.sql.gz | sort | tail -n1)" | mariadb -h "$DB_HOST" -uwavelog wavelog'
assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM TABLE_HRD_CONTACTS_V01 WHERE COL_CALL='K1ABC'")" "QSO restored from dump"
bk_shell_down

e2e_uninstall
echo "PASS: $SCENARIO"
