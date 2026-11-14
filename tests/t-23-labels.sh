#!/usr/bin/env bash
# tests/t-23-labels.sh - #23: status, add-account and the history log name
# tags, labels and folder names, never an email, an account id or a path
# under the home folder; no email or id reaches a child process's
# arguments; the swap handoff file is mode 600 from creation.
#
# Fixture emails and ids are generated here, at test time, on a reserved
# domain, and written under the scratch root only, so no committed file
# holds an address or an id-shaped string. The scan looks for three shapes:
# an email, a uuid, and the case's own home folder and profile root (a
# fixed prefix would be vacuous: the case's HOME is a scratch folder). It
# reads the output of status and add-account (as #23 words it), every
# history row, and the fakes' argument log, calls.log (email and uuid only:
# file paths in arguments legitimately sit under HOME). launch and swap print
# a profile's path by design, so only their rows are scanned. The scan's
# control arm plants one of each shape and requires each to be found.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

# ---- Fixture values (generated, never committed) -----------------------------

fid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }
fmail() { printf 'acct-%s.%s%s' "$1" "$$" "@example.invalid"; }
ID_A="$(fid 23)"
MAIL_A="$(fmail a)"
MAIL_P="$(fmail p)"
MAIL_C="$(fmail c)"
MAIL_X="$(fmail x)"

EMAIL_ERE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
UUID_ERE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
NEW_PID=4242
# The config file as the usage text names it, with a literal tilde.
TILDE_CONFIG="$(printf '%s/.claude/account-switcher/config.toml' '~')"

# ---- Scenario ----------------------------------------------------------------

profile_dir() {
  if [[ "$1" == "primary" ]]; then
    printf '%s' "${AS_PROFILE_ROOT}/Claude"
  else
    printf '%s' "${AS_PROFILE_ROOT}/Claude-$1"
  fi
}

# [accounts] with primary and tag-a carrying an email, tag-b without one;
# [swap_handoff] pointing git at the scratch fixture (and the handoff at
# $1 when given).
write_config() {
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'primary = { label = "Personal", profile_email = "%s" }\n' "$MAIL_P"
    printf 'tag-a = { label = "Alpha", profile_email = "%s" }\n' "$MAIL_A"
    printf 'tag-b = { label = "Beta" }\n'
    printf '\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT"
    if [[ -n "${1:-}" ]]; then printf 'workspace_dir = "%s"\n' "$1"; fi
  } > "${AS_STORE}/config.toml"
  /bin/chmod 600 "${AS_STORE}/config.toml"
}

# The CLI account in ~/.claude.json: $1 = email (may be empty), $2 = id.
write_claude_json() {
  printf '{"oauthAccount": {"emailAddress": "%s", "accountUuid": "%s"}}\n' "$1" "$2" > "$AS_CLAUDE_JSON"
}

scenario() {
  new_case
  /bin/mkdir -p "$AS_STORE" "$(profile_dir primary)" "$(profile_dir tag-a)" "$(profile_dir tag-b)" \
    || harness_error "cannot create the profile folders"
  set_ps_fixture ps-no-claude.txt
  write_config
  write_claude_json "$MAIL_A" "$ID_A"
}

history_text() {
  if [[ -f "${AS_STORE}/swap-history.log" ]]; then printf '%s' "$(< "${AS_STORE}/swap-history.log")"; fi
}

calls_text() {
  if [[ -f "${AS_TEST_ROOT}/calls.log" ]]; then printf '%s' "$(< "${AS_TEST_ROOT}/calls.log")"; fi
}

# ---- Scan --------------------------------------------------------------------

# hits <text> <home|nohome>: one word per shape found in the text: email,
# uuid, home (the case's HOME or profile root; only with "home"). The email
# and uuid tests read the text with the scratch base (the folder holding the
# case root) taken out, so a base whose own path holds a uuid can't raise a
# false hit.
hits() {
  local t="$1" s h="" base="${AS_TEST_ROOT%/*}"
  s="${t//"$base"/<base>}"
  [[ "$s" =~ $EMAIL_ERE ]] && h="${h}email "
  [[ "$s" =~ $UUID_ERE ]] && h="${h}uuid "
  if [[ "$2" == "home" ]]; then
    case "$t" in
      *"$HOME"*|*"$AS_PROFILE_ROOT"*) h="${h}home " ;;
    esac
  fi
  printf '%s' "$h"
}

