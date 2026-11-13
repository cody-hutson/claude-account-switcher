#!/usr/bin/env bash
# tests/t-09-detect.sh - #9: one exact matcher for running instances.
#
# A Claude main process is one whose argv[0] is exactly the case's app
# binary ($AS_APP_BUNDLE/Contents/MacOS/Claude). Its profile comes from the
# --user-data-dir value compared as a whole folder; a single process without
# the flag is primary; more than one is resolved by the profile folder it
# holds open (the lsof fake), else reported unknown. Every caller goes
# through the same matcher: list, clone-prefs (is_tag_running), the swap
# handoff (detect_running_tag) and quit (get_claude_pids). Process tables
# are tests/fixtures/ps/; open-file lists are tests/fixtures/lsof/.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

APP_BIN_ROW_TEXT="/Contents/MacOS/Claude"

# A case with the four profile folders and the switcher's store.
scenario() {
  new_case
  /bin/mkdir -p "${AS_PROFILE_ROOT}/Claude" "${AS_PROFILE_ROOT}/Claude-tag-a" \
    "${AS_PROFILE_ROOT}/Claude-tag-a-2" "${AS_PROFILE_ROOT}/Claude-tag-b" "$AS_STORE"
  [[ -z "${1:-}" ]] || set_ps_fixture "$1" "${2:-}"
}

# One `list` instance row, formatted as the script prints it.
row() {  # $1 pid, $2 tag, $3 method, $4 data-dir
  printf '  PID %-7s tag=%-12s via=%-8s data-dir=%s' "$1" "$2" "$3" "$4"
}

# The "  PID ..." rows of the last run's stdout.
instance_rows() {
  local l
  while IFS= read -r l; do
    case "$l" in "  PID "*) printf '%s\n' "$l" ;; esac
  done <<< "$out"
}

# No instance row reads tag=primary without via=argv, flagless or lsof.
assert_primary_has_reason() {
  local l
  while IFS= read -r l; do
    case "$l" in
      *"tag=primary "*)
        case "$l" in
          *"via=argv "*|*"via=flagless "*|*"via=lsof "*) ;;
          *) printf '    tag=primary without a reason: %s\n' "$l"; return 1 ;;
        esac
        ;;
    esac
  done < <(instance_rows)
  return 0
}

# The rendered process table holds a row starting "<pid> <text>".
assert_table_row() {
  assert_contains "$(< "$AS_FIXTURE_PS")" "  $1 $2"
}

# ---- Matching ------------------------------------------------------------

case_flagless_primary() {
  scenario ps-match.txt
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "$(row 501 primary flagless "${AS_PROFILE_ROOT}/Claude")" &&
    assert_never_called lsof &&
    assert_called ps $'\t-axww\t-o\tpid=,args='
  result "matching: the one main process without --user-data-dir -> primary, via=flagless (no lsof)" $?
}

case_space_path_tag() {
  scenario ps-match.txt
  run_switcher list
  assert_rc 0 &&
    assert_contains "${AS_PROFILE_ROOT}" "Application Support" &&
    assert_contains "$out" "$(row 502 tag-a argv "${AS_PROFILE_ROOT}/Claude-tag-a")"
  result "matching: --user-data-dir under 'Application Support' (a space) -> tag-a, via=argv" $?
}

case_tag_prefix() {
  scenario ps-match.txt
  run_switcher list
  local rows
  rows="$(instance_rows)"
  assert_rc 0 &&
    assert_contains "$rows" "$(row 502 tag-a argv "${AS_PROFILE_ROOT}/Claude-tag-a")" &&
    assert_contains "$rows" "$(row 505 tag-a-2 argv "${AS_PROFILE_ROOT}/Claude-tag-a-2")" &&
    assert_not_contains "$rows" "PID 505     tag=tag-a "
  result "matching: tag-a and tag-a-2 are told apart" $?
}

case_primary_folder_whole() {
  # tag-a and tag-b run; process 700 is not Claude but names primary's
  # folder in its arguments.
  scenario ps-tags-only.txt
  run_switcher list
  local rows
  rows="$(instance_rows)"
  assert_rc 0 &&
    assert_table_row 700 "/usr/bin/python3 -c pass ${AS_APP_BUNDLE}${APP_BIN_ROW_TEXT} --user-data-dir=${AS_PROFILE_ROOT}/Claude" &&
    assert_eq "$(count_lines "$rows")" "2" "instance rows" &&
    assert_not_contains "$rows" "tag=primary" &&
    assert_contains "$rows" "$(row 503 tag-b argv "${AS_PROFILE_ROOT}/Claude-tag-b")"
  result "matching: primary's folder is never matched by a Claude-<tag> row" $?
}

