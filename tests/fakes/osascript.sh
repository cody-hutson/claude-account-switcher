#!/bin/bash
# as-fake: recording
#
# Fake osascript. Records the call and runs no script. It tells the calls
# apart by their arguments:
#   the quit script (an -e argument ending "to quit")
#       With AS_FAKE_QUIT=graceful every app quits: alive.txt is emptied and
#       the process table ($AS_FIXTURE_PS) is replaced by
#       $AS_FIXTURE_PS_AFTER_QUIT. Otherwise nothing changes.
#   the AppKit activation (-l JavaScript, a script naming NSRunningApplication)
#       Records "osascript<TAB>ACTIVATE<TAB>appkit<TAB><pid>" (the PID is the
#       last argument) and puts $AS_FAKE_FRONT_AFTER_APPKIT in front.
#   the System Events activation (an -e argument naming System Events)
#       Records "osascript<TAB>ACTIVATE<TAB>system-events<TAB><pid>" and puts
#       $AS_FAKE_FRONT_AFTER_SYSEVENTS in front.
# "In front" is the PID in $AS_TEST_ROOT/front.txt, which the lsappinfo fake
# reads: "target" means the PID the call named, a number means that PID, and
# unset or empty leaves the front unchanged. An activation exits
# $AS_FAKE_ACTIVATE_RC (default 0); every other call exits 0.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'osascript (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
log="${AS_TEST_ROOT}/calls.log"
line="${0##*/}"
kind=""
lang=""
last=""
prev=""
for arg; do
  case "$prev|$arg" in
    "-l|JavaScript") lang="js" ;;
    "-e|"*" to quit") kind="quit" ;;
    "-e|"*"System Events"*) kind="system-events" ;;
    "-e|"*NSRunningApplication*) [[ "$lang" == "js" ]] && kind="appkit" ;;
  esac
  prev="$arg"
  last="$arg"
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

pid_re='^[0-9]+$'

# activate <rung> <value of its AS_FAKE_FRONT_AFTER_* variable>
activate() {
  local after="$2"
  [[ $last =~ $pid_re ]] || last=""
  printf 'osascript\tACTIVATE\t%s\t%s\n' "$1" "$last" >> "$log"
  [[ "$after" == "target" ]] && after="$last"
  if [[ -n "$after" && $after =~ $pid_re ]]; then
    printf '%s\n' "$after" > "${AS_TEST_ROOT}/front.txt"
  fi
  exit "${AS_FAKE_ACTIVATE_RC:-0}"
}

case "$kind" in
  appkit)        activate appkit "${AS_FAKE_FRONT_AFTER_APPKIT:-}" ;;
  system-events) activate system-events "${AS_FAKE_FRONT_AFTER_SYSEVENTS:-}" ;;
esac

if [[ "$kind" == "quit" && "${AS_FAKE_QUIT:-}" == "graceful" ]]; then
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
