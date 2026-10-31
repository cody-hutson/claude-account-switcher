#!/usr/bin/env bash
# tests/t-08-front.sh - #8: after launch or swap, the new instance's window
# is brought to the front by PID, that is checked, and the output ends with
# one line naming the tag, the PID, whether it is in front, and the account
# from the #6 check.
#
# The open fake adds the new main process to the table
# (AS_FAKE_OPEN_SPAWNS_PID). The lsappinfo fake keeps the front
# application's PID in front.txt and prints it as an ASN with the trailing
# colon; AS_FAKE_FRONT_AFTER_SETFRONT, _APPKIT and _SYSEVENTS say which PID
# each rung leaves in front ("target" = the PID the rung named). The default
# sleep fake returns at once, so the 15 s wait runs its full 30 polls without
# waiting. Fixture ids are generated here, as in t-06, and written under the
# scratch root only.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

fid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }
ID_A="$(fid 10)"     # pinned to tag-a
ID_B="$(fid 11)"     # pinned to tag-b
ID_P="$(fid 12)"     # pinned to primary
ID_X="$(fid 13)"     # pinned to no tag
NEW_PID=4242
HINT="Switch with Cmd-backtick or the Dock"

# ---- Scenario ----------------------------------------------------------------

profile_dir() {
  if [[ "$1" == "primary" ]]; then
    printf '%s' "${AS_PROFILE_ROOT}/Claude"
  else
    printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"
  fi
}

# record <tag> <id>: the tag's profile records <id>.
record() {
  printf '{\n  "lastKnownAccountUuid": "%s",\n  "windowSizeWasSignedIn": true\n}\n' "$2" \
    > "$(profile_dir "$1")/config.json"
}

# write_config [tag=id ...]: [accounts] with labels, then [identity] pins.
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

# A case with three profiles on their pinned accounts and the given process
# table (default: tag-a running); the next open starts PID $NEW_PID.
scenario() {
  new_case
  /bin/mkdir -p "$AS_STORE" "$(profile_dir primary)" "$(profile_dir tag-a)" "$(profile_dir tag-b)" \
    || harness_error "cannot create the profile folders"
  set_ps_fixture "${1:-ps-one-tag.txt}" "${2:-}"
  write_config "tag-a=${ID_A}" "tag-b=${ID_B}" "primary=${ID_P}"
  record tag-a "$ID_A"
  record tag-b "$ID_B"
  record primary "$ID_P"
  AS_FAKE_OPEN_SPAWNS_PID="$NEW_PID"
  export AS_FAKE_OPEN_SPAWNS_PID
}

# The rungs tried, in order, as <rung>:<pid> words: the lsappinfo setfront
# calls and the activations the osascript fake told apart.
rungs_tried() {
  local l rest words=""
  while IFS= read -r l || [[ -n "$l" ]]; do
    case "$l" in
      "lsappinfo"$'\t'"setfront"$'\t'*)
        rest="${l##*$'\t'}"
        words="${words} setfront:${rest#"#"}"
        ;;
      "osascript"$'\t'"ACTIVATE"$'\t'*)
        rest="${l#osascript$'\t'ACTIVATE$'\t'}"
        words="${words} ${rest%%$'\t'*}:${rest##*$'\t'}"
        ;;
    esac
  done < "${AS_TEST_ROOT}/calls.log"
  printf '%s' "${words# }"
}

# The last line of $1.
last_line() {
  local l last=""
  while IFS= read -r l; do last="$l"; done <<< "$1"
  printf '%s' "$last"
}

history_text() {
  if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi
}

# No uuid-shaped string in the text $1.
assert_no_id_text() {
  local re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
  if [[ "$1" =~ $re ]]; then printf '    %s holds a uuid-shaped string\n' "${2:-text}"; return 1; fi
  return 0
}

# run_merged <subcommand> <tag>: runs the script with stdout and stderr in
# one stream, as a terminal shows them; sets out and rc.
run_merged() {
  local o="${AS_TEST_ROOT}/.run-merged"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$SWITCHER" "$1" "$2"
  ) > "$o" 2>&1 < /dev/null
  rc=$?
  out="$(< "$o")"
  err=""
}

