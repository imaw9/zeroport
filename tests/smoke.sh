#!/usr/bin/env bash
# Smoke tests that need neither root nor a server.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

failures=0
check() {
  local name="$1"; shift
  if "$@"; then printf 'ok   %s\n' "$name"; else printf 'FAIL %s\n' "$name"; failures=$((failures + 1)); fi
}
exit_code() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

bash -n zeroport.sh
check "help lists commands" grep -q 'lockdown' <<<"$(bash zeroport.sh --help)"
check "version" grep -Eq '^zeroport [0-9]+\.[0-9]+\.[0-9]+$' <<<"$(bash zeroport.sh --version)"
check "no command exits 2" test "$(exit_code bash zeroport.sh)" = 2
check "unknown argument exits 2" test "$(exit_code bash zeroport.sh audit --nope)" = 2
check "unknown step exits 2" test "$(exit_code bash zeroport.sh bootstrap --only=docker)" = 2
check "bad swap size exits 2" test "$(exit_code bash zeroport.sh bootstrap --swap-size=lots)" = 2
check "two commands exit 2" test "$(exit_code bash zeroport.sh audit lockdown)" = 2

# shellcheck source=zeroport.sh
source zeroport.sh
for ip in 100.64.0.1 100.101.2.3 100.127.255.254 fd7a:115c:a1e0::1 FD7A:115C:A1E0:ab::2; do
  check "tailscale address ${ip}" is_tailscale_ip "$ip"
done
not_tailscale() { ! is_tailscale_ip "$1"; }
for ip in 100.63.255.255 100.128.0.1 10.0.0.1 107.175.238.143 2001:db8::1 fd7a:115d::1; do
  check "not tailscale ${ip}" not_tailscale "$ip"
done
# shellcheck disable=SC2034  # read by should_run
ONLY_STEPS="user,ssh"
check "should_run includes listed step" should_run ssh
skips() { ! should_run "$1"; }
check "should_run excludes other step" skips update

if ((failures)); then printf '\n%d failed\n' "$failures"; exit 1; fi
printf '\nall smoke tests passed\n'
