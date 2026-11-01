#!/usr/bin/env bash
# tests/t-07-signin.sh - #7: signin <tag> signs one tag in, leaves the other
# instances open by default, and compares every profile's identity before
# and after, so a login that lands in another open instance is reported
# (exit 4, naming that tag) rather than missed.
#
# Each case builds profile folders under the scratch profile root (primary,
# alpha, beta and fresh), a config.toml with labels, placeholder email
# values and pins, and a process table. Fixture ids are generated here, at
# test time, and written under the scratch root only; every config.json
# also holds placeholder strings under the two token-cache key names.
#
# Scenario changes happen between polls: signin runs AS_TEST_POLL_HOOK once
# per poll (test mode only), and the hook runs fake/step.<poll> when the
# case wrote one. So a terminal-mode case, whose timer is `read -t`, can
# stage a change mid-wait as well as a sleep-mode case, and the retry sleeps
# inside the identity read never advance the poll count.
#
# After every case: no placeholder token, no uuid-shaped string and no
# 64-hex run in stdout, stderr, the history log or any file under the case
# root, except the fixture config.json files (and, for ids only,
# config.toml, whose [identity] table holds the pins by design, as in t-06).
# A control case proves each scan can fail.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

fid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }
ID_P="$(fid 1)"      # pinned to primary
ID_A="$(fid 2)"      # pinned to alpha
ID_B="$(fid 3)"      # pinned to beta
ID_X="$(fid 9)"      # pinned to no tag

TOKEN_MARK="FIXTURE-NOT-A-TOKEN"
# The scenario helpers (fake/steps.sh) read the placeholder from here, so the
# literal is never in a file the scans read.
T7_TOKEN_MARK="$TOKEN_MARK"
export T7_TOKEN_MARK
UUID_ERE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
HEX64_ERE='[0-9a-fA-F]{64}'
LABEL_MARK="Lbl-Fixture"
MAIL_MARK="mailbox-fixture"
P_PID=501
A_PID=502
B_PID=503
NEW_PID=90001

# ---- Scenario ----------------------------------------------------------------

# The scenario helpers, written into each case as fake/steps.sh and sourced
# both here and by the per-poll hook. Real binaries only, by absolute path,
# so a step never goes through a fake or into calls.log.
steps_lib() {
  /bin/cat <<'STEPS'
fid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }
pdir() {
  if [[ "$1" == "primary" ]]; then printf '%s' "${AS_PROFILE_ROOT}/Claude"; else printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"; fi
}
# json_cfg [n]: a config.json with the two placeholder token caches,
# windowSizeWasSignedIn and three filler keys; with n, the identity key
# holds fixture id n.
json_cfg() {
  printf '{\n  "oauth:tokenCache": "%s-1",\n' "$T7_TOKEN_MARK"
  if [[ -n "${1:-}" ]]; then printf '  "lastKnownAccountUuid": "%s",\n' "$(fid "$1")"; fi
  printf '  "oauth:tokenCacheV2": "%s-2",\n  "windowSizeWasSignedIn": true,\n' "$T7_TOKEN_MARK"
  printf '  "fillerOne": 1,\n  "fillerTwo": "two",\n  "fillerThree": [3]\n}\n'
}
# record <tag> [n]: the tag's profile folder and its config.json.
record() { /bin/mkdir -p "$(pdir "$1")" && json_cfg "${2:-}" > "$(pdir "$1")/config.json"; }
# set_key <tag> <n>: the identity key now holds fixture id n (rewritten
# through a temp file and a rename, as the app does).
set_key() {
  local f
  f="$(pdir "$1")/config.json"
  /usr/bin/jq --arg v "$(fid "$2")" '.lastKnownAccountUuid = $v' "$f" > "${f}.next" && /bin/mv -f "${f}.next" "$f"
}
# churn <tag> <k>: every other key changes (a flag flips, a filler key comes
# and goes, the key order reverses); the identity key is untouched.
churn() {
  local f
  f="$(pdir "$1")/config.json"
  /usr/bin/jq --argjson k "$2" '.windowSizeWasSignedIn = (($k % 2) == 0)
    | (if ($k % 2) == 0 then del(.fillerTwo) else .fillerTwo = "two" end)
    | to_entries | reverse | from_entries' "$f" > "${f}.next" && /bin/mv -f "${f}.next" "$f"
}
# corrupt <tag>: a write cut off mid-file.
corrupt() { printf '{\n  "oauth:tokenCache": "%s-1",\n  "lastKnownAcc' "$T7_TOKEN_MARK" > "$(pdir "$1")/config.json"; }
# ps_line <pid>:<kind>: one row of the process table.
#   primary      the app binary with no --user-data-dir (flagless)
#   <tag>        the app binary with --user-data-dir=<the tag's folder>
#   custom       the app binary with a --user-data-dir no tag names
#   pager:<tag>  /usr/bin/less with the binary path and the tag's flag as arguments
#   grep         /usr/bin/grep with the binary path as its argument
ps_line() {
  local pid="${1%%:*}" kind="${1#*:}" bin="${AS_APP_BUNDLE}/Contents/MacOS/Claude"
  case "$kind" in
    primary) printf '%5s %s\n' "$pid" "$bin" ;;
    custom)  printf '%5s %s --user-data-dir=%s\n' "$pid" "$bin" "${AS_PROFILE_ROOT}/Custom Profile" ;;
    pager:*) printf '%5s /usr/bin/less %s --user-data-dir=%s\n' "$pid" "$bin" "$(pdir "${kind#pager:}")" ;;
    grep)    printf '%5s /usr/bin/grep %s\n' "$pid" "$bin" ;;
    *)       printf '%5s %s --user-data-dir=%s\n' "$pid" "$bin" "$(pdir "$kind")" ;;
  esac
}
# ps_add <pid>:<kind>: a process joins the table (and alive.txt).
ps_add() { ps_line "$1" >> "$AS_FIXTURE_PS"; printf '%s\n' "${1%%:*}" >> "${AS_TEST_ROOT}/alive.txt"; }
# ps_del <pid>: the process leaves the table (and alive.txt).
ps_del() {
  local row p rest="" first=1
  while IFS= read -r row || [[ -n "$row" ]]; do
    if [[ $first -eq 1 ]]; then first=0; rest="${rest}${row}"$'\n'; continue; fi
    p="${row#"${row%%[! ]*}"}"
    [[ "${p%% *}" == "$1" ]] && continue
    rest="${rest}${row}"$'\n'
  done < "$AS_FIXTURE_PS"
  printf '%s' "$rest" > "$AS_FIXTURE_PS"
  rest=""
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -z "$p" || "$p" == "$1" ]] && continue
    rest="${rest}${p}"$'\n'
  done < "${AS_TEST_ROOT}/alive.txt"
  printf '%s' "$rest" > "${AS_TEST_ROOT}/alive.txt"
}
# feed <line>: a line typed at the (simulated) terminal.
feed() { printf '%s\n' "$1" > "${AS_TEST_ROOT}/fake/stdin.fifo"; }
# send_int: Ctrl-C, delivered to the switcher (the hook's parent) with the
# shell's builtin kill.
send_int() { kill -INT "$PPID"; }
STEPS
}

# The per-poll hook: records the poll in calls.log and fake/tick, then runs
# fake/step.<poll> when the case wrote one.
install_hook() {
  local d="${AS_TEST_ROOT}/fake"
  /bin/cat > "${d}/hook.sh" <<'HOOK'
#!/bin/bash
set -u
d="${AS_TEST_ROOT}/fake"
printf '%s\n' "$1" > "${d}/tick"
printf 'hook\t%s\n' "$1" >> "${AS_TEST_ROOT}/calls.log"
. "${d}/steps.sh"
if [[ -f "${d}/step.$1" ]]; then . "${d}/step.$1"; fi
exit 0
HOOK
  /bin/chmod 755 "${d}/hook.sh" || harness_error "cannot chmod the hook"
  AS_TEST_POLL_HOOK="${d}/hook.sh"
  export AS_TEST_POLL_HOOK
}

# step <poll> <commands>: what happens at the start of that poll.
step() { printf '%s\n' "$2" > "${AS_TEST_ROOT}/fake/step.$1"; }