case_helpers_excluded() {
  scenario ps-match.txt
  run_switcher list
  local rows
  rows="$(instance_rows)"
  assert_rc 0 &&
    assert_table_row 511 "${AS_APP_BUNDLE}/Contents/Frameworks/Claude Helper.app" &&
    assert_not_contains "$rows" "PID 511" &&
    assert_not_contains "$rows" "PID 512"
  result "matching: Claude Helper processes are not instances" $?
}

case_non_claude_excluded() {
  # 700 carries the binary path as an argument (the old substring selector
  # took it); 701's argv[0] has the binary path as a prefix.
  scenario ps-match.txt
  run_switcher list
  local rows
  rows="$(instance_rows)"
  assert_rc 0 &&
    assert_table_row 700 "/usr/bin/python3 -c pass ${AS_APP_BUNDLE}${APP_BIN_ROW_TEXT} " &&
    assert_table_row 701 "${AS_APP_BUNDLE}${APP_BIN_ROW_TEXT}2 " &&
    assert_not_contains "$rows" "PID 700" &&
    assert_not_contains "$rows" "PID 701" &&
    assert_eq "$(count_lines "$rows")" "3" "instance rows"
  result "matching (H-3): a process whose arguments contain the app path, or whose argv[0] only starts with it, is excluded" $?
}

# ---- More than one process without --user-data-dir -------------------------

case_two_flagless_resolved() {
  scenario ps-two-flagless.txt
  set_lsof_fixture 501 primary.txt
  set_lsof_fixture 504 tag-a.txt
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "$(row 501 primary lsof "${AS_PROFILE_ROOT}/Claude")" &&
    assert_contains "$out" "$(row 504 tag-a lsof "${AS_PROFILE_ROOT}/Claude-tag-a")" &&
    assert_contains "$out" "$(row 503 tag-b argv "${AS_PROFILE_ROOT}/Claude-tag-b")" &&
    assert_called lsof $'\t-p\t501' &&
    assert_called lsof $'\t-p\t504' &&
    assert_not_contains "$(calls_of lsof)" $'\t-p\t503'
  result "two flagless: open files resolve them to primary and tag-a (via=lsof); the argv row is not looked up" $?
}

case_two_flagless_inconclusive() {
  # 501 holds files under two profile folders; 504 has no open-file list.
  scenario ps-two-flagless.txt
  set_lsof_fixture 501 mixed.txt
  run_switcher list
  local rows
  rows="$(instance_rows)"
  assert_rc 0 &&
    assert_contains "$rows" "$(row 501 unknown none "(unknown)")" &&
    assert_contains "$rows" "$(row 504 unknown none "(unknown)")" &&
    assert_not_contains "$rows" "tag=primary" &&
    assert_primary_has_reason
  result "two flagless: inconclusive open files -> tag=unknown via=none, never primary" $?
}

case_unresolved_rows() {
  # 506 names primary's folder; 501 has no flag, so with 506 claiming
  # primary it is looked up by open files (it holds tag-a's); 507 names a
  # folder that is no valid tag; 508 passes the flag without "=".
  scenario ps-unresolved.txt
  set_lsof_fixture 501 tag-a.txt
  run_switcher list
  local rows
  rows="$(instance_rows)"
  assert_rc 0 &&
    assert_contains "$rows" "$(row 506 primary argv "${AS_PROFILE_ROOT}/Claude")" &&
    assert_contains "$rows" "$(row 501 tag-a lsof "${AS_PROFILE_ROOT}/Claude-tag-a")" &&
    assert_contains "$rows" "$(row 507 unknown none "(unknown)")" &&
    assert_contains "$rows" "$(row 508 unknown none "(unknown)")" &&
    assert_eq "$(count_lines "$rows")" "4" "instance rows" &&
    assert_called lsof $'\t-p\t501' &&
    assert_called lsof $'\t-p\t507' &&
    assert_called lsof $'\t-p\t508' &&
    assert_not_contains "$(calls_of lsof)" $'\t-p\t506'
  result "unresolved: a flagless row beside an argv primary, a bad folder and a flag without '=' go to open files, else unknown" $?
}

