#!/bin/bash
# as-fake: recording
#
# Fake kill. Records the call and never signals anything. A PID is alive
# when it is listed in $AS_TEST_ROOT/alive.txt.
#   kill -0 <pid>              exit 0 if alive, else 1
#   kill -<SIG> <pid> | <pid>  alive: exit 0, and the PID leaves alive.txt
#                              unless AS_FAKE_KILL_EFFECTIVE=0
#                              not alive: records STRAY and exits 99, so a
#                              PID the scenario did not list is never signalled

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'kill (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
log="${AS_TEST_ROOT}/calls.log"
alive="${AS_TEST_ROOT}/alive.txt"
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

is_alive() {
  local p
  [[ -f "$alive" ]] || return 1
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ "$p" == "$1" ]] && return 0
  done < "$alive"
  return 1
}

forget() {
  local p rest=""
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -z "$p" || "$p" == "$1" ]] && continue
    rest="${rest}${p}"$'\n'
  done < "$alive"
  printf '%s' "$rest" > "$alive"
}

sig="TERM"
case "${1:-}" in
  -*) sig="${1#-}"; shift ;;
esac
pid_re='^[0-9]+$'
[[ $# -gt 0 ]] || { printf 'kill (fake): no PID given\n' >&2; exit 2; }
for pid; do
  if [[ ! $pid =~ $pid_re ]]; then
    printf 'kill (fake): not a PID: %s\n' "$pid" >&2
    exit 2
  fi
done

if [[ "$sig" == "0" ]]; then
  for pid; do
    is_alive "$pid" || exit 1
  done
  exit 0
fi

for pid; do
  if ! is_alive "$pid"; then
    printf 'kill\tSTRAY\t%s\n' "$pid" >> "$log"
    printf 'kill (fake): PID %s is not in the scenario; refusing\n' "$pid" >&2
    exit 99
  fi
done
if [[ "${AS_FAKE_KILL_EFFECTIVE:-1}" != "0" ]]; then
  for pid; do
    forget "$pid"
  done
fi
exit 0
