#!/bin/bash
# as-fake: passthrough
#
# Text-tool fake (awk, grep, sed, jq, ...). Records its arguments, then runs
# the real binary with them. tests/lib.sh copies this template to
# $AS_FAKES_DIR/<name> and writes the real path in place of the placeholder.
#
# Every fake appends one line to $AS_TEST_ROOT/calls.log: its own name, then
# each argument, tab-separated (an embedded tab or newline is written as \t
# or \n so the call stays on one line). A fake only uses builtins, so it
# never calls another fake.

set -u
real='__AS_REAL__'
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf '%s (fake): AS_TEST_ROOT is not a test root; refusing\n' "${0##*/}" >&2
  exit 98
fi
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"

exec "$real" "$@"