case_ps_fails() {
  scenario
  clone_files
  # A ps that fails: the table cannot be read, so nothing is known.
  printf '#!/bin/bash\n# as-fake: recording\nprintf "ps\\tFAILED\\n" >> "${AS_TEST_ROOT}/calls.log"\nexit 1\n' > "${AS_FAKES_DIR}/ps"
  /bin/chmod 755 "${AS_FAKES_DIR}/ps"
  local before list_out
  before="$(tree_digest "${AS_PROFILE_ROOT}/Claude")"
  run_switcher list
  list_out="$out"
  run_switcher clone-prefs tag-a primary
  assert_contains "$list_out" "(the process table could not be read; running instances unknown)" &&
    assert_not_contains "$list_out" "(no Claude desktop app instances running)" &&
    assert_rc 1 &&
    assert_contains "$err" "Cannot tell whether 'primary' is running" &&
    assert_called ps "FAILED" &&
    assert_tree_unchanged "${AS_PROFILE_ROOT}/Claude" "$before"
  result "ps failure: list says the table could not be read; clone-prefs refuses rather than reading 'not running'" $?
}

# ---- Output ----------------------------------------------------------------

case_list_reasons() {
  local ok=0 f
  for f in ps-three.txt ps-match.txt ps-tags-only.txt ps-two-flagless.txt; do
    scenario "$f"
    set_lsof_fixture 501 primary.txt
    run_switcher list
    assert_rc 0 && assert_primary_has_reason || ok=1
  done
  scenario ps-two-flagless.txt
  run_switcher list
  assert_eq "$ok" "0" "every table" &&
    assert_contains "$out" "tag=unknown" &&
    assert_primary_has_reason
  result "output: list never prints primary without a via= reason, and prints unknown where the matcher says so" $?
}

# swap <tag> --no-mirror with a graceful quit; the handoff's Direction line
# and history row show what detect_running_tag returned.
swap_and_read_handoff() {
  printf 'version = 1\n\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT" > "${AS_STORE}/config.toml"
  export AS_FAKE_QUIT=graceful
  run_switcher swap tag-b --no-mirror
  body=""
  [[ -f "${AS_STORE}/SWAP_HANDOFF.md" ]] && body="$(< "${AS_STORE}/SWAP_HANDOFF.md")"
  history=""
  [[ -f "${AS_STORE}/swap-history.log" ]] && history="$(< "${AS_STORE}/swap-history.log")"
}

case_detect_several_no_marker() {
  scenario ps-three.txt ps-no-claude.txt
  swap_and_read_handoff
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `unknown` → `tag-b`' &&
    assert_contains "$history" "HANDOFF_CAPTURE source=unknown target=tag-b" &&
    assert_never_called pgrep
  result "detect: several instances, no marker -> unknown; the handoff records source=unknown" $?
}

case_detect_stale_marker() {
  scenario ps-three.txt ps-no-claude.txt
  printf 'tag-z\n' > "${AS_STORE}/.statusline-marker"
  swap_and_read_handoff
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `unknown` → `tag-b`' &&
    assert_never_called pgrep
  result "detect: several instances, the marker names a tag that is not running -> unknown" $?
}

case_detect_one_instance() {
  scenario ps-one-tag.txt ps-no-claude.txt
  swap_and_read_handoff
  assert_rc 0 &&
    assert_contains "$body" '- **Direction:** `tag-a` → `tag-b`' &&
    assert_never_called pgrep
  result "detect: one instance -> its tag from --user-data-dir (the space no longer breaks the parse)" $?
}

# ---- clone-prefs <src> primary --------------------------------------------

# Gives tag-a (the source) and primary (the target) a claude_desktop_config.json.
clone_files() {
  printf '{"sidebarMode":"source"}\n' > "${AS_PROFILE_ROOT}/Claude-tag-a/claude_desktop_config.json"
  printf '{"sidebarMode":"target"}\n' > "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json"
}

