#!/usr/bin/env bash
# tests/t-06-identity.sh - #6: the account each tag's profile records,
# checked against the account pinned to the tag.
#
# The switcher reads lastKnownAccountUuid from <profile>/config.json with jq
# and compares it with the tag's line in [identity] of config.toml. Fixture
# ids are generated here, at test time, and written under the scratch root
# only, so no committed file holds an id-shaped string. Every fixture
# config.json also holds placeholder strings under the two token-cache key
# names, and every case asserts that no output, history row or other file
# under the scratch root carries a placeholder or, unless the case passes
# --show-ids, an id-shaped string. The scan's control arm runs the same scan
# over a fixture config.json and requires it to find both.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

# Fixture id <n>: uuid-shaped, generated here, never committed.
fid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }
ID_A="$(fid 10)"     # pinned to tag-a; ends ...000a
ID_B="$(fid 11)"     # pinned to tag-b; ends ...000b
ID_P="$(fid 12)"     # pinned to primary
ID_X="$(fid 13)"     # pinned to no tag; ends ...000d

TOKEN_MARK="FIXTURE-NOT-A-TOKEN"
UUID_ERE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
DECOY_MARK="DECOY-PROFILE-CONTENT"

# ---- Scenario ----------------------------------------------------------------

profile_dir() {
  if [[ "$1" == "primary" ]]; then
    printf '%s' "${AS_PROFILE_ROOT}/Claude"
  else
    printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"
  fi
}

# Files the case wrote as the profile's input (exempt from the leak scan).
fixture() { FIXTURE_LIST="${FIXTURE_LIST}$1"$'\n'; }

is_fixture() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" && "$f" == "$1" ]] && return 0
  done <<< "$FIXTURE_LIST"
  return 1
}

# A case with the three profile folders, an empty process table, the store,
# a control fixture for the leak scan, and a sleep fake that records and
# returns at once (so the retry costs no time; see torn_sleep_fake).
scenario() {
  new_case
  FIXTURE_LIST=""
  /bin/mkdir -p "$AS_STORE" "$(profile_dir primary)" "$(profile_dir tag-a)" "$(profile_dir tag-b)" \
    "${AS_TEST_ROOT}/control" || harness_error "cannot create the profile folders"
  set_ps_fixture ps-no-claude.txt
  CONTROL_JSON="${AS_TEST_ROOT}/control/config.json"
  json_with "\"lastKnownAccountUuid\": \"${ID_X}\"" > "$CONTROL_JSON"
  fixture "$CONTROL_JSON"
  unset T6_NEXT T6_TARGET
  torn_sleep_fake
}

# A config.json body: two placeholder token caches around the given member.
json_with() {
  printf '{\n  "oauth:tokenCache": "%s-1",\n  %s,\n  "oauth:tokenCacheV2": "%s-2",\n  "windowSizeWasSignedIn": true\n}\n' \
    "$TOKEN_MARK" "$1" "$TOKEN_MARK"
}

# record <tag> <id>: the tag's profile records <id>.
record() {
  local f
  f="$(profile_dir "$1")/config.json"
  json_with "\"lastKnownAccountUuid\": \"$2\"" > "$f"
  fixture "$f"
}

# record_raw <tag> <text>: the tag's config.json holds exactly <text>.
record_raw() {
  local f
  f="$(profile_dir "$1")/config.json"
  printf '%s' "$2" > "$f"
  fixture "$f"
}

# A torn config.json: the app's write cut off inside the identity value.
torn_json() {
  printf '{\n  "oauth:tokenCache": "%s-1",\n  "lastKnownAccountUuid": "%s' "$TOKEN_MARK" "${1:0:20}"
}

# write_config [tag=id ...]: config.toml with primary, tag-a and tag-b in
# [accounts]; then [identity] with each pin given; then [swap_handoff],
# pointing git at the scratch fixture.
write_config() {
  local pin
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'primary = { label = "Primary" }\n'
    printf 'tag-a = { label = "Alpha" }\n'
    printf 'tag-b = { label = "Beta" }\n'
    printf '\n[identity]\n'
    for pin; do printf '%s = "%s"\n' "${pin%%=*}" "${pin#*=}"; done
    printf '\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT"
  } > "${AS_STORE}/config.toml"
}

# The same, without an [identity] table (an install from before #6).
write_config_no_identity() {
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'primary = { label = "Primary" }\n'
    printf 'tag-a = { label = "Alpha" }\n'
    printf 'tag-b = { label = "Beta" }\n'
    printf '\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT"
  } > "${AS_STORE}/config.toml"
}