# assert_clean <text> <home|nohome> <what>: no shape found.
assert_clean() {
  local h
  h="$(hits "$1" "$2")"
  if [[ -n "$h" ]]; then printf '    %s holds: %s\n' "$3" "$h"; return 1; fi
  return 0
}

# The control arm: a text planting one of each shape must show all three.
assert_scan_control() {
  local h
  h="$(hits "x ${MAIL_X} y ${ID_A} z ${HOME}/q" home)"
  if [[ "$h" != "email uuid home " ]]; then printf '    control: the scan found only [%s]\n' "$h"; return 1; fi
  h="$(hits "${AS_PROFILE_ROOT}/Claude-x" home)"
  if [[ "$h" != "home " ]]; then printf '    control: the scan missed the profile root\n'; return 1; fi
  return 0
}

# The rows, the output given and calls.log are all clean.
assert_all_clean() {
  assert_scan_control &&
    assert_clean "$1" home "the output" &&
    assert_clean "$(history_text)" home "the history log" &&
    assert_clean "$(calls_text)" nohome "calls.log"
}

# ---- status (AC1) ------------------------------------------------------------

case_status_label() {
  scenario
  run_switcher status
  assert_rc 0 &&
    assert_contains "$out" "  account:      Alpha" &&
    assert_contains "$out" "  switcher tag: tag-a" &&
    assert_called awk "tag=tag-a" &&
    assert_not_contains "$out" "email:" &&
    assert_not_contains "$out" "account id:" &&
    assert_all_clean "$out$err"
  result "status: the CLI account's label (Alpha), no email or id; output, rows and calls.log clean (control arm finds each shape)" $?
}

# An [accounts] entry keyed `default` (add-account accepts that tag) still
# resolves: status reads each key literally.
case_status_default_key() {
  scenario
  {
    printf 'version = 1\n\n[accounts]\n'
    printf 'default = { label = "Home", profile_email = "%s" }\n' "$MAIL_A"
    printf '\n[swap_handoff]\ngit_root = "%s"\n' "$TEST_GIT_ROOT"
  } > "${AS_STORE}/config.toml"
  run_switcher status
  assert_rc 0 &&
    assert_contains "$out" "  account:      Home" &&
    assert_contains "$out" "  switcher tag: default" &&
    assert_all_clean "$out$err"
  result "status: an entry keyed default resolves to its own label (Home), as the lookup did before #23" $?
}

case_status_unknown() {
  local r1 r2 r3 o1 o2 o3 c=0
  scenario
  write_claude_json "$MAIL_X" "$ID_A"
  run_switcher status; r1="$rc"; o1="$out$err"
  assert_all_clean "$o1" || c=1
  # An empty CLI email must not match tag-b, the entry with no email.
  write_claude_json "" "$ID_A"
  run_switcher status; r2="$rc"; o2="$out$err"
  assert_all_clean "$o2" || c=1
  /bin/rm -f "$AS_CLAUDE_JSON"
  run_switcher status; r3="$rc"; o3="$out$err"
  assert_all_clean "$o3" || c=1
  assert_eq "$r1$r2$r3" "000" "exits" &&
    assert_contains "$o1" "  account:      unknown" &&
    assert_contains "$o2" "  account:      unknown" &&
    assert_not_contains "$o2" "Beta" &&
    assert_contains "$o3" "  account:      unknown" &&
    assert_eq "$c" "0" "scans"
  result "status: unknown for an unconfigured email, an empty email (never the entry without one) and a missing ~/.claude.json" $?
}

