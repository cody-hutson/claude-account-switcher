#!/usr/bin/env bash
# tests/t-24-closed-tags.sh - #24: the tags Claude closed on its own.
#
# The switcher keeps a record, open-tags.json, of the tags it opened (or
# adopted) and the ones it later found gone without closing them itself.
# Each case seeds that record, a process table and the app's own log, then
# runs the commands that observe it. The app's log is rendered from
# tests/fixtures/applog/*.txt: each template holds the update close under
# test plus noise a correct reader skips (a line an hour before the span,
# an unstamped continuation line that names an update close, and a
# millisecond-stamped line inside the span that does too). The cases run in
# a zone 5 hours west of UTC (TZ=XST5): the record is in UTC, the app's log
# in local time, so a reader that mixed them would read the wrong span.
#
# Stamps are taken from the case's own clock: a tag "seen 10 minutes ago"
# is the current time less 600 s, and an update close "5 minutes ago" is
# stamped at the current time less 300 s, so every span holds what the case
# means it to.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

TZ="XST5"
export TZ

NOW_EP=0
SEEN_EP=0
S_UTC=""
EVENT_EP=0
IDLE_TEXT="[stealth-update] Triggering stealth update after idle timeout"

utc_of() { /bin/date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
local_of() { /bin/date -r "$1" '+%Y-%m-%d %H:%M:%S'; }
rand_hex() { /usr/bin/od -An -N"$1" -tx1 /dev/urandom | /usr/bin/tr -d ' \n'; }

pdir() {
  if [[ "$1" == "primary" ]]; then
    printf '%s' "${AS_PROFILE_ROOT}/Claude"
  else
    printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"
  fi
}
rec() { printf '%s' "${AS_STORE}/open-tags.json"; }
history_text() {
  if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi
}
# rec_q <jq filter>: one value from the record, through the real jq.
rec_q() { /usr/bin/jq -r "$1" "$(rec)" 2> /dev/null; }
file_mode() { /usr/bin/stat -f '%Lp' "$1" 2> /dev/null; }

# Lines of $1 that contain $2.
count_matching() {
  local l n=0
  while IFS= read -r l; do [[ "$l" == *"$2"* ]] && n=$((n + 1)); done <<< "$1"
  printf '%d' "$n"
}

# ps_rows <pid>:<tag> ...: the process table (primary without a flag, any
# other tag with its --user-data-dir), every PID alive. A graceful quit
# leaves none.
ps_rows() {
  local spec
  {
    printf '  PID ARGS\n'
    for spec; do
      if [[ "${spec#*:}" == "primary" ]]; then
        printf '%5s %s\n' "${spec%%:*}" "${AS_APP_BUNDLE}/Contents/MacOS/Claude"
      else
        printf '%5s %s --user-data-dir=%s\n' "${spec%%:*}" "${AS_APP_BUNDLE}/Contents/MacOS/Claude" "$(pdir "${spec#*:}")"
      fi
    done
  } > "$AS_FIXTURE_PS"
  {
    for spec; do printf '%s\n' "${spec%%:*}"; done
  } > "${AS_TEST_ROOT}/alive.txt"
  printf '  PID ARGS\n' > "$AS_FIXTURE_PS_AFTER_QUIT"
}

# scenario [<ps fixture> [<after-quit fixture>]]: a case with primary, tag-a
# and tag-b configured and on disk, the store, and the clock read: a tag is
# "seen" 10 minutes ago and an update close is stamped 5 minutes ago.
scenario() {
  new_case
  unset AS_FAKE_OPEN_SPAWNS_PID AS_FAKE_QUIT AS_TEST_POLL_HOOK
  /bin/mkdir -p "$AS_STORE" "$(pdir primary)" "$(pdir tag-a)" "$(pdir tag-b)" \
    || harness_error "cannot create the scenario folders"
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'primary = { label = "Primary" }\n'
    printf 'tag-a = { label = "Alpha" }\n'
    printf 'tag-b = { label = "Beta" }\n'
  } > "${AS_STORE}/config.toml"
  if [[ -n "${1:-}" ]]; then set_ps_fixture "$1" "${2:-}"; fi
  NOW_EP="$(/bin/date +%s)"
  SEEN_EP=$((NOW_EP - 600))
  S_UTC="$(utc_of "$SEEN_EP")"
  EVENT_EP=$((NOW_EP - 300))
}

# seed <primary_seen epoch|-> <mark epoch|-> [<tag>:<seen epoch> ...]: the
# record with those open entries and no closed one.
seed() {
  local p="null" m="null" spec o=""
  if [[ "$1" != "-" ]]; then p="\"$(utc_of "$1")\""; fi
  if [[ "$2" != "-" ]]; then m="\"$(utc_of "$2")\""; fi
  shift 2
  for spec; do o="${o}{\"tag\":\"${spec%%:*}\",\"seen_utc\":\"$(utc_of "${spec#*:}")\"},"; done
  printf '{"schema":1,"open":[%s],"closed":[],"primary_seen_utc":%s,"event_mark_utc":%s}\n' \
    "${o%,}" "$p" "$m" > "$(rec)"
  /bin/chmod 600 "$(rec)"
}

# seed_closed <tag> <seen epoch> <cause> <event>: adds a closed entry.
seed_closed() {
  local tmp="${AS_TEST_ROOT}/rec.tmp"
  if ! /usr/bin/jq --arg t "$1" --arg s "$(utc_of "$2")" --arg f "$(utc_of "$NOW_EP")" --arg c "$3" --arg e "$4" \
      '.closed += [{tag: $t, seen_utc: $s, found_utc: $f, cause: $c, event: $e}]' "$(rec)" > "$tmp"; then
    harness_error "cannot seed a closed entry"
  fi
  /bin/mv "$tmp" "$(rec)" || harness_error "cannot seed a closed entry"
}

PLANT_UUID=""
PLANT_EMAIL=""
PLANT_PATH=""

# applog <template> <event epoch> [<file>]: renders the template as the
# app's log <file> (default main.log): __T_EVENT__ at the event, __T_NOISE__
# one second before it (inside the span), __T_BEFORE__ an hour before the
# seen time (outside it), and the planted values.
applog() {
  local l ev noise before f="${3:-main.log}"
  ev="$(local_of "$2")"
  noise="$(local_of "$(($2 - 1))")"
  before="$(local_of "$((SEEN_EP - 3600))")"
  /bin/mkdir -p "$AS_APP_LOG_DIR" || harness_error "cannot create the app log folder"
  : > "${AS_APP_LOG_DIR}/${f}"
  while IFS= read -r l || [[ -n "$l" ]]; do
    l="${l//__T_EVENT__/$ev}"
    l="${l//__T_NOISE__/$noise}"
    l="${l//__T_BEFORE__/$before}"
    l="${l//__PLANT_UUID__/$PLANT_UUID}"
    l="${l//__PLANT_EMAIL__/$PLANT_EMAIL}"
    l="${l//__PLANT_PATH__/$PLANT_PATH}"
    printf '%s\n' "$l" >> "${AS_APP_LOG_DIR}/${f}"
  done < "${FIXTURES}/applog/$1"
}

# idle_line <epoch> [<file>]: appends one idle-timeout update close.
idle_line() {
  /bin/mkdir -p "$AS_APP_LOG_DIR" || harness_error "cannot create the app log folder"
  printf '%s [info] %s\n' "$(local_of "$1")" "$IDLE_TEXT" >> "${AS_APP_LOG_DIR}/${2:-main.log}"
}

# helper_install <epoch>: the updater's helper log with a completed install
# stamped then (local time with milliseconds, as the helper stamps it).
helper_install() {
  /bin/mkdir -p "$AS_UPDATER_CACHE" || harness_error "cannot create the updater cache"
  printf '%s.500 ShipIt[1:2] Beginning installation\n%s.900 ShipIt[1:2] Installation completed successfully\n' \
    "$(local_of "$1")" "$(local_of "$1")" >> "${AS_UPDATER_CACHE}/ShipIt_stderr.log"
}

# row_for <tag> <cause>: the list section's row for a recorded closure seen
# at S_UTC.
row_for() {
  local text="closed, cause unknown"
  if [[ "$2" == "updater" ]]; then text="closed by the app's updater"; fi
  printf '  %-12s %-30slast seen %s' "$1" "$text" "$S_UTC"
}

# ---- The cause ------------------------------------------------------------------

case_cause_idle() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  applog idle-close.txt "$EVENT_EP"
  printf '{"schema": 1, "staged_version": "none"}\n' > "${AS_STORE}/update-state.json"
  local us_before
  us_before="$(/usr/bin/shasum < "${AS_STORE}/update-state.json")"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "Tags Claude closed without the switcher (since it last saw them running):" &&
    assert_contains "$out" "$(row_for tag-a updater)" &&
    assert_contains "$out" "  Reopen the ones the app's updater closed: account-switcher reopen" &&
    assert_not_contains "$out" "Reopen one closed for an unknown reason" &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=updater event=idle-update" &&
    assert_eq "$(rec_q '.closed[0].cause + "/" + .closed[0].event')" "updater/idle-update" "the recorded cause" &&
    assert_eq "$(rec_q '.open | length')" "0" "open entries left" &&
    assert_eq "$(file_mode "$(rec)")" "600" "the record's mode" &&
    assert_unchanged "${AS_STORE}/update-state.json" "$us_before"
  result "cause: an idle-timeout update close in the span -> 'closed by the app's updater', one CLOSED row, the record mode 600, update-state.json untouched (INT-3)" $?
}

case_cause_forced() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  applog forced-restart.txt "$EVENT_EP"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "$(row_for tag-a updater)" &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=updater event=pending-restart"
  result "cause: a forced restart after a long-pending update -> cause=updater event=pending-restart" $?
}