# The case's sleep: records the call and returns at once. With T6_NEXT and
# T6_TARGET set, it stands in for the app finishing its write: it puts the
# whole file T6_NEXT where the torn T6_TARGET was. Builtins only.
torn_sleep_fake() {
  /bin/cat > "${AS_FAKES_DIR}/sleep" <<'FAKE'
#!/bin/bash
# as-fake: passthrough
line="sleep"
for arg; do line="${line}"$'\t'"${arg}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
if [[ -n "${T6_NEXT:-}" && -n "${T6_TARGET:-}" ]]; then
  while IFS= read -r l || [[ -n "$l" ]]; do printf '%s\n' "$l"; done < "$T6_NEXT" > "$T6_TARGET"
fi
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/sleep" || harness_error "cannot chmod the sleep fake"
}

# Appends the last run's stdout and stderr to the case transcript, which the
# leak scan reads along with every other file under the root.
keep_run() { printf '%s\n%s\n' "$out" "$err" >> "${AS_TEST_ROOT}/transcript.txt"; }

history_text() {
  if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi
}

# ---- Leak scan ---------------------------------------------------------------

# hits_in <token|ids> <path>: the files under <path> holding a placeholder
# token (any case) or a uuid-shaped string.
hits_in() {
  case "$1" in
    token) /usr/bin/grep -rlaiF -e "$TOKEN_MARK" -- "$2" 2> /dev/null ;;
    ids)   /usr/bin/grep -rlaE -e "$UUID_ERE" -- "$2" 2> /dev/null ;;
  esac
  return 0
}

# leaks <token|ids>: the hits under the case root, less the fixture
# config.json files the case wrote. For ids, config.toml is exempt as well:
# its [identity] table is where pins live, by design.
leaks() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    is_fixture "$f" && continue
    if [[ "$1" == "ids" && "$f" == "${AS_STORE}/config.toml" ]]; then continue; fi
    printf '%s\n' "$f"
  done < <(hits_in "$1" "$AS_TEST_ROOT")
}

# assert_no_leaks [show-ids]: no placeholder anywhere, and no id outside the
# exempt files (skipped for a case that passed --show-ids). Control arm: the
# same scans over the control fixture config.json must each find it.
assert_no_leaks() {
  local found
  [[ -n "$(hits_in token "$CONTROL_JSON")" ]] || { printf '    control: the token scan missed a fixture config.json\n'; return 1; }
  [[ -n "$(hits_in ids "$CONTROL_JSON")" ]] || { printf '    control: the id scan missed a fixture config.json\n'; return 1; }
  found="$(leaks token)"
  if [[ -n "$found" ]]; then printf '    placeholder token found in:\n%s\n' "$found"; return 1; fi
  if [[ "${1:-}" != "show-ids" ]]; then
    found="$(leaks ids)"
    if [[ -n "$found" ]]; then printf '    uuid-shaped string found in:\n%s\n' "$found"; return 1; fi
  fi
  return 0
}

# No uuid-shaped string in the text $1.
assert_no_id_text() {
  local re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
  if [[ "$1" =~ $re ]]; then printf '    %s holds a uuid-shaped string\n' "${2:-text}"; return 1; fi
  return 0
}

