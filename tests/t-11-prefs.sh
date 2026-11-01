#!/usr/bin/env bash
# tests/t-11-prefs.sh - #11: key-level settings sync between profiles.
#
# Three profiles (primary, tag-a, tag-b; tag-a and tag-b in [accounts]),
# each with a claude_desktop_config.json holding every key class: the 8
# allowlisted (G) keys, capability and security keys, account-keyed entries
# (flat names ending in an account id, and maps keyed by account/org), a
# session-keyed grant, paths, and an unclassified (U) key. Every id, session
# key and path is generated when the case runs, so this file holds none. The
# "only allowlisted keys change" check is #11's: jq -S with delpaths of the 8
# paths on both files, before and after, for every writing command. After
# every case the case's whole output (prefs verbs), the settings lines of
# swap and clone-prefs, every PREFS_* history row and the sync state are
# scanned for a uuid, a session id and an absolute path; the scan has a
# control arm.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

JQ=/usr/bin/jq
G_MAP='{"sidebar-mode":["preferences","sidebarMode"],
  "keep-awake":["preferences","keepAwakeEnabled"],
  "preferred-browser":["preferences","coworkPreferredBrowser"],
  "new-session-worktree":["preferences","epitaxyPrefs","cc-landing-worktree-enabled"],
  "transcript-links-in-preview":["preferences","epitaxyPrefs","epitaxy-transcript-links-in-preview"],
  "preferred-editor":["preferences","epitaxyPrefs","claude-code-preferred-editor"],
  "projects-library-layout":["preferences","epitaxyPrefs","projects.library.layout"],
  "projects-library-small-icons":["preferences","epitaxyPrefs","projects.library.smallIcons"]}'
G_PATHS="$($JQ -c '[.[]]' <<< "$G_MAP")"
G_ALL='{"sidebar-mode":"wide","keep-awake":true,"preferred-browser":"chrome","new-session-worktree":true,
  "transcript-links-in-preview":true,"preferred-editor":"code","projects-library-layout":"grid",
  "projects-library-small-icons":false}'
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
SESS_RE='session_[A-Za-z0-9]'

rand_hex() { /usr/bin/od -An -N"$1" -tx1 /dev/urandom | /usr/bin/tr -d ' \n'; }
rand_uuid() {
  local h
  h="$(rand_hex 16)"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

pdir() {
  if [[ "$1" == "primary" ]]; then printf '%s' "${AS_PROFILE_ROOT}/Claude"; else printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"; fi
}
pfile() { printf '%s/claude_desktop_config.json' "$(pdir "$1")"; }

# write_prof <tag> <g-json>: the profile's settings file, with fresh ids, a
# session key and paths under the case's HOME, and the allowlisted values in
# <g-json> ({key-id: value}; an id left out is absent).
write_prof() {
  local tag="$1" a1 a2 o1 p1 l1 s1
  a1="$(rand_uuid)"; a2="$(rand_uuid)"; o1="$(rand_uuid)"; p1="$(rand_uuid)"; l1="$(rand_uuid)"
  s1="session_$(rand_hex 12)"
  $JQ -n --arg home "$HOME" --arg tag "$tag" --arg a1 "$a1" --arg a2 "$a2" --arg o1 "$o1" \
    --arg p1 "$p1" --arg l1 "$l1" --arg s1 "$s1" --argjson g "$2" --argjson map "$G_MAP" '
    {coworkUserFilesPath: "\($home)/files-\($tag)",
     preferences: {
       chromeExtensionEnabled: true,
       coworkWebSearchEnabled: ($tag == "primary"),
       bypassPermissionsModeEnabled: ($tag == "tag-b"),
       localAgentModeTrustedFolders: ["\($home)/work-\($tag)", "\($home)/src"],
       bypassPermissionsGateByAccount: {($a1): true},
       coworkModelAutoFallbackByAccount: {($a1): "auto", ($a2): "off"},
       remoteSessionFolderGrants: {($s1): ["\($home)/grant-\($tag)"]},
       remoteToolsDeviceName: "device-\($tag)",
       chromeExtension: {pairedDevice: $l1},
       earlyWindowShowLatched: ($tag != "primary"),
       epitaxyPrefs: {
         ("autoResumeRateLimit." + $a1): true,
         ("code-sessions-show-empty-projects." + $a2): false,
         ("cc-landing-draft-permission-mode." + $a1): "plan",
         "cc-landing-draft-permission-mode": (if $tag == "primary" then "default" else "acceptEdits" end),
         "dframe-code-sections": {"\($a1)/\($o1)": {open: true}},
         ("projects." + $p1 + ".overviewPaneOpen"): true,
         "starred-local-code-sessions": ["local_\($l1)"],
         "desktop-frame.paneStore.v1": {lastPath: "\($home)/pane-\($tag)"}}}}
    | reduce ($g | to_entries[]) as $e (.; setpath($map[$e.key]; $e.value))' > "$(pfile "$tag")" \
    || harness_error "cannot write a fixture profile"
  /bin/chmod 600 "$(pfile "$tag")"
}

# setg <tag> <key-id> <json|absent>: changes one key in place, as the app would.
setg() {
  local f tmp
  f="$(pfile "$1")"
  tmp="${AS_TEST_ROOT}/.setg"
  if [[ "$3" == "absent" ]]; then
    $JQ --argjson p "$($JQ -c --arg k "$2" '.[$k]' <<< "$G_MAP")" 'delpaths([$p])' "$f" > "$tmp"
  else
    $JQ --argjson p "$($JQ -c --arg k "$2" '.[$k]' <<< "$G_MAP")" --argjson v "$3" 'setpath($p; $v)' "$f" > "$tmp"
  fi
  /bin/cat "$tmp" > "$f"
}

# gv <tag> <key-id>: the value (JSON), or absent.
gv() {
  $JQ -c --argjson p "$($JQ -c --arg k "$2" '.[$k]' <<< "$G_MAP")" \
    'if (try getpath($p) catch null) == null then "absent" else getpath($p) end' "$(pfile "$1")" | /usr/bin/tr -d '"'
}

# strip <tag>: the profile's file with the 8 allowlisted paths removed (#11's check).
strip() { $JQ -S --argjson p "$G_PATHS" 'delpaths($p)' "$(pfile "$1")"; }

# A case: three profiles with every class, tag-a and tag-b in [accounts], the
# given process table (default: no Claude running).
scene() {
  new_case
  /bin/mkdir -p "$(pdir primary)" "$(pdir tag-a)" "$(pdir tag-b)" "$AS_STORE"
  printf '[accounts]\ntag-a = { label = "Alpha", profile_email = "" }\ntag-b = { label = "Beta", profile_email = "" }\n' \
    > "${AS_STORE}/config.toml"
  set_ps_fixture "${1:-ps-no-claude.txt}" "${2:-}"
  : > "${AS_TEST_ROOT}/transcript.txt"
  unset AS_TEST_STDIN_IS_TTY
  write_prof primary "$G_ALL"
  write_prof tag-a "$G_ALL"
  write_prof tag-b "$G_ALL"
}

# Keeps the last run's output for the identifier scan. swap and clone-prefs
# print a few lines slices 1-7 already printed with an absolute path (the
# user-data-dir, source and target, a snapshot restore); those lines are left
# out, and every other line is scanned.
keep() {
  local l
  while IFS= read -r l; do
    case "$l" in
      *"user-data-dir: "*|*"  source: "*|*"  target: "*|*"from clone-prefs snapshot"*) ;;
      *) printf '%s\n' "$l" ;;
    esac
  done <<< "${out}"$'\n'"${err}" >> "${AS_TEST_ROOT}/transcript.txt"
}

