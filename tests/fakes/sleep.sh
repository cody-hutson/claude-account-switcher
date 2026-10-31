#!/bin/bash
# as-fake: recording
#
# Fake sleep. Records the call (its argument is the number of seconds) and
# returns at once. Every wait in the script counts polls rather than reading
# the clock, and every fake changes state on a call, never with time, so no
# case needs the time to pass: a quit's 15 one-second waits, an identity
# read's retry and launch's 0.5 s polls for the new instance all run at full
# count without sleeping. t-06-identity.sh replaces this per case with a
# sleep that also finishes a torn config.json write.

set -u
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'sleep (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
exit 0
