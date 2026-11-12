#!/usr/bin/env bash
# tests/t-00-seam.sh - the command-path seam and its test-mode interlock.
#
# Production neutrality (a planted AS_* value is ignored outside test mode),
# one refusal case per interlock check (each must exit 78 with one refusal
# line, before any fake runs), one positive case, and the guards inside the
# kill, security and write-tool fakes.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

EXPECT_V="$(/usr/bin/sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' "$SWITCHER")"

# Exit 78, exactly one stderr line naming the reason, nothing on stdout, and
# no fake called: the interlock ran before the script did anything.
refused() {  # $1 = text the refusal line must contain
  assert_rc 78 &&
    assert_eq "$(count_lines "$err")" "1" "stderr lines" &&
    assert_contains "$err" "ERROR: AS_TEST_MODE=1 but $1" &&
    assert_contains "$err" "Test mode never runs against real state; refusing." &&
    assert_eq "$out" "" "stdout" &&
    assert_eq "$(< "${AS_TEST_ROOT}/calls.log")" "" "calls.log"
}

# ---- Production neutrality ------------------------------------------------

# run_prod_driver: sources the script (every line but its call to main) in
# production mode, with the case's planted environment, and prints what each
# test-only name holds after the seam block, whether it is readonly, and
# what _stdout_tty answers with stdout redirected to a file. Nothing in the
# script runs but its top level, which defines and assigns only, so no real
# command runs and no real state is read.
run_prod_driver() {
  local lib="${AS_TEST_ROOT}/switcher-lib.sh" l prev="" first=1
  : > "$lib"
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $first -eq 0 ]]; then printf '%s\n' "$prev" >> "$lib"; fi
    prev="$l"
    first=0
  done < "$SWITCHER"
  [[ "$prev" == "main "* ]] || harness_error "the script's last line is not the call to main"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    PATH="$SYSTEM_PATH"
    unset AS_TEST_MODE
    # shellcheck disable=SC2016
    exec /bin/bash -c '
      . "$1" || exit 70
      ro=yes
      ( AS_TEST_STDOUT_IS_TTY=1 ) 2> /dev/null && ro=no
      ( AS_TEST_STDIN_IS_TTY=1 ) 2> /dev/null && ro=no
      ( AS_TEST_PREFS_EXTRA_OP="[]" ) 2> /dev/null && ro=no
      if _stdout_tty; then tty=yes; else tty=no; fi
      ops="$(_prefs_test_ops "[]")"
      printf "stdin=[%s] stdout=[%s] hook=[%s] extra_op=[%s] readonly=%s stdout_tty=%s ops=%s\n" \
        "$AS_TEST_STDIN_IS_TTY" "$AS_TEST_STDOUT_IS_TTY" "$AS_TEST_POLL_HOOK" "$AS_TEST_PREFS_EXTRA_OP" \
        "$ro" "$tty" "$ops"' t00-driver "$lib"
  ) > "${AS_TEST_ROOT}/.run-out" 2> "${AS_TEST_ROOT}/.run-err" < /dev/null
  rc=$?
  _read_run "${AS_TEST_ROOT}/.run-out" "${AS_TEST_ROOT}/.run-err"
}

case_prod_planted_bin_ignored() {
  new_case
  # Every AS_BIN_* is exported and points at a fake; AS_BIN_CAT points
  # nowhere and AS_STORE somewhere else. Outside test mode all are ignored.
  # So are the test-only names, planted here too.
  export AS_BIN_CAT=/nonexistent
  new_sibling_dir
  export AS_STORE="$SIBLING_DIR"
  local hook="${AS_TEST_ROOT}/planted-hook.sh"
  printf '#!/bin/bash\nexit 0\n' > "$hook"
  /bin/chmod 755 "$hook"
  export AS_TEST_STDIN_IS_TTY=1 AS_TEST_STDOUT_IS_TTY=1 AS_TEST_POLL_HOOK="$hook" \
    AS_TEST_PREFS_EXTRA_OP='[["preferences","bypassPermissionsModeEnabled"],true]'
  run_switcher_prod help
  local help_rc="$rc" help_out="$out"
  run_prod_driver
  unset AS_TEST_STDIN_IS_TTY AS_TEST_STDOUT_IS_TTY AS_TEST_POLL_HOOK AS_TEST_PREFS_EXTRA_OP
  assert_eq "$help_rc" "0" "help exit" &&
    assert_contains "$help_out" "USAGE:" &&
    assert_contains "$help_out" "STORE:        ${HOME}/.claude/account-switcher" &&
    assert_rc 0 &&
    assert_eq "$out" "stdin=[] stdout=[] hook=[] extra_op=[] readonly=yes stdout_tty=no ops=[]" "the test-only names in production" &&
    assert_eq "$(< "${AS_TEST_ROOT}/calls.log")" "" "calls.log"
  result "production: planted AS_BIN_CAT, AS_STORE and test-only names (AS_TEST_STDIN_IS_TTY, AS_TEST_STDOUT_IS_TTY, AS_TEST_POLL_HOOK, AS_TEST_PREFS_EXTRA_OP) are ignored: help runs the real commands, each test-only name is empty and readonly, stdout to a file is not a terminal, and the settings write gets no extra op" $?
}