case_cause_no_event() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  applog no-event.txt "$EVENT_EP"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "$(row_for tag-a unknown)" &&
    assert_contains "$out" "  Reopen one closed for an unknown reason: account-switcher launch <tag>" &&
    assert_not_contains "$out" "Reopen the ones the app's updater closed" &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=unknown event=none"
  result "cause: no update close in the span (one an hour before it) -> 'closed, cause unknown', event=none" $?
}

case_cause_one_event_two_tags() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}" "tag-b:${SEEN_EP}"
  applog idle-close.txt "$EVENT_EP"
  run_switcher list
  local h
  h="$(history_text)"
  assert_rc 0 &&
    assert_contains "$out" "$(row_for tag-a unknown)" &&
    assert_contains "$out" "$(row_for tag-b unknown)" &&
    assert_contains "$h" "CLOSED tag=tag-a seen=${S_UTC} cause=unknown event=idle-update" &&
    assert_contains "$h" "CLOSED tag=tag-b seen=${S_UTC} cause=unknown event=idle-update"
  result "cause: one update close and two tags gone -> both unknown (the millisecond, unstamped and before-the-span lines are not counted)" $?
}

case_cause_no_log() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "$(row_for tag-a unknown)" &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=unknown event=none"
  result "cause: the app's log folder is missing -> unknown" $?
}

case_cause_log_files() {
  local first_ok=1 second_ok=1
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP" main3.log
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=${S_UTC} cause=updater event=idle-update"* ]]; then first_ok=0; fi
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP" main-window.log
  idle_line "$EVENT_EP" main12.log.1
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=${S_UTC} cause=unknown event=none"* ]]; then second_ok=0; fi
  assert_eq "$first_ok" "0" "an update close in main3.log counts" &&
    assert_eq "$second_ok" "0" "main-window.log and other names do not"
  result "the reader: a numbered copy (main3.log) is read; main-window.log and other names are not" $?
}

# ---- When nothing is recorded ---------------------------------------------------------