case_status_show_ids_not_terminal() {
  scenario
  run_switcher status --show-ids
  assert_rc 2 &&
    assert_eq "$out" "" "stdout" &&
    assert_contains "$err" "status --show-ids" &&
    assert_all_clean "$out$err"
  result "status --show-ids off a terminal: exit 2, nothing on stdout, no id anywhere" $?
}

case_status_show_ids_terminal() {
  scenario
  AS_TEST_STDOUT_IS_TTY=1
  export AS_TEST_STDOUT_IS_TTY
  run_switcher status --show-ids
  unset AS_TEST_STDOUT_IS_TTY
  assert_rc 0 &&
    assert_contains "$out" "  account:      Alpha" &&
    assert_contains "$out" "  email:        ${MAIL_A}" &&
    assert_contains "$out" "  account id:   ${ID_A}" &&
    assert_clean "$err" home "stderr" &&
    assert_clean "$(history_text)" home "the history log" &&
    assert_clean "$(calls_text)" nohome "calls.log"
  result "status --show-ids at a terminal: the email and id on stdout only (stderr, rows and calls.log clean)" $?
}

case_status_bad_arg() {
  scenario
  run_switcher status "$MAIL_X"
  assert_rc 2 &&
    assert_eq "$out" "" "stdout" &&
    assert_all_clean "$out$err"
  result "status with an unknown argument: exit 2, and the argument is not echoed" $?
}

# ---- add-account (AC2, AC3, AC6) ---------------------------------------------

case_add_account() {
  local line mode
  scenario
  run_switcher add-account tag-c "$MAIL_C" "Gamma"
  line="$(/usr/bin/grep -F 'tag-c = ' "${AS_STORE}/config.toml")"
  mode="$(/usr/bin/stat -f '%Lp' "${AS_STORE}/config.toml")"
  assert_rc 0 &&
    assert_eq "$line" "tag-c = { label = \"Gamma\", profile_email = \"${MAIL_C}\" }" "the new [accounts] entry" &&
    assert_eq "$mode" "600" "config.toml mode" &&
    assert_contains "$out$err" "tag=tag-c" &&
    assert_all_clean "$out$err" &&
    assert_contains "$(history_text)" "ADD_ACCOUNT tag=tag-c label=\"Gamma\""
  result "add-account: the entry lands with the email (mode 600); output, row and calls.log carry no email" $?
}

case_add_account_backslash_label() {
  local n
  scenario
  run_switcher add-account tag-c "$MAIL_C" 'C:\new'
  n="$(/usr/bin/grep -c -F 'tag-c = { label = "C:\new", profile_email' "${AS_STORE}/config.toml")"
  assert_rc 0 &&
    assert_eq "$n" "1" "one literal entry line (no expanded backslash)" &&
    assert_all_clean "$out$err"
  result "add-account: a backslash in the label is written literally, on one line" $?
}

case_add_account_refusals() {
  local c=0 o="" u="" before after
  scenario
  before="$(/sbin/md5 -q "${AS_STORE}/config.toml")"
  run_switcher add-account "$MAIL_C" tag-c
  [[ "$rc" == "1" ]] || c=1; assert_clean "$out$err" home "wrong order" || c=1; o="$o$out$err"
  run_switcher add-account tag-c "not-an-email"
  [[ "$rc" == "1" ]] || c=1; assert_clean "$out$err" home "bad email" || c=1; o="$o$out$err"
  run_switcher add-account tag-a "$MAIL_C"
  [[ "$rc" == "1" ]] || c=1; assert_clean "$out$err" home "duplicate tag" || c=1; o="$o$out$err"
  # The usage text: its example.com placeholders are documentation, so only
  # the home folder is scanned for there.
  run_switcher add-account; [[ "$rc" == "1" ]] || c=1; u="$out$err"
  after="$(/sbin/md5 -q "${AS_STORE}/config.toml")"
  assert_eq "$c" "0" "each refusal exits 1" &&
    assert_eq "$after" "$before" "config.toml unchanged" &&
    assert_not_contains "$o" "not-an-email" &&
    assert_all_clean "$o" &&
    assert_contains "$u" "${TILDE_CONFIG}" &&
    assert_eq "$(hits "$u" home)" "email " "usage: the placeholder email only, no home path"
  result "add-account refusals (wrong order, bad email, duplicate tag, usage): no email, value or home path echoed; nothing written" $?
}