run_p() { run_switcher "$@"; keep; }

# run_in <stdin> <arg> ...: runs the switcher with stdin from the string.
run_in() {
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
  keep
}

tty_on() { AS_TEST_STDIN_IS_TTY=1; export AS_TEST_STDIN_IS_TTY; }

log_text() { if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi; }
rows_of() { local l; while IFS= read -r l; do [[ "$l" == *" $1 "* ]] && printf '%s\n' "$l"; done <<< "$(log_text)"; }
state() { $JQ -c "$1" "${AS_STORE}/prefs-sync.json"; }

# leaks <file> ...: prints each line holding a uuid, a session id, the
# scratch root or the invoking user's home.
leaks() {
  local f l
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r l || [[ -n "$l" ]]; do
      if [[ "$l" =~ $UUID_RE || "$l" =~ $SESS_RE || "$l" == *"$AS_TEST_ROOT"* \
            || ( -n "$TEST_REAL_HOME" && "$l" == *"$TEST_REAL_HOME/"* ) ]]; then
        printf '    %s: %s\n' "${f##*/}" "$l"
      fi
    done < "$f"
  done
}

# The scan run after every case: the kept output, the PREFS_* rows and the
# sync state.
assert_no_ids() {
  local found
  rows_of PREFS_SYNC > "${AS_TEST_ROOT}/.rows"
  { rows_of PREFS_PIN; rows_of PREFS_UNDO; } >> "${AS_TEST_ROOT}/.rows"
  found="$(leaks "${AS_TEST_ROOT}/transcript.txt" "${AS_TEST_ROOT}/.rows" "${AS_STORE}/prefs-sync.json")"
  [[ -z "$found" ]] && return 0
  printf '    identifier in output:\n%s\n' "$found"
  return 1
}

# Every allowlisted path removed, the three profiles are as they were.
strip_all() { strip primary; strip tag-a; strip tag-b; }
assert_strip_same() {
  [[ "$(strip_all)" == "$1" ]] && return 0
  printf '    a key outside the allowlist changed (%s)\n' "${2:-}"
  return 1
}

# One digest over every profile file, every prior copy, the state and the log.
all_digest() {
  local t
  for t in primary tag-a tag-b; do
    /usr/bin/shasum "$(pfile "$t")" 2> /dev/null
    /usr/bin/shasum "$(pfile "$t").sync-prev" 2> /dev/null
  done
  /usr/bin/shasum "${AS_STORE}/prefs-sync.json" "${AS_STORE}/swap-history.log" 2> /dev/null
  /bin/ls -a "$AS_STORE" "$(pdir primary)" "$(pdir tag-a)" "$(pdir tag-b)"
}

# A first sync, with every profile agreeing and nothing running: every key
# initializes. Then the given process table.
seeded() {
  scene
  run_p prefs sync
  [[ "$rc" == "0" ]] || harness_error "the seeding sync exited ${rc}"
  set_ps_fixture "${1:-ps-no-claude.txt}" "${2:-}"
  : > "${AS_STORE}/swap-history.log"
  : > "${AS_TEST_ROOT}/calls.log"
}

# A lock as the switcher writes it (mkdir + an owner line), $1 seconds old.
make_lock() {
  local now
  now="$(/bin/date +%s)"
  /bin/mkdir -p "${AS_STORE}/.prefs-sync.lock" || harness_error "cannot create the lock"
  printf 'pid=4242 started_epoch=%s started_utc=2026-10-31T10:00:00Z\n' "$((now - $1))" \
    > "${AS_STORE}/.prefs-sync.lock/owner"
}

# ---- The control arm of the identifier scan ---------------------------------

case_scan_control() {
  new_case
  local f="${AS_TEST_ROOT}/planted.txt" n
  { printf 'ok line\n'; printf 'id %s\n' "$(rand_uuid)"; printf 'grant session_%s\n' "$(rand_hex 6)"
    printf 'path %s/x\n' "$HOME"; printf 'tilde ~/.claude/x\n'; } > "$f"
  n="$(count_lines "$(leaks "$f")")"
  assert_eq "$n" "3" "planted identifiers found (a uuid, a session id, a path; not the ~ form)"
  result "scan control: a planted uuid, session id and absolute path are each caught; a ~ path and a plain line are not" $?
}

# ---- #11 acceptance criteria -------------------------------------------------