# The script without its last line (the call to main), for drivers that
# source it and call its functions directly. Prints the copy's path.
switcher_lib() {
  local lib="${AS_TEST_ROOT}/switcher-lib.sh" l prev="" first=1
  : > "$lib"
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 0 ]]; then printf '%s\n' "$prev" >> "$lib"; fi
    prev="$l"
    first=0
  done < "$SWITCHER"
  [[ "$prev" == "main "* ]] || harness_error "the script's last line is not the call to main"
  printf '%s' "$lib"
}

# run_driver <driver file>: sources the script copy in /bin/bash under its
# own set -euo pipefail, with the case's environment, and runs the driver.
run_driver() {
  local lib
  lib="$(switcher_lib)"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$1" "$lib"
  ) > "${AS_TEST_ROOT}/.run-out" 2> "${AS_TEST_ROOT}/.run-err" < /dev/null
  rc=$?
  _read_run "${AS_TEST_ROOT}/.run-out" "${AS_TEST_ROOT}/.run-err"
}

# Adds a main process for <tag> with PID <pid> to the case's table.
add_instance() {
  printf '%5s %s --user-data-dir=%s\n' "$1" "${AS_APP_BUNDLE}/Contents/MacOS/Claude" "$(profile_dir "$2")" \
    >> "$AS_FIXTURE_PS"
  printf '%s\n' "$1" >> "${AS_TEST_ROOT}/alive.txt"
}

# ---- launch: the ladder --------------------------------------------------------

case_launch_setfront() {
  # primary and tag-a run, and an older tag-b process (503) is in the table:
  # the wait must take only the PID the launch started.
  scenario ps-three.txt
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_FRONT_AFTER_SETFRONT
  run_switcher launch tag-b
  local want asn_hex
  want="tag=tag-b pid=${NEW_PID} front=yes account=\"Beta\" status=match"
  asn_hex="$(printf '%x' "$((NEW_PID + 0x1d000))")"
  assert_rc 0 &&
    assert_eq "$(count_lines "$(calls_of open)")" "1" "open calls" &&
    assert_called open "--user-data-dir=$(profile_dir tag-b)" &&
    assert_eq "$(rungs_tried)" "setfront:${NEW_PID}" "rungs tried" &&
    assert_eq "$out" "$want" "stdout (the closing line only)" &&
    assert_called lsappinfo $'\tinfo\t-only\tpid\tASN:0x0-0x'"${asn_hex}" &&
    assert_not_contains "$(calls_of lsappinfo)" $'\tASN:0x0-0x'"${asn_hex}:" &&
    assert_not_contains "$(calls_of lsappinfo)" "#503" &&
    assert_contains "$err" "PID ${NEW_PID} is in front (setfront)." &&
    assert_call_order open lsappinfo
  result "launch tag-b with other tags running: one open, the new PID (not the older 503), setfront verifies -> front=yes, tag, PID and label" $?
}

case_launch_ends_with_line() {
  scenario
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_FRONT_AFTER_SETFRONT
  run_merged launch tag-b
  assert_rc 0 &&
    assert_eq "$(last_line "$out")" "tag=tag-b pid=${NEW_PID} front=yes account=\"Beta\" status=match" "last line, stdout and stderr together"
  result "launch: with stdout and stderr in one stream (a terminal), the closing line is the last line" $?
}

case_ladder_appkit() {
  scenario
  AS_FAKE_FRONT_AFTER_APPKIT=target
  export AS_FAKE_FRONT_AFTER_APPKIT
  run_switcher launch tag-b
  assert_rc 0 &&
    assert_eq "$(rungs_tried)" "setfront:${NEW_PID} appkit:${NEW_PID}" "rungs tried" &&
    assert_called osascript $'\t-l\tJavaScript\t-e\t' &&
    assert_called osascript "NSRunningApplication" &&
    assert_eq "$(last_line "$out")" "tag=tag-b pid=${NEW_PID} front=yes account=\"Beta\" status=match" "closing line" &&
    assert_not_contains "$(calls_of osascript)" "System Events"
  result "ladder: setfront does not verify, the AppKit rung does -> stops there, front=yes" $?
}