# ---- History rows (AC2, AC4): exact shapes ----------------------------------

# row_shape <row>: 0 for a LAUNCH, APP_SWAP or ADD_ACCOUNT row in the new
# shape, 1 otherwise.
row_shape() {
  local ts='\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]'
  local f='Claude(-[a-z0-9-]+)?'
  [[ "$1" =~ ^${ts}\ LAUNCH\ tag=[a-z0-9-]+\ udd=${f}\ first_launch=(true|false)$ ]] && return 0
  [[ "$1" =~ ^${ts}\ APP_SWAP\ target=[a-z0-9-]+\ udd=${f}\ first_launch=(true|false)\ mirror=(yes|no)$ ]] && return 0
  [[ "$1" =~ ^${ts}\ ADD_ACCOUNT\ tag=[a-z0-9-]+\ label=\"[^\"]*\"$ ]] && return 0
  return 1
}

case_row_shapes() {
  local l n=0 bad=0 ctl=0
  scenario
  set_ps_fixture ps-no-claude.txt
  AS_FAKE_OPEN_SPAWNS_PID="$NEW_PID"
  export AS_FAKE_OPEN_SPAWNS_PID
  run_switcher launch tag-a
  set_ps_fixture ps-one-tag.txt ps-no-claude.txt
  export AS_FAKE_QUIT=graceful
  run_switcher swap tag-b --no-mirror --no-handoff
  run_switcher add-account tag-c "$MAIL_C" "Gamma (work)"
  while IFS= read -r l; do
    case "$l" in
      *" LAUNCH "*|*" APP_SWAP "*|*" ADD_ACCOUNT "*) n=$((n + 1)); row_shape "$l" || { bad=1; printf '    bad row: %s\n' "$l"; } ;;
    esac
  done <<< "$(history_text)"
  # Control: the old shapes fail the check.
  row_shape "[2026-11-14T00:00:00Z] LAUNCH tag=tag-a udd=${AS_PROFILE_ROOT}/Claude-tag-a first_launch=false" && ctl=1
  row_shape "[2026-11-14T00:00:00Z] APP_SWAP target=tag-b udd=${AS_PROFILE_ROOT}/Claude-tag-b first_launch=false mirror=no" && ctl=2
  row_shape "[2026-11-14T00:00:00Z] ADD_ACCOUNT tag=tag-c email=${MAIL_C} label=Gamma" && ctl=3
  assert_eq "$ctl" "0" "control: each old shape fails" &&
    assert_eq "$n" "3" "rows checked (LAUNCH, APP_SWAP, ADD_ACCOUNT)" &&
    assert_eq "$bad" "0" "rows in another shape" &&
    assert_contains "$(history_text)" "LAUNCH tag=tag-a udd=Claude-tag-a first_launch=" &&
    assert_contains "$(history_text)" "APP_SWAP target=tag-b udd=Claude-tag-b " &&
    assert_clean "$(history_text)" home "the history log" &&
    assert_clean "$(calls_text)" nohome "calls.log"
  result "rows: LAUNCH and APP_SWAP name the profile folder, ADD_ACCOUNT the tag and quoted label; old shapes fail (control)" $?
}

# ---- The swap handoff (AC5) --------------------------------------------------

# A case-local chmod: records, for each call on SWAP_HANDOFF.md, the mode
# requested and the file's mode just before (none when it doesn't exist),
# then runs the harness's own guarded chmod fake.
mode_recording_chmod() {
  /bin/mv "${AS_FAKES_DIR}/chmod" "${AS_FAKES_DIR}/chmod.real" || harness_error "cannot move the chmod fake"
  /bin/cat > "${AS_FAKES_DIR}/chmod" <<'FAKE'
#!/bin/bash
# as-fake: guarded-passthrough
last="${!#}"
case "$last" in
  */SWAP_HANDOFF.md)
    m="$(/usr/bin/stat -f '%Lp' "$last" 2> /dev/null)" || m=""
    printf '%s %s\n' "$1" "${m:-none}" >> "${AS_TEST_ROOT}/modes.log" ;;
esac
exec "${AS_FAKES_DIR}/chmod.real" "$@"
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/chmod" || harness_error "cannot chmod the chmod fake"
}

