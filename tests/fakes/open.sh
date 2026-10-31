#!/bin/bash
# as-fake: recording
#
# Fake open. Records the call and launches nothing. With
# AS_FAKE_OPEN_SPAWNS_PID=<n>, a Claude main process with PID <n> (argv[0]
# the case's $AS_APP_BUNDLE/Contents/MacOS/Claude) joins the process table
# ($AS_FIXTURE_PS) and alive.txt; it carries the --user-data-dir argument
# passed to open unless AS_FAKE_OPEN_UDD=0. Exits 0.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'open (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
line="${0##*/}"
udd=""
for arg; do
  case "$arg" in
    --user-data-dir=*) udd="$arg" ;;
  esac
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"

pid="${AS_FAKE_OPEN_SPAWNS_PID:-}"
if [[ -n "$pid" ]]; then
  printf -v row '%5s %s' "$pid" "${AS_APP_BUNDLE:-/Applications/Claude.app}/Contents/MacOS/Claude"
  if [[ -n "$udd" && "${AS_FAKE_OPEN_UDD:-1}" != "0" ]]; then
    row="${row} ${udd}"
  fi
  printf '%s\n' "$row" >> "${AS_FIXTURE_PS:-${AS_TEST_ROOT}/ps.txt}"
  printf '%s\n' "$pid" >> "${AS_TEST_ROOT}/alive.txt"
fi
exit 0