# write_config [alpha-unpinned]: [accounts] for primary, alpha and beta with
# fixture labels and placeholder email values, then [identity] pins.
write_config() {
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'primary = { label = "%s Primary", profile_email = "primary.%s" }\n' "$LABEL_MARK" "$MAIL_MARK"
    printf 'alpha = { label = "%s Alpha", profile_email = "alpha.%s" }\n' "$LABEL_MARK" "$MAIL_MARK"
    printf 'beta = { label = "%s Beta", profile_email = "beta.%s" }\n' "$LABEL_MARK" "$MAIL_MARK"
    printf '\n[identity]\n'
    printf 'primary = "%s"\n' "$ID_P"
    if [[ "${1:-}" != "alpha-unpinned" ]]; then printf 'alpha = "%s"\n' "$ID_A"; fi
    printf 'beta = "%s"\n' "$ID_B"
  } > "${AS_STORE}/config.toml"
}

# ps_table <pid>:<kind> ...: the process table (ps_line kinds) and alive.txt.
ps_table() {
  local spec
  printf '  PID ARGS\n' > "$AS_FIXTURE_PS"
  : > "${AS_TEST_ROOT}/alive.txt"
  for spec; do ps_add "$spec"; done
}

# A case: primary (on its pinned account), alpha (signed in to nothing yet),
# beta (on its pinned account) and fresh (not in [accounts], no account);
# primary and beta running; the next open starts PID $NEW_PID.
scenario() {
  new_case
  unset AS_TEST_STDIN_IS_TTY AS_TEST_POLL_HOOK T7_TRACE
  HOLDER=""
  /bin/mkdir -p "$AS_STORE" "${AS_TEST_ROOT}/control" "${AS_TEST_ROOT}/fake" || harness_error "cannot create the case folders"
  steps_lib > "${AS_TEST_ROOT}/fake/steps.sh"
  # shellcheck source=/dev/null
  . "${AS_TEST_ROOT}/fake/steps.sh"
  install_hook
  write_config
  record primary 1
  record alpha
  record beta 3
  record fresh
  json_cfg 9 > "${AS_TEST_ROOT}/control/config.json"
  ps_table "${P_PID}:primary" "${B_PID}:beta"
  AS_FAKE_OPEN_SPAWNS_PID="$NEW_PID"
  export AS_FAKE_OPEN_SPAWNS_PID
}

# Makes fake/stdin.fifo and holds it open read-write in the background, so a
# read on it times out instead of ending; sets FIFO and HOLDER.
tty_fifo() {
  FIFO="${AS_TEST_ROOT}/fake/stdin.fifo"
  /usr/bin/mkfifo "$FIFO" || harness_error "cannot make the fifo"
  ( exec 3<> "$FIFO"; exec /bin/sleep 60 ) &
  HOLDER=$!
  AS_TEST_STDIN_IS_TTY=1
  export AS_TEST_STDIN_IS_TTY
}

# Stops this case's fifo holder (a /bin/sleep this file started).
release_fifo() {
  if [[ -n "${HOLDER:-}" ]]; then
    kill "$HOLDER" 2> /dev/null
    wait "$HOLDER" 2> /dev/null
    HOLDER=""
  fi
}

# Appends the last run's stdout and stderr to the case transcript, which the
# secret scans read along with every other file under the root.
keep_run() { printf '%s\n%s\n' "$out" "$err" >> "${AS_TEST_ROOT}/transcript.txt"; }

# run_si <stdin> <arg> ...: runs the switcher in test mode with stdin from
# <stdin>, from inside the case root; up to nine arguments, each passed on
# its own (signin skips an empty one). Sets out, err and rc.
run_si() {
  local in="$1" o="${AS_TEST_ROOT}/.run-out" e="${AS_TEST_ROOT}/.run-err"
  shift
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$SWITCHER" "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}"
  ) > "$o" 2> "$e" < "$in"
  rc=$?
  _read_run "$o" "$e"
  keep_run
}

# run_si_bg <stdin> <arg> ...: the same in the background; sets SI_PID and
# writes it to switcher.pid. wait_si collects it.
run_si_bg() {
  local in="$1" o="${AS_TEST_ROOT}/.run-out" e="${AS_TEST_ROOT}/.run-err"
  shift
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$SWITCHER" "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}"
  ) > "$o" 2> "$e" < "$in" &
  SI_PID=$!
  printf '%s\n' "$SI_PID" > "${AS_TEST_ROOT}/switcher.pid"
}

wait_si() {
  wait "$SI_PID"
  rc=$?
  _read_run "${AS_TEST_ROOT}/.run-out" "${AS_TEST_ROOT}/.run-err"
  keep_run
}

# wait_out <text>: waits (up to 15 s) until the background run's stdout holds <text>.
wait_out() {
  local i=0
  while [[ $i -lt 150 ]]; do
    if [[ -f "${AS_TEST_ROOT}/.run-out" && "$(< "${AS_TEST_ROOT}/.run-out")" == *"$1"* ]]; then return 0; fi
    /bin/sleep 0.1
    i=$((i + 1))
  done
  printf '    the run never printed: %s\n' "$1"
  return 1
}

history_text() {
  if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi
}

# The last line of $1.
last_line() {
  local l last=""
  while IFS= read -r l; do last="$l"; done <<< "$1"
  printf '%s' "$last"
}

# The poll the hook last recorded (0 when no poll ran).
ticks() {
  local t=0
  if [[ -f "${AS_TEST_ROOT}/fake/tick" ]]; then IFS= read -r t < "${AS_TEST_ROOT}/fake/tick"; fi
  printf '%s' "$t"
}

# count_calls <line>: the calls.log lines equal to <line>.
count_calls() {
  local l n=0
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ "$l" == "$1" ]] && n=$((n + 1))
  done < "${AS_TEST_ROOT}/calls.log"
  printf '%s' "$n"
}

# assert_summary <expected summary line>: the last stdout line is it.
assert_summary() { assert_eq "$(last_line "$out")" "$1" "summary (last stdout line)"; }

# assert_no_open_or_quit: no fake open or osascript call at all.
assert_no_open_or_quit() { assert_never_called open && assert_never_called osascript; }

# assert_left_running <pid> ...: each PID is still alive (the kill fake and
# a graceful quit both remove what they stop), and nothing ran the quit
# script or kill (bring_to_front's activations are not quits).
assert_left_running() {
  local p alive
  alive="$(< "${AS_TEST_ROOT}/alive.txt")"
  for p; do
    [[ $'\n'"${alive}"$'\n' == *$'\n'"${p}"$'\n'* ]] || { printf '    PID %s is no longer running\n' "$p"; return 1; }
  done
  assert_not_contains "$(calls_of osascript)" "to quit" && assert_never_called kill
}

# ---- Secret scans --------------------------------------------------------------

# raw_hits <token|ids|hex> <path>: files under <path> holding a placeholder
# token (any case), a uuid-shaped string or a 64-hex run. FIFOs are skipped
# (-D skip): a terminal-mode case's stdin fifo is not a file anything is
# written to, and opening one with no writer would block.
raw_hits() {
  case "$1" in
    token) /usr/bin/grep -rlaiF -D skip -e "$TOKEN_MARK" -- "$2" 2> /dev/null ;;
    ids)   /usr/bin/grep -rlaE -D skip -e "$UUID_ERE" -- "$2" 2> /dev/null ;;
    hex)   /usr/bin/grep -rlaE -D skip -e "$HEX64_ERE" -- "$2" 2> /dev/null ;;
  esac
  return 0
}

# is_exempt <kind> <file>: the fixture config.json files and the control
# fixture are exempt; config.toml for ids only (its [identity] table is
# where pins live, by design); a trace a case names in T7_TRACE for ids and
# hex only (xtrace shows digests and the target's own id, by design).
is_exempt() {
  case "$2" in
    "${AS_PROFILE_ROOT}/Claude/config.json"|"${AS_PROFILE_ROOT}/Claude-"*/config.json|"${AS_TEST_ROOT}/control/"*) return 0 ;;
  esac
  if [[ "$1" == "ids" && "$2" == "${AS_STORE}/config.toml" ]]; then return 0; fi
  if [[ "$1" != "token" && -n "${T7_TRACE:-}" && "$2" == "$T7_TRACE" ]]; then return 0; fi
  return 1
}

secret_hits() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    is_exempt "$1" "$f" && continue
    printf '%s\n' "$f"
  done < <(raw_hits "$1" "$AS_TEST_ROOT")
}

# assert_no_secrets: no placeholder token, uuid-shaped string or 64-hex run
# in any run's stdout or stderr (transcript.txt), the history log or any
# other file under the case root.
assert_no_secrets() {
  local k found
  for k in token ids hex; do
    found="$(secret_hits "$k")"
    if [[ -n "$found" ]]; then printf '    %s found in:\n%s\n' "$k" "$found"; return 1; fi
  done
  return 0
}