# Every logged call that names a path under the profile root is a jq read of
# a profile's config.json, or open's --user-data-dir (a folder, not a file);
# and at least one such read happened.
assert_profile_reads_config_only() {
  local l last rest n=0 re='^Claude(-[a-z0-9-]+)?/config\.json$'
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ "$l" == *"${AS_PROFILE_ROOT}/"* ]] || continue
    case "$l" in
      open$'\t'*) continue ;;
      jq$'\t'*)
        last="${l##*$'\t'}"
        rest="${last#"${AS_PROFILE_ROOT}/"}"
        if [[ "$last" != "$rest" && "$rest" =~ $re && "$(count_lines "${l//$'\t'/$'\n'}")" == "4" ]]; then
          n=$((n + 1))
          continue
        fi
        ;;
    esac
    printf '    a call names something else under the profile root: %s\n' "$l"
    return 1
  done < "${AS_TEST_ROOT}/calls.log"
  [[ $n -gt 0 ]] && return 0
  printf '    no jq read of a config.json was logged\n'
  return 1
}

# One identity row (tag, expected label, current, status), as printed.
row() { printf '%-16s %-24s %-44s %s' "$1" "\"$2\"" "$3" "$4"; }

# ---- The read and the status ---------------------------------------------------

case_identity_match() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
  # tag-b's profile records its id in capitals; it is the same account.
  record tag-b "$(printf '%s' "$ID_B" | /usr/bin/tr 'a-f' 'A-F')"
  run_switcher identity tag-a
  keep_run
  local a_out="$out" a_rc="$rc"
  run_switcher identity tag-b
  keep_run
  assert_eq "$a_rc" "0" "identity tag-a exit" &&
    assert_contains "$a_out" "$(row tag-a Alpha '"Alpha"' match)" &&
    assert_rc 0 &&
    assert_contains "$out" "$(row tag-b Beta '"Beta"' match)" &&
    assert_no_leaks
  result "match: the recorded id equals the pin (capitals in config.json read the same) -> match, exit 0" $?
}

case_identity_mismatch_one_tag() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}" "primary=${ID_P}"
  record tag-a "$ID_A"
  record tag-b "$ID_A"
  record primary "$ID_P"
  run_switcher identity --all
  keep_run
  local mismatches
  mismatches="$(printf '%s\n' "$out" | /usr/bin/grep -c ' MISMATCH$')"
  assert_rc 1 &&
    assert_contains "$out" "$(row tag-b Beta "tag-a's account" MISMATCH)" &&
    assert_contains "$out" "$(row tag-a Alpha '"Alpha"' match)" &&
    assert_contains "$out" "$(row primary Primary '"Primary"' match)" &&
    assert_eq "$mismatches" "1" "MISMATCH rows" &&
    assert_contains "$out" "fix: account-switcher signin tag-b" &&
    assert_no_leaks
  result "MISMATCH: tag-b records tag-a's pinned id -> MISMATCH for tag-b only ('tag-a's account'), exit 1" $?
}

case_identity_unrecognized() {
  scenario
  write_config "tag-a=${ID_A}"
  record tag-a "$ID_X"
  run_switcher identity tag-a
  keep_run
  assert_rc 1 &&
    assert_contains "$out" "$(row tag-a Alpha 'an unrecognized account (…000d)' MISMATCH)" &&
    assert_no_leaks
  result "MISMATCH: an id no tag is pinned to -> 'an unrecognized account (…<last 4 hex>)', exit 1" $?
}

# unknown_case <name> <current text>: identity tag-a must read unknown with
# that text, never match, and exit 0. The scenario is set up by the caller.
unknown_case() {
  run_switcher identity tag-a
  keep_run
  assert_rc 0 &&
    assert_contains "$out" "$(row tag-a Alpha "$2" unknown)" &&
    assert_not_contains "$out" " match" &&
    assert_no_leaks
  result "unknown: $1 -> unknown ('$2'), never match, exit 0" $?
}

case_unknown_no_pin() {
  scenario
  write_config "tag-b=${ID_B}"
  record tag-a "$ID_A"
  run_switcher identity tag-a
  keep_run
  assert_rc 0 &&
    assert_contains "$out" "$(row tag-a Alpha 'no pin' unknown)" &&
    assert_contains "$out" "  no pin: run account-switcher identity pin tag-a" &&
    assert_no_leaks
  result "unknown: a tag with no pin (its profile does record an id) -> unknown with the pin hint, exit 0" $?
}

case_unknown_no_folder() {
  scenario
  write_config "tag-a=${ID_A}"
  /bin/rmdir "$(profile_dir tag-a)" || harness_error "cannot remove tag-a's folder"
  unknown_case "pinned, but no profile folder" "no profile folder yet"
}

case_unknown_no_file() {
  scenario
  write_config "tag-a=${ID_A}"
  unknown_case "pinned, but no config.json" "no config.json in the profile"
}

case_unknown_unparseable() {
  scenario
  write_config "tag-a=${ID_A}"
  record_raw tag-a "$(torn_json "$ID_A")"
  run_switcher identity tag-a
  keep_run
  assert_rc 0 &&
    assert_contains "$out" "$(row tag-a Alpha "config.json can't be read" unknown)" &&
    assert_eq "$(count_lines "$(calls_of jq)")" "2" "jq reads" &&
    assert_eq "$(count_lines "$(calls_of sleep)")" "1" "sleeps" &&
    assert_no_leaks
  result "unknown: config.json unparseable on both reads -> one retry (2 jq reads, 1 sleep), then unknown" $?
}