case_undetermined() {
  scenario ps-unresolved.txt
  seed - - "tag-a:${SEEN_EP}"
  applog idle-close.txt "$EVENT_EP"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$out" "tag=unknown" &&
    assert_not_contains "$(history_text)" "CLOSED" &&
    assert_eq "$(rec_q '.open[0].tag + " " + .open[0].seen_utc')" "tag-a ${S_UTC}" "tag-a's open entry" &&
    assert_eq "$(rec_q '.closed | length')" "0" "closed entries" &&
    assert_not_contains "$out" "Tags Claude closed without the switcher"
  result "an instance whose tag is unknown: no closure is recorded, tag-a's entry and seen time stay, no row (INT-6)" $?
}

case_binary_missing() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  applog idle-close.txt "$EVENT_EP"
  /bin/rm -f "$APP_MAIN_BIN"
  local before
  before="$(/usr/bin/shasum < "$(rec)")"
  run_switcher list
  assert_rc 0 &&
    assert_unchanged "$(rec)" "$before" &&
    assert_not_contains "$(history_text)" "CLOSED"
  result "the app binary is missing: list warns as before and records nothing" $?
}

# ---- The record and its rows ------------------------------------------------------------

case_list_twice() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  applog idle-close.txt "$EVENT_EP"
  run_switcher list
  run_switcher list
  assert_rc 0 &&
    assert_eq "$(count_matching "$(history_text)" "] CLOSED ")" "1" "CLOSED rows" &&
    assert_contains "$out" "$(row_for tag-a updater)"
  result "list run twice writes one CLOSED row; the second list still shows the closure" $?
}

case_quit_then_list() {
  scenario ps-tags-only.txt ps-no-claude.txt
  export AS_FAKE_QUIT=graceful
  run_switcher list
  local adopted
  adopted="$(rec_q '[.open[].tag] | join(",")')"
  run_switcher quit
  local quit_rc="$rc" open_after
  open_after="$(rec_q '.open | length')"
  run_switcher list
  assert_eq "$adopted" "tag-a,tag-b" "adopted at the first list" &&
    assert_eq "$quit_rc" "0" "quit" &&
    assert_contains "$(history_text)" "] QUIT_ALL tags=tag-a,tag-b by=quit" &&
    assert_eq "$open_after" "0" "open entries after quit" &&
    assert_not_contains "$(history_text)" "CLOSED" &&
    assert_not_contains "$out" "Tags Claude closed without the switcher"
  result "quit, then list: the switcher's own quit is no closure; the QUIT_ALL row names the tags and by=quit" $?
}

case_swap_then_list() {
  scenario ps-one-tag.txt ps-no-claude.txt
  export AS_FAKE_QUIT=graceful AS_FAKE_OPEN_SPAWNS_PID=4501
  run_switcher list
  run_switcher swap tag-b --no-mirror --no-handoff
  local swap_rc="$rc"
  run_switcher list
  assert_eq "$swap_rc" "0" "swap" &&
    assert_contains "$(history_text)" "] QUIT_ALL tags=tag-a by=swap" &&
    assert_not_contains "$(history_text)" "CLOSED" &&
    assert_eq "$(rec_q '[.open[].tag] | join(",")')" "tag-b" "open after the swap" &&
    assert_eq "$(rec_q '.closed | length')" "0" "closed entries"
  result "swap tag-b, then list: tag-a (closed by the swap) is not reported, the swap writes QUIT_ALL by=swap, tag-b is tracked" $?
}

case_adopt() {
  scenario ps-three.txt
  run_switcher list
  assert_rc 0 &&
    assert_eq "$(rec_q '[.open[].tag] | sort | join(",")')" "tag-a,tag-b" "adopted" &&
    assert_eq "$(rec_q '.primary_seen_utc | type')" "string" "primary's last-seen time"
  result "adoption: running tags started with --user-data-dir are adopted; the flagless primary is not (its last-seen time is kept)" $?
}

case_planted_ids() {
  scenario ps-no-claude.txt
  local h1 h2 h3
  h1="$(rand_hex 4)"
  h2="$(rand_hex 2)"
  h3="$(rand_hex 6)"
  PLANT_UUID="${h1}-${h2}-4${h2:1}-8${h2:1}-${h3}"
  PLANT_EMAIL="planted.$(rand_hex 3)@example.invalid"
  PLANT_PATH="${HOME}/Library/Application Support/Claude-planted-$(rand_hex 2)"
  seed - - "tag-a:${SEEN_EP}"
  applog planted-ids.txt "$EVENT_EP"
  run_switcher list
  local list_out="$out" list_err="$err"
  seed - - "tag-b:${SEEN_EP}"
  export AS_FAKE_OPEN_SPAWNS_PID=4502
  run_switcher launch tag-a
  local all row_ok=1 l v leaked=""
  all="${list_out}${list_err}${out}${err}$(history_text)$(< "$(rec)")"
  for v in "$PLANT_UUID" "$PLANT_EMAIL" "$PLANT_PATH"; do
    [[ "$all" != *"$v"* ]] || leaked="${leaked} one-planted-value"
  done
  # Control: the same scan finds each planted value in the rendered log.
  local logtext control=""
  logtext="$(< "${AS_APP_LOG_DIR}/main.log")"
  for v in "$PLANT_UUID" "$PLANT_EMAIL" "$PLANT_PATH"; do
    [[ "$logtext" == *"$v"* ]] || control="${control} missing"
  done
  # AC2: every new row is [UTC] KIND key=value, with no udd=, id or path.
  local re='^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] CLOSED tag=[a-z0-9-]+ seen=[0-9TZ:-]+ cause=(updater|unknown) event=(idle-update|pending-restart|none)$'
  while IFS= read -r l; do
    case "$l" in
      *"] CLOSED "*)
        if [[ "$l" =~ $re ]]; then row_ok=0; else row_ok=2; break; fi
        ;;
    esac
  done <<< "$(history_text)"
  out="leaked:${leaked:- none} control:${control:- ok}"
  assert_eq "$leaked" "" "planted values in output, history or the record" &&
    assert_eq "$control" "" "control: each planted value is in the rendered log" &&
    assert_eq "$row_ok" "0" "every CLOSED row's shape" &&
    assert_contains "$list_out" "$(row_for tag-a updater)" &&
    assert_contains "$err" "Since the switcher last saw them running, Claude closed: tag-b ("
  result "AC5/AC2: ids, an email and a path on the update-close lines reach no output, row or record (control: they are in the log); rows are [UTC] KIND key=value; launch prints the notice" $?
}