case_clone_primary_running() {
  scenario ps-primary-only.txt
  clone_files
  local before
  before="$(tree_digest "${AS_PROFILE_ROOT}/Claude")"
  run_switcher clone-prefs tag-a primary
  assert_rc 1 &&
    assert_contains "$err" "Target instance ('primary') is currently running" &&
    assert_tree_unchanged "${AS_PROFILE_ROOT}/Claude" "$before" &&
    assert_never_called mktemp
  result "clone-prefs <src> primary: refuses while primary (no flag) is running" $?
}

case_clone_primary_other_tags() {
  # Only tag-a and tag-b run (and a non-Claude process naming primary's
  # folder). The running check passes. The next guard was M-10 (a
  # sensitive-looking key in the source); #11 replaced the whole-file copy
  # it guarded with the key-level step, which never copies such a key.
  scenario ps-tags-only.txt
  clone_files
  printf '{"oauth":"fake"}\n' > "${AS_PROFILE_ROOT}/Claude-tag-a/claude_desktop_config.json"
  local before
  before="$(tree_digest "${AS_PROFILE_ROOT}/Claude")"
  run_switcher clone-prefs tag-a primary
  assert_rc 0 &&
    assert_not_contains "$err" "currently running" &&
    assert_not_contains "$err" "Cannot tell" &&
    assert_not_contains "$(< "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json")" "oauth" &&
    assert_tree_unchanged "${AS_PROFILE_ROOT}/Claude" "$before"
  result "clone-prefs <src> primary: with only other tags running it passes the running check, and the source's token-shaped key never reaches primary (#11: key-level step, no M-10 scan)" $?
}

case_clone_primary_writes() {
  scenario ps-tags-only.txt
  clone_files
  run_switcher clone-prefs tag-a primary
  # #11: the settings step is key-level and these files hold no allowlisted
  # key, so primary's file stays as it is; the step and #11's running rule
  # read the table too.
  assert_rc 0 &&
    assert_contains "$err" "settings: 0 applied to primary" &&
    assert_eq "$(< "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json")" '{"sidebarMode":"target"}' "target config" &&
    assert_eq "$(count_lines "$(calls_of ps)")" "4" "process-table reads (pre-snapshot check, the running rule, the settings step, pre-apply re-check)"
  result "clone-prefs <src> primary: proceeds when primary is not running (#11: no allowlisted key, so the file is left as it is); every check reads the table" $?
}

case_clone_primary_undetermined() {
  # Two flagless processes, neither resolvable: is_tag_running primary = 2.
  scenario ps-two-flagless.txt
  set_lsof_fixture 501 mixed.txt
  clone_files
  local before
  before="$(tree_digest "${AS_PROFILE_ROOT}/Claude")"
  run_switcher clone-prefs tag-a primary
  assert_rc 1 &&
    assert_contains "$err" "Cannot tell whether 'primary' is running" &&
    assert_contains "$err" "tag is unknown" &&
    assert_tree_unchanged "${AS_PROFILE_ROOT}/Claude" "$before" &&
    assert_never_called mktemp
  result "clone-prefs <src> primary: refuses with a reason when it cannot tell (is_tag_running = 2)" $?
}

case_clone_recheck() {
  # Only tags at the first check; primary appears before the second.
  scenario ps-tags-only.txt
  set_ps_next_fixture ps-primary-only.txt
  clone_files
  local before
  before="$(tree_digest "${AS_PROFILE_ROOT}/Claude")"
  run_switcher clone-prefs tag-a primary
  assert_rc 1 &&
    assert_contains "$err" "Target instance ('primary') started while preparing snapshot" &&
    assert_called mktemp ".clone-prefs-bak." &&
    assert_tree_unchanged "${AS_PROFILE_ROOT}/Claude" "$before"
  result "clone-prefs <src> primary: the pre-apply re-check uses the matcher; primary appearing aborts and the snapshot is restored" $?
}

case_clone_tag_prefix() {
  local ok_run rc_run err_run
  # tag-a-2 runs, tag-a does not: cloning into tag-a proceeds.
  scenario ps-tag-a-2-only.txt
  printf '{"sidebarMode":"source"}\n' > "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json"
  run_switcher clone-prefs primary tag-a
  rc_run="$rc"
  err_run="$err"
  ok_run=0
  [[ "$rc_run" == "0" && "$err_run" == *"settings: 0 applied to tag-a"* ]] || ok_run=1
  # Control: tag-a itself runs: it refuses.
  scenario ps-three.txt
  printf '{"sidebarMode":"source"}\n' > "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json"
  run_switcher clone-prefs primary tag-a
  assert_eq "$ok_run" "0" "clone into tag-a while tag-a-2 runs (exit ${rc_run})" &&
    assert_rc 1 &&
    assert_contains "$err" "Target instance ('tag-a') is currently running"
  result "clone-prefs primary tag-a: a running tag-a-2 is not tag-a; a running tag-a refuses" $?
}