# Every history row is one signin may write (or the pin's row), and holds no
# fixture label, placeholder email, uuid-shaped string or 64-hex run (case
# 19 tallies these over every case).
ROWS_SEEN=0
ROWS_BAD=0
row_ok() {
  local re='^\[[0-9TZ:-]+\] (SIGNIN|SIGNIN_OTHER|IDENTITY|IDENTITY_PIN|LAUNCH|QUIT_ALL)( |$)'
  [[ "$1" =~ $re ]] || return 1
  [[ "$1" != *"$LABEL_MARK"* && "$1" != *"$MAIL_MARK"* ]] || return 1
  [[ ! "$1" =~ $UUID_ERE ]] || return 1
  [[ ! "$1" =~ $HEX64_ERE ]] || return 1
  return 0
}

assert_rows_clean() {
  local l bad=0 log="${AS_STORE}/swap-history.log"
  [[ -f "$log" ]] || return 0
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ -n "$l" ]] || continue
    ROWS_SEEN=$((ROWS_SEEN + 1))
    if ! row_ok "$l"; then printf '    history row breaks the row rule: %s\n' "$l"; bad=1; fi
  done < "$log"
  if [[ $bad -ne 0 ]]; then ROWS_BAD=$((ROWS_BAD + 1)); return 1; fi
  return 0
}

# What every case ends with.
assert_clean() { assert_no_secrets && assert_rows_clean; }

finish_case() {  # $1 = name, $2 = status
  release_fifo
  result "$1" "$2"
}

# ---- Cases 1-7: the default mode (other instances left open) ------------------

C1_OUT="" C1_ERR="" C1_RC="" C1_LOG="" C1_TICK=""

case_1_match() {
  scenario
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha
  C1_OUT="$out" C1_ERR="$err" C1_RC="$rc" C1_LOG="$(history_text)" C1_TICK="$(ticks)"
  assert_rc 0 &&
    assert_contains "$out" "Sign in tag 'alpha' as \"${LABEL_MARK} Alpha\" (alpha.${MAIL_MARK})." &&
    assert_contains "$out" "Open Claude instances, left running: primary · PID ${P_PID}, beta · PID ${B_PID}" &&
    assert_contains "$out" "choose \"Continue with email\", enter alpha.${MAIL_MARK}, then type the code" &&
    assert_contains "$out" "make sure the browser is signed into alpha.${MAIL_MARK} first" &&
    assert_contains "$out" "Opened 'alpha' (PID ${NEW_PID})." &&
    assert_contains "$out" "✓ 'alpha' is signed into \"${LABEL_MARK} Alpha\" (match)." &&
    assert_contains "$out" "Watching the other instances for 20 s" &&
    assert_eq "$(count_lines "$(calls_of open)")" "1" "open calls" &&
    assert_called open "--user-data-dir=$(pdir alpha)" &&
    assert_eq "$(count_calls "sleep"$'\t'"2")" "11" "2 s sleeps (1 wait poll + 10 settle polls)" &&
    assert_eq "$(ticks)" "12" "polls" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_contains "$(history_text)" "SIGNIN tag=alpha mode=others-open result=match detail=changed others_changed=0 others_unverified=0" &&
    assert_contains "$(history_text)" "IDENTITY tag=alpha status=match" &&
    assert_contains "$(history_text)" "LAUNCH tag=alpha" &&
    assert_left_running "$P_PID" "$B_PID" "$NEW_PID" &&
    assert_clean
  finish_case "1. signin alpha with primary and beta open: label, email, email-code advice and the open list first; one open; alpha's account appears -> match, exit 0" $?
}

# check_case2 <stdout> <stderr> <exit> <history> <polls>: case 2's assertion,
# as a function so control arm 2c can run it on case 1's clean output.
check_case2() {
  [[ "$3" == "4" ]] || { printf '    case 2: exit %s, not 4\n' "$3"; return 1; }
  [[ "$2" == *MISMATCH*"profile 'beta' changed during this sign-in"* ]] || { printf "    case 2: no MISMATCH block naming 'beta'\n"; return 1; }
  [[ "$5" =~ ^[0-9]+$ && "$5" -le 3 ]] || { printf '    case 2: the wait ran %s polls, not at most 3\n' "$5"; return 1; }
  [[ "$4" == *"SIGNIN_OTHER tag=beta change=changed during=alpha"* ]] || { printf '    case 2: no SIGNIN_OTHER row for beta\n'; return 1; }
  [[ "$1" == *"others_changed=1"* ]] || { printf '    case 2: the summary does not count the change\n'; return 1; }
  return 0
}

case_2_other_changes() {
  scenario
  step 2 'set_key beta 7'
  run_si /dev/null signin alpha --settle 0
  check_case2 "$out" "$err" "$rc" "$(history_text)" "$(ticks)" &&
    assert_contains "$out" "Stopping: profile 'beta' changed (see below)." &&
    assert_contains "$err" "Before: had a recorded account. Now: an unrecognized account (MISMATCH)." &&
    assert_contains "$err" "account-switcher signin beta --quit-others" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=other-changed recorded_as=none others_checked=3 others_changed=1 others_unverified=0 exit=4" &&
    assert_clean
  finish_case "2. another profile's identity changes mid-wait -> MISMATCH naming beta, the wait stops within one poll, exit 4" $?
}

case_2c_control() {
  local r=0
  if [[ -z "$C1_RC" ]]; then printf '    case 1 did not run\n'; finish_case "2c. control arm" 1; return; fi
  check_case2 "$C1_OUT" "$C1_ERR" "$C1_RC" "$C1_LOG" "$C1_TICK" > /dev/null || r=$?
  [[ $r -ne 0 ]]
  finish_case "2c. control arm: case 2's assertion run on case 1's clean output fails (so case 2's check can fail)" $?
}

case_3_same_tick() {
  scenario
  step 2 'set_key alpha 2; set_key primary 9'
  run_si /dev/null signin alpha --settle 0
  assert_rc 4 &&
    assert_contains "$out" "✓ 'alpha' is signed into \"${LABEL_MARK} Alpha\" (match)." &&
    assert_contains "$err" "profile 'primary' changed during this sign-in" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=1 others_unverified=0 exit=4" &&
    assert_clean
  finish_case "3. the target reads match and primary changes in the same poll -> both reported, exit 4 (4 wins over 0)" $?
}

case_4_churn() {
  scenario
  local k before after
  k=1
  while [[ $k -le 8 ]]; do step "$k" "churn beta $k"; k=$((k + 1)); done
  step 3 'churn beta 3; set_key alpha 2'
  before="$(/usr/bin/shasum < "$(pdir beta)/config.json")"
  run_si /dev/null signin alpha --settle 6
  after="$(/usr/bin/shasum < "$(pdir beta)/config.json")"
  assert_rc 0 &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_eq "$(ticks)" "6" "polls (3 wait, 3 settle)" &&
    { [[ "$before" != "$after" ]] || { printf "    control: beta's config.json did not change, so the churn never ran\n"; false; }; } &&
    assert_clean
  finish_case "4. every poll rewrites beta's other keys (a whole-file checksum changes), its identity does not -> unchanged, exit 0" $?
}

case_5_running_target() {
  scenario
  record alpha 9
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta"
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_never_called open &&
    assert_contains "$out" "Using the running instance for 'alpha' (PID ${A_PID}); not opening another." &&
    assert_contains "$out" "sign out from the app's account menu first; then sign in as \"${LABEL_MARK} Alpha\"" &&
    assert_contains "$out" "Open Claude instances, left running: primary · PID ${P_PID}, beta · PID ${B_PID}" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_left_running "$P_PID" "$A_PID" "$B_PID" &&
    assert_clean
  finish_case "5. the target is already running -> that instance is used, no open, completes on the change, exit 0" $?
}

case_6_primary_nothing_running() {
  scenario
  record primary 9
  ps_table
  step 2 'set_key primary 1'
  run_si /dev/null signin primary --settle 0
  assert_rc 0 &&
    assert_eq "$(count_lines "$(calls_of open)")" "1" "open calls" &&
    assert_not_contains "$(calls_of open)" "--user-data-dir" &&
    assert_contains "$out" "Opened 'primary' (PID ${NEW_PID})." &&
    assert_not_contains "$err" "a primary instance started" &&
    assert_summary "signin tag=primary mode=others-open result=match detail=changed recorded_as=primary others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "6. signin primary with nothing running: open with no flag, the new flagless PID is the target (no 'primary started' warning), exit 0" $?
}

case_6b_primary_running() {
  scenario
  record primary 9
  step 2 'set_key primary 1'
  run_si /dev/null signin default --settle 0
  assert_rc 0 &&
    assert_never_called open &&
    assert_contains "$out" "Using the running instance for 'primary' (PID ${P_PID}); not opening another." &&
    assert_not_contains "$err" "a primary instance started" &&
    assert_summary "signin tag=primary mode=others-open result=match detail=changed recorded_as=primary others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "6b. signin default (primary) with primary running: its instance is used, no open, exit 0" $?
}

