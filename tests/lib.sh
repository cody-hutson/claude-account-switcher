#!/usr/bin/env bash
# tests/lib.sh - shared helpers for the T1 simulated suite.
#
# Sourced by tests/run.sh and by every tests/t-NN-*.sh file; see
# tests/README.md. Bash 3.2 only: no mapfile, declare -A, [[ -v, ${x^^} or
# readarray.
#
# new_case builds a fresh scratch root for each case and exports
# AS_TEST_MODE=1 plus every seam variable pointing into it:
#   $AS_TEST_ROOT/.as-test-root  sentinel the interlock looks for
#   $AS_TEST_ROOT/home           HOME for the case
#   $AS_TEST_ROOT/fakes          one fake per seamed command (tests/fakes/)
#   $AS_TEST_ROOT/calls.log      one line per fake call
#   $AS_TEST_ROOT/ps.txt         process table the ps fake prints
#   $AS_TEST_ROOT/ps-next.txt    optional table the ps fake installs after
#                                its next call (set_ps_next_fixture)
#   $AS_TEST_ROOT/lsof/<pid>.txt open-file names the lsof fake prints
#   $AS_TEST_ROOT/alive.txt      PIDs the kill fake treats as alive
#   $AS_TEST_ROOT/front.txt      PID of the front application (lsappinfo and
#                                osascript fakes; absent until a rung moves
#                                it, then $AS_FAKE_FRONT_PID, default 400)
#   $AS_TEST_ROOT/Applications/Claude.app/Contents/MacOS/Claude
#                                an empty placeholder for the app's main
#                                binary ($APP_MAIN_BIN), where the matcher
#                                looks (#9)
#   $AS_TEST_ROOT/git-fixture    scratch git repository ($TEST_GIT_ROOT)
#   $AS_TEST_ROOT/tmp            TMPDIR for the script under test
# The harness itself never runs a fake: the fakes directory goes on PATH only
# inside the subshell that runs the script under test.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "tests/lib.sh must be sourced by bash" >&2
  exit 2
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
REPO="$(cd "${LIB_DIR}/.." && pwd)" || exit 2
FIXTURES="${LIB_DIR}/fixtures"
SWITCHER="${REPO}/account-switcher.sh"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
TEST_NAME="${0##*/}"
TEST_NAME="${TEST_NAME%.sh}"

# The invoking user's home, captured before any case replaces HOME. run.sh
# exports it; a test file run on its own captures it here.
: "${TEST_REAL_HOME:=${HOME:-}}"
export TEST_REAL_HOME

pass=0
fail=0
CASE_DIRS=""
out=""
err=""
rc=0

# Commands that get the guarded pass-through fake. The interlock requires
# the write set (RM MV CP RSYNC CHMOD INSTALL MKTEMP MKDIR PLISTBUDDY PLUTIL)
# to be guarded; GIT is guarded as well, so no case can aim git at a path
# outside the scratch root, the real checkout included.
FAKE_GUARDED=" RM MV CP RSYNC CHMOD INSTALL MKTEMP MKDIR PLISTBUDDY PLUTIL GIT "

harness_error() {
  printf 'HARNESS ERROR (%s): %s\n' "$TEST_NAME" "$*" >&2
  exit 2
}

# ---- Reading the seam from the script text (never by running it) ---------

# Prints "NAME PATH" for each `: "${AS_BIN_NAME:=PATH}"` default line.
seam_defaults() {
  local file="${1:-$SWITCHER}" l
  local re='^: "[$][{]AS_BIN_([A-Z0-9]+):=([^}]*)[}]"$'
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $l =~ $re ]]; then
      printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "$file"
}

# Prints the value of the AS_SEAM_BINS assignment.
seam_bins() {
  local file="${1:-$SWITCHER}" l
  local re='^AS_SEAM_BINS="([^"]*)"$'
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ $l =~ $re ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
  return 1
}