case_install_check() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  applog idle-close.txt "$EVENT_EP"
  run_switcher list
  /bin/mkdir -p "${HOME}/.claude/commands" || harness_error "cannot create the commands folder"
  /bin/cp "$REPO/account-switcher.sh" "${AS_STORE}/account-switcher.sh"
  /bin/chmod 755 "${AS_STORE}/account-switcher.sh"
  /bin/cp "$REPO/commands/account-switcher.md" "${HOME}/.claude/commands/account-switcher.md"
  local present=1
  [[ -f "$(rec)" ]] && present=0
  run_install --check
  assert_eq "$present" "0" "open-tags.json exists" &&
    assert_rc 0 &&
    assert_not_contains "$out" "leftover" &&
    assert_not_contains "$out" "open-tags.json"
  result "install.sh --check exits 0 with open-tags.json in the store, never naming it (INT-8)" $?
}

# ---- The count, with primary (Stage 5 A-2) ---------------------------------------------
#
# primary's own update close is logged like any other. These five cases are
# the corrected count's check table: primary counts as one more closure when
# it was seen at or after the tag, is not itself newly closed, and is gone
# or running again after a completed install.

case_count_hand_quit() {
  local both_unknown=1 alone_updater=1
  # tag-b quit by hand; tag-a and primary closed by the updater; the
  # install; the helper reopened primary.
  scenario
  ps_rows 4400:primary
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}" "tag-b:${SEEN_EP}"
  idle_line "$((EVENT_EP - 20))"
  idle_line "$((EVENT_EP - 10))" main1.log
  helper_install "$((EVENT_EP - 5))"
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=${S_UTC} cause=unknown"* && \
        "$(history_text)" == *"CLOSED tag=tag-b seen=${S_UTC} cause=unknown"* ]]; then both_unknown=0; fi
  local first="$out"
  # The same, without the hand-closed tag: tag-a reads updater.
  scenario
  ps_rows 4400:primary
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}"
  idle_line "$((EVENT_EP - 20))"
  idle_line "$((EVENT_EP - 10))" main1.log
  helper_install "$((EVENT_EP - 5))"
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=${S_UTC} cause=updater event=idle-update"* ]]; then alone_updater=0; fi
  out="${first}"$'\n'"${out}"
  assert_eq "$both_unknown" "0" "a hand-quit tag in the chain: both tags unknown" &&
    assert_eq "$alone_updater" "0" "without it: tag-a updater"
  result "count: primary's own update close is counted, so a tag quit by hand in the same chain reads unknown, never updater (FM-1); without it the other reads updater" $?
}

case_count_alone() {
  # tag-a alone (primary not running when it was seen); the updater closed
  # it; the install; the helper started primary.
  scenario
  ps_rows 4400:primary
  seed "$((SEEN_EP - 3600))" - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP"
  helper_install "$((EVENT_EP + 2))"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=updater event=idle-update"
  result "count: tag-a alone, primary last seen before it -> updater" $?
}

case_count_primary_tracked() {
  # primary (opened by the switcher, so tracked) and tag-a closed by the
  # updater; tag-b still runs, so nothing installs; primary is not back.
  scenario
  ps_rows 503:tag-b
  seed "$SEEN_EP" - "primary:${SEEN_EP}" "tag-a:${SEEN_EP}" "tag-b:${SEEN_EP}"
  idle_line "$((EVENT_EP - 10))"
  idle_line "$EVENT_EP"
  run_switcher list
  local h
  h="$(history_text)"
  assert_rc 0 &&
    assert_contains "$h" "CLOSED tag=primary seen=${S_UTC} cause=updater" &&
    assert_contains "$h" "CLOSED tag=tag-a seen=${S_UTC} cause=updater"
  result "count: a tracked primary and tag-a both gone, two update closes -> both updater (primary is not counted twice)" $?
}

case_count_primary_untracked() {
  # The same, with a primary the Dock opened (never tracked).
  scenario
  ps_rows 503:tag-b
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}" "tag-b:${SEEN_EP}"
  idle_line "$((EVENT_EP - 10))"
  idle_line "$EVENT_EP"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=updater"
  result "count: an untracked primary gone with tag-a, two update closes -> tag-a updater" $?
}

case_count_cost() {
  # primary quit by hand; tag-a closed by the updater; the install; the
  # helper reopened primary. The stated cost: this reads unknown.
  scenario
  ps_rows 4400:primary
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP"
  helper_install "$((EVENT_EP + 2))"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$(history_text)" "CLOSED tag=tag-a seen=${S_UTC} cause=unknown event=idle-update"
  result "count, the stated cost: primary quit by hand, tag-a closed by the updater, the install -> tag-a unknown (the safe direction)" $?
}

case_count_no_helper_log() {
  local missing_ok=1 control_ok=1
  # primary runs, seen with tag-a; one update close; the updater's own log
  # can't be read, so a close and relaunch of primary in the span can't be
  # ruled out: primary counts, and tag-a reads unknown (Stage 6 D6-7).
  scenario
  ps_rows 501:primary
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP"
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=${S_UTC} cause=unknown event=idle-update"* ]]; then missing_ok=0; fi
  local first="$out"
  # Control: the log is readable and shows no completed install since S:
  # primary was running throughout, so tag-a reads updater.
  scenario
  ps_rows 501:primary
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP"
  /bin/mkdir -p "$AS_UPDATER_CACHE" || harness_error "cannot create the updater cache"
  printf '%s.500 ShipIt[1:2] Detected this as an install request\n' "$(local_of "$EVENT_EP")" > "${AS_UPDATER_CACHE}/ShipIt_stderr.log"
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=${S_UTC} cause=updater event=idle-update"* ]]; then control_ok=0; fi
  out="${first}"$'\n'"${out}"
  assert_eq "$missing_ok" "0" "the updater's log unreadable: tag-a unknown" &&
    assert_eq "$control_ok" "0" "control: readable, no install since S: tag-a updater"
  result "count: primary running and the updater's log unreadable -> primary counts (it may have closed and come back), tag-a unknown; control: the log readable with no install since -> updater" $?
}

