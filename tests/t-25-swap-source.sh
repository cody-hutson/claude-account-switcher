#!/usr/bin/env bash
# tests/t-25-swap-source.sh - #25 item 1: the source `swap` records when no
# Claude instance is running.
#
# swap's handoff capture names the account it swaps from. With nothing
# running there is no source to read, and the switcher used to record
# `primary` as a nominal one. It now records `unknown`, the value it already
# uses when several instances run and none can be told apart. The
# statusline marker is set to `primary` in the first case, so a fallback to
# the marker would also show. The second case is the control: with one
# instance running, its tag is the source.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

# A case with the profile folders and the switcher's store, using the given
# process table for every read.
scenario() {
  new_case
  /bin/mkdir -p "${AS_PROFILE_ROOT}/Claude" "${AS_PROFILE_ROOT}/Claude-tag-a" \
    "${AS_PROFILE_ROOT}/Claude-tag-b" "$AS_STORE"
  set_ps_fixture "$1" ps-no-claude.txt
}

# swap tag-b --no-mirror with a graceful quit; the handoff's Direction line
# and history rows show the source it recorded.
swap_and_read_handoff() {
  printf 'version = 1\n\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT" > "${AS_STORE}/config.toml"
  export AS_FAKE_QUIT=graceful
  run_switcher swap tag-b --no-mirror
  body=""
  [[ -f "${AS_STORE}/SWAP_HANDOFF.md" ]] && body="$(< "${AS_STORE}/SWAP_HANDOFF.md")"
  history=""
  [[ -f "${AS_STORE}/swap-history.log" ]] && history="$(< "${AS_STORE}/swap-history.log")"
}

case_swap_source_nothing_running() {
  scenario ps-no-claude.txt
  printf 'primary\n' > "${AS_STORE}/.statusline-marker"
  swap_and_read_handoff
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `unknown` → `tag-b`' &&
    assert_contains "$history" "HANDOFF_CAPTURE source=unknown target=tag-b" &&
    assert_not_contains "$history" "source=primary" &&
    assert_not_contains "$body" '- **Direction:** `primary`'
  result "#25: swap with nothing running records the source as unknown, never primary (the marker says primary)" $?
}

case_swap_source_one_running() {
  scenario ps-one-tag.txt
  swap_and_read_handoff
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `tag-a` → `tag-b`' &&
    assert_contains "$history" "HANDOFF_CAPTURE source=tag-a target=tag-b"
  result "#25 control: swap with one instance running records that instance's tag as the source" $?
}

case_swap_source_nothing_running
case_swap_source_one_running
finish