case_only_allowlisted() {
  local ok=0 before
  seeded
  # prefs sync: a change in tag-a spreads.
  before="$(strip_all)"
  setg tag-a transcript-links-in-preview false
  run_p prefs sync
  [[ "$rc" == "0" && "$(gv primary transcript-links-in-preview)" == "false" ]] || { ok=1; printf '    sync rc=%s\n' "$rc"; }
  assert_strip_same "$before" "prefs sync" || ok=1
  # swap tag-b (through clone-prefs) and swap primary.
  setg tag-a keep-awake false
  export AS_FAKE_QUIT=graceful
  run_p swap tag-b --no-handoff
  [[ "$rc" == "0" && "$(gv tag-b keep-awake)" == "false" && "$(gv primary keep-awake)" == "true" ]] || { ok=1; printf '    swap tag-b rc=%s\n' "$rc"; }
  assert_strip_same "$before" "swap tag-b" || ok=1
  run_p swap primary --no-handoff
  [[ "$rc" == "0" && "$(gv primary keep-awake)" == "false" ]] || { ok=1; printf '    swap primary rc=%s\n' "$rc"; }
  assert_strip_same "$before" "swap primary" || ok=1
  # clone-prefs.
  setg tag-b preferred-browser '"safari"'
  run_p clone-prefs primary tag-a
  [[ "$rc" == "0" && "$(gv tag-a preferred-browser)" == "safari" ]] || { ok=1; printf '    clone-prefs rc=%s\n' "$rc"; }
  assert_strip_same "$before" "clone-prefs" || ok=1
  # adopt.
  setg tag-b preferred-editor '"vim"'
  run_p prefs adopt preferred-editor --from tag-b
  [[ "$rc" == "0" && "$(gv primary preferred-editor)" == "vim" && "$(gv tag-a preferred-editor)" == "vim" ]] || { ok=1; printf '    adopt rc=%s\n' "$rc"; }
  assert_strip_same "$before" "adopt" || ok=1
  # undo (key by key) of the last write to primary.
  run_p prefs undo primary
  [[ "$rc" == "0" && "$(gv primary preferred-editor)" == "code" ]] || { ok=1; printf '    undo rc=%s\n' "$rc"; }
  assert_strip_same "$before" "undo" || ok=1
  # review: a conflict, settled with tag-b's value.
  seeded
  before="$(strip_all)"
  setg tag-a sidebar-mode '"narrow"'
  setg tag-b sidebar-mode '"auto"'
  tty_on
  run_in $'2\ntag-b\ny\n' prefs review
  [[ "$rc" == "0" && "$(gv primary sidebar-mode)" == "auto" && "$(gv tag-a sidebar-mode)" == "auto" ]] || { ok=1; printf '    review rc=%s\n' "$rc"; }
  assert_strip_same "$before" "review" || ok=1
  assert_eq "$ok" "0" "every writing command" && assert_no_ids
  result "only allowlisted keys change: sync, swap (tag and primary), clone-prefs, adopt, undo and review leave each profile identical once the 8 paths are removed (jq -S, delpaths)" $?
}

case_dotted_literal() {
  scene
  setg primary projects-library-layout absent
  setg tag-b projects-library-layout absent
  setg tag-a projects-library-layout '"list"'
  run_p prefs adopt projects-library-layout --from tag-a
  assert_rc 0 &&
    assert_eq "$($JQ -r '.preferences.epitaxyPrefs["projects.library.layout"]' "$(pfile primary)")" "list" "primary's literal key" &&
    assert_eq "$($JQ -r '.preferences.epitaxyPrefs["projects.library.layout"]' "$(pfile tag-b)")" "list" "tag-b's literal key" &&
    assert_eq "$($JQ -r '.preferences.epitaxyPrefs | has("projects")' "$(pfile primary)")" "false" "a nested projects object in primary" &&
    assert_eq "$($JQ -r '.preferences | has("projects")' "$(pfile primary)")" "false" "a nested projects object under preferences" &&
    assert_no_ids
  result "dotted names are literal: projects.library.layout is read from tag-a and written at that one key; no nested projects object appears" $?
}

case_latest_wins() {
  seeded
  setg tag-a transcript-links-in-preview false
  run_p prefs sync
  local row
  row="$(rows_of PREFS_SYNC)"
  assert_rc 0 &&
    assert_eq "$(gv primary transcript-links-in-preview)" "false" "primary" &&
    assert_eq "$(gv tag-b transcript-links-in-preview)" "false" "tag-b" &&
    assert_contains "$row" "keys=transcript-links-in-preview " &&
    assert_contains "$row" "from=transcript-links-in-preview:tag-a" &&
    assert_contains "$err" "settings: 2 applied to every profile (transcript-links-in-preview from tag-a)" &&
    assert_eq "$(state '.keys["transcript-links-in-preview"].fleet')" "false" "fleet value" &&
    assert_no_ids
  result "latest change wins: a change in tag-a reaches every other profile, primary included; the row names the key and the source tag" $?
}

case_behind_not_changed() {
  seeded
  setg tag-a keep-awake false
  # Only tag-a is named: the change becomes the fleet value, nothing is written.
  run_p prefs sync tag-a
  local first_rc="$rc" p1 b1
  p1="$(gv primary keep-awake)"; b1="$(gv tag-b keep-awake)"
  run_p prefs sync
  assert_eq "$first_rc" "0" "sync tag-a exit" &&
    assert_eq "$p1|$b1" "true|true" "primary and tag-b after sync tag-a" &&
    assert_rc 0 &&
    assert_eq "$(gv primary keep-awake)|$(gv tag-b keep-awake)" "false|false" "after the full sync" &&
    assert_eq "$(state '.keys["keep-awake"].fleet')" "false" "fleet value (tag-b's old true never spread)" &&
    assert_no_ids
  result "behind doesn't count as changed: profiles left behind receive the fleet value, and their old value never spreads" $?
}

case_unclear_order() {
  local ok=0
  # With no sync state: primary differs on one key, tag-a alone holds another.
  scene
  setg primary transcript-links-in-preview false
  setg primary projects-library-layout absent
  setg tag-b projects-library-layout absent
  export AS_FAKE_QUIT=graceful
  run_p swap primary --no-handoff
  [[ "$rc" == "0" && "$(gv primary projects-library-layout)" == "absent" && "$(gv primary transcript-links-in-preview)" == "false" ]] || ok=1
  [[ "$err" == *"2 needs review: run 'account-switcher prefs review'"* ]] || { ok=1; printf '    first swap: no review count\n'; }
  [[ "$(state '.keys["sidebar-mode"].fleet')" == '"wide"' ]] || { ok=1; printf '    an agreeing key did not initialize\n'; }
  run_p prefs diff
  [[ "$out" == *"transcript-links-in-preview: needs review (proposed: primary's false)"* ]] || { ok=1; printf '    no proposal from primary\n'; }
  [[ "$out" == *"projects-library-layout: needs review (no default: primary has no value)"* ]] || { ok=1; printf '    no "no default"\n'; }
  # With history: two profiles change one key to different values.
  seeded
  setg tag-a sidebar-mode '"narrow"'
  setg tag-b sidebar-mode '"auto"'
  run_p swap primary --no-handoff
  [[ "$(gv primary sidebar-mode)" == "wide" && "$err" == *"1 needs review"* ]] || { ok=1; printf '    swap wrote a conflicting key\n'; }
  run_p prefs sync
  [[ "$rc" == "1" && "$(gv primary sidebar-mode)" == "wide" ]] || { ok=1; printf '    sync rc=%s\n' "$rc"; }
  tty_on
  run_in $'4\n' prefs review
  [[ "$rc" == "1" && "$out" == *'tag-a="narrow" (changed)'* && "$out" == *'tag-b="auto" (changed)'* ]] || { ok=1; printf '    review rc=%s\n' "$rc"; }
  assert_eq "$ok" "0" "review cases" && assert_no_ids
  result "unclear order goes to review: a key that differs with no history (primary's value proposed), one held by one profile only (no default), and two different changes are never written; review shows both values with their tags" $?
}

