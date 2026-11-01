#!/usr/bin/env bash
# tests/run.sh - entry point for the T1 simulated suite. See tests/README.md.
#
#   bash tests/run.sh                     the checks below, then every tests/t-*.sh
#   bash tests/run.sh t-05-install-check  the checks, then the named file(s) only
#   bash tests/run.sh --check-defaults    only: every seam default is an executable file
#
# The checks: /bin/bash -n on every script; the seam-coverage lint (no
# absolute command path outside the seam block, one default line per
# AS_SEAM_BINS name), each with a control that proves it can fail; and the
# default-path check. Exit status: 0 all passed, 1 a case failed, 2 a
# harness error. CI runs this under the system /bin/bash 3.2.

set -uo pipefail

# Captured before anything can replace HOME; every case's HOME is checked
# against it (tests/lib.sh).
TEST_REAL_HOME="${HOME:-}"
export TEST_REAL_HOME

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh" || exit 2

usage() {
  printf 'Usage: bash tests/run.sh [--check-defaults] [t-NN-slug ...]\n'
}

check_parse() {
  local f
  for f in "$SWITCHER" "${REPO}/install.sh" "${LIB_DIR}/run.sh" "${LIB_DIR}/lib.sh" \
           "${LIB_DIR}"/fakes/*.sh "${LIB_DIR}"/t-*.sh; do
    out="$(/bin/bash -n "$f" 2>&1)"
    rc=$?
    err=""
    result "/bin/bash -n ${f#"$REPO"/}" "$rc"
  done
}

check_lint() {
  local report count ok probe
  report="$(seam_lint)"
  rc=$?
  out="$report"
  err=""
  count="${report##*count }"
  ok=1
  [[ $rc -eq 0 && "$report" == *"count "* && "$count" == "0" ]] && ok=0
  result "seam lint: no absolute bin, sbin or libexec path outside the seam block" "$ok"

  # Control: the same lint over a copy with three planted bare paths (and two
  # lines it must not count) reports exactly 3.
  new_sibling_dir
  probe="${SIBLING_DIR}/account-switcher.sh"
  /bin/cp "$SWITCHER" "$probe" || harness_error "cannot copy the script for the lint control"
  {
    printf '%s\n' '  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist"'
    printf '%s\n' '  n=$(/usr/sbin/sysctl -n hw.ncpu)'
    printf '%s\n' '  /usr/local/bin/gh --version | "$AS_BIN_HEAD" -1'
    printf '%s\n' '  # /usr/bin/true in a comment is not counted'
    printf '%s\n' '  "$AS_BIN_CAT" /dev/null'
  } >> "$probe"
  report="$(seam_lint "$probe")"
  rc=$?
  out="$report"
  count="${report##*count }"
  ok=1
  [[ $rc -eq 0 && "$count" == "3" ]] && ok=0
  result "seam lint control: three planted bare paths are counted" "$ok"
}

check_default_counts() {
  local counts n_lines n_words ok probe
  counts="$(seam_default_counts)"
  n_lines="${counts%% *}"
  n_words="${counts##* }"
  out="default lines ${n_lines}, AS_SEAM_BINS names ${n_words}"
  err=""
  rc=0
  ok=1
  [[ "$n_words" -gt 0 && "$n_lines" == "$n_words" ]] && ok=0
  result "seam lint: one AS_BIN_ default line per AS_SEAM_BINS name (${n_lines} = ${n_words})" "$ok"

  # Control: a default line for a name missing from AS_SEAM_BINS is caught.
  new_sibling_dir
  probe="${SIBLING_DIR}/account-switcher.sh"
  /bin/cp "$SWITCHER" "$probe" || harness_error "cannot copy the script for the count control"
  printf '%s\n' ': "${AS_BIN_PLANTED:=/usr/bin/true}"' >> "$probe"
  counts="$(seam_default_counts "$probe")"
  out="control: ${counts}"
  ok=1
  [[ "${counts%% *}" != "${counts##* }" ]] && ok=0
  result "seam lint control: a default line without an AS_SEAM_BINS name is caught" "$ok"
}

check_defaults() {
  local name path n=0 missing=""
  while read -r name path; do
    n=$((n + 1))
    [[ -f "$path" && -x "$path" ]] || missing="${missing} ${name}=${path}"
  done < <(seam_defaults)
  out="checked ${n} defaults; not an executable file:${missing:- none}"
  err=""
  rc=0
  [[ $n -gt 0 && -z "$missing" ]]
  result "check-defaults: every AS_BIN_ default (${n}) is an executable file" $?
}

# ---- Arguments ---------------------------------------------------------------

only_defaults=0
files=""
for arg; do
  case "$arg" in
    --check-defaults) only_defaults=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *)
      name="${arg##*/}"
      name="${name%.sh}"
      [[ -f "${LIB_DIR}/${name}.sh" && "$name" == t-* ]] || { printf 'No such test file: %s\n' "$arg" >&2; exit 2; }
      files="${files}${LIB_DIR}/${name}.sh"$'\n'
      ;;
  esac
done

if [[ $only_defaults -eq 1 ]]; then
  check_defaults
  finish
fi

if [[ -z "$files" ]]; then
  for f in "${LIB_DIR}"/t-*.sh; do
    [[ -f "$f" ]] && files="${files}${f}"$'\n'
  done
fi

printf '== checks\n'
check_parse
check_lint
check_default_counts
check_defaults

# ---- Test files ----------------------------------------------------------------

new_sibling_dir
TEST_RESULTS="${SIBLING_DIR}/results.txt"
: > "$TEST_RESULTS"
export TEST_RESULTS
harness=0
total_pass=$pass
total_fail=$fail

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  name="${f##*/}"
  name="${name%.sh}"
  printf '\n== %s\n' "$name"
  /bin/bash "$f"
  frc=$?
  line=""
  while IFS= read -r l; do
    [[ "${l%% *}" == "$name" ]] && line="$l"
  done < "$TEST_RESULTS"
  if [[ $frc -gt 1 || -z "$line" ]]; then
    printf 'HARNESS ERROR: %s exited %s without a result line\n' "$name" "$frc" >&2
    harness=1
    continue
  fi
  set -- $line
  total_pass=$((total_pass + $2))
  total_fail=$((total_fail + $3))
done <<< "$files"

printf '\nT1 suite: %d passed, %d failed, %d cases\n' "$total_pass" "$total_fail" "$((total_pass + total_fail))"
cleanup_cases
if [[ $harness -ne 0 ]]; then exit 2; fi
if [[ $total_fail -ne 0 ]]; then exit 1; fi
exit 0