case_7_flagless_appears() {
  scenario
  ps_table "${B_PID}:beta"
  step 3 'ps_add 90002:primary'
  step 4 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_contains "$err" "a primary instance started during sign-in (PID 90002); the login may land in primary." &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "7. target alpha; a flagless (primary) instance appears mid-wait -> a warning naming its PID; primary unchanged -> exit 0" $?
}

case_7b_flagless_lands() {
  scenario
  ps_table "${B_PID}:beta"
  step 3 'ps_add 90002:primary'
  step 4 'set_key alpha 2; set_key primary 9'
  run_si /dev/null signin alpha --settle 0
  assert_rc 4 &&
    assert_contains "$err" "a primary instance started during sign-in (PID 90002)" &&
    assert_contains "$err" "profile 'primary' changed during this sign-in" &&
    assert_contains "$(history_text)" "SIGNIN_OTHER tag=primary change=changed during=alpha" &&
    assert_clean
  finish_case "7b. the same, and primary's identity changes -> MISMATCH naming primary, exit 4" $?
}

# ---- Cases 8-8d: completion by the operator at a terminal ---------------------
#
# Same-account re-sign-in: alpha is running and already records its pinned
# account, so nothing on disk changes; only a typed y completes it. stdin is
# a fifo held open (a read on it times out, as at a quiet terminal), and the
# hook types into it at a given poll.

tty_alpha_same_account() {
  scenario
  record alpha 2
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta"
  tty_fifo
}

case_8_typed_y() {
  tty_alpha_same_account
  step 1 'feed y'
  run_si "$FIFO" signin alpha --settle 0
  assert_rc 0 &&
    assert_contains "$out" "Does the 'alpha' window show you signed in as \"${LABEL_MARK} Alpha\"? [y/N]" &&
    assert_contains "$out" "✓ 'alpha' is recorded as \"${LABEL_MARK} Alpha\" (match; the recorded account did not change, so signin could not see the sign-in itself)." &&
    assert_eq "$(ticks)" "1" "polls" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=unchanged recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "8. same-account re-sign-in at a terminal: y typed at poll 1 -> match, detail=unchanged, exit 0" $?
}

case_8b_quiet_then_y() {
  tty_alpha_same_account
  step 3 'feed y'
  run_si "$FIFO" signin alpha --settle 0
  assert_rc 0 &&
    assert_eq "$(ticks)" "3" "polls (two read timeouts, then the answer)" &&
    assert_not_contains "$out" "Input ended" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=unchanged recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "8b. no input for two polls (read -t times out with status 1 on bash 3.2), then y -> completes at poll 3, detail=unchanged (fails against the old status mapping)" $?
}

case_8c_buffered_input() {
  tty_alpha_same_account
  release_fifo
  printf 'y\n\n' > "${AS_TEST_ROOT}/fake/typed-ahead.txt"
  run_si "${AS_TEST_ROOT}/fake/typed-ahead.txt" signin alpha --timeout 30 --settle 0
  assert_rc 3 &&
    assert_eq "$(ticks)" "15" "polls (no completion at poll 1; the timeout)" &&
    assert_contains "$out" "Input ended, so signin no longer reads an answer" &&
    assert_contains "$out" "? 'alpha': sign-in not seen within 30s (unknown)." &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=timeout recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "8c. a y and an Enter typed before the prompt are drained and never complete it -> no match at poll 1; timeout, exit 3" $?
}

case_8d_bare_enter() {
  tty_alpha_same_account
  step 1 'feed ""'
  step 2 'feed y'
  local n
  run_si "$FIFO" signin alpha --settle 0
  n="$(printf '%s' "$out" | /usr/bin/grep -o "Does the 'alpha' window show you signed in" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  assert_rc 0 &&
    assert_eq "$(ticks)" "2" "polls" &&
    assert_eq "$n" "2" "times the question was asked" &&
    assert_contains "$out" "detail=unchanged" &&
    assert_clean
  finish_case "8d. a bare Enter does not complete it; the question is asked again, and y at poll 2 completes, exit 0" $?
}

# ---- Cases 9-11: timeout, the target exiting, MISMATCH --------------------------

case_9_timeout() {
  scenario
  record alpha 2
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta"
  run_si /dev/null signin alpha --timeout 30 --settle 0
  assert_rc 3 &&
    assert_eq "$(count_calls "sleep"$'\t'"2")" "15" "2 s sleeps (time counted in polls)" &&
    assert_eq "$(ticks)" "15" "polls" &&
    assert_contains "$out" "? 'alpha': sign-in not seen within 30s (unknown)." &&
    assert_not_contains "$out" "(match)" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=timeout recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "9. no change and no answer, --timeout 30 -> exactly 15 polls; unknown (never match, though the pin already equals), detail=timeout, exit 3" $?
}

case_9b_timeout_mismatch() {
  scenario
  record alpha 3
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta"
  run_si /dev/null signin alpha --timeout 30 --settle 0
  assert_rc 1 &&
    assert_contains "$out" "✗ 'alpha' is recorded as beta's account, not \"${LABEL_MARK} Alpha\" (MISMATCH)." &&
    assert_summary "signin tag=alpha mode=others-open result=MISMATCH detail=timeout recorded_as=beta others_checked=3 others_changed=0 others_unverified=0 exit=1" &&
    assert_clean
  finish_case "9b. a timeout while the target records another tag's account -> MISMATCH, exit 1 (the only exit 1 path)" $?
}

case_10_target_exited() {
  scenario
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta"
  step 2 "ps_del ${A_PID}"
  run_si /dev/null signin alpha --settle 0
  assert_rc 3 &&
    assert_eq "$(ticks)" "3" "polls (two misses)" &&
    assert_contains "$out" "The 'alpha' instance exited before sign-in finished. If a browser tab or an emailed code is still pending, don't complete it:" &&
    assert_contains "$out" "Check again in a minute with: account-switcher identity --all" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=target-exited recorded_as=none others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "10. the target's process is gone on two polls in a row -> the 'don't complete it' message, detail=target-exited, exit 3" $?
}

case_10b_restarted() {
  scenario
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta"
  step 2 "ps_del ${A_PID}; ps_add 90003:alpha"
  step 3 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_contains "$out" "following the restarted instance (PID 90003)" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "10b. the target's process is replaced by a new one on the same profile -> followed, completes, exit 0" $?
}

case_11_mismatch() {
  scenario
  step 2 'set_key alpha 3'
  run_si /dev/null signin alpha --settle 0
  assert_rc 1 &&
    assert_contains "$out" "✗ 'alpha' is recorded as beta's account, not \"${LABEL_MARK} Alpha\" (MISMATCH). In the 'alpha' window, sign out, then run: account-switcher signin alpha" &&
    assert_summary "signin tag=alpha mode=others-open result=MISMATCH detail=changed recorded_as=beta others_checked=3 others_changed=0 others_unverified=0 exit=1" &&
    assert_contains "$(history_text)" "IDENTITY tag=alpha status=MISMATCH" &&
    assert_clean
  finish_case "11. alpha's new account is beta's pin -> MISMATCH naming beta's account, exit 1" $?
}

# ---- Cases 12-12c: no pin yet ----------------------------------------------------

