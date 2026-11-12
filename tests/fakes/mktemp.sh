#!/bin/bash
# as-fake: guarded-passthrough
#
# Fake mktemp. Guarded like the other write tools: records its arguments,
# refuses (exit 99) an absolute argument outside $AS_TEST_ROOT or one with a
# ".." component, then runs the real mktemp. macOS mktemp ignores TMPDIR
# when it is given no template, so a call without one gets a template under
# $AS_TEST_ROOT/tmp instead, and the file it creates stays inside the root.
# tests/lib.sh writes the real path in place of the placeholder.

set -u
real='__AS_REAL__'
if [[ -z "${AS_TEST_ROOT:-}" || ! -f "${AS_TEST_ROOT}/.as-test-root" ]]; then
  printf 'mktemp (fake): AS_TEST_ROOT is not a test root; refusing\n' >&2
  exit 98
fi
log="${AS_TEST_ROOT}/calls.log"
line="${0##*/}"
for arg; do
  arg="${arg//$'\t'/\\t}"
  line="${line}"$'\t'"${arg//$'\n'/\\n}"
done
printf '%s\n' "$line" >> "$log"

refuse() {
  printf 'mktemp\tREFUSED\t%s\n' "$1" >> "$log"
  printf 'mktemp (fake): refusing a path outside the test root: %s\n' "$1" >&2
  exit 99
}

template=0
prev=""
for arg; do
  case "$arg" in
    */../*|*/..|../*|..) refuse "$arg" ;;
    /dev/null) ;;
    "${AS_TEST_ROOT}"/?*) ;;
    /*) refuse "$arg" ;;
  esac
  case "$arg" in
    -*) ;;
    *) [[ "$prev" == "-t" ]] || template=1 ;;
  esac
  prev="$arg"
done

if [[ $template -eq 0 ]]; then
  [[ -d "${AS_TEST_ROOT}/tmp" ]] || { printf 'mktemp (fake): %s/tmp is missing\n' "$AS_TEST_ROOT" >&2; exit 1; }
  exec "$real" "$@" "${AS_TEST_ROOT}/tmp/tmp.XXXXXXXXXX"
fi
exec "$real" "$@"
