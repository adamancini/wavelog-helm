#!/usr/bin/env bash
# Declarative API keys: seeded from a Secret, idempotent across restarts,
# updated by upgrade, never deleted. Also checks that generated admin and
# MariaDB root passwords survive helm upgrade (no admin existingSecret here).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCENARIO=apikeys
VALUES="$E2E_DIR/values-apikeys.yaml"
API_KEY=wlE2Etestkey0001
MANUAL_KEY=wlE2Emanualkey01

secret_value() { k get secret "$1" -o go-template="{{index .data \"$2\"}}" | base64 -d; }

key_count() { e2e_sql "SELECT COUNT(*) FROM api WHERE \`key\`='$1'"; }

# login_ok <url> <password>: the admin can log in and reach the dashboard.
login_ok() {
  local url=$1 password=$2 jar="$E2E_TMP/cookies" location code
  rm -f "$jar"
  curl -s -o /dev/null -c "$jar" -b "$jar" "$url/index.php/user/login"
  location=$(curl -s -o /dev/null -w '%{redirect_url}' -c "$jar" -b "$jar" \
    --data-urlencode "user_name=admin" \
    --data-urlencode "user_password=$password" \
    "$url/index.php/user/login")
  [[ $location == */dashboard ]] || e2e_die "login POST redirected to '$location', not the dashboard"
  code=$(curl -s -o /dev/null -w '%{http_code}' -c "$jar" -b "$jar" "$url/index.php/dashboard")
  assert_eq 200 "$code" "dashboard after login"
}

post_qso() {
  local url=$1 call=$2 body code
  body=$(printf '{"key":"%s","station_profile_id":"1","type":"adif","string":"<call:5>%s<band:3>20m<mode:3>FT8<qso_date:8>20260101<time_on:6>120000<eor>"}' "$API_KEY" "$call")
  code=$(curl -s -o "$E2E_TMP/qso.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "$body" "$url/index.php/api/qso")
  [[ $code == 200 || $code == 201 ]] || e2e_die "POST /api/qso returned $code: $(cat "$E2E_TMP/qso.json")"
  grep -q '"status":"created"\|"status":"ok"' "$E2E_TMP/qso.json" \
    || e2e_die "POST /api/qso status not ok: $(cat "$E2E_TMP/qso.json")"
  printf 'ok: POST /api/qso accepted (%s)\n' "$code" >&2
}

e2e_namespace "$SCENARIO"
k create secret generic wl-apikey --from-literal=api-key="$API_KEY" >/dev/null
e2e_install "$SCENARIO" -f "$VALUES"

assert_eq 1 "$(key_count "$API_KEY")" "API key seeded once"
assert_eq "rw|active|e2e logger|1" \
  "$(e2e_sql "SELECT CONCAT_WS('|', rights, status, description, user_id) FROM api WHERE \`key\`='$API_KEY'")" \
  "API key row fields"
assert_eq "$(e2e_sql "SELECT user_id FROM users WHERE user_name='admin'")" \
  "$(e2e_sql "SELECT user_id FROM api WHERE \`key\`='$API_KEY'")" "key belongs to admin"
e2e_log "station profiles owned by the admin: $(e2e_sql "SELECT station_id FROM station_profile WHERE user_id=1" | tr '\n' ' ')"
assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM station_profile WHERE user_id=1 AND station_id=1")" \
  "station 1 is the admin's station"

url=$(e2e_url)
post_qso "$url" K1ABC
assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM TABLE_HRD_CONTACTS_V01 WHERE COL_CALL='K1ABC'")" "QSO stored"

# Restart: still exactly one row.
e2e_restart_wavelog
assert_eq 1 "$(key_count "$API_KEY")" "one API key row after restart"

# A key added by hand must survive; changed values update the row in place.
e2e_sql "INSERT INTO api (\`key\`, rights, status, description, user_id, created_by) VALUES ('$MANUAL_KEY', 'r', 'active', 'manual', 1, 1)"
admin_pw_before=$(secret_value "$E2E_FULLNAME-app" admin-password)
root_pw_before=$(secret_value "$E2E_FULLNAME-mariadb" mariadb-root-password)
[[ -n $admin_pw_before && -n $root_pw_before ]] || e2e_die "generated admin/root passwords missing"
e2e_upgrade -f "$VALUES" --set 'apiKeys[0].description=e2e logger updated'
assert_eq 1 "$(key_count "$API_KEY")" "one API key row after upgrade"
assert_eq "e2e logger updated" "$(e2e_sql "SELECT description FROM api WHERE \`key\`='$API_KEY'")" "description updated by upgrade"
assert_eq 1 "$(key_count "$MANUAL_KEY")" "manually inserted key survives upgrade"

# Generated secrets persist across upgrade and still work.
assert_eq "$admin_pw_before" "$(secret_value "$E2E_FULLNAME-app" admin-password)" "generated admin password unchanged by upgrade"
assert_eq "$root_pw_before" "$(secret_value "$E2E_FULLNAME-mariadb" mariadb-root-password)" "MariaDB root password unchanged by upgrade"
url=$(e2e_url)
login_ok "$url" "$admin_pw_before"
post_qso "$url" K2DEF

e2e_uninstall
echo "PASS: $SCENARIO"
