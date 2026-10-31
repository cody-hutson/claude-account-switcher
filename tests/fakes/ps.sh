#!/bin/bash
# as-fake: recording
#
# Fake ps. Records the call and prints the scenario's process table, the
# file named by $AS_FIXTURE_PS. The table is written the way
# `ps -axo pid,args` prints it, header line included; for `-o args` the PID
# column is dropped. Tests render it from tests/fixtures/ps/.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'ps (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"

# The column list is the argument after the one that ends in "o" (-o, -axo).
cols="pid,args"
prev=""
for arg; do
  case "$prev" in
    -*o) cols="$arg" ;;
  esac
  prev="$arg"
done

table="${AS_FIXTURE_PS:-${AS_TEST_ROOT}/ps.txt}"
[[ -f "$table" ]] || exit 0
while IFS= read -r row || [[ -n "$row" ]]; do
  if [[ "$cols" == "args" ]]; then
    row="${row#"${row%%[! ]*}"}"
    printf '%s\n' "${row#* }"
  else
    printf '%s\n' "$row"
  fi
done < "$table"
exit 0