case_pins() {
  local ok=0
  seeded
  run_p prefs pin tag-a keep-awake
  [[ "$rc" == "0" ]] || ok=1
  setg tag-a keep-awake false
  run_p prefs sync
  [[ "$(gv primary keep-awake)|$(gv tag-b keep-awake)|$(gv tag-a keep-awake)" == "true|true|false" ]] || { ok=1; printf '    a pinned change spread\n'; }
  [[ "$err" == *"1 kept (pinned)"* ]] || { ok=1; printf '    not reported kept\n'; }
  setg primary keep-awake false
  setg primary keep-awake true
  setg tag-b keep-awake false
  run_p prefs sync
  [[ "$(gv primary keep-awake)|$(gv tag-a keep-awake)" == "false|false" ]] || { ok=1; printf '    keep-awake after a tag-b change\n'; }
  setg tag-b keep-awake true
  run_p prefs sync
  [[ "$(gv tag-a keep-awake)" == "false" ]] || { ok=1; printf '    the pinned tag-a was written\n'; }
  run_p prefs diff
  [[ "$out" == *"tag-a=false (pinned)"* ]] || { ok=1; printf '    diff does not show the pin\n'; }
  run_p prefs unpin tag-a keep-awake
  run_p prefs sync
  [[ "$(gv tag-a keep-awake)" == "true" ]] || { ok=1; printf '    unpin did not reverse it\n'; }
  run_p prefs pin tag-b --all
  setg primary sidebar-mode '"narrow"'
  setg tag-b preferred-browser '"safari"'
  run_p prefs sync
  [[ "$(gv tag-a sidebar-mode)|$(gv tag-b sidebar-mode)|$(gv tag-a preferred-browser)" == "narrow|wide|chrome" ]] || { ok=1; printf '    --all did not leave tag-b out\n'; }
  assert_eq "$ok" "0" "pin cases" &&
    assert_eq "$(count_lines "$(rows_of PREFS_PIN)")" "3" "PREFS_PIN rows" &&
    assert_no_ids
  result "pins hold: a pinned key is never written and its change doesn't spread; diff shows it; unpin reverses it; pin --all leaves the whole profile out" $?
}

case_running_tag() {
  local ok=0 a_before
  seeded ps-one-tag.txt
  a_before="$(/usr/bin/shasum < "$(pfile tag-a)")"
  setg primary keep-awake false
  setg primary keep-awake true
  setg tag-b keep-awake false
  run_p prefs sync
  [[ "$rc" == "1" && "$err" == *"Skipped 'tag-a': it is running"* && "$(gv primary keep-awake)" == "false" ]] || { ok=1; printf '    sync rc=%s\n' "$rc"; }
  assert_unchanged "$(pfile tag-a)" "$a_before" || ok=1
  setg tag-b preferred-browser '"safari"'
  run_p prefs adopt preferred-browser --from tag-b
  [[ "$rc" == "1" && "$err" == *"Skipped 'tag-a': it is running"* ]] || { ok=1; printf '    adopt rc=%s\n' "$rc"; }
  run_p prefs undo tag-a
  [[ "$rc" == "2" && "$err" == *"'tag-a' is running"* ]] || { ok=1; printf '    undo rc=%s\n' "$rc"; }
  run_p clone-prefs primary tag-a
  [[ "$rc" == "1" && "$err" == *"is currently running"* ]] || { ok=1; printf '    clone-prefs rc=%s\n' "$rc"; }
  assert_unchanged "$(pfile tag-a)" "$a_before" || ok=1
  # Primary without --user-data-dir is primary running.
  seeded ps-primary-only.txt
  setg tag-a keep-awake false
  run_p prefs sync
  [[ "$err" == *"Skipped 'primary': it is running"* && "$(gv primary keep-awake)|$(gv tag-b keep-awake)" == "true|false" ]] || { ok=1; printf '    primary (no flag) was written\n'; }
  assert_eq "$ok" "0" "running cases" && assert_no_ids
  result "running profiles are never written: a stub with --user-data-dir=<Claude-tag-a> is skipped by sync and adopt (said so) and refused by undo and clone-prefs, while primary's folder Claude is not taken for it; a main process with no flag is primary running" $?
}

case_running_refusals() {
  local ok=0 before t
  # Two main processes without --user-data-dir, each resolved by the folder
  # it holds open (primary, tag-a), so neither reads unknown and tag-b is not
  # running: every command but swap writes nothing and says why.
  seeded
  printf '  PID ARGS\n  501 %s/Contents/MacOS/Claude\n  504 %s/Contents/MacOS/Claude\n' \
    "$AS_APP_BUNDLE" "$AS_APP_BUNDLE" > "$AS_FIXTURE_PS"
  set_lsof_fixture 501 primary.txt
  set_lsof_fixture 504 tag-a.txt
  setg tag-a keep-awake false
  before="$(all_digest)"
  for t in "prefs sync" "prefs sync tag-b" "prefs adopt keep-awake --from tag-a" "prefs undo tag-b" "clone-prefs primary tag-b"; do
    # Word splitting is the point here.
    # shellcheck disable=SC2086
    run_p $t
    [[ "$rc" != "0" && "$err" == *"Claude instances are running without --user-data-dir"* ]] || { ok=1; printf '    %s: rc=%s\n' "$t" "$rc"; }
  done
  tty_on
  run_in $'4\n' prefs review
  [[ "$rc" == "2" && "$err" == *"running without --user-data-dir"* ]] || { ok=1; printf '    review rc=%s\n' "$rc"; }
  unset AS_TEST_STDIN_IS_TTY
  [[ "$(all_digest)" == "$before" ]] || { ok=1; printf '    a file changed\n'; }
  # A row that reads unknown, and a table that can't be read.
  seeded ps-unresolved.txt
  run_p prefs sync
  [[ "$rc" == "2" && "$err" == *"profile is unknown"* ]] || { ok=1; printf '    unknown rc=%s\n' "$rc"; }
  printf '#!/bin/bash\n# as-fake: recording\nexit 1\n' > "${AS_FAKES_DIR}/ps"
  run_p prefs sync
  [[ "$rc" == "2" && "$err" == *"process table could not be read"* ]] || { ok=1; printf '    unreadable rc=%s\n' "$rc"; }
  # swap is exempt: it quits first, then writes its target.
  seeded ps-two-flagless.txt ps-no-claude.txt
  set_lsof_fixture 501 primary.txt
  set_lsof_fixture 504 tag-a.txt
  setg tag-a keep-awake false
  export AS_FAKE_QUIT=graceful
  run_p swap tag-b --no-handoff
  [[ "$rc" == "0" && "$(gv tag-b keep-awake)" == "false" ]] || { ok=1; printf '    swap rc=%s\n' "$rc"; }
  assert_eq "$ok" "0" "refusals" && assert_no_ids
  result "running checks: with two main processes without --user-data-dir, a row that reads unknown, or an unreadable table, sync, adopt, undo, review and clone-prefs write nothing and say why; swap, which quits first, still writes its target" $?
}