# ---- swap with the mirror, when the target cannot be determined -----------

case_swap_mirror_undetermined() {
  scenario ps-two-flagless.txt ps-no-claude.txt
  set_lsof_fixture 501 mixed.txt
  clone_files
  export AS_FAKE_QUIT=graceful
  run_switcher swap tag-a --no-handoff
  # #11: the settings step runs after the quit, when nothing is running, so
  # an undetermined target before the quit no longer skips it.
  assert_rc 0 &&
    assert_contains "$out" "settings: 0 applied to tag-a" &&
    assert_call_order osascript mktemp &&
    assert_called osascript $'-e\ttell application "Claude" to quit' &&
    assert_called open "--user-data-dir=${AS_PROFILE_ROOT}/Claude-tag-a"
  result "swap: an undetermined target before the quit no longer skips the settings step (#11: it runs after the quit), then launches" $?
}

# ---- quit ------------------------------------------------------------------

case_quit_pid_set() {
  # Every PID in the table is alive to the kill fake, 700 included, so only
  # the matcher keeps 700 out of the set quit_all_claude tracks and signals.
  scenario ps-quit.txt ps-quit-after.txt
  export AS_FAKE_QUIT=graceful
  run_switcher quit --all
  local kills
  kills="$(calls_of kill)"
  assert_rc 0 &&
    assert_table_row 700 "/usr/bin/python3 -c pass ${AS_APP_BUNDLE}${APP_BIN_ROW_TEXT} " &&
    assert_contains "$(< "${AS_TEST_ROOT}/ps.txt")" "  700 " &&
    assert_contains "$kills" $'kill\t-0\t501' &&
    assert_contains "$kills" $'kill\t-0\t502' &&
    assert_not_contains "$kills" "700" &&
    assert_not_contains "$kills" "511" &&
    assert_contains "$err" "Existing instances quit"
  result "quit: the PID set holds the main processes only, never the non-Claude process that names the app path" $?
}

# ---- The app where detection looks -------------------------------------------

# The app's main binary is missing from where the matcher looks (the harness
# made a placeholder; this removes it). tag-a runs, [accounts] holds tag-a
# and tag-b, and primary's and tag-a's settings differ, so a sync would
# write.
app_missing_scene() {
  scenario ps-one-tag.txt
  printf '[accounts]\ntag-a = { label = "Alpha", profile_email = "" }\ntag-b = { label = "Beta", profile_email = "" }\n' \
    > "${AS_STORE}/config.toml"
  printf '{"preferences":{"keepAwakeEnabled":true}}\n' > "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json"
  printf '{"preferences":{"keepAwakeEnabled":false}}\n' > "${AS_PROFILE_ROOT}/Claude-tag-a/claude_desktop_config.json"
  /bin/rm -f "$APP_MAIN_BIN"
  [[ ! -e "$APP_MAIN_BIN" ]] || harness_error "the app binary placeholder is still there"
}

# Lines of $1 that contain $2.
n_lines_with() {
  local l n=0
  while IFS= read -r l; do [[ "$l" == *"$2"* ]] && n=$((n + 1)); done <<< "$1"
  printf '%d' "$n"
}