case_prod_version() {
  new_case
  run_switcher_prod version
  assert_rc 0 &&
    assert_eq "$out" "account-switcher ${EXPECT_V}" "version line" &&
    assert_eq "$err" "" "stderr" &&
    assert_eq "$(< "${AS_TEST_ROOT}/calls.log")" "" "calls.log"
  result "production: version prints ${EXPECT_V} with every seam variable planted" $?
}

case_planted_test_mode() {
  new_case
  new_sibling_dir
  # An ordinary shell with AS_TEST_MODE=1 planted and nothing else: no test
  # root, a home outside any test root. Every interlock reference is ${x:-},
  # so this is a refusal (78), not an unbound-variable exit (1).
  (
    cd "$AS_TEST_ROOT" || exit 2
    exec /usr/bin/env -i HOME="$SIBLING_DIR" PATH="$SYSTEM_PATH" AS_TEST_MODE=1 \
      /bin/bash "$SWITCHER" version
  ) > "${AS_TEST_ROOT}/.run-out" 2> "${AS_TEST_ROOT}/.run-err" < /dev/null
  rc=$?
  _read_run "${AS_TEST_ROOT}/.run-out" "${AS_TEST_ROOT}/.run-err"
  refused "AS_TEST_ROOT is not an absolute path"
  result "planted AS_TEST_MODE=1 in a plain environment -> exit 78, one refusal line" $?
}

# ---- Interlock check 1: the scratch root ----------------------------------

case_root_no_sentinel() {
  new_case
  /bin/rm -f "${AS_TEST_ROOT}/.as-test-root"
  run_switcher version
  : > "${AS_TEST_ROOT}/.as-test-root"    # so the case root is cleaned up
  refused "AS_TEST_ROOT has no .as-test-root sentinel"
  result "check 1: a root without the sentinel -> 78" $?
}

# run_with_root <value> <args>: runs the script with AS_TEST_ROOT replaced by
# <value>, from inside the case's real root, then restores AS_TEST_ROOT.
run_with_root() {
  local root="$AS_TEST_ROOT" value="$1"
  shift
  (
    cd "$root" || exit 2
    _child_env
    AS_TEST_ROOT="$value"
    export AS_TEST_ROOT
    exec /bin/bash "$SWITCHER" "$@"
  ) > "${root}/.run-out" 2> "${root}/.run-err" < /dev/null
  rc=$?
  _read_run "${root}/.run-out" "${root}/.run-err"
}

case_root_relative() {
  new_case
  run_with_root "relative/root" version
  refused "AS_TEST_ROOT is not an absolute path"
  result "check 1: a relative AS_TEST_ROOT -> 78" $?
}

case_root_is_slash() {
  new_case
  run_with_root "/" version
  refused "AS_TEST_ROOT is /"
  result "check 1: AS_TEST_ROOT=/ -> 78" $?
}

# ---- Interlock checks 2 and 3: HOME and the fakes directory ----------------

case_home_sibling() {
  new_case
  new_sibling_dir
  export HOME="$SIBLING_DIR"
  run_switcher version
  refused "HOME is not under AS_TEST_ROOT"
  result "check 2: HOME in a sibling of AS_TEST_ROOT -> 78" $?
}

case_fakes_outside() {
  new_case
  new_sibling_dir
  export AS_FAKES_DIR="$SIBLING_DIR"
  run_switcher version
  refused "AS_FAKES_DIR is not under AS_TEST_ROOT"
  result "check 3: AS_FAKES_DIR outside AS_TEST_ROOT -> 78" $?
}