case_swap_and_launch() {
  local ok=0 qn mn on n l before
  seeded ps-one-tag.txt ps-no-claude.txt
  setg tag-a keep-awake false
  export AS_FAKE_QUIT=graceful
  run_p swap tag-b --no-handoff
  # calls.log order: the quit, then the settings write into tag-b, then the launch.
  qn=0; mn=0; on=0; n=0
  while IFS= read -r l; do
    n=$((n + 1))
    case "$l" in
      osascript*"to quit"*) [[ $qn -gt 0 ]] || qn=$n ;;
      mv*"Claude-tag-b/claude_desktop_config.json") [[ $mn -gt 0 ]] || mn=$n ;;
      open*) [[ $on -gt 0 ]] || on=$n ;;
    esac
  done < "${AS_TEST_ROOT}/calls.log"
  [[ $qn -gt 0 && $mn -gt $qn && $on -gt $mn ]] || { ok=1; printf '    order: quit %s, settings %s, open %s\n' "$qn" "$mn" "$on"; }
  [[ "$(gv tag-b keep-awake)|$(gv primary keep-awake)" == "false|true" ]] || { ok=1; printf '    swap wrote more than its target\n'; }
  [[ "$(count_lines "$(rows_of PREFS_SYNC)")" == "1" && "$(rows_of PREFS_SYNC)" == *"cmd=swap target=tag-b"* ]] || { ok=1; printf '    PREFS_SYNC row\n'; }
  # The target may be primary.
  set_ps_fixture ps-no-claude.txt
  run_p swap primary --no-handoff
  [[ "$(gv primary keep-awake)" == "false" ]] || { ok=1; printf '    swap primary did not write primary\n'; }
  # --no-mirror skips the step.
  setg tag-b sidebar-mode '"narrow"'
  run_p swap primary --no-handoff --no-mirror
  [[ "$(gv primary sidebar-mode)" == "wide" && "$err" != *"settings:"* ]] || { ok=1; printf '    --no-mirror ran the step\n'; }
  # launch: the state, every prior copy and the log's settings rows are untouched.
  before="$(/usr/bin/shasum "${AS_STORE}/prefs-sync.json" "$(pfile primary).sync-prev" "$(pfile tag-b).sync-prev" "$(pfile primary)")"
  n="$(count_lines "$(rows_of PREFS_SYNC)")"
  run_p launch tag-a
  [[ "$rc" == "0" ]] || { ok=1; printf '    launch rc=%s\n' "$rc"; }
  [[ "$(/usr/bin/shasum "${AS_STORE}/prefs-sync.json" "$(pfile primary).sync-prev" "$(pfile tag-b).sync-prev" "$(pfile primary)")" == "$before" ]] || { ok=1; printf '    launch changed the state or a prior copy\n'; }
  [[ "$(count_lines "$(rows_of PREFS_SYNC)")" == "$n" && "$(rows_of LAUNCH)" == *"tag=tag-a"* ]] || { ok=1; printf '    launch added a settings row\n'; }
  assert_eq "$ok" "0" "swap and launch" && assert_no_ids
  result "swap and launch: swap quits, then writes only its target (primary too), then launches (read from the recording fakes); --no-mirror skips it; launch leaves the sync state, every prior copy and the settings rows unchanged" $?
}

case_clone_prefs() {
  local ok=0 before
  seeded
  local src dst
  src="$(pdir tag-a)"; dst="$(pdir tag-b)"
  /bin/mkdir -p "${src}/Claude Extensions/ext-one" "${src}/Claude Extensions Settings"
  printf 'x\n' > "${src}/Claude Extensions/ext-one/manifest.json"
  printf '{"on":true}\n' > "${src}/Claude Extensions Settings/ext-one.json"
  printf '{"worktrees":{"a":{"p":1}},"schemaVersion":1}\n' > "${src}/git-worktrees.json"
  printf '{"worktrees":{"b":{"p":2}},"schemaVersion":1}\n' > "${dst}/git-worktrees.json"
  before="$(strip_all)"
  setg primary keep-awake false
  run_p clone-prefs tag-a tag-b
  [[ "$rc" == "0" ]] || { ok=1; printf '    rc=%s\n' "$rc"; }
  [[ "$(gv tag-b keep-awake)" == "false" ]] || { ok=1; printf '    the key-level step did not write tag-b\n'; }
  assert_strip_same "$before" "clone-prefs" || ok=1
  [[ "$(strip tag-b)" != "$(strip tag-a)" ]] || { ok=1; printf '    tag-a'"'"'s whole file was copied\n'; }
  [[ -f "${dst}/Claude Extensions/ext-one/manifest.json" && -f "${dst}/Claude Extensions Settings/ext-one.json" ]] || { ok=1; printf '    extensions not copied\n'; }
  [[ "$($JQ -c '.worktrees | keys' "${dst}/git-worktrees.json")" == '["a","b"]' ]] || { ok=1; printf '    git-worktrees.json not merged\n'; }
  [[ "$err" == *"Cloned 3 item(s) from 'tag-a' to 'tag-b'"* ]] || { ok=1; printf '    item count\n'; }
  [[ "$(rows_of PREFS_SYNC)" == *"cmd=clone-prefs target=tag-b"* && "$(rows_of CLONE_PREFS)" == *"mirrored=Claude Extensions/,Claude Extensions Settings/,git-worktrees.json"* ]] || { ok=1; printf '    rows\n'; }
  assert_eq "$ok" "0" "clone-prefs" && assert_no_ids
  result "clone-prefs no longer copies the whole file: its settings step is the key-level sync for the target, and Claude Extensions/, Claude Extensions Settings/ and the git-worktrees.json merge are unchanged" $?
}

case_read_only() {
  local before ok=0
  seeded
  setg tag-a keep-awake false
  setg tag-b sidebar-mode '"narrow"'
  setg tag-a sidebar-mode '"auto"'
  printf '%s\n' "[2026-10-31T00:00:00Z] LAUNCH tag=x" > "${AS_STORE}/swap-history.log"
  before="$(all_digest)"
  : > "${AS_TEST_ROOT}/calls.log"
  run_p prefs diff
  [[ "$rc" == "1" ]] || { ok=1; printf '    diff rc=%s\n' "$rc"; }
  run_p prefs diff --all
  run_p prefs sync --dry-run
  [[ "$rc" == "1" && "$err" == *"settings (dry run): 2 would apply to every profile"* ]] || { ok=1; printf '    dry-run rc=%s\n' "$rc"; }
  run_p prefs sync tag-b --dry-run
  assert_eq "$ok" "0" "read-only runs" &&
    assert_eq "$(all_digest)" "$before" "every profile file, prior copy, the state, the log and the folders" &&
    assert_never_called mktemp && assert_never_called mv && assert_never_called mkdir &&
    assert_no_ids
  result "read-only means read-only: prefs diff [--all] and prefs sync [--dry-run] leave every profile file, prior copy, the sync state and the history log byte-identical" $?
}