# ---- One event, one observation (the mark) ---------------------------------------

case_mark() {
  local marked=1 unmarked=1
  # An earlier observation counted the update close at E and saw tag-a
  # running one second later; tag-a then closed with no event. The 2 s
  # slack reaches back to E, which the mark keeps from being counted again.
  scenario ps-no-claude.txt
  seed - "$EVENT_EP" "tag-a:$((EVENT_EP + 1))"
  idle_line "$EVENT_EP"
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=$(utc_of "$((EVENT_EP + 1))") cause=unknown event=none"* ]]; then marked=0; fi
  # Control: without the mark, the same event counts.
  scenario ps-no-claude.txt
  seed - - "tag-a:$((EVENT_EP + 1))"
  idle_line "$EVENT_EP"
  run_switcher list
  if [[ "$(history_text)" == *"CLOSED tag=tag-a seen=$(utc_of "$((EVENT_EP + 1))") cause=updater"* ]]; then unmarked=0; fi
  assert_eq "$marked" "0" "an event already counted is not counted again" &&
    assert_eq "$unmarked" "0" "control: without the mark it is"
  result "the mark: an update close counted at one observation is never counted at the next (control: without the mark it is)" $?
}

case_mark_moves() {
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}"
  idle_line "$EVENT_EP"
  run_switcher list
  assert_rc 0 &&
    assert_eq "$(rec_q '.event_mark_utc')" "$(utc_of "$EVENT_EP")" "the mark after the observation"
  result "the mark moves to the latest update close an observation counted" $?
}

case_mark_moves_unknown() {
  # One update close and two tags gone: both read unknown, and the close is
  # still marked as counted, so the next observation can't count it again
  # (Stage 6 D6-8: the mark moves whatever cause the observation recorded).
  scenario ps-no-claude.txt
  seed - - "tag-a:${SEEN_EP}" "tag-b:${SEEN_EP}"
  idle_line "$EVENT_EP"
  run_switcher list
  assert_rc 0 &&
    assert_not_contains "$(history_text)" "cause=updater" &&
    assert_eq "$(rec_q '.event_mark_utc')" "$(utc_of "$EVENT_EP")" "the mark after an observation that recorded only unknown"
  result "the mark moves past an update close an observation counted even when every closure it recorded reads unknown" $?
}

# ---- One clock per run ----------------------------------------------------------------

# An open fake that takes a second and a half before it starts the next PID,
# so stamps read after an open would differ from the observation's.
slow_open_fake() {
  printf '%s\n' "$@" > "${AS_TEST_ROOT}/open-pids.txt"
  /bin/cat > "${AS_FAKES_DIR}/open" <<'FAKE'
#!/bin/bash
# as-fake: recording
set -u
[[ -n "${AS_TEST_ROOT:-}" && -f "${AS_TEST_ROOT}/.as-test-root" ]] || exit 98
line="open"
udd=""
for arg; do
  case "$arg" in --user-data-dir=*) udd="$arg" ;; esac
  line="${line}"$'\t'"${arg}"
done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
/bin/sleep 1.5
pids="${AS_TEST_ROOT}/open-pids.txt"
pid=""
rest=""
first=1
while IFS= read -r p || [[ -n "$p" ]]; do
  if [[ $first -eq 1 ]]; then pid="$p"; first=0; else rest="${rest}${p}"$'\n'; fi
done < "$pids"
printf '%s' "$rest" > "$pids"
if [[ -n "$pid" ]]; then
  printf -v row '%5s %s' "$pid" "${AS_APP_BUNDLE}/Contents/MacOS/Claude"
  if [[ -n "$udd" ]]; then row="${row} ${udd}"; fi
  printf '%s\n' "$row" >> "$AS_FIXTURE_PS"
  printf '%s\n' "$pid" >> "${AS_TEST_ROOT}/alive.txt"
fi
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/open" || harness_error "cannot chmod the open fake"
}

case_one_clock() {
  # primary runs (the Dock's); launch tag-a, then launch tag-b. Then tag-b
  # is quit by hand, and the updater closes tag-a and primary; the install;
  # the helper reopens primary. Both tags must read unknown.
  scenario
  ps_rows 501:primary
  slow_open_fake 4501 4502
  run_switcher launch tag-a
  run_switcher launch tag-b
  local stamps
  stamps="$(rec_q '[.open[] | .seen_utc] + [.primary_seen_utc] | unique | length')"
  local t
  t="$(/bin/date +%s)"
  ps_rows 4400:primary
  idle_line "$t"
  idle_line "$t" main1.log
  helper_install "$t"
  run_switcher list
  local h
  h="$(history_text)"
  out="stamps=${stamps}"$'\n'"${out}"
  assert_eq "$stamps" "1" "one stamp for both tags and primary after the second launch" &&
    assert_contains "$h" "CLOSED tag=tag-a" &&
    assert_contains "$h" "CLOSED tag=tag-b" &&
    assert_not_contains "$h" "cause=updater"
  result "one clock per run: after launch tag-a and launch tag-b (each open takes 1.5 s), both tags and primary carry one stamp, so a tag quit by hand in the chain reads unknown" $?
}

# row_shape <row>: returns 0 when a QUIT_ALL, CLOSED or REOPEN row is exactly
# [UTC] KIND key=value with that kind's keys and value shapes, so nothing
# else (no udd=, id or path) can ride on it; 2 for a row of another kind.
row_shape() {
  local u='^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] '
  local tags='(none|[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*)'
  local s='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  local re
  case "$1" in
    *"] QUIT_ALL"*) re="${u}QUIT_ALL tags=${tags} by=(quit|swap|update|signin)$" ;;
    *"] CLOSED "*)  re="${u}CLOSED tag=[a-z0-9][a-z0-9-]* seen=${s} cause=(updater|unknown) event=(idle-update|pending-restart|none)$" ;;
    *"] REOPEN "*)  re="${u}REOPEN tags=${tags} reopened=[0-9]+/[0-9]+ missing=${tags}$" ;;
    *) return 2 ;;
  esac
  [[ "$1" =~ $re ]]
}