modes_text() {
  if [[ -f "${AS_TEST_ROOT}/modes.log" ]]; then printf '%s' "$(< "${AS_TEST_ROOT}/modes.log")"; fi
}

swap_with_handoff() {
  set_ps_fixture ps-one-tag.txt ps-no-claude.txt
  AS_FAKE_QUIT=graceful
  AS_FAKE_OPEN_SPAWNS_PID="$NEW_PID"
  export AS_FAKE_QUIT AS_FAKE_OPEN_SPAWNS_PID
  run_switcher swap tag-b --no-mirror
}

# A permissive umask (022) for the run, so a file the switcher left to it
# would read 644: the closing chmod must find the new file at 600 already.
case_handoff_new_file() {
  local f mode
  scenario
  mode_recording_chmod
  f="${AS_STORE}/SWAP_HANDOFF.md"
  umask 022
  swap_with_handoff
  mode="$(/usr/bin/stat -f '%Lp' "$f" 2> /dev/null)"
  assert_rc 0 &&
    assert_eq "$mode" "600" "a new handoff's mode" &&
    assert_eq "$(modes_text)" "600 600" "the mode before the closing chmod (created at 600)" &&
    assert_contains "$(history_text)" "HANDOFF_CAPTURE source=tag-a target=tag-b"
  result "handoff: a new SWAP_HANDOFF.md is created with mode 600" $?
}

# The existing file must be made 600 before the write: the first chmod finds
# it at 644, and the closing one finds it at 600 already.
case_handoff_existing_644() {
  local f mode body
  scenario
  mode_recording_chmod
  umask 022
  f="${AS_STORE}/SWAP_HANDOFF.md"
  printf 'OLD-HANDOFF-MARKER\n' > "$f"
  /bin/chmod 644 "$f"
  swap_with_handoff
  mode="$(/usr/bin/stat -f '%Lp' "$f" 2> /dev/null)"
  body="$(< "$f")"
  assert_rc 0 &&
    assert_eq "$mode" "600" "the rewritten handoff's mode" &&
    assert_not_contains "$body" "OLD-HANDOFF-MARKER" &&
    assert_contains "$body" '- **Direction:** `tag-a` → `tag-b`' &&
    assert_eq "$(modes_text)" "600 644"$'\n'"600 600" "the mode before each chmod (644, then already 600)"
  result "handoff: an existing 644 file is made 600 and rewritten" $?
}

# The handoff's folder is read-only: an existing file is still made 600 and
# written in place; with no file, the write fails and the swap stops before
# anything is quit, as before #23.
case_handoff_readonly_folder() {
  local ws mode r1 r2
  scenario
  ws="${AS_TEST_ROOT}/ws"
  /bin/mkdir -p "$ws"
  printf 'old\n' > "${ws}/SWAP_HANDOFF.md"
  /bin/chmod 644 "${ws}/SWAP_HANDOFF.md"
  /bin/chmod 555 "$ws"
  write_config "$ws"
  swap_with_handoff; r1="$rc"
  mode="$(/usr/bin/stat -f '%Lp' "${ws}/SWAP_HANDOFF.md" 2> /dev/null)"
  /bin/chmod 755 "$ws"; /bin/rm -f "${ws}/SWAP_HANDOFF.md"; /bin/chmod 555 "$ws"
  : > "${AS_TEST_ROOT}/calls.log"
  swap_with_handoff; r2="$rc"
  /bin/chmod 755 "$ws"
  assert_eq "$r1" "0" "existing file in a read-only folder: exit" &&
    assert_eq "$mode" "600" "existing file in a read-only folder: mode" &&
    assert_eq "$([[ "$r2" != "0" ]] && printf fail || printf ok)" "fail" "no file in a read-only folder: the swap stops" &&
    assert_never_called osascript &&
    assert_never_called kill &&
    assert_eq "$([[ -e "${ws}/SWAP_HANDOFF.md" ]] && printf yes || printf no)" "no" "no handoff written"
  result "handoff: a read-only folder still rewrites an existing file at 600; a failed write stops the swap before any quit" $?
}

