# shellcheck shell=bash
# Shared helpers for the end-to-end scenarios. Source from a scenario script:
#   . "$(dirname "$0")/lib.sh"
#
# Requires E2E_KUBE_CONTEXT; every kubectl/helm call is pinned to it. Only
# throwaway clusters (colima, kind-*) are accepted.

set -euo pipefail

E2E_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
E2E_CHART="$E2E_DIR/../../charts/wavelog"
E2E_RELEASE=${E2E_RELEASE:-wl}
E2E_FULLNAME="$E2E_RELEASE-wavelog"
E2E_NS=""
E2E_TMP=$(mktemp -d)

e2e_log() { printf '==> %s\n' "$*" >&2; }
e2e_die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ -z ${E2E_KUBE_CONTEXT:-} ]]; then
  e2e_die "E2E_KUBE_CONTEXT is not set"
fi
if [[ ! $E2E_KUBE_CONTEXT =~ ^(colima|kind-.*)$ ]]; then
  e2e_die "refusing kube context '$E2E_KUBE_CONTEXT' (allowed: colima, kind-*)"
fi

k() { kubectl --context "$E2E_KUBE_CONTEXT" -n "$E2E_NS" "$@"; }
h() { helm --kube-context "$E2E_KUBE_CONTEXT" -n "$E2E_NS" "$@"; }

e2e_cleanup() {
  local pidfile
  for pidfile in "$E2E_TMP"/*.pid; do
    [[ -f $pidfile ]] && kill "$(cat "$pidfile")" 2>/dev/null || true
  done
  rm -rf "$E2E_TMP"
}
trap e2e_cleanup EXIT

# e2e_namespace <scenario>: (re)create a clean namespace wl-e2e-<scenario>.
e2e_namespace() {
  E2E_NS="wl-e2e-$1"
  if kubectl --context "$E2E_KUBE_CONTEXT" get namespace "$E2E_NS" >/dev/null 2>&1; then
    e2e_log "deleting leftover namespace $E2E_NS"
    kubectl --context "$E2E_KUBE_CONTEXT" delete namespace "$E2E_NS" --wait=true --timeout=5m >/dev/null
  fi
  kubectl --context "$E2E_KUBE_CONTEXT" create namespace "$E2E_NS" >/dev/null
}

# e2e_install <scenario> [helm args]: install the chart into wl-e2e-<scenario>.
# Reuses the namespace if e2e_namespace already created it for this scenario.
e2e_install() {
  local scenario=$1
  shift
  [[ $E2E_NS == "wl-e2e-$scenario" ]] || e2e_namespace "$scenario"
  e2e_log "helm install $E2E_RELEASE into $E2E_NS"
  h install "$E2E_RELEASE" "$E2E_CHART" --wait --timeout 10m "$@"
}

# e2e_upgrade [helm args]: helm upgrade the scenario's release in place.
e2e_upgrade() {
  e2e_log "helm upgrade $E2E_RELEASE in $E2E_NS"
  h upgrade "$E2E_RELEASE" "$E2E_CHART" --wait --timeout 10m "$@"
}

e2e_uninstall() {
  e2e_log "uninstalling $E2E_RELEASE and deleting $E2E_NS"
  h uninstall "$E2E_RELEASE" --wait --timeout 5m >/dev/null || true
  kubectl --context "$E2E_KUBE_CONTEXT" delete namespace "$E2E_NS" --wait=true --timeout=5m >/dev/null
}

# e2e_url: port-forward the Service and echo the base URL. Call again after a
# pod restart; the previous forward is replaced.
e2e_url() {
  local log="$E2E_TMP/port-forward.log" pidfile="$E2E_TMP/port-forward.pid" port=""
  if [[ -f $pidfile ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
  : >"$log"
  k port-forward "svc/$E2E_FULLNAME" :80 >"$log" 2>&1 </dev/null &
  echo $! >"$pidfile"
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$log" | head -n1)
    [[ -n $port ]] && break
    sleep 1
  done
  [[ -n $port ]] || e2e_die "port-forward did not start: $(cat "$log")"
  echo "http://127.0.0.1:$port"
}

e2e_wavelog_pod() {
  k get pod -l app.kubernetes.io/instance="$E2E_RELEASE",app.kubernetes.io/component=wavelog \
    -o jsonpath='{.items[0].metadata.name}'
}

e2e_mariadb_pod() {
  k get pod -l app.kubernetes.io/instance="$E2E_RELEASE",app.kubernetes.io/component=mariadb \
    -o jsonpath='{.items[0].metadata.name}'
}

# e2e_sql "<query>": run a query as root on the bundled MariaDB; tab-separated, no header.
e2e_sql() {
  # shellcheck disable=SC2016 # expanded inside the container
  k exec "$(e2e_mariadb_pod)" -c mariadb -- sh -c \
    'mariadb -N -B -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" -e "$1"' sh "$1"
}

assert_eq() {
  local expected=$1 actual=$2 msg=$3
  if [[ $expected != "$actual" ]]; then
    e2e_die "$msg: expected '$expected', got '$actual'"
  fi
  printf 'ok: %s\n' "$msg" >&2
}

# assert_http <code> <url> [curl args]
assert_http() {
  local expected=$1 url=$2 code
  shift 2
  code=$(curl -s -o /dev/null -w '%{http_code}' "$@" "$url")
  assert_eq "$expected" "$code" "HTTP $url"
}

# e2e_delete_wavelog_pod: delete the Wavelog pod and wait for a replacement to exist.
e2e_delete_wavelog_pod() {
  local old new=""
  old=$(e2e_wavelog_pod)
  k delete pod "$old" --wait=true --timeout=5m >/dev/null
  for _ in $(seq 1 60); do
    new=$(e2e_wavelog_pod 2>/dev/null || true)
    [[ -n $new && $new != "$old" ]] && break
    sleep 2
  done
  [[ -n $new && $new != "$old" ]] || e2e_die "no replacement for pod $old"
  echo "$new"
}

# e2e_restart_wavelog: delete the Wavelog pod and wait until the new one is Ready.
e2e_restart_wavelog() {
  local pod
  pod=$(e2e_delete_wavelog_pod)
  e2e_log "waiting for $pod to become Ready"
  k wait --for=condition=Ready "pod/$pod" --timeout=10m >/dev/null
}