case_12_new_tag() {
  scenario
  step 2 'record newtag 2'
  run_si /dev/null signin newtag --new --settle 0
  assert_rc 3 &&
    assert_contains "$out" "Sign in tag 'newtag' (not in [accounts]; no configured account to check against)." &&
    assert_contains "$out" "enter the account you intend for this tag" &&
    assert_called open "--user-data-dir=$(pdir newtag)" &&
    assert_contains "$out" "? 'newtag': no pin (unknown)." &&
    assert_contains "$out" "It is recorded as alpha's account." &&
    assert_contains "$out" "Not in [accounts]: add it with account-switcher add-account newtag <email>, then account-switcher identity pin newtag" &&
    assert_not_contains "$out" "Pin 'newtag'" &&
    assert_summary "signin tag=newtag mode=others-open result=unknown detail=unpinned recorded_as=alpha others_checked=4 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "12. signin newtag --new (the live test's shape): its account appears -> unknown, detail=unpinned, the add-account then pin steps, no pin prompt, exit 3" $?
}

case_12b_pin_offer() {
  scenario
  write_config alpha-unpinned
  tty_fifo
  step 2 'set_key alpha 2'
  local asked=0
  run_si_bg "$FIFO" signin alpha --settle 0
  wait_out "Pin 'alpha' to this account now? [y/N]" || asked=1
  # Answer either way, so a missed prompt can't leave the run blocked.
  feed y
  wait_si
  assert_eq "$asked" "0" "the pin question was asked" &&
    assert_rc 3 &&
    assert_contains "$out" "? 'alpha': no pin (unknown)." &&
    assert_contains "$out" "Pinned. account-switcher identity alpha now reads match" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=unpinned recorded_as=unrecognized others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_contains "$(< "${AS_STORE}/config.toml")" "alpha = \"${ID_A}\"" &&
    assert_contains "$(history_text)" "IDENTITY_PIN tag=alpha" &&
    assert_clean
  finish_case "12b. an unpinned tag in [accounts] at a terminal: the pin is offered after the drain, y pins it in a subshell, and signin still exits 3" $?
}

case_12c_no_offer_pinned_elsewhere() {
  scenario
  write_config alpha-unpinned
  AS_TEST_STDIN_IS_TTY=1
  export AS_TEST_STDIN_IS_TTY
  step 2 'set_key alpha 3'
  run_si /dev/null signin alpha --settle 0
  assert_rc 3 &&
    assert_contains "$out" "It is recorded as beta's account." &&
    assert_contains "$out" "identity pin refuses an account already pinned to another tag" &&
    assert_not_contains "$out" "Pin 'alpha'" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=unpinned recorded_as=beta others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "12c. at a terminal, but the new account is pinned to beta -> no pin offer (identity pin would refuse), the next step instead, exit 3" $?
}

# ---- Cases 13-14: a profile that can't be read ---------------------------------

case_13_unreadable_left() {
  scenario
  step 2 'corrupt beta'
  step 3 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 4 &&
    assert_contains "$err" "UNVERIFIED:" &&
    assert_contains "$err" "profile 'beta' could not be re-checked (its identity can't be read). signin can't confirm it is unchanged." &&
    assert_contains "$(history_text)" "SIGNIN_OTHER tag=beta change=unverified during=alpha" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=1 exit=4" &&
    assert_clean
  finish_case "13. beta's config.json is torn mid-wait and stays torn -> UNVERIFIED naming beta, exit 4 (even with the target at match)" $?
}

case_13b_unreadable_restored() {
  scenario
  step 2 'corrupt beta'
  step 3 'record beta 3'
  step 4 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_eq "$(ticks)" "4" "polls (the retry sleeps did not advance the poll count)" &&
    { [[ "$(count_calls "sleep"$'\t'"1")" -ge 2 ]] || { printf '    the torn read was not retried\n'; false; }; } &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "13b. beta torn at poll 2 and whole again at poll 3 -> the torn read is retried, not a stop, and settles clean, exit 0" $?
}

case_14_unreadable_before_refused() {
  scenario
  corrupt beta
  run_si /dev/null signin alpha --settle 0
  assert_rc 2 &&
    assert_contains "$err" "can't read the identity of 'beta'; signin can't protect it." &&
    assert_contains "$err" "there is no terminal to ask; nothing was opened" &&
    assert_no_open_or_quit &&
    assert_clean
  finish_case "14. beta can't be read before the start, no terminal, no --yes -> refused, nothing opened, exit 2" $?
}

case_14b_unreadable_before_yes() {
  scenario
  corrupt beta
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha --yes --settle 0
  assert_rc 4 &&
    assert_called open "--user-data-dir=$(pdir alpha)" &&
    assert_contains "$err" "profile 'beta' could not be re-checked" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=1 exit=4" &&
    assert_clean
  finish_case "14b. the same with --yes -> it goes on, and beta is UNVERIFIED at the end, exit 4" $?
}

# ---- Cases 15-15d: --quit-others ----------------------------------------------

# alpha (the target) and beta running; a graceful quit leaves an empty table
# (its header line kept, which the ps fake skips).
quit_scenario() {
  scenario
  ps_table "${A_PID}:alpha" "${B_PID}:beta"
  printf '  PID ARGS\n' > "$AS_FIXTURE_PS_AFTER_QUIT"
  AS_FAKE_QUIT=graceful
  export AS_FAKE_QUIT
}

case_15_quit_no_terminal() {
  quit_scenario
  run_si /dev/null signin alpha --quit-others
  assert_rc 2 &&
    assert_contains "$out" "  alpha · PID ${A_PID}  (target: will be quit and reopened)" &&
    assert_contains "$out" "  beta · PID ${B_PID}" &&
    assert_contains "$out" "--quit-others quits every Claude instance listed above (work in progress in them may be lost), then opens 'alpha' alone." &&
    assert_contains "$err" "--quit-others needs a terminal to confirm the list, or --yes. Nothing was quit." &&
    assert_no_open_or_quit &&
    assert_clean
  finish_case "15. --quit-others with no terminal and no --yes -> the list (target marked), no quit, nothing opened, exit 2" $?
}

case_15b_quit_yes() {
  quit_scenario
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha --quit-others --yes --settle 0
  assert_rc 0 &&
    assert_called osascript "to quit" &&
    assert_call_order osascript open &&
    assert_eq "$(count_lines "$(calls_of open)")" "1" "open calls" &&
    assert_called open "--user-data-dir=$(pdir alpha)" &&
    assert_eq "$(< "${AS_TEST_ROOT}/alive.txt")" "${NEW_PID}" "processes alive after the run (only the target)" &&
    { ! assert_left_running "$B_PID" > /dev/null || { printf '    control: assert_left_running passed after a quit\n'; false; }; } &&
    assert_contains "$(history_text)" "QUIT_ALL" &&
    assert_summary "signin tag=alpha mode=quit-others result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "15b. --quit-others --yes -> the list, quit through quit_all_claude, QUIT_ALL row, alpha opened alone, mode=quit-others, exit 0" $?
}

# A ps fake that adds a process to the table after its second call (signin's
# instance scan), so the quit path's own read sees a PID nobody confirmed.
ps_fake_grows() {
  /bin/cat > "${AS_FAKES_DIR}/ps" <<'FAKE'
#!/bin/bash
# as-fake: recording
line="ps"
for arg; do line="${line}"$'\t'"${arg}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
n=0
[[ -f "${AS_TEST_ROOT}/ps-count" ]] && IFS= read -r n < "${AS_TEST_ROOT}/ps-count"
n=$((n + 1))
printf '%s\n' "$n" > "${AS_TEST_ROOT}/ps-count"
first=1
while IFS= read -r row || [[ -n "$row" ]]; do
  if [[ $first -eq 1 ]]; then first=0; continue; fi
  printf '%s\n' "$row"
done < "$AS_FIXTURE_PS"
if [[ $n -eq 2 ]]; then
  printf '%5s %s --user-data-dir=%s\n' 504 "${AS_APP_BUNDLE}/Contents/MacOS/Claude" "${AS_PROFILE_ROOT}/Claude-fresh" >> "$AS_FIXTURE_PS"
  printf '504\n' >> "${AS_TEST_ROOT}/alive.txt"
fi
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/ps" || harness_error "cannot chmod the ps fake"
}

case_15c_quit_set_differs() {
  quit_scenario
  ps_fake_grows
  run_si /dev/null signin alpha --quit-others --yes
  assert_rc 2 &&
    assert_contains "$err" "The quit path would signal processes that weren't listed (PID 504). Nothing was quit" &&
    assert_no_open_or_quit &&
    assert_clean
  finish_case "15c. the PIDs the quit path would signal differ from the confirmed list -> refused before any quit, exit 2" $?
}

# An osascript fake that, on the quit script, sends TERM to the switcher
# (switcher.pid) and then quits every app, as AS_FAKE_QUIT=graceful does.
# TERM, not INT: this case runs the switcher in the background, and bash
# starts a background command with SIGINT ignored, which a script cannot
# trap. INT and TERM share one handler; case 18 sends INT in the foreground.
osascript_fake_interrupts() {
  /bin/cat > "${AS_FAKES_DIR}/osascript" <<'FAKE'
#!/bin/bash
# as-fake: recording
line="osascript"
for arg; do line="${line}"$'\t'"${arg}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
quit=0
for arg; do case "$arg" in *" to quit") quit=1 ;; esac; done
[[ $quit -eq 1 ]] || exit 0
i=0
while [[ ! -s "${AS_TEST_ROOT}/switcher.pid" && $i -lt 50 ]]; do /bin/sleep 0.1; i=$((i + 1)); done
IFS= read -r pid < "${AS_TEST_ROOT}/switcher.pid"
kill -TERM "$pid"
: > "${AS_TEST_ROOT}/alive.txt"
printf '  PID ARGS\n' > "$AS_FIXTURE_PS"
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/osascript" || harness_error "cannot chmod the osascript fake"
}

