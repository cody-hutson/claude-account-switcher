#!/usr/bin/env bash
# tests/t-01-detect.sh - which tag is running: `list` and detect_running_tag.
#
# Both read the same process table: tests/fixtures/ps/ps-three.txt holds a
# primary instance without --user-data-dir, then two tags with it, each path
# containing the space in "Application Support".
#
# The detect_running_tag cases were CHARACTERIZATION #9 and pinned the old
# behaviour: its `--user-data-dir=[^[:space:]]+` match stopped at that
# space, so the argument branch never matched a real profile path and the
# function fell back to the statusline marker, or to `primary` without one.
# The #9 rework (one exact matcher, unknown instead of a guess) flipped them
# to the corrected behaviour under the same case names: with several
# instances and no marker the source is `unknown`, and pgrep is gone.
# detect_running_tag is reached through `swap`; the observable is the
# Direction line of the handoff it writes. t-09-detect.sh covers the
# matcher itself.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

make_profiles() {
  /bin/mkdir -p "${AS_PROFILE_ROOT}/Claude" "${AS_PROFILE_ROOT}/Claude-tag-a" "${AS_PROFILE_ROOT}/Claude-tag-b"
}

# A swap scenario: the three-instance table, a graceful quit that leaves no
# Claude process, a handoff pointed at the scratch git fixture, and one old
# APP_SWAP row so the handoff's time window has a prior swap to read.
swap_scenario() {
  new_case
  make_profiles
  set_ps_fixture ps-three.txt ps-no-claude.txt
  export AS_FAKE_QUIT=graceful
  /bin/mkdir -p "$AS_STORE"
  printf 'version = 1\n\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT" > "${AS_STORE}/config.toml"
  printf '[2026-01-01T00:00:00Z] APP_SWAP target=tag-a udd=x first_launch=false mirror=no\n' > "${AS_STORE}/swap-history.log"
}

# Every git call named the scratch fixture with -C, and none was refused.
git_stayed_in_fixture() {
  local l n=0
  while IFS= read -r l; do
    n=$((n + 1))
    case "$l" in
      *$'\tREFUSED\t'*) printf '    git call refused: %s\n' "$l"; return 1 ;;
      "git"$'\t-C\t'"${TEST_GIT_ROOT}"$'\t'*) ;;
      *) printf '    git call outside the fixture: %s\n' "$l"; return 1 ;;
    esac
  done < <(calls_of git)
  [[ $n -gt 0 ]] || { printf '    expected git calls against the fixture\n'; return 1; }
}

case_list_labels() {
  local primary tag_a tag_b profile_row
  new_case
  make_profiles
  set_ps_fixture ps-three.txt
  run_switcher list
  printf -v primary '  PID %-7s tag=%-12s via=%-8s data-dir=%s' 501 primary flagless "${AS_PROFILE_ROOT}/Claude"
  printf -v tag_a '  PID %-7s tag=%-12s via=%-8s data-dir=%s' 502 tag-a argv "${AS_PROFILE_ROOT}/Claude-tag-a"
  printf -v tag_b '  PID %-7s tag=%-12s via=%-8s data-dir=%s' 503 tag-b argv "${AS_PROFILE_ROOT}/Claude-tag-b"
  printf -v profile_row '  %-12s %s  (' tag-a "${AS_PROFILE_ROOT}/Claude-tag-a"
  assert_rc 0 &&
    assert_contains "$out" "$primary" &&
    assert_contains "$out" "$tag_a" &&
    assert_contains "$out" "$tag_b" &&
    assert_eq "$(count_lines "$(printf '%s\n' "$out" | /usr/bin/grep '^  PID ')")" "3" "instance rows" &&
    assert_contains "$out" "$profile_row" &&
    assert_called ps $'\t-axww\t-o\tpid=,args='
  result "list labels primary (no flag, via=flagless), tag-a and tag-b (via=argv), path with a space intact" $?
}

case_detect_no_marker() {
  swap_scenario
  run_switcher swap tag-b --no-mirror
  local handoff="${AS_STORE}/SWAP_HANDOFF.md" body=""
  [[ -f "$handoff" ]] && body="$(< "$handoff")"
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `unknown` → `tag-b`' &&
    assert_not_contains "$body" '- **Direction:** `primary`' &&
    assert_contains "$body" "- Active worktree: \`${TEST_GIT_ROOT}\`" &&
    git_stayed_in_fixture &&
    assert_called osascript $'-e\ttell application "Claude" to quit' &&
    assert_called open "--user-data-dir=${AS_PROFILE_ROOT}/Claude-tag-b" &&
    assert_not_contains "$(calls_of kill)" "STRAY" &&
    assert_never_called pgrep &&
    assert_eq "$(< "${AS_STORE}/.statusline-marker")" "tag-b" "marker after swap"
  result "#9 (was CHARACTERIZATION 'primary'): three instances, no marker -> source reads 'unknown'" $?
}

case_detect_marker() {
  swap_scenario
  printf 'tag-a\n' > "${AS_STORE}/.statusline-marker"
  run_switcher swap tag-b --no-mirror
  local handoff="${AS_STORE}/SWAP_HANDOFF.md" body=""
  [[ -f "$handoff" ]] && body="$(< "$handoff")"
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `tag-a` → `tag-b`' &&
    assert_never_called pgrep &&
    git_stayed_in_fixture
  result "#9 (was CHARACTERIZATION): several instances, the marker names a running tag -> source is the marker value, no pgrep" $?
}

case_list_labels
case_detect_no_marker
case_detect_marker
finish