case_swap_from_primary() {
  # primary runs (the Dock's); swap tag-b quits it, and the switcher's own
  # quit of primary logs no update close, so primary_seen clears. Then the
  # updater closes tag-b (an idle close, the install, the helper reopens
  # primary): tag-b reads updater, and reopen brings it back. Without the
  # clear, primary would count as one more closure in tag-b's span, and
  # tag-b would read unknown and never be reopened (#24's headline path).
  scenario
  ps_rows 501:primary
  export AS_FAKE_QUIT=graceful AS_FAKE_OPEN_SPAWNS_PID=4502
  run_switcher list
  local listed_p
  listed_p="$(rec_q '.primary_seen_utc | type')"
  run_switcher swap tag-b --no-mirror --no-handoff
  local swap_rc="$rc" swap_p seen_b
  swap_p="$(rec_q '.primary_seen_utc | type')"
  seen_b="$(rec_q '.open[] | select(.tag == "tag-b") | .seen_utc')"
  local t
  t="$(/bin/date +%s)"
  ps_rows 4400:primary
  idle_line "$t"
  helper_install "$t"
  updater_flag true
  run_switcher list
  local list_out="$out"
  export AS_FAKE_OPEN_SPAWNS_PID=4503
  run_switcher reopen
  local reopen_rc="$rc" reopen_out="$out"
  # Every QUIT_ALL, CLOSED and REOPEN row has exactly its shape; control: a
  # planted udd= on a row of each kind fails it.
  local l bad="" n_q=0 n_c=0 n_r=0 control=""
  while IFS= read -r l; do
    row_shape "$l"
    case $? in
      0) case "$l" in *"] QUIT_ALL"*) n_q=$((n_q + 1)) ;; *"] CLOSED "*) n_c=$((n_c + 1)) ;; *) n_r=$((n_r + 1)) ;; esac ;;
      1) bad="${bad} bad-row" ;;
    esac
  done <<< "$(history_text)"
  for l in "[2026-11-12T00:00:00Z] QUIT_ALL tags=primary by=swap udd=/x" \
           "[2026-11-12T00:00:00Z] CLOSED tag=tag-b seen=2026-11-12T00:00:00Z cause=updater event=none udd=/x" \
           "[2026-11-12T00:00:00Z] REOPEN tags=tag-b reopened=1/1 missing=none udd=/x"; do
    row_shape "$l" && control="${control} passed"
  done
  out="${list_out}"$'\n'"${reopen_out}"
  assert_eq "$listed_p" "string" "primary_seen after the first list" &&
    assert_eq "$swap_rc" "0" "swap" &&
    assert_eq "$swap_p" "null" "primary_seen after the swap quit primary" &&
    assert_eq "$([[ "$seen_b" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && printf ok)" "ok" "tag-b tracked from the swap" &&
    assert_contains "$(history_text)" "] QUIT_ALL tags=primary by=swap" &&
    assert_contains "$list_out" "$(printf '  %-12s %-30slast seen %s' tag-b "closed by the app's updater" "$seen_b")" &&
    assert_contains "$(history_text)" "CLOSED tag=tag-b seen=${seen_b} cause=updater event=idle-update" &&
    assert_eq "$reopen_rc" "0" "reopen" &&
    assert_contains "$reopen_out" "  tag-b · PID 4503" &&
    assert_contains "$reopen_out" "reopen reopened=1/1 missing=none unknown=none exit=0" &&
    assert_eq "$(n_open_flagless)" "0" "opens without --user-data-dir" &&
    assert_eq "$bad" "" "rows off their shape" &&
    assert_eq "${n_q}/${n_c}/${n_r}" "1/1/1" "QUIT_ALL/CLOSED/REOPEN rows" &&
    assert_eq "$control" "" "control: a planted udd= fails each shape"
  result "swap tag-b from a running primary clears primary_seen (its own quit logs no update close), so the updater's close of tag-b reads updater and reopen brings it back; every QUIT_ALL, CLOSED and REOPEN row has its exact shape (control: a planted udd= fails each)" $?
}

case_signin_observes() {
  # signin observes before its open: tag-a and primary, last seen 10 minutes
  # ago, carry signin's stamp, as tag-b does. Then tag-b is quit by hand,
  # and the updater closes tag-a and primary; the install; the helper
  # reopens primary. Both tags read unknown. Without the observation, tag-b
  # alone would be seen at signin's stamp, the two closes would cover it,
  # and the hand-quit tag-b would read closed by the updater.
  scenario
  ps_rows 501:primary 502:tag-a
  seed "$SEEN_EP" - "tag-a:${SEEN_EP}"
  export AS_FAKE_OPEN_SPAWNS_PID=4503
  run_switcher signin tag-b --timeout 30 --settle 0
  local si_rc="$rc" stamps
  stamps="$(rec_q '[.open[] | .seen_utc] + [.primary_seen_utc] | unique | length')"
  local t
  t="$(/bin/date +%s)"
  ps_rows 4400:primary
  idle_line "$t"
  idle_line "$t" main1.log
  helper_install "$t"
  run_switcher list
  local h
  h="$(history_text)"
  out="signin_rc=${si_rc} stamps=${stamps}"$'\n'"${out}"
  assert_eq "$si_rc" "3" "signin (no account appears: timeout)" &&
    assert_eq "$stamps" "1" "one stamp for tag-a, tag-b and primary after signin" &&
    assert_contains "$h" "CLOSED tag=tag-a" &&
    assert_contains "$h" "CLOSED tag=tag-b" &&
    assert_not_contains "$h" "cause=updater"
  result "signin observes before its open: tag-a and primary take its stamp with tag-b, so a tag-b quit by hand in the chain reads unknown, never updater" $?
}

# ---- A tag seen again (Stage 5 A-1) ---------------------------------------------------