case_15d_quit_interrupted() {
  quit_scenario
  osascript_fake_interrupts
  run_si_bg /dev/null signin alpha --quit-others --yes
  wait_si
  assert_rc 2 &&
    assert_contains "$out" "Interrupted while quitting. Listed before the quit: PIDs ${A_PID} ${B_PID}." &&
    assert_contains "$out" "Nothing was signed in." &&
    assert_contains "$(history_text)" "QUIT_ALL" &&
    assert_never_called open &&
    assert_clean
  finish_case "15d. a stop signal (TERM) while quit_all_claude runs -> the QUIT_ALL row, what was listed and what still runs, nothing opened, exit 2" $?
}

case_15e_quit_unlisted_appears() {
  # fresh (PID 504) is opened from the Dock while the quit runs: the graceful
  # quit closes alpha and beta and leaves fresh's instance in the table. The
  # quit signals only the confirmed PIDs, so 504 is named, never signalled.
  quit_scenario
  ps_line 504:fresh >> "$AS_FIXTURE_PS_AFTER_QUIT"
  run_si /dev/null signin alpha --quit-others --yes --settle 0
  local k
  k="$(calls_of kill)"
  assert_rc 2 &&
    assert_called osascript "to quit" &&
    assert_contains "$err" "A Claude instance that wasn't listed is running: fresh · PID 504. Stopping the quit; nothing more is signalled." &&
    assert_not_contains "$k" $'\t504' &&
    assert_contains "$out" "Stopped the quit: an instance that wasn't listed appeared (named above), and signin closes only what it listed. Listed before the quit: PIDs ${A_PID} ${B_PID}. Closed: ${A_PID} ${B_PID}. Still running: 504. Nothing was signed in." &&
    assert_contains "$(history_text)" "QUIT_ALL" &&
    assert_never_called open &&
    assert_clean
  finish_case "15e. an instance that wasn't listed appears during --quit-others' quit -> named (fresh · PID 504), never signalled, what was closed and what still runs, nothing opened, exit 2" $?
}

# ---- Cases 16-16d: refusals and the exit-code invariant -------------------------

case_16_refusals() {
  scenario
  local bad="" spec a1 a2 a3 rest
  for spec in "signin" "signin|Bad_Tag" "signin|alpha;x" "signin|alpha|--bogus" \
              "signin|alpha|--timeout|5" "signin|alpha|--timeout|99999" "signin|alpha|--timeout|abc" \
              "signin|alpha|--timeout" "signin|alpha|--settle|121" "signin|alpha|--settle|-1" \
              "signin|alpha|--yes|--yes" "signin|gamma" "signin|alpha|extra" "login|Bad_Tag" \
              'signin|alpha|$(true)' "signin|-alpha"; do
    IFS='|' read -r a1 a2 a3 rest <<< "$spec"
    run_si /dev/null "$a1" "$a2" "$a3" "${rest:-}"
    if [[ "$rc" != "2" ]]; then bad="${bad} [${spec}]=exit${rc}"; fi
  done
  run_switcher signin alpha --yes --new --quit-others --timeout 30 --settle 0 extra one
  keep_run
  if [[ "$rc" != "2" ]]; then bad="${bad} [ten-args]=exit${rc}"; fi
  /bin/rm -f "${AS_STORE}/config.toml"
  run_si /dev/null signin alpha --new
  if [[ "$rc" != "2" ]]; then bad="${bad} [no-config.toml]=exit${rc}"; fi
  assert_eq "${bad# }" "" "arguments that did not exit 2" &&
    assert_no_open_or_quit &&
    assert_contains "$err" "No config.toml at" &&
    assert_clean
  finish_case "16. bad tag, metacharacters, unknown or repeated flag, --timeout 5/99999/abc/none, --settle 121/-1, unconfigured tag, extra or too many arguments, no config.toml -> exit 2 each, nothing opened" $?
}

# fail_fake <name>: replaces that passthrough fake with one that records
# the call and exits 1.
fail_fake() {
  printf '#!/bin/bash\n# as-fake: passthrough\nprintf '"'"'%s\\tFAILS\\n'"'"' >> "${AS_TEST_ROOT}/calls.log"\nexit 1\n' "$1" > "${AS_FAKES_DIR}/$1"
  /bin/chmod 755 "${AS_FAKES_DIR}/$1" || harness_error "cannot chmod the $1 fake"
}

case_16b_failure_before_open() {
  scenario
  fail_fake od
  run_si /dev/null signin alpha
  local salt_rc="$rc" salt_err="$err" i=1
  # An unguarded failure: the history log is due for rotation and tail fails.
  scenario
  while [[ $i -le 1200 ]]; do printf 'old row %s\n' "$i"; i=$((i + 1)); done > "${AS_STORE}/swap-history.log"
  fail_fake tail
  run_si /dev/null signin alpha
  assert_eq "$salt_rc" "2" "exit when the salt can't be made" &&
    assert_contains "$salt_err" "Could not set up the identity snapshot (no random salt); nothing was opened." &&
    assert_rc 2 &&
    assert_contains "$err" "signin stopped before anything was opened or quit (status 1)." &&
    assert_no_open_or_quit &&
    assert_no_secrets
  finish_case "16b. a failure before anything is opened -> exit 2, never 1: the salt's od failing (refused), and an unguarded failure (the log rotation's tail) caught by the entry trap" $?
}

case_16c_failure_after_open() {
  scenario
  /bin/cat > "${AS_FAKES_DIR}/sleep" <<'FAKE'
#!/bin/bash
# as-fake: recording
line="sleep"
for arg; do line="${line}"$'\t'"${arg}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
t=0
[[ -f "${AS_TEST_ROOT}/fake/tick" ]] && IFS= read -r t < "${AS_TEST_ROOT}/fake/tick"
if [[ "${1:-}" == "2" && $t -ge 2 ]]; then exit 1; fi
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/sleep" || harness_error "cannot chmod the sleep fake"
  run_si /dev/null signin alpha --settle 0
  assert_rc 3 &&
    assert_contains "$err" "signin stopped unexpectedly (status 1); checking every profile before it reports." &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=aborted recorded_as=none others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_contains "$(history_text)" "SIGNIN tag=alpha mode=others-open result=unknown detail=aborted" &&
    assert_clean
  finish_case "16c. a command that fails after the target was opened (the poll's sleep exits 1) -> the final check runs, detail=aborted, exit 3, never 1" $?
}

case_16d_interrupt_before_open() {
  scenario
  corrupt beta
  /bin/cat > "${AS_FAKES_DIR}/sleep" <<'FAKE'
#!/bin/bash
# as-fake: recording
line="sleep"
for arg; do line="${line}"$'\t'"${arg}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
if [[ "${1:-}" == "1" ]]; then kill -INT "$PPID"; fi
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/sleep" || harness_error "cannot chmod the sleep fake"
  run_si /dev/null signin alpha --yes
  assert_rc 2 &&
    assert_contains "$out" "Stopped (interrupted) before anything was opened or quit." &&
    assert_no_open_or_quit &&
    assert_clean
  finish_case "16d. Ctrl-C during the snapshot, before anything is opened -> exit 2, nothing opened" $?
}

# ---- Case 17: the trace ----------------------------------------------------------

# run_trace: case 1 under /bin/bash -x, each trace line prefixed with the
# function it ran in. The trace goes to T7_TRACE (exempt from the id and hex
# scans: xtrace shows digests and the target's own id through #6's read, by
# design); stdout goes to the transcript as usual.
run_trace() {
  local o="${AS_TEST_ROOT}/.run-out"
  T7_TRACE="${AS_TEST_ROOT}/trace.txt"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    # shellcheck disable=SC2016
    PS4='+${FUNCNAME[0]:-main}: '
    export PS4
    exec /bin/bash -x "$SWITCHER" signin alpha --settle 0
  ) > "$o" 2> "$T7_TRACE" < /dev/null
  rc=$?
  out="$(< "$o")"
  err=""
  printf '%s\n' "$out" >> "${AS_TEST_ROOT}/transcript.txt"
}