# ---- Interlock checks 4 and 5: every command is a fake of the right class --

case_bin_unset() {
  new_case
  unset AS_BIN_KILL
  run_switcher version
  refused "AS_BIN_KILL is not under AS_FAKES_DIR (got '/bin/kill')"
  result "check 4: AS_BIN_KILL not exported (falls back to /bin/kill) -> 78" $?
}

case_bin_real_path() {
  new_case
  export AS_BIN_PS=/bin/ps
  run_switcher version
  refused "AS_BIN_PS is not under AS_FAKES_DIR (got '/bin/ps')"
  result "check 4: AS_BIN_PS pointed at /bin/ps -> 78" $?
}

case_bin_missing_file() {
  new_case
  export AS_BIN_GREP="${AS_FAKES_DIR}/no-such-fake"
  run_switcher version
  refused "AS_BIN_GREP is not an executable file"
  result "check 4: AS_BIN_GREP naming a missing file -> 78" $?
}

case_kill_passthrough() {
  new_case
  # The kill fake replaced by a pass-through that would run the real kill.
  render_fixture "${LIB_DIR}/fakes/passthrough.sh" "${AS_FAKES_DIR}/kill"
  /bin/chmod 755 "${AS_FAKES_DIR}/kill"
  run_switcher version
  refused "AS_BIN_KILL is a passthrough fake but must be recording"
  result "check 5: a pass-through kill fake -> 78" $?
}

case_rm_unguarded() {
  new_case
  render_fixture "${LIB_DIR}/fakes/passthrough.sh" "${AS_FAKES_DIR}/rm"
  /bin/chmod 755 "${AS_FAKES_DIR}/rm"
  run_switcher version
  refused "AS_BIN_RM is a passthrough fake but must be guarded-passthrough"
  result "check 5: an unguarded rm fake -> 78" $?
}

case_one_line_fake() {
  new_case
  # A one-line fake: the second read hits end-of-file. Must still be a
  # refusal (78), not a set -e exit (1).
  printf '#!/bin/bash' > "${AS_FAKES_DIR}/wc"
  run_switcher version
  refused "AS_BIN_WC has no shebang and as-fake class marker"
  result "check 5: a one-line fake (no class marker) -> 78, not 1" $?
}

# ---- Interlock checks 6 and 7: roots and the keychain service --------------

case_root_outside() {
  new_case
  unset AS_APP_BUNDLE
  run_switcher version
  refused "AS_APP_BUNDLE is not under AS_TEST_ROOT (got '/Applications/Claude.app')"
  result "check 6: AS_APP_BUNDLE not exported (falls back to /Applications) -> 78" $?
}

case_root_dotdot() {
  new_case
  export AS_STORE="${AS_TEST_ROOT}/../elsewhere"
  run_switcher version
  refused "AS_STORE is not under AS_TEST_ROOT"
  result "check 6: AS_STORE climbing out with .. -> 78" $?
}

case_keychain_default() {
  new_case
  # status reads the keychain; with the real service name it must refuse
  # before calling anything, so the security fake is never reached.
  unset AS_KEYCHAIN_SVC
  run_switcher status
  refused "AS_KEYCHAIN_SVC does not begin with as-test- (got 'Claude Code-credentials')"
  result "check 7: status with the default keychain service -> 78, security never called" $?
}

# ---- Interlock check 9: the stdout-is-a-terminal override ---------------------

case_stdout_override_value() {
  new_case
  export AS_TEST_STDOUT_IS_TTY=yes
  run_switcher version
  unset AS_TEST_STDOUT_IS_TTY
  refused "AS_TEST_STDOUT_IS_TTY is not 0 or 1 (got 'yes')"
  result "check 9: AS_TEST_STDOUT_IS_TTY other than 0 or 1 -> 78" $?
}

case_extra_op_value() {
  new_case
  export AS_TEST_PREFS_EXTRA_OP='preferences.bypassPermissionsModeEnabled=true'
  run_switcher version
  unset AS_TEST_PREFS_EXTRA_OP
  refused "AS_TEST_PREFS_EXTRA_OP is not a JSON array (got 'preferences.bypassPermissionsModeEnabled=true')"
  result "check 10: AS_TEST_PREFS_EXTRA_OP that is not a JSON array -> 78" $?
}