# Seam-coverage lint. Prints each executable line outside the seam block that
# names a command by absolute path in the bin/sbin/libexec family (with or
# without /usr or /usr/local), then "count N". Exits 2 when a block marker is
# missing, so a moved block cannot read as clean.
seam_lint() {
  local file="${1:-$SWITCHER}"
  /usr/bin/awk '
    index($0, "# ---- Command paths and roots (test seam)") == 1 { inblock = 1; saw_start = 1; next }
    index($0, "# ---- End of test seam") == 1 { inblock = 0; saw_end = 1; next }
    inblock { next }
    /^[[:space:]]*#/ { next }
    {
      s = " " $0
      n = gsub(/[^A-Za-z0-9_.\/-]\/(usr\/(local\/)?)?(s?bin|libexec)\//, "&", s)
      if (n > 0) { count += n; printf "  line %d: %s\n", NR, $0 }
    }
    END {
      if (!saw_start || !saw_end) { print "seam block markers not found"; exit 2 }
      printf "count %d\n", count
    }
  ' "$file"
}

# Prints "<default-lines> <seam-bins-words>" for the default-count check.
seam_default_counts() {
  local file="${1:-$SWITCHER}" l n_lines=0 words
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ "$l" == ': "${AS_BIN_'* ]] && n_lines=$((n_lines + 1))
  done < "$file"
  words="$(seam_bins "$file")"
  # Word splitting is the point here.
  # shellcheck disable=SC2086
  set -- $words
  printf '%d %d\n' "$n_lines" "$#"
}

# ---- Scratch roots ---------------------------------------------------------

_case_base() {
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  [[ -n "$base" ]] || base="/tmp"
  # A scratch root must never sit under the invoking user's home.
  if [[ -n "$TEST_REAL_HOME" ]]; then
    case "$base" in
      "$TEST_REAL_HOME"|"$TEST_REAL_HOME"/*) base="/tmp" ;;
    esac
  fi
  printf '%s' "$base"
}

# Renders a fixture: copies $1 to $2, writing the case's HOME for __HOME__
# and the case's app bundle ($AS_APP_BUNDLE) for __APP__.
render_fixture() {
  local src="$1" dest="$2" l
  [[ -f "$src" ]] || harness_error "fixture not found: $src"
  : > "$dest" || harness_error "cannot write $dest"
  while IFS= read -r l || [[ -n "$l" ]]; do
    l="${l//__HOME__/$HOME}"
    if [[ "$l" == *__APP__* ]]; then
      [[ -n "${AS_APP_BUNDLE:-}" ]] || harness_error "fixture $src names __APP__ but AS_APP_BUNDLE is unset"
      l="${l//__APP__/$AS_APP_BUNDLE}"
    fi
    printf '%s\n' "$l" >> "$dest"
  done < "$src"
}

# Copies each fake template to $AS_FAKES_DIR/<basename of the real path>,
# writes the real path in place of __AS_REAL__, and exports AS_BIN_<NAME>.
install_fakes() {
  local name path base template l n=0
  /bin/mkdir -p "$AS_FAKES_DIR" || harness_error "cannot create $AS_FAKES_DIR"
  while read -r name path; do
    base="${path##*/}"
    if [[ -f "${LIB_DIR}/fakes/${base}.sh" ]]; then
      template="${LIB_DIR}/fakes/${base}.sh"
    elif [[ "$FAKE_GUARDED" == *" ${name} "* ]]; then
      template="${LIB_DIR}/fakes/guarded-passthrough.sh"
    else
      template="${LIB_DIR}/fakes/passthrough.sh"
    fi
    : > "${AS_FAKES_DIR}/${base}"
    while IFS= read -r l || [[ -n "$l" ]]; do
      printf '%s\n' "${l//__AS_REAL__/$path}" >> "${AS_FAKES_DIR}/${base}"
    done < "$template"
    /bin/chmod 755 "${AS_FAKES_DIR}/${base}" || harness_error "cannot chmod a fake"
    export "AS_BIN_${name}=${AS_FAKES_DIR}/${base}"
    n=$((n + 1))
  done < <(seam_defaults)
  [[ $n -gt 0 ]] || harness_error "no seam defaults found in $SWITCHER"
}