case_app_missing_refuses() {
  local bad="" spec want before calls
  local -a parts args
  app_missing_scene
  AS_TEST_STDIN_IS_TTY=1
  export AS_TEST_STDIN_IS_TTY
  before="$(tree_digest "$HOME")"
  for spec in "1|swap|tag-a|--no-handoff" "1|quit|--all" "1|clone-prefs|primary|tag-a" \
              "2|signin|tag-a|--yes" "2|update|--yes" "2|prefs|sync" "2|prefs|sync|tag-a" \
              "2|prefs|adopt|keep-awake|--from|tag-a" "2|prefs|review" "2|prefs|pin|tag-a|keep-awake" \
              "2|prefs|unpin|tag-a|keep-awake" "2|prefs|undo|tag-a" "2|reopen"; do
    IFS='|' read -r -a parts <<< "$spec"
    want="${parts[0]}"
    args=("${parts[@]:1}")
    : > "${AS_TEST_ROOT}/calls.log"
    run_switcher "${args[@]}"
    calls="$(calls_of ps)$(calls_of lsof)$(calls_of osascript)$(calls_of kill)$(calls_of open)"
    if [[ "$rc" != "$want" ]]; then bad="${bad} [${args[*]}]=exit${rc}"; fi
    if [[ "$err" != *"The Claude app's main binary is not at ${APP_MAIN_BIN}, which is where the switcher looks to tell which profiles are running"* ]]; then
      bad="${bad} [${args[*]}]=no-refusal-text"
    fi
    if [[ -n "$calls" ]]; then bad="${bad} [${args[*]}]=read-ps-or-signalled-or-opened"; fi
  done
  unset AS_TEST_STDIN_IS_TTY
  assert_eq "${bad# }" "" "commands that did not refuse as expected" &&
    assert_tree_unchanged "$HOME" "$before"
  result "the app's main binary is not where detection looks -> swap, quit, clone-prefs (exit 1), signin, update, reopen and every writing prefs verb (exit 2) refuse naming the path, before reading the process table, signalling, opening or writing anything (HOME unchanged)" $?
}

case_app_missing_warns() {
  local bad="" spec n
  local -a args
  app_missing_scene
  for spec in "list" "identity" "status" "prefs|diff" "prefs|sync|--dry-run" "launch|tag-a"; do
    IFS='|' read -r -a args <<< "$spec"
    run_switcher "${args[@]}"
    n="$(n_lines_with "$err" "The Claude app's main binary is not at ${APP_MAIN_BIN}, where the switcher looks for running instances")"
    if [[ "$n" != "1" ]]; then bad="${bad} [${args[*]}]=${n}-warnings"; fi
    case "${args[*]}" in
      list) [[ "$rc" == "0" && "$out" == *"=== Running Claude desktop app instances ==="* ]] || bad="${bad} [list]=exit${rc}" ;;
      identity) [[ "$rc" == "0" && "$out" == *"TAG"* ]] || bad="${bad} [identity]=exit${rc}" ;;
      status) [[ "$rc" == "0" && "$out" == *"=== Claude Code Account Switcher"* ]] || bad="${bad} [status]=exit${rc}" ;;
      "prefs diff") [[ "$rc" == "1" && "$out" == *"Synced settings (the allowlist)"* ]] || bad="${bad} [prefs diff]=exit${rc}" ;;
      "prefs sync --dry-run") [[ "$rc" != "2" && "$err" == *"settings (dry run)"* ]] || bad="${bad} [prefs sync --dry-run]=exit${rc}" ;;
      "launch tag-a") [[ "$rc" == "0" ]] && assert_called open "--user-data-dir=${AS_PROFILE_ROOT}/Claude-tag-a" > /dev/null || bad="${bad} [launch]=exit${rc}" ;;
    esac
  done
  assert_eq "${bad# }" "" "commands that did not warn once and carry on"
  result "the app's main binary is not where detection looks -> list, identity, status, prefs diff, prefs sync --dry-run and launch print one warning line naming the path and carry on" $?
}

# ---- No pgrep ----------------------------------------------------------------

# Prints "<executable lines naming pgrep> <executable lines with 'pgrep -f'>
# <comment lines with 'pgrep -f'>" for a copy of the script.
pgrep_counts() {
  /usr/bin/awk '
    /^[[:space:]]*#/ { if (index($0, "pgrep -f")) c++; next }
    index($0, "pgrep") { e++ }
    index($0, "pgrep -f") { f++ }
    END { printf "%d %d %d\n", e, f, c }
  ' "$1"
}

case_pgrep_lint() {
  local counts probe control
  counts="$(pgrep_counts "$SWITCHER")"
  new_sibling_dir
  probe="${SIBLING_DIR}/account-switcher.sh"
  /bin/cp "$SWITCHER" "$probe" || harness_error "cannot copy the script for the pgrep lint control"
  printf '%s\n' '  if pgrep -f "Claude" >/dev/null; then :; fi' >> "$probe"
  control="$(pgrep_counts "$probe")"
  set -- $counts
  local e="$1" f="$2" c="$3"
  set -- $control
  assert_eq "$e" "0" "executable lines naming pgrep" &&
    assert_eq "$f" "0" "executable lines with 'pgrep -f'" &&
    [[ "$c" -gt 0 ]] &&
    assert_eq "$1 $2" "1 1" "control: a planted executable pgrep -f line"
  result "lint: 'pgrep -f' appears only on comment lines (${c} of them); a planted call is caught" $?
}