case_17_trace() {
  scenario
  step 2 'set_key alpha 2'
  run_trace
  local l body n=0 jq_lines=0 bad="" trace
  trace="$(< "$T7_TRACE")"
  while IFS= read -r l || [[ -n "$l" ]]; do
    body="${l#"${l%%[!+]*}"}"
    [[ "$body" == "snapshot_read: "* ]] || continue
    n=$((n + 1))
    [[ "$body" == *"input | if type"* ]] && jq_lines=$((jq_lines + 1))
    if [[ "$body" =~ $UUID_ERE || "$body" == *"$TOKEN_MARK"* ]]; then bad="${bad}"$'\n'"      ${body:0:80}"; fi
  done < "$T7_TRACE"
  assert_rc 0 &&
    { [[ $n -gt 0 && $jq_lines -gt 0 ]] || { printf '    no traced line inside snapshot_read (%s, jq %s)\n' "$n" "$jq_lines"; false; }; } &&
    assert_eq "${bad}" "" "snapshot_read trace lines holding an id or a placeholder" &&
    { [[ "$trace" == *"$ID_A"* ]] || { printf "    control: the target's own id (read by #6) is not in the trace, so the scan proves nothing\n"; false; }; } &&
    assert_not_contains "$trace" "$TOKEN_MARK" &&
    assert_clean
  finish_case "17. case 1 under bash -x: no traced line inside snapshot_read holds any profile's id or a placeholder (control: the target's id, read by #6, is in the trace)" $?
}

# ---- Case 18: interrupt -------------------------------------------------------------

case_18_interrupt_after_landing() {
  scenario
  step 3 'set_key beta 7; send_int'
  run_si /dev/null signin alpha --settle 0
  assert_rc 4 &&
    assert_contains "$out" "Stopping (interrupted); checking every profile before reporting." &&
    assert_contains "$err" "profile 'beta' changed during this sign-in" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=aborted recorded_as=none others_checked=3 others_changed=1 others_unverified=0 exit=4" &&
    assert_contains "$(history_text)" "SIGNIN tag=alpha mode=others-open result=unknown detail=aborted" &&
    assert_contains "$(history_text)" "SIGNIN_OTHER tag=beta change=changed during=alpha" &&
    assert_clean
  finish_case "18. Ctrl-C at poll 3 just after beta changed -> the final check still runs: result=unknown detail=aborted, MISMATCH for beta, rows written, exit 4" $?
}

case_18b_interrupt_quiet() {
  scenario
  step 2 'send_int'
  run_si /dev/null signin alpha --settle 0
  assert_rc 3 &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=aborted recorded_as=none others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "18b. Ctrl-C with nothing changed -> detail=aborted, exit 3" $?
}

case_18c_interrupt_in_settle() {
  scenario
  record alpha 9
  step 2 'set_key alpha 2'
  step 4 'send_int'
  run_si /dev/null signin alpha --settle 10
  assert_rc 3 &&
    assert_not_contains "$out" "(match)" &&
    assert_summary "signin tag=alpha mode=others-open result=unknown detail=aborted recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=3" &&
    assert_clean
  finish_case "18c. Ctrl-C during the settle window after the target read match -> never match: detail=aborted, exit 3" $?
}

# ---- Case 19: history rows across every case --------------------------------------

case_19_rows() {
  local ctl=0
  row_ok "[2026-10-31T00:00:00Z] SIGNIN tag=alpha mode=others-open result=match detail=changed others_changed=0 others_unverified=0" || ctl=1
  row_ok "[2026-10-31T00:00:00Z] SIGNIN tag=alpha label=${LABEL_MARK}" && ctl=2
  row_ok "[2026-10-31T00:00:00Z] SIGNIN tag=alpha to=alpha.${MAIL_MARK}" && ctl=3
  row_ok "[2026-10-31T00:00:00Z] IDENTITY tag=alpha id=${ID_A}" && ctl=4
  row_ok "[2026-10-31T00:00:00Z] SIGNIN tag=alpha d=$(printf '%064d' 0)" && ctl=5
  row_ok "[2026-10-31T00:00:00Z] ADD_ACCOUNT tag=alpha" && ctl=6
  assert_eq "$ctl" "0" "row-rule control (a clean row passes; label, email, id, 64-hex and other row kinds fail)" &&
    { [[ $ROWS_SEEN -gt 0 ]] || { printf '    no history row was checked\n'; false; }; } &&
    assert_eq "$ROWS_BAD" "0" "cases with a bad history row"
  result "19. every history row written in every case (${ROWS_SEEN} rows) is SIGNIN, SIGNIN_OTHER, IDENTITY, IDENTITY_PIN, LAUNCH or QUIT_ALL, with no label, email, id or 64-hex run (control: each kind of bad row fails)" $?
}

# ---- Cases 20-22: lookalike processes, unknown instances, the settle window -------

case_20_lookalikes() {
  scenario
  ps_table "${P_PID}:primary" "${B_PID}:beta" "777:pager:alpha" "778:grep"
  step 2 'ps_add 779:grep'
  step 3 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_eq "$(count_lines "$(calls_of open)")" "1" "open calls" &&
    assert_contains "$out" "Opened 'alpha' (PID ${NEW_PID})." &&
    assert_not_contains "$out" "Using the running instance" &&
    assert_contains "$out" "Open Claude instances, left running: primary · PID ${P_PID}, beta · PID ${B_PID}"$'\n' &&
    assert_not_contains "$err" "primary instance started" &&
    assert_not_contains "$err" "PID 779" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "20. a pager carrying the binary path and alpha's flag, and grep lines carrying the path, are not instances: open still runs, neither is the target, no primary warning" $?
}

case_21_unknown_instance_refused() {
  scenario
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta" "504:custom"
  run_si /dev/null signin alpha
  assert_rc 2 &&
    assert_contains "$out" "unknown · PID 504" &&
    assert_contains "$err" "PID 504 runs on a profile signin can't determine, so signin can't protect it." &&
    assert_no_open_or_quit &&
    assert_clean
  finish_case "21. the target runs and another instance's profile can't be determined, no terminal, no --yes -> refused, exit 2" $?
}

case_21b_unknown_instance_yes() {
  scenario
  ps_table "${P_PID}:primary" "${A_PID}:alpha" "${B_PID}:beta" "504:custom"
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha --yes --settle 0
  assert_rc 4 &&
    assert_contains "$err" "an instance (PID 504) runs on a profile signin can't check" &&
    assert_contains "$(history_text)" "SIGNIN_OTHER tag=unknown change=unverified during=alpha" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=1 exit=4" &&
    assert_clean
  finish_case "21b. the same with --yes -> it goes on; UNVERIFIED naming PID 504, exit 4 even with the target at match" $?
}

case_21c_unknown_target_not_running() {
  scenario
  ps_table "${P_PID}:primary" "${B_PID}:beta" "504:custom"
  run_si /dev/null signin alpha --yes
  assert_rc 2 &&
    assert_contains "$err" "Can't tell whether PID 504 is 'alpha'; run account-switcher list, or use --quit-others." &&
    assert_no_open_or_quit &&
    assert_clean
  finish_case "21c. the target is not found but an instance's profile is unknown (it could be the target) -> refused even with --yes, exit 2" $?
}

case_21d_unknown_appears() {
  scenario
  step 2 'ps_add 505:custom'
  step 3 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 4 &&
    assert_contains "$err" "an instance started during sign-in (PID 505) whose profile signin can't determine" &&
    assert_contains "$err" "an instance (PID 505) runs on a profile signin can't check" &&
    assert_clean
  finish_case "21d. an instance whose profile can't be determined appears mid-wait -> UNVERIFIED naming its PID, exit 4" $?
}

case_22_settle_catches() {
  scenario
  step 2 'set_key alpha 2'
  step 5 'set_key beta 7'
  run_si /dev/null signin alpha
  assert_rc 4 &&
    assert_contains "$out" "Watching the other instances for 20 s" &&
    assert_contains "$out" "Stopping: profile 'beta' changed (see below)." &&
    assert_eq "$(ticks)" "5" "polls (the settle window stopped at the change)" &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=1 others_unverified=0 exit=4" &&
    assert_clean
  finish_case "22. a repeat callback landing in beta during the 20 s settle window after a match -> caught, exit 4" $?
}

case_22b_settle_zero() {
  scenario
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_not_contains "$out" "Watching the other instances" &&
    assert_eq "$(count_calls "sleep"$'\t'"2")" "1" "2 s sleeps" &&
    assert_clean
  finish_case "22b. --settle 0 -> no settle window, exit 0" $?
}

# ---- Case 23: snapshot_read on its own --------------------------------------------

# The script without its last line (the call to main), for a driver that
# sources it and calls its functions directly. Prints the copy's path.
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
  keep_run
}