case_unknown_bad_value() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  # 36 characters but not an id; and a short value.
  record tag-a "${TOKEN_MARK}-zzzzzzzzzzzzzzzz"
  record tag-b "${TOKEN_MARK}-9"
  run_switcher identity --all
  keep_run
  assert_rc 0 &&
    assert_eq "${#TOKEN_MARK}" "19" "placeholder length" &&
    assert_contains "$out" "$(row tag-a Alpha 'the recorded value is not an account id' unknown)" &&
    assert_contains "$out" "$(row tag-b Beta 'the recorded value is not an account id' unknown)" &&
    assert_no_leaks
  result "unknown: a value that is not uuid-shaped (36 characters, or short) -> unknown, and the value is never printed" $?
}

case_unknown_key_absent() {
  scenario
  write_config "tag-a=${ID_A}"
  record_raw tag-a "$(json_with '"sidebarMode": "source"')"
  unknown_case "pinned, but the key is absent" "no account recorded"
}

case_unknown_not_object() {
  scenario
  write_config "tag-a=${ID_A}"
  record_raw tag-a "[\"${ID_A}\", \"${TOKEN_MARK}-1\"]"
  unknown_case "pinned, but config.json is not one object" "config.json can't be read"
}

case_torn_read_retry() {
  scenario
  write_config "tag-a=${ID_A}"
  local target next
  target="$(profile_dir tag-a)/config.json"
  next="${AS_TEST_ROOT}/control/config-next.json"
  json_with "\"lastKnownAccountUuid\": \"${ID_A}\"" > "$next"
  fixture "$next"
  record_raw tag-a "$(torn_json "$ID_A")"
  T6_NEXT="$next"
  T6_TARGET="$target"
  export T6_NEXT T6_TARGET
  run_switcher identity tag-a
  keep_run
  unset T6_NEXT T6_TARGET
  assert_rc 0 &&
    assert_contains "$out" "$(row tag-a Alpha '"Alpha"' match)" &&
    assert_eq "$(count_lines "$(calls_of jq)")" "2" "jq reads" &&
    assert_eq "$(count_lines "$(calls_of sleep)")" "1" "sleeps" &&
    assert_call_order jq sleep &&
    assert_no_leaks
  result "torn read: the first read fails, the app finishes its write during the one retry -> match" $?
}

case_status_contract() {
  # identity_status is called by a driver under set -euo pipefail, both in
  # $(...) and as a plain command. It must return 0 for every result.
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
  record tag-b "$ID_A"
  local lib="${AS_TEST_ROOT}/switcher-lib.sh" l prev="" first=1
  : > "$lib"
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 0 ]]; then printf '%s\n' "$prev" >> "$lib"; fi
    prev="$l"
    first=0
  done < "$SWITCHER"
  # $prev is the script's last line, the call to main, left out of the copy.
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash -c '
      . "$1" || exit 70
      shift
      for t; do
        s="$(identity_status "$t")"
        identity_status "$t" > /dev/null
        printf "%s|%s\n" "$t" "$s"
      done
      printf "survived set -euo pipefail\n"' t06-driver "$lib" tag-a tag-b primary Not_A_Tag
  ) > "${AS_TEST_ROOT}/.run-out" 2> "${AS_TEST_ROOT}/.run-err" < /dev/null
  rc=$?
  _read_run "${AS_TEST_ROOT}/.run-out" "${AS_TEST_ROOT}/.run-err"
  keep_run
  assert_rc 0 &&
    assert_contains "$prev" "main " &&
    assert_contains "$out" "tag-a|match pinned" &&
    assert_contains "$out" "tag-b|MISMATCH other-tag tag-a" &&
    assert_contains "$out" "primary|unknown no-file" &&
    assert_contains "$out" "Not_A_Tag|unknown bad-tag" &&
    assert_contains "$out" "survived set -euo pipefail" &&
    assert_no_leaks
  result "identity_status returns 0 for match, MISMATCH and unknown under set -euo pipefail; the result is on stdout" $?
}

# ---- The read-only command -----------------------------------------------------

case_identity_exit_codes() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
  run_switcher identity --all
  keep_run
  local rc_ok="$rc"
  record tag-b "$ID_A"
  run_switcher identity --all
  keep_run
  local rc_mismatch="$rc"
  run_switcher identity tag-z
  keep_run
  local rc_untagged="$rc"
  run_switcher identity --all --bogus
  keep_run
  local rc_flag="$rc"
  printf 'version = 1\n\n[accounts]\n# primary = { label = "Primary" }\n' > "${AS_STORE}/config.toml"
  run_switcher identity --all
  keep_run
  local rc_empty="$rc" err_empty="$err"
  /bin/rm -f "${AS_STORE}/config.toml"
  run_switcher identity
  keep_run
  assert_eq "$rc_ok" "0" "match + unknown rows" &&
    assert_eq "$rc_mismatch" "1" "a MISMATCH row" &&
    assert_eq "$rc_untagged" "2" "a tag not in [accounts]" &&
    assert_eq "$rc_flag" "2" "an unknown flag" &&
    assert_eq "$rc_empty" "2" "no tag in [accounts]" &&
    assert_contains "$err_empty" "No tag in [accounts]" &&
    assert_rc 2 &&
    assert_contains "$err" "No config.toml" &&
    assert_no_leaks
  result "identity exit codes: 0 with no MISMATCH (unknown rows pass), 1 with one, 2 when it cannot run" $?
}

