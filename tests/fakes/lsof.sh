#!/bin/bash
# as-fake: recording
#
# Fake lsof. Records the call and never reads any process's files. For
# `-p <pid>` it prints $AS_TEST_ROOT/lsof/<pid>.txt (lsof -Fn records,
# rendered from tests/fixtures/lsof/ by set_lsof_fixture) and exits 0; with
# no fixture for that PID it prints nothing and exits 1, as lsof does for a
# PID that has gone. A call without `-p <pid>` is refused with exit 99.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'lsof (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
log="${AS_TEST_ROOT}/calls.log"
line="${0##*/}"
pid=""
prev=""
for arg; do
  [[ "$prev" == "-p" ]] && pid="$arg"
  prev="$arg"
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

pid_re='^[0-9]+$'
if [[ ! $pid =~ $pid_re ]]; then
  printf 'lsof\tREFUSED\t%s\n' "$pid" >> "$log"
  printf 'lsof (fake): only -p <pid> is simulated\n' >&2
  exit 99
fi

fixture="${AS_TEST_ROOT}/lsof/${pid}.txt"
[[ -f "$fixture" ]] || exit 1
while IFS= read -r row || [[ -n "$row" ]]; do
  printf '%s\n' "$row"
done < "$fixture"
exit 0
