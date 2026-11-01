#!/usr/bin/env bash
# tests/t-10-update.sh - #10: a staged app update is shown and installed on
# request, update holds a lock that launch, swap and signin respect, and
# launch and swap refuse a tag that is neither configured nor on disk.
#
# Every case builds a fake updater cache under the scratch HOME: the helper's
# state file (rendered from fixtures/update/shipit-state.json, the five real
# key names with fake values), generated installed and staged Info.plist
# files, and the helper's log (fixtures/update/shipit-log.txt, masked:
# timestamped and untimestamped lines). The per-poll hook (AS_TEST_POLL_HOOK)
# plays the helper during update's wait: it appends the completion line,
# swaps the installed version, removes the staged bundle and, when asked,
# starts the flagless instance the helper opens itself. The process table
# always holds the helper (PID 610), which is not a main process, so the
# kill fake shows it is never signalled.
#
# The helper stamps its log in local time with no zone. The cases run in a
# zone 5 hours west of UTC with no daylight saving (TZ=XST5), so a reader
# that mixed local time and UTC would read the wrong instant; the case for
# the other side of the step's start runs 5 hours east (TZ=XST-5).

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

TZ="XST5"
export TZ

OLD_V="4.29.0"
NEW_V="4.4212.0"
HELPER_PID=610
RELAUNCH_PID=4400
# The fixture log's last timestamped line, and its first install request
# after the last completed install (2026-10-29 12:37:33 local, read in UTC-5).
LIVE_LINE="2026-10-31 11:21:05.500 ShipIt[113:214] Detected this as an install request"
SEED_UTC="2026-10-29T17:37:33Z"
DECOY_MARK="DECOY-PROFILE-CONTENT"

# ---- Scenario ----------------------------------------------------------------

pdir() {
  if [[ "$1" == "primary" ]]; then
    printf '%s' "${AS_PROFILE_ROOT}/Claude"
  else
    printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"
  fi
}

app_plist() { printf '%s' "${AS_APP_BUNDLE}/Contents/Info.plist"; }
staged_plist() { printf '%s' "${AS_UPDATER_CACHE}/update.fake1/Claude.app/Contents/Info.plist"; }
state_path() { printf '%s' "${AS_UPDATER_CACHE}/ShipItState.plist"; }
log_path() { printf '%s' "${AS_UPDATER_CACHE}/ShipIt_stderr.log"; }
lock_path() { printf '%s' "${AS_STORE}/.update.lock"; }
# The lock as messages show it: under ~, never the home folder's absolute path.
# A literal ~ is the point here (display text).
# shellcheck disable=SC2088
LOCK_SHOWN='~/.claude/account-switcher/.update.lock'

# info_plist <path> <version>: a generated Info.plist (XML).
info_plist() {
  /bin/mkdir -p "${1%/*}" || harness_error "cannot create ${1%/*}"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>fake</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' "$2" > "$1"
}

# state_file <true|false> [xml]: the helper's state file from the fixture,
# with launchAfterInstallation set; xml converts it to an XML property list
# (not JSON), which only the plutil fallback reads.
state_file() {
  local l f
  f="$(state_path)"
  : > "$f"
  while IFS= read -r l || [[ -n "$l" ]]; do
    printf '%s\n' "${l//__LAI__/$1}" >> "$f"
  done < "${FIXTURES}/update/shipit-state.json"
  if [[ "${2:-}" == "xml" ]]; then
    /usr/bin/plutil -convert xml1 "$f" || harness_error "cannot convert the state file"
  fi
}

# write_config [line ...]: [accounts] primary, tag-a, tag-b; [update] with a
# 10 s install timeout and any extra lines.
write_config() {
  local l
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'primary = { label = "Primary" }\n'
    printf 'tag-a = { label = "Alpha" }\n'
    printf 'tag-b = { label = "Beta" }\n'
    printf '\n[update]\ninstall_timeout_s = 10\n'
    for l; do printf '%s\n' "$l"; done
    printf '\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT"
  } > "${AS_STORE}/config.toml"
}

# ps_table [<pid>:<tag> ...]: the process table (primary without a flag,
# any other tag with its --user-data-dir) plus the updater's helper; every
# PID alive. A graceful quit leaves only the helper.
ps_table() {
  local spec helper
  printf -v helper '%5s %s %s' "$HELPER_PID" \
    "${AS_APP_BUNDLE}/Contents/Frameworks/Squirrel.framework/Resources/ShipIt" "$(state_path)"
  {
    printf '  PID ARGS\n'
    for spec; do
      if [[ "${spec#*:}" == "primary" ]]; then
        printf '%5s %s\n' "${spec%%:*}" "${AS_APP_BUNDLE}/Contents/MacOS/Claude"
      else
        printf '%5s %s --user-data-dir=%s\n' "${spec%%:*}" "${AS_APP_BUNDLE}/Contents/MacOS/Claude" "$(pdir "${spec#*:}")"
      fi
    done
    printf '%s\n' "$helper"
  } > "$AS_FIXTURE_PS"
  {
    for spec; do printf '%s\n' "${spec%%:*}"; done
    printf '%s\n' "$HELPER_PID"
  } > "${AS_TEST_ROOT}/alive.txt"
  printf '  PID ARGS\n%s\n' "$helper" > "$AS_FIXTURE_PS_AFTER_QUIT"
  AS_FAKE_QUIT=graceful
  export AS_FAKE_QUIT
}

# multi_open_fake <pid> ...: an open fake that starts the next PID in the
# list on each call (one instance per open, with the --user-data-dir it was
# given), and nothing once the list is used up.
multi_open_fake() {
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

# scenario <installed> <staged|none> <launchAfterInstallation> [<pid>:<tag> ...]
scenario() {
  local installed="$1" staged="$2" lai="$3"
  shift 3
  new_case
  unset AS_TEST_STDIN_IS_TTY AS_TEST_POLL_HOOK
  /bin/mkdir -p "$AS_STORE" "$(pdir primary)" "$(pdir tag-a)" "$(pdir tag-b)" "$AS_UPDATER_CACHE" \
    || harness_error "cannot create the scenario folders"
  write_config
  info_plist "$(app_plist)" "$installed"
  if [[ "$staged" != "none" ]]; then info_plist "$(staged_plist)" "$staged"; fi
  state_file "$lai"
  render_fixture "${FIXTURES}/update/shipit-log.txt" "$(log_path)"
  ps_table "$@"
  multi_open_fake 4301 4302 4303
}

# helper_hook <mode> [<poll>] [<relaunch 0|1>] [<new version>]: the per-poll
# hook that plays the updater's helper on poll <poll> (default 2):
#   install    "Beginning installation" and "Installation completed
#              successfully" stamped now, the installed Info.plist then reads
#              <new version>, the staged bundle is gone, and with relaunch=1
#              a main process with no --user-data-dir (PID 4400) starts
#   unchanged  the two log lines only (the version stays)
#   begin      "Beginning installation" only (an install still running)
#   none       nothing
# With CHECK=1 in hook.conf it also records, on that poll, whether the lock
# exists, install.sh --check's output and exit code, and a launch's.
helper_hook() {
  local hook="${AS_TEST_ROOT}/hook.sh"
  printf 'MODE=%s\nAT=%s\nRELAUNCH=%s\nNEWV=%s\nRELAUNCH_PID=%s\nCHECK=0\nREPO_DIR=%s\nSWITCHER_PATH=%s\n' \
    "$1" "${2:-2}" "${3:-0}" "${4:-$NEW_V}" "$RELAUNCH_PID" "$REPO" "$SWITCHER" > "${AS_TEST_ROOT}/hook.conf"
  /bin/cat > "$hook" <<'HOOK'
#!/bin/bash
set -u
. "${AS_TEST_ROOT}/hook.conf"
printf '%s\n' "$1" >> "${AS_TEST_ROOT}/hook-polls.txt"
[[ "$1" == "$AT" ]] || exit 0
stamp="$(/bin/date '+%Y-%m-%d %H:%M:%S').500"
log="${AS_UPDATER_CACHE}/ShipIt_stderr.log"
case "$MODE" in
  install|unchanged)
    printf '%s ShipIt[115:216] Beginning installation\n' "$stamp" >> "$log"
    printf 'ERROR: Unrecognized attribute string flag in a dump\n' >> "$log"
    printf '%s ShipIt[115:216] Installation completed successfully\n' "$stamp" >> "$log"
    ;;
  begin)
    printf '%s ShipIt[115:216] Beginning installation\n' "$stamp" >> "$log"
    printf 'ERROR: Unrecognized attribute string flag in a dump\n' >> "$log"
    ;;
esac
if [[ "$MODE" == "install" ]]; then
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>CFBundleShortVersionString</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' \
    "$NEWV" > "${AS_APP_BUNDLE}/Contents/Info.plist"
  /bin/rm -rf "${AS_UPDATER_CACHE}/update.fake1"
  if [[ "$RELAUNCH" == "1" ]]; then
    printf '%5s %s\n' "$RELAUNCH_PID" "${AS_APP_BUNDLE}/Contents/MacOS/Claude" >> "$AS_FIXTURE_PS"
    printf '%s\n' "$RELAUNCH_PID" >> "${AS_TEST_ROOT}/alive.txt"
  fi
fi
if [[ "$CHECK" == "1" ]]; then
  if [[ -d "${AS_STORE}/.update.lock" ]]; then printf 'yes\n' > "${AS_TEST_ROOT}/lock-seen.txt"; fi
  /bin/bash "${REPO_DIR}/install.sh" --check > "${AS_TEST_ROOT}/check-out.txt" 2>&1
  printf '%s\n' "$?" > "${AS_TEST_ROOT}/check-rc.txt"
  /bin/bash "$SWITCHER_PATH" launch tag-b > "${AS_TEST_ROOT}/launch-out.txt" 2>&1 < /dev/null
  printf '%s\n' "$?" > "${AS_TEST_ROOT}/launch-rc.txt"
fi
exit 0
HOOK
  /bin/chmod 755 "$hook" || harness_error "cannot chmod the hook"
  AS_TEST_POLL_HOOK="$hook"
  export AS_TEST_POLL_HOOK
}