case_show_ids() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
  record tag-b "$ID_X"
  run_switcher identity --all
  keep_run
  local plain_out="$out" plain_err="$err"
  run_switcher identity --all --show-ids
  keep_run
  assert_no_id_text "$plain_out" "stdout without --show-ids" &&
    assert_no_id_text "$plain_err" "stderr without --show-ids" &&
    assert_contains "$plain_out" "an unrecognized account (…000d)" &&
    assert_rc 1 &&
    assert_contains "$out" "$ID_A" &&
    assert_contains "$out" "$ID_B" &&
    assert_contains "$out" "$ID_X" &&
    assert_no_id_text "$err" "stderr with --show-ids" &&
    assert_no_id_text "$(history_text)" "the history log" &&
    assert_no_leaks show-ids
  result "--show-ids prints the pinned and recorded ids on stdout only; without it no id is printed" $?
}

case_identity_read_only() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
  record tag-b "$ID_A"
  # Decoys the read must never open, and a history log over the rotation
  # threshold, which a read-only command must not rotate.
  local d
  d="$(profile_dir tag-a)"
  /bin/mkdir -p "${d}/Local Storage/leveldb" "${d}/IndexedDB" || harness_error "cannot create decoys"
  printf '%s\n' "$DECOY_MARK" > "${d}/Cookies"
  printf '%s\n' "$DECOY_MARK" > "${d}/Local Storage/leveldb/LOCK"
  printf '%s\n' "$DECOY_MARK" > "${d}/IndexedDB/data"
  /usr/bin/awk 'BEGIN { for (i = 0; i < 1200; i++) printf "[2026-01-01T00:00:00Z] QUIT_ALL\n" }' \
    > "${AS_STORE}/swap-history.log"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher identity --all
  keep_run
  assert_rc 1 &&
    assert_tree_unchanged "$HOME" "$before" &&
    assert_profile_reads_config_only &&
    assert_not_contains "$(< "${AS_TEST_ROOT}/transcript.txt")" "$DECOY_MARK" &&
    assert_never_called mktemp &&
    assert_never_called mv &&
    assert_no_leaks
  result "identity is read-only: no file under HOME changes (no log rotation); only each profile's config.json is read, by jq" $?
}

# ---- launch and swap -------------------------------------------------------------

case_launch_mismatch_refuses() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-b "$ID_A"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher launch tag-b
  keep_run
  assert_rc 1 &&
    assert_contains "$err" "Profile 'tag-b' is recorded as signed into tag-a's account, not \"Beta\" (MISMATCH). Not launching." &&
    assert_contains "$err" "Fix: account-switcher signin tag-b; or launch anyway with --force" &&
    assert_never_called open &&
    assert_tree_unchanged "$HOME" "$before" &&
    assert_no_leaks
  result "launch: MISMATCH refuses with the recovery text; no open call, nothing written" $?
}

case_launch_unrecognized_refuses() {
  scenario
  write_config "tag-a=${ID_A}"
  record tag-a "$ID_X"
  run_switcher launch tag-a
  keep_run
  assert_rc 1 &&
    assert_contains "$err" "recorded as signed into an unrecognized account (…000d), not \"Alpha\"" &&
    assert_never_called open &&
    assert_no_leaks
  result "launch: an unrecognized account refuses the same way, naming only the last 4 hex digits" $?
}

case_launch_force() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-b "$ID_A"
  run_switcher launch tag-b --force
  keep_run
  local history
  history="$(history_text)"
  assert_rc 0 &&
    assert_contains "$err" "Profile 'tag-b' is recorded as signed into tag-a's account, not \"Beta\" (MISMATCH). Launching anyway (--force)." &&
    assert_called open "--user-data-dir=$(profile_dir tag-b)" &&
    assert_contains "$history" "IDENTITY tag=tag-b status=MISMATCH" &&
    assert_contains "$history" "LAUNCH tag=tag-b" &&
    assert_no_leaks
  result "launch --force: a MISMATCH launches anyway, with the warning, and logs status=MISMATCH" $?
}