case_ladder_system_events() {
  # setfront leaves the older tag-a window (502) in front, the #8 symptom;
  # that is not the new PID, so the ladder goes on.
  scenario
  AS_FAKE_FRONT_AFTER_SETFRONT=502
  AS_FAKE_FRONT_AFTER_SYSEVENTS=target
  export AS_FAKE_FRONT_AFTER_SETFRONT AS_FAKE_FRONT_AFTER_SYSEVENTS
  run_switcher launch tag-b
  assert_rc 0 &&
    assert_eq "$(rungs_tried)" "setfront:${NEW_PID} appkit:${NEW_PID} system-events:${NEW_PID}" "rungs tried" &&
    assert_called osascript $'\t-e\ton run argv\t-e\ttell application "System Events" to set frontmost of (first application process whose unix id is ((item 1 of argv) as integer)) to true\t-e\tend run\t'"${NEW_PID}" &&
    assert_eq "$(last_line "$out")" "tag=tag-b pid=${NEW_PID} front=yes account=\"Beta\" status=match" "closing line" &&
    assert_contains "$err" "PID ${NEW_PID} is in front (system-events)."
  result "ladder: only the System Events rung verifies (setfront left the older window in front) -> all three in order, front=yes" $?
}

case_ladder_none() {
  # No rung moves the front, and every rung command fails: the launch still
  # exits 0 and says how to switch.
  scenario
  AS_FAKE_ACTIVATE_RC=1
  export AS_FAKE_ACTIVATE_RC
  run_switcher launch tag-b
  local osa
  osa="$(calls_of osascript)"
  assert_rc 0 &&
    assert_eq "$(rungs_tried)" "setfront:${NEW_PID} appkit:${NEW_PID} system-events:${NEW_PID}" "rungs tried" &&
    assert_eq "$(last_line "$out")" "tag=tag-b pid=${NEW_PID} front=no account=\"Beta\" status=match  ${HINT}" "closing line" &&
    assert_contains "$err" "PID ${NEW_PID} is running but could not be brought to the front." &&
    assert_eq "$(count_lines "$(calls_of open)")" "1" "open calls" &&
    assert_not_contains "$osa" "to activate" &&
    assert_not_contains "$osa" 'application "Claude"'
  result "ladder: no rung verifies (and each rung's command fails) -> all three tried, front=no with the hint, exit 0; no bundle-level activate" $?
}

case_launch_primary() {
  # primary is launched without --user-data-dir; with tag-a running it is
  # the one flagless process, so the matcher reads it as primary.
  scenario
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_FRONT_AFTER_SETFRONT
  run_switcher launch primary
  assert_rc 0 &&
    assert_eq "$(calls_of open)" "open"$'\t-n\t-a\tClaude' "open call" &&
    assert_eq "$out" "tag=primary pid=${NEW_PID} front=yes account=\"Primary\" status=match" "stdout"
  result "launch primary with tag-a running: the new flagless PID is primary -> front=yes, \"Primary\"" $?
}

# ---- launch: no new PID ----------------------------------------------------------

case_no_new_pid() {
  scenario
  unset AS_FAKE_OPEN_SPAWNS_PID
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_FRONT_AFTER_SETFRONT
  run_switcher launch tag-b
  local sleeps
  sleeps="$(calls_of sleep)"
  assert_rc 0 &&
    assert_eq "$out" "tag=tag-b pid=unknown front=no account=\"Beta\" status=match  ${HINT}" "stdout" &&
    assert_contains "$err" "No new 'tag-b' instance appeared within 15 s" &&
    assert_eq "$(count_lines "$sleeps")" "30" "sleeps (15 s at 0.5 s)" &&
    assert_eq "$(count_lines "$(printf '%s\n' "$sleeps" | /usr/bin/grep -vx $'sleep\t0.5')")" "0" "sleeps other than 0.5 s" &&
    assert_eq "$(rungs_tried)" "" "rungs tried" &&
    assert_called open "--user-data-dir=$(profile_dir tag-b)"
  result "no new PID within the timeout -> 30 polls 0.5 s apart, pid=unknown front=no with the hint, no rung tried, exit 0" $?
}