# run_up <stdin text> <arg> ...: the switcher in test mode with stdin from a
# file holding <stdin text>; sets out, err and rc.
run_up() {
  local in="${AS_TEST_ROOT}/.run-in" o="${AS_TEST_ROOT}/.run-out" e="${AS_TEST_ROOT}/.run-err"
  printf '%s' "$1" > "$in"
  shift
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$SWITCHER" "$@"
  ) > "$o" 2> "$e" < "$in"
  rc=$?
  _read_run "$o" "$e"
}

history_text() {
  if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi
}

# n_calls <fake> <exact line>: how many calls.log lines equal <exact line>.
n_calls() {
  local l n=0
  while IFS= read -r l; do
    [[ "$l" == "$2" ]] && n=$((n + 1))
  done < <(calls_of "$1")
  printf '%d' "$n"
}

# Open calls without --user-data-dir (primary), and with a tag's.
opens_flagless() { n_calls open $'open\t-n\t-a\tClaude'; }
opens_tag() { n_calls open $'open\t-n\t-a\tClaude\t--args\t--user-data-dir='"$(pdir "$1")"; }

# No kill call names the helper's PID, and no PID was refused as a stray.
assert_helper_untouched() {
  local k
  k="$(calls_of kill)"
  assert_not_contains "$k" $'\t'"${HELPER_PID}" && assert_not_contains "$k" "STRAY"
}

assert_no_lock() {
  [[ ! -e "$(lock_path)" ]] && return 0
  printf '    the update lock is still there\n'
  return 1
}

# json_field <field>: one field of update-state.json, through the real jq.
json_field() { /usr/bin/jq -r ".$1 // \"null\"" "${AS_STORE}/update-state.json" 2> /dev/null; }

file_mode() { /usr/bin/stat -f '%Lp' "$1" 2> /dev/null; }

# Lines of $1 that contain $2.
count_matching() {
  local l n=0
  while IFS= read -r l; do [[ "$l" == *"$2"* ]] && n=$((n + 1)); done <<< "$1"
  printf '%d' "$n"
}

# make_lock <age seconds|none>: a lock as update writes it (an owner line
# with the start time), or a bare directory with none.
make_lock() {
  local ep
  /bin/mkdir -p "$(lock_path)" || harness_error "cannot create the lock"
  if [[ "$1" != "none" ]]; then
    ep=$(( $(/bin/date +%s) - $1 ))
    printf 'pid=4242 started_epoch=%s started_utc=%s\n' "$ep" "$(/bin/date -u -r "$ep" +%Y-%m-%dT%H:%M:%SZ)" \
      > "$(lock_path)/owner"
  fi
}

# The script without its last line (the call to main), for drivers that
# source it (as t-08 does). Prints the copy's path.
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

# ---- The reader's scope (#10's "reads only" criterion) -------------------------