case_launch_unknown_hint() {
  scenario
  write_config "tag-b=${ID_B}"
  record tag-a "$ID_A"
  run_switcher launch tag-a
  keep_run
  assert_rc 0 &&
    assert_contains "$err" "Account check: 'tag-a' is unknown (no pin). Once its window shows \"Alpha\", pin it: account-switcher identity pin tag-a" &&
    assert_called open "--user-data-dir=$(profile_dir tag-a)" &&
    assert_contains "$(history_text)" "IDENTITY tag=tag-a status=unknown" &&
    assert_no_leaks
  result "launch: unknown proceeds with a one-line hint naming identity pin" $?
}

case_launch_match() {
  scenario
  write_config "tag-a=${ID_A}" "primary=${ID_P}"
  record tag-a "$ID_A"
  record primary "$ID_P"
  run_switcher launch tag-a
  keep_run
  local a_err="$err"
  run_switcher launch primary
  keep_run
  assert_contains "$a_err" "Account check: 'tag-a' is recorded as \"Alpha\" (match)." &&
    assert_rc 0 &&
    assert_contains "$err" "Account check: 'primary' is recorded as \"Primary\" (match)." &&
    assert_called open "--user-data-dir=$(profile_dir tag-a)" &&
    assert_eq "$(count_lines "$(calls_of open)")" "2" "open calls" &&
    assert_profile_reads_config_only &&
    assert_no_leaks
  result "launch: match prints the label and launches (tag-a and primary); the check reads only config.json" $?
}

# swap tag-b with tag-a running; the graceful quit empties the table.
swap_scenario() {
  scenario
  set_ps_fixture ps-one-tag.txt ps-no-claude.txt
  export AS_FAKE_QUIT=graceful
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
}

case_swap_mismatch_refuses() {
  swap_scenario
  record tag-b "$ID_A"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher swap tag-b --no-mirror
  keep_run
  assert_rc 1 &&
    assert_contains "$err" "Profile 'tag-b' is recorded as signed into tag-a's account, not \"Beta\" (MISMATCH). Not swapping." &&
    assert_contains "$err" "or swap anyway with --force" &&
    assert_not_contains "$err" "Swap interrupted" &&
    assert_never_called osascript &&
    assert_never_called kill &&
    assert_never_called open &&
    assert_never_called git &&
    assert_never_called ps &&
    assert_eq "$([[ -e "${AS_STORE}/SWAP_HANDOFF.md" ]] && printf yes || printf no)" "no" "handoff file" &&
    assert_tree_unchanged "$HOME" "$before" &&
    assert_no_leaks
  result "swap: MISMATCH refuses before any quit, handoff or write (no osascript, kill, open or git call)" $?
}

case_swap_force() {
  swap_scenario
  record tag-b "$ID_A"
  run_switcher swap tag-b --no-mirror --force
  keep_run
  local history
  history="$(history_text)"
  assert_rc 0 &&
    assert_contains "$err" "(MISMATCH). Swapping anyway (--force)." &&
    assert_call_order osascript open &&
    assert_called open "--user-data-dir=$(profile_dir tag-b)" &&
    assert_contains "$history" "IDENTITY tag=tag-b status=MISMATCH" &&
    assert_contains "$history" "HANDOFF_CAPTURE source=tag-a target=tag-b" &&
    assert_no_leaks
  result "swap --force: a MISMATCH swaps anyway, with the warning, and logs status=MISMATCH" $?
}

case_swap_match() {
  swap_scenario
  record tag-b "$ID_B"
  run_switcher swap tag-b --no-mirror
  keep_run
  assert_rc 0 &&
    assert_contains "$err" "Account check: 'tag-b' is recorded as \"Beta\" (match)." &&
    assert_called open "--user-data-dir=$(profile_dir tag-b)" &&
    assert_contains "$(history_text)" "IDENTITY tag=tag-b status=match" &&
    assert_no_leaks
  result "swap: match prints the label, then quits and launches" $?
}

# ---- identity pin --------------------------------------------------------------

# The lines of config.toml's [identity] table.
identity_lines() {
  /usr/bin/awk '/^\[/ { t = ($0 == "[identity]"); next } t && NF { print }' "${AS_STORE}/config.toml"
}