case_launch_clears() {
  # tag-a is recorded as closed by the updater; launch tag-a sees its new
  # PID, so the closure clears; then tag-a is quit by hand: a new closure.
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  export AS_FAKE_OPEN_SPAWNS_PID=4501
  run_switcher launch tag-a
  local closed_after
  closed_after="$(rec_q '.closed | length')"
  set_ps_fixture ps-no-claude.txt
  run_switcher list
  assert_eq "$closed_after" "0" "the closure clears when launch saw the PID" &&
    assert_eq "$(count_matching "$(history_text)" "] CLOSED tag=tag-a ")" "1" "a new CLOSED row for the second closure" &&
    assert_contains "$(history_text)" "cause=unknown event=none"
  result "a launch that sees the tag's new PID clears its closure, so a later hand quit is a closure of its own (FM-2)" $?
}

case_open_never_took() {
  # The same, but the open produces no instance: the first closure and its
  # cause stand, and no second row is written.
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  run_switcher launch tag-a
  run_switcher list
  assert_eq "$(count_matching "$(history_text)" "] CLOSED ")" "0" "CLOSED rows" &&
    assert_contains "$out" "$(row_for tag-a updater)" &&
    assert_eq "$(rec_q '.open | length')" "0" "the open entry that never took"
  result "an open that produced no instance: the first closure and its cause stand, no second row" $?
}

# An open fake that records the call and fails (exit 1), launching nothing
# (the same fake as t-10-update.sh's).
failing_open_fake() {
  /bin/cat > "${AS_FAKES_DIR}/open" <<'FAKE'
#!/bin/bash
# as-fake: recording
line="open"
for arg; do line="${line}"$'\t'"${arg}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
exit 1
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/open" || harness_error "cannot chmod the open fake"
}

case_open_fails() {
  # INT-7: a failed open writes no record entry, no LAUNCH row and no
  # marker, and tag-a's recorded closure stands. Control: the same launch
  # with an open that works writes all three.
  local fail_rc fail_calls fail_open fail_closed fail_marker fail_hist
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  printf 'tag-b\n' > "${AS_STORE}/.statusline-marker"
  failing_open_fake
  run_switcher launch tag-a
  fail_rc="$rc"
  fail_calls="$(count_matching "$(calls_of open)" "--user-data-dir=$(pdir tag-a)")"
  fail_open="$(rec_q '[.open[].tag] | join(",")')"
  fail_closed="$(rec_q '[.closed[].tag] | join(",")')"
  fail_marker="$(< "${AS_STORE}/.statusline-marker")"
  fail_hist="$(history_text)"
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  printf 'tag-b\n' > "${AS_STORE}/.statusline-marker"
  export AS_FAKE_OPEN_SPAWNS_PID=4501
  run_switcher launch tag-a
  assert_eq "$fail_rc" "1" "exit of the launch whose open failed" &&
    assert_eq "$fail_calls" "1" "open calls for tag-a" &&
    assert_eq "$fail_open" "" "the record's open tags after the failed open" &&
    assert_eq "$fail_closed" "tag-a" "the recorded closure after the failed open" &&
    assert_eq "$fail_marker" "tag-b" "the marker after the failed open" &&
    assert_not_contains "$fail_hist" "LAUNCH tag=" &&
    assert_rc 0 &&
    assert_eq "$(rec_q '[.open[].tag] | join(",")')" "tag-a" "control: the record's open tags" &&
    assert_eq "$(< "${AS_STORE}/.statusline-marker")" "tag-a" "control: the marker" &&
    assert_contains "$(history_text)" "LAUNCH tag=tag-a "
  result "INT-7: a launch whose open fails writes no record entry, no LAUNCH row and no marker, and the recorded closure stands (control: a working open writes all three)" $?
}

# ---- reopen (#24 AC3) ---------------------------------------------------------------

# updater_flag <true|false>: the helper's state file (JSON) with
# launchAfterInstallation set.
updater_flag() {
  /bin/mkdir -p "$AS_UPDATER_CACHE" || harness_error "cannot create the updater cache"
  printf '{"launchAfterInstallation": %s, "useUpdateBundleName": true}\n' "$1" > "${AS_UPDATER_CACHE}/ShipItState.plist"
}

# The open calls without --user-data-dir (primary), and with a tag's.
n_open_flagless() {
  local l n=0
  while IFS= read -r l; do [[ "$l" == $'open\t-n\t-a\tClaude' ]] && n=$((n + 1)); done < <(calls_of open)
  printf '%d' "$n"
}
n_open_tag() {
  local l n=0
  while IFS= read -r l; do [[ "$l" == $'open\t-n\t-a\tClaude\t--args\t--user-data-dir='"$(pdir "$1")" ]] && n=$((n + 1)); done < <(calls_of open)
  printf '%d' "$n"
}

case_reopen_helper_primary() {
  # The helper reopened primary after an install it was asked to reopen the
  # app from; primary and tag-a are recorded as closed by the updater.
  scenario
  ps_rows 4400:primary
  seed - -
  seed_closed primary "$SEEN_EP" updater idle-update
  seed_closed tag-a "$SEEN_EP" updater idle-update
  updater_flag true
  helper_install "$((NOW_EP - 20))"
  export AS_FAKE_OPEN_SPAWNS_PID=4501
  run_switcher reopen
  assert_rc 0 &&
    assert_eq "$(n_open_tag tag-a)" "1" "opens of tag-a" &&
    assert_eq "$(n_open_flagless)" "0" "opens without --user-data-dir" &&
    assert_contains "$out" "  tag-a · PID 4501" &&
    assert_contains "$out" "reopen reopened=1/1 missing=none unknown=none exit=0" &&
    assert_eq "$(rec_q '.closed | length')" "0" "closed entries left" &&
    assert_contains "$(history_text)" "] REOPEN tags=tag-a reopened=1/1 missing=none"
  result "reopen: the helper's primary is running, so only tag-a opens (never an open without --user-data-dir); the records clear, one REOPEN row, exit 0" $?
}

