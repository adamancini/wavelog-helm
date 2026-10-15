#!/usr/bin/env bash
# Wizard mode: the web installer is served and stays available across restarts
# until it has written a config. The full click-through is a manual check.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SCENARIO=wizard

installer_served() {
  local url=$1 jar="$E2E_TMP/cookies"
  rm -f "$jar"
  # The installer redirects to itself until it has set its session cookie.
  assert_eq 200 "$(curl -s -L --max-redirs 5 -c "$jar" -b "$jar" -o "$E2E_TMP/install.html" \
    -w '%{http_code}' "$url/install/")" "GET /install/"
  grep -q 'Install | Wavelog' "$E2E_TMP/install.html" || e2e_die "GET /install/ is not the installer"
  grep -q 'welcome-tab' "$E2E_TMP/install.html" || e2e_die "installer welcome step missing"
  printf 'ok: installer served\n' >&2
}

e2e_install "$SCENARIO" -f "$E2E_DIR/values-wizard.yaml"
installer_served "$(e2e_url)"

e2e_restart_wavelog
installer_served "$(e2e_url)"

e2e_uninstall
echo "PASS: $SCENARIO"