case_pin_creates_table() {
  scenario
  write_config_no_identity
  record tag-a "$ID_A"
  run_switcher identity pin tag-a --yes
  keep_run
  local pin_out="$out" pin_err="$err" pin_rc="$rc" mode
  mode="$(/usr/bin/stat -f '%Lp' "${AS_STORE}/config.toml")"
  run_switcher identity tag-a
  keep_run
  assert_eq "$pin_rc" "0" "pin exit" &&
    assert_eq "$(identity_lines)" "tag-a = \"${ID_A}\"" "[identity]" &&
    assert_eq "$mode" "600" "config.toml mode" &&
    assert_contains "$pin_err" "Pinned 'tag-a' to \"Alpha\" (id …000a)" &&
    assert_no_id_text "${pin_out}${pin_err}" "pin output" &&
    assert_contains "$(< "${AS_STORE}/config.toml")" "git_root = \"${TEST_GIT_ROOT}\"" &&
    assert_rc 0 &&
    assert_contains "$out" "$(row tag-a Alpha '"Alpha"' match)" &&
    assert_no_leaks
  result "identity pin: adds the [identity] table when there is none (mode 600); identity then reads match" $?
}

case_pin_existing_table() {
  scenario
  write_config "tag-b=${ID_B}" "tag-a=${ID_X}"
  record tag-a "$ID_A"
  run_switcher identity pin tag-a --yes
  keep_run
  local next_header
  next_header="$(/usr/bin/awk '/^\[identity\]$/ { s = 1; next } s && /^\[/ { print; exit }' "${AS_STORE}/config.toml")"
  assert_rc 0 &&
    assert_eq "$(identity_lines)" "tag-b = \"${ID_B}\""$'\n'"tag-a = \"${ID_A}\"" "[identity]" &&
    assert_eq "$next_header" "[swap_handoff]" "the table after [identity]" &&
    assert_contains "$err" "This replaces the current pin (id …000d)." &&
    assert_no_leaks
  result "identity pin: replaces the tag's line inside an existing [identity] table and keeps the rest" $?
}

case_pin_refuses_unconfigured() {
  scenario
  write_config "tag-a=${ID_A}"
  /bin/mkdir -p "$(profile_dir tag-z)" || harness_error "cannot create tag-z's folder"
  record tag-z "$ID_X"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher identity pin tag-z --yes
  keep_run
  assert_rc 2 &&
    assert_contains "$err" "Tag 'tag-z' is not in [accounts]" &&
    assert_tree_unchanged "$HOME" "$before" &&
    assert_no_leaks
  result "identity pin: refuses a tag that is not in [accounts] (exit 2), nothing written" $?
}

case_pin_refuses_unknown() {
  scenario
  write_config "tag-a=${ID_A}"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher identity pin tag-b --yes
  keep_run
  assert_rc 2 &&
    assert_contains "$err" "Can't pin 'tag-b': its account is unknown (no config.json in the profile)" &&
    assert_tree_unchanged "$HOME" "$before" &&
    assert_no_leaks
  result "identity pin: refuses when the tag's account is unknown (exit 2), nothing written" $?
}

case_pin_refuses_other_tags_id() {
  scenario
  write_config "tag-a=${ID_A}"
  record tag-a "$ID_A"
  record tag-b "$ID_A"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher identity pin tag-b --yes
  keep_run
  local refuse_rc="$rc" refuse_err="$err" unchanged=0
  assert_tree_unchanged "$HOME" "$before" > /dev/null || unchanged=1
  run_switcher identity pin tag-b --yes --force
  keep_run
  assert_eq "$refuse_rc" "2" "pin without --force" &&
    assert_contains "$refuse_err" "already pinned to 'tag-a'" &&
    assert_eq "$unchanged" "0" "HOME unchanged after the refusal" &&
    assert_rc 0 &&
    assert_contains "$err" "The same account is pinned to 'tag-a' as well (--force)." &&
    assert_eq "$(identity_lines)" "tag-a = \"${ID_A}\""$'\n'"tag-b = \"${ID_A}\"" "[identity]" &&
    assert_no_leaks
  result "identity pin: refuses an id already pinned to another tag (exit 2); --force pins it" $?
}

case_pin_declined() {
  scenario
  write_config "tag-b=${ID_B}"
  record tag-a "$ID_A"
  local before
  before="$(tree_digest "$HOME")"
  run_switcher identity pin tag-a
  keep_run
  assert_rc 1 &&
    assert_contains "$err" "Pin tag-a as \"Alpha\" (id …000a)? [y/N]" &&
    assert_contains "$err" "Not pinned." &&
    assert_tree_unchanged "$HOME" "$before" &&
    assert_no_leaks
  result "identity pin: without --yes it asks with the label and last 4 hex digits; no answer writes nothing" $?
}

