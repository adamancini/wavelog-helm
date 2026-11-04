#!/usr/bin/env bash
# DXCache: the chart's DXCache logs in to two fake DX nodes, enriches their
# spots through Wavelog's own lookup API and serves them back to Wavelog's
# cluster page. Bootstrap wires dxcache_url and the loopback API key, keeps
# them stable across restarts, and on disable clears only its own URL.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCENARIO=dxcache
VALUES="$E2E_DIR/values-dxcache.yaml"
FAKE_NODES="$E2E_DIR/fake-dxnode.yaml"
CHART_URL="http://$E2E_FULLNAME-dxcache.wl-e2e-$SCENARIO.svc:3000"
FOREIGN_URL=https://dxc.example.org/dxcache
# Spots for all bands, max age 60 min, any spotter continent: the fake
# spotters (N0CALL-n) are in North America, and the default de filter is EU.
SPOTS_PATH=/index.php/dxcluster/spots/All/60/Any

secret_value() { k get secret "$1" -o go-template="{{index .data \"$2\"}}" | base64 -d; }

dxcache_url() { e2e_sql "SELECT option_value FROM options WHERE option_name='dxcache_url'"; }

key_count() {
  e2e_sql "SELECT COUNT(*) FROM api WHERE description='DXCache (managed by chart)' AND rights='r'"
}

e2e_namespace "$SCENARIO"
k apply -f "$FAKE_NODES" >/dev/null
e2e_install "$SCENARIO" -f "$VALUES"
k rollout status "deployment/$E2E_FULLNAME-dxcache" --timeout=300s >/dev/null
printf 'ok: %s-dxcache rolled out\n' "$E2E_FULLNAME" >&2

assert_eq "$CHART_URL" "$(dxcache_url)" "dxcache_url points at the chart's DXCache"
assert_eq 1 "$(key_count)" "one DXCache API key"

# Spots reach Wavelog only after DXCache resolved them through Wavelog's
# lookup API (unresolved spots are dropped), so any spot proves the loopback.
url=$(e2e_url)
jar="$E2E_TMP/cookies"
e2e_login "$url" "$(secret_value "$E2E_FULLNAME-app" admin-password)" "$jar"
spots=""
for _ in $(seq 1 24); do
  spots=$(curl -s -c "$jar" -b "$jar" "$url$SPOTS_PATH")
  k1abc=$(jq '[.[] | select(.spotted=="K1ABC")] | length' <<<"$spots" 2>/dev/null || echo x)
  ja=$(jq '[.[] | select(.spotted=="JA1XYZ")] | length' <<<"$spots" 2>/dev/null || echo 0)
  vk=$(jq '[.[] | select(.spotted=="VK2ABC")] | length' <<<"$spots" 2>/dev/null || echo 0)
  [[ $k1abc == 1 && $ja -ge 1 && $vk -ge 1 ]] && break
  sleep 5
done
e2e_log "spots: $(jq -c '[.[] | {spotted, spotter, frequency}]' <<<"$spots" 2>/dev/null || echo "$spots" | head -c 300)"
assert_eq 1 "$k1abc" "K1ABC spotted once, merged across both nodes"
[[ $ja -ge 1 ]] || e2e_die "JA1XYZ (node A) not in spots"
[[ $vk -ge 1 ]] || e2e_die "VK2ABC (node B) not in spots"
printf 'ok: spots from both nodes reach Wavelog\n' >&2

# Restart: bootstrap is idempotent.
e2e_restart_wavelog
assert_eq 1 "$(key_count)" "one DXCache API key after restart"
assert_eq "$CHART_URL" "$(dxcache_url)" "dxcache_url unchanged after restart"

# Disable clears the chart's own URL; a URL set by the operator is left alone.
e2e_upgrade -f "$VALUES" --set dxcache.enabled=false
assert_eq "" "$(dxcache_url)" "dxcache_url cleared on disable"
e2e_sql "UPDATE options SET option_value='$FOREIGN_URL' WHERE option_name='dxcache_url'"
e2e_restart_wavelog
assert_eq "$FOREIGN_URL" "$(dxcache_url)" "foreign dxcache_url kept"

e2e_uninstall
echo "PASS: $SCENARIO"