# reader_scope_check <calls.log copy>: every absolute path an argument names
# is one of the four helper files, and only the reader's commands ran.
# Prints each offending call; returns 1 when there is one.
reader_scope_check() {
  local l name args a bad=0 allowed cmds=" PlistBuddy jq plutil awk ps "
  allowed=" $(state_path) | $(app_plist) | $(staged_plist) | $(log_path) "
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ -n "$l" ]] || continue
    name="${l%%$'\t'*}"
    case "$cmds" in
      *" ${name} "*) ;;
      *) printf '    a command outside the reader ran: %s\n' "$l"; bad=1; continue ;;
    esac
    args="${l#"$name"}"
    while [[ -n "$args" ]]; do
      args="${args#$'\t'}"
      a="${args%%$'\t'*}"
      args="${args#"$a"}"
      case "$a" in
        /*) [[ "$allowed" == *" ${a} "* ]] || { printf '    a path outside the allowed set: %s\n' "$a"; bad=1; } ;;
      esac
      case "$a" in
        *Cookies*|*"Local Storage"*|*IndexedDB*|*config.json*|*.claude.json*)
          printf '    a profile or token path: %s\n' "$a"; bad=1 ;;
      esac
    done
  done < "$1"
  return "$bad"
}

case_reader_scope() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  /bin/mkdir -p "$(pdir tag-a)/Local Storage/leveldb" || harness_error "cannot create the decoys"
  printf '%s\n' "$DECOY_MARK" > "$(pdir tag-a)/Cookies"
  printf '%s\n' "$DECOY_MARK" > "$(pdir tag-a)/Local Storage/leveldb/LOCK"
  printf '{"lastKnownAccountUuid": "%s", "oauth:tokenCache": "%s"}\n' "$DECOY_MARK" "$DECOY_MARK" \
    > "$(pdir tag-a)/config.json"
  local driver="${AS_TEST_ROOT}/reader-driver.sh" reader_ok=0 control_ok=0 full_ok=0 report
  /bin/cat > "$driver" <<'DRIVER'
#!/bin/bash
set -euo pipefail
. "$1"
: > "${AS_TEST_ROOT}/calls.log"
_update_installed
_update_staged
_updater_flag
_updater_log_scan "" || :
claude_instances > /dev/null || :
if [[ "${T10_CONTROL:-0}" == "1" ]]; then profile_account_uuid "$(udd_for_tag tag-a)" > /dev/null || :; fi
printf 'installed=%s staged=%s flag=%s last=%s\n' "$UPD_INSTALLED" "$UPD_STAGED" "$UPD_FLAG" "$UPD_LOG_LAST"
DRIVER
  # The reader alone.
  run_driver "$driver"
  /bin/cp "${AS_TEST_ROOT}/calls.log" "${AS_TEST_ROOT}/calls-reader.txt"
  report="$(reader_scope_check "${AS_TEST_ROOT}/calls-reader.txt")" || reader_ok=1
  [[ "$rc" == "0" && "$out" == "installed=${OLD_V} staged=${NEW_V} flag=false last=${LIVE_LINE}" ]] || reader_ok=1
  # Every one of the four files was read (so the check is not empty).
  local f
  for f in "$(state_path)" "$(app_plist)" "$(staged_plist)" "$(log_path)"; do
    [[ "$(< "${AS_TEST_ROOT}/calls-reader.txt")" == *"$f"* ]] || reader_ok=1
  done
  # Control arm: the same check over a run that also does #6's identity read
  # (config.json, through jq) must fail.
  T10_CONTROL=1
  export T10_CONTROL
  run_driver "$driver"
  unset T10_CONTROL
  /bin/cp "${AS_TEST_ROOT}/calls.log" "${AS_TEST_ROOT}/calls-control.txt"
  if reader_scope_check "${AS_TEST_ROOT}/calls-control.txt" > /dev/null; then control_ok=1; fi
  # The whole list and update commands: no profile or token path, no
  # keychain, and the decoys never reach any output.
  : > "${AS_TEST_ROOT}/calls.log"
  helper_hook install
  run_switcher list
  local list_out="$out"
  run_up "" update --yes
  local calls
  calls="$(< "${AS_TEST_ROOT}/calls.log")"
  [[ "$rc" == "0" ]] || full_ok=1
  case "$calls" in
    *Cookies*|*"Local Storage"*|*IndexedDB*|*config.json*|*.claude.json*) full_ok=1 ;;
  esac
  [[ -z "$(calls_of security)" ]] || full_ok=1
  [[ "${list_out}${out}${err}" != *"$DECOY_MARK"* ]] || full_ok=1
  out="${report}"
  assert_eq "$reader_ok" "0" "the reader's calls stay in the allowed set" &&
    assert_eq "$control_ok" "0" "control: the identity read is flagged" &&
    assert_eq "$full_ok" "0" "list and update name no profile, token or keychain path"
  result "reader scope: the reader runs only PlistBuddy, jq, plutil, awk and ps, on the state file, both Info.plist files and the log (control: #6's config.json read is flagged); list and update open no cookies, Local Storage, keychain or token" $?
}

# ---- list ----------------------------------------------------------------------

case_list_rows() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  /bin/mkdir -p "$(pdir tag-x)" || harness_error "cannot create the stray folder"
  printf 'tag-a\n' > "${AS_STORE}/.statusline-marker"
  local marker_before
  marker_before="$(/usr/bin/shasum < "${AS_STORE}/.statusline-marker")"
  run_switcher list
  local first_out="$out" first_rc="$rc" stray_row a_row
  printf -v stray_row '  %-12s %s  (' tag-x "$(pdir tag-x)"
  printf -v a_row '  %-12s %s  (' tag-a "$(pdir tag-a)"
  local re_wait="waiting:   [0-9]+d [0-9]+h \\(since ${SEED_UTC}\\)"
  local mode first_seen staged_rec
  mode="$(file_mode "${AS_STORE}/update-state.json")"
  first_seen="$(json_field first_seen_utc)"
  staged_rec="$(json_field staged_version)"
  # A second list keeps the recorded time, though every cache file is new.
  run_switcher list
  assert_eq "$first_rc" "0" "list exit" &&
    assert_contains "$first_out" "  installed: ${OLD_V}" &&
    assert_contains "$first_out" "  staged:    ${NEW_V}" &&
    [[ "$first_out" =~ $re_wait ]] &&
    assert_contains "$first_out" "To close them, install it and reopen the same tags: account-switcher update" &&
    assert_eq "$first_seen" "$SEED_UTC" "first_seen_utc (seeded from the log, read in local time)" &&
    assert_eq "$staged_rec" "$NEW_V" "staged_version recorded" &&
    assert_eq "$(json_field phase)" "idle" "phase" &&
    assert_eq "$mode" "600" "update-state.json mode" &&
    assert_contains "$first_out" "${stray_row}" &&
    assert_eq "$(count_matching "$first_out" "${stray_row}")" "1" "tag-x rows" &&
    assert_contains "$(printf '%s\n' "$first_out" | /usr/bin/grep -F "$stray_row")" "unconfigured" &&
    assert_not_contains "$(printf '%s\n' "$first_out" | /usr/bin/grep -F "$a_row")" "unconfigured" &&
    assert_contains "$first_out" "never deletes one" &&
    [[ -d "$(pdir tag-x)" ]] &&
    assert_unchanged "${AS_STORE}/.statusline-marker" "$marker_before" &&
    assert_contains "$out" "(since ${SEED_UTC})"
  result "list: installed, staged and waiting (first_seen_utc seeded from the log's first request after the last install, UTC; kept on the next list); update-state.json mode 600; the stray Claude-tag-x is unconfigured and kept; the tag marker untouched" $?
}

case_list_none() {
  scenario "$OLD_V" none false
  run_switcher list
  local none_out="$out"
  # A staged bundle with the installed version is not waiting either.
  info_plist "$(staged_plist)" "$OLD_V"
  run_switcher list
  assert_rc 0 &&
    assert_contains "$none_out" "  staged:    none" &&
    assert_not_contains "$none_out" "waiting:" &&
    assert_contains "$out" "  staged:    none" &&
    assert_eq "$(json_field staged_version)" "none" "staged_version recorded" &&
    assert_eq "$(json_field first_seen_utc)" "null" "first_seen_utc"
  result "list: nothing staged, or a staged bundle with the installed version -> staged none, no waiting row" $?
}

case_unknown_never_none() {
  local ok=0 o
  # (a) The cache folder can't be read.
  scenario "$OLD_V" "$NEW_V" false 501:primary
  /bin/chmod 000 "$AS_UPDATER_CACHE"
  run_switcher list
  o="$out"
  /bin/chmod 755 "$AS_UPDATER_CACHE"
  [[ "$o" == *"  staged:    unknown (the updater cache folder can't be read)"* && "$o" == *"  waiting:   unknown"* && "$o" != *"staged:    none"* ]] || { ok=1; printf '    (a) %s\n' "${o##*App update}"; }
  # (b) The installed Info.plist can't be read; update refuses, nothing closed.
  scenario "$OLD_V" "$NEW_V" false 501:primary
  /bin/chmod 000 "$(app_plist)"
  run_switcher list
  o="$out"
  run_up "" update --yes
  /bin/chmod 644 "$(app_plist)"
  [[ "$o" == *"  installed: unknown (the app's Info.plist can't be read)"* && "$rc" == "2" && "$err" == *"installed app's version can't be read"* ]] || { ok=1; printf '    (b) rc=%s\n' "$rc"; }
  [[ -z "$(calls_of osascript)" ]] || ok=1
  # (c) The staged Info.plist is not a property list.
  scenario "$OLD_V" "$NEW_V" false 501:primary
  printf 'not a plist\n' > "$(staged_plist)"
  run_switcher list
  o="$out"
  run_up "" update --yes
  [[ "$o" == *"  staged:    unknown (the staged bundle's Info.plist can't be read)"* && "$rc" == "2" && "$err" == *"Can't tell whether an update is staged"* ]] || { ok=1; printf '    (c) rc=%s\n' "$rc"; }
  # (d) No Claude cache at all; another app's ShipIt cache with a staged
  #     bundle is never read.
  scenario "$OLD_V" "$NEW_V" false
  /bin/mv "$AS_UPDATER_CACHE" "${HOME}/Library/Caches/com.example.other.ShipIt" || harness_error "cannot move the cache"
  info_plist "${HOME}/Library/Caches/com.example.other.ShipIt/update.fake1/Claude.app/Contents/Info.plist" "9.9.9"
  run_switcher list
  o="$out"
  [[ "$o" == *"  staged:    unknown (no updater cache folder)"* && "$o" != *"9.9.9"* ]] || { ok=1; printf '    (d) %s\n' "${o##*App update}"; }
  [[ "$(< "${AS_TEST_ROOT}/calls.log")" != *"com.example.other"* ]] || ok=1
  # (e) The helper's state file can't be read: update refuses.
  scenario "$OLD_V" "$NEW_V" false 501:primary
  /bin/chmod 000 "$(state_path)"
  run_up "" update --yes
  /bin/chmod 644 "$(state_path)"
  [[ "$rc" == "2" && "$err" == *"state file"* && -z "$(calls_of osascript)" ]] || { ok=1; printf '    (e) rc=%s\n' "$rc"; }
  # Control: the same reads with everything readable show versions, not unknown.
  scenario "$OLD_V" "$NEW_V" false
  run_switcher list
  [[ "$out" == *"  staged:    ${NEW_V}"* && "$out" == *"  installed: ${OLD_V}"* && "$out" != *"unknown ("* ]] || ok=1
  assert_eq "$ok" "0" "unknown cases"
  result "unknown, never none: an unreadable cache, installed or staged Info.plist, or a missing cache reads unknown (another app's ShipIt cache is never read); update refuses (exit 2, nothing closed), also on an unreadable state file" $?
}

case_versions_as_strings() {
  # 3.6556.2 is installed and 4.29.0 staged: a numeric compare of the middle
  # component would call the staged build older.
  scenario "3.6556.2" "4.29.0" false 501:primary
  run_switcher list
  local up_out="$out"
  helper_hook install 2 0 "4.29.0"
  run_up "" update --yes
  local up_rc="$rc" up_run="$out"
  # And the other way round: whatever differs is shown.
  scenario "4.29.0" "3.6556.2" false
  run_switcher list
  assert_eq "$up_rc" "0" "update exit" &&
    assert_contains "$up_out" "  staged:    4.29.0" &&
    assert_contains "$up_run" "Installed version: 3.6556.2 before, 4.29.0 after." &&
    assert_contains "$up_run" "result=updated" &&
    assert_contains "$out" "  staged:    3.6556.2" &&
    assert_contains "$out" "  installed: 4.29.0"
  result "versions are strings: 3.6556.2 -> 4.29.0 is staged and installed; 3.6556.2 staged over 4.29.0 is still shown" $?
}

# ---- update ---------------------------------------------------------------------

case_nothing_staged() {
  scenario "$OLD_V" none false 501:primary 502:tag-a
  run_up "" update
  assert_rc 0 &&
    assert_contains "$out" "No update is staged (installed: ${OLD_V}). Nothing to install; nothing was closed." &&
    assert_never_called osascript &&
    assert_never_called kill &&
    assert_never_called open &&
    assert_no_lock &&
    assert_not_contains "$(history_text)" "QUIT_ALL"
  result "update with nothing staged: says so, closes nothing, exit 0" $?
}

case_no_terminal_refuses() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  run_up "" update
  assert_rc 2 &&
    assert_contains "$out" "Install the staged Claude update: ${OLD_V} installed, ${NEW_V} staged." &&
    assert_contains "$out" "It will close:"$'\n'"  primary · PID 501"$'\n'"  tag-a · PID 502" &&
    assert_contains "$out" "Scheduled tasks pause while Claude is closed." &&
    assert_contains "$err" "update needs a terminal to confirm the list above, or --yes. Nothing was closed." &&
    assert_never_called osascript &&
    assert_never_called kill &&
    assert_no_lock
  result "update without a terminal or --yes: lists tag · PID and the scheduled-task warning, then refuses, exit 2, nothing closed" $?
}

case_confirm_at_terminal() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  AS_TEST_STDIN_IS_TTY=1
  export AS_TEST_STDIN_IS_TTY
  run_up $'n\n' update
  local n_rc="$rc" n_out="$out" n_osa
  n_osa="$(calls_of osascript)"
  helper_hook install
  run_up $'y\n' update
  assert_eq "$n_rc" "2" "declined exit" &&
    assert_contains "$n_out" "Close them and install ${NEW_V}? [y/N]" &&
    assert_contains "$n_out" "Not updating; nothing was closed." &&
    assert_eq "$n_osa" "" "osascript calls when declined" &&
    assert_rc 0 &&
    assert_contains "$out" "result=updated" &&
    assert_no_lock
  result "update at a terminal: n declines (exit 2, nothing closed); y installs (exit 0)" $?
}

case_completed() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  helper_hook install
  run_up "" update --yes
  local history
  history="$(history_text)"
  assert_rc 0 &&
    assert_called osascript 'tell application "Claude" to quit' &&
    assert_helper_untouched &&
    assert_eq "$(opens_flagless)" "1" "open calls for primary (no flag)" &&
    assert_eq "$(opens_tag tag-a)" "1" "open calls for tag-a" &&
    assert_eq "$(count_lines "$(calls_of open)")" "2" "open calls" &&
    assert_eq "$(n_calls sleep $'sleep\t1')" "1" "1 s waits (completion seen on poll 2)" &&
    assert_not_contains "$err" "shows no 'Installation completed successfully'" &&
    assert_contains "$out" "Reopening:"$'\n'"  primary · PID 4301"$'\n'"  tag-a · PID 4302" &&
    assert_contains "$out" "Installed version: ${OLD_V} before, ${NEW_V} after." &&
    assert_contains "$out" "update before=${OLD_V} after=${NEW_V} result=updated reopened=2/2 exit=0" &&
    assert_contains "$history" "] QUIT_ALL" &&
    assert_contains "$history" "LAUNCH tag=primary" &&
    assert_contains "$history" "LAUNCH tag=tag-a" &&
    assert_contains "$history" "UPDATE result=updated before=${OLD_V} after=${NEW_V} reopened=2/2" &&
    assert_no_lock &&
    assert_eq "$(json_field installed_version)" "$NEW_V" "installed_version recorded" &&
    assert_eq "$(json_field staged_version)" "none" "staged_version recorded" &&
    assert_eq "$(json_field phase)" "idle" "phase"
  result "update --yes, installed: quits through the quit path (the helper, PID 610, never signalled), sees the completion line stamped now (local time, UTC-5), reopens primary and tag-a, prints both versions, QUIT_ALL/LAUNCH/UPDATE rows, lock released, exit 0" $?
}

case_timeout() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  helper_hook none
  run_up "" update --yes
  assert_rc 1 &&
    assert_eq "$(n_calls sleep $'sleep\t1')" "10" "1 s waits (install_timeout_s = 10)" &&
    assert_eq "$(count_lines "$(< "${AS_TEST_ROOT}/hook-polls.txt")")" "10" "polls" &&
    assert_contains "$out" "No 'Installation completed successfully' within 10 s, and the installed version did not change. The updater log's last line:"$'\n'"  ${LIVE_LINE}" &&
    assert_not_contains "$out" "NSURL" &&
    assert_contains "$out" "result=timeout reopened=2/2 exit=1" &&
    assert_eq "$(opens_flagless)" "1" "primary reopened" &&
    assert_contains "$(history_text)" "UPDATE result=timeout before=${OLD_V} after=${OLD_V}" &&
    assert_helper_untouched &&
    assert_no_lock
  result "update: the bounded wait times out (10 polls) -> exit 1 with the log's last timestamped line (untimestamped lines skipped); the tags reopen" $?
}

case_either_side_of_start() {
  # East of UTC this time, with a completion line stamped 10 minutes before
  # the step's start: it must not count. (case_completed is the other side:
  # a line stamped now, in a zone west of UTC, counts on the first check.)
  scenario "$OLD_V" "$NEW_V" false 501:primary
  TZ="XST-5"
  export TZ
  printf '%s.500 ShipIt[99:98] Installation completed successfully\n' \
    "$(/bin/date -r $(( $(/bin/date +%s) - 600 )) '+%Y-%m-%d %H:%M:%S')" >> "$(log_path)"
  helper_hook none
  run_up "" update --yes
  TZ="XST5"
  export TZ
  assert_rc 1 &&
    assert_contains "$out" "result=timeout" &&
    assert_eq "$(n_calls sleep $'sleep\t1')" "10" "1 s waits"
  result "the step's start, in local time: a completion stamped 10 minutes before it (TZ UTC+5) does not count -> timeout, exit 1" $?
}

case_unchanged() {
  scenario "$OLD_V" "$NEW_V" false 501:primary
  helper_hook unchanged
  run_up "" update --yes
  assert_rc 1 &&
    assert_contains "$out" "The updater reported 'Installation completed successfully', but the installed version did not change." &&
    assert_contains "$out" "ShipIt[115:216] Installation completed successfully" &&
    assert_contains "$out" "Installed version: ${OLD_V} before, ${OLD_V} after." &&
    assert_contains "$out" "result=unchanged reopened=1/1 exit=1" &&
    assert_no_lock
  result "update: the helper finishes but the version did not change -> exit 1 with the log's last line" $?
}

case_lai_true() {
  # The request asked the helper to relaunch: its flagless instance is
  # primary's reopen, and update never opens primary itself.
  scenario "$OLD_V" "$NEW_V" true 501:primary 502:tag-a
  helper_hook install 2 1
  run_up "" update --yes
  local a_rc="$rc" a_out="$out" a_flagless a_tag a_plutil
  a_flagless="$(opens_flagless)"
  a_tag="$(opens_tag tag-a)"
  a_plutil="$(calls_of plutil)"
  # primary was not open: the helper's instance is reported and left running.
  scenario "$OLD_V" "$NEW_V" true 502:tag-a
  helper_hook install 2 1
  run_up "" update --yes
  assert_eq "$a_rc" "0" "exit (primary open)" &&
    assert_eq "$a_flagless" "0" "open calls for primary" &&
    assert_eq "$a_tag" "1" "open calls for tag-a" &&
    assert_contains "$a_out" "  primary · PID ${RELAUNCH_PID} (opened by the updater; not opened again)" &&
    assert_contains "$a_out" "reopened=2/2 exit=0" &&
    assert_eq "$a_plutil" "" "plutil calls (the state file is JSON)" &&
    assert_rc 0 &&
    assert_eq "$(opens_flagless)" "0" "open calls for primary (primary not open)" &&
    assert_contains "$out" "  primary · PID ${RELAUNCH_PID} was opened by the updater (primary was not open before); it is left running." &&
    assert_contains "$out" "reopened=1/1 exit=0"
  result "launchAfterInstallation true: primary is the helper's to reopen, never launched twice (and left running when it was not open); the JSON state file never goes through plutil" $?
}

case_state_not_json() {
  scenario "$OLD_V" "$NEW_V" true 501:primary 502:tag-a
  state_file true xml
  helper_hook install 2 1
  run_up "" update --yes
  assert_rc 0 &&
    assert_called plutil $'-convert\tjson\t-o\t-\t'"$(state_path)" &&
    assert_eq "$(opens_flagless)" "0" "open calls for primary" &&
    assert_contains "$out" "(opened by the updater; not opened again)"
  result "a state file that is not JSON is read through plutil -convert json | jq: launchAfterInstallation true is honoured" $?
}

case_lai_false_reopens_primary() {
  scenario "$OLD_V" "$NEW_V" false 501:primary
  helper_hook install
  run_up "" update --yes
  assert_rc 0 &&
    assert_eq "$(opens_flagless)" "1" "open calls for primary" &&
    assert_contains "$out" "  primary · PID 4301" &&
    assert_contains "$out" "reopened=1/1 exit=0"
  result "launchAfterInstallation false: the switcher reopens primary itself" $?
}

case_tag_not_reopened() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  multi_open_fake 4301
  helper_hook install
  run_up "" update --yes
  assert_rc 3 &&
    assert_contains "$out" "  tag-a: opened, but no new instance appeared within 15 s" &&
    assert_contains "$err" "Not every tag reopened: tag-a." &&
    assert_contains "$out" "result=updated reopened=1/2 exit=3"
  result "update: installed, but a tag does not reopen in time -> named, exit 3" $?
}

case_pids_changed_refuses() {
  # A new instance (tag-b, PID 503) appears after the list was printed: the
  # quit path would signal an instance the operator did not confirm.
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  {
    printf '%s\n' "$(< "$AS_FIXTURE_PS")"
    printf '%5s %s --user-data-dir=%s\n' 503 "${AS_APP_BUNDLE}/Contents/MacOS/Claude" "$(pdir tag-b)"
  } > "${AS_TEST_ROOT}/ps-next.txt"
  printf '503\n' >> "${AS_TEST_ROOT}/alive.txt"
  helper_hook install
  run_up "" update --yes
  assert_rc 2 &&
    assert_contains "$err" "The open instances changed since the list (PID 503 was not listed). Nothing was closed; run update again." &&
    assert_never_called osascript &&
    assert_never_called kill &&
    assert_no_lock &&
    assert_not_contains "$(history_text)" "QUIT_ALL"
  result "update compares get_claude_pids with the listed PIDs just before the quit: a new instance refuses, exit 2, nothing closed" $?
}

case_unlisted_during_quit() {
  # tag-b (PID 4500) is opened from the Dock while update's quit runs: the
  # graceful quit closes the two listed instances and leaves tag-b's in the
  # table. The quit must signal only the listed PIDs, so 4500 is named and
  # never signalled, and update stops before the install.
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  printf '%5s %s --user-data-dir=%s\n' 4500 "${AS_APP_BUNDLE}/Contents/MacOS/Claude" "$(pdir tag-b)" >> "$AS_FIXTURE_PS_AFTER_QUIT"
  helper_hook install
  run_up "" update --yes
  local k
  k="$(calls_of kill)"
  assert_rc 2 &&
    assert_called osascript 'tell application "Claude" to quit' &&
    assert_contains "$err" "A Claude instance that wasn't listed is running: tag-b · PID 4500. Stopping the quit; nothing more is signalled." &&
    assert_not_contains "$k" $'\t4500' &&
    assert_helper_untouched &&
    { [[ ! -e "${AS_TEST_ROOT}/hook-polls.txt" ]] || { printf '    update waited for the install\n'; false; }; } &&
    assert_not_contains "$out" "Waiting up to" &&
    assert_eq "$(opens_flagless)" "1" "open calls for primary (reopened)" &&
    assert_eq "$(opens_tag tag-a)" "1" "open calls for tag-a (reopened)" &&
    assert_eq "$(opens_tag tag-b)" "0" "open calls for tag-b" &&
    assert_contains "$out" "update before=${OLD_V} after=${OLD_V} result=unlisted reopened=2/2 exit=2" &&
    assert_contains "$(history_text)" "UPDATE result=unlisted before=${OLD_V} after=${OLD_V} reopened=2/2" &&
    assert_no_lock
  result "an instance that wasn't listed appears during update's quit -> named (tag-b · PID 4500), never signalled, no install wait, the listed tags reopened, result=unlisted, exit 2" $?
}

case_install_running_refuses() {
  scenario "$OLD_V" "$NEW_V" false 501:primary
  {
    printf '2026-10-31 11:30:00.100 ShipIt[117:218] Beginning installation\n'
    printf 'ERROR: Unrecognized attribute string flag after the last stamp\n'
    printf '    NSFilePath = "%s";\n' "$(staged_plist)"
  } >> "$(log_path)"
  run_up "" update --yes
  local busy_rc="$rc" busy_err="$err" busy_osa
  busy_osa="$(calls_of osascript)"
  # The same table (the helper process alive) with the log's last stamped
  # line an install request: update goes ahead.
  scenario "$OLD_V" "$NEW_V" false 501:primary
  helper_hook install
  run_up "" update --yes
  assert_eq "$busy_rc" "2" "exit while installing" &&
    assert_contains "$busy_err" "The updater is installing right now (its log's last line: 2026-10-31 11:30:00.100 ShipIt[117:218] Beginning installation)" &&
    assert_eq "$busy_osa" "" "osascript calls while installing" &&
    assert_rc 0
  result "an install is running when the log's last timestamped line is 'Beginning installation' (untimestamped lines after it skipped) -> refused, exit 2; a live helper process alone is not the test" $?
}

case_timeout_install_running() {
  # The helper begins installing on poll 2 and has not finished when the wait
  # ends: reopening now would start the app while its bundle is replaced.
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  helper_hook begin
  run_up "" update --yes
  assert_rc 1 &&
    assert_eq "$(n_calls sleep $'sleep\t1')" "10" "1 s waits (install_timeout_s = 10)" &&
    assert_contains "$out" "No 'Installation completed successfully' within 10 s, and the updater's log shows an install still running:" &&
    assert_contains "$out" "ShipIt[115:216] Beginning installation" &&
    assert_contains "$out" "Not reopening while the app is being replaced." &&
    assert_contains "$out" "  account-switcher launch primary"$'\n'"  account-switcher launch tag-a" &&
    assert_never_called open &&
    assert_contains "$out" "update before=${OLD_V} after=${OLD_V} result=timeout reopened=0/2 exit=1" &&
    assert_contains "$(history_text)" "UPDATE result=timeout before=${OLD_V} after=${OLD_V} reopened=0/2" &&
    assert_helper_untouched &&
    assert_no_lock
  result "the wait ends with the updater's log still showing an install running -> nothing reopened, a launch command per tag, result=timeout reopened=0/2, exit 1" $?
}

# An open fake that records the call and fails (exit 1), launching nothing.
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

case_reopen_open_fails() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  failing_open_fake
  helper_hook install
  run_up "" update --yes
  assert_rc 3 &&
    assert_eq "$(count_lines "$(calls_of open)")" "2" "open calls" &&
    assert_contains "$out" "  primary: could not be opened (open failed); run: account-switcher launch primary" &&
    assert_contains "$out" "  tag-a: could not be opened (open failed); run: account-switcher launch tag-a" &&
    assert_contains "$err" "Not every tag reopened: primary tag-a." &&
    assert_contains "$out" "update before=${OLD_V} after=${NEW_V} result=updated reopened=0/2 exit=3" &&
    assert_not_contains "$(history_text)" "LAUNCH tag=" &&
    assert_no_lock
  result "update's reopen when open fails -> each tag counted as not reopened (no LAUNCH row), the summary line, exit 3 (not an errexit stop)" $?
}

case_quit_failed() {
  # Neither instance quits: the graceful quit closes nothing and TERM and
  # KILL leave both alive.
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  unset AS_FAKE_QUIT
  AS_FAKE_KILL_EFFECTIVE=0
  export AS_FAKE_KILL_EFFECTIVE
  helper_hook install
  run_up "" update --yes
  unset AS_FAKE_KILL_EFFECTIVE
  assert_rc 1 &&
    assert_called kill $'-TERM\t501' &&
    assert_called kill $'-KILL\t502' &&
    assert_contains "$err" "Could not close every instance (see above), so the updater can't install. Reopening what was closed." &&
    { [[ ! -e "${AS_TEST_ROOT}/hook-polls.txt" ]] || { printf '    update waited for the install\n'; false; }; } &&
    assert_contains "$out" "  primary: already running; not opened again" &&
    assert_contains "$out" "  tag-a: already running; not opened again" &&
    assert_never_called open &&
    assert_contains "$out" "Installed version: ${OLD_V} before, ${OLD_V} after (nothing was installed)." &&
    assert_contains "$out" "update before=${OLD_V} after=${OLD_V} result=quit-failed reopened=2/2 exit=1" &&
    assert_contains "$(history_text)" "UPDATE result=quit-failed before=${OLD_V} after=${OLD_V} reopened=2/2" &&
    assert_helper_untouched &&
    assert_no_lock
  result "an instance that won't quit -> the quit-failed path: no install wait, the still-running tags are not opened again, result=quit-failed, exit 1" $?
}

# An osascript fake that, on the quit script, sends TERM to the switcher
# (switcher.pid) and then quits every app, as AS_FAKE_QUIT=graceful does.
# TERM, not INT: the switcher runs in the background here, and bash starts a
# background command with SIGINT ignored; INT and TERM share update's
# handler.
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
printf '%s' "$(< "$AS_FIXTURE_PS_AFTER_QUIT")" > "$AS_FIXTURE_PS"
exit 0
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/osascript" || harness_error "cannot chmod the osascript fake"
}

case_interrupt_during_quit() {
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  osascript_fake_interrupts
  helper_hook install
  local o="${AS_TEST_ROOT}/.run-out" e="${AS_TEST_ROOT}/.run-err" pid
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$SWITCHER" update --yes
  ) > "$o" 2> "$e" < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "${AS_TEST_ROOT}/switcher.pid"
  wait "$pid"
  rc=$?
  _read_run "$o" "$e"
  assert_rc 130 &&
    assert_contains "$err" "Interrupted." &&
    assert_contains "$err" "Claude was closed for the update. Once the updater's log no longer ends with 'Beginning installation', reopen each tag:" &&
    assert_contains "$err" "  account-switcher launch primary"$'\n'"  account-switcher launch tag-a" &&
    { [[ ! -e "${AS_TEST_ROOT}/hook-polls.txt" ]] || { printf '    update waited for the install\n'; false; }; } &&
    assert_never_called open &&
    assert_not_contains "$out" "update before=" &&
    assert_no_lock
  result "a stop signal (TERM) during update's quit -> update's handler: what was closed and how to reopen it, the lock released, exit 130" $?
}

case_listed_pid_gone_refuses() {
  # tag-a (PID 502) quits by itself after the list was printed: the open
  # instances no longer match what the operator confirmed.
  scenario "$OLD_V" "$NEW_V" false 501:primary 502:tag-a
  local row
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ "$row" == "  502 "* ]] || printf '%s\n' "$row"
  done < "$AS_FIXTURE_PS" > "${AS_TEST_ROOT}/ps-next.txt"
  helper_hook install
  run_up "" update --yes
  assert_rc 2 &&
    assert_contains "$err" "The open instances changed since the list (PID 502 is gone). Nothing was closed; run update again." &&
    assert_never_called osascript &&
    assert_never_called kill &&
    assert_no_lock &&
    assert_not_contains "$(history_text)" "QUIT_ALL"
  result "update's set check, the other direction: a listed PID gone before the quit refuses, exit 2, nothing closed" $?
}

case_log_line_controls() {
  # The helper log's last line carries a title-setting OSC sequence, a colour
  # sequence and a C1 CSI (UTF-8 C2 9B): update prints the line with every C0
  # and C1 control removed.
  scenario "$OLD_V" "$NEW_V" false 501:primary
  printf '2026-10-31 11:30:00.100 ShipIt[117:218] Beginning installation \033]0;spoofed\007\033[31mred\033[0m \302\233x\n' >> "$(log_path)"
  run_up "" update --yes
  local shown="${err#*last line: }"
  shown="${shown%%). Nothing was closed*}"
  assert_rc 2 &&
    assert_eq "$shown" "2026-10-31 11:30:00.100 ShipIt[117:218] Beginning installation ]0;spoofed[31mred[0m x" "the log line as printed" &&
    assert_not_contains "$shown" $'\033' &&
    assert_not_contains "$shown" $'\007' &&
    assert_not_contains "$shown" $'\302\233' &&
    assert_never_called osascript
  result "update prints the updater log's last line with C0 and C1 control characters removed (an OSC title, a colour sequence and a C1 CSI)" $?
}

case_bad_arguments() {
  local ok=0
  scenario "$OLD_V" "$NEW_V" false 501:primary
  run_up "" update --force
  [[ "$rc" == "2" && "$err" == *"Unknown argument for update: --force"* ]] || ok=1
  run_up "" update 'x;y'
  [[ "$rc" == "2" ]] || ok=1
  [[ -z "$(calls_of osascript)" ]] || ok=1
  assert_eq "$ok" "0" "refusals"
  result "update: an unknown flag or a metacharacter argument -> exit 2 (never 1, which means the version did not change)" $?
}

# ---- The lock ---------------------------------------------------------------------

case_lock_refuses() {
  scenario "$OLD_V" "$NEW_V" false
  make_lock 60
  local ok=0 owner_before
  owner_before="$(/usr/bin/shasum < "$(lock_path)/owner")"
  run_up "" launch tag-a
  [[ "$rc" == "1" && "$err" == *"An update is running (the lock ${LOCK_SHOWN} is"* && "$err" == *"Not launching"* \
     && "$err" != *"$(lock_path)"* ]] || { ok=1; printf '    launch rc=%s\n' "$rc"; }
  run_up "" swap tag-a --no-handoff
  [[ "$rc" == "1" && "$err" == *"Not swapping"* ]] || { ok=1; printf '    swap rc=%s\n' "$rc"; }
  run_up "" signin tag-a --yes
  [[ "$rc" == "2" && "$err" == *"An update is running"* && "$err" == *"Not signing in"* ]] || { ok=1; printf '    signin rc=%s\n' "$rc"; }
  run_up "" update --yes
  [[ "$rc" == "2" && "$err" == *"Not updating"* ]] || { ok=1; printf '    update rc=%s\n' "$rc"; }
  run_switcher list
  [[ "$out" == *"  update:    running (lock "* ]] || ok=1
  assert_eq "$ok" "0" "refusals" &&
    assert_never_called open &&
    assert_never_called osascript &&
    [[ -d "$(lock_path)" ]] &&
    assert_unchanged "$(lock_path)/owner" "$owner_before"
  result "while the lock exists, launch and swap refuse (exit 1), signin refuses through its refusal (exit 2), update refuses (exit 2); nothing opened or quit; list shows the update running" $?
}

case_stale_lock() {
  local ok=0 owner_before
  scenario "$OLD_V" "$NEW_V" false
  make_lock 3600
  owner_before="$(/usr/bin/shasum < "$(lock_path)/owner")"
  run_up "" launch tag-a
  [[ "$rc" == "1" && "$err" == *"is 1h 0m old (taken by PID 4242), past the 10-minute limit"* \
     && "$err" == *"The switcher never removes a lock it did not take."* && "$err" == *"remove it: trash ${LOCK_SHOWN}"* \
     && "$err" != *"$(lock_path)"* ]] || { ok=1; printf '    launch rc=%s\n' "$rc"; }
  run_switcher list
  [[ "$out" == *"  update:    stale lock (1h 0m old, taken by PID 4242): ${LOCK_SHOWN}"* \
     && "$out" == *"If no update is running, remove it: trash ${LOCK_SHOWN}"* && "$out" != *"$(lock_path)"* ]] || ok=1
  assert_unchanged "$(lock_path)/owner" "$owner_before" || ok=1
  # A lock with no owner line is of unknown age: reported the same way.
  scenario "$OLD_V" "$NEW_V" false
  make_lock none
  run_up "" swap tag-a --no-handoff
  [[ "$rc" == "1" && "$err" == *"is of unknown age (taken by PID unknown), past the 10-minute limit"* ]] || { ok=1; printf '    swap rc=%s\n' "$rc"; }
  assert_eq "$ok" "0" "stale cases" &&
    [[ -d "$(lock_path)" ]] &&
    assert_never_called open
  result "a lock older than 10 minutes (or of unknown age) is reported as stale with the trash remedy, still refuses, and is never removed" $?
}

case_install_check() {
  local ok=0
  scenario "$OLD_V" "$NEW_V" false 501:primary
  /bin/mkdir -p "${HOME}/.claude/commands" || harness_error "cannot create the commands folder"
  /bin/cp "$REPO/account-switcher.sh" "${AS_STORE}/account-switcher.sh"
  /bin/chmod 755 "${AS_STORE}/account-switcher.sh"
  /bin/cp "$REPO/commands/account-switcher.md" "${HOME}/.claude/commands/account-switcher.md"
  # list creates update-state.json.
  run_switcher list
  [[ -f "${AS_STORE}/update-state.json" ]] || ok=1
  run_install --check
  local list_rc="$rc" list_check="$out"
  # update creates .update.lock: the hook runs install.sh --check, and a
  # launch, while update holds it.
  helper_hook install
  printf 'CHECK=1\n' >> "${AS_TEST_ROOT}/hook.conf"
  run_up "" update --yes
  local up_rc="$rc"
  assert_eq "$ok" "0" "update-state.json after list" &&
    assert_eq "$list_rc" "0" "install.sh --check after list" &&
    assert_not_contains "$list_check" "leftover" &&
    assert_eq "$up_rc" "0" "update exit" &&
    assert_eq "$(< "${AS_TEST_ROOT}/lock-seen.txt")" "yes" "the lock existed during the check" &&
    assert_eq "$(< "${AS_TEST_ROOT}/check-rc.txt")" "0" "install.sh --check while update holds the lock" &&
    assert_not_contains "$(< "${AS_TEST_ROOT}/check-out.txt")" "leftover" &&
    assert_eq "$(< "${AS_TEST_ROOT}/launch-rc.txt")" "1" "launch while update holds the lock" &&
    assert_contains "$(< "${AS_TEST_ROOT}/launch-out.txt")" "An update is running" &&
    assert_no_lock
  result "install.sh --check exits 0 with update-state.json (from list) and with .update.lock held by a running update; a launch then refuses" $?
}

# ---- The launch and swap warning ---------------------------------------------------

record_state() {  # <first_seen_utc>
  printf '{"schema":1,"staged_version":"%s","installed_version":"%s","first_seen_utc":"%s","phase":"idle","run":null}\n' \
    "$NEW_V" "$OLD_V" "$1" > "${AS_STORE}/update-state.json"
}

ago_utc() { /bin/date -u -r $(( $(/bin/date +%s) - $1 )) +%Y-%m-%dT%H:%M:%SZ; }

case_wait_warning() {
  local ok=0 n
  scenario "$OLD_V" "$NEW_V" false
  record_state "$(ago_utc 108000)"
  run_up "" launch tag-a
  n="$(count_matching "$err" "to install (over 24 h)")"
  [[ "$rc" == "0" && "$n" == "1" && "$err" == *"Claude ${NEW_V} has waited 1d 6h to install (over 24 h); it installs only when every Claude instance is closed. To install it now: account-switcher update"* ]] || { ok=1; printf '    launch 30 h: rc=%s n=%s\n' "$rc" "$n"; }
  run_up "" swap tag-b --no-mirror --no-handoff
  [[ "$rc" == "0" && "$(count_matching "$err" "to install (over 24 h)")" == "1" ]] || { ok=1; printf '    swap 30 h: rc=%s\n' "$rc"; }
  # Under the threshold: no line.
  scenario "$OLD_V" "$NEW_V" false
  record_state "$(ago_utc 7200)"
  run_up "" launch tag-a
  [[ "$rc" == "0" && "$err" != *"to install (over"* ]] || ok=1
  # A higher threshold in config.toml.
  scenario "$OLD_V" "$NEW_V" false
  write_config "warn_after_hours = 48"
  record_state "$(ago_utc 108000)"
  run_up "" launch tag-a
  [[ "$rc" == "0" && "$err" != *"to install (over"* ]] || ok=1
  record_state "$(ago_utc 180000)"
  run_up "" launch tag-a
  [[ "$rc" == "0" && "$err" == *"has waited 2d 2h to install (over 48 h)"* ]] || { ok=1; printf '    launch 50 h at 48: rc=%s\n' "$rc"; }
  assert_eq "$ok" "0" "warning cases"
  result "launch and swap print one line naming update once the staged update has waited past [update] warn_after_hours (default 24, 48 when set), and none below it" $?
}

# ---- The unknown-tag guard ---------------------------------------------------------

case_unknown_tag_guard() {
  local ok=0
  scenario "$OLD_V" none false
  run_up "" launch tagb
  [[ "$rc" == "1" && "$err" == *"Tag 'tagb' is not in [accounts] and has no profile folder, so launch would create a new, empty profile. Configured tags: primary, tag-a, tag-b. Closest match: tag-b. If 'tagb' is a new tag on purpose: account-switcher launch tagb --new"* ]] || { ok=1; printf '    launch rc=%s\n' "$rc"; }
  [[ ! -d "$(pdir tagb)" ]] || ok=1
  [[ "$err" != *"Account check"* && "$(history_text)" != *"IDENTITY"* ]] || { ok=1; printf '    the identity check ran before the guard\n'; }
  run_up "" swap tag-c --no-mirror
  [[ "$rc" == "1" && "$err" == *"so swap would create a new, empty profile"* && "$err" == *"Closest match: tag-a."* && -z "$(calls_of osascript)" ]] || { ok=1; printf '    swap rc=%s\n' "$rc"; }
  [[ ! -f "${AS_STORE}/SWAP_HANDOFF.md" ]] || ok=1
  [[ -z "$(calls_of open)" ]] || ok=1
  # --new allows it; an existing unconfigured folder passes; primary always does.
  run_up "" launch tagb --new
  [[ "$rc" == "0" && "$(opens_tag tagb)" == "1" ]] || { ok=1; printf '    --new rc=%s\n' "$rc"; }
  /bin/mkdir -p "$(pdir tag-x)" || harness_error "cannot create the stray folder"
  run_up "" launch tag-x
  [[ "$rc" == "0" && "$(opens_tag tag-x)" == "1" ]] || { ok=1; printf '    existing folder rc=%s\n' "$rc"; }
  run_up "" swap tagd --new --no-mirror --no-handoff
  [[ "$rc" == "0" && "$(opens_tag tagd)" == "1" ]] || { ok=1; printf '    swap --new rc=%s\n' "$rc"; }
  # No config at all: no configured tags to offer.
  /bin/rm -f "${AS_STORE}/config.toml"
  run_up "" launch typo
  [[ "$rc" == "1" && "$err" == *"No tag is configured in [accounts]"* ]] || { ok=1; printf '    no config rc=%s\n' "$rc"; }
  run_up "" launch primary
  [[ "$rc" == "0" ]] || { ok=1; printf '    primary rc=%s\n' "$rc"; }
  assert_eq "$ok" "0" "guard cases"
  result "unknown-tag guard: launch and swap refuse a tag neither in [accounts] nor on disk, before the account check, naming the configured tags and the closest match; --new, an existing folder and primary pass" $?
}

# ---- Help, and the seam ------------------------------------------------------------

case_help() {
  new_case
  run_switcher help
  assert_rc 0 &&
    assert_contains "$out" "update [--yes]         Install the staged Claude app update." &&
    assert_contains "$out" "launch <tag> [--force] [--new]" &&
    assert_contains "$out" "--new             allow a tag that is not in" &&
    assert_contains "$out" "marked unconfigured (never deleted)"
  result "help describes update, --new and list's unconfigured and version rows" $?
}

case_seam_guarded() {
  local ok=0 fake var
  for fake in PlistBuddy plutil mkdir; do
    new_case
    render_fixture "${LIB_DIR}/fakes/passthrough.sh" "${AS_FAKES_DIR}/${fake}"
    /bin/chmod 755 "${AS_FAKES_DIR}/${fake}"
    run_switcher version
    case "$fake" in PlistBuddy) var=PLISTBUDDY ;; plutil) var=PLUTIL ;; *) var=MKDIR ;; esac
    [[ "$rc" == "78" && "$err" == *"AS_BIN_${var} is a passthrough fake but must be guarded-passthrough"* ]] || { ok=1; printf '    %s rc=%s\n' "$fake" "$rc"; }
    [[ -z "$(< "${AS_TEST_ROOT}/calls.log")" ]] || ok=1
  done
  assert_eq "$ok" "0" "interlock"
  result "seam: PlistBuddy, plutil and mkdir must be guarded pass-through fakes (a pass-through one -> 78, nothing run)" $?
}

case_reader_scope
case_list_rows
case_list_none
case_unknown_never_none
case_versions_as_strings
case_nothing_staged
case_no_terminal_refuses
case_confirm_at_terminal
case_completed
case_timeout
case_either_side_of_start
case_unchanged
case_lai_true
case_state_not_json
case_lai_false_reopens_primary
case_tag_not_reopened
case_pids_changed_refuses
case_listed_pid_gone_refuses
case_unlisted_during_quit
case_timeout_install_running
case_reopen_open_fails
case_quit_failed
case_interrupt_during_quit
case_install_running_refuses
case_log_line_controls
case_bad_arguments
case_lock_refuses
case_stale_lock
case_install_check
case_wait_warning
case_unknown_tag_guard
case_help
case_seam_guarded
finish