# ---- History rows and the leak scan's own control ------------------------------

case_history_rows() {
  scenario
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}"
  record tag-a "$ID_A"
  record tag-b "$ID_A"
  run_switcher launch tag-a
  keep_run
  run_switcher launch tag-b --force
  keep_run
  run_switcher launch primary
  keep_run
  record tag-b "$ID_B"
  /bin/rm -f "${AS_STORE}/config.toml"
  write_config "tag-a=${ID_A}"
  run_switcher identity pin tag-b --yes
  keep_run
  local l rows="" bad=0 ts='^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] '
  local re_id="${ts}IDENTITY tag=[a-z0-9-]+ status=(match|MISMATCH|unknown)$"
  local re_pin="${ts}IDENTITY_PIN tag=[a-z0-9-]+$"
  while IFS= read -r l; do
    case "$l" in
      *" IDENTITY "*|*" IDENTITY_PIN "*)
        rows="${rows}${l##*Z\] }"$'\n'
        if [[ ! "$l" =~ $re_id && ! "$l" =~ $re_pin ]]; then bad=1; fi
        case "$l" in *Alpha*|*Beta*|*Primary*) bad=1 ;; esac
        ;;
    esac
  done <<< "$(history_text)"
  assert_eq "$bad" "0" "every IDENTITY and IDENTITY_PIN row is <utc>, tag and status word only" &&
    assert_eq "$rows" "IDENTITY tag=tag-a status=match"$'\n'"IDENTITY tag=tag-b status=MISMATCH"$'\n'"IDENTITY tag=primary status=unknown"$'\n'"IDENTITY_PIN tag=tag-b"$'\n' "rows" &&
    assert_no_id_text "$(history_text)" "the history log" &&
    assert_no_leaks
  result "history: IDENTITY rows carry tag and status only, IDENTITY_PIN the tag only; no id, no label" $?
}

case_leak_scan_control() {
  # Each assertion the cases rely on must be able to fail: run against a
  # fixture config.json (or a copy of one outside the exempt list), the
  # token scan, the id scan and the text check each report it.
  scenario
  record tag-a "$ID_A"
  local fx copy="${HOME}/copy-of-config.json" t_hit i_hit t_none i_none text_rc=0 leak_rc=0
  fx="$(profile_dir tag-a)/config.json"
  /bin/cp "$fx" "$copy" || harness_error "cannot copy the fixture"
  t_hit="$(leaks token)"
  i_hit="$(leaks ids)"
  assert_no_leaks > /dev/null || leak_rc=1
  /bin/rm -f "$copy"
  t_none="$(leaks token)"
  i_none="$(leaks ids)"
  assert_no_id_text "$(< "$fx")" "a fixture config.json" > /dev/null || text_rc=1
  assert_eq "$(hits_in token "$fx")" "$fx" "token scan over a fixture config.json" &&
    assert_eq "$(hits_in ids "$fx")" "$fx" "id scan over a fixture config.json" &&
    assert_eq "$t_hit" "$copy" "token scan with a copy outside the exempt list" &&
    assert_eq "$i_hit" "$copy" "id scan with a copy outside the exempt list" &&
    assert_eq "$leak_rc" "1" "assert_no_leaks with the copy present" &&
    assert_eq "$text_rc" "1" "the text check on a fixture config.json" &&
    assert_eq "$t_none" "" "token scan with the copy gone" &&
    assert_eq "$i_none" "" "id scan with the copy gone" &&
    assert_no_leaks
  result "leak scan control: each check fails on a fixture config.json, and on a copy of one outside the exempt list" $?
}

case_identity_match
case_identity_mismatch_one_tag
case_identity_unrecognized
case_unknown_no_pin
case_unknown_no_folder
case_unknown_no_file
case_unknown_unparseable
case_unknown_bad_value
case_unknown_key_absent
case_unknown_not_object
case_torn_read_retry
case_status_contract
case_identity_exit_codes
case_show_ids
case_identity_read_only
case_launch_mismatch_refuses
case_launch_unrecognized_refuses
case_launch_force
case_launch_unknown_hint
case_launch_match
case_swap_mismatch_refuses
case_swap_force
case_swap_match
case_pin_creates_table
case_pin_existing_table
case_pin_refuses_unconfigured
case_pin_refuses_unknown
case_pin_refuses_other_tags_id
case_pin_declined
case_history_rows
case_leak_scan_control
finish
