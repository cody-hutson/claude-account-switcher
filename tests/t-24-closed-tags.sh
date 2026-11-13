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
case_mark
case_mark_moves
case_one_clock
case_launch_clears
case_open_never_took
finish