case_pgrep_seam_removed() {
  local bins
  bins=" $(seam_bins) "
  assert_not_contains "$bins" " PGREP " &&
    assert_contains "$bins" " LSOF " &&
    assert_not_contains "$(< "$SWITCHER")" "AS_BIN_PGREP" &&
    assert_contains "$(seam_defaults)" "LSOF /usr/sbin/lsof" &&
    [[ ! -e "${LIB_DIR}/fakes/pgrep.sh" ]]
  result "seam: pgrep has no command, default, fake or seam name; lsof has all three" $?
}

case_lsof_recording_only() {
  new_case
  render_fixture "${LIB_DIR}/fakes/passthrough.sh" "${AS_FAKES_DIR}/lsof"
  /bin/chmod 755 "${AS_FAKES_DIR}/lsof"
  run_switcher version
  assert_rc 78 &&
    assert_contains "$err" "AS_BIN_LSOF is a passthrough fake but must be recording" &&
    assert_eq "$(< "${AS_TEST_ROOT}/calls.log")" "" "calls.log"
  result "seam: lsof is in the danger set; a pass-through lsof fake -> 78" $?
}

case_lsof_fake_guard() {
  new_case
  local o_none rc_none rc_bad
  o_none="$("$AS_BIN_LSOF" -w -Fn -p 4242)"
  rc_none=$?
  "$AS_BIN_LSOF" -w -Fn 2> /dev/null
  rc_bad=$?
  assert_eq "$rc_none" "1" "a PID with no fixture" &&
    assert_eq "$o_none" "" "output for a PID with no fixture" &&
    assert_eq "$rc_bad" "99" "a call without -p <pid>" &&
    assert_called lsof $'REFUSED'
  result "lsof fake: a PID without a fixture prints nothing (exit 1); a call without -p is refused (99)" $?
}

# ---- Scale -------------------------------------------------------------------

case_scale() {
  scenario
  # The match first, then 40,000 other processes: a reader that stopped at
  # the match would close the pipe while ps is still writing.
  /usr/bin/awk -v app="${AS_APP_BUNDLE}/Contents/MacOS/Claude" -v root="$AS_PROFILE_ROOT" 'BEGIN {
    print "  PID ARGS"
    printf "  502 %s --user-data-dir=%s/Claude-tag-a\n", app, root
    for (i = 0; i < 40000; i++) printf "%5d /usr/sbin/filler-daemon --serial=%d --flag=value\n", 10000 + i, i
  }' > "$AS_FIXTURE_PS"
  printf '{"sidebarMode":"source"}\n' > "${AS_PROFILE_ROOT}/Claude/claude_desktop_config.json"
  run_switcher clone-prefs primary tag-a
  assert_rc 1 &&
    assert_eq "$(count_lines "$(< "$AS_FIXTURE_PS")")" "40002" "table rows" &&
    assert_contains "$err" "Target instance ('tag-a') is currently running" &&
    assert_not_contains "$err" "Cannot tell"
  result "scale: a 40,000-row table with the match first still reads tag-a as running" $?
}

case_flagless_primary
case_space_path_tag
case_tag_prefix
case_primary_folder_whole
case_helpers_excluded
case_non_claude_excluded
case_two_flagless_resolved
case_two_flagless_inconclusive
case_unresolved_rows
case_ps_fails
case_list_reasons
case_detect_several_no_marker
case_detect_stale_marker
case_detect_one_instance
case_clone_primary_running
case_clone_primary_other_tags
case_clone_primary_writes
case_clone_primary_undetermined
case_clone_recheck
case_clone_tag_prefix
case_swap_mirror_undetermined
case_quit_pid_set
case_app_missing_refuses
case_app_missing_warns
case_pgrep_lint
case_pgrep_seam_removed
case_lsof_recording_only
case_lsof_fake_guard
case_scale
finish