# ---- identity pin (AC3): the id is not in awk's arguments or environment -----

# A case-local awk fake: records its arguments (as the passthrough does) and
# the name of every environment variable whose value holds a uuid, then runs
# the real awk. Names, not values: the inherited environment may hold an
# unrelated uuid, so the case compares against a baseline run; and the
# scratch base is taken out of each value first (the harness's
# GIT_CEILING_DIRECTORIES names it).
env_recording_awk() {
  /bin/cat > "${AS_FAKES_DIR}/awk" <<'FAKE'
#!/bin/bash
# as-fake: passthrough
line="awk"
for arg; do arg="${arg//$'\t'/\\t}"; line="${line}"$'\t'"${arg//$'\n'/\\n}"; done
printf '%s\n' "$line" >> "${AS_TEST_ROOT}/calls.log"
re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
base="${AS_TEST_ROOT%/*}"
while IFS= read -r v; do
  val="${v#*=}"; val="${val//"$base"/}"
  [[ "$val" =~ $re ]] && printf '%s\n' "${v%%=*}" >> "${AS_TEST_ROOT}/env.log"
done < <(/usr/bin/env)
exec /usr/bin/awk "$@"
FAKE
  /bin/chmod 755 "${AS_FAKES_DIR}/awk" || harness_error "cannot chmod the awk fake"
}

# The names env.log holds, sorted and unique, one per line.
env_names() {
  if [[ -f "${AS_TEST_ROOT}/env.log" ]]; then /usr/bin/sort -u "${AS_TEST_ROOT}/env.log"; fi
}

case_identity_pin_channel() {
  local pin base after extra ctl
  scenario
  printf '{"lastKnownAccountUuid": "%s"}\n' "$ID_A" > "$(profile_dir tag-a)/config.json"
  env_recording_awk
  # Baseline: the names the inherited environment brings to any awk call.
  "${AS_FAKES_DIR}/awk" 'BEGIN{}' < /dev/null
  base="$(env_names)"
  run_switcher identity pin tag-a --yes
  pin="$(/usr/bin/awk '/^\[/ { t = ($0 == "[identity]"); next } t && NF { print }' "${AS_STORE}/config.toml")"
  after="$(env_names)"
  extra="$(/usr/bin/comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$after") | /usr/bin/tr '\n' ' ')"
  # Control: the same fake, given a uuid in a new variable, records its name.
  AS_PROBE="x${ID_A}" "${AS_FAKES_DIR}/awk" 'BEGIN{}' < /dev/null
  ctl="$(env_names | /usr/bin/grep -c -x 'AS_PROBE')"
  assert_rc 0 &&
    assert_eq "$pin" "tag-a = \"${ID_A}\"" "the pin lands" &&
    assert_eq "$extra" "" "variables holding a uuid in awk's environment during the pin" &&
    assert_clean "$(calls_text)" nohome "calls.log" &&
    assert_eq "$ctl" "1" "control: the recorder names a variable holding a uuid"
  result "identity pin: the pinned id reaches awk on stdin, in neither its arguments nor its environment (control: the recorder names one)" $?
}

case_status_label
case_status_default_key
case_status_unknown
case_status_show_ids_not_terminal
case_status_show_ids_terminal
case_status_bad_arg
case_add_account
case_add_account_backslash_label
case_add_account_refusals
case_row_shapes
case_handoff_new_file
case_handoff_existing_644
case_handoff_readonly_folder
case_identity_pin_channel
finish