case_23_snapshot_read() {
  scenario
  local drv="${AS_TEST_ROOT}/driver.sh" want
  /bin/cat > "$drv" <<'DRV'
. "$1"
_snap_init
R="${AS_PROFILE_ROOT}"
mk() { /bin/mkdir -p "${R}/u-$1"; printf '%s' "$2" > "${R}/u-$1/config.json"; }
mk null 'null'
mk empty ''
mk torn '{"lastKnownAccountUuid": "abc'
mk array '[1, 2]'
mk obj '{}'
mk keynull '{"lastKnownAccountUuid": null}'
mk num '{"lastKnownAccountUuid": 1}'
mk str '{"lastKnownAccountUuid": "1"}'
mk up '{"lastKnownAccountUuid": "ABC"}'
mk low '{"lastKnownAccountUuid": "abc"}'
/bin/mkdir -p "${R}/u-nofile"
for n in null empty torn array obj keynull num str up low nofile nofolder; do
  snapshot_read "${R}/u-${n}" st dg
  printf '%s=%s ' "$n" "$st"
done
printf '\n'
snapshot_read "${R}/u-num" s1 d1
snapshot_read "${R}/u-str" s2 d2
if [[ "$d1" == "$d2" ]]; then printf 'num-vs-str=equal '; else printf 'num-vs-str=different '; fi
snapshot_read "${R}/u-up" s1 d1
snapshot_read "${R}/u-low" s2 d2
if [[ "$d1" == "$d2" ]]; then printf 'case=equal '; else printf 'case=different '; fi
if snapshot_read "${R}/u-str" _sr_d x 2> /dev/null; then printf 'sr-name=accepted '; else printf 'sr-name=refused-%s ' "$?"; fi
if snapshot_read "${R}/u-str" 'arr[1]' x 2> /dev/null; then printf 'array-name=accepted '; else printf 'array-name=refused-%s ' "$?"; fi
d="stale"
f="stale"
snapshot_read "${R}/u-str" f d
if [[ "$f" == "present" && "$d" != "stale" && -n "$d" ]]; then printf 'caller-d-f=written\n'; else printf 'caller-d-f=stale\n'; fi
DRV
  run_driver "$drv"
  want="null=unreadable empty=unreadable torn=unreadable array=unreadable obj=absent keynull=absent num=present str=present up=present low=present nofile=nofile nofolder=nofolder "$'\n'
  want="${want}num-vs-str=different case=equal sr-name=refused-2 array-name=refused-2 caller-d-f=written"
  assert_rc 0 &&
    assert_eq "$out" "$want" "snapshot_read results" &&
    assert_clean
  finish_case "23. snapshot_read: top-level null, empty, torn and array read unreadable; {} and null absent; 1 and \"1\" differ; scalar out-names only (_sr_ and array names refused); a caller's d and f are written" $?
}

# ---- Cases 24-26: the seam, help, the no-account warning --------------------------

case_24_seam() {
  scenario
  local l prod_unset="" bins="" hook_dir
  while IFS= read -r l || [[ -n "$l" ]]; do
    case "$l" in
      "  unset _n AS_TEST_ROOT AS_FAKES_DIR AS_KEYCHAIN_SVC "*) prod_unset="$l" ;;
      AS_SEAM_BINS=*) bins="$l" ;;
    esac
  done < "$SWITCHER"
  new_sibling_dir
  hook_dir="$SIBLING_DIR"
  printf '#!/bin/bash\nexit 0\n' > "${hook_dir}/hook.sh"
  /bin/chmod 755 "${hook_dir}/hook.sh"
  AS_TEST_POLL_HOOK="${hook_dir}/hook.sh"
  export AS_TEST_POLL_HOOK
  : > "${AS_TEST_ROOT}/calls.log"
  run_si /dev/null signin alpha
  assert_rc 78 &&
    assert_contains "$err" "AS_TEST_POLL_HOOK is not under AS_TEST_ROOT" &&
    assert_eq "$(< "${AS_TEST_ROOT}/calls.log")" "" "commands run before the refusal" &&
    assert_contains "$prod_unset" " AS_TEST_STDIN_IS_TTY " &&
    assert_contains "${prod_unset} " " AS_TEST_POLL_HOOK " &&
    assert_contains "$bins" " OD " &&
    assert_contains "$bins" " SHASUM " &&
    assert_called_never_default &&
    assert_clean
  finish_case "24. seam: a poll hook outside the scratch root is refused by the interlock (78, nothing run); production unsets both test-only names; OD and SHASUM are seam commands" $?
}

# The defaults of the two new seam commands are their system paths.
assert_called_never_default() {
  local d
  d="$(seam_defaults)"
  assert_contains "$d" "OD /usr/bin/od" && assert_contains "$d" "SHASUM /usr/bin/shasum"
}

case_25_help_and_login() {
  scenario
  run_switcher help
  keep_run
  local help_out="$out"
  step 2 'set_key alpha 2'
  run_si /dev/null login alpha --settle 0
  assert_contains "$help_out" "signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]" &&
    assert_contains "$help_out" "detected after the fact, not prevented" &&
    assert_rc 0 &&
    assert_summary "signin tag=alpha mode=others-open result=match detail=changed recorded_as=alpha others_checked=3 others_changed=0 others_unverified=0 exit=0" &&
    assert_clean
  finish_case "25. help describes signin and its summary line; login is the same command" $?
}

case_26_no_account_warning() {
  scenario
  ps_table "${P_PID}:primary" "506:fresh"
  step 2 'set_key alpha 2'
  run_si /dev/null signin alpha --settle 0
  assert_rc 0 &&
    assert_contains "$err" "'fresh' (PID 506) has no recorded account and may be showing a sign-in screen." &&
    assert_contains "$out" "If any other Claude window shows a sign-in screen, close it before you start." &&
    assert_clean
  finish_case "26. an open instance with no recorded account is named before the sign-in (the likeliest place for a stray login)" $?
}

# ---- Control: the secret scans can fail --------------------------------------------

case_0_scan_control() {
  scenario
  local fx copy="${HOME}/copy-of-config.json" hexf="${HOME}/planted.txt" t_hit i_hit h_hit leak_rc=0 t_none i_none h_none
  fx="$(pdir beta)/config.json"
  /bin/cp "$fx" "$copy" || harness_error "cannot copy the fixture"
  printf 'd=%064d\n' 0 > "$hexf"
  t_hit="$(secret_hits token)"
  i_hit="$(secret_hits ids)"
  h_hit="$(secret_hits hex)"
  assert_no_secrets > /dev/null || leak_rc=1
  /bin/rm -f "$copy" "$hexf"
  t_none="$(secret_hits token)"
  i_none="$(secret_hits ids)"
  h_none="$(secret_hits hex)"
  assert_eq "$(raw_hits token "$fx")" "$fx" "token scan over a fixture config.json" &&
    assert_eq "$(raw_hits ids "$fx")" "$fx" "id scan over a fixture config.json" &&
    assert_eq "$t_hit" "$copy" "token scan with a copy outside the exempt list" &&
    assert_eq "$i_hit" "$copy" "id scan with a copy outside the exempt list" &&
    assert_eq "$h_hit" "$hexf" "hex scan with a planted 64-hex line" &&
    assert_eq "$leak_rc" "1" "assert_no_secrets with the planted files present" &&
    assert_eq "${t_none}${i_none}${h_none}" "" "scans with the planted files gone" &&
    assert_clean
  finish_case "0. control: the token, id and 64-hex scans each fail on a planted file outside the exempt list, and pass once it is gone" $?
}

case_0_scan_control
case_1_match
case_2_other_changes
case_2c_control
case_3_same_tick
case_4_churn
case_5_running_target
case_6_primary_nothing_running
case_6b_primary_running
case_7_flagless_appears
case_7b_flagless_lands
case_8_typed_y
case_8b_quiet_then_y
case_8c_buffered_input
case_8d_bare_enter
case_9_timeout
case_9b_timeout_mismatch
case_10_target_exited
case_10b_restarted
case_11_mismatch
case_12_new_tag
case_12b_pin_offer
case_12c_no_offer_pinned_elsewhere
case_13_unreadable_left
case_13b_unreadable_restored
case_14_unreadable_before_refused
case_14b_unreadable_before_yes
case_15_quit_no_terminal
case_15b_quit_yes
case_15c_quit_set_differs
case_15d_quit_interrupted
case_15e_quit_unlisted_appears
case_16_refusals
case_16b_failure_before_open
case_16c_failure_after_open
case_16d_interrupt_before_open
case_17_trace
case_18_interrupt_after_landing
case_18b_interrupt_quiet
case_18c_interrupt_in_settle
case_20_lookalikes
case_21_unknown_instance_refused
case_21b_unknown_instance_yes
case_21c_unknown_target_not_running
case_21d_unknown_appears
case_22_settle_catches
case_22b_settle_zero
case_23_snapshot_read
case_24_seam
case_25_help_and_login
case_26_no_account_warning
case_19_rows
finish
