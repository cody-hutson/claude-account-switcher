#!/bin/bash
# as-fake: recording
#
# Fake pgrep. Records the call, then matches the last argument (an extended
# regular expression, as with `pgrep -f`) against the arguments column of
# each row of $AS_FIXTURE_PS. Prints the matching PIDs; exits 0 if any row
# matched, else 1. AS_FAKE_PGREP_RC forces the exit code.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'pgrep (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
line="${0##*/}"
pattern=""
for arg; do
  pattern="$arg"
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"

table="${AS_FIXTURE_PS:-${AS_TEST_ROOT}/ps.txt}"
found=1
first=1
if [[ -f "$table" && -n "$pattern" ]]; then
  while IFS= read -r row || [[ -n "$row" ]]; do
    if [[ $first -eq 1 ]]; then first=0; continue; fi   # header
    row="${row#"${row%%[! ]*}"}"
    pid="${row%% *}"
    args="${row#* }"
    if [[ $args =~ $pattern ]]; then
      printf '%s\n' "$pid"
      found=0
    fi
  done < "$table"
fi

if [[ -n "${AS_FAKE_PGREP_RC:-}" ]]; then
  exit "$AS_FAKE_PGREP_RC"
fi
exit "$found"