# ---- swap ---------------------------------------------------------------------------

case_swap_line() {
  scenario ps-one-tag.txt ps-no-claude.txt
  AS_FAKE_QUIT=graceful
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_QUIT AS_FAKE_FRONT_AFTER_SETFRONT
  run_switcher swap tag-b --no-mirror --no-handoff
  assert_rc 0 &&
    assert_eq "$(last_line "$out")" "tag=tag-b pid=${NEW_PID} front=yes account=\"Beta\" status=match" "closing line" &&
    assert_called osascript $'-e\ttell application "Claude" to quit' &&
    assert_call_order osascript open &&
    assert_call_order open lsappinfo &&
    assert_eq "$(rungs_tried)" "setfront:${NEW_PID}" "rungs tried" &&
    assert_not_contains "$err" "Swap interrupted"
  result "swap tag-b: quits, opens, brings the new PID to the front, and ends with the same line" $?
}

# ---- launch: the #6 refusal and the account words --------------------------------

case_mismatch_refused() {
  scenario
  record tag-b "$ID_A"
  run_switcher launch tag-b
  assert_rc 1 &&
    assert_contains "$err" "(MISMATCH). Not launching." &&
    assert_never_called open &&
    assert_never_called lsappinfo &&
    assert_never_called sleep &&
    assert_eq "$out" "" "stdout"
  result "launch: a MISMATCH is still refused before open (no open, no wait, no lsappinfo, no closing line)" $?
}

case_account_words() {
  # One launch per account state; each starts a new PID, and every PID is
  # brought to the front by setfront.
  scenario
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_FRONT_AFTER_SETFRONT
  local all="" l1 l2 l3 l4 control_rc=0
  run_switcher launch tag-b
  l1="$(last_line "$out")"; all="${all}${out}${err}"
  record tag-b "$ID_A"
  AS_FAKE_OPEN_SPAWNS_PID=4243
  run_switcher launch tag-b --force
  l2="$(last_line "$out")"; all="${all}${out}${err}"
  record tag-b "$ID_X"
  AS_FAKE_OPEN_SPAWNS_PID=4244
  run_switcher launch tag-b --force
  l3="$(last_line "$out")"; all="${all}${out}${err}"
  write_config "tag-b=${ID_B}"
  AS_FAKE_OPEN_SPAWNS_PID=4245
  run_switcher launch tag-a
  l4="$(last_line "$out")"; all="${all}${out}${err}"
  # Control: the same check on a text holding a fixture id must fail.
  assert_no_id_text "launch printed ${ID_B}" > /dev/null || control_rc=1
  assert_eq "$l1" "tag=tag-b pid=${NEW_PID} front=yes account=\"Beta\" status=match" "match" &&
    assert_eq "$l2" "tag=tag-b pid=4243 front=yes account=\"Alpha\" status=MISMATCH" "MISMATCH, another tag's account" &&
    assert_eq "$l3" "tag=tag-b pid=4244 front=yes account=unrecognized status=MISMATCH" "MISMATCH, an unrecognized account" &&
    assert_eq "$l4" "tag=tag-a pid=4245 front=yes account=unknown status=unknown" "unknown (no pin)" &&
    assert_no_id_text "$all" "launch output" &&
    assert_no_id_text "$(history_text)" "the history log" &&
    assert_eq "$control_rc" "1" "control: the uuid check on a text holding a fixture id"
  result "account words: the tag's label (match), the other tag's label, unrecognized, unknown; no uuid-shaped string in any output or the log (control fails on one)" $?
}

