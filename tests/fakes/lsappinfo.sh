#!/bin/bash
# as-fake: recording
#
# Fake lsappinfo. Records the call and never talks to Launch Services, so no
# application is ever brought forward. The front application is a PID kept
# in $AS_TEST_ROOT/front.txt; until something writes it, it is
# $AS_FAKE_FRONT_PID (default 400, an application that is not Claude).
# An application's ASN here is ASN:0x0-0x<hex of PID + 0x1d000>, so a caller
# that reads a PID out of an ASN instead of asking `info` gets a wrong one.
#   front                     prints the front application's ASN WITH the
#                             trailing colon, as lsappinfo does
#   info -only pid <spec>     prints "pid"=<n> for ASN:0x0-0x<hex> (trailing
#                             colon or not) and for #<pid>; for anything else
#                             (an ASN whose colons were all deleted, say)
#                             prints nothing, as lsappinfo does; exits 0
#   setfront <spec>           puts $AS_FAKE_FRONT_AFTER_SETFRONT in front:
#                             "target" means the PID <spec> names, a number
#                             means that PID; unset or empty leaves the front
#                             unchanged. Exits $AS_FAKE_ACTIVATE_RC (default 0)
# Any other command (lsappinfo can also launch and kill applications) is
# refused with exit 99.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'lsappinfo (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
log="${AS_TEST_ROOT}/calls.log"
state="${AS_TEST_ROOT}/front.txt"
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

pid_re='^[0-9]+$'
asn_re='^ASN:0x0-0x([0-9a-f]+):?$'
offset=$((0x1d000))

front() {
  local p=""
  if [[ -f "$state" ]]; then
    IFS= read -r p < "$state" || :
  else
    p="${AS_FAKE_FRONT_PID:-400}"
  fi
  printf '%s' "$p"
}

# Prints the PID the application specifier $1 names, or nothing.
spec_pid() {
  local n
  if [[ "$1" =~ $asn_re ]]; then
    n=$((0x${BASH_REMATCH[1]} - offset))
    [[ $n -gt 1 ]] && printf '%s' "$n"
    return 0
  fi
  case "$1" in
    "#"*) n="${1#"#"}"; [[ $n =~ $pid_re && $n -gt 1 ]] && printf '%s' "$n" ;;
  esac
  return 0
}

case "${1:-}" in
  front)
    p="$(front)"
    [[ $p =~ $pid_re ]] || exit 0
    printf 'ASN:0x0-0x%x:\n' "$((p + offset))"
    exit 0
    ;;
  info)
    if [[ "${2:-}" != "-only" || "${3:-}" != "pid" || $# -ne 4 ]]; then
      printf 'lsappinfo\tREFUSED\tinfo\n' >> "$log"
      printf 'lsappinfo (fake): only info -only pid <spec> is simulated\n' >&2
      exit 99
    fi
    p="$(spec_pid "$4")"
    [[ -n "$p" ]] && printf '"pid"=%s\n' "$p"
    exit 0
    ;;
  setfront)
    target="$(spec_pid "${2:-}")"
    after="${AS_FAKE_FRONT_AFTER_SETFRONT:-}"
    [[ "$after" == "target" ]] && after="$target"
    if [[ -n "$after" && $after =~ $pid_re ]]; then
      printf '%s\n' "$after" > "$state"
    fi
    exit "${AS_FAKE_ACTIVATE_RC:-0}"
    ;;
  *)
    printf 'lsappinfo\tREFUSED\t%s\n' "${1:-}" >> "$log"
    printf 'lsappinfo (fake): only front, info -only pid and setfront are simulated\n' >&2
    exit 99
    ;;
esac