case_reopen_never_appears() {
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  run_switcher reopen
  local first_rc="$rc" first_out="$out"
  run_switcher list
  local list_out="$out"
  run_switcher reopen
  out="${first_out}"$'\n'"${list_out}"$'\n'"${out}"
  assert_eq "$first_rc" "3" "the first reopen" &&
    assert_contains "$first_out" "reopen reopened=0/1 missing=tag-a unknown=none exit=3" &&
    assert_not_contains "$(history_text)" "] CLOSED " &&
    assert_contains "$list_out" "$(row_for tag-a updater)" &&
    assert_rc 3 &&
    assert_eq "$(n_open_tag tag-a)" "2" "opens of tag-a over both reopens"
  result "reopen: a tag that never appears -> exit 3, named, still recorded; list writes no second CLOSED row and still shows it; the next reopen offers it again" $?
}

case_reopen_refusals() {
  local lock_ok=1 install_ok=1
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  /bin/mkdir -p "${AS_STORE}/.update.lock" || harness_error "cannot create the lock"
  printf 'pid=4242 started_epoch=%s started_utc=%s\n' "$NOW_EP" "$(utc_of "$NOW_EP")" > "${AS_STORE}/.update.lock/owner"
  run_switcher reopen
  if [[ "$rc" == "2" && "$err" == *"An update is running"*"Not reopening"* && -z "$(calls_of open)" ]]; then lock_ok=0; fi
  local lock_err="$err"
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" updater idle-update
  /bin/mkdir -p "$AS_UPDATER_CACHE" || harness_error "cannot create the updater cache"
  printf '%s.500 ShipIt[1:2] Beginning installation\n' "$(local_of "$NOW_EP")" > "${AS_UPDATER_CACHE}/ShipIt_stderr.log"
  run_switcher reopen
  if [[ "$rc" == "2" && "$err" == *"The updater is installing right now; nothing was opened."* && -z "$(calls_of open)" ]]; then install_ok=0; fi
  out="${lock_err}"$'\n'"${err}"
  assert_eq "$lock_ok" "0" "under the update lock" &&
    assert_eq "$install_ok" "0" "while an install runs" &&
    assert_not_contains "$(history_text)" "REOPEN"
  result "reopen refuses (exit 2, nothing opened, no row) while update holds its lock and while the updater's log shows an install running" $?
}

case_reopen_waits_for_helper() {
  local waited=1 control=1
  # 30 s after a completed install, the flag true, primary not running yet:
  # reopen waits for the helper's primary and never opens it.
  scenario ps-no-claude.txt
  seed - -
  seed_closed primary "$SEEN_EP" updater idle-update
  updater_flag true
  helper_install "$((NOW_EP - 30))"
  set_ps_next_fixture ps-primary-only.txt
  run_switcher reopen
  if [[ "$rc" == "0" && "$(n_open_flagless)" == "0" && "$out" == *"  primary · PID 501 (opened by the updater; not opened again)"* \
        && "$out" == *"reopen reopened=1/1 missing=none unknown=none exit=0"* ]]; then waited=0; fi
  local first="$out"
  # Control: the flag false, the same table switch: reopen opens primary.
  scenario ps-no-claude.txt
  seed - -
  seed_closed primary "$SEEN_EP" updater idle-update
  updater_flag false
  helper_install "$((NOW_EP - 30))"
  export AS_FAKE_OPEN_SPAWNS_PID=4502
  run_switcher reopen
  if [[ "$(n_open_flagless)" == "1" ]]; then control=0; fi
  out="${first}"$'\n'"${out}"
  assert_eq "$waited" "0" "waits for the helper's primary, never opens it" &&
    assert_eq "$control" "0" "control: with the flag false it opens primary"
  result "reopen right after an install the updater reopens: it waits for the helper's primary (seen on a later poll) and never opens it (control: with the flag false it opens primary)" $?
}

case_reopen_unknown_only() {
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-a "$SEEN_EP" unknown none
  run_switcher reopen
  assert_rc 0 &&
    assert_contains "$out" "Nothing to reopen: no tag is recorded as closed by the app's updater." &&
    assert_contains "$out" "Not reopened (closed, cause unknown; it may have been closed on purpose):" &&
    assert_contains "$out" "  account-switcher launch tag-a" &&
    assert_contains "$out" "reopen reopened=0/0 missing=none unknown=tag-a exit=0" &&
    assert_never_called open &&
    assert_not_contains "$(history_text)" "REOPEN"
  result "reopen with only 'cause unknown' tags: nothing opens, each is named with a launch command, exit 0" $?
}

case_reopen_unconfigured() {
  # A tag recorded as closed by the updater that is neither in [accounts]
  # nor on disk any more would open as a new, empty profile.
  scenario ps-no-claude.txt
  seed - -
  seed_closed tag-z "$SEEN_EP" updater idle-update
  run_switcher reopen
  assert_rc 3 &&
    assert_contains "$out" "  account-switcher launch tag-z --new" &&
    assert_contains "$out" "reopen reopened=0/1 missing=tag-z unknown=none exit=3" &&
    assert_never_called open
  result "reopen never opens a tag that is neither in [accounts] nor on disk: named with launch --new, exit 3" $?
}

case_reopen_arguments() {
  scenario ps-no-claude.txt
  run_switcher reopen tag-a
  assert_rc 2 &&
    assert_contains "$err" "Usage: account-switcher reopen" &&
    assert_never_called ps
  result "reopen takes no arguments: exit 2 with the usage line, before reading the process table" $?
}

case_cause_idle
case_cause_forced
case_cause_no_event
case_cause_one_event_two_tags
case_cause_no_log
case_cause_log_files
case_undetermined
case_binary_missing
case_list_twice
case_quit_then_list
case_swap_then_list
case_adopt
case_planted_ids
case_install_check
case_count_hand_quit
case_count_alone
case_count_primary_tracked
case_count_primary_untracked
case_count_cost
case_count_no_helper_log
case_mark
case_mark_moves
case_mark_moves_unknown
case_one_clock
case_swap_from_primary
case_signin_observes
case_launch_clears
case_open_never_took
case_open_fails
case_reopen_helper_primary
case_reopen_never_appears
case_reopen_refusals
case_reopen_waits_for_helper
case_reopen_unknown_only
case_reopen_unconfigured
case_reopen_arguments
finish