case_history_rows() {
  scenario
  AS_FAKE_FRONT_AFTER_SETFRONT=target
  export AS_FAKE_FRONT_AFTER_SETFRONT
  run_switcher launch tag-b
  local l kinds="" bad=0
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    l="${l#*Z\] }"
    kinds="${kinds}${l%% *} "
    case "$l" in *"pid="*|*"front="*|*Beta*) bad=1 ;; esac
  done <<< "$(history_text)"
  assert_rc 0 &&
    assert_eq "$kinds" "IDENTITY LAUNCH " "history rows" &&
    assert_contains "$(history_text)" "LAUNCH tag=tag-b udd=$(profile_dir tag-b) first_launch=false" &&
    assert_eq "$bad" "0" "no PID or label in the log"
  result "history: launch still writes its IDENTITY and LAUNCH rows only, LAUNCH unchanged; no PID or label logged" $?
}

# ---- The primitives, called directly -------------------------------------------

case_front_pid() {
  scenario
  AS_FAKE_FRONT_PID="$NEW_PID"
  export AS_FAKE_FRONT_PID
  local driver="${AS_TEST_ROOT}/driver.sh"
  /bin/cat > "$driver" <<'DRIVER'
. "$1" || exit 70
raw="$("$AS_BIN_LSAPPINFO" front)"
printf 'raw|%s\n' "$raw"
printf 'front_pid|%s\n' "$(front_pid)"
printf 'sed-form|%s\n' "$("$AS_BIN_LSAPPINFO" info -only pid "$("$AS_BIN_LSAPPINFO" front | "$AS_BIN_SED" 's/:$//')")"
printf 'tr-form|%s\n' "$("$AS_BIN_LSAPPINFO" info -only pid "$("$AS_BIN_LSAPPINFO" front | "$AS_BIN_TR" -d ':')")"
v=0
"$AS_BIN_LSAPPINFO" kill > /dev/null 2>&1 || v=$?
printf 'kill-verb|%s\n' "$v"
DRIVER
  run_driver "$driver"
  local asn
  asn="ASN:0x0-0x$(printf '%x' "$((NEW_PID + 0x1d000))"):"
  assert_rc 0 &&
    assert_contains "$out" "raw|${asn}"$'\n' &&
    assert_contains "$out" "front_pid|${NEW_PID}"$'\n' &&
    assert_contains "$out" "sed-form|\"pid\"=${NEW_PID}"$'\n' &&
    assert_contains "$out" "tr-form|"$'\n' &&
    assert_contains "$out" "kill-verb|99"
  result "front_pid: reads the PID from an ASN:...: string with the trailing colon; control: the tr -d ':' form returns nothing; the fake refuses other verbs" $?
}