# ---- Positive case ------------------------------------------------------------

case_positive() {
  new_case
  set_ps_fixture ps-no-claude.txt
  run_switcher version
  local v_out="$out" v_rc="$rc" v_calls
  v_calls="$(< "${AS_TEST_ROOT}/calls.log")"
  run_switcher list
  assert_eq "$v_rc" "0" "version exit" &&
    assert_eq "$v_out" "account-switcher ${EXPECT_V}" "version line" &&
    assert_eq "$v_calls" "" "calls.log after version" &&
    assert_rc 0 &&
    assert_contains "$out" "(no Claude desktop app instances running)" &&
    assert_called ps $'\t-axww\t-o\tpid=,args=' &&
    assert_called awk "AS_MATCH_BIN"
  result "positive: a complete test environment runs, and list goes through the fakes" $?
}

# ---- Guards inside the fakes ----------------------------------------------

case_kill_stray() {
  new_case
  printf '4242\n' > "${AS_TEST_ROOT}/alive.txt"
  "$AS_BIN_KILL" -0 4242
  local rc_alive=$?
  "$AS_BIN_KILL" -0 4343
  local rc_absent=$?
  "$AS_BIN_KILL" -TERM 4343 2> /dev/null
  local rc_stray=$?
  "$AS_BIN_KILL" -TERM 4242
  local rc_term=$?
  "$AS_BIN_KILL" -0 4242
  local rc_after=$?
  assert_eq "$rc_alive" "0" "kill -0 on a listed PID" &&
    assert_eq "$rc_absent" "1" "kill -0 on an unlisted PID" &&
    assert_eq "$rc_stray" "99" "kill -TERM on an unlisted PID" &&
    assert_called kill $'STRAY\t4343' &&
    assert_eq "$rc_term" "0" "kill -TERM on a listed PID" &&
    assert_eq "$rc_after" "1" "kill -0 after an effective TERM"
  result "kill fake: an unlisted PID is recorded STRAY and exits 99; nothing is signalled" $?
}

case_security_guard() {
  new_case
  "$AS_BIN_SECURITY" find-generic-password -s "Claude Code-credentials" -w > /dev/null 2>&1
  local rc_real=$?
  local json
  json="$("$AS_BIN_SECURITY" find-generic-password -s "$AS_KEYCHAIN_SVC" -w)"
  local rc_test=$?
  assert_eq "$rc_real" "99" "the real service name" &&
    assert_called security $'REFUSED\tClaude Code-credentials' &&
    assert_eq "$rc_test" "0" "a test service name" &&
    assert_eq "$json" "$AS_FIXTURE_KEYCHAIN_JSON" "fake keychain item"
  result "security fake: a non as-test- service exits 99; a test service gets the fake item" $?
}

case_write_guard() {
  new_case
  new_sibling_dir
  local victim="${SIBLING_DIR}/keep-me"
  : > "$victim"
  "$AS_BIN_RM" -f "$victim" 2> /dev/null
  local rc_abs=$?
  "$AS_BIN_RM" -f "${AS_TEST_ROOT}/../${SIBLING_DIR##*/}/keep-me" 2> /dev/null
  local rc_dotdot=$?
  : > "${AS_TEST_ROOT}/scratch-file"
  "$AS_BIN_RM" -f "${AS_TEST_ROOT}/scratch-file"
  local rc_inside=$?
  assert_eq "$rc_abs" "99" "rm of a path outside the root" &&
    assert_eq "$rc_dotdot" "99" "rm of a path climbing out with .." &&
    [[ -f "$victim" ]] &&
    assert_eq "$rc_inside" "0" "rm inside the root" &&
    [[ ! -e "${AS_TEST_ROOT}/scratch-file" ]]
  result "write fakes: a path outside the root (absolute or via ..) is refused, nothing removed" $?
}

case_prod_planted_bin_ignored
case_prod_version
case_planted_test_mode
case_root_no_sentinel
case_root_relative
case_root_is_slash
case_home_sibling
case_fakes_outside
case_bin_unset
case_bin_real_path
case_bin_missing_file
case_kill_passthrough
case_rm_unguarded
case_one_line_fake
case_root_outside
case_root_dotdot
case_keychain_default
case_stdout_override_value
case_extra_op_value
case_positive
case_kill_stray
case_security_guard
case_write_guard
finish