case_diff_output() {
  local ok=0 d1 rc1
  scene
  setg primary new-session-worktree false
  /bin/mkdir -p "${AS_PROFILE_ROOT}/Claude-stray"
  printf '{"preferences":{"storeReadCacheLatched":false}}\n' > "${AS_PROFILE_ROOT}/Claude-stray/claude_desktop_config.json"
  run_p prefs diff
  rc1="$rc"; d1="$out"
  [[ "$rc1" == "1" ]] || ok=1
  [[ "$d1" == *"new-session-worktree: needs review (proposed: primary's false); fleet=none; primary=false, tag-a=true, tag-b=true"* ]] || { ok=1; printf '    G line\n'; }
  [[ "$d1" == *"coworkWebSearchEnabled (C): primary=true, tag-a=false, tag-b=false"* ]] || { ok=1; printf '    C line\n'; }
  [[ "$d1" == *"localAgentModeTrustedFolders (S): primary=2 entries, tag-a=2 entries, tag-b=2 entries"* ]] || { ok=1; printf '    S list line\n'; }
  [[ "$d1" == *"bypassPermissionsModeEnabled (S): primary=false, tag-a=false, tag-b=true"* ]] || { ok=1; printf '    S line\n'; }
  [[ "$d1" == *'cc-landing-draft-permission-mode (S): primary="default", tag-a="acceptEdits", tag-b="acceptEdits"'* ]] || { ok=1; printf '    S string line\n'; }
  [[ "$d1" != *"chromeExtensionEnabled"* ]] || { ok=1; printf '    a C key that agrees was shown\n'; }
  [[ "$d1" == *"primary: 7 account-keyed entries for 2 account(s), 7 local entries"* ]] || { ok=1; printf '    A/L counts\n'; }
  [[ "$d1" == *"earlyWindowShowLatched (in primary, tag-a, tag-b)"* && "$d1" != *"storeReadCacheLatched"* ]] || { ok=1; printf '    U line\n'; }
  run_p prefs diff --all
  [[ "$out" == *"storeReadCacheLatched (in stray)"* && "$out" == *"stray (not synced)"* ]] || { ok=1; printf '    --all\n'; }
  # The fixture's ids, session keys and paths: the output holds none.
  [[ -z "$(leaks "${AS_TEST_ROOT}/transcript.txt")" ]] || ok=1
  setg primary new-session-worktree true
  run_p prefs sync
  run_p prefs diff
  [[ "$rc" == "0" && "$out" == *"Result: in sync; nothing pending."* ]] || { ok=1; printf '    in-sync rc=%s\n' "$rc"; }
  run_p prefs diff --bogus
  assert_eq "$ok" "0" "diff output" && assert_rc 2 && assert_no_ids
  result "prefs diff shows differences without identifiers: each key's status, fleet value and per-profile marks; C and S that differ (booleans, short strings); A and L counts; U by name (--all adds unsynced folders); no uuid, session id or path; exit 1 differs, 0 in sync, 2 error" $?
}

case_prior_copy_undo() {
  local ok=0 pre mode
  seeded
  pre="$(/bin/cat "$(pfile tag-b)")"
  setg tag-a keep-awake false
  setg tag-a sidebar-mode '"narrow"'
  pre="$(/bin/cat "$(pfile tag-b)")"
  run_p prefs sync tag-b
  mode="$(/usr/bin/stat -f '%Lp' "$(pfile tag-b).sync-prev")"
  [[ "$mode" == "600" && "$(/bin/cat "$(pfile tag-b).sync-prev")" == "$pre" ]] || { ok=1; printf '    prior copy mode=%s\n' "$mode"; }
  [[ "$(/bin/ls -a "$(pdir tag-b)" | /usr/bin/grep -c 'sync-prev')" == "1" ]] || { ok=1; printf '    more than one prior copy\n'; }
  # The app then changes one synced key and an unsynced one.
  setg tag-b sidebar-mode '"auto"'
  $JQ '.preferences.remoteToolsDeviceName = "renamed"' "$(pfile tag-b)" > "${AS_TEST_ROOT}/.x" && /bin/cat "${AS_TEST_ROOT}/.x" > "$(pfile tag-b)"
  run_p prefs undo tag-b
  [[ "$rc" == "0" && "$(gv tag-b keep-awake)" == "true" && "$(gv tag-b sidebar-mode)" == "auto" ]] || { ok=1; printf '    undo rc=%s\n' "$rc"; }
  [[ "$($JQ -r '.preferences.remoteToolsDeviceName' "$(pfile tag-b)")" == "renamed" ]] || { ok=1; printf '    a later app change was lost\n'; }
  [[ "$err" == *"Left sidebar-mode in tag-b: it changed since that sync."* ]] || { ok=1; printf '    no note for the changed key\n'; }
  [[ "$(/bin/ls -a "$(pdir tag-b)" | /usr/bin/grep -c 'sync-prev')" == "1" ]] || { ok=1; printf '    undo removed or added a prior copy\n'; }
  export AS_FAKE_QUIT=graceful
  run_p swap tag-b --no-handoff
  [[ "$(gv tag-b keep-awake)" == "true" && "$out$err" == *"1 needs review"* ]] || { ok=1; printf '    the next swap re-applied an undone key\n'; }
  [[ "$(state '.keys["keep-awake"].pending.reason')" == '"undo"' ]] || { ok=1; printf '    not marked needs review\n'; }
  # --whole-file restores the prior copy after a confirmation.
  tty_on
  run_in $'n\n' prefs undo tag-b --whole-file
  [[ "$rc" == "2" ]] || { ok=1; printf '    declined rc=%s\n' "$rc"; }
  pre="$(/bin/cat "$(pfile tag-b).sync-prev")"
  run_in $'y\n' prefs undo tag-b --whole-file
  [[ "$rc" == "0" && "$(/bin/cat "$(pfile tag-b)")" == "$pre" && -f "$(pfile tag-b).sync-prev" ]] || { ok=1; printf '    whole-file rc=%s\n' "$rc"; }
  [[ "$out" == *"Changes the app made to it since then will be lost."* ]] || { ok=1; printf '    no loss warning\n'; }
  assert_eq "$ok" "0" "prior copy and undo" && assert_no_ids
  result "one prior copy, one-step undo: a write leaves exactly one .sync-prev, mode 600; undo restores only keys still holding the synced value, keeps later app changes and marks them needs review, so the next swap doesn't re-apply them; --whole-file restores the copy after a confirmation" $?
}