case_contracts() {
  # Every call runs in a driver under the script's own set -euo pipefail,
  # once in $(...) and once as a plain command: a non-zero return would end
  # the driver before it prints "survived".
  scenario
  add_instance "$NEW_PID" tag-b
  local driver="${AS_TEST_ROOT}/driver.sh"
  /bin/cat > "$driver" <<'DRIVER'
. "$1" || exit 70
show() { printf '%s|%s\n' "$1" "$2"; }
show wait-new "$(wait_for_new_instance tag-b 502 1)"
wait_for_new_instance tag-b 502 1 > /dev/null
show wait-excluded "$(wait_for_new_instance tag-b "502 4242" 1)"
wait_for_new_instance tag-b "502 4242" 1 > /dev/null
show wait-newline-list "$(wait_for_new_instance tag-b "$(printf '502\n4242\n')" 0)"
show wait-bad-tag "$(wait_for_new_instance Not_A_Tag "" 1)"
wait_for_new_instance Not_A_Tag > /dev/null
show wait-default "$(wait_for_new_instance default "" 0)"
show wait-bad-timeout "$(wait_for_new_instance tag-a "" x)"
export AS_FAKE_FRONT_AFTER_SETFRONT=target
show front-verified "$(bring_to_front 4242)"
bring_to_front 4242 > /dev/null
export AS_FAKE_FRONT_AFTER_SETFRONT="" AS_FAKE_ACTIVATE_RC=1
show front-none "$(bring_to_front 4243)"
bring_to_front 4243 > /dev/null
show front-word "$(bring_to_front abc)"
show front-zero "$(bring_to_front 0)"
show front-empty "$(bring_to_front)"
bring_to_front "" > /dev/null
printf 'survived set -euo pipefail\n'
DRIVER
  run_driver "$driver"
  local part_a_out="$out" part_a_rc="$rc"
  # Part B: the process table cannot be read. The wait polls to its end
  # (timeout 2 s: 5 reads, 4 sleeps) and still prints nothing and returns 0.
  printf '#!/bin/bash\n# as-fake: recording\nprintf "ps\\tFAILED\\n" >> "${AS_TEST_ROOT}/calls.log"\nexit 1\n' > "${AS_FAKES_DIR}/ps"
  /bin/chmod 755 "${AS_FAKES_DIR}/ps"
  : > "${AS_TEST_ROOT}/calls.log"
  /bin/cat > "$driver" <<'DRIVER'
. "$1" || exit 70
printf 'wait-ps-fails|%s\n' "$(wait_for_new_instance tag-b "" 2)"
wait_for_new_instance tag-b "" 2 > /dev/null
printf 'survived set -euo pipefail\n'
DRIVER
  run_driver "$driver"
  assert_eq "$part_a_rc" "0" "part A exit" &&
    assert_contains "$part_a_out" "wait-new|${NEW_PID}"$'\n' &&
    assert_contains "$part_a_out" "wait-excluded|"$'\n' &&
    assert_contains "$part_a_out" "wait-newline-list|"$'\n' &&
    assert_contains "$part_a_out" "wait-bad-tag|"$'\n' &&
    assert_contains "$part_a_out" "wait-default|"$'\n' &&
    assert_contains "$part_a_out" "wait-bad-timeout|502"$'\n' &&
    assert_contains "$part_a_out" "front-verified|setfront"$'\n' &&
    assert_contains "$part_a_out" "front-none|none"$'\n' &&
    assert_contains "$part_a_out" "front-word|none"$'\n' &&
    assert_contains "$part_a_out" "front-zero|none"$'\n' &&
    assert_contains "$part_a_out" "front-empty|none"$'\n' &&
    assert_contains "$part_a_out" "survived set -euo pipefail" &&
    assert_rc 0 &&
    assert_contains "$out" "wait-ps-fails|"$'\n' &&
    assert_contains "$out" "survived set -euo pipefail" &&
    assert_eq "$(count_lines "$(calls_of ps)")" "10" "ps reads (2 waits x 5)" &&
    assert_eq "$(count_lines "$(calls_of sleep)")" "8" "sleeps (2 waits x 4)"
  result "contracts: wait_for_new_instance and bring_to_front return 0 on every path (found, excluded, bad tag, bad timeout, unreadable table; verified, none, bad PID)" $?
}

case_help_names_line() {
  new_case
  run_switcher help
  assert_rc 0 &&
    assert_contains "$out" "Then waits up to 15 s for the new instance, brings" &&
    assert_contains "$out" "tag=<tag> pid=<pid> front=yes|no" &&
    assert_contains "$out" 'account=<"label"|unrecognized|unknown>' &&
    assert_contains "$out" "status=<match|MISMATCH|unknown>" &&
    assert_contains "$out" "System Events step may show a one-time macOS prompt"
  result "help: launch and swap describe the closing line, the 15 s wait and the System Events prompt" $?
}

# ---- The seam ----------------------------------------------------------------------

case_lsappinfo_recording_only() {
  new_case
  render_fixture "${LIB_DIR}/fakes/passthrough.sh" "${AS_FAKES_DIR}/lsappinfo"
  /bin/chmod 755 "${AS_FAKES_DIR}/lsappinfo"
  run_switcher version
  assert_rc 78 &&
    assert_contains "$err" "AS_BIN_LSAPPINFO is a passthrough fake but must be recording" &&
    assert_eq "$(< "${AS_TEST_ROOT}/calls.log")" "" "calls.log"
  result "seam: lsappinfo is in the danger set; a pass-through lsappinfo fake -> 78" $?
}

case_launch_setfront
case_launch_ends_with_line
case_ladder_appkit
case_ladder_system_events
case_ladder_none
case_launch_primary
case_no_new_pid
case_swap_line
case_mismatch_refused
case_account_words
case_history_rows
case_front_pid
case_contracts
case_help_names_line
case_lsappinfo_recording_only
finish
