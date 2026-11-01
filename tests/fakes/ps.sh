#!/bin/bash
# as-fake: recording
#
# Fake ps. Records the call and prints the scenario's process table, the
# file named by $AS_FIXTURE_PS. The table is written the way
# `ps -axo pid,args` prints it, header line included; for `-o args` the PID
# column is dropped, and when every column name ends in "=" (`-o pid=,args=`)
# the header line is left out, as ps does. Tests render it from
# tests/fixtures/ps/. When $AS_TEST_ROOT/ps-next.txt is non-empty, it
# replaces the table after this call and is emptied, so the next call sees
# the changed list (set_ps_next_fixture).

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
no_header=1
rest="${cols},"
while [[ -n "$rest" ]]; do
  col="${rest%%,*}"
  rest="${rest#*,}"
  [[ "$col" == *= ]] || no_header=0
done

table="${AS_FIXTURE_PS:-${AS_TEST_ROOT}/ps.txt}"
[[ -f "$table" ]] || exit 0
first=1
while IFS= read -r row || [[ -n "$row" ]]; do
  if [[ $first -eq 1 ]]; then
    first=0
    [[ $no_header -eq 1 ]] && continue
  fi
  # A failed write (a reader that closed the pipe early) ends the fake with a
  # non-zero status, as a real ps would end, whether SIGPIPE is fatal or
  # ignored here (F-07): a pipeline that closes early then fails under
  # pipefail either way.
  if [[ "$cols" == "args" || "$cols" == "args=" ]]; then
    row="${row#"${row%%[! ]*}"}"
    printf '%s\n' "${row#* }" || exit 1
  else
    printf '%s\n' "$row" || exit 1
  fi
done < "$table"

next="${AS_TEST_ROOT}/ps-next.txt"
if [[ -s "$next" ]]; then
  rows=""
  while IFS= read -r row || [[ -n "$row" ]]; do
    rows="${rows}${row}"$'\n'
  done < "$next"
  printf '%s' "$rows" > "$table"
  : > "$next"
fi
exit 0
