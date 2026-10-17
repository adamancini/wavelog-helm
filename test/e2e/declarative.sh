#!/usr/bin/env bash
# Declarative install: schema, admin user, migrations, idempotent restarts,
# secrets stable across upgrade, and refusal to touch a partial install.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCENARIO=declarative
VALUES="$E2E_DIR/values-declarative.yaml"
# shellcheck disable=SC2016 # literal $ and \ in the password
ADMIN_PASSWORD='p'"'"'a"s$s\w0rd'

login_ok() {
  local url=$1 jar="$E2E_TMP/cookies" code body location
  rm -f "$jar"
  code=$(curl -s -o /dev/null -w '%{http_code}' -c "$jar" -b "$jar" "$url/index.php/dashboard")
  [[ $code != 200 ]] || e2e_die "dashboard served without login"
  curl -s -o /dev/null -c "$jar" -b "$jar" "$url/index.php/user/login"
  # Success redirects to the dashboard; failure redirects back to user/login.
  location=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$jar" -b "$jar" \
    --data-urlencode "user_name=admin" \
    --data-urlencode "user_password=$ADMIN_PASSWORD" \
    "$url/index.php/user/login")
  [[ $location == */dashboard ]] || e2e_die "login POST redirected to '$location', not the dashboard"
  printf 'ok: login POST redirects to the dashboard\n' >&2
  code=$(curl -s -o "$E2E_TMP/dashboard.html" -w '%{http_code}' -c "$jar" -b "$jar" \
    "$url/index.php/dashboard")
  assert_eq 200 "$code" "dashboard after login"
  body=$(cat "$E2E_TMP/dashboard.html")
  [[ $body == *N0CALL* ]] || e2e_die "dashboard does not contain N0CALL"
  printf 'ok: dashboard shows N0CALL\n' >&2
}

secret_value() { k get secret "$1" -o go-template="{{index .data \"$2\"}}"; }

e2e_namespace "$SCENARIO"
k create secret generic wl-admin --from-literal=admin-password="$ADMIN_PASSWORD" >/dev/null
# No pre-wait for MariaDB: bootstrap starts while the database initialises.
e2e_install "$SCENARIO" -f "$VALUES"

pod=$(e2e_wavelog_pod)
restarts=$(k get pod "$pod" -o jsonpath='{.status.initContainerStatuses[?(@.name=="bootstrap")].restartCount}')
assert_eq 0 "$restarts" "bootstrap succeeded on its first attempt"
bootstrap_logs=$(k logs "$pod" -c bootstrap)
printf '%s\n' "$bootstrap_logs" >&2
if [[ $bootstrap_logs == *"waiting for database"* ]]; then
  e2e_log "bootstrap waited for the database"
fi

assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM users WHERE user_name='admin'")" "one admin user"

e2e_log "bootstrap.php unit checks"
for src in "$E2E_CHART/files/bootstrap.php" "$E2E_DIR/bootstrap_unit.php"; do
  dest="/tmp/${src##*/}"
  # shellcheck disable=SC2016 # expanded inside the container
  k exec -i "$pod" -c wavelog -- sh -c 'cat > "$1"' sh "$dest" <"$src"
done
k exec "$pod" -c wavelog -- php /tmp/bootstrap_unit.php /tmp/bootstrap.php

url=$(e2e_url)
code=$(curl -s -o "$E2E_TMP/install.html" -w '%{http_code}' "$url/install/")
[[ $code == 403 || $code == 30? ]] || e2e_die "GET /install/: expected 403 or redirect, got $code"
if grep -q -e 'Install Wavelog' -e 'Install | Wavelog' "$E2E_TMP/install.html"; then
  e2e_die "GET /install/ served the installer"
fi
printf 'ok: installer locked (%s)\n' "$code" >&2

login_ok "$url"

# shellcheck disable=SC2016 # PHP code
expected_version=$(k exec "$pod" -c wavelog -- php -r \
  'define("BASEPATH", 1); define("APPPATH", ""); include "/var/www/html/application/config/migration.php"; echo $config["migration_version"];')