case_half_written() {
  local ok=0
  seeded
  setg primary keep-awake false
  printf '{"preferences": {"sidebarMode": ' > "$(pfile tag-a)"
  export AS_FAKE_QUIT=graceful
  run_p swap tag-b --no-handoff
  [[ "$rc" == "0" && "$out$err" == *"'tag-a': its settings file is not valid JSON"* ]] || { ok=1; printf '    swap rc=%s\n' "$rc"; }
  [[ "$(gv tag-b keep-awake)" == "false" ]] || { ok=1; printf '    the other profiles did not sync\n'; }
  [[ "$(count_lines "$(calls_of sleep | /usr/bin/grep -x $'sleep\t1')")" -ge 1 ]] || { ok=1; printf '    no retry a second later\n'; }
  assert_called open "--user-data-dir=$(pdir tag-b)" || ok=1
  [[ "$(/bin/cat "$(pfile tag-a)")" == '{"preferences": {"sidebarMode": ' ]] || { ok=1; printf '    the torn file was written\n'; }
  assert_eq "$ok" "0" "half-written" && assert_no_ids
  result "a half-written file doesn't break anything: it is read twice, a second apart, then skipped with a warning; the other profiles sync and swap still launches" $?
}

case_visible_logged() {
  local ok=0 rows n
  seeded
  run_p prefs pin tag-a preferred-browser
  setg tag-b keep-awake false
  setg tag-a sidebar-mode '"narrow"'
  setg primary sidebar-mode '"auto"'
  setg tag-b preferred-browser '"safari"'
  export AS_FAKE_QUIT=graceful
  run_p swap tag-a --no-handoff
  n="$(count_lines "$(printf '%s\n' "$out" "$err" | /usr/bin/grep 'settings: ')")"
  [[ "$n" == "1" ]] || { ok=1; printf '    %s summary lines\n' "$n"; }
  [[ "$out$err" == *"settings: 1 applied to tag-a (keep-awake from tag-b), 1 kept (pinned), 0 skipped, 1 needs review: run 'account-switcher prefs review'"* ]] || { ok=1; printf '    summary line\n'; }
  run_p prefs unpin tag-a preferred-browser
  run_p prefs undo tag-a
  rows="$(rows_of PREFS_SYNC; rows_of PREFS_PIN; rows_of PREFS_UNDO)"
  [[ "$(count_lines "$rows")" == "4" ]] || { ok=1; printf '    rows:\n%s\n' "$rows"; }
  [[ "$rows" == *"PREFS_SYNC cmd=swap target=tag-a applied=1 keys=keep-awake kept=1 review=1 skipped=0 from=keep-awake:tag-b"* ]] || { ok=1; printf '    PREFS_SYNC row\n'; }
  [[ "$rows" == *"PREFS_UNDO cmd=undo target=tag-a mode=keys undone=1 keys=keep-awake"* ]] || { ok=1; printf '    PREFS_UNDO row\n'; }
  [[ "$rows" != *"true"* && "$rows" != *"false"* && "$rows" != *'"'* && "$rows" != *"narrow"* && "$rows" != *"safari"* ]] || { ok=1; printf '    a row carries a value\n'; }
  assert_eq "$ok" "0" "summary and rows" && assert_no_ids
  result "visible and logged: swap prints one summary line (applied, kept, skipped, needs review); every writing command appends one PREFS_SYNC, PREFS_PIN or PREFS_UNDO row with key ids and counts, never values" $?
}

case_documented() {
  local ok=0 readme cmd ver
  new_case
  : > "${AS_TEST_ROOT}/transcript.txt"
  # help prints the store's paths (lines from before #11), so its output is
  # not kept for the identifier scan.
  run_switcher help
  ver="$(/usr/bin/sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "$SWITCHER")"
  [[ -n "$ver" && "$out" == *"(v${ver})"* ]] || { ok=1; printf '    help does not show the version read from the script\n'; }
  for cmd in "diff [--all]" "sync [<tag>] [--dry-run]" "review" "adopt <key-id> --from <tag>" "pin <tag> <key-id>|--all" "unpin <tag> <key-id>|--all" "undo <tag> [--whole-file]" "Needs a terminal"; do
    [[ "$out" == *"$cmd"* ]] || { ok=1; printf '    help lacks: %s\n' "$cmd"; }
  done
  readme="$(< "${REPO}/README.md")"
  for cmd in "## How \`swap\` works internally" "## Settings sync between profiles (\`prefs\`)" "| \`prefs diff [--all]\`" "class G" "prefs review" "prefs pin" "prefs undo" "Nothing deletes"; do
    [[ "$readme" == *"$cmd"* ]] || { ok=1; printf '    README lacks: %s\n' "$cmd"; }
  done
  cmd="$(< "${REPO}/commands/account-switcher.md")"
  for readme in "prefs diff" "prefs review" "prefs pin" "prefs undo" "needs a terminal"; do
    [[ "$cmd" == *"$readme"* ]] || { ok=1; printf '    commands/account-switcher.md lacks: %s\n' "$readme"; }
  done
  assert_eq "$ok" "0" "documentation" && assert_no_ids
  result "documented: help lists the prefs verbs and says review needs a terminal; README (How swap works, the settings section, Subcommand reference) and the slash command describe them" $?
}

# ---- Beyond the criteria -------------------------------------------------------

case_type_differs() {
  local ok=0
  seeded
  setg tag-a keep-awake '"yes"'
  setg primary sidebar-mode '"narrow"'
  run_p prefs sync
  [[ "$(gv primary keep-awake)|$(gv tag-b keep-awake)|$(gv tag-a keep-awake)" == "true|true|yes" ]] || { ok=1; printf '    a key of another type was written\n'; }
  [[ "$(gv tag-b sidebar-mode)" == "narrow" ]] || { ok=1; printf '    the other keys did not sync\n'; }
  [[ "$rc" == "1" && "$err" == *"1 skipped"* ]] || { ok=1; printf '    rc=%s\n' "$rc"; }
  run_p prefs diff
  [[ "$out" == *"keep-awake: type differs in a profile: left alone"* ]] || { ok=1; printf '    diff\n'; }
  assert_eq "$ok" "0" "type" && assert_no_ids
  result "a key whose type differs in any profile is treated as unclassified for that run: never written, reported, and the other keys sync" $?
}

