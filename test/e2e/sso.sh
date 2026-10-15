#!/usr/bin/env bash
# Header SSO: a JWT signed by the IdP key logs in as the install admin (linked
# declaratively by adminIdentity), a token signed by another key is rejected,
# no user is ever created, the link survives restarts, and bootstrap refuses
# to link an identity another user already holds.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCENARIO=sso
VALUES="$E2E_DIR/values-sso.yaml"
ISS=https://idp.example.test
SUB=e2e-subject-1
# json_encode(['iss' => $iss, 'sub' => $sub]) with default flags, as
# Header_auth builds it.
EXPECTED_ACCOUNT='{"iss":"https:\/\/idp.example.test","sub":"e2e-subject-1"}'
VENV="$E2E_DIR/.venv"
KEYS="$E2E_TMP/keys"
PROXY_ISSUER=http://jwks
API_KEY=wlE2Esidecarkey01

if [[ ! -x $VENV/bin/python ]]; then
  e2e_log "creating $VENV"
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -c 'import jwt, cryptography' 2>/dev/null \
  || "$VENV/bin/pip" install --quiet 'PyJWT[crypto]==2.10.1'
mint() { "$VENV/bin/python" "$E2E_DIR/mint_jwt.py" "$@"; }

# pod_url: port-forward straight to Apache (pod port 80) and echo the base URL.
pod_url() {
  local log="$E2E_TMP/pod-forward.log" pidfile="$E2E_TMP/pod-forward.pid" port=""
  if [[ -f $pidfile ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
  : >"$log"
  k port-forward "pod/$(e2e_wavelog_pod)" :80 >"$log" 2>&1 </dev/null &
  echo $! >"$pidfile"
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$log" | head -n1)
    [[ -n $port ]] && break
    sleep 1
  done
  [[ -n $port ]] || e2e_die "port-forward did not start: $(cat "$log")"
  echo "http://127.0.0.1:$port"
}

user_count() { e2e_sql "SELECT COUNT(*) FROM users"; }
# Hex of the stored bytes: the mariadb client escapes backslashes in batch output.
admin_account() { e2e_sql "SELECT HEX(external_account) FROM users WHERE user_name='admin'"; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr a-f A-F; }

# sso_login <url> <token>: send the header-auth login request; echo the
# redirect target. The cookie jar keeps the resulting session.
sso_login() {
  local url=$1 token=$2
  rm -f "$E2E_TMP/cookies"
  curl -s -o /dev/null -w '%{redirect_url}' -c "$E2E_TMP/cookies" -b "$E2E_TMP/cookies" \
    -H "X-Forwarded-Access-Token: $token" "$url/index.php/header_auth/login"
}

e2e_namespace "$SCENARIO"

mint keys "$KEYS"
# Discovery for the oauth2-proxy phase; the issuer must match issuerUrl exactly.
cat >"$KEYS/openid-configuration" <<EOF2
{"issuer":"$PROXY_ISSUER","authorization_endpoint":"$PROXY_ISSUER/authorize","token_endpoint":"$PROXY_ISSUER/token","jwks_uri":"$PROXY_ISSUER/jwks.json","response_types_supported":["code"],"subject_types_supported":["public"],"id_token_signing_alg_values_supported":["RS256"]}
EOF2
k create configmap jwks --from-file=jwks.json="$KEYS/jwks.json" \
  --from-file=openid-configuration="$KEYS/openid-configuration" >/dev/null
k apply -f "$E2E_DIR/jwks-server.yaml" >/dev/null
k wait --for=condition=Ready pod/jwks --timeout=5m >/dev/null

e2e_install "$SCENARIO" -f "$VALUES"
pod=$(e2e_wavelog_pod)
k logs "$pod" -c bootstrap >&2
assert_eq "$(hex "$EXPECTED_ACCOUNT")" "$(admin_account)" "admin external_account linked by bootstrap"
assert_eq 1 "$(user_count)" "one user after install"

url=$(pod_url)
assert_eq 200 "$(curl -s -o "$E2E_TMP/login.html" -w '%{http_code}' "$url/index.php/user/login")" "login page"
grep -q 'Login with SSO' "$E2E_TMP/login.html" || e2e_die "login page has no SSO button"
printf 'ok: login page offers SSO\n' >&2

# A token signed by the IdP key logs in as the admin.
location=$(sso_login "$url" "$(mint token "$KEYS/idp.pem" "$ISS" "$SUB")")
[[ $location == */dashboard ]] || e2e_die "SSO login redirected to '$location', not the dashboard"
printf 'ok: SSO login redirects to the dashboard\n' >&2
code=$(curl -s -o "$E2E_TMP/dashboard.html" -w '%{http_code}' -c "$E2E_TMP/cookies" -b "$E2E_TMP/cookies" \
  "$url/index.php/dashboard")
assert_eq 200 "$code" "dashboard after SSO login"
grep -q N0CALL "$E2E_TMP/dashboard.html" || e2e_die "dashboard does not show N0CALL"
printf 'ok: dashboard shows N0CALL\n' >&2
assert_eq 1 "$(user_count)" "SSO login created no user"
assert_eq admin "$(e2e_sql "SELECT user_name FROM users WHERE user_id=1")" "admin keeps its user name"

# A token signed by another key is rejected.
location=$(sso_login "$url" "$(mint token "$KEYS/other.pem" "$ISS" "$SUB")")
[[ $location == */user/login ]] || e2e_die "forged token redirected to '$location', not user/login"
code=$(curl -s -o /dev/null -w '%{http_code}' -c "$E2E_TMP/cookies" -b "$E2E_TMP/cookies" "$url/index.php/dashboard")
[[ $code != 200 ]] || e2e_die "dashboard served after a forged token"
printf 'ok: token signed by another key rejected\n' >&2
assert_eq 1 "$(user_count)" "forged token created no user"

# Restart: the link is re-applied unchanged.
e2e_restart_wavelog
assert_eq "$(hex "$EXPECTED_ACCOUNT")" "$(admin_account)" "external_account unchanged after restart"
assert_eq 1 "$(user_count)" "one user after restart"
url=$(pod_url)
location=$(sso_login "$url" "$(mint token "$KEYS/idp.pem" "$ISS" "$SUB")")
[[ $location == */dashboard ]] || e2e_die "SSO login after restart redirected to '$location'"
printf 'ok: SSO login after restart\n' >&2

# oauth2-proxy sidecar: the Service reaches the proxy, never Apache.
k create secret generic wl-apikey --from-literal=api-key="$API_KEY" >/dev/null
k create secret generic wl-oauth2-proxy --from-literal=client-id=wavelog \
  --from-literal=client-secret=e2e-client-secret \
  --from-literal=cookie-secret=0123456789abcdef0123456789abcdef >/dev/null
e2e_upgrade -f "$VALUES" -f "$E2E_DIR/values-sso-proxy.yaml"
assert_eq "proxy" "$(k get svc "$E2E_FULLNAME" -o jsonpath='{.spec.ports[0].targetPort}')" "Service targets the proxy port"
assert_eq 1 "$(k get svc "$E2E_FULLNAME" -o jsonpath='{.spec.ports[*].name}' | wc -w | tr -d ' ')" "Service has a single port"
url=$(e2e_url)
curl -s -o /dev/null -D "$E2E_TMP/headers" "$url/"
status=$(head -n1 "$E2E_TMP/headers" | tr -d '\r')
location=$(sed -n 's/^[Ll]ocation: *//p' "$E2E_TMP/headers" | tr -d '\r')
[[ $status == *" 302"* ]] || e2e_die "GET / through the proxy returned '$status', not a 302"
[[ $location == "$PROXY_ISSUER/authorize"* ]] || e2e_die "GET / redirected to '$location', not the issuer"
printf 'ok: GET / redirects to the issuer\n' >&2
body=$(printf '{"key":"%s","station_profile_id":"1","type":"adif","string":"<call:5>K3GHI<band:3>20m<mode:3>FT8<qso_date:8>20260101<time_on:6>120000<eor>"}' "$API_KEY")
code=$(curl -s -o "$E2E_TMP/qso.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$body" "$url/index.php/api/qso")
[[ $code == 200 || $code == 201 ]] || e2e_die "POST /api/qso through the proxy returned $code: $(cat "$E2E_TMP/qso.json")"
grep -q '"status":"created"\|"status":"ok"' "$E2E_TMP/qso.json" \
  || e2e_die "POST /api/qso through the proxy not ok: $(cat "$E2E_TMP/qso.json")"
printf 'ok: API QSO accepted through the proxy (%s)\n' "$code" >&2
assert_eq 1 "$(e2e_sql "SELECT COUNT(*) FROM TABLE_HRD_CONTACTS_V01 WHERE COL_CALL='K3GHI'")" "QSO stored via the proxy"

# The API skip route must not open a way around the proxy: traversal paths
# never reach the dashboard, and a client-supplied token header on a skipped
# route never logs anyone in.
admin_token=$(mint token "$KEYS/idp.pem" "$ISS" "$SUB")
for path in /index.php/api/../dashboard /index.php/api/%2e%2e/dashboard /index.php/api/..%2fdashboard \
  /index.php/api/%2e%2e%2fdashboard; do
  code=$(curl -s --path-as-is -o "$E2E_TMP/probe.html" -w '%{http_code}' "$url$path")
  e2e_log "unauthenticated GET $path -> $code"
  [[ $code != 200 ]] || e2e_die "GET $path returned 200 through the proxy"
  ! grep -q N0CALL "$E2E_TMP/probe.html" || e2e_die "GET $path served the dashboard"
done
printf 'ok: traversal paths do not bypass the proxy\n' >&2
for path in /index.php/api/../header_auth/login /index.php/api/%2e%2e/header_auth/login \
  /index.php/api/..%2fheader_auth/login /index.php/api/nonexistent; do
  rm -f "$E2E_TMP/cookies"
  curl -s --path-as-is -o /dev/null -w '%{http_code} %{redirect_url}\n' -c "$E2E_TMP/cookies" -b "$E2E_TMP/cookies" \
    -H "X-Forwarded-Access-Token: $admin_token" "$url$path" >"$E2E_TMP/probe.out"
  e2e_log "token GET $path -> $(cat "$E2E_TMP/probe.out")"
  ! grep -q '/dashboard' "$E2E_TMP/probe.out" || e2e_die "client token on $path logged in"
  code=$(curl -s --path-as-is -o "$E2E_TMP/probe.html" -w '%{http_code}' -c "$E2E_TMP/cookies" -b "$E2E_TMP/cookies" "$url/index.php/dashboard")
  [[ $code != 200 ]] || e2e_die "dashboard served after client token on $path"
done
printf 'ok: client-supplied token on skipped routes logs nobody in\n' >&2

# Another user holding the identity: bootstrap refuses to steal it.
# Non-strict mode fills the remaining NOT NULL columns with implicit defaults.
e2e_sql "UPDATE users SET external_account=NULL WHERE user_name='admin';
  SET SESSION sql_mode='';
  INSERT INTO users (user_name, user_password, user_email, user_type, user_callsign, user_locator,
    user_firstname, user_lastname, external_account)
  VALUES ('other', 'x', 'other@example.com', '3', 'N0OTH', 'AA00aa', '', '', '$EXPECTED_ACCOUNT')"
pod=$(e2e_delete_wavelog_pod)
logs=""
for _ in $(seq 1 120); do
  logs=$(k logs "$pod" -c bootstrap 2>/dev/null; k logs "$pod" -c bootstrap --previous 2>/dev/null || true)
  [[ $logs == *"SSO identity already linked to another user"* ]] && break
  sleep 2
done
[[ $logs == *"bootstrap: SSO identity already linked to another user"* ]] \
  || e2e_die "bootstrap did not refuse a taken identity: $logs"
printf 'ok: bootstrap refuses an identity linked to another user\n' >&2
assert_eq NULL "$(admin_account)" "admin left unlinked"

e2e_uninstall
echo "PASS: $SCENARIO"
