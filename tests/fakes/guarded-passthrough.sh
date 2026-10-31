#!/bin/bash
# as-fake: guarded-passthrough
#
# Write-tool fake (rm, mv, cp, rsync, chmod, install, and git; mktemp has
# its own template, mktemp.sh, with the same guard).
# Records its arguments, refuses (exit 99) when any absolute argument lies
# outside $AS_TEST_ROOT or any argument has a ".." path component, and
# otherwise runs the real binary. /dev/null is the one absolute path allowed
# outside the root. A bug that computed a real path is stopped here, before
# anything is written. tests/lib.sh writes the real path in place of the
# placeholder when it copies this template.

set -u
real='__AS_REAL__'
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf '%s (fake): AS_TEST_ROOT is not a test root; refusing\n' "${0##*/}" >&2
  exit 98
fi
name="${0##*/}"
log="${AS_TEST_ROOT}/calls.log"
line="$name"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

refuse() {
  printf '%s\tREFUSED\t%s\n' "$name" "$1" >> "$log"
  printf '%s (fake): refusing a path outside the test root: %s\n' "$name" "$1" >&2
  exit 99
}

for arg; do
  case "$arg" in
    */../*|*/..|../*|..) refuse "$arg" ;;
    /dev/null) ;;
    "${AS_TEST_ROOT}"/?*) ;;
    /*) refuse "$arg" ;;
  esac
done

exec "$real" "$@"