# A scratch git repository with one commit, for cases that need git content
# (point [swap_handoff].git_root at $TEST_GIT_ROOT). Built with no system or
# global git config, so no signing, hook or credential helper runs.
make_git_fixture() {
  TEST_GIT_ROOT="${AS_TEST_ROOT}/git-fixture"
  /bin/mkdir -p "$TEST_GIT_ROOT" || harness_error "cannot create $TEST_GIT_ROOT"
  (
    cd "$TEST_GIT_ROOT" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE XDG_CONFIG_HOME
    GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
    /usr/bin/git -c init.defaultBranch=main init -q . &&
      printf 'scratch fixture\n' > README.txt &&
      /usr/bin/git add README.txt &&
      /usr/bin/git -c user.name=as-test -c user.email=as-test \
        -c commit.gpgsign=false commit -q -m "scratch fixture"
  ) > /dev/null 2>&1 || harness_error "could not create the scratch git fixture"
}

# Starts a case: a fresh scratch root, a scratch HOME, the fakes, the scratch
# git fixture, and every seam variable exported and pointing into the root.
new_case() {
  local base
  base="$(_case_base)"
  AS_TEST_ROOT="$(/usr/bin/mktemp -d "${base}/as-t1.XXXXXX")" || harness_error "mktemp failed under $base"
  CASE_DIRS="${CASE_DIRS}${AS_TEST_ROOT}"$'\n'
  : > "${AS_TEST_ROOT}/.as-test-root" || harness_error "cannot write the sentinel"

  HOME="${AS_TEST_ROOT}/home"
  if [[ -n "$TEST_REAL_HOME" ]]; then
    case "$HOME" in
      "$TEST_REAL_HOME"|"$TEST_REAL_HOME"/*)
        harness_error "a case HOME would sit under the invoking user's home; refusing" ;;
    esac
  fi
  /bin/mkdir -p "$HOME" "${AS_TEST_ROOT}/tmp" || harness_error "cannot create the scratch HOME"
  AS_FAKES_DIR="${AS_TEST_ROOT}/fakes"
  AS_TEST_MODE=1
  export AS_TEST_MODE AS_TEST_ROOT AS_FAKES_DIR HOME
  install_fakes

  AS_STORE="${HOME}/.claude/account-switcher"
  AS_CLAUDE_JSON="${HOME}/.claude.json"
  AS_PROFILE_ROOT="${HOME}/Library/Application Support"
  AS_APP_BUNDLE="${AS_TEST_ROOT}/Applications/Claude.app"
  AS_UPDATER_CACHE="${HOME}/Library/Caches/com.anthropic.claudefordesktop.ShipIt"
  AS_APP_LOG_DIR="${HOME}/Library/Logs/Claude"
  AS_KEYCHAIN_SVC="as-test-credentials"
  export AS_STORE AS_CLAUDE_JSON AS_PROFILE_ROOT AS_APP_BUNDLE AS_UPDATER_CACHE \
    AS_APP_LOG_DIR AS_KEYCHAIN_SVC
  # The app's main binary, where the matcher looks (#9): an empty placeholder,
  # so the commands that refuse when it is missing run. A case removes it to
  # test that refusal.
  APP_MAIN_BIN="${AS_APP_BUNDLE}/Contents/MacOS/Claude"
  /bin/mkdir -p "${APP_MAIN_BIN%/*}" || harness_error "cannot create the app bundle folder"
  : > "$APP_MAIN_BIN" || harness_error "cannot write the app binary placeholder"
  /bin/chmod 755 "$APP_MAIN_BIN" || harness_error "cannot chmod the app binary placeholder"

  AS_FIXTURE_PS="${AS_TEST_ROOT}/ps.txt"
  AS_FIXTURE_PS_AFTER_QUIT="${AS_TEST_ROOT}/ps-after-quit.txt"
  # A JSON document, quotes included, that the security fake prints.
  # shellcheck disable=SC2089
  AS_FIXTURE_KEYCHAIN_JSON='{"claudeAiOauth":{"subscriptionType":"fake","rateLimitTier":"fake"}}'
  # shellcheck disable=SC2090
  export AS_FIXTURE_PS AS_FIXTURE_PS_AFTER_QUIT AS_FIXTURE_KEYCHAIN_JSON
  unset AS_FAKE_QUIT AS_FAKE_KILL_EFFECTIVE AS_FAKE_OPEN_SPAWNS_PID AS_FAKE_OPEN_UDD \
    AS_FAKE_KEYCHAIN AS_FAKE_FRONT_PID AS_FAKE_FRONT_AFTER_SETFRONT \
    AS_FAKE_FRONT_AFTER_APPKIT AS_FAKE_FRONT_AFTER_SYSEVENTS AS_FAKE_ACTIVATE_RC
  : > "$AS_FIXTURE_PS"
  : > "$AS_FIXTURE_PS_AFTER_QUIT"
  /bin/mkdir -p "${AS_TEST_ROOT}/lsof" || harness_error "cannot create the lsof fixture directory"
  : > "${AS_TEST_ROOT}/alive.txt"
  : > "${AS_TEST_ROOT}/calls.log"

  make_git_fixture
  INSTALL_SRC="$REPO"
  out=""
  err=""
  rc=0
}

# Sets SIBLING_DIR to a new directory outside the case's root (for refusal
# cases); it is cleaned up with the case roots.
new_sibling_dir() {
  local base
  base="$(_case_base)"
  SIBLING_DIR="$(/usr/bin/mktemp -d "${base}/as-t1-elsewhere.XXXXXX")" || harness_error "mktemp failed under $base"
  : > "${SIBLING_DIR}/.as-test-sibling"
  CASE_DIRS="${CASE_DIRS}${SIBLING_DIR}"$'\n'
}

# Removes every scratch directory this file created (TEST_KEEP=1 keeps them).
cleanup_cases() {
  local d
  if [[ "${TEST_KEEP:-0}" == "1" ]]; then
    [[ -n "$CASE_DIRS" ]] && printf 'kept scratch directories:\n%s' "$CASE_DIRS"
    CASE_DIRS=""
    return 0
  fi
  while IFS= read -r d; do
    [[ -n "$d" && "$d" == /* ]] || continue
    [[ -f "${d}/.as-test-root" || -f "${d}/.as-test-sibling" ]] || continue
    /bin/chmod -R u+rwX "$d" 2> /dev/null
    /bin/rm -rf "$d"
  done <<< "$CASE_DIRS"
  CASE_DIRS=""
}
trap cleanup_cases EXIT

# Renders tests/fixtures/ps/<name> as the case's process table, lists every
# PID in it as alive, and renders an optional second fixture as the table
# the osascript fake installs on a graceful quit.
set_ps_fixture() {
  local row first=1 alive=""
  render_fixture "${FIXTURES}/ps/$1" "$AS_FIXTURE_PS"
  while IFS= read -r row || [[ -n "$row" ]]; do
    if [[ $first -eq 1 ]]; then first=0; continue; fi
    row="${row#"${row%%[! ]*}"}"
    alive="${alive}${row%% *}"$'\n'
  done < "$AS_FIXTURE_PS"
  printf '%s' "$alive" > "${AS_TEST_ROOT}/alive.txt"
  if [[ -n "${2:-}" ]]; then
    render_fixture "${FIXTURES}/ps/$2" "$AS_FIXTURE_PS_AFTER_QUIT"
  fi
}

# Renders tests/fixtures/ps/<name> as the table the ps fake installs right
# after its next call, so the following call sees a changed process list.
set_ps_next_fixture() {
  render_fixture "${FIXTURES}/ps/$1" "${AS_TEST_ROOT}/ps-next.txt"
}

# set_lsof_fixture <pid> <name>: renders tests/fixtures/lsof/<name> as the
# open-file names (lsof -Fn records) the lsof fake prints for that PID.
set_lsof_fixture() {
  render_fixture "${FIXTURES}/lsof/$2" "${AS_TEST_ROOT}/lsof/$1.txt"
}

# ---- Running the code under test -------------------------------------------

# The environment of the script under test: fakes first on a system PATH (so
# a shebang child resolves /bin/bash), TMPDIR inside the root (macOS mktemp
# ignores it without a template; the mktemp fake supplies one), and git kept
# from walking up out of the root or reading system config.
_child_env() {
  PATH="${AS_FAKES_DIR}:${SYSTEM_PATH}"
  TMPDIR="${AS_TEST_ROOT}/tmp"
  GIT_CEILING_DIRECTORIES="${AS_TEST_ROOT%/*}"
  GIT_CONFIG_NOSYSTEM=1
  export PATH TMPDIR GIT_CEILING_DIRECTORIES GIT_CONFIG_NOSYSTEM
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_GLOBAL XDG_CONFIG_HOME
}

_read_run() {
  out="$(< "$1")"
  if [[ -n "${2:-}" ]]; then err="$(< "$2")"; else err=""; fi
}

# run_switcher <args>: runs account-switcher.sh in test mode under /bin/bash,
# from inside $AS_TEST_ROOT, in a subshell. Sets out (stdout), err (stderr)
# and rc.
run_switcher() {
  local o="${AS_TEST_ROOT}/.run-out" e="${AS_TEST_ROOT}/.run-err"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "$SWITCHER" "$@"
  ) > "$o" 2> "$e" < /dev/null
  rc=$?
  _read_run "$o" "$e"
}

# run_switcher_prod <args>: the same, but with AS_TEST_MODE unset and no
# fakes on PATH, so the script runs in production mode. Every other seam
# variable stays exported (pointing at the fakes) to show they are ignored.
run_switcher_prod() {
  local o="${AS_TEST_ROOT}/.run-out" e="${AS_TEST_ROOT}/.run-err"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    PATH="$SYSTEM_PATH"
    unset AS_TEST_MODE
    exec /bin/bash "$SWITCHER" "$@"
  ) > "$o" 2> "$e" < /dev/null
  rc=$?
  _read_run "$o" "$e"
}

# run_install <args>: runs $INSTALL_SRC/install.sh (default: the repo) under
# /bin/bash with the case's environment. Sets out (stdout and stderr, merged
# as the issue-5 runner captured them) and rc.
run_install() {
  local o="${AS_TEST_ROOT}/.run-out"
  (
    cd "$AS_TEST_ROOT" || exit 2
    _child_env
    exec /bin/bash "${INSTALL_SRC}/install.sh" "$@"
  ) > "$o" 2>&1 < /dev/null
  rc=$?
  _read_run "$o"
}

# ---- Assertions (each prints why on failure and returns 1) -----------------

assert_rc() {
  [[ "$rc" == "$1" ]] && return 0
  printf '    expected exit %s, got %s\n' "$1" "$rc"
  return 1
}

assert_eq() {
  [[ "$1" == "$2" ]] && return 0
  printf '    %s: expected [%s], got [%s]\n' "${3:-value}" "$2" "$1"
  return 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] && return 0
  printf '    expected to contain: %s\n' "$2"
  return 1
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] && return 0
  printf '    expected not to contain: %s\n' "$2"
  return 1
}

# Prints the number of lines in $1 (0 for an empty string).
count_lines() {
  local n=0 l
  if [[ -n "$1" ]]; then
    while IFS= read -r l; do n=$((n + 1)); done <<< "$1"
  fi
  printf '%d' "$n"
}

# calls_of <fake>: prints that fake's lines from calls.log.
calls_of() {
  local fake="$1" l
  [[ -f "${AS_TEST_ROOT}/calls.log" ]] || return 0
  while IFS= read -r l || [[ -n "$l" ]]; do
    case "$l" in
      "$fake"|"$fake"$'\t'*) printf '%s\n' "$l" ;;
    esac
  done < "${AS_TEST_ROOT}/calls.log"
}

# assert_called <fake> <substring>: some call of <fake> contains <substring>
# (arguments are tab-separated in calls.log).
assert_called() {
  local l
  while IFS= read -r l; do
    [[ "$l" == *"${2:-}"* ]] && return 0
  done < <(calls_of "$1")
  printf '    expected a %s call containing: %s\n' "$1" "${2:-}"
  return 1
}

assert_never_called() {
  local calls
  calls="$(calls_of "$1")"
  [[ -z "$calls" ]] && return 0
  printf '    expected no %s call, got:\n%s\n' "$1" "$calls"
  return 1
}

# assert_call_order <first> <second>: the first call of <first> precedes the
# first call of <second>.
assert_call_order() {
  local l n=0 a=0 b=0
  while IFS= read -r l || [[ -n "$l" ]]; do
    n=$((n + 1))
    case "$l" in
      "$1"|"$1"$'\t'*) [[ $a -eq 0 ]] && a=$n ;;
    esac
    case "$l" in
      "$2"|"$2"$'\t'*) [[ $b -eq 0 ]] && b=$n ;;
    esac
  done < "${AS_TEST_ROOT}/calls.log"
  [[ $a -gt 0 && $b -gt 0 && $a -lt $b ]] && return 0
  printf '    expected %s (line %s) before %s (line %s) in calls.log\n' "$1" "$a" "$2" "$b"
  return 1
}

# assert_unchanged <path> <shasum-before>: compare with `shasum < path`.
assert_unchanged() {
  local now
  now="$(/usr/bin/shasum < "$1")"
  [[ "$now" == "$2" ]] && return 0
  printf '    %s changed\n' "$1"
  return 1
}

# tree_digest <dir>: one digest over every name and file content under <dir>.
tree_digest() {
  (
    cd "$1" || exit 1
    LC_ALL=C
    export LC_ALL
    /usr/bin/find . -print | /usr/bin/sort
    /usr/bin/find . -type f -exec /usr/bin/shasum {} + | /usr/bin/sort
  ) | /usr/bin/shasum
}

# assert_tree_unchanged <dir> <tree_digest-before>
assert_tree_unchanged() {
  local now
  now="$(tree_digest "$1")"
  [[ "$now" == "$2" ]] && return 0
  printf '    the tree under %s changed\n' "$1"
  return 1
}

# ---- Results ---------------------------------------------------------------

_show_run() {
  local l n=0
  printf '    last run: exit %s\n' "$rc"
  while IFS= read -r l && [[ $n -lt 15 ]]; do
    printf '    | %s\n' "$l"
    n=$((n + 1))
  done <<< "${out}${err:+$'\n'}${err}"
}

result() {  # $1 = name, $2 = 0 for pass
  if [[ "$2" -eq 0 ]]; then
    printf 'PASS  %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$1"
    _show_run
    fail=$((fail + 1))
  fi
}

finish() {
  cleanup_cases
  printf '%s: %d passed, %d failed\n' "$TEST_NAME" "$pass" "$fail"
  if [[ -n "${TEST_RESULTS:-}" ]]; then
    printf '%s %d %d\n' "$TEST_NAME" "$pass" "$fail" >> "$TEST_RESULTS"
  fi
  if [[ $fail -eq 0 ]]; then exit 0; fi
  exit 1
}