case_removed_key() {
  local ok=0
  seeded
  setg tag-a transcript-links-in-preview absent
  run_p prefs sync
  [[ "$(gv tag-a transcript-links-in-preview)|$(gv primary transcript-links-in-preview)|$(gv tag-b transcript-links-in-preview)" == "absent|true|true" ]] || { ok=1; printf '    first run\n'; }
  run_p prefs sync
  [[ "$(gv tag-a transcript-links-in-preview)" == "absent" ]] || { ok=1; printf '    re-added on the second run\n'; }
  run_p prefs diff
  [[ "$out" == *"tag-a=absent (removed by the app)"* ]] || { ok=1; printf '    diff\n'; }
  assert_eq "$ok" "0" "removal" && assert_no_ids
  result "a key the app removed from a profile is not re-added there, its removal doesn't spread, and diff shows it" $?
}

case_lock() {
  local ok=0 owner
  seeded
  setg tag-a keep-awake false
  make_lock 60
  owner="$(/usr/bin/shasum < "${AS_STORE}/.prefs-sync.lock/owner")"
  run_p prefs sync
  [[ "$rc" == "2" && "$err" == *"A settings sync is running (the lock ~/.claude/account-switcher/.prefs-sync.lock is 1m old, taken by PID 4242)"* ]] || { ok=1; printf '    sync rc=%s\n' "$rc"; }
  run_p clone-prefs primary tag-b
  [[ "$rc" == "1" && "$err" == *"A settings sync is running"* ]] || { ok=1; printf '    clone-prefs rc=%s\n' "$rc"; }
  export AS_FAKE_QUIT=graceful
  run_p swap tag-b --no-handoff
  [[ "$rc" == "0" && "$err$out" == *"Skipping the settings step; the swap continues."* && "$(gv tag-b keep-awake)" == "true" ]] || { ok=1; printf '    swap rc=%s\n' "$rc"; }
  assert_called open "--user-data-dir=$(pdir tag-b)" || ok=1
  assert_unchanged "${AS_STORE}/.prefs-sync.lock/owner" "$owner" || ok=1
  make_lock 3600
  run_p prefs pin tag-a keep-awake
  [[ "$rc" == "2" && "$err" == *"is 1h 0m old (taken by PID 4242), past the 10-minute limit"* && "$err" == *"remove it: trash ~/.claude/account-switcher/.prefs-sync.lock"* ]] || { ok=1; printf '    stale rc=%s\n' "$rc"; }
  [[ -d "${AS_STORE}/.prefs-sync.lock" ]] || { ok=1; printf '    the stale lock was removed\n'; }
  [[ "$(gv primary keep-awake)" == "true" ]] || { ok=1; printf '    a write happened under the lock\n'; }
  assert_eq "$ok" "0" "lock" && assert_no_ids
  result "the settings-sync lock: a held lock refuses sync (2), clone-prefs (1) and the swap's settings step (the swap still launches); a stale one is reported with the trash remedy and never removed" $?
}

case_install_check() {
  local ok=0 rc1 out1
  scene
  /bin/mkdir -p "${HOME}/.claude/commands" || harness_error "cannot create the commands folder"
  /bin/cp "$REPO/account-switcher.sh" "${AS_STORE}/account-switcher.sh"
  /bin/chmod 755 "${AS_STORE}/account-switcher.sh"
  /bin/cp "$REPO/commands/account-switcher.md" "${HOME}/.claude/commands/account-switcher.md"
  # prefs sync creates prefs-sync.json.
  run_p prefs sync
  [[ -f "${AS_STORE}/prefs-sync.json" ]] || ok=1
  run_install --check
  rc1="$rc"; out1="$out"
  # A sync holds .prefs-sync.lock while it writes; the lock as it makes it.
  make_lock 30
  run_install --check
  assert_eq "$ok" "0" "prefs-sync.json after prefs sync" &&
    assert_eq "$rc1" "0" "install.sh --check with prefs-sync.json" &&
    assert_not_contains "$out1" "leftover" &&
    assert_rc 0 &&
    assert_not_contains "$out" "leftover" &&
    assert_no_ids
  result "install.sh --check exits 0 with prefs-sync.json (from prefs sync) and with .prefs-sync.lock held" $?
}

case_exit_codes() {
  local ok=0 r
  check() { [[ "$rc" == "$1" ]] || { ok=1; printf '    %s: expected %s, got %s\n' "$2" "$1" "$rc"; }; }
  scene
  setg primary new-session-worktree false
  run_p prefs diff; check 1 "diff, differs"
  run_p prefs diff x; check 2 "diff, bad argument"
  run_p prefs sync --dry-run; check 1 "sync --dry-run, pending"
  run_p prefs sync; check 1 "sync, a key needs review"
  run_p prefs sync nosuch; check 2 "sync, not a profile"
  run_p prefs review; check 2 "review, no terminal"
  run_p prefs adopt new-session-worktree --from tag-a; check 0 "adopt"
  run_p prefs adopt nosuch --from tag-a; check 2 "adopt, unknown key"
  run_p prefs diff; check 0 "diff, in sync"
  run_p prefs sync --dry-run; check 0 "sync --dry-run, nothing to do"
  run_p prefs sync; check 0 "sync, done"
  run_p prefs pin tag-a keep-awake; check 0 "pin"
  run_p prefs pin tag-a nosuch; check 2 "pin, unknown key"
  run_p prefs unpin tag-a keep-awake; check 0 "unpin"
  run_p prefs unpin nosuch keep-awake; check 2 "unpin, not a profile"
  run_p prefs undo tag-b; check 1 "undo, nothing to restore"
  run_p prefs undo primary; check 0 "undo"
  run_p prefs undo; check 2 "undo, no tag"
  tty_on
  run_in $'' prefs review; check 1 "review, a key left pending (undo)"
  run_in $'1\ny\n' prefs review; check 0 "review, applied"
  run_in $'' prefs review; check 0 "review, nothing to review"
  unset AS_TEST_STDIN_IS_TTY
  run_p prefs bogus; check 2 "unknown verb"
  r="$ok"
  assert_eq "$r" "0" "exit codes" && assert_no_ids
  result "exit codes: diff 0/1/2, sync 0/1/2, sync --dry-run 0/1, review 0/1/2, adopt 0/2, pin and unpin 0/2, undo 0/1/2, an unknown verb 2" $?
}

case_scan_control
case_only_allowlisted
case_dotted_literal
case_latest_wins
case_behind_not_changed
case_unclear_order
case_pins
case_running_tag
case_running_refusals
case_swap_and_launch
case_clone_prefs
case_read_only
case_diff_output
case_prior_copy_undo
case_half_written
case_visible_logged
case_documented
case_type_differs
case_removed_key
case_lock
case_install_check
case_exit_codes
finish