assert_eq "$expected_version" "$(e2e_sql "SELECT MAX(version) FROM migrations")" "schema at migration_version"
# The wizard's last step loads DXCC data; bootstrap must too, or station
# DXCC can't be chosen and callsigns can't be resolved to countries.
prefixes=$(e2e_sql "SELECT COUNT(*) FROM dxcc_prefixes")
[[ $prefixes -gt 1000 ]] || e2e_die "DXCC data not loaded on install ($prefixes prefixes)"
printf 'ok: DXCC data loaded (%s prefixes)\n' "$prefixes" >&2
# Other reference data Wavelog's cron would only load on its first scheduled run.
for t in vuccgrids lotw_users sota_directory wwff_directory pota_directory; do
  n=$(e2e_sql "SELECT COUNT(*) FROM $t")
  [[ $n -gt 0 ]] || e2e_die "reference table $t empty after install"
done
printf 'ok: reference tables seeded\n' >&2
updates_present() {
  k exec "$(e2e_wavelog_pod)" -c wavelog -- sh -c \
    'test -s /var/www/html/updates/clublog_scp.txt && test -s /var/www/html/updates/dok.txt'
}
updates_present || e2e_die "reference files missing from updates/"
printf 'ok: reference files downloaded\n' >&2
assert_eq "1 pending" "$(e2e_sql "SELECT CONCAT(enabled, ' ', status) FROM cron WHERE id='vucc_grid_file'")" \
  "cron.enableJobs enabled vucc_grid_file"

# Generated secrets survive helm upgrade.
enc_before=$(secret_value "$E2E_FULLNAME-app" encryption-key)
db_before=$(secret_value "$E2E_FULLNAME-mariadb" mariadb-password)
e2e_upgrade -f "$VALUES"
assert_eq "$enc_before" "$(secret_value "$E2E_FULLNAME-app" encryption-key)" "encryption key unchanged by upgrade"
assert_eq "$db_before" "$(secret_value "$E2E_FULLNAME-mariadb" mariadb-password)" "DB password unchanged by upgrade"
url=$(e2e_url)
login_ok "$url"

# Restart: bootstrap is idempotent.
e2e_restart_wavelog
assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM users")" "still one user after restart"
updates_present || e2e_die "reference files lost on restart (updates/ not persisted)"
printf 'ok: reference files survived the restart\n' >&2
url=$(e2e_url)
login_ok "$url"

# Application log: a line written to today's log file (as Wavelog's Apache
# user would) must reach the logs sidecar's stdout.
probe="ERROR - e2e-log-probe-$RANDOM"
k exec "$(e2e_wavelog_pod)" -c wavelog -- su -s /bin/sh www-data -c \
  "echo '$probe' >> /var/www/html/application/logs/log-\$(date -u +%F).php"
for _ in $(seq 1 20); do
  k logs "$(e2e_wavelog_pod)" -c logs 2>/dev/null | grep -qF "$probe" && break
  sleep 1
done
k logs "$(e2e_wavelog_pod)" -c logs 2>/dev/null | grep -qF "$probe" ||
  e2e_die "logs sidecar did not stream '$probe'"
printf 'ok: application log streamed to the logs container\n' >&2

# Partial install: bootstrap must refuse and leave the database alone.
tables_before=$(e2e_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()")
e2e_sql "SET FOREIGN_KEY_CHECKS=0; DROP TABLE users"
pod=$(e2e_delete_wavelog_pod)
exit_code=""
for _ in $(seq 1 120); do
  exit_code=$(k get pod "$pod" -o jsonpath='{.status.initContainerStatuses[?(@.name=="bootstrap")].state.terminated.exitCode}')
  [[ -n $exit_code ]] || exit_code=$(k get pod "$pod" \
    -o jsonpath='{.status.initContainerStatuses[?(@.name=="bootstrap")].lastState.terminated.exitCode}')
  [[ -n $exit_code ]] && break
  sleep 2
done
[[ -n $exit_code && $exit_code != 0 ]] || e2e_die "bootstrap did not fail on a partial install (exit '$exit_code')"
printf 'ok: bootstrap exited %s on partial install\n' "$exit_code" >&2
logs=$(k logs "$pod" -c bootstrap 2>/dev/null; k logs "$pod" -c bootstrap --previous 2>/dev/null || true)
[[ $logs == *"partial install detected"* ]] || e2e_die "bootstrap logs lack 'partial install detected': $logs"
printf 'ok: partial install detected\n' >&2
assert_eq "$((tables_before - 1))" \
  "$(e2e_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()")" \
  "partial install left untouched"

e2e_uninstall
echo "PASS: $SCENARIO"
