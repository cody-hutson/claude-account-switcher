#!/bin/bash
# as-fake: recording
#
# Fake osascript. Records the call and runs no script. With
# AS_FAKE_QUIT=graceful every app quits: alive.txt is emptied and the process
# table ($AS_FIXTURE_PS) is replaced by $AS_FIXTURE_PS_AFTER_QUIT. Otherwise
# nothing changes. Exits 0.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'osascript (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"

if [[ "${AS_FAKE_QUIT:-}" == "graceful" ]]; then
  : > "${AS_TEST_ROOT}/alive.txt"
  table="${AS_FIXTURE_PS:-${AS_TEST_ROOT}/ps.txt}"
  after="${AS_FIXTURE_PS_AFTER_QUIT:-}"
  rows=""
  if [[ -n "$after" && -f "$after" ]]; then
    while IFS= read -r row || [[ -n "$row" ]]; do
      rows="${rows}${row}"$'\n'
    done < "$after"
  fi
  printf '%s' "$rows" > "$table"
fi
exit 0
