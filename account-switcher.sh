#!/usr/bin/env bash
# account-switcher.sh - Claude desktop app account switcher
#
# Swap, launch, and manage multiple Claude desktop app accounts via the
# Electron --user-data-dir flag. An earlier CLI-mutation approach was
# removed after a security review; only the Mac-app launcher surface ships.
#
# Subcommands: swap | launch | signin | identity | clone-prefs | prefs | quit | update | reopen | list | status | config | add-account | version | help
#
# Primitives: bash + jq + open + osascript + lsappinfo. No Python, no node.
# No tokens are persisted on disk by this script. OAuth state lives in the
# macOS keychain (CLI surface, when used) or Electron safeStorage per
# user-data-dir (Mac app surface).

set -euo pipefail

# No core dumps (#6): the identity read below has jq parse a profile's
# config.json, which also holds the app's token caches, so a crashing child
# must never write its memory to disk. macOS defaults to this; set it anyway.
ulimit -c 0 2>/dev/null || :

# ---- Command paths and roots (test seam) ---------------------------------
#
# Every external command runs through an AS_BIN_<NAME> variable and every data
# root through an AS_<ROOT> variable, so the test suite under tests/ can point
# them at fakes in a scratch directory. Outside test mode the environment is
# ignored: each seam name is unset, given the absolute path the script has
# always used, and made readonly, so a value planted in the caller's
# environment never reaches a command. Test mode (AS_TEST_MODE=1, which only
# tests/lib.sh sets) honours the environment, but first runs
# _as_test_mode_interlock, which exits 78 unless every seam points into the
# scratch test root. A new command or root joins AS_SEAM_BINS or AS_SEAM_ROOTS,
# with its default line, in the change that first calls it; the coverage lint
# in tests/run.sh fails otherwise.

# Prints one refusal line and exits 78 (EX_CONFIG).
_as_test_refuse() {
  printf 'ERROR: AS_TEST_MODE=1 but %s. Test mode never runs against real state; refusing.\n' "$1" >&2
  exit 78
}

# Returns 0 when path $1 lies strictly under directory $2. The test is
# lexical, so a path with a ".." component is refused outright.
_as_test_under() {
  local path="${1:-}" dir="${2:-}"
  [[ -n "$path" && -n "$dir" ]] || return 1
  case "$path" in
    */../*|*/..|../*|..) return 1 ;;
  esac
  [[ "$path" == "$dir"/?* ]]
}

# Runs only when AS_TEST_MODE=1. Uses builtins only, and every reference is
# written ${name:-}, so a planted AS_TEST_MODE=1 with nothing else set refuses
# with 78 instead of tripping set -u.
_as_test_mode_interlock() {
  local root="${AS_TEST_ROOT:-}" fakes="${AS_FAKES_DIR:-}"
  local danger=" KILL SECURITY OSASCRIPT OPEN PS LSOF LSAPPINFO "
  # PlistBuddy and plutil can rewrite a property list, so they are guarded
  # like the write tools (#10).
  local write=" RM MV CP RSYNC CHMOD INSTALL MKTEMP MKDIR PLISTBUDDY PLUTIL "
  local name var value line1 line2 class need

  # 1. The scratch root: absolute, normalised, not /, a directory, and marked
  #    by the sentinel only tests/lib.sh writes.
  [[ "$root" == /* ]] || _as_test_refuse "AS_TEST_ROOT is not an absolute path (got '${root}')"
  [[ "$root" != "/" ]] || _as_test_refuse "AS_TEST_ROOT is /"
  case "$root" in
    */|*/./*|*/.|*/../*|*/..) _as_test_refuse "AS_TEST_ROOT is not a normalised path (got '${root}')" ;;
  esac
  [[ -d "$root" ]] || _as_test_refuse "AS_TEST_ROOT is not an existing directory (got '${root}')"
  [[ -f "${root}/.as-test-root" ]] || _as_test_refuse "AS_TEST_ROOT has no .as-test-root sentinel (got '${root}')"

  # 2. HOME, and 3. the fakes directory, both under the scratch root.
  _as_test_under "${HOME:-}" "$root" || _as_test_refuse "HOME is not under AS_TEST_ROOT (got '${HOME:-}')"
  _as_test_under "$fakes" "$root" || _as_test_refuse "AS_FAKES_DIR is not under AS_TEST_ROOT (got '${fakes}')"

  # 4. Every command is an executable file in the fakes directory. A name the
  #    harness forgot to export arrives holding its real default (the := lines
  #    run first), so the location test is what catches it.
  # 5. Each fake declares its class on line 2; the danger set must record
  #    without running anything, the write set must guard its paths.
  for name in ${AS_SEAM_BINS:-}; do
    var="AS_BIN_${name}"
    value="${!var:-}"
    [[ -n "$value" ]] || _as_test_refuse "${var} is unset"
    [[ -f "$value" && -x "$value" ]] || _as_test_refuse "${var} is not an executable file (got '${value}')"
    _as_test_under "$value" "$fakes" || _as_test_refuse "${var} is not under AS_FAKES_DIR (got '${value}')"
    [[ -r "$value" ]] || _as_test_refuse "${var} is not readable (got '${value}')"
    line1="" line2=""
    { IFS= read -r line1 || :; IFS= read -r line2 || :; } < "$value"
    case "${line1}|${line2}" in
      '#!'*'|# as-fake: recording') class="recording" ;;
      '#!'*'|# as-fake: guarded-passthrough') class="guarded-passthrough" ;;
      '#!'*'|# as-fake: passthrough') class="passthrough" ;;
      *) _as_test_refuse "${var} has no shebang and as-fake class marker on lines 1 and 2 (got '${value}')" ;;
    esac
    need=""
    case "$danger" in *" ${name} "*) need="recording" ;; esac
    case "$write" in *" ${name} "*) need="guarded-passthrough" ;; esac
    [[ -z "$need" || "$class" == "$need" ]] || _as_test_refuse "${var} is a ${class} fake but must be ${need}"
  done

  # 6. Every data root under the scratch root.
  for name in ${AS_SEAM_ROOTS:-}; do
    var="AS_${name}"
    _as_test_under "${!var:-}" "$root" || _as_test_refuse "${var} is not under AS_TEST_ROOT (got '${!var:-}')"
  done

  # 7. A keychain service name that no real item uses.
  [[ "${AS_KEYCHAIN_SVC:-}" == as-test-* ]] || _as_test_refuse "AS_KEYCHAIN_SVC does not begin with as-test- (got '${AS_KEYCHAIN_SVC:-}')"

  # 8. The per-poll test hook signin (#7) and update (#10) run, when set, is
  #    an executable file under the scratch root.
  if [[ -n "${AS_TEST_POLL_HOOK:-}" ]]; then
    _as_test_under "${AS_TEST_POLL_HOOK:-}" "$root" || _as_test_refuse "AS_TEST_POLL_HOOK is not under AS_TEST_ROOT (got '${AS_TEST_POLL_HOOK:-}')"
    [[ -f "${AS_TEST_POLL_HOOK:-}" && -x "${AS_TEST_POLL_HOOK:-}" ]] || _as_test_refuse "AS_TEST_POLL_HOOK is not an executable file (got '${AS_TEST_POLL_HOOK:-}')"
  fi

  # 9. The stdout-is-a-terminal override `identity --show-ids` reads (#6),
  #    when set, is 0 or 1.
  case "${AS_TEST_STDOUT_IS_TTY:-}" in
    ""|0|1) ;;
    *) _as_test_refuse "AS_TEST_STDOUT_IS_TTY is not 0 or 1 (got '${AS_TEST_STDOUT_IS_TTY:-}')" ;;
  esac

  # 10. The settings write's extra op (#11, F-06), when set, is one JSON
  #     array (the op [path, value]).
  case "${AS_TEST_PREFS_EXTRA_OP:-}" in
    ""|"["*"]") ;;
    *) _as_test_refuse "AS_TEST_PREFS_EXTRA_OP is not a JSON array (got '${AS_TEST_PREFS_EXTRA_OP:-}')" ;;
  esac
}

AS_SEAM_BINS="AWK BASENAME CAT CHMOD COMMAND CP DATE DU GIT GREP HEAD INSTALL JQ KILL LSAPPINFO LSOF MKDIR MKTEMP MV OD OPEN OSASCRIPT PLISTBUDDY PLUTIL PS PYTHON3 RM RSYNC SECURITY SED SHASUM SLEEP TAIL TR WC"
AS_SEAM_ROOTS="STORE CLAUDE_JSON PROFILE_ROOT APP_BUNDLE UPDATER_CACHE APP_LOG_DIR"
# Test-only names, honoured only in test mode like every seam name:
# AS_TEST_STDIN_IS_TTY=1 makes stdin count as a terminal (signin #7, update
# #10, prefs #11); AS_TEST_STDOUT_IS_TTY=1 makes stdout count as one
# (identity --show-ids, #6); AS_TEST_POLL_HOOK names a scratch script
# signin and update run once per poll, so a case can change the scenario
# between polls; and AS_TEST_PREFS_EXTRA_OP is one more [path, value] op the
# settings write applies, so a case can reach its "differs outside the
# allowlisted keys" check, which nothing else can (#11).
if [[ "${AS_TEST_MODE:-0}" != "1" ]]; then
  # Production: the environment is ignored.
  for _n in $AS_SEAM_BINS; do unset "AS_BIN_${_n}"; done
  for _n in $AS_SEAM_ROOTS; do unset "AS_${_n}"; done
  unset _n AS_TEST_ROOT AS_FAKES_DIR AS_KEYCHAIN_SVC AS_TEST_STDIN_IS_TTY AS_TEST_STDOUT_IS_TTY AS_TEST_POLL_HOOK AS_TEST_PREFS_EXTRA_OP
fi
: "${AS_BIN_AWK:=/usr/bin/awk}"
: "${AS_BIN_BASENAME:=/usr/bin/basename}"
: "${AS_BIN_CAT:=/bin/cat}"
: "${AS_BIN_CHMOD:=/bin/chmod}"
: "${AS_BIN_COMMAND:=/usr/bin/command}"
: "${AS_BIN_CP:=/bin/cp}"
: "${AS_BIN_DATE:=/bin/date}"
: "${AS_BIN_DU:=/usr/bin/du}"
: "${AS_BIN_GIT:=/usr/bin/git}"
: "${AS_BIN_GREP:=/usr/bin/grep}"
: "${AS_BIN_HEAD:=/usr/bin/head}"
: "${AS_BIN_INSTALL:=/usr/bin/install}"
: "${AS_BIN_JQ:=/usr/bin/jq}"
: "${AS_BIN_KILL:=/bin/kill}"
: "${AS_BIN_LSAPPINFO:=/usr/bin/lsappinfo}"
: "${AS_BIN_LSOF:=/usr/sbin/lsof}"
: "${AS_BIN_MKDIR:=/bin/mkdir}"
: "${AS_BIN_MKTEMP:=/usr/bin/mktemp}"
: "${AS_BIN_MV:=/bin/mv}"
: "${AS_BIN_OD:=/usr/bin/od}"
: "${AS_BIN_OPEN:=/usr/bin/open}"
: "${AS_BIN_OSASCRIPT:=/usr/bin/osascript}"
: "${AS_BIN_PLISTBUDDY:=/usr/libexec/PlistBuddy}"
: "${AS_BIN_PLUTIL:=/usr/bin/plutil}"
: "${AS_BIN_PS:=/bin/ps}"
: "${AS_BIN_PYTHON3:=/usr/bin/python3}"
: "${AS_BIN_RM:=/bin/rm}"
: "${AS_BIN_RSYNC:=/usr/bin/rsync}"
: "${AS_BIN_SECURITY:=/usr/bin/security}"
: "${AS_BIN_SED:=/usr/bin/sed}"
: "${AS_BIN_SHASUM:=/usr/bin/shasum}"
: "${AS_BIN_SLEEP:=/bin/sleep}"
: "${AS_BIN_TAIL:=/usr/bin/tail}"
: "${AS_BIN_TR:=/usr/bin/tr}"
: "${AS_BIN_WC:=/usr/bin/wc}"
: "${AS_STORE:=${HOME}/.claude/account-switcher}"
: "${AS_CLAUDE_JSON:=${HOME}/.claude.json}"
: "${AS_PROFILE_ROOT:=${HOME}/Library/Application Support}"
: "${AS_APP_BUNDLE:=/Applications/Claude.app}"
: "${AS_UPDATER_CACHE:=${HOME}/Library/Caches/com.anthropic.claudefordesktop.ShipIt}"
: "${AS_APP_LOG_DIR:=${HOME}/Library/Logs/Claude}"
: "${AS_KEYCHAIN_SVC:=Claude Code-credentials}"
if [[ "${AS_TEST_MODE:-0}" == "1" ]]; then _as_test_mode_interlock; fi
readonly AS_BIN_AWK AS_BIN_BASENAME AS_BIN_CAT AS_BIN_CHMOD AS_BIN_COMMAND \
  AS_BIN_CP AS_BIN_DATE AS_BIN_DU AS_BIN_GIT AS_BIN_GREP \
  AS_BIN_HEAD AS_BIN_INSTALL AS_BIN_JQ AS_BIN_KILL AS_BIN_LSAPPINFO AS_BIN_LSOF \
  AS_BIN_MKDIR AS_BIN_MKTEMP AS_BIN_MV AS_BIN_OD \
  AS_BIN_OPEN AS_BIN_OSASCRIPT AS_BIN_PLISTBUDDY AS_BIN_PLUTIL AS_BIN_PS AS_BIN_PYTHON3 \
  AS_BIN_RM AS_BIN_RSYNC AS_BIN_SECURITY AS_BIN_SED AS_BIN_SHASUM AS_BIN_SLEEP AS_BIN_TAIL \
  AS_BIN_TR AS_BIN_WC
readonly AS_STORE AS_CLAUDE_JSON AS_PROFILE_ROOT AS_APP_BUNDLE AS_UPDATER_CACHE \
  AS_APP_LOG_DIR AS_KEYCHAIN_SVC
AS_TEST_STDIN_IS_TTY="${AS_TEST_STDIN_IS_TTY:-}"
AS_TEST_STDOUT_IS_TTY="${AS_TEST_STDOUT_IS_TTY:-}"
AS_TEST_POLL_HOOK="${AS_TEST_POLL_HOOK:-}"
AS_TEST_PREFS_EXTRA_OP="${AS_TEST_PREFS_EXTRA_OP:-}"
readonly AS_TEST_STDIN_IS_TTY AS_TEST_STDOUT_IS_TTY AS_TEST_POLL_HOOK AS_TEST_PREFS_EXTRA_OP

# ---- End of test seam -----------------------------------------------------

# No tracing past this point, whatever turned it on: bash -x, an exported
# SHELLOPTS that holds xtrace, or a BASH_ENV that sets -x. A trace would print
# the sign-in salt and digests (#7), the account id #6 reads from a profile,
# and the keychain value status reads, since each passes through a shell
# variable or a traced command line. Unconditional: there is no debug
# opt-in. The seam block above holds none of these, so tracing it is harmless.
{ set +x; } 2>/dev/null

# ---- Constants & paths ---------------------------------------------------

# Bump on every change to this script. `install.sh --check` reads this line
# from both the repo copy and the installed copy (without running either), so
# keep it a single `readonly VERSION="..."` assignment.
readonly VERSION="11.1.0"

readonly STORE="${AS_STORE}"
readonly CLAUDE_JSON="${AS_CLAUDE_JSON}"
readonly KEYCHAIN_SVC="${AS_KEYCHAIN_SVC}"
readonly CONFIG_FILE="${STORE}/config.toml"
readonly STATUSLINE_MARKER="${STORE}/.statusline-marker"
readonly SWAP_LOG="${STORE}/swap-history.log"

# ---- Output helpers ------------------------------------------------------

die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
info() { printf '\033[36m[switcher]\033[0m %s\n' "$*" >&2; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }

# ---- Validation helpers (input validation) -------------------------------

# H-1: Reject tags that don't match [a-z0-9-]{1,32}, or start with '-', or
# contain path-traversal sequences. Applied at every launcher entry point
# that constructs filesystem paths from the tag.
validate_tag() {
  local tag="$1"
  if [[ -z "$tag" ]]; then
    die "Tag must not be empty."
  fi
  if [[ "$tag" =~ ^- ]]; then
    die "Tag must not start with '-' (got: '${tag}')."
  fi
  if [[ ! "$tag" =~ ^[a-z0-9-]{1,32}$ ]]; then
    die "Tag must match [a-z0-9-]{1,32} (got: '${tag}'). Tags only contain lowercase a-z, digits, and hyphens."
  fi
}

# M-1: Reject argv tokens containing shell metacharacters that could escape
# script context if any subcommand handler later constructs a shell command
# from them. Layered defence with the slash command's "$ARGUMENTS" quoting.
validate_argv_safe() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *';'*|*'&'*|*'|'*|*'`'*|*'$('*|*'>'*|*'<'*|*$'\n'*|*$'\r'*)
        die "Argument contains shell metacharacters (got: '${arg}'). Refusing for safety."
        ;;
    esac
  done
}

# M-1 relaxed: softer validation for operator-supplied
# free-form note values passed via --note. Notes are stored verbatim as
# markdown content in SWAP_HANDOFF.md — never used as shell commands or
# argv to subprocesses. Allow ;, &, |, <, > (common in prose; e.g.,
# "hit limit; need to swap") but still block genuine shell-injection
# patterns (backticks for command substitution, $( substitution, newlines
# that would break markdown formatting).
validate_note_safe() {
  local note="$1"
  case "$note" in
    *'`'*|*'$('*|*$'\n'*|*$'\r'*)
      die "Note contains unsafe characters (backtick, \$(, or embedded newline). Refusing for safety. Use plain prose only — punctuation like ; and | is allowed."
      ;;
  esac
}

# ---- Log rotation (M-13) -------------------------------------------------

# Trim swap-history.log to last 1000 lines if total exceeds 1100. Older
# content moves to swap-history.log.1 (single-file rotation). Called once
# per script invocation (at script entry).
rotate_swap_log_if_needed() {
  [[ -f "$SWAP_LOG" ]] || return 0
  local total
  total=$("$AS_BIN_WC" -l < "$SWAP_LOG" 2>/dev/null | "$AS_BIN_TR" -d ' ')
  [[ -n "$total" ]] || return 0
  if [[ "$total" -gt 1100 ]]; then
    local tmp
    tmp="$("$AS_BIN_MKTEMP")"
    "$AS_BIN_TAIL" -n 1000 "$SWAP_LOG" > "$tmp"
    "$AS_BIN_MV" -f "$SWAP_LOG" "${SWAP_LOG}.1"
    "$AS_BIN_MV" -f "$tmp" "$SWAP_LOG"
    "$AS_BIN_CHMOD" 600 "$SWAP_LOG"
  fi
}

# ---- Store and history-log modes (S-06) ------------------------------------
#
# No global umask: it would also change the mode of the profile files the app
# owns that the switcher rewrites. Instead the two things the switcher may
# create in its store get their modes where they are created: the store
# folder 700, and swap-history.log 600 (a umask inside a subshell, for that
# one empty file). _swap_log_ensure runs before every row is appended, so the
# first row never creates the log with the caller's umask.

_swap_log_ensure() {
  if [[ -d "$STORE" && ! -e "$SWAP_LOG" ]]; then
    ( umask 077 && : >> "$SWAP_LOG" ) 2>/dev/null || :
  fi
  return 0
}

# _store_ensure: creates the store (mode 700) when it is missing; returns 1
# when it can't.
_store_ensure() {
  if [[ ! -d "$STORE" ]]; then "$AS_BIN_MKDIR" -p -m 700 "$STORE" 2>/dev/null || return 1; fi
  return 0
}

# ---- TOML reader (hand-rolled; supports flat and one-level table.key) ----

toml_get() {
  local key="$1"
  local file="${CONFIG_FILE}"
  [[ -f "$file" ]] || return 1

  if [[ "$key" == *.* ]]; then
    local table="${key%%.*}"
    local subkey="${key#*.}"
    "$AS_BIN_AWK" -v table="[${table}]" -v sk="${subkey}" '
      BEGIN { in_t = 0 }
      /^\[/  { in_t = ($0 == table); next }
      in_t && $0 ~ "^"sk"[[:space:]]*=" {
        sub("^"sk"[[:space:]]*=[[:space:]]*", ""); sub("[[:space:]]*$", "")
        gsub("^\"|\"$", ""); print; exit
      }
    ' "$file"
  else
    "$AS_BIN_AWK" -v sk="${key}" '
      /^\[/ { exit }
      $0 ~ "^"sk"[[:space:]]*=" {
        sub("^"sk"[[:space:]]*=[[:space:]]*", ""); sub("[[:space:]]*$", "")
        gsub("^\"|\"$", ""); print; exit
      }
    ' "$file"
  fi
}

# ---- Tag resolution ------------------------------------------------------

# Resolves a switcher tag for the given oauth email by scanning [accounts]
# in config.toml for a matching profile_email. Returns the tag, or
# "(unmatched)" when no entry matches. BSD-awk compatible.
resolve_tag_from_email() {
  local email="$1"
  [[ -f "$CONFIG_FILE" ]] || { printf '(unmatched)\n'; return; }
  "$AS_BIN_AWK" -v email="$email" '
    /^\[accounts\]/ { in_a = 1; next }
    /^\[/           { in_a = 0 }
    in_a && /profile_email/ {
      tag = $0; sub(/[[:space:]]*=.*$/, "", tag)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", tag)
      e = $0; sub(/.*profile_email[[:space:]]*=[[:space:]]*"/, "", e); sub(/".*/, "", e)
      if (e == email) { print tag; matched = 1; exit }
    }
    END { if (!matched) print "(unmatched)" }
  ' "$CONFIG_FILE"
}

# Returns 0 if the given tag has an entry in [accounts] of config.toml,
# 1 otherwise. Used by cmd_swap_app to warn when target tag is unregistered
# and by cmd_add_account to detect duplicate registration. No code path
# writes to [accounts] implicitly; cmd_add_account provides the explicit
# registration path.
tag_is_in_accounts() {
  local tag="$1"
  [[ -f "$CONFIG_FILE" ]] || return 1
  "$AS_BIN_AWK" -v tag="$tag" '
    /^\[accounts\]/ { in_a = 1; next }
    /^\[/           { in_a = 0 }
    in_a && $0 ~ "^"tag"[[:space:]]*=" { print "FOUND"; exit }
  ' "$CONFIG_FILE" | "$AS_BIN_GREP" -qx "FOUND"
}

# ---- Process helpers (M-12, #9) ------------------------------------------
#
# Every running-instance check goes through one matcher, _claude_main_rows:
# get_claude_pids (and so quit_all_claude), is_tag_running (clone-prefs),
# detect_running_tag (the swap handoff) and cmd_list_instances.
#
# A process is a Claude main process only when its argv[0] equals the app's
# main binary, "${AS_APP_BUNDLE}/Contents/MacOS/Claude", exactly. A substring
# of the whole command line is not enough: helper processes, and any other
# process whose arguments merely mention the path, are not main processes.
# argv[0] is read from the same `ps -o args` row that carries the
# --user-data-dir value, so identity and profile come from one read; the
# row is argv joined by spaces, so "argv[0] is the binary" means the row
# equals the binary path or begins with it followed by a space.
#
# awk reads the whole process table and nothing in the chain exits early,
# so a large table cannot close the pipe under pipefail.

# Prints one raw row per Claude main process: pid<TAB>KIND<TAB>method, where
# KIND is primary or <tag> (method argv) when --user-data-dir names exactly
# <root>/Claude or <root>/Claude-<tag>; FLAGLESS (method flagless) when the
# process has no --user-data-dir; UNRESOLVED (method none) otherwise. The
# value keeps its spaces ("Application Support"). A folder is compared whole:
# <root>/Claude never matches <root>/Claude-<tag>, and tag-a never matches
# tag-a-2. Returns the pipeline's status: non-zero when ps failed.
_claude_main_rows() {
  "$AS_BIN_PS" -axww -o pid=,args= 2>/dev/null \
    | AS_MATCH_BIN="${AS_APP_BUNDLE}/Contents/MacOS/Claude" AS_MATCH_ROOT="${AS_PROFILE_ROOT}" \
      "$AS_BIN_AWK" '
      {
        pid = $1
        if (pid !~ /^[0-9]+$/) next
        a = $0
        sub(/^[ \t]*[0-9]+[ \t]/, "", a)
        bin = ENVIRON["AS_MATCH_BIN"]
        if (a == bin) rest = ""
        else if (index(a, bin " ") == 1) rest = substr(a, length(bin) + 1)
        else next
        i = index(rest, " --user-data-dir=")
        if (i == 0) {
          if (index(rest, " --user-data-dir") > 0) print pid "\tUNRESOLVED\tnone"
          else print pid "\tFLAGLESS\tflagless"
          next
        }
        v = substr(rest, i + 17)
        if (index(v, " --user-data-dir") > 0) { print pid "\tUNRESOLVED\tnone"; next }
        j = index(v, " --")
        if (j) v = substr(v, 1, j - 1)
        root = ENVIRON["AS_MATCH_ROOT"]
        if (v == root "/Claude") { print pid "\tprimary\targv"; next }
        if (index(v, root "/Claude-") == 1) {
          t = substr(v, length(root) + 9)
          if (t ~ /^[a-z0-9][a-z0-9-]*$/ && length(t) <= 32 && t != "primary" && t != "default") {
            print pid "\t" t "\targv"
            next
          }
        }
        print pid "\tUNRESOLVED\tnone"
      }'
}

# Prints "Claude" or "Claude-<tag>" when process $1 holds files open under
# exactly one profile folder of AS_PROFILE_ROOT; otherwise nothing. Reads
# file NAMES from lsof's -Fn records only, never file contents, and prints
# only the folder name, never a path under it. The first path component is
# compared whole, so a file under Claude-<tag>/ never counts as Claude.
lsof_profile_root() {
  "$AS_BIN_LSOF" -w -Fn -p "$1" 2>/dev/null \
    | AS_MATCH_ROOT="${AS_PROFILE_ROOT}/" "$AS_BIN_AWK" '
      substr($0, 1, 1) == "n" {
        p = substr($0, 2)
        r = ENVIRON["AS_MATCH_ROOT"]
        if (index(p, r) == 1) {
          split(substr(p, length(r) + 1), c, "/")
          t = substr(c[1], 8)
          if (c[1] == "Claude" || (c[1] ~ /^Claude-[a-z0-9][a-z0-9-]*$/ && length(t) <= 32 && t != "primary" && t != "default")) seen[c[1]] = 1
        }
      }
      END { n = 0; for (k in seen) { n++; last = k }; if (n == 1) print last }'
  return 0
}

# Prints the final row for process $1 from the profile folder it holds open.
_resolve_by_open_files() {
  local root
  root="$(lsof_profile_root "$1")"
  case "$root" in
    Claude)    printf '%s\tprimary\tlsof\n' "$1" ;;
    Claude-?*) printf '%s\t%s\tlsof\n' "$1" "${root#Claude-}" ;;
    *)         printf '%s\tunknown\tnone\n' "$1" ;;
  esac
}

# Prints one row per Claude main process: pid<TAB>profile<TAB>method
#   profile: primary | <tag> | unknown      method: argv | flagless | lsof | none
# A process without --user-data-dir is primary (the switcher launches primary
# without the flag) only when it is the one such process and no other
# process names primary's folder. Otherwise each flagless process, and each
# process whose --user-data-dir names no configured profile folder, is
# resolved by the profile folder it holds open (lsof), or reported unknown.
# No row ever reads primary without one of those three reasons. An empty
# table means no instance is running. Returns 2, printing nothing, when the
# process table could not be read.
claude_instances() {
  local raw st=0
  raw="$(_claude_main_rows)" || st=$?
  [[ $st -eq 0 ]] || return 2
  _claude_instances_from "$raw"
}

# _claude_instances_from <raw rows>: the second half of claude_instances, for
# a caller that also needs the raw rows (the settings sync's running check,
# #11, counts the raw FLAGLESS rows from the same read).
_claude_instances_from() {
  local raw="$1" pid kind method flagless=0 argv_primary=0
  while IFS=$'\t' read -r pid kind method; do
    case "$kind" in
      FLAGLESS) flagless=$((flagless + 1)) ;;
      primary)  argv_primary=1 ;;
    esac
  done <<< "$raw"
  while IFS=$'\t' read -r pid kind method; do
    [[ -n "$pid" ]] || continue
    case "$kind" in
      FLAGLESS)
        if [[ $flagless -eq 1 && $argv_primary -eq 0 ]]; then
          printf '%s\tprimary\tflagless\n' "$pid"
        else
          _resolve_by_open_files "$pid"
        fi
        ;;
      UNRESOLVED) _resolve_by_open_files "$pid" ;;
      *)          printf '%s\t%s\t%s\n' "$pid" "$kind" "$method" ;;
    esac
  done <<< "$raw"
  return 0
}

# Returns newline-separated PIDs of running Claude main processes, from the
# matcher above: helpers and processes that only mention the app path are
# never included, so quit_all_claude never signals them. Used in place of
# `pkill -f`. Always returns 0: callers detect "no Claude running" via empty
# stdout, not via exit status (under set -euo pipefail a failing assignment
# would end the script).
get_claude_pids() {
  local raw="" pid rest
  raw="$(_claude_main_rows)" || true
  while IFS=$'\t' read -r pid rest; do
    if [[ -n "$pid" ]]; then printf '%s\n' "$pid"; fi
  done <<< "$raw"
  return 0
}

# Send the given signal to all running Claude main PIDs (best-effort).
kill_claude_processes() {
  local sig="${1:-TERM}"
  local pids
  pids=$(get_claude_pids)
  [[ -z "$pids" ]] && return 0
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    "$AS_BIN_KILL" "-${sig}" "$pid" 2>/dev/null || true
  done <<< "$pids"
}

# is_tag_running <tag>: whether an instance of <tag> is running, from the
# matcher above ("default" is primary).
#   0  a running instance's profile is <tag>
#   1  none is, and every running instance's profile is known
#   2  none is, but some instance's profile is unknown, or the process
#      table could not be read: undetermined
# clone-prefs treats 2 as "refuse and say why"; swap proceeds, because it
# quits every instance first. Call it as `is_tag_running "$t" || rs=$?`: a
# bare call that returns 1 or 2 ends the script under set -e.
#
# This replaces is_instance_running_for_udd, whose live defect was a
# substring match of "--user-data-dir=<folder>" against each command line:
# primary's folder is a prefix of every Claude-<tag> folder, and primary is
# launched without the flag, so primary read as running whenever another
# tag was open and as not running when only primary was; tag alt matched
# alt-2 the same way. Its last reader was also `grep -q`, which closes the
# pipe on its first match; under pipefail that can turn a found instance
# into "not running", but only once the filtered lines outgrow one pipe
# buffer, which a real process table does not reach.
is_tag_running() {
  local want="$1" rows st=0 pid profile method unknown=0
  [[ "$want" == "default" ]] && want="primary"
  rows="$(claude_instances)" || st=$?
  [[ $st -eq 0 ]] || return 2
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    if [[ "$profile" == "$want" ]]; then return 0; fi
    if [[ "$profile" == "unknown" ]]; then unknown=1; fi
  done <<< "$rows"
  if [[ $unknown -eq 1 ]]; then return 2; fi
  return 1
}

# ---- Where detection looks for the app (#9) --------------------------------
#
# _claude_main_rows recognises a Claude main process only by its argv[0],
# the app's main binary under AS_APP_BUNDLE, which outside test mode is fixed
# at the default install location. With the app installed anywhere else,
# every running check would read "nothing running". So every command whose
# safety rests on knowing whether a profile is running (swap, quit,
# clone-prefs, signin, update and the writing prefs verbs) refuses, before it
# captures, quits, opens or writes any profile, when that binary isn't there,
# naming the path it expected, through its own refusal and exit code. (For
# swap, quit and clone-prefs, main may trim the switcher's own history log
# first; that touches no profile, handoff or app state.) The
# read-only reports (list, identity, status, prefs diff, prefs sync
# --dry-run) and launch, which uses the matcher only to find the new window
# for its report, print one warning line and carry on. version and help read
# no process table and report no running state, so they say nothing.

readonly APP_MAIN_BIN="${AS_APP_BUNDLE}/Contents/MacOS/Claude"

# Returns 0 when the app's main binary is where detection looks.
app_binary_present() { [[ -f "$APP_MAIN_BIN" ]]; }

# app_binary_refusal <what was not done>: the refusal text, without the
# ERROR prefix (each command prints it through its own refusal).
app_binary_refusal() {
  printf "The Claude app's main binary is not at %s, which is where the switcher looks to tell which profiles are running, so it can't tell whether a profile is running. Nothing was %s. If Claude is installed somewhere else, move it there." \
    "$APP_MAIN_BIN" "$1"
}

# One warning line when the binary is missing; always returns 0.
app_binary_warn() {
  app_binary_present && return 0
  warn "The Claude app's main binary is not at ${APP_MAIN_BIN}, where the switcher looks for running instances, so an instance of an app installed elsewhere is not seen as running."
  return 0
}

# ---- Mac app surface -----------------------------------------------------

# Compute the user-data-dir for a profile tag.
# - "primary" / "default" → ~/Library/Application Support/Claude
#                           (default Mac app dir; preserves existing chat history)
# - any other tag         → ~/Library/Application Support/Claude-<tag>
#                           (isolated; first launch prompts login)
udd_for_tag() {
  local tag="$1"
  if [[ "$tag" == "primary" ]] || [[ "$tag" == "default" ]]; then
    printf '%s' "${AS_PROFILE_ROOT}/Claude"
  else
    printf '%s' "${AS_PROFILE_ROOT}/Claude-${tag}"
  fi
}

# ---- Account identity per tag (#6) ---------------------------------------
#
# Each profile's config.json records the account the profile last signed
# into (lastKnownAccountUuid). The operator pins the account each tag must
# hold in the [identity] table of config.toml (`identity pin <tag>`), and
# launch, swap and the read-only `identity` command compare the two.
# Output names labels, plus at most the last 4 hex digits of an id, never a
# whole id (`identity --show-ids` prints whole ids, and only when stdout is
# a terminal). History rows carry a tag and a status word, never an id or a
# label.

readonly AS_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Prints the error and exits 2: the identity commands' "cannot run" status,
# kept apart from die's 1, which `identity` uses for a MISMATCH.
_die2() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 2; }

# profile_account_uuid <user-data-dir>
# Prints the account id the profile records, as a 36-character lowercase
# uuid, and returns 0. Otherwise prints nothing and returns:
#   1  config.json is absent or unreadable
#   2  it did not parse on two reads, or its top level is not one object
#   3  it records no id (the key is absent, or not a string)
#   4  the recorded value is not uuid-shaped
#
# Security (#6): the same file holds the app's token caches. jq opens it
# read-only, in place, and only the one selected value crosses the pipe, so
# no shell variable ever holds the file's contents, and the filter lets
# nothing longer than 36 characters through. Never read the file with cat or
# $(<...), never copy it, never pass it through a second filter, and never
# trace this function with set -x. Nothing else in the profile (Cookies,
# Local Storage, IndexedDB) and no keychain item is opened. jq's errors go to
# /dev/null; they name a position in the file, never a value.
profile_account_uuid() {
  local f="${1:-}/config.json" v="" try=1 parsed=0
  [[ -f "$f" && -r "$f" ]] || return 1
  while [[ $try -le 2 ]]; do
    if [[ -s "$f" ]] && v="$("$AS_BIN_JQ" -r '
        if type != "object" then "N"
        elif (.lastKnownAccountUuid | type) != "string" then empty
        elif (.lastKnownAccountUuid | length) != 36 then "X"
        else .lastKnownAccountUuid | ascii_downcase end' "$f" 2>/dev/null)"; then
      parsed=1
      break
    fi
    v=""
    # The app rewrites config.json while it runs (a journal, then a rename),
    # so a read can land on a torn or empty file: one retry, a second later.
    if [[ $try -eq 1 ]]; then "$AS_BIN_SLEEP" 1; fi
    try=$((try + 1))
  done
  [[ $parsed -eq 1 ]] || return 2
  case "$v" in
    "")      return 3 ;;
    N|*$'\n'*) return 2 ;;
  esac
  [[ "$v" =~ $AS_UUID_RE ]] || return 4
  printf '%s' "$v"
}

# Prints $1 with A-F lowercased when the result is uuid-shaped; returns 1
# otherwise. The value travels on stdin, never on a command line.
_uuid_shaped() {
  local v=""
  v="$(printf '%s' "${1:-}" | "$AS_BIN_TR" 'A-F' 'a-f')" || return 1
  [[ "$v" =~ $AS_UUID_RE ]] || return 1
  printf '%s' "$v"
}

# The [accounts] and [identity] key for a tag: "default" is primary, as in
# udd_for_tag and is_tag_running.
identity_key() {
  if [[ "${1:-}" == "default" ]]; then printf 'primary'; else printf '%s' "${1:-}"; fi
}

# expected_account_uuid <tag>: prints the id pinned to <tag> in [identity]
# (read with toml_get), or returns 1 when there is no uuid-shaped pin.
expected_account_uuid() {
  local v=""
  v="$(toml_get "identity.$(identity_key "${1:-}")" 2>/dev/null)" || return 1
  _uuid_shaped "$v"
}

# Prints the key of each line of [identity], one per line. The header must be
# exactly "[identity]", which is how toml_get finds the table.
identity_pinned_tags() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  "$AS_BIN_AWK" '
    /^\[/ { in_t = ($0 == "[identity]"); next }
    in_t && /^[a-z0-9][a-z0-9-]*[[:space:]]*=/ { k = $0; sub(/[[:space:]]*=.*$/, "", k); print k }
  ' "$CONFIG_FILE"
}

# pinned_tag_for_id <id> <tag>: prints the first tag other than <tag> whose
# pin equals <id>, or nothing.
pinned_tag_for_id() {
  local id="${1:-}" self keys k pin
  self="$(identity_key "${2:-}")"
  keys="$(identity_pinned_tags)" || keys=""
  # Keys are [a-z0-9-] only (the awk pattern above), so splitting is exact.
  for k in $keys; do
    if [[ "$k" == "$self" ]]; then continue; fi
    pin="$(expected_account_uuid "$k")" || continue
    if [[ "$pin" == "$id" ]]; then
      printf '%s' "$k"
      return 0
    fi
  done
  return 0
}

# Prints the tag of each entry in [accounts], one per line. Comment lines,
# such as the template's placeholder, are skipped.
accounts_tags() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  "$AS_BIN_AWK" '
    /^\[/ { in_a = ($0 ~ /^\[accounts\]/); next }
    in_a && /^[a-z0-9][a-z0-9-]*[[:space:]]*=/ { k = $0; sub(/[[:space:]]*=.*$/, "", k); print k }
  ' "$CONFIG_FILE"
}

# account_label <tag>: prints the label of the tag's [accounts] entry, or the
# tag itself when there is none.
account_label() {
  local key l=""
  key="$(identity_key "${1:-}")"
  if [[ -f "$CONFIG_FILE" ]]; then
    l="$("$AS_BIN_AWK" -v tag="$key" '
      /^\[/ { in_a = ($0 ~ /^\[accounts\]/); next }
      in_a && $0 ~ "^"tag"[[:space:]]*=" {
        if (match($0, /label[[:space:]]*=[[:space:]]*"[^"]*"/)) {
          v = substr($0, RSTART, RLENGTH)
          sub(/^label[[:space:]]*=[[:space:]]*"/, "", v); sub(/"$/, "", v)
          print v
        }
        exit
      }' "$CONFIG_FILE")" || l=""
  fi
  printf '%s' "${l:-$key}"
}

# identity_status <tag>
# Compares the account <tag>'s profile records (profile_account_uuid) with
# the account pinned to <tag> (expected_account_uuid) and prints one line
# on stdout: a status word, a detail word and, for two details, a value:
#   match pinned                  the profile records the pinned account
#   MISMATCH other-tag <tag>      it records the account pinned to <tag>
#   MISMATCH unrecognized <hhhh>  it records an account no tag is pinned to;
#                                 <hhhh> is the last 4 hex digits of its id
#   unknown <reason>              no-folder | no-file | unreadable | no-id |
#                                 bad-id | no-pin | bad-tag
# match needs both ids uuid-shaped and equal; whatever cannot be read or
# compared is unknown, never match. It never prints a whole id.
#
# Return contract: identity_status ALWAYS returns 0, whatever the result,
# and the result is on stdout, so a caller under set -euo pipefail can write
#   st="$(identity_status "$tag")"
# with no guard. The work runs in _identity_status_eval as the left side of
# an || list, so no failing command inside it can end the script, and that
# function never calls exit or die; this one ends with `return 0`.
identity_status() {
  _IDS_RESULT="unknown unreadable"
  _identity_status_eval "${1:-}" || :
  printf '%s\n' "$_IDS_RESULT"
  return 0
}

# Sets _IDS_RESULT for identity_status. Reads the tag's own profile only.
_identity_status_eval() {
  local tag="${1:-}" key udd cur="" prc=0 pin="" other=""
  if [[ ! "$tag" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then _IDS_RESULT="unknown bad-tag"; return 0; fi
  key="$(identity_key "$tag")"
  udd="$(udd_for_tag "$tag")"
  if [[ ! -d "$udd" ]]; then _IDS_RESULT="unknown no-folder"; return 0; fi
  if [[ ! -e "${udd}/config.json" ]]; then _IDS_RESULT="unknown no-file"; return 0; fi
  cur="$(profile_account_uuid "$udd")" || prc=$?
  case "$prc" in
    0) ;;
    3) _IDS_RESULT="unknown no-id"; return 0 ;;
    4) _IDS_RESULT="unknown bad-id"; return 0 ;;
    *) _IDS_RESULT="unknown unreadable"; return 0 ;;
  esac
  pin="$(expected_account_uuid "$key")" || pin=""
  if [[ -z "$pin" ]]; then _IDS_RESULT="unknown no-pin"; return 0; fi
  if [[ "$cur" == "$pin" ]]; then _IDS_RESULT="match pinned"; return 0; fi
  other="$(pinned_tag_for_id "$cur" "$key")" || other=""
  if [[ -n "$other" ]]; then
    _IDS_RESULT="MISMATCH other-tag ${other}"
  else
    _IDS_RESULT="MISMATCH unrecognized ${cur:32:4}"
  fi
  return 0
}

# Splits an identity_status line into _IDS_STATUS, _IDS_DETAIL, _IDS_VALUE.
_ids_parse() {
  local rest
  _IDS_STATUS="${1%% *}"
  rest="${1#* }"
  _IDS_DETAIL="${rest%% *}"
  _IDS_VALUE=""
  if [[ "$rest" == *" "* ]]; then _IDS_VALUE="${rest#* }"; fi
}

# identity_current_text <status line> <label>: how the current account reads
# in output: the label, another tag's account, an unrecognized account with
# the last 4 hex digits of its id, or why it is unknown. Never a whole id.
identity_current_text() {
  _ids_parse "${1:-}"
  case "${_IDS_STATUS}/${_IDS_DETAIL}" in
    match/*)               printf '"%s"' "${2:-}" ;;
    MISMATCH/other-tag)    printf "%s's account" "$_IDS_VALUE" ;;
    MISMATCH/unrecognized) printf 'an unrecognized account (…%s)' "$_IDS_VALUE" ;;
    unknown/no-folder)     printf 'no profile folder yet' ;;
    unknown/no-file)       printf 'no config.json in the profile' ;;
    unknown/unreadable)    printf "config.json can't be read" ;;
    unknown/no-id)         printf 'no account recorded' ;;
    unknown/bad-id)        printf 'the recorded value is not an account id' ;;
    unknown/no-pin)        printf 'no pin' ;;
    *)                     printf 'unknown' ;;
  esac
}

# identity_gate <tag> <force: true|false> <launch|swap>
# The #6 check launch and swap run before they open, quit or capture
# anything. It only reads. On MISMATCH without --force it refuses (exit 1)
# with the recovery steps, and nothing has been opened or quit and no
# profile written (main may have trimmed the switcher's own history log).
# Otherwise it prints one status line and appends one IDENTITY row (tag and
# status word only) to the history log. It never quits an instance.
identity_gate() {
  local tag="$1" force="$2" verb="$3" doing Doing st label current
  case "$verb" in
    swap) doing="swapping"; Doing="Swapping" ;;
    *)    doing="launching"; Doing="Launching" ;;
  esac
  st="$(identity_status "$tag")"
  label="$(account_label "$tag")"
  current="$(identity_current_text "$st" "$label")"
  _ids_parse "$st"
  case "$_IDS_STATUS" in
    match)
      ok "Account check: '${tag}' is recorded as \"${label}\" (match)."
      ;;
    MISMATCH)
      if [[ "$force" != "true" ]]; then
        die "Profile '${tag}' is recorded as signed into ${current}, not \"${label}\" (MISMATCH). Not ${doing}.
  Fix: account-switcher signin ${tag}; or ${verb} anyway with --force, then in that window sign out and sign back in as \"${label}\"."
      fi
      warn "Profile '${tag}' is recorded as signed into ${current}, not \"${label}\" (MISMATCH). ${Doing} anyway (--force)."
      warn "  Fix: in that window, sign out and sign back in as \"${label}\" (or: account-switcher signin ${tag})."
      ;;
    *)
      if tag_is_in_accounts "$(identity_key "$tag")"; then
        info "Account check: '${tag}' is unknown (${current}). Once its window shows \"${label}\", pin it: account-switcher identity pin ${tag}"
      else
        info "Account check: '${tag}' is unknown (${current}). To check it, register it with add-account, then run: account-switcher identity pin ${tag}"
      fi
      ;;
  esac
  if [[ -d "$STORE" ]]; then
    _swap_log_ensure
    printf '[%s] IDENTITY tag=%s status=%s\n' \
      "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$_IDS_STATUS" >> "$SWAP_LOG"
  fi
}

# ---- detect_running_tag --------------------------------------------------

# Prints the profile of the running Claude instance (primary, <tag> or
# unknown), or nothing when no instance is running. Used by cmd_swap_app for
# the SOURCE of the handoff capture (the account active at swap time).
#
#   - One instance: its profile from claude_instances (which may be unknown).
#   - Several instances: the first line of $STATUSLINE_MARKER (the target of
#     the last launch or swap) when it names one of the running profiles;
#     otherwise unknown. Several instances with no usable marker are never
#     guessed to be primary.
#   - No instance: empty; the caller decides.
#
# The argument parse this replaces stopped at the first space in the
# --user-data-dir value, so it could never match a path under "Application
# Support", and every call fell through to a pgrep fallback, then the
# marker, then "primary". That explains the earlier report that the app
# strips --user-data-dir from its arguments; the flag is visible in ps.
detect_running_tag() {
  local rows st=0 pid profile method n=0 only="" marker=""
  rows="$(claude_instances)" || st=$?
  if [[ $st -ne 0 ]]; then printf '%s' "unknown"; return 0; fi
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    n=$((n + 1))
    only="$profile"
  done <<< "$rows"
  if [[ $n -eq 0 ]]; then return 0; fi
  if [[ $n -eq 1 ]]; then printf '%s' "$only"; return 0; fi

  if [[ -f "$STATUSLINE_MARKER" && -r "$STATUSLINE_MARKER" ]]; then
    { IFS= read -r marker || :; } < "$STATUSLINE_MARKER"
    marker="${marker//[[:space:]]/}"
    if [[ "$marker" == "default" ]]; then marker="primary"; fi
  fi
  if [[ -n "$marker" && "$marker" != "unknown" ]]; then
    while IFS=$'\t' read -r pid profile method; do
      [[ -n "$pid" ]] || continue
      if [[ "$profile" == "$marker" ]]; then printf '%s' "$marker"; return 0; fi
    done <<< "$rows"
  fi
  printf '%s' "unknown"
  return 0
}

# ---- capture_handoff -----------------------------------------------------

# Privacy-safe work-state snapshot captured at swap boundary. Chats remain
# ephemeral per-account (Anthropic's design); work STATE carries forward via
# an auto-generated SWAP_HANDOFF.md captured at the swap boundary.
#
# Writes a SWAP_HANDOFF.md (under the configured workspace dir) with metadata
# + pointers to durable surfaces. The next Claude session in either account
# can read this at session start and get enough context to continue work
# without re-explanation.
#
# Privacy framework (defense-in-depth):
#   - Allowlist: branch names, milestone numbers, issue/PR numbers,
#     commit SHAs, counts, timestamps, file paths, status enums
#   - Filter at write-time: commit subjects + issue/PR titles truncated to
#     80 chars + token-pattern regex redaction (eyJ.../sk-ant-.../60+
#     base64-ish runs → [REDACTED-TOKEN-LIKE])
#   - Never captured: commit body, issue body, file contents, chat text,
#     email addresses, customer/PII data, API keys, tokens, passwords
#
# Time window: cutoff = max(now - 24h, last_swap_timestamp)
#   - If operator stays in one account for weeks, last_swap_ts extends
#     the window so the handoff covers everything since they last swapped
#   - 24h is the floor for typical session bridging
#
# Bounded size caps:
#   - Max 50 commits (overflow: list 50 + "[N more]")
#   - Max 20 issues (overflow: 20 most-recently-touched)
#   - Max 50 modified files
#
# Args:
#   $1 = source_tag  (currently-running account; from detect_running_tag)
#   $2 = target_tag  (account being swapped to)
#   $3 = operator_note  (optional; from --note flag in cmd_swap_app)
#
# Behavior:
#   - Always writes (overwrites previous snapshot — single-source-of-truth
#     per swap, not append-only)
#   - Graceful degradation when gh CLI or git unavailable
#   - Writes BEFORE quit_all_claude in cmd_swap_app, so handoff is captured
#     even if quit/launch later fail
capture_handoff() {
  local source_tag="$1"
  local target_tag="$2"
  local operator_note="${3:-}"

  # Workspace dir where SWAP_HANDOFF.md is written. Configurable via
  # [swap_handoff].workspace_dir; defaults to $STORE (which always exists),
  # so the default path always works.
  local ws_dir
  ws_dir=$(toml_get "swap_handoff.workspace_dir" 2>/dev/null || echo "")
  ws_dir="${ws_dir/#\~/$HOME}"
  [[ -z "$ws_dir" ]] && ws_dir="$STORE"

  # Git work-tree to summarize (branch / commits / uncommitted files).
  # Configurable via [swap_handoff].git_root; defaults to the current git
  # work-tree top-level if $PWD is inside one, else empty (handled gracefully).
  local git_root
  git_root=$(toml_get "swap_handoff.git_root" 2>/dev/null || echo "")
  git_root="${git_root/#\~/$HOME}"
  if [[ -z "$git_root" ]] && "$AS_BIN_GIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_root="$("$AS_BIN_GIT" rev-parse --show-toplevel 2>/dev/null)"
  fi

  local handoff_file="${ws_dir}/SWAP_HANDOFF.md"
  local handoff_dir="${ws_dir}"

  if [[ ! -d "$handoff_dir" ]]; then
    warn "SWAP_HANDOFF.md parent dir doesn't exist: $handoff_dir. Skipping handoff capture."
    return 0
  fi

  # ---- Compute time cutoff -----------------------------------------------
  local now_ts cutoff_ts last_swap_ts twenty_four_hours_ago
  now_ts=$("$AS_BIN_DATE" +%s)
  twenty_four_hours_ago=$((now_ts - 86400))

  last_swap_ts=$("$AS_BIN_GREP" '^\[' "$SWAP_LOG" 2>/dev/null \
    | "$AS_BIN_GREP" ' APP_SWAP ' \
    | "$AS_BIN_TAIL" -1 \
    | "$AS_BIN_AWK" -F'[][]' '{print $2}' \
    | "$AS_BIN_PYTHON3" -c '
import sys, datetime
line = sys.stdin.read().strip()
if line:
    print(int(datetime.datetime.fromisoformat(line.replace("Z","+00:00")).timestamp()))
else:
    print(0)
' 2>/dev/null || echo 0)

  if (( last_swap_ts > 0 )) && (( last_swap_ts > twenty_four_hours_ago )); then
    cutoff_ts=$last_swap_ts
  else
    cutoff_ts=$twenty_four_hours_ago
  fi

  local cutoff_iso now_iso
  cutoff_iso=$("$AS_BIN_PYTHON3" -c "import datetime; print(datetime.datetime.utcfromtimestamp($cutoff_ts).isoformat() + 'Z')")
  now_iso=$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)

  info "Capturing swap handoff to ${handoff_file}..."
  info "  Window: since ${cutoff_iso}"

  # ---- Active workspace context ------------------------------------------
  # Summarize the configured git_root (from [swap_handoff].git_root, or the
  # work-tree containing $PWD). If it's detached HEAD, branch --show-current
  # returns exit 0 with empty stdout — the `|| echo` fallback doesn't fire on
  # exit 0, so we explicitly check for empty and report the detached SHA. A
  # checked-out feature branch reports normally. If no git_root is configured
  # or it isn't a git repo, degrade gracefully without errors.
  local active_branch="(no git workspace configured)"
  local active_worktree="(none)"
  if [[ -n "$git_root" ]] && [[ -d "${git_root}/.git" ]]; then
    active_branch=$("$AS_BIN_GIT" -C "${git_root}" branch --show-current 2>/dev/null || echo "")
    if [[ -z "$active_branch" ]]; then
      # Detached HEAD — report the SHA short form for traceability.
      local detached_sha
      detached_sha=$("$AS_BIN_GIT" -C "${git_root}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      active_branch="(detached @ ${detached_sha})"
    fi
    active_worktree="${git_root}"
  fi

  # ---- Auto-derived metadata (with PII filters) --------------------------
  # Token-redaction regex applied to all auto-derived strings before write.
  local redact='s/(eyJ[A-Za-z0-9_.-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|[A-Za-z0-9_-]{60,})/[REDACTED-TOKEN-LIKE]/g'
  local truncate='{ if (length > 80) print substr($0, 1, 80) "…"; else print $0 }'

  # Commits since cutoff (max 50, redacted, truncated)
  local commits_block="(no git workspace configured)"
  if [[ -n "$git_root" ]] && [[ -d "${git_root}/.git" ]]; then
    commits_block=$("$AS_BIN_GIT" -C "${git_root}" log \
      --since="${cutoff_iso}" \
      --pretty=format:'- `%h` %s' \
      --max-count=50 \
      2>/dev/null \
      | "$AS_BIN_SED" -E "$redact" \
      | "$AS_BIN_AWK" "$truncate" \
      || true)
    [[ -z "$commits_block" ]] && commits_block="(no commits since cutoff)"
  fi

  # Resolve operator's gh repo from config (parameterization seam — see
  # config.toml.template [swap_handoff].gh_repo). When unset, skip the gh
  # queries entirely; the handoff still captures commits, files, and metadata.
  local gh_repo
  gh_repo=$(toml_get "swap_handoff.gh_repo" 2>/dev/null || echo "")

  # Issues touched (max 20, search by updated-at)
  local issues_block="(gh repo not configured — see config.toml [swap_handoff].gh_repo)"
  if [[ -n "$gh_repo" ]] && "$AS_BIN_COMMAND" -v gh >/dev/null 2>&1; then
    issues_block=$(gh issue list \
      --repo "$gh_repo" \
      --state all \
      --limit 20 \
      --search "updated:>=${cutoff_iso%T*}" \
      --json number,state,title,updatedAt \
      --jq '.[] | "- #\(.number) [\(.state)] \(.title)"' \
      2>/dev/null \
      | "$AS_BIN_SED" -E "$redact" \
      | "$AS_BIN_AWK" "$truncate" \
      || true)
    [[ -z "$issues_block" ]] && issues_block="(no issues touched since cutoff)"
  elif ! "$AS_BIN_COMMAND" -v gh >/dev/null 2>&1; then
    issues_block="(gh CLI unavailable)"
  fi

  # Open PRs (current state, not historical)
  local prs_block="(gh repo not configured — see config.toml [swap_handoff].gh_repo)"
  if [[ -n "$gh_repo" ]] && "$AS_BIN_COMMAND" -v gh >/dev/null 2>&1; then
    prs_block=$(gh pr list \
      --repo "$gh_repo" \
      --state open \
      --limit 20 \
      --json number,isDraft,title,headRefName \
      --jq '.[] | "- #\(.number) [\(if .isDraft then "DRAFT" else "OPEN" end)] \(.title) (\(.headRefName))"' \
      2>/dev/null \
      | "$AS_BIN_SED" -E "$redact" \
      | "$AS_BIN_AWK" "$truncate" \
      || true)
    [[ -z "$prs_block" ]] && prs_block="(no open PRs)"
  elif ! "$AS_BIN_COMMAND" -v gh >/dev/null 2>&1; then
    prs_block="(gh CLI unavailable)"
  fi

  # Uncommitted changes (point-in-time, paths only)
  local files_block="(no git workspace configured)"
  if [[ -n "$git_root" ]] && [[ -d "${git_root}/.git" ]]; then
    files_block="(no uncommitted changes)"
    local porcelain
    porcelain=$("$AS_BIN_GIT" -C "${git_root}" status --porcelain 2>/dev/null \
      | "$AS_BIN_AWK" 'NR<=50 {print "- " $0}' \
      || true)
    [[ -n "$porcelain" ]] && files_block="$porcelain"
  fi

  # Active project — peek at PORTFOLIO.md under the workspace dir if present
  local active_project="(none configured)"
  if [[ -f "${ws_dir}/PORTFOLIO.md" ]]; then
    active_project=$("$AS_BIN_GREP" -m 1 -E '^### [A-Z]' "${ws_dir}/PORTFOLIO.md" 2>/dev/null \
      | "$AS_BIN_SED" 's/^### //;s/[[:space:]]*$//' \
      | "$AS_BIN_AWK" "$truncate" \
      || echo "(none)")
  fi

  # ---- Write the handoff document (always overwrite; single source) ------
  local note_line=""
  if [[ -n "$operator_note" ]]; then
    # Operator-supplied note — operator's responsibility for content; we don't
    # auto-redact (operator may want to reference specific identifiers). Just
    # truncate to a reasonable length.
    local note_truncated
    note_truncated=$(printf '%s' "$operator_note" | "$AS_BIN_AWK" '{ if (length > 240) print substr($0, 1, 240) "…"; else print $0 }')
    note_line="- **Operator note:** ${note_truncated}"
  fi

  "$AS_BIN_CAT" > "$handoff_file" <<HANDOFF_EOF
# Swap Handoff State

> Auto-generated by account-switcher at the swap boundary. Captures
> last-known work context as **metadata + pointers**, never content. Privacy
> safe by design: no PII, no chat text, no file contents, no tokens. See
> the project README § swap for details.

## Last swap

- **Captured at:** ${now_iso}
- **Direction:** \`${source_tag}\` → \`${target_tag}\`
- **Window covered:** since ${cutoff_iso} (max of 24h or last swap)
${note_line}

## Active workspace context

- Active branch: \`${active_branch}\`
- Active worktree: \`${active_worktree}\`
- Active project: ${active_project}

## Activity since last swap (bounded; metadata only)

### Commits

${commits_block}

### Issues touched

${issues_block}

### Open PRs

${prs_block}

### Uncommitted changes (point-in-time)

${files_block}

## Read the durable sources

- Branch state: \`git -C "${git_root:-<your-repo>}" log --oneline\`
- Issues / PRs: \`gh issue list\` / \`gh pr list\` (set [swap_handoff].gh_repo to enrich automatically)

---

*This file is auto-overwritten on every swap. To preserve a specific*
*handoff snapshot, copy this file to a timestamped backup before swapping.*
HANDOFF_EOF

  "$AS_BIN_CHMOD" 644 "$handoff_file"

  ok "Handoff captured: ${handoff_file}"

  # Log to swap-history.log for auditability
  _swap_log_ensure
  printf '[%s] HANDOFF_CAPTURE source=%s target=%s note=%s\n' \
    "$now_iso" "$source_tag" "$target_tag" \
    "$([ -n "$operator_note" ] && echo 'yes' || echo 'no')" \
    >> "$SWAP_LOG"
}

# ---- quit_all_claude (M-4, M-5, M-12; F2) --------------------------------

# Returns the subset of newline-separated PIDs that are currently alive
# according to /bin/kill -0 (kernel process existence check). Empty
# stdout means none alive. Sets exit status: 0 if any alive, 1 if none.
#
# F2: /bin/kill -0 queries the kernel process table directly and
# does NOT depend on argv-visibility. pgrep -f "Claude.app/..." can
# transiently miss a live process during AppleScript graceful-quit
# handlers (the process may briefly modify argv, become defunct-but-not-
# reaped, or enter other states where ps -axo args reports differently).
# kill -0 bypasses all of those by asking the kernel "does this PID exist
# and would I be allowed to signal it?".
_alive_pids() {
  local pid_list="$1"
  local any_alive="false"
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if "$AS_BIN_KILL" -0 "$pid" 2>/dev/null; then
      any_alive="true"
      printf '%s\n' "$pid"
    fi
  done <<< "$pid_list"
  [[ "$any_alive" == "true" ]] && return 0 || return 1
}

# _quit_listed_check <listed>: the listed mode's check (see quit_all_claude).
# Returns 0 when every Claude main process running now is one of <listed>
# (PIDs, space-separated, with spaces around). Otherwise names each other
# one (tag · PID, from the matcher) in one error line and returns 1. A table
# that can't be read is no evidence of a new instance: it returns 0, and the
# quit still signals only the listed PIDs.
_quit_listed_check() {
  local rows st=0 pid profile method extra=""
  rows="$(claude_instances)" || st=$?
  [[ $st -eq 0 ]] || return 0
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    case "$1" in *" ${pid} "*) continue ;; esac
    extra="${extra:+${extra}, }${profile} · PID ${pid}"
  done <<< "$rows"
  [[ -n "$extra" ]] || return 0
  printf "\033[31mERROR:\033[0m A Claude instance that wasn't listed is running: %s. Stopping the quit; nothing more is signalled.\n" "$extra" >&2
  return 1
}

# quit_all_claude [listed <pid> ...]
#   With no argument (swap, quit): closes every Claude main process.
#   With listed and the PIDs the caller listed and the operator confirmed
#   (update, signin --quit-others): signals only those PIDs. At every read
#   of the process table during the quit (on entry, each second of the
#   graceful wait, before TERM, before KILL, and at the final check), a main
#   process that is not one of them stops the quit at once: nothing more is
#   signalled, it is named (tag · PID), and the function returns 3.
# The graceful step is the same in both modes: one AppleScript quit to the
# app by name. Ends through die (exit 1) when a process it signalled is
# still alive; callers that must not end run it in a subshell.
quit_all_claude() {
  # F2: Capture initial PID list at function entry. We track THESE
  # specific processes through the quit lifecycle via /bin/kill -0 instead
  # of pgrep -f. The pgrep approach was unreliable: during AppleScript-
  # induced quit handlers (e.g., "Save changes?" dialogs, exec transitions,
  # argv modifications) pgrep -f could transiently fail to match a live
  # process, causing the wait loop and SIGTERM/SIGKILL guards to clause
  # through and return "success" while the process remained alive.
  local initial_pids="" mode="all" listed=" " q
  QUIT_TAGS=""
  if [[ "${1:-}" == "listed" ]]; then
    mode="listed"
    shift
    for q; do
      [[ -n "$q" ]] || continue
      initial_pids="${initial_pids}${q}"$'\n'
      listed="${listed}${q} "
    done
  else
    initial_pids=$(get_claude_pids)
  fi

  if [[ -z "$initial_pids" ]]; then
    return 0
  fi
  if [[ "$mode" == "listed" ]]; then _quit_listed_check "$listed" || return 3; fi

  # #24: the tags about to close leave the record before anything is
  # signalled, so the app is never reported as having closed them.
  # The PIDs are numbers, so word splitting is the point.
  # shellcheck disable=SC2086
  _open_tags_quitting $initial_pids

  info "Sending graceful quit to running Claude instances..."
  "$AS_BIN_OSASCRIPT" -e 'tell application "Claude" to quit' 2>/dev/null || true

  # M-4: 15-second graceful-quit timeout (was 5s). Electron typically
  # finishes pending writes within seconds, but leveldb compaction can run
  # longer; SIGKILL during compaction risks safeStorage corruption.
  #
  # F2: Wait for ALL initial PIDs to die (kill -0 returns nonzero), not
  # for pgrep to stop matching. This catches the case where a process is
  # alive but argv-invisible.
  local n=0
  while [[ $n -lt 15 ]]; do
    if ! _alive_pids "$initial_pids" >/dev/null 2>&1; then
      break
    fi
    if [[ "$mode" == "listed" ]]; then _quit_listed_check "$listed" || return 3; fi
    "$AS_BIN_SLEEP" 1
    n=$((n + 1))
  done

  # M-4 + F2: SIGTERM step. Send SIGTERM to any initial PID still alive
  # per kill -0, plus any new Claude processes started during the wait
  # (e.g., LaunchAgent re-spawn, user clicked Dock icon). In listed mode a
  # new process stops the quit instead (above), so only listed PIDs are
  # signalled.
  local alive_initial
  alive_initial=$(_alive_pids "$initial_pids" 2>/dev/null || true)
  local fresh_pids=""
  if [[ "$mode" == "listed" ]]; then
    _quit_listed_check "$listed" || return 3
  else
    fresh_pids=$(get_claude_pids)
  fi
  # shellcheck disable=SC2086
  if [[ -n "$fresh_pids" ]]; then _open_tags_quitting $fresh_pids; fi
  if [[ -n "$alive_initial" ]] || [[ -n "$fresh_pids" ]]; then
    warn "Some Claude processes did not exit gracefully; sending SIGTERM"
    local p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      "$AS_BIN_KILL" -TERM "$p" 2>/dev/null || true
    done <<< "$alive_initial"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      "$AS_BIN_KILL" -TERM "$p" 2>/dev/null || true
    done <<< "$fresh_pids"
    "$AS_BIN_SLEEP" 2
  fi

  # M-12 + F2: SIGKILL via PID list. Re-scan with kill -0 + fresh
  # get_claude_pids in case the process state changed during SIGTERM
  # (e.g., process briefly went argv-visible, or new instance launched).
  alive_initial=$(_alive_pids "$initial_pids" 2>/dev/null || true)
  if [[ "$mode" == "listed" ]]; then
    _quit_listed_check "$listed" || return 3
  else
    fresh_pids=$(get_claude_pids)
  fi
  # shellcheck disable=SC2086
  if [[ -n "$fresh_pids" ]]; then _open_tags_quitting $fresh_pids; fi
  if [[ -n "$alive_initial" ]] || [[ -n "$fresh_pids" ]]; then
    warn "Claude processes resisting SIGTERM; sending SIGKILL via PID list"
    local p
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      "$AS_BIN_KILL" -KILL "$p" 2>/dev/null || true
    done <<< "$alive_initial"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      "$AS_BIN_KILL" -KILL "$p" 2>/dev/null || true
    done <<< "$fresh_pids"
    "$AS_BIN_SLEEP" 1
  fi

  # M-5 + F2: Final verification using BOTH kill -0 (initial PID set) AND
  # fresh get_claude_pids (new instances launched during quit window).
  # Dies if either check finds a live process — pgrep transient-miss can
  # no longer hide a stale instance because kill -0 is argv-independent.
  local stragglers=()
  alive_initial=$(_alive_pids "$initial_pids" 2>/dev/null || true)
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    stragglers+=("${p} (initial; survived quit)")
  done <<< "$alive_initial"
  if [[ "$mode" == "listed" ]]; then
    _quit_listed_check "$listed" || return 3
  else
    fresh_pids=$(get_claude_pids)
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # Only count fresh PIDs that were not in the initial set (already counted above).
    if ! "$AS_BIN_GREP" -qx "$p" <<< "$initial_pids"; then
      stragglers+=("${p} (launched during quit window)")
    fi
  done <<< "$fresh_pids"

  if [[ ${#stragglers[@]} -gt 0 ]]; then
    die "Could not terminate all Claude processes (PIDs still alive: ${stragglers[*]}). Investigate manually before retrying."
  fi

  ok "Existing instances quit"
}

# ---- The new instance, brought to the front (#8) --------------------------
#
# After `open -n`, launch and swap find the new instance's PID, ask macOS to
# put that process in front, check that it is, and end with one line on
# stdout naming the tag, the PID, whether it is in front, and the account
# from the #6 check (labels only, never ids):
#
#   tag=<tag> pid=<pid|unknown> front=yes|no account=<"label"|unrecognized|unknown> status=<match|MISMATCH|unknown>
#
# followed, when front=no, by two spaces and "Switch with Cmd-backtick or the
# Dock". Before this the switcher only said to look for the new window, so
# the operator could go on working in a window that was already in front.
# wait_for_new_instance and bring_to_front are also called by signin (#7);
# their contracts below are stable.

# How long launch and swap wait for the new instance to appear, in seconds.
readonly NEW_INSTANCE_WAIT_S=15

# front_pid: prints the PID of the front application, or nothing; always
# returns 0. `lsappinfo front` prints the front application's ASN with a
# trailing colon (ASN:0x0-0x1d01d:). Only that trailing colon is removed
# before `lsappinfo info -only pid` reads it: deleting every colon (tr -d ':')
# also removes the "ASN:" prefix, and info then prints nothing (Stage 5 A-1).
front_pid() {
  local asn="" line="" re='"pid"=([0-9]+)'
  asn="$("$AS_BIN_LSAPPINFO" front 2>/dev/null | "$AS_BIN_SED" 's/:$//')" || asn=""
  if [[ "$asn" != ASN:* ]]; then return 0; fi
  line="$("$AS_BIN_LSAPPINFO" info -only pid "$asn" 2>/dev/null)" || line=""
  if [[ "$line" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
  return 0
}

# wait_for_new_instance <tag> <pre-open PID list> [timeout]
#
# Contract (stable; signin calls it too):
#   - Polls the exact matcher (claude_instances, #9) every 0.5 s for up to
#     <timeout> seconds (default 15; anything but a whole number reads 15).
#   - Prints the PID of the first main process whose profile resolves to
#     <tag> ("default" is primary) and whose PID is not in <pre-open PID
#     list> (PIDs separated by spaces or newlines, normally get_claude_pids
#     taken just before `open`), then stops.
#   - Prints nothing when no such process appears in time, or when <tag> is
#     not a valid tag (then it returns at once). A process table that cannot
#     be read counts as "not yet".
#   - ALWAYS returns 0, so  pid="$(wait_for_new_instance "$t" "$pre")"  is
#     safe under set -euo pipefail. It only reads; it never signals.
# The number of polls is fixed (two per second of timeout) rather than read
# from the clock, so a test's sleep fake can drive the wait to its end.
wait_for_new_instance() {
  local want="${1:-}" pre=" ${2:-} " limit="${3:-15}" polls n=0 rows pid profile method
  if [[ "$want" == "default" ]]; then want="primary"; fi
  if [[ ! "$want" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then return 0; fi
  pre="${pre//$'\n'/ }"
  if [[ ! "$limit" =~ ^[0-9]{1,5}$ ]]; then limit=15; fi
  polls=$(( 10#$limit * 2 ))
  while :; do
    rows=""
    rows="$(claude_instances)" || rows=""
    while IFS=$'\t' read -r pid profile method; do
      if [[ -z "$pid" || "$profile" != "$want" ]]; then continue; fi
      if [[ "$pre" == *" ${pid} "* ]]; then continue; fi
      printf '%s\n' "$pid"
      return 0
    done <<< "$rows"
    if [[ $n -ge $polls ]]; then break; fi
    "$AS_BIN_SLEEP" 0.5 2>/dev/null || :
    n=$((n + 1))
  done
  return 0
}

# The AppKit rung's script (JavaScript for Automation with the ObjC bridge).
# The PID arrives as argv[0], never as part of the code. 3 is
# NSApplicationActivateAllWindows (1) | NSApplicationActivateIgnoringOtherApps (2).
# shellcheck disable=SC2016
readonly AS_JXA_ACTIVATE='function run(argv) {
  ObjC.import("AppKit");
  var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
  if (app.isNil()) { return "absent"; }
  app.activateWithOptions(3);
  return "asked";
}'

# The System Events rung's script; the PID arrives as item 1 of argv.
readonly AS_SE_ACTIVATE='tell application "System Events" to set frontmost of (first application process whose unix id is ((item 1 of argv) as integer)) to true'

# _front_is <pid>: returns 0 when front_pid reads <pid>, checked twice, each
# after a 0.5 s pause (activation is asynchronous); 1 otherwise.
_front_is() {
  local i=0 f=""
  while [[ $i -lt 2 ]]; do
    "$AS_BIN_SLEEP" 0.5 2>/dev/null || :
    f="$(front_pid)"
    if [[ -n "$f" && "$f" == "$1" ]]; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

# bring_to_front <pid>
#
# Contract (stable; signin calls it too):
#   - Asks macOS to put main process <pid> in front, one rung at a time, and
#     after each rung checks with front_pid whether <pid> is now the front
#     application (_front_is: two checks, 0.5 s apart).
#   - Stops at the first rung that verifies and prints its name, one word on
#     stdout: setfront, appkit or system-events; or none when no rung
#     verified, or when <pid> is not a positive whole number (then no rung
#     runs). The word names the first rung after which <pid> was seen in
#     front; a window that comes forward on its own is credited to the rung
#     just tried.
#   - ALWAYS returns 0, so  rung="$(bring_to_front "$pid")"  is safe under
#     set -euo pipefail. A rung whose command fails reads as not verified.
#
# The rungs, in order (Stage 5 D-8 as amended by A-1):
#   setfront       `lsappinfo setfront "#<pid>"`: a Launch Services request
#                  addressed by PID ("#<pid>" is lsappinfo's PID form of an
#                  application specifier). Raises no Automation prompt.
#   appkit         osascript -l JavaScript: NSRunningApplication for <pid>,
#                  then activateWithOptions. An AppKit call made inside
#                  osascript, not an Apple event to another app, so it raises
#                  no Automation prompt either.
#   system-events  osascript asking System Events to set frontmost of the
#                  process whose unix id is <pid>. The first time this rung
#                  runs, macOS may show a one-time Automation prompt ("... wants
#                  to control System Events"); once that is denied, osascript
#                  fails silently (-1743) and the rung reads as not verified.
#   none           nothing else is tried; the caller says how to switch.
# Never `open -a Claude` or `tell application "Claude" to activate`: both
# name the app bundle, not a process, so with several instances running
# Launch Services picks one of them, not necessarily <pid>. From macOS 14 an
# app that is not frontmost may have its activation request ignored
# (cooperative activation), which is why each rung is verified, not trusted.
bring_to_front() {
  local pid="${1:-}" rung
  if [[ ! "$pid" =~ ^[1-9][0-9]{0,9}$ ]]; then printf 'none\n'; return 0; fi
  for rung in setfront appkit system-events; do
    case "$rung" in
      setfront)
        "$AS_BIN_LSAPPINFO" setfront "#${pid}" > /dev/null 2>&1 || :
        ;;
      appkit)
        "$AS_BIN_OSASCRIPT" -l JavaScript -e "$AS_JXA_ACTIVATE" "$pid" > /dev/null 2>&1 || :
        ;;
      system-events)
        "$AS_BIN_OSASCRIPT" -e 'on run argv' -e "$AS_SE_ACTIVATE" -e 'end run' "$pid" > /dev/null 2>&1 || :
        ;;
    esac
    if _front_is "$pid"; then
      printf '%s\n' "$rung"
      return 0
    fi
  done
  printf 'none\n'
  return 0
}

# _launch_report <tag> <pre-open PID list>: the end of launch and swap.
# Waits for the new instance, brings it to the front, reads the #6 status
# again (the same on-disk value the gate read, so a report, not a second
# gate, and no second history row) and prints the closing line on stdout.
_launch_report() {
  local tag="$1" pre="$2" pid="" rung="none" front="no" st account line
  info "Waiting up to ${NEW_INSTANCE_WAIT_S} s for the new '${tag}' instance..."
  pid="$(wait_for_new_instance "$tag" "$pre" "$NEW_INSTANCE_WAIT_S")"
  if [[ -n "$pid" ]]; then
    # #24: its new PID was seen, so the tag is running (a closure clears).
    _open_tags_back "$tag"
    rung="$(bring_to_front "$pid")"
    if [[ "$rung" != "none" ]]; then
      front="yes"
      info "  PID ${pid} is in front (${rung})."
    else
      info "  PID ${pid} is running but could not be brought to the front."
    fi
  else
    pid="unknown"
    info "  No new '${tag}' instance appeared within ${NEW_INSTANCE_WAIT_S} s; it may still be starting (account-switcher list)."
  fi
  st="$(identity_status "$tag")"
  _ids_parse "$st"
  case "${_IDS_STATUS}/${_IDS_DETAIL}" in
    match/*)            account="\"$(account_label "$tag")\"" ;;
    MISMATCH/other-tag) account="\"$(account_label "$_IDS_VALUE")\"" ;;
    MISMATCH/*)         account="unrecognized" ;;
    *)                  account="unknown" ;;
  esac
  line="tag=${tag} pid=${pid} front=${front} account=${account} status=${_IDS_STATUS}"
  if [[ "$front" != "yes" ]]; then line="${line}  Switch with Cmd-backtick or the Dock"; fi
  printf '%s\n' "$line"
  return 0
}

# ---- App updates: the reader, the record and the lock (#10) ---------------
#
# Every tag runs the same app bundle, so one updater serves every tag. An
# instance that downloads an update hands it to the updater's helper
# (ShipIt), which works in AS_UPDATER_CACHE: the cache folder named by the
# app's bundle id, ~/Library/Caches/com.anthropic.claudefordesktop.ShipIt.
# Other apps keep ShipIt caches too, so the folder is always named, never
# found with a *ShipIt* pattern. The helper installs only once no instance
# of the app is running.
#
# The reader opens exactly four files, each through a seamed command, so the
# test suite's recording fakes can show what was read: the helper's state
# file (ShipItState.plist, which is JSON despite its name: read with jq, and
# through plutil only when it is not JSON), the installed and the staged
# Info.plist (PlistBuddy) and the helper's log (awk). Beyond those it lists
# the cache folder (a glob), and update reads the process list. It opens no
# cookies, no Local Storage, no keychain item, no token and nothing in any
# profile folder. When the cache folder is absent it runs no command at all.
#
# Versions are strings. They are compared for equality only, never ordered:
# the middle component restarts with each major (3.6556.2, then 4.29.0).
#
# What cannot be read is unknown, never none. none means the cache was read
# and holds no staged bundle other than the installed version.

readonly UPDATER_STATE_FILE="${AS_UPDATER_CACHE}/ShipItState.plist"
readonly UPDATER_LOG="${AS_UPDATER_CACHE}/ShipIt_stderr.log"
readonly APP_INFO_PLIST="${AS_APP_BUNDLE}/Contents/Info.plist"
readonly UPDATE_STATE="${STORE}/update-state.json"
readonly UPDATE_LOCK="${STORE}/.update.lock"
readonly UPDATE_LOCK_STALE_S=600
# Both locks (this one and the settings-sync lock of #11) go stale after 10
# minutes.
readonly LOCK_STALE_S=$UPDATE_LOCK_STALE_S
readonly PREFS_STATE="${STORE}/prefs-sync.json"
readonly PREFS_LOCK="${STORE}/.prefs-sync.lock"
readonly UPDATE_TIMEOUT_DEFAULT=120
readonly AS_VERSION_RE='^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$'
readonly AS_UTC_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# The jq filter for launchAfterInstallation: "true" or "false", or "unknown"
# when the top level is not one object or the value is not a boolean.
# shellcheck disable=SC2016
readonly UPD_FLAG_JQ='if type == "object" and (.launchAfterInstallation | type) == "boolean"
  then (.launchAfterInstallation | tostring) else "unknown" end'

UPD_INSTALLED="unknown"
UPD_INSTALLED_WHY=""
UPD_STAGED="unknown"
UPD_WHY=""
UPD_FIRST_SEEN=""
UPD_WAIT_S=""
UPD_FLAG="unknown"
UPD_LOG_LAST=""
UPD_LOG_SEED=""
UPD_LOG_DONE=0
LOCK_OWNED=""
LOCK_STALE=1
LOCK_AGE=""
LOCK_PID=""

# _strip_controls <text>: prints <text> without its C0 control characters,
# DEL, and C1 control characters (U+0080 to U+009F, in their UTF-8 form), so
# a line read from a file the switcher doesn't write can't move the cursor,
# recolour or retitle the terminal when it is printed (S-07). Builtins only,
# matched byte by byte in the C locale (a subshell, so the locale change
# stays inside it).
_strip_controls() (
  LC_ALL=C
  c0=$'[\001-\037\177]'
  c1=$'\302[\200-\237]'
  s="$1"
  s="${s//$c0/}"
  s="${s//$c1/}"
  printf '%s' "$s"
)

# _plist_version <Info.plist>: prints its CFBundleShortVersionString and
# returns 0, or prints nothing and returns 1 (absent, unreadable, no such
# key, or a value that is not version-shaped).
_plist_version() {
  local f="${1:-}" v=""
  [[ -f "$f" && -r "$f" ]] || return 1
  v="$("$AS_BIN_PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$f" 2>/dev/null)" || return 1
  [[ "$v" =~ $AS_VERSION_RE ]] || return 1
  printf '%s' "$v"
}

# Sets UPD_INSTALLED (a version or unknown) and UPD_INSTALLED_WHY.
_update_installed() {
  UPD_INSTALLED_WHY=""
  if UPD_INSTALLED="$(_plist_version "$APP_INFO_PLIST")"; then return 0; fi
  UPD_INSTALLED="unknown"
  if [[ -e "$APP_INFO_PLIST" ]]; then
    UPD_INSTALLED_WHY="the app's Info.plist can't be read"
  else
    UPD_INSTALLED_WHY="the app's Info.plist is missing"
  fi
}

# Sets UPD_STAGED to the staged bundle's version, none or unknown, and
# UPD_WHY to the reason for unknown. A staged bundle is
# <cache>/update.<random>/Claude.app. One whose version equals
# UPD_INSTALLED is not waiting (none); several with different versions, or
# any folder or Info.plist that can't be read, are unknown.
_update_staged() {
  local d v found=""
  UPD_STAGED="unknown"
  UPD_WHY=""
  if [[ ! -d "$AS_UPDATER_CACHE" ]]; then UPD_WHY="no updater cache folder"; return 0; fi
  if [[ ! -r "$AS_UPDATER_CACHE" || ! -x "$AS_UPDATER_CACHE" ]]; then
    UPD_WHY="the updater cache folder can't be read"
    return 0
  fi
  for d in "$AS_UPDATER_CACHE"/update.*; do
    [[ -d "$d" ]] || continue
    if [[ ! -r "$d" || ! -x "$d" ]]; then UPD_WHY="a staged update folder can't be read"; return 0; fi
    [[ -e "${d}/Claude.app" ]] || continue
    if ! v="$(_plist_version "${d}/Claude.app/Contents/Info.plist")"; then
      UPD_WHY="the staged bundle's Info.plist can't be read"
      return 0
    fi
    if [[ -n "$found" && "$v" != "$found" ]]; then UPD_WHY="several staged bundles"; return 0; fi
    found="$v"
  done
  if [[ -z "$found" || "$found" == "$UPD_INSTALLED" ]]; then UPD_STAGED="none"; else UPD_STAGED="$found"; fi
}

# Sets UPD_FLAG to true, false or unknown: the helper state file's
# launchAfterInstallation. The file is JSON, which PlistBuddy can't read, so
# jq reads it; only when jq can't parse it (it is not JSON) does plutil
# convert it to JSON for jq. unknown when both reads fail, and when the file
# parses but holds no boolean there.
_updater_flag() {
  local f="$UPDATER_STATE_FILE" v=""
  UPD_FLAG="unknown"
  [[ -f "$f" && -r "$f" ]] || return 0
  if ! v="$("$AS_BIN_JQ" -r "$UPD_FLAG_JQ" "$f" 2>/dev/null)"; then
    v="$("$AS_BIN_PLUTIL" -convert json -o - "$f" 2>/dev/null | "$AS_BIN_JQ" -r "$UPD_FLAG_JQ" 2>/dev/null)" || v=""
  fi
  case "$v" in
    true|false) UPD_FLAG="$v" ;;
  esac
  return 0
}

# _updater_log_scan [<since>]: one awk pass over the helper's log. Lines
# that do not start with a timestamp (the "ERROR: Unrecognized attribute"
# lines and the indented NSFilePath / NSURL dumps) are skipped. Sets:
#   UPD_LOG_LAST  the last timestamped line ("" when there is none)
#   UPD_LOG_SEED  the time of the first "Detected this as an install request"
#                 after the last "Installation completed successfully"
#                 (YYYY-MM-DD HH:MM:SS, local time; "" when there is none)
#   UPD_LOG_DONE  the number of "Installation completed successfully" lines
#                 stamped at or after <since> (0 without <since>)
# Returns 1 when the log can't be read.
#
# Time zone: the helper stamps each line in local time, with milliseconds
# and no zone ("2026-10-31 11:21:05.123") [INFERRED: the logger's usual
# convention; not verified]. So every comparison here is in local time:
# <since> is `date '+%Y-%m-%d %H:%M:%S'` in this zone, and both sides are
# compared to the second as fixed-width strings (the milliseconds are
# dropped). A completion stamped in the same second as <since> counts; a
# real install finishes seconds after the quit begins. Only first_seen_utc
# is converted to UTC (_update_local_to_utc). In the hour a daylight-saving
# change repeats, local times are ambiguous, and a line stamped in it can be
# misordered.
_updater_log_scan() {
  local since="${1:-}" out="" k v
  # The last line is printed as read, so its control characters are removed
  # first (S-07, _strip_controls).
  UPD_LOG_LAST=""
  UPD_LOG_SEED=""
  UPD_LOG_DONE=0
  [[ -f "$UPDATER_LOG" && -r "$UPDATER_LOG" ]] || return 1
  out="$(AS_SINCE="$since" "$AS_BIN_AWK" '
    BEGIN { since = ENVIRON["AS_SINCE"]; n = 0; seed = ""; last = "" }
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] / {
      t = substr($0, 1, 19)
      last = $0
      msg = substr($0, 25)
      i = index(msg, "] ")
      if (i > 0) msg = substr(msg, i + 2)
      if (index(msg, "Installation completed successfully") == 1) {
        seed = ""
        if (since != "" && t >= since) n++
      } else if (index(msg, "Detected this as an install request") == 1) {
        if (seed == "") seed = t
      }
    }
    END { gsub(/\t/, " ", last); printf "L\t%s\nS\t%s\nN\t%d\n", last, seed, n }' "$UPDATER_LOG" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r k v; do
    case "$k" in
      L) UPD_LOG_LAST="$(_strip_controls "$v")" ;;
      S) UPD_LOG_SEED="$v" ;;
      N) if [[ "$v" =~ ^[0-9]+$ ]]; then UPD_LOG_DONE="$v"; fi ;;
    esac
  done <<< "$out"
  return 0
}

# Returns 0 when the last timestamped log line (from _updater_log_scan) says
# an install is under way. Whether a ShipIt process exists is not the test:
# one waits for hours in the normal staged state.
_updater_installing() {
  local msg="${UPD_LOG_LAST:24}"
  msg="${msg#*] }"
  case "$msg" in
    "Beginning installation"*|"Moving bundle"*|"Moved bundle"*) return 0 ;;
  esac
  return 1
}

# _update_local_to_utc <YYYY-MM-DD HH:MM:SS>: prints the same instant as an
# ISO UTC string (BSD date reads the local time with -j -f), or returns 1.
_update_local_to_utc() {
  local e=""
  e="$("$AS_BIN_DATE" -j -f '%Y-%m-%d %H:%M:%S' "${1:-}" +%s 2>/dev/null)" || return 1
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  "$AS_BIN_DATE" -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# _utc_epoch <ISO UTC>: prints its epoch seconds, or returns 1.
_utc_epoch() {
  local e=""
  e="$("$AS_BIN_DATE" -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${1:-}" +%s 2>/dev/null)" || return 1
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$e"
}

# _fmt_duration <seconds>: "2d 3h", "3h 12m", "12m" or "under 1m".
_fmt_duration() {
  local s="${1:-0}" d h m
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  d=$((s / 86400))
  h=$(((s % 86400) / 3600))
  m=$(((s % 3600) / 60))
  if [[ $d -gt 0 ]]; then printf '%dd %dh' "$d" "$h"
  elif [[ $h -gt 0 ]]; then printf '%dh %dm' "$h" "$m"
  elif [[ $m -gt 0 ]]; then printf '%dm' "$m"
  else printf 'under 1m'
  fi
}

# The switcher's own record, update-state.json (mode 600), so a status line
# can show "update waiting" without reading the helper's files:
#   {"schema": 1, "staged_version": "<version>" | "none",
#    "installed_version": "<version>" | "unknown",
#    "first_seen_utc": "<ISO UTC>" | null, "phase": "idle" | "updating",
#    "run": null | {"started_utc": "<ISO UTC>", "pid": <n>}}
# first_seen_utc is when the switcher first saw that staged version. It
# cannot come from the cache's file times, which are rewritten at every app
# launch, so with no record it is seeded from the helper log's first install
# request after the last completed install, and otherwise it is the time of
# the observation. It never touches the tag marker (.statusline-marker),
# whose first line detect_running_tag reads as a tag.

# Sets UPD_REC_STAGED, UPD_REC_INSTALLED, UPD_REC_FIRST and UPD_REC_PHASE from
# the record ("" each when it is absent, unreadable or malformed).
_update_state_read() {
  local line=""
  UPD_REC_STAGED="" UPD_REC_INSTALLED="" UPD_REC_FIRST="" UPD_REC_PHASE=""
  [[ -f "$UPDATE_STATE" && -r "$UPDATE_STATE" ]] || return 0
  line="$("$AS_BIN_JQ" -r 'if type == "object" then
      [(.staged_version // "" | tostring), (.installed_version // "" | tostring),
       (.first_seen_utc // "" | tostring), (.phase // "" | tostring)] | join("|")
    else empty end' "$UPDATE_STATE" 2>/dev/null)" || line=""
  IFS='|' read -r UPD_REC_STAGED UPD_REC_INSTALLED UPD_REC_FIRST UPD_REC_PHASE <<< "$line" || :
  [[ "$UPD_REC_STAGED" =~ $AS_VERSION_RE ]] || UPD_REC_STAGED=""
  [[ "$UPD_REC_INSTALLED" =~ $AS_VERSION_RE ]] || UPD_REC_INSTALLED=""
  [[ "$UPD_REC_FIRST" =~ $AS_UTC_RE ]] || UPD_REC_FIRST=""
  return 0
}

# _update_state_write <staged> <installed> <first_seen> <phase> [<run started> <run pid>]
# Writes the record through a temp file, mv and chmod 600. Only when the
# store exists; a write that fails leaves the old record and returns 0.
_update_state_write() {
  local tmp=""
  [[ -d "$STORE" ]] || return 0
  tmp="$("$AS_BIN_MKTEMP" 2>/dev/null)" || return 0
  if "$AS_BIN_JQ" -n --arg s "${1:-}" --arg i "${2:-}" --arg f "${3:-}" --arg p "${4:-idle}" \
        --arg rs "${5:-}" --arg rp "${6:-0}" \
        '{schema: 1, staged_version: $s, installed_version: $i,
          first_seen_utc: (if $f == "" then null else $f end), phase: $p,
          run: (if $rs == "" then null else {started_utc: $rs, pid: ($rp | tonumber)} end)}' \
        > "$tmp" 2>/dev/null \
      && "$AS_BIN_MV" -f "$tmp" "$UPDATE_STATE" 2>/dev/null \
      && "$AS_BIN_CHMOD" 600 "$UPDATE_STATE" 2>/dev/null; then
    return 0
  fi
  "$AS_BIN_RM" -f "$tmp" 2>/dev/null || :
  return 0
}

# update_observe: reads the installed and staged versions and how long the
# staged one has waited, and rewrites update-state.json when what it holds
# changed. While the update lock exists it writes nothing (that run owns the
# record). Sets UPD_INSTALLED, UPD_INSTALLED_WHY, UPD_STAGED, UPD_WHY,
# UPD_FIRST_SEEN and UPD_WAIT_S (seconds, or "" when unknown). Always
# returns 0.
update_observe() {
  local first="" now="" fe=""
  UPD_FIRST_SEEN=""
  UPD_WAIT_S=""
  _update_installed
  _update_staged
  if [[ "$UPD_STAGED" == "unknown" ]]; then return 0; fi
  _update_state_read
  if [[ "$UPD_STAGED" != "none" ]]; then
    if [[ "$UPD_REC_STAGED" == "$UPD_STAGED" && -n "$UPD_REC_FIRST" ]]; then
      first="$UPD_REC_FIRST"
    elif [[ -z "$UPD_REC_STAGED" ]] && _updater_log_scan "" && [[ -n "$UPD_LOG_SEED" ]]; then
      first="$(_update_local_to_utc "$UPD_LOG_SEED")" || first=""
    fi
    if [[ ! "$first" =~ $AS_UTC_RE ]]; then first="$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)"; fi
    UPD_FIRST_SEEN="$first"
    now="$("$AS_BIN_DATE" +%s)"
    fe="$(_utc_epoch "$first")" || fe=""
    if [[ -n "$fe" && "$now" =~ ^[0-9]+$ ]]; then
      UPD_WAIT_S=$((now - fe))
      if [[ $UPD_WAIT_S -lt 0 ]]; then UPD_WAIT_S=0; fi
    fi
  fi
  if [[ ! -d "$UPDATE_LOCK" ]] && [[ "$UPD_REC_STAGED" != "$UPD_STAGED" \
        || "$UPD_REC_INSTALLED" != "$UPD_INSTALLED" || "$UPD_REC_FIRST" != "$UPD_FIRST_SEEN" \
        || "$UPD_REC_PHASE" != "idle" ]]; then
    _update_state_write "$UPD_STAGED" "$UPD_INSTALLED" "$UPD_FIRST_SEEN" idle
  fi
  return 0
}

# _update_config_int <key> <default> <min> <max>: the whole number at
# [update].<key> in config.toml, or <default> when unset; a value that is not
# a whole number in range warns and reads <default>.
_update_config_int() {
  local v=""
  v="$(toml_get "update.$1" 2>/dev/null)" || v=""
  if [[ -z "$v" ]]; then printf '%s' "$2"; return 0; fi
  if [[ "$v" =~ ^[0-9]{1,5}$ ]] && [[ $((10#$v)) -ge $3 && $((10#$v)) -le $4 ]]; then
    printf '%s' "$((10#$v))"
    return 0
  fi
  warn "config.toml [update] $1 = '${v}' is not a whole number from $3 to $4; using $2."
  printf '%s' "$2"
}

# _update_idle_close_text: the warning's sentence (#24), one source for
# launch, swap and list, so their wording can't drift apart. The callers
# supply its first word ("The", or list's "the").
_update_idle_close_text() {
  printf "app may close idle windows on its own to install it, from about 10 minutes after it finds the update: that ends their Code sessions and Terminal tabs, and tags other than primary don't come back. To install it on your terms: account-switcher update"
}

# update_wait_warning: launch and swap call this before they open anything.
# From the moment an app update is staged, one warning line: the app may
# close idle windows on its own to install it (#24). launch and swap each
# leave an instance open, so they warn whenever an update is staged; the
# [update] warn_after_hours threshold of v11.0.0 is no longer read. Never
# refuses.
update_wait_warning() {
  local staged=""
  update_observe
  [[ "$UPD_STAGED" != "unknown" && "$UPD_STAGED" != "none" ]] || return 0
  if [[ -n "$UPD_WAIT_S" ]]; then staged=" (staged $(_fmt_duration "$UPD_WAIT_S") ago)"; fi
  warn "Claude ${UPD_STAGED} is waiting to install${staged}. The $(_update_idle_close_text)"
  return 0
}

# ---- Tags Claude closed on its own (#24) ----------------------------------
#
# While an app update is staged, Claude closes an idle instance on its own to
# install it, and with several tags open the first ones to close never come
# back: the update installs only once every instance is closed, and the
# updater then reopens only primary. The switcher has no background job. It
# notices the next time a command that reads the process table runs (an
# observation): list, launch, swap, reopen and signin, and update while an
# update is staged (with nothing staged it stops before its listing). Every
# quit the switcher makes goes through quit_all_claude, which takes the tags
# it is about to close out of the record before anything is signalled, so
# the switcher's own quits are never reported as the app's.
#
# The record, open-tags.json (mode 600), is the only input to detection:
#   {"schema": 1,
#    "open":   [{"tag": "<tag>", "seen_utc": "<ISO UTC>"}],
#    "closed": [{"tag": "<tag>", "seen_utc": "<ISO UTC>", "found_utc": "<ISO UTC>",
#                "cause": "updater" | "unknown",
#                "event": "idle-update" | "pending-restart" | "none"}],
#    "primary_seen_utc": "<ISO UTC>" | null,
#    "event_mark_utc": "<ISO UTC>" | null}
# It holds tags, UTC stamps and words from closed sets, and no id, email or
# path. A file that is absent, unreadable or malformed reads as empty: that
# loses tracking, but never reports a closure that didn't happen.
#   open    the tags the switcher opened, or adopted: a running instance
#           started with --user-data-dir, which only the switcher passes.
#           primary is never adopted, because the Dock and the updater's
#           helper start it too. Each carries the last time it was seen.
#   closed  tags found gone without the switcher closing them. An entry
#           stays until its tag is seen running again (an observation, or a
#           wait that saw its new PID), so list keeps naming it and reopen
#           keeps offering it.
#   primary_seen_utc  the last time the switcher saw primary running,
#           whoever started it; cleared when the switcher's own quit closes
#           it. Only the cause rule reads it.
#   event_mark_utc    the latest app-log event an observation has already
#           counted, so the 2 s slack never counts one event twice.
#
# One clock per run: every stamp a run writes is the time it first read the
# clock (_open_tags_now), and every command that stamps a tag observes first.
# So a tag a command opens carries the same seen time as everything that
# command saw running, and the cause rule's comparisons of seen times hold.
# Stamps a few seconds apart within one command would let an instance seen
# just before another's open lend its close to the other's time span.
#
# The cause rule. The app writes one shared log (main.log and its numbered
# copies), whose update-close lines name no profile, so a closure is tied to
# its cause by counting. For the tags found closed at one observation (at F),
# each last seen at S_i:
#   u_i  the update closes in the app's log stamped in [S_i - 2 s, F] and
#        after event_mark_utc: the idle-timeout close ("idle-update") and
#        the restart after a long-pending update ("pending-restart");
#   k_i  the tags found closed with S_j >= S_i, plus 1 for primary when it
#        was seen at or after S_i (primary_seen_utc as stored before this
#        observation), is not itself one of them, and is either gone at F or
#        running again after a completed install since S_i: its own close
#        then used an event too.
# The cause is "updater" (closed by the app's updater) only when the log was
# readable and u_i >= k_i >= 1; otherwise "unknown" (closed, cause unknown).
# Fewer events than closures means the log can't say which window an event
# closed, so every one of those tags reads unknown. The rule errs towards
# unknown: a primary quit by hand in the same span turns a real updater
# close into unknown, and reopen then leaves that tag for launch. A trigger
# line that never ended in a close still counts (the log's format is
# undocumented; when its wording changes, every cause reads unknown).
# Residuals: two runs in the same second can each record the same closure
# (there is no lock, on purpose: a stale lock would switch tracking off);
# a list that runs while update holds its lock can read the record before
# update's quit removes its tags and write after it.

readonly OPEN_TAGS="${STORE}/open-tags.json"
readonly APPLOG_SLACK_S=2
readonly OT_TAG_RE='^[a-z0-9][a-z0-9-]{0,31}$'
readonly OT_STAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'

# The record in memory: space-separated tokens with |-separated fields
# (tags, UTC stamps and closed-set words hold neither character).
#   OT_OPEN    <tag>|<seen>
#   OT_CLOSED  <tag>|<seen>|<found>|<cause>|<event>
OT_OPEN=""
OT_CLOSED=""
OT_PSEEN=""
OT_MARK=""
OT_LOADED=0
# Set by open_tags_observe: the tags newly found closed (<tag>:<cause>), and
# how many instances run ("" when the process table could not be read).
OT_NEW=""
OT_RUNNING_N=""
OT_NOW_EP=""
OT_NOW_UTC=""
# Set by quit_all_claude: the tags it closed, a comma list for QUIT_ALL rows.
QUIT_TAGS=""
APPLOG_EVENTS=""

# _open_tags_now: reads the clock once per run (see "One clock per run"),
# setting OT_NOW_EP and OT_NOW_UTC. Returns 1 when the clock can't be read.
_open_tags_now() {
  local ep="" u=""
  if [[ -n "$OT_NOW_EP" ]]; then return 0; fi
  ep="$("$AS_BIN_DATE" +%s 2>/dev/null)" || ep=""
  [[ "$ep" =~ ^[0-9]+$ ]] || return 1
  u="$("$AS_BIN_DATE" -u -r "$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || u=""
  [[ "$u" =~ $AS_UTC_RE ]] || return 1
  OT_NOW_EP="$ep"
  OT_NOW_UTC="$u"
  return 0
}

# _ot_local <epoch>: the local time "YYYY-MM-DD HH:MM:SS", as the app's log
# stamps its lines.
_ot_local() {
  "$AS_BIN_DATE" -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# _ot_in <tokens> <tag>: returns 0 when a token in <tokens> is <tag>'s.
_ot_in() {
  local tok
  for tok in $1; do
    if [[ "${tok%%|*}" == "$2" ]]; then return 0; fi
  done
  return 1
}

# _ot_without <tokens> <tag>: prints <tokens> without <tag>'s.
_ot_without() {
  local tok out=""
  for tok in $1; do
    if [[ "${tok%%|*}" != "$2" ]]; then out="${out} ${tok}"; fi
  done
  printf '%s' "$out"
}

# _open_tags_read: loads the record (see above). Each value is checked
# against its own shape; anything else is dropped. Always returns 0.
_open_tags_read() {
  local out="" kind tag a b c d
  OT_OPEN="" OT_CLOSED="" OT_PSEEN="" OT_MARK=""
  OT_LOADED=1
  [[ -f "$OPEN_TAGS" && -r "$OPEN_TAGS" ]] || return 0
  out="$("$AS_BIN_JQ" -r 'if type == "object" and .schema == 1 then
      ((.open | if type == "array" then .[] else empty end) | select(type == "object")
        | ["O", (.tag | tostring), (.seen_utc | tostring)] | join("|")),
      ((.closed | if type == "array" then .[] else empty end) | select(type == "object")
        | ["C", (.tag | tostring), (.seen_utc | tostring), (.found_utc | tostring),
           (.cause | tostring), (.event | tostring)] | join("|")),
      ("P|" + (.primary_seen_utc // "" | tostring)),
      ("M|" + (.event_mark_utc // "" | tostring))
    else empty end' "$OPEN_TAGS" 2>/dev/null)" || out=""
  while IFS='|' read -r kind tag a b c d; do
    case "$kind" in
      O)
        if [[ "$tag" =~ $OT_TAG_RE && "$a" =~ $AS_UTC_RE ]] && ! _ot_in "$OT_OPEN" "$tag"; then
          OT_OPEN="${OT_OPEN} ${tag}|${a}"
        fi
        ;;
      C)
        case "${c}/${d}" in
          updater/idle-update|updater/pending-restart|unknown/idle-update|unknown/pending-restart|unknown/none) ;;
          *) continue ;;
        esac
        if [[ "$tag" =~ $OT_TAG_RE && "$a" =~ $AS_UTC_RE && "$b" =~ $AS_UTC_RE ]] && ! _ot_in "$OT_CLOSED" "$tag"; then
          OT_CLOSED="${OT_CLOSED} ${tag}|${a}|${b}|${c}|${d}"
        fi
        ;;
      P) if [[ "$tag" =~ $AS_UTC_RE ]]; then OT_PSEEN="$tag"; fi ;;
      M) if [[ "$tag" =~ $AS_UTC_RE ]]; then OT_MARK="$tag"; fi ;;
    esac
  done <<< "$out"
  return 0
}

# _open_tags_write: writes the record through a temp file beside it (mode
# 600 from its creation, so the rename is within one folder), mv and chmod
# 600. Only when the store exists; a write that fails leaves the old record
# and returns 0.
_open_tags_write() {
  local tmp="${OPEN_TAGS}.tmp.$$"
  [[ -d "$STORE" ]] || return 0
  # $o, $c, $p and $m are jq's variables.
  # shellcheck disable=SC2016
  if ( umask 077 && "$AS_BIN_JQ" -n --arg o "$OT_OPEN" --arg c "$OT_CLOSED" --arg p "$OT_PSEEN" --arg m "$OT_MARK" \
        '{schema: 1,
          open: [$o | split(" ")[] | select(length > 0) | split("|") | {tag: .[0], seen_utc: .[1]}],
          closed: [$c | split(" ")[] | select(length > 0) | split("|")
                   | {tag: .[0], seen_utc: .[1], found_utc: .[2], cause: .[3], event: .[4]}],
          primary_seen_utc: (if $p == "" then null else $p end),
          event_mark_utc: (if $m == "" then null else $m end)}' \
        > "$tmp" ) 2>/dev/null \
      && "$AS_BIN_MV" -f "$tmp" "$OPEN_TAGS" 2>/dev/null \
      && "$AS_BIN_CHMOD" 600 "$OPEN_TAGS" 2>/dev/null; then
    return 0
  fi
  "$AS_BIN_RM" -f "$tmp" 2>/dev/null || :
  return 0
}

# _open_tags_set_open <tag> <keep|clear>: <tag>'s open entry is seen now.
# clear also drops its closed entry and, for primary, sets primary_seen_utc.
_open_tags_set_open() {
  local tag="$1"
  if [[ "$tag" == "default" ]]; then tag="primary"; fi
  [[ "$tag" =~ $OT_TAG_RE ]] || return 0
  [[ -d "$STORE" ]] || return 0
  _open_tags_now || return 0
  _open_tags_read
  OT_OPEN="$(_ot_without "$OT_OPEN" "$tag") ${tag}|${OT_NOW_UTC}"
  if [[ "$2" == "clear" ]]; then
    OT_CLOSED="$(_ot_without "$OT_CLOSED" "$tag")"
    if [[ "$tag" == "primary" ]]; then OT_PSEEN="$OT_NOW_UTC"; fi
  fi
  _open_tags_write
  return 0
}

# _open_tags_primary_seen: primary is running (the updater's helper opened
# it), though the switcher doesn't track it: primary_seen_utc is now.
_open_tags_primary_seen() {
  [[ -d "$STORE" ]] || return 0
  _open_tags_now || return 0
  _open_tags_read
  OT_PSEEN="$OT_NOW_UTC"
  _open_tags_write
  return 0
}

# _open_tags_add <tag>: the switcher's open of <tag> succeeded. Its closed
# entry, if any, stays until an instance is seen (_open_tags_back): an open
# that never produced one is not a tag that came back.
_open_tags_add() { _open_tags_set_open "$1" keep; }

# _open_tags_back <tag>: <tag> is running (a wait saw its new PID, or reopen
# counted it): seen now, and its closed entry clears.
_open_tags_back() { _open_tags_set_open "$1" clear; }

# _ot_quit_tag <tag>: adds <tag> to QUIT_TAGS once.
_ot_quit_tag() {
  case ",${QUIT_TAGS}," in
    *",$1,"*) ;;
    *) QUIT_TAGS="${QUIT_TAGS:+${QUIT_TAGS},}$1" ;;
  esac
  return 0
}

# _open_tags_quitting <pid> ...: quit_all_claude calls this before it
# signals anything. The tag of each PID leaves open, so this quit is never
# reported as the app closing it, and joins QUIT_TAGS (unknown stands for an
# instance whose tag can't be told). primary leaving clears primary_seen_utc.
# When the process table can't be read, every open entry is dropped: missing
# a later closure is better than reporting this quit as one. Always returns 0.
_open_tags_quitting() {
  local want=" $* " rows st=0 pid profile method gone="" all=0 t
  rows="$(claude_instances)" || st=$?
  if [[ $st -ne 0 ]]; then
    _ot_quit_tag unknown
    all=1
  else
    while IFS=$'\t' read -r pid profile method; do
      [[ -n "$pid" ]] || continue
      if [[ "$want" != *" ${pid} "* ]]; then continue; fi
      _ot_quit_tag "$profile"
      gone="${gone} ${profile}"
    done <<< "$rows"
  fi
  [[ -d "$STORE" ]] || return 0
  if [[ $all -eq 0 && -z "$gone" ]]; then return 0; fi
  _open_tags_read
  if [[ $all -eq 1 ]]; then
    OT_OPEN=""
  else
    for t in $gone; do
      if [[ "$t" == "unknown" ]]; then continue; fi
      OT_OPEN="$(_ot_without "$OT_OPEN" "$t")"
      if [[ "$t" == "primary" ]]; then OT_PSEEN=""; fi
    done
  fi
  _open_tags_write
  return 0
}

# _applog_update_quits <from> <to>: the app's update closes stamped in
# [<from>, <to>] (local "YYYY-MM-DD HH:MM:SS", as the log stamps them). Sets
# APPLOG_EVENTS to one "<type><TAB><stamp>" line per event, where <type> is
# idle-update or pending-restart. Reads main.log and its numbered copies
# (main1.log, main12.log, ...), never main-window.log, one awk per file;
# the copies' time spans overlap, so files are filtered by time, not order.
# The awk program prints only its own type words and the 19-character
# stamp, never a line ($0), and the shell drops anything else: nothing else
# the log holds (it also holds account and organization ids) can leave this
# function (#24 AC5). Returns 1 when no file can be read.
_applog_update_quits() {
  local from="$1" to="$2" f any=0 out="" typ t
  APPLOG_EVENTS=""
  for f in "${AS_APP_LOG_DIR}/main.log" "${AS_APP_LOG_DIR}"/main[0-9].log "${AS_APP_LOG_DIR}"/main[0-9][0-9].log; do
    [[ -f "$f" && -r "$f" ]] || continue
    any=1
    # $0 is awk's line, used only inside index().
    # shellcheck disable=SC2016
    out="$(AS_FROM="$from" AS_TO="$to" "$AS_BIN_AWK" '
      BEGIN { from = ENVIRON["AS_FROM"]; to = ENVIRON["AS_TO"] }
      /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] / {
        t = substr($0, 1, 19)
        if (t < from || t > to) next
        if (index($0, "[stealth-update] Triggering stealth update after idle timeout") > 0) print "idle-update\t" t
        else if (index($0, "[updater] Auto-restarting app after update pending for") > 0) print "pending-restart\t" t
      }' "$f" 2>/dev/null)" || out=""
    while IFS=$'\t' read -r typ t; do
      case "$typ" in idle-update|pending-restart) ;; *) continue ;; esac
      [[ "$t" =~ $OT_STAMP_RE ]] || continue
      APPLOG_EVENTS="${APPLOG_EVENTS}${typ}"$'\t'"${t}"$'\n'
    done <<< "$out"
  done
  [[ $any -eq 1 ]] || return 1
  return 0
}

# _open_tags_causes <newly closed tokens> <primary_seen before> <running>:
# the cause rule (above) for the tags found closed at this observation.
# Appends each to OT_CLOSED and OT_NEW, writes one CLOSED history row each,
# and moves event_mark_utc past the events it counted.
_open_tags_causes() {
  local newc="$1" p_before="$2" running="$3" tok tag seen ep sj tk j
  local mep="" pep="" readable=1 lo="" from_ep from to u k etype estamp last last_type
  local cause event any_closed_primary=0 max_counted="" mark_utc=""
  if [[ -n "$OT_MARK" ]]; then mep="$(_utc_epoch "$OT_MARK")" || mep=""; fi
  if [[ -n "$p_before" ]]; then pep="$(_utc_epoch "$p_before")" || pep=""; fi
  # Each tag's span starts at its seen time less the slack, and after the
  # mark; the reader is asked once, from the earliest of those starts.
  local spans=""
  for tok in $newc; do
    tag="${tok%%|*}"
    seen="${tok#*|}"
    if [[ "$tag" == "primary" ]]; then any_closed_primary=1; fi
    ep="$(_utc_epoch "$seen")" || ep=""
    if [[ -z "$ep" ]]; then spans="${spans} ${tag}|x|x"; continue; fi
    from_ep=$((ep - APPLOG_SLACK_S))
    if [[ -n "$mep" && $from_ep -le $mep ]]; then from_ep=$((mep + 1)); fi
    spans="${spans} ${tag}|${ep}|${from_ep}"
    if [[ -z "$lo" || $from_ep -lt $lo ]]; then lo="$from_ep"; fi
  done
  to="$(_ot_local "$OT_NOW_EP")" || to=""
  from=""
  if [[ -n "$lo" ]]; then from="$(_ot_local "$lo")" || from=""; fi
  if [[ -z "$from" || -z "$to" ]] || ! _applog_update_quits "$from" "$to"; then readable=0; fi
  for tok in $spans; do
    IFS='|' read -r tag ep from_ep <<< "$tok"
    cause="unknown"
    event="none"
    if [[ "$ep" != "x" && $readable -eq 1 ]]; then
      from="$(_ot_local "$from_ep")" || from=""
      u=0
      last=""
      last_type="none"
      while IFS=$'\t' read -r etype estamp; do
        [[ -n "$etype" ]] || continue
        if [[ -n "$from" && ! "$estamp" < "$from" ]]; then
          u=$((u + 1))
          if [[ -z "$last" || "$estamp" > "$last" ]]; then last="$estamp"; last_type="$etype"; fi
        fi
      done <<< "$APPLOG_EVENTS"
      event="$last_type"
      if [[ -n "$last" ]] && [[ -z "$max_counted" || "$last" > "$max_counted" ]]; then max_counted="$last"; fi
      # k: the closures that must have fallen in this span.
      k=0
      for j in $spans; do
        sj="${j#*|}"
        sj="${sj%%|*}"
        if [[ "$sj" != "x" && $sj -ge $ep ]]; then k=$((k + 1)); fi
      done
      if [[ -n "$pep" && $pep -ge $ep && $any_closed_primary -eq 0 ]]; then
        if [[ "$running" != *" primary "* ]]; then
          k=$((k + 1))
        elif ! _updater_log_scan "$(_ot_local "$ep")" || [[ $UPD_LOG_DONE -gt 0 ]]; then
          # Running again after a completed install (or the helper's log
          # can't be read, so that can't be ruled out): its close used an
          # event too.
          k=$((k + 1))
        fi
      fi
      if [[ $k -ge 1 && $u -ge $k ]]; then cause="updater"; fi
    fi
    seen=""
    for tk in $newc; do
      if [[ "${tk%%|*}" == "$tag" ]]; then seen="${tk#*|}"; fi
    done
    OT_CLOSED="${OT_CLOSED} ${tag}|${seen}|${OT_NOW_UTC}|${cause}|${event}"
    OT_NEW="${OT_NEW:+${OT_NEW} }${tag}:${cause}"
    if [[ -d "$STORE" ]]; then
      _swap_log_ensure
      printf '[%s] CLOSED tag=%s seen=%s cause=%s event=%s\n' \
        "$OT_NOW_UTC" "$tag" "$seen" "$cause" "$event" >> "$SWAP_LOG" || :
    fi
  done
  if [[ -n "$max_counted" ]]; then
    mark_utc="$(_update_local_to_utc "$max_counted")" || mark_utc=""
    if [[ "$mark_utc" =~ $AS_UTC_RE ]]; then OT_MARK="$mark_utc"; fi
  fi
  return 0
}

# open_tags_observe: one observation (see above). Compares the record's open
# tags with the running instances: a running tag is seen now; one that is
# gone is newly closed, with its cause; a running instance started with
# --user-data-dir (other than primary) that isn't tracked is adopted; a
# closed tag that runs again clears. It records nothing closed when the read
# is undetermined (the app binary is not where detection looks, the process
# table can't be read, or an instance's tag is unknown), though it still
# refreshes what it sees running. Sets OT_NEW and OT_RUNNING_N. Always
# returns 0.
open_tags_observe() {
  local rows st=0
  OT_NEW=""
  OT_RUNNING_N=""
  app_binary_present || return 0
  rows="$(claude_instances)" || st=$?
  [[ $st -eq 0 ]] || return 0
  _open_tags_observe_rows "$rows"
}

# _open_tags_observe_rows <claude_instances rows>: the observation, from
# rows the caller has already read (update observes from its own listing
# read, so it reads the process table no more often than before).
_open_tags_observe_rows() {
  local rows="$1" pid profile method running=" " argv=" " undetermined=0 n=0
  local tok tag seen newc="" changed=0 p_before new_open="" new_closed=""
  OT_NEW=""
  OT_RUNNING_N=""
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    n=$((n + 1))
    if [[ "$profile" == "unknown" ]]; then undetermined=1; continue; fi
    running="${running}${profile} "
    if [[ "$method" == "argv" && "$profile" != "primary" ]]; then argv="${argv}${profile} "; fi
  done <<< "$rows"
  OT_RUNNING_N="$n"
  [[ -d "$STORE" ]] || return 0
  _open_tags_now || return 0
  _open_tags_read
  p_before="$OT_PSEEN"
  for tok in $OT_OPEN; do
    tag="${tok%%|*}"
    seen="${tok#*|}"
    if [[ "$running" == *" ${tag} "* ]]; then
      new_open="${new_open} ${tag}|${OT_NOW_UTC}"
      if [[ "$seen" != "$OT_NOW_UTC" ]]; then changed=1; fi
    elif [[ $undetermined -eq 1 ]]; then
      new_open="${new_open} ${tok}"
    elif _ot_in "$OT_CLOSED" "$tag"; then
      # An open since that closure never produced an instance (reopen or
      # launch exited without one): the first closure and its cause stand,
      # and no second row is written.
      changed=1
    else
      newc="${newc} ${tok}"
      changed=1
    fi
  done
  for tag in $argv; do
    if ! _ot_in "$new_open" "$tag"; then
      new_open="${new_open} ${tag}|${OT_NOW_UTC}"
      changed=1
    fi
  done
  OT_OPEN="$new_open"
  for tok in $OT_CLOSED; do
    if [[ "$running" == *" ${tok%%|*} "* ]]; then changed=1; else new_closed="${new_closed} ${tok}"; fi
  done
  OT_CLOSED="$new_closed"
  if [[ "$running" == *" primary "* && "$OT_PSEEN" != "$OT_NOW_UTC" ]]; then
    OT_PSEEN="$OT_NOW_UTC"
    changed=1
  fi
  if [[ -n "$newc" ]]; then _open_tags_causes "$newc" "$p_before" "$running"; fi
  if [[ $changed -eq 1 ]]; then _open_tags_write; fi
  return 0
}

# _open_tags_cause_text <updater|unknown>
_open_tags_cause_text() {
  case "$1" in
    updater) printf "closed by the app's updater" ;;
    *)       printf 'closed, cause unknown' ;;
  esac
}

# open_tags_notice: launch, swap and update print one warning line naming
# the tags this run's observation found closed.
open_tags_notice() {
  local tok list=""
  [[ -n "$OT_NEW" ]] || return 0
  for tok in $OT_NEW; do
    list="${list:+${list}, }${tok%%:*} ($(_open_tags_cause_text "${tok#*:}"))"
  done
  warn "Since the switcher last saw them running, Claude closed: ${list}. account-switcher list shows them; account-switcher reopen brings back the ones the updater closed."
  return 0
}

# _open_tags_section: list's section of every recorded closure, printed only
# when there is one.
_open_tags_section() {
  local tok tag seen found cause event any_u=0 any_k=0
  if [[ $OT_LOADED -eq 0 ]]; then _open_tags_read; fi
  [[ -n "${OT_CLOSED// /}" ]] || return 0
  printf 'Tags Claude closed without the switcher (since it last saw them running):\n'
  for tok in $OT_CLOSED; do
    IFS='|' read -r tag seen found cause event <<< "$tok"
    printf '  %-12s %-30slast seen %s\n' "$tag" "$(_open_tags_cause_text "$cause")" "$seen"
    if [[ "$cause" == "updater" ]]; then any_u=1; else any_k=1; fi
  done
  if [[ $any_u -eq 1 ]]; then printf "  Reopen the ones the app's updater closed: account-switcher reopen\n"; fi
  if [[ $any_k -eq 1 ]]; then printf '  Reopen one closed for an unknown reason: account-switcher launch <tag>\n'; fi
  printf '\n'
  return 0
}

# The update lock is a directory, made with mkdir, which fails when the
# directory exists, so two runs cannot both take it. It holds one file,
# owner: "pid=<n> started_epoch=<n> started_utc=<ISO UTC>". update takes it
# before it closes anything and releases it last (also from its EXIT trap);
# launch, swap and signin refuse while it exists, so the switcher never
# starts the app while its bundle may be being replaced. (Opening Claude from
# the Dock is not stopped.) The settings-sync lock (#11, PREFS_LOCK) is the
# same kind of directory, taken by every command that writes a profile's
# settings or the sync state. The helpers below take the lock's path, so the
# two locks are one implementation and behave alike.
#
# A lock older than 10 minutes is reported as stale, with its remedy, and
# still refuses. The switcher never removes a lock it did not take: age
# alone does not show that the run which took it has stopped (an install can
# hang, and a PID can be reused), and starting the app mid-install is what
# the lock exists to prevent. The operator checks, then removes it with
# trash.

# _lock_held <dir>: returns 0 and sets LOCK_STALE (1 or 0), LOCK_AGE (text)
# and LOCK_PID when the lock exists; returns 1 otherwise. Builtins only
# until a lock is found.
_lock_held() {
  local dir="$1" line="" ep="" now="" age="" re='^pid=([0-9]+) started_epoch=([0-9]+) '
  LOCK_STALE=1
  LOCK_AGE="of unknown age"
  LOCK_PID="unknown"
  [[ -d "$dir" ]] || return 1
  if [[ -f "${dir}/owner" && -r "${dir}/owner" ]]; then
    { IFS= read -r line || :; } < "${dir}/owner"
  fi
  if [[ "${line} " =~ $re ]]; then
    LOCK_PID="${BASH_REMATCH[1]}"
    ep="${BASH_REMATCH[2]}"
  fi
  now="$("$AS_BIN_DATE" +%s 2>/dev/null)" || now=""
  if [[ -n "$ep" && "$now" =~ ^[0-9]+$ ]]; then
    age=$((now - ep))
    if [[ $age -lt 0 ]]; then age=0; fi
    LOCK_AGE="$(_fmt_duration "$age") old"
    if [[ $age -le $LOCK_STALE_S ]]; then LOCK_STALE=0; fi
  fi
  return 0
}

# _lock_refusal <dir> <doing>: the refusal text for a held lock (call it
# after _lock_held returned 0); <doing> is e.g. "launching". Both locks are
# named by their path under ~ (_tilde_path), so no message prints the home
# folder's absolute path.
_lock_refusal() {
  local dir="$1" shown
  if [[ "$dir" == "$PREFS_LOCK" ]]; then
    shown="$(_tilde_path "$dir")"
    if [[ "$LOCK_STALE" == "0" ]]; then
      printf "A settings sync is running (the lock %s is %s, taken by PID %s). Not %s while it may be writing a profile's settings; wait for it to finish, then run the command again." \
        "$shown" "$LOCK_AGE" "$LOCK_PID" "$2"
    else
      printf "The settings-sync lock %s is %s (taken by PID %s), past the 10-minute limit, so it is probably left from a sync that stopped. Not %s. The switcher never removes a lock it did not take. If no swap, clone-prefs or prefs command is running, remove it: trash %s" \
        "$shown" "$LOCK_AGE" "$LOCK_PID" "$2" "$shown"
    fi
    return 0
  fi
  shown="$(_tilde_path "$dir")"
  if [[ "$LOCK_STALE" == "0" ]]; then
    printf 'An update is running (the lock %s is %s, taken by PID %s). Not %s while the app bundle may be being replaced; wait for account-switcher update to finish.' \
      "$shown" "$LOCK_AGE" "$LOCK_PID" "$2"
  else
    printf "The update lock %s is %s (taken by PID %s), past the 10-minute limit, so it is probably left from an update that stopped. Not %s. The switcher never removes a lock it did not take. If no update is running (the updater's log does not end with 'Beginning installation'; account-switcher list shows the versions), remove it: trash %s" \
      "$shown" "$LOCK_AGE" "$LOCK_PID" "$2" "$shown"
  fi
}

# _lock_take <dir>: takes the lock for this run, or returns 1 when it exists
# (or cannot be made). A run holds at most one lock at a time.
_lock_take() {
  "$AS_BIN_MKDIR" -m 700 "$1" 2>/dev/null || return 1
  LOCK_OWNED="$1"
  printf 'pid=%s started_epoch=%s started_utc=%s\n' "$$" "$("$AS_BIN_DATE" +%s)" \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" > "${1}/owner" || :
  return 0
}

# Releases the lock, only when this run took it.
_lock_release() {
  local dir="$LOCK_OWNED"
  [[ -n "$dir" ]] || return 0
  LOCK_OWNED=""
  "$AS_BIN_RM" -f "${dir}/owner" 2>/dev/null || :
  if ! "$AS_BIN_RM" -d "$dir" 2>/dev/null; then
    if [[ "$dir" == "$PREFS_LOCK" ]]; then
      warn "Could not remove the settings-sync lock $(_tilde_path "$dir"); remove it with: trash $(_tilde_path "$dir")"
    else
      warn "Could not remove the update lock $(_tilde_path "$dir"); remove it with: trash $(_tilde_path "$dir")"
    fi
  fi
  return 0
}

# The update lock's names for the helpers above.
_update_lock_held() { _lock_held "$UPDATE_LOCK"; }
_update_lock_refusal() { _lock_refusal "$UPDATE_LOCK" "$1"; }
_update_lock_take() { _lock_take "$UPDATE_LOCK"; }
_update_lock_release() { _lock_release; }

# _tilde_path <path>: the path with a leading $HOME written as ~.
_tilde_path() {
  # A literal ~ is the point here (display text), so SC2088 does not apply.
  # shellcheck disable=SC2088
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---- The unknown-tag guard (#10) ------------------------------------------
#
# launch and swap would create a new, empty profile folder for any tag that
# passes the format check, a typo included. They refuse a tag that is not in
# [accounts] and has no profile folder, unless --new (the same flag, with the
# same meaning, as signin's). primary and default always pass: they name the
# app's own default folder. A folder that exists passes even when its tag is
# not in [accounts]; list reports it as unconfigured.

# _closest_tag <tag> <candidates, one per line>: the candidate with the
# smallest edit distance to <tag> (the first one on a tie), or nothing.
_closest_tag() {
  printf '%s\n' "${2:-}" | AS_WANT="${1:-}" "$AS_BIN_AWK" '
    function lev(s, t,   m, n, i, j, c, x, d) {
      split("", d)
      m = length(s); n = length(t)
      for (i = 0; i <= m; i++) d[i, 0] = i
      for (j = 0; j <= n; j++) d[0, j] = j
      for (i = 1; i <= m; i++) {
        for (j = 1; j <= n; j++) {
          c = (substr(s, i, 1) == substr(t, j, 1)) ? 0 : 1
          x = d[i - 1, j] + 1
          if (d[i, j - 1] + 1 < x) x = d[i, j - 1] + 1
          if (d[i - 1, j - 1] + c < x) x = d[i - 1, j - 1] + c
          d[i, j] = x
        }
      }
      return d[m, n]
    }
    NF { x = lev(ENVIRON["AS_WANT"], $0); if (best == "" || x < bd) { best = $0; bd = x } }
    END { if (best != "") print best }'
}

# unknown_tag_guard <tag> <new: true|false> <launch|swap>: returns 0, or
# refuses (exit 1) with the configured tags and the closest match, before
# anything is opened, quit or written.
unknown_tag_guard() {
  local tag="$1" new="$2" verb="$3" tags="" list="" closest=""
  case "$tag" in primary|default) return 0 ;; esac
  if tag_is_in_accounts "$tag"; then return 0; fi
  if [[ -d "$(udd_for_tag "$tag")" ]]; then return 0; fi
  if [[ "$new" == "true" ]]; then
    info "'${tag}' is not in [accounts] and has no profile folder; ${verb} creates a new one (--new)."
    return 0
  fi
  tags="$(accounts_tags)" || tags=""
  if [[ -n "$tags" ]]; then
    list="${tags//$'\n'/, }"
    closest="$(_closest_tag "$tag" "$tags")" || closest=""
    die "Tag '${tag}' is not in [accounts] and has no profile folder, so ${verb} would create a new, empty profile. Configured tags: ${list}. Closest match: ${closest:-none}. If '${tag}' is a new tag on purpose: account-switcher ${verb} ${tag} --new"
  fi
  die "Tag '${tag}' is not in [accounts] and has no profile folder, so ${verb} would create a new, empty profile. No tag is configured in [accounts] of ${CONFIG_FILE}. If '${tag}' is a new tag on purpose: account-switcher ${verb} ${tag} --new"
}

# ---- launch (additive; H-1) ----------------------------------------------

# open_tag_instance <tag> <user-data-dir> <first_launch: true|false>
# The open path launch, signin (#7) and update's reopen (#10) share: starts a
# new instance for the tag (primary without the flag), records the tag in
# the statusline marker and appends the LAUNCH row. Returns 1, writing
# neither, when open fails: a caller in a condition (signin, update) runs
# with errexit off, so the status must say so itself (F-05).
open_tag_instance() {
  local tag="$1" udd="$2" first_launch="$3"
  if [[ "$tag" == "primary" ]] || [[ "$tag" == "default" ]]; then
    "$AS_BIN_OPEN" -n -a "Claude" || return 1
  else
    "$AS_BIN_OPEN" -n -a "Claude" --args --user-data-dir="$udd" || return 1
  fi

  printf '%s\n' "$tag" > "$STATUSLINE_MARKER"

  _swap_log_ensure
  printf '[%s] LAUNCH tag=%s udd=%s first_launch=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$udd" "$first_launch" \
    >> "$SWAP_LOG"

  # #24: the tag is tracked from its open.
  _open_tags_add "$tag"
}

cmd_launch() {
  local tag="" force="false" new="false" arg
  for arg; do
    case "$arg" in
      --force) force="true" ;;
      --new) new="true" ;;
      -*) die "Unknown flag: ${arg} (launch takes <tag> [--force] [--new])" ;;
      *)
        if [[ -z "$tag" ]]; then tag="$arg"; else die "Unexpected arg: ${arg}"; fi
        ;;
    esac
  done
  if [[ -z "$tag" ]]; then
    die "Usage: account-switcher launch <tag> [--force] [--new]  (e.g. primary, backup)"
  fi
  validate_tag "$tag"

  # #10: never while update holds its lock, and never a tag that is neither
  # configured nor on disk (--new allows it). Both run before the #6 check.
  if _update_lock_held; then die "$(_update_lock_refusal launching)"; fi
  unknown_tag_guard "$tag" "$new" launch

  # #6: check the account the profile records before opening anything. A
  # MISMATCH refuses here (--force overrides); unknown proceeds with a hint.
  identity_gate "$tag" "$force" launch

  # #24: an observation, after the #6 check so a refusal writes nothing.
  open_tags_observe
  open_tags_notice

  # #10, #24: one line while an app update is staged.
  update_wait_warning

  # #9: launch never uses detection to avoid a second process (it always
  # opens a new one), only to find the new window for its report, so a
  # missing app binary is a warning here, not a refusal.
  app_binary_warn

  local udd
  udd=$(udd_for_tag "$tag")
  local first_launch="false"
  [[ -d "$udd" ]] || first_launch="true"

  info "Launching Claude desktop app: tag=${tag}"
  info "  user-data-dir: ${udd}"
  if [[ "$first_launch" == "true" ]]; then
    info "  (first launch — Claude will prompt for login in the new window)"
  fi

  # #8: every main process running before `open`, so the wait below takes
  # only a process that is new.
  local pre_pids
  pre_pids="$(get_claude_pids)"

  open_tag_instance "$tag" "$udd" "$first_launch" || die "Could not open the '${tag}' instance (open failed); nothing was launched."

  ok "Launched. Look for the new Claude window."

  if [[ "$first_launch" == "true" ]]; then
    info ""
    info "Next: sign this profile in with: account-switcher signin ${tag}"
    info "(it uses this window, names the account to sign in as, and checks that no other profile changed)."
    info "After sign-in, the user-data-dir holds that account's auth + chat + plugins, and later launches skip the sign-in screen."
  fi

  # #8: wait for the new instance, bring it to the front, end with its line.
  # The launch itself has happened, so this never changes the exit status.
  _launch_report "$tag" "$pre_pids"
}

# ---- list (running instances + configured profile dirs) ------------------

cmd_list_instances() {
  app_binary_warn
  # #24: an observation; the section after the instance rows lists what it
  # found.
  open_tags_observe
  printf '\n=== Running Claude desktop app instances ===\n\n'

  # One row per main process from claude_instances. via= says how the tag
  # was found, so primary is never shown without a reason.
  local rows st=0 found=0 pid profile method udd
  rows="$(claude_instances)" || st=$?
  if [[ $st -ne 0 ]]; then
    printf '  (the process table could not be read; running instances unknown)\n'
  else
    while IFS=$'\t' read -r pid profile method; do
      [[ -n "$pid" ]] || continue
      found=1
      if [[ "$profile" == "unknown" ]]; then
        udd="(unknown)"
      else
        udd="$(udd_for_tag "$profile")"
      fi
      printf '  PID %-7s tag=%-12s via=%-8s data-dir=%s\n' "$pid" "$profile" "$method" "$udd"
    done <<< "$rows"
    if [[ $found -eq 0 ]]; then
      printf '  (no Claude desktop app instances running)\n'
    else
      printf '\n  via: argv = its --user-data-dir argument; flagless = the only instance\n'
      printf '  started without one (primary); lsof = the profile folder it holds open;\n'
      printf '  none = the tag could not be determined (tag=unknown).\n'
    fi
  fi
  printf '\n'
  _open_tags_section

  # #10: every Claude-* folder whose tag is not in [accounts] is marked
  # unconfigured. list only reports it; it never deletes a folder.
  printf 'Profile folders (under "%s"):\n' "${AS_PROFILE_ROOT}/"
  local tag size note unconfigured=0
  for d in "${AS_PROFILE_ROOT}/Claude" "${AS_PROFILE_ROOT}/Claude-"*; do
    [[ -d "$d" ]] || continue
    tag=$("$AS_BIN_BASENAME" "$d" | "$AS_BIN_SED" 's/^Claude-//; s/^Claude$/primary/')
    size=$("$AS_BIN_DU" -sh "$d" 2>/dev/null | "$AS_BIN_AWK" '{print $1}')
    note=""
    if [[ "$d" != "${AS_PROFILE_ROOT}/Claude" ]]; then
      if [[ ! "$tag" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || ! tag_is_in_accounts "$tag"; then
        note="  unconfigured"
        unconfigured=$((unconfigured + 1))
      fi
    fi
    printf '  %-12s %s  (%s)%s\n' "$tag" "$d" "${size:-?}" "$note"
  done
  if [[ $unconfigured -gt 0 ]]; then
    printf '\n  unconfigured: a Claude-* folder whose tag is not in [accounts]. The switcher\n'
    printf '  never deletes one. Register it (account-switcher add-account <tag> <email>),\n'
    printf '  or, once you are sure nothing in it is needed, trash the folder yourself.\n'
  fi
  printf '\n'

  # #10: the one app and its updater, shared by every tag.
  update_observe
  printf 'App update (one app and one updater serve every tag):\n'
  if [[ "$UPD_INSTALLED" == "unknown" ]]; then
    printf '  installed: unknown (%s)\n' "$UPD_INSTALLED_WHY"
  else
    printf '  installed: %s\n' "$UPD_INSTALLED"
  fi
  case "$UPD_STAGED" in
    unknown)
      printf '  staged:    unknown (%s)\n' "$UPD_WHY"
      printf '  waiting:   unknown\n'
      ;;
    none)
      printf '  staged:    none\n'
      ;;
    *)
      printf '  staged:    %s\n' "$UPD_STAGED"
      if [[ -n "$UPD_WAIT_S" ]]; then
        printf '  waiting:   %s (since %s)\n' "$(_fmt_duration "$UPD_WAIT_S")" "$UPD_FIRST_SEEN"
      else
        printf '  waiting:   unknown\n'
      fi
      # #24: while any instance is open (or the process table could not be
      # read, so none can be ruled out).
      if [[ "$OT_RUNNING_N" != "0" ]]; then
        printf '  warning:   the %s\n' "$(_update_idle_close_text)"
      fi
      ;;
  esac
  if _update_lock_held; then
    if [[ "$LOCK_STALE" == "0" ]]; then
      printf '  update:    running (lock %s, taken by PID %s)\n' "$LOCK_AGE" "$LOCK_PID"
    else
      printf '  update:    stale lock (%s, taken by PID %s): %s\n' "$LOCK_AGE" "$LOCK_PID" "$(_tilde_path "$UPDATE_LOCK")"
      printf '             If no update is running, remove it: trash %s\n' "$(_tilde_path "$UPDATE_LOCK")"
    fi
  fi
  case "$UPD_STAGED" in
    unknown|none) ;;
    *)
      printf '  An update installs only when every Claude instance is closed.\n'
      printf '  To close them, install it and reopen the same tags: account-switcher update\n'
      ;;
  esac
  printf '\n'
}

# ---- Settings sync between profiles (#11) ---------------------------------
#
# Each profile keeps its own claude_desktop_config.json. The switcher keeps a
# short allowlist of global UI preferences (class G, PREFS_ALLOW) consistent
# across the participating profiles, one key at a time, and never writes
# anything else in the file. A value is chosen per key by change memory (the
# value the switcher last saw in each profile, kept in PREFS_STATE), latest
# wins (a change seen in one profile becomes the fleet value) and defaults
# from primary (proposed in review when a key has no history and the profiles
# disagree). Two different changes first seen in the same run have no known
# order, so the key goes to review instead. The rules engine is one jq
# program, PREFS_PLAN_JQ; bash 3.2 has no associative arrays, so no per-key
# logic lives in bash. Keys are addressed by path arrays passed with
# --argjson and read with getpath/setpath, never by a dotted jq path: many
# names under epitaxyPrefs are flat names that contain dots.
#
# Commands: swap (its target, after every instance has quit), clone-prefs
# (its target), and `prefs` (diff, sync, review, adopt, pin, unpin, undo).
# launch never reads or writes a settings file. Nothing deletes: no command
# removes a settings file, a key in one, or a prior copy, with one stated
# exception: `prefs undo <tag>` removes a key the last sync added to <tag>
# that still holds the value that sync wrote. Output names tags,
# key ids, allowlisted values (booleans and short strings) and counts, never
# an account, org, session or project id, a path or an email.
#
# Participating profiles: primary plus every [accounts] tag whose profile
# folder exists (default is primary). A profile is running when a row of
# claude_instances resolves to it. Every write re-checks that just before its
# rename. Every command but swap writes nothing, and says why, when more than
# one main process has no --user-data-dir (the raw FLAGLESS class), when a
# row reads unknown, or when the process table cannot be read; swap runs its
# settings step after every instance has quit, so only the per-write re-check
# applies to it, and it skips the step with a warning when the table cannot
# be read.

readonly PREFS_FILE="claude_desktop_config.json"
readonly PREFS_TMP_PREFIX=".as-prefs-tmp."

# Class G, the allowlist: the only paths the switcher ever writes. Each path
# is an array of literal key names.
readonly PREFS_ALLOW='[
  {"id":"sidebar-mode","path":["preferences","sidebarMode"],"type":"string"},
  {"id":"keep-awake","path":["preferences","keepAwakeEnabled"],"type":"boolean"},
  {"id":"preferred-browser","path":["preferences","coworkPreferredBrowser"],"type":"string"},
  {"id":"new-session-worktree","path":["preferences","epitaxyPrefs","cc-landing-worktree-enabled"],"type":"boolean"},
  {"id":"transcript-links-in-preview","path":["preferences","epitaxyPrefs","epitaxy-transcript-links-in-preview"],"type":"boolean"},
  {"id":"preferred-editor","path":["preferences","epitaxyPrefs","claude-code-preferred-editor"],"type":"string"},
  {"id":"projects-library-layout","path":["preferences","epitaxyPrefs","projects.library.layout"],"type":"string"},
  {"id":"projects-library-small-icons","path":["preferences","epitaxyPrefs","projects.library.smallIcons"],"type":"boolean"}
]'

# The exact-name classes, per family level: "top" (a top-level key),
# "pref" (a child of preferences) and "epx" (a child of
# preferences.epitaxyPrefs). G names come from PREFS_ALLOW. C capability
# toggles, S security or policy, L profile-local, and A the account-keyed
# maps; A and L also match by shape (PREFS_DEFS classify), and anything left
# is U, unclassified, which is never written.
readonly PREFS_CLASSES='{
  "top": {"coworkUserFilesPath":"L"},
  "pref": {
    "chromeExtensionEnabled":"C","coworkBrowserToolsEnabled":"C","coworkWebSearchEnabled":"C",
    "bypassPermissionsModeEnabled":"S","allowAllBrowserActions":"S","localAgentModeTrustedFolders":"S",
    "launchPreviewAllowedOrigins":"S","ccRemoteControlDefaultEnabled":"S","remoteControlPinnedFolders":"S",
    "remoteControlExcludedFolders":"S","ccdScheduledTasksEnabled":"S","coworkScheduledTasksEnabled":"S",
    "coworkHipaaRestricted":"S","orgWorkAcrossAppsDisabled":"S",
    "chromeExtension":"L","remoteToolsDeviceName":"L","coworkLegacyRootGrantsPruned":"L",
    "launchChromeImportPrompt":"L","launchPreviewPersistedWorkspaces":"L",
    "launchPreviewSessionScopedSessions":"L","remoteSessionFolderGrants":"L",
    "bypassPermissionsGateByAccount":"A","coworkModelAutoFallbackByAccount":"A"},
  "epx": {
    "cc-landing-draft-permission-mode":"S",
    "ccd-sessions-filter":"L","closedWidgetTools":"L","code-sessions-status-filter":"L",
    "desktop-frame.paneStore.v1":"L","dframe-local-slice":"L","epitaxy-files-tree-width":"L",
    "epitaxy-serene-whistle-decided":"L","epitaxy-split-suggestion":"L",
    "epitaxy-transcript-links-chooser-seen":"L","projects.library.guidanceDismissed":"L",
    "projects.overviewColumnFlex":"L","projects.retiredAntPicksCleared":"L","starred-cowork-spaces":"L",
    "starred-local-code-sessions":"L","starred-local-routines":"L","starred-session-groups":"L",
    "dframe-code-sections":"A","dframe-group-scopes":"A"}
}'

# Shared jq definitions. ABS marks a key a profile does not hold; allowlisted
# values are always scalars, so the marker cannot collide with a value. mask
# hides identifiers by shape: uuids, session ids, emails, hex runs and paths,
# and (S-04) any token of 8 or more letters and digits that mixes both
# (prefixed base62 ids, ULIDs, the id in a local_ value) and any run of 6 or
# more digits. show routes numbers through mask too. Ordinary key names,
# booleans, short words and version strings such as 4.29.0 pass unchanged.
readonly PREFS_DEFS='
def ABS: {"absent": true};
def isabs: type == "object" and .absent == true;
def among($a): . as $x | any($a[]; . == $x);
def haspath($p):
  if ($p | length) == 0 then true
  elif type == "object" and has($p[0]) then (.[$p[0]] | haspath($p[1:]))
  else false end;
def parentok($p): (try getpath($p[:-1]) catch null) | type == "object";
def val($p): if haspath($p) then getpath($p) else ABS end;
def allsame: (map(.cur | tojson) | unique | length) == 1;
def UUID: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
def MIXED: "(?<![A-Za-z0-9])(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{8,}(?![A-Za-z0-9])";
def mask: gsub(UUID; "<id>") | gsub("session_[A-Za-z0-9_-]+"; "<session-id>")
  | gsub("[^ \"<>]+@[^ \"<>]+"; "<email>") | gsub("[0-9a-fA-F-]{12,}"; "<id>") | gsub("/[^ \"<>]*"; "<path>")
  | gsub(MIXED; "<id>") | gsub("[0-9]{6,}"; "<id>");
def show:
  if isabs then "absent"
  elif type == "number" then (tojson | mask)
  elif type == "boolean" or type == "null" then tojson
  elif type == "array" or type == "object" then "\(length) \(if length == 1 then "entry" else "entries" end)"
  elif (length <= 40) and test("^[A-Za-z0-9 ._:+-]*$") and (mask == .) then tojson
  else "<masked>" end;
'

# The rules engine. Input: the readable profiles' files (in $m.readable
# order) and $m: allow, state, readable, named (the profiles this command may
# write), running, now, and optionally pins (in place of the state's),
# decisions ({key-id: {value, by, from}}: review and adopt) and only_decided
# (leave every other key untouched). Output: one plan entry per key with its
# status, fleet value, writes (tags), held (tags named but not written, and
# why), kept (pinned tags), and the per-profile records.
#   status: type (a value's type differs in some profile: left alone),
#   unset (no profile holds it), init (no history, all agree), review
#   (pending), agreed (pending, but every unpinned profile agrees again),
#   steady (no profile changed it), latest (changes, all to one value),
#   decided (set by review or adopt), untouched.
readonly PREFS_PLAN_JQ='
[inputs] as $docs
| ($m.state.keys // {}) as $keys
| ($m.pins // $m.state.pins // {}) as $pins
| [range(0; $m.readable | length) as $i | {tag: $m.readable[$i], doc: $docs[$i]}] as $profs
| { now: $m.now,
    keys: [ $m.allow[] as $k
      | ($keys[$k.id] // null) as $e
      | (($m.decisions // {})[$k.id] // null) as $dec
      | if ($m.only_decided == true) and $dec == null then
          {id: $k.id, path: $k.path, status: "untouched", entry: $e, recs: [], writes: [], held: [], kept: []}
        else
          [ $profs[] as $p
            | ($p.doc | val($k.path)) as $cur
            | (($e.seen // {}) | has($p.tag)) as $sh
            | (if $sh then $e.seen[$p.tag] else null end) as $sv
            | ($sh and ($sv | type) == "object") as $sabs
            | {tag: $p.tag, cur: $cur, absent: ($cur | isabs),
               pinned: (($pins[$p.tag] // []) | any(.[]; . == $k.id or . == "*")),
               parentok: ($p.doc | parentok($k.path)),
               typeok: (($cur | isabs) or (($cur | type) == $k.type)),
               changed: (if ($sh | not) then false elif ($cur | isabs) then false
                         elif $sabs then true else $cur != $sv end),
               removed: (($cur | isabs) and $sh and (($sabs | not) or ($sv.removed == true)))}
          ] as $recs
          | ($recs | map(select(.pinned | not))) as $U
          | ($e != null and ($e | has("fleet"))) as $hasfleet
          | ($e.pending // null) as $pend
          | (if any($recs[]; .typeok | not) then {status: "type"}
             elif $dec != null then {status: "decided", fleet: $dec.value, by: $dec.by, from: $dec.from}
             elif $pend != null then
               (if ($U | length) > 0 and all($U[]; .absent | not) and ($U | allsame)
                then {status: "agreed", fleet: $U[0].cur, by: (if $hasfleet then "latest" else "init" end)}
                else {status: "review", reason: $pend.reason} end)
             elif ($hasfleet | not) then
               ($U | map(select(.absent | not))) as $present
               | if ($U | length) > 0 and ($present | length) == ($U | length) and ($U | allsame)
                 then {status: "init", fleet: $U[0].cur, by: "init"}
                 elif ($present | length) == 0 then {status: "unset"}
                 else {status: "review", reason: "init"} end
             else
               ($U | map(select(.changed))) as $C
               | if ($C | length) == 0 then {status: "steady", fleet: $e.fleet}
                 elif ($C | allsame) then {status: "latest", fleet: $C[0].cur, by: "latest", from: ($C | map(.tag) | join(","))}
                 else {status: "review", reason: "conflict"} end
             end) as $r
          | (($r.status | among(["type", "review", "unset"])) | not) as $settled
          | (if $settled then [$U[] | select((.removed | not) and (.cur != $r.fleet))] else [] end) as $targets
          | [$targets[] | select((.tag | among($m.named)) and ((.tag | among($m.running)) | not) and .parentok) | .tag] as $writes
          | [$targets[] | select(.tag | among($m.named)) | select((.tag | among($writes)) | not)
             | {tag, why: (if (.tag | among($m.running)) then "running" else "no-parent" end)}] as $held
          | (if $settled then [$recs[] | select(.pinned and (.tag | among($m.named)) and (.cur != $r.fleet)) | .tag] else [] end) as $kept
          | ($recs | map(select(.tag == "primary" and (.absent | not))) | .[0].cur) as $prim
          | {id: $k.id, path: $k.path, type: $k.type, status: $r.status, entry: $e,
             fleet: (if $settled then $r.fleet else $e.fleet end),
             hasfleet: ($settled or $hasfleet),
             decided: (if ($r.status | among(["init", "agreed", "latest", "decided"])) then
                         {at: $m.now, by: $r.by} + (if $r.from then {from: $r.from} else {} end)
                       elif $settled then $e.decided else null end),
             pending: (if $r.status == "review" then
                         {since: ($pend.since // $m.now), reason: ($pend.reason // $r.reason),
                          candidates: ($U | map({(.tag): .cur}) | add // {})}
                       else null end),
             proposed: (if ($r.status == "review") and ($hasfleet | not) then $prim else null end),
             from: $r.from, recs: $recs, writes: $writes, held: $held, kept: $kept,
             pinchanged: (($r.status == "steady") and any($recs[]; .pinned and .changed))}
        end ] }
'

# The new sync state from a plan and the profiles actually written ($m.plan,
# $m.written, $m.readable, $m.state, optionally $m.pins). A settled key
# records each readable profile's value as it now is; a pending key keeps its
# last-seen values, so the competing changes stay visible. A removed key is
# recorded {"absent": true, "removed": true}, so it is never re-added; one a
# profile never had, {"absent": true}. The undo record of each written
# profile is replaced by this write's before/after values.
readonly PREFS_COMMIT_JQ='
$m.plan as $p
| ($m.state // {}) as $st
| $m.written as $w
| $m.readable as $rd
| {schema: 1,
   keys: (reduce $p.keys[] as $k (($st.keys // {});
     if ($k.status | among(["untouched", "type", "unset"])) then .
     elif $k.status == "review" then .[$k.id] = (($k.entry // {}) + {pending: $k.pending})
     else
       [$k.writes[] | select(among($w))] as $done
       | .[$k.id] = {fleet: $k.fleet, decided: $k.decided, pending: null,
           seen: ((($k.entry.seen // {}) | with_entries(select((.key | among($rd)) | not)))
                  + ([$k.recs[] | {(.tag): (if (.tag | among($done)) then $k.fleet
                                            elif .absent then (if .removed then {absent: true, removed: true} else ABS end)
                                            else .cur end)}] | add // {}))}
     end)),
   pins: ($m.pins // $st.pins // {}),
   undo: (($st.undo // {}) + ([$w[] as $t
           | {($t): {at: $p.now, changes: ([$p.keys[] | . as $k | select($k.writes | any(.[]; . == $t))
               | {($k.id): {before: ($k.recs[] | select(.tag == $t) | .cur), after: $k.fleet}}] | add // {})}}]
         | add // {}))}
'

# The class report for prefs diff: C and S families that differ, per-profile
# counts of account-keyed (A) and local (L) entries, and U families by masked
# name. $m: classes, allow, tags (in file order), extra (tags that do not
# participate, read for --all), all.
readonly PREFS_REPORT_JQ='
[inputs] as $docs
| ($m.classes | .pref += ([$m.allow[] | select(.path | length == 2) | {(.path[1]): "G"}] | add)
               | .epx += ([$m.allow[] | select(.path | length == 3) | {(.path[2]): "G"}] | add)) as $X
| def acct_ids($k): [$k | scan(UUID)][0:1];
  def classify($lvl; $name; $v):
    ($X[$lvl][$name] // null) as $x
    | if $x == "A" then {class: "A", fam: $name,
          n: (if ($v | type) == "object" then ($v | length) else 1 end),
          ids: (if ($v | type) == "object" then [$v | keys[] | acct_ids(.)[]] else [] end)}
      elif $x != null then {class: $x, fam: $name, n: 1, ids: []}
      elif ($name | test("^" + UUID + "$")) then {class: "A", fam: "<account-id>", n: 1, ids: [$name]}
      elif ($name | test("\\." + UUID + "$")) then
        {class: "A", fam: ((($name | sub("\\." + UUID + "$"; "")) | mask) + ".<account-id>"), n: 1,
         ids: [$name | scan(UUID)][-1:]}
      elif ($v | type) == "object" and ($v | length) > 0
           and all($v | keys[]; test("^" + UUID + "(/" + UUID + ")?$")) then
        {class: "A", fam: ($name | mask), n: ($v | length), ids: [$v | keys[] | acct_ids(.)[]]}
      elif ($name | test(UUID)) or ($name | test("session_|local_|/|remote:"))
           or ($name | test("^projects\\.[^.]+\\.overviewPaneOpen$")) then
        {class: "L", fam: ($name | mask), n: 1, ids: []}
      else {class: "U", fam: ($name | mask), n: 1, ids: []} end;
  def families:
    . as $d
    | [ ($d | to_entries[] | select(.key != "preferences") | classify("top"; .key; .value) + {k: "top/\(.key)", v: .value}),
        (if ($d.preferences | type) == "object" then
           ($d.preferences | to_entries[] | select(.key != "epitaxyPrefs") | classify("pref"; .key; .value) + {k: "pref/\(.key)", v: .value}),
           (if ($d.preferences.epitaxyPrefs | type) == "object" then
              ($d.preferences.epitaxyPrefs | to_entries[] | classify("epx"; .key; .value) + {k: "epx/\(.key)", v: .value})
            else empty end)
         elif $d | has("preferences") then {class: "U", fam: "preferences", n: 1, ids: [], k: "top/preferences", v: null}
         else empty end) ];
  [range(0; $m.tags | length) as $i | {tag: $m.tags[$i], extra: ($m.tags[$i] | among($m.extra)), fams: ($docs[$i] | families)}] as $P
| ([$P[] | select(.extra | not)]) as $Pp
| (if $m.all then $P else $Pp end) as $Ps
| [ ($Pp | [.[].fams[] | select(.class == "C" or .class == "S") | {k, class, fam}] | unique_by(.k))[] as $f
    | [$Pp[] | . as $p | {tag: $p.tag, v: ([$p.fams[] | select(.k == $f.k) | .v] | if length == 0 then ABS else .[0] end)}] as $vals
    | select($m.all or (($vals | map(.v | tojson) | unique | length) > 1))
    | "  \($f.fam) (\($f.class)): " + ([$vals[] | "\(.tag)=\(.v | show)"] | join(", ")) ] as $cs
| [ $Ps[] | . as $p
    | ([$p.fams[] | select(.class == "A")]) as $a
    | "  \($p.tag)\(if $p.extra then " (not synced)" else "" end): \([$a[].n] | add // 0) account-keyed entries for \([$a[].ids[]] | unique | length) account(s), \([$p.fams[] | select(.class == "L")] | length) local entries" ] as $counts
| [ ($Ps | [.[] | . as $p | $p.fams[] | select(.class == "U") | {fam, tag: $p.tag}] | group_by(.fam))[]
    | "  \(.[0].fam) (in \(map(.tag) | unique | join(", ")))" ] as $us
| {cs: $cs, counts: $counts, us: $us}
'

# The synced-key lines of prefs diff, and whether everything is in sync, from
# a plan made for every participating profile with nothing running.
readonly PREFS_TABLE_JQ='
.keys | [ .[] as $k
  | ([$k.writes[], ($k.held[] | .tag)]) as $behind
  | ($k.entry != null and ($k.entry | has("fleet"))) as $hf
  | ($k.status == "unset" or $k.status == "init" or ($k.status == "steady" and ($behind | length) == 0)) as $ok
  | (if $k.status == "type" then "type differs in a profile: left alone"
     elif $k.status == "review" then "needs review"
       + (if $hf then "" elif $k.proposed != null then " (proposed: primary'"'"'s \($k.proposed | show))"
          else " (no default: primary has no value)" end)
     elif $k.status == "unset" then "not set in any profile"
     elif $k.status == "init" then "in sync (recorded at the next sync)"
     elif $k.status == "agreed" then "in sync again (needs review until the next sync)"
     elif $k.status == "latest" then "changed in \($k.from)"
     elif ($behind | length) > 0 then "behind in \($behind | join(", "))"
     elif $k.pinchanged then "in sync (a pinned profile differs)"
     else "in sync" end) as $st
  | {id: $k.id, ok: $ok,
     line: ("  \($k.id): \($st); fleet=\(if $hf then ($k.entry.fleet | show) else "none" end); "
       + ([$k.recs[] | . as $r | "\(.tag)=\(.cur | show)"
           + ([(if $r.changed then "changed" else empty end),
               (if ($r.tag | among($behind)) then "behind" else empty end),
               (if $r.pinned then "pinned" else empty end),
               (if $r.removed then "removed by the app" else empty end)]
              | if length > 0 then " (" + join(", ") + ")" else "" end)] | join(", ")))} ]
| {ok: all(.[]; .ok), lines: map(.line), byid: (map({(.id): .line}) | add // {})}
'

# Run state of a settings step (globals, because bash 3.2 has no other way to
# return several values).
PRS_STATE="ok"
PRS_RUNNING=""
PRS_WHY=""
PR_STATE_JSON='{}'
PR_READABLE=""
PR_BAD=""
PR_FILES=()
PR_PLAN=""
PR_TMP=""
PR_TMP2=""
PR_HOLD=""
PR_REVIEW=0
PR_SKIPPED=0

# _prefs_words <word> ...: a JSON array of the words, which are tags or key
# ids ([a-z0-9-] only), so no escaping is needed.
_prefs_words() {
  local w out=""
  for w in "$@"; do
    [[ -n "$w" ]] || continue
    out="${out:+${out},}\"${w}\""
  done
  printf '[%s]' "$out"
}

# _prefs_now: the current UTC time.
_prefs_now() { "$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ; }

# _prefs_scan: reads the process table once (_claude_main_rows) and resolves
# it (_claude_instances_from), the one matcher every running check uses.
# Sets PRS_STATE (ok | unreadable | flagless | unknown), PRS_RUNNING (the
# profiles running, space-separated, with spaces around) and PRS_WHY.
_prefs_scan() {
  local raw="" st=0 rows="" pid kind method n=0 unknown=0
  PRS_STATE="ok"
  PRS_RUNNING=" "
  PRS_WHY=""
  raw="$(_claude_main_rows)" || st=$?
  if [[ $st -ne 0 ]]; then
    PRS_STATE="unreadable"
    PRS_WHY="the process table could not be read, so the switcher cannot tell which profiles are running"
    return 0
  fi
  while IFS=$'\t' read -r pid kind method; do
    if [[ "$kind" == "FLAGLESS" ]]; then n=$((n + 1)); fi
  done <<< "$raw"
  rows="$(_claude_instances_from "$raw")" || rows=""
  while IFS=$'\t' read -r pid kind method; do
    [[ -n "$pid" ]] || continue
    if [[ "$kind" == "unknown" ]]; then
      unknown=1
    else
      PRS_RUNNING="${PRS_RUNNING}${kind} "
    fi
  done <<< "$rows"
  if [[ $n -gt 1 ]]; then
    PRS_STATE="flagless"
    PRS_WHY="${n} Claude instances are running without --user-data-dir, so one of them could be any profile (see 'account-switcher list')"
  elif [[ $unknown -eq 1 ]]; then
    PRS_STATE="unknown"
    PRS_WHY="a running Claude instance's profile is unknown, so it could be any profile (see 'account-switcher list')"
  fi
  return 0
}

# _prefs_running <tag>: 0 when the last scan saw <tag> running.
_prefs_running() {
  case "$PRS_RUNNING" in *" ${1} "*) return 0 ;; esac
  return 1
}

# _prefs_participants: primary (when its folder exists), then every
# [accounts] tag whose profile folder exists; default is primary.
_prefs_participants() {
  local t seen=" " tags=""
  if [[ -d "$(udd_for_tag primary)" ]]; then
    printf 'primary\n'
    seen=" primary "
  fi
  tags="$(accounts_tags)" || tags=""
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$t" == "default" ]]; then t="primary"; fi
    case "$seen" in *" ${t} "*) continue ;; esac
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || continue
    [[ -d "$(udd_for_tag "$t")" ]] || continue
    printf '%s\n' "$t"
    seen="${seen}${t} "
  done <<< "$tags"
  return 0
}

# _prefs_extra_tags <participants>: every other Claude-<tag> profile folder
# (read by `prefs diff --all` only, never written).
_prefs_extra_tags() {
  local d t
  for d in "${AS_PROFILE_ROOT}"/Claude-*; do
    [[ -d "$d" ]] || continue
    t="${d##*/Claude-}"
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$t" != "primary" && "$t" != "default" ]] || continue
    case " ${1//$'\n'/ } " in *" ${t} "*) continue ;; esac
    printf '%s\n' "$t"
  done
  return 0
}

# _prefs_state_load: sets PR_STATE_JSON from PREFS_STATE ({} when absent);
# returns 1 when the file exists but is not a sync state.
_prefs_state_load() {
  PR_STATE_JSON='{}'
  [[ -e "$PREFS_STATE" ]] || return 0
  PR_STATE_JSON="$("$AS_BIN_JQ" -c 'if type == "object" and .schema == 1 then . else error("shape") end' \
    "$PREFS_STATE" 2>/dev/null)" || { PR_STATE_JSON='{}'; return 1; }
  return 0
}

# The refusal for a sync state that cannot be read.
_prefs_state_bad() {
  printf "The sync state %s is not a sync state the switcher can read. Nothing was written. Move it aside (the next sync then treats every disagreement as needing review): trash %s" \
    "$(_tilde_path "$PREFS_STATE")" "$(_tilde_path "$PREFS_STATE")"
}

# _prefs_read <tag> ...: validates each profile's settings file (one JSON
# object, read twice at most, a second apart: the app rewrites the file
# while it runs). Sets PR_READABLE (tags, one per line), PR_FILES (their
# files, same order) and PR_BAD ("tag<TAB>no-file|invalid" lines), and warns
# for each invalid one. jq reads each file in place; nothing copies it.
_prefs_read() {
  local t f try ok
  PR_READABLE=""
  PR_BAD=""
  PR_FILES=()
  for t in "$@"; do
    f="$(udd_for_tag "$t")/${PREFS_FILE}"
    if [[ ! -f "$f" ]]; then
      PR_BAD="${PR_BAD}${t}"$'\t'"no-file"$'\n'
      continue
    fi
    ok=0
    try=1
    while [[ $try -le 2 ]]; do
      if "$AS_BIN_JQ" -e 'type == "object"' "$f" >/dev/null 2>&1; then ok=1; break; fi
      if [[ $try -eq 1 ]]; then "$AS_BIN_SLEEP" 1; fi
      try=$((try + 1))
    done
    if [[ $ok -eq 1 ]]; then
      PR_READABLE="${PR_READABLE}${t}"$'\n'
      PR_FILES+=("$f")
    else
      PR_BAD="${PR_BAD}${t}"$'\t'"invalid"$'\n'
      warn "'${t}': its settings file is not valid JSON (read twice, a second apart); skipped for this run."
    fi
  done
  return 0
}

# _prefs_plan <named tags> <running tags> [decisions-json] [only-decided]
# [pins-json]: runs PREFS_PLAN_JQ over the files _prefs_read accepted; sets
# PR_PLAN. Returns 1 when jq fails twice (a file changed under it).
_prefs_plan() {
  local named="$1" running="$2" dec="${3:-}" only="${4:-false}" pins="${5:-}" meta try=1
  local readable
  # The lists hold tags only, so word splitting is the point.
  # shellcheck disable=SC2086
  readable="$(_prefs_words $PR_READABLE)"
  [[ -n "$dec" ]] || dec='{}'
  meta="$("$AS_BIN_JQ" -cn --argjson allow "$PREFS_ALLOW" --argjson state "$PR_STATE_JSON" \
    --argjson readable "$readable" --argjson named "$named" --argjson running "$running" \
    --argjson dec "$dec" --arg now "$(_prefs_now)" --arg only "$only" --arg pins "$pins" \
    '{allow: $allow, state: $state, readable: $readable, named: $named, running: $running,
      now: $now, decisions: $dec, only_decided: ($only == "true")}
     + (if $pins == "" then {} else {pins: ($pins | fromjson)} end)')" || return 1
  while [[ $try -le 2 ]]; do
    if PR_PLAN="$("$AS_BIN_JQ" -c -n --argjson m "$meta" "${PREFS_DEFS} ${PREFS_PLAN_JQ}" \
        ${PR_FILES[@]+"${PR_FILES[@]}"} < /dev/null 2>/dev/null)"; then
      return 0
    fi
    if [[ $try -eq 1 ]]; then "$AS_BIN_SLEEP" 1; fi
    try=$((try + 1))
  done
  PR_PLAN=""
  return 1
}

# _prefs_ops <tag>: the [path, value] pairs PR_PLAN writes into <tag>.
_prefs_ops() {
  printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -c --arg t "$1" '[.keys[] | select(.writes | any(.[]; . == $t)) | [.path, .fleet]]'
}

# Removes this run's temporary files in a profile folder or the store.
_prefs_rm_tmp() {
  local f
  for f in "$PR_TMP" "$PR_TMP2"; do
    if [[ -n "$f" && -e "$f" ]]; then "$AS_BIN_RM" -f "$f" 2>/dev/null || :; fi
  done
  PR_TMP=""
  PR_TMP2=""
  return 0
}

# _prefs_sweep_tmp <tag> ...: removes temporary files an interrupted run
# left in these profile folders (only this switcher's own prefix).
_prefs_sweep_tmp() {
  local t f
  for t in "$@"; do
    for f in "$(udd_for_tag "$t")/${PREFS_TMP_PREFIX}"*; do
      if [[ -f "$f" ]]; then "$AS_BIN_RM" -f "$f" 2>/dev/null || :; fi
    done
  done
  return 0
}

# _prefs_test_ops <ops-json>: prints the ops, with AS_TEST_PREFS_EXTRA_OP
# appended in test mode only. Every op the plan emits is allowlisted, so this
# test-only op is the one way a case can reach the "differs outside the
# allowlisted keys" check below (F-06). Outside test mode the name is fixed
# empty, so the ops pass unchanged.
_prefs_test_ops() {
  if [[ "${AS_TEST_MODE:-0}" == "1" && -n "$AS_TEST_PREFS_EXTRA_OP" ]]; then
    printf '%s' "$1" | "$AS_BIN_JQ" -c --argjson x "$AS_TEST_PREFS_EXTRA_OP" '. + [$x]'
    return
  fi
  printf '%s' "$1"
}

# _prefs_write <tag> <ops-json> <swap|strict> <replace|keep> [file-to-restore]
# The write sequence for one profile (#11, step 4):
#   1. build the new file in a mktemp file inside the profile folder, mode
#      600 (from the current file with the ops applied, or a copy of the
#      prior copy for `undo --whole-file`);
#   2. confirm it equals the current file once the allowlisted paths are
#      removed from both (skipped for --whole-file, which replaces the file);
#   3. re-check that the profile is not running (strict: also that no
#      running instance could be any profile);
#   4. copy the current file to claude_desktop_config.json.sync-prev, mode
#      600 (replace; `undo` keeps the prior copy);
#   5. rename the new file into place.
# Returns 0 written, 1 held back by the re-check (PR_HOLD says why), 2 failed.
_prefs_write() {
  local tag="$1" ops="$2" mode="$3" prev="$4" restore="${5:-}" udd f same=""
  PR_HOLD=""
  udd="$(udd_for_tag "$tag")"
  f="${udd}/${PREFS_FILE}"
  PR_TMP="$("$AS_BIN_MKTEMP" "${udd}/${PREFS_TMP_PREFIX}XXXXXX")" || { PR_TMP=""; return 2; }
  "$AS_BIN_CHMOD" 600 "$PR_TMP" || { _prefs_rm_tmp; return 2; }
  if [[ -n "$restore" ]]; then
    "$AS_BIN_CAT" "$restore" > "$PR_TMP" 2>/dev/null || { _prefs_rm_tmp; return 2; }
  else
    ops="$(_prefs_test_ops "$ops")" || { _prefs_rm_tmp; return 2; }
    # An op whose value is the absent marker removes the key (prefs undo of a
    # key the last sync added); allowlisted values are scalars, so the marker
    # can't be a value.
    if ! "$AS_BIN_JQ" --argjson ops "$ops" 'reduce $ops[] as $o (.;
        if ($o[1] | type) == "object" and $o[1].absent == true then delpaths([$o[0]]) else setpath($o[0]; $o[1]) end)' \
        "$f" > "$PR_TMP" 2>/dev/null; then
      _prefs_rm_tmp
      return 2
    fi
    same="$("$AS_BIN_JQ" -n --argjson allow "$PREFS_ALLOW" \
      '[$allow[].path] as $p | (input | delpaths($p)) == (input | delpaths($p))' "$f" "$PR_TMP" 2>/dev/null)" || same=""
    if [[ "$same" != "true" ]]; then
      warn "'${tag}': the new settings file would differ outside the allowlisted keys; not written."
      _prefs_rm_tmp
      return 2
    fi
  fi
  _prefs_scan
  if [[ "$PRS_STATE" == "unreadable" ]] || [[ "$mode" == "strict" && "$PRS_STATE" != "ok" ]]; then
    PR_HOLD="$PRS_WHY"
    _prefs_rm_tmp
    return 1
  fi
  if _prefs_running "$tag"; then
    PR_HOLD="running"
    _prefs_rm_tmp
    return 1
  fi
  if [[ "$prev" == "replace" ]]; then
    PR_TMP2="$("$AS_BIN_MKTEMP" "${udd}/${PREFS_TMP_PREFIX}XXXXXX")" || { PR_TMP2=""; _prefs_rm_tmp; return 2; }
    if ! "$AS_BIN_CP" "$f" "$PR_TMP2" || ! "$AS_BIN_CHMOD" 600 "$PR_TMP2" \
        || ! "$AS_BIN_MV" -f "$PR_TMP2" "${f}.sync-prev"; then
      _prefs_rm_tmp
      return 2
    fi
    PR_TMP2=""
  fi
  "$AS_BIN_MV" -f "$PR_TMP" "$f" || { _prefs_rm_tmp; return 2; }
  PR_TMP=""
  return 0
}

# _prefs_state_write <json>: writes the sync state through a temporary file
# in the store, mode 600, then a rename.
_prefs_state_write() {
  _store_ensure || return 1
  PR_TMP="$("$AS_BIN_MKTEMP" "${STORE}/.prefs-sync.json.XXXXXX")" || { PR_TMP=""; return 1; }
  "$AS_BIN_CHMOD" 600 "$PR_TMP" || { _prefs_rm_tmp; return 1; }
  printf '%s\n' "$1" | "$AS_BIN_JQ" . > "$PR_TMP" || { _prefs_rm_tmp; return 1; }
  "$AS_BIN_MV" -f "$PR_TMP" "$PREFS_STATE" || { _prefs_rm_tmp; return 1; }
  PR_TMP=""
  return 0
}

# _prefs_commit <written tags> [pins-json]: the new state (PREFS_COMMIT_JQ)
# from PR_PLAN, written when it differs from the one loaded.
_prefs_commit() {
  local written new
  # shellcheck disable=SC2086
  written="$(_prefs_words $1)"
  # shellcheck disable=SC2086
  new="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -c --argjson state "$PR_STATE_JSON" --argjson w "$written" \
    --argjson rd "$(_prefs_words $PR_READABLE)" --arg pins "${2:-}" \
    "${PREFS_DEFS} . as \$plan | {plan: \$plan, state: \$state, written: \$w, readable: \$rd}
      + (if \$pins == \"\" then {} else {pins: (\$pins | fromjson)} end) | . as \$m | ${PREFS_COMMIT_JQ}")" || return 1
  if [[ "$new" == "$PR_STATE_JSON" ]]; then return 0; fi
  _prefs_state_write "$new" || return 1
  PR_STATE_JSON="$new"
  return 0
}

# _prefs_lock <doing>: takes the settings-sync lock, or prints the refusal
# (the same rule and message shape as the update lock) and returns 1.
_prefs_lock() {
  _store_ensure || :
  if _lock_held "$PREFS_LOCK"; then
    printf '\033[31mERROR:\033[0m %s\n' "$(_lock_refusal "$PREFS_LOCK" "$1")" >&2
    return 1
  fi
  if ! _lock_take "$PREFS_LOCK"; then
    printf '\033[31mERROR:\033[0m %s\n' "Another settings sync took the lock $(_tilde_path "$PREFS_LOCK") just now. Not ${1}." >&2
    return 1
  fi
  return 0
}

# _prefs_tally <cmd> <target> <written tags> <not-written tags> <named tags>:
# prints the summary line and, except for a dry run, appends the PREFS_SYNC
# row (key ids and counts, never values). <target> is a tag or "all". Sets
# PR_REVIEW and PR_SKIPPED.
#   applied  key writes made          kept     keys a pin kept different
#   skipped  key writes held back (running, a type that differs, no object
#            to hold the key) plus named profiles whose file can't be read
#   review   keys that need review
_prefs_tally() {
  local cmd="$1" target="$2" label t line ids applied kept review skipped unreadable=0 bad_t why
  label="$target"
  if [[ "$target" == "all" ]]; then label="every profile"; fi
  # shellcheck disable=SC2086
  line="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r --argjson w "$(_prefs_words $3)" --argjson nw "$(_prefs_words $4)" \
    "${PREFS_DEFS}"'
    [.keys[] | . as $k | $k.writes[] | select(among($w)) | $k.id] as $done
    | [.keys[] | select(.id | among($done))] as $ids
    | [.keys[] | select((.kept | length) > 0 or .pinchanged)] as $kept
    | [.keys[] | select(.status == "review")] as $rev
    | (([.keys[] | select(.status == "type")] | length)
       + ([.keys[].held[]] | length)
       + ([.keys[] | .writes[] | select(among($nw))] | length)) as $skip
    | [$ids[] | select(.from != null and (.status == "latest" or .status == "decided")) | "\(.id):\(.from | gsub(","; "+"))"] as $src
    | [$ids[] | if .from != null and (.status == "latest" or .status == "decided")
                then "\(.id) from \(.from | gsub(","; " and "))" else .id end] as $shown
    | "\($done | length)|\($ids | map(.id) | join(","))|\($kept | length)|\($rev | length)|\($skip)|\($src | join(","))|\($shown | join(", "))"')" || line=""
  local src shown
  IFS='|' read -r applied ids kept review skipped src shown <<< "$line"
  [[ -n "$applied" ]] || { applied=0; ids=""; kept=0; review=0; skipped=0; src=""; shown=""; }
  local nm=" ${5:-} "
  nm="${nm//$'\n'/ }"
  while IFS=$'\t' read -r bad_t why; do
    [[ -n "$bad_t" ]] || continue
    case "$nm" in *" ${bad_t} "*) unreadable=$((unreadable + 1)) ;; esac
  done <<< "$PR_BAD"
  skipped=$((skipped + unreadable))
  PR_REVIEW="$review"
  PR_SKIPPED="$skipped"
  local hint=""
  if [[ "$review" -gt 0 ]]; then hint=": run 'account-switcher prefs review'"; fi
  printf '%s: %s %s to %s%s, %s kept (pinned), %s skipped, %s needs review%s\n' \
    "$([[ "$cmd" == "dry-run" ]] && printf 'settings (dry run)' || printf 'settings')" \
    "$applied" "$([[ "$cmd" == "dry-run" ]] && printf 'would apply' || printf 'applied')" \
    "$label" "${shown:+ (${shown})}" "$kept" "$skipped" "$review" "$hint" >&2
  if [[ "$cmd" != "dry-run" ]]; then
    _swap_log_ensure
    printf '[%s] PREFS_SYNC cmd=%s target=%s applied=%s keys=%s kept=%s review=%s skipped=%s from=%s\n' \
      "$(_prefs_now)" "$cmd" "$target" "$applied" "${ids:-none}" "$kept" "$review" "$skipped" "${src:-none}" >> "$SWAP_LOG"
  fi
  return 0
}

# _prefs_prepare <swap|strict> [read-only]: loads the sync state, scans the
# process table and reads every participating profile (sets PR_PARTS).
# Returns 2, having said why, when the state can't be read or the running
# check stops the run (strict: any reason; swap: an unreadable table only).
# A writing run first removes temporary files an interrupted run left; a
# read-only one leaves them.
_prefs_prepare() {
  local mode="$1" ro="${2:-}"
  if ! _prefs_state_load; then
    printf '\033[31mERROR:\033[0m %s\n' "$(_prefs_state_bad)" >&2
    return 2
  fi
  PR_PARTS="$(_prefs_participants)"
  _prefs_scan
  if [[ "$PRS_STATE" == "unreadable" ]] || [[ "$mode" == "strict" && "$PRS_STATE" != "ok" ]]; then
    if [[ "$mode" == "swap" ]]; then
      warn "Skipping the settings step: ${PRS_WHY}. The swap continues."
    else
      printf "\033[31mERROR:\033[0m Not writing any profile's settings: %s.\n" "$PRS_WHY" >&2
    fi
    return 2
  fi
  if [[ "$ro" != "read-only" ]]; then
    # shellcheck disable=SC2086
    _prefs_sweep_tmp $PR_PARTS
  fi
  # shellcheck disable=SC2086
  _prefs_read $PR_PARTS
  return 0
}

# _prefs_apply <swap|strict> <replace|keep> <tag> ...: writes PR_PLAN's ops
# into each named profile, in order (sets PR_WRITTEN and PR_NOTWRITTEN). A
# strict re-check that fails stops every later write.
_prefs_apply() {
  local mode="$1" prev="$2" t ops wrc
  shift 2
  PR_WRITTEN=""
  PR_NOTWRITTEN=""
  for t in "$@"; do
    case "$PR_BAD" in
      "${t}"$'\t'"no-file"*|*$'\n'"${t}"$'\t'"no-file"*)
        info "Skipped '${t}': it has no settings file yet (the app creates it)."
        continue ;;
      "${t}"$'\t'*|*$'\n'"${t}"$'\t'*) continue ;;
    esac
    ops="$(_prefs_ops "$t")" || ops="[]"
    [[ "$ops" != "[]" ]] || continue
    wrc=0
    _prefs_write "$t" "$ops" "$mode" "$prev" || wrc=$?
    if [[ $wrc -eq 0 ]]; then
      PR_WRITTEN="${PR_WRITTEN} ${t}"
    else
      PR_NOTWRITTEN="${PR_NOTWRITTEN} ${t}"
      if [[ "$PR_HOLD" == "running" ]]; then
        info "Skipped '${t}': it is running; its settings are written at its next sync."
      elif [[ -n "$PR_HOLD" ]]; then
        warn "Skipped '${t}' and every profile after it: ${PR_HOLD}."
        break
      else
        warn "Skipped '${t}': its settings file could not be written."
      fi
    fi
  done
  _prefs_held_notes
  return 0
}

# _prefs_detail <tag> ...: one line per profile PR_PLAN writes, naming the
# keys and the allowlisted values (booleans and short strings).
_prefs_detail() {
  # shellcheck disable=SC2086
  printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r --argjson t "$(_prefs_words "$@")" "${PREFS_DEFS}"'
    . as $p | $t[] as $tag
    | [$p.keys[] | select(.writes | any(.[]; . == $tag)) | "\(.id)=\(.fleet | show)"] as $w
    | select($w | length > 0) | "  \($tag): \($w | join(", "))"' >&2 || :
}

# prefs_step <cmd> <swap|strict> <target> <tag> ...: one key-level settings
# sync that may write only the named tags (#11's write sequence): lock, read
# and validate every participating file, plan, write each named profile,
# write the sync state, append the PREFS_SYNC row, release the lock. <target>
# is the tag, or "all". Prints the summary line. Never exits, so swap goes on
# to launch whatever it returns:
#   0  done; nothing needs review and nothing was skipped
#   1  done; a key needs review, or a write was skipped
#   2  refused or failed before any profile was written
prefs_step() {
  local cmd="$1" mode="$2" target="$3" rc=0
  shift 3
  if ! _prefs_lock "writing any profile's settings"; then
    if [[ "$mode" == "swap" ]]; then warn "Skipping the settings step; the swap continues."; fi
    return 2
  fi
  _prefs_step_body "$cmd" "$mode" "$target" "$@" || rc=$?
  _prefs_rm_tmp
  _lock_release
  return "$rc"
}

_prefs_step_body() {
  local cmd="$1" mode="$2" target="$3"
  shift 3
  _prefs_prepare "$mode" || return 2
  local t
  for t in "$@"; do
    case " ${PR_PARTS//$'\n'/ } " in
      *" ${t} "*) ;;
      *) info "'${t}' does not take part in the settings sync (not in [accounts]); its settings are left as they are." ;;
    esac
  done
  # shellcheck disable=SC2086
  if ! _prefs_plan "$(_prefs_words "$@")" "$(_prefs_words $PRS_RUNNING)"; then
    warn "The settings files changed while they were being read; nothing was written. Run it again."
    return 2
  fi
  _prefs_apply "$mode" replace "$@"
  if [[ "$cmd" == "sync" ]]; then
    # shellcheck disable=SC2086
    _prefs_detail $PR_WRITTEN
  fi
  if ! _prefs_commit "$PR_WRITTEN"; then
    warn "The sync state $(_tilde_path "$PREFS_STATE") could not be written; the profiles written keep their new values."
  fi
  _prefs_tally "$cmd" "$target" "$PR_WRITTEN" "$PR_NOTWRITTEN" "$*"
  if [[ "$PR_REVIEW" -gt 0 || "$PR_SKIPPED" -gt 0 ]]; then return 1; fi
  return 0
}


# Says which named profiles the plan held back, and why.
_prefs_held_notes() {
  local t why
  while IFS=$'\t' read -r t why; do
    [[ -n "$t" ]] || continue
    case "$why" in
      running) info "Skipped '${t}': it is running; its settings are written at its next sync." ;;
      *) info "Skipped '${t}' for a key: its settings file has no object to hold it yet (the app adds it)." ;;
    esac
  done < <(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r '[.keys[].held[] | "\(.tag)\t\(.why)"] | unique[]' 2>/dev/null)
  return 0
}

# ---- prefs (#11) ------------------------------------------------------------
#
# Exit codes (also in help and the README):
#   diff         0 in sync and nothing pending, 1 otherwise, 2 error
#   sync         0 done, nothing pending or skipped; 1 done, but a key needs
#                review or a write was skipped; 2 refused, nothing written
#   sync --dry-run  0 nothing to write and nothing pending; 1 something to
#                write or pending; 2 refused
#   review       0 applied, nothing left pending; 1 something left pending,
#                or the plan was declined; 2 refused
#   adopt        0 set and written everywhere it applies; 1 set, but a
#                profile was skipped; 2 refused
#   pin, unpin   0 done; 2 refused
#   undo         0 restored; 1 nothing to restore; 2 refused

_prefs_usage() {
  "$AS_BIN_CAT" <<EOF >&2
Usage: account-switcher prefs <verb> [...]
  diff [--all]                  every difference between the profiles' settings (read-only)
  sync [<tag>] [--dry-run]      sync the allowlisted keys into <tag>, or every profile not running
  review                        walk the keys that differ and decide (needs a terminal)
  adopt <key-id> --from <tag>   make <tag>'s value the value for every profile
  pin <tag> <key-id>|--all      keep a key (or the whole profile) different in <tag> on purpose
  unpin <tag> <key-id>|--all    reverse a pin
  undo <tag> [--whole-file]     reverse the last sync to <tag>
Key ids: $(_prefs_key_ids)
EOF
}

# Prints the allowlist's key ids, comma-separated.
_prefs_key_ids() {
  printf '%s' "$PREFS_ALLOW" | "$AS_BIN_JQ" -r '[.[].id] | join(", ")'
}

# A refusal: one error line, exit 2.
_prefs_refuse() {
  printf '\033[31mERROR:\033[0m %s\n' "$*" >&2
  exit 2
}

# The EXIT trap of the writing verbs: removes this run's temporary files and
# releases the lock this run took.
_prefs_on_exit() {
  local rc=$?
  set +e
  _prefs_rm_tmp
  _lock_release
  exit "$rc"
}

# _prefs_key <key-id>: prints the allowlist entry, or refuses.
_prefs_key() {
  local k=""
  [[ "${1:-}" =~ ^[a-z0-9-]{1,40}$ ]] || _prefs_refuse "Unknown key id '${1:-}'. Key ids: $(_prefs_key_ids)."
  k="$(printf '%s' "$PREFS_ALLOW" | "$AS_BIN_JQ" -c --arg id "$1" '.[] | select(.id == $id)')" || k=""
  [[ -n "$k" ]] || _prefs_refuse "Unknown key id '${1}'. Key ids: $(_prefs_key_ids)."
  printf '%s' "$k"
}

# _prefs_tag <tag>: prints the participating tag (default is primary), or
# refuses.
_prefs_tag() {
  local t="${1:-}" parts
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || _prefs_refuse "Tag must match [a-z0-9-]{1,32} (got: '${t}')."
  if [[ "$t" == "default" ]]; then t="primary"; fi
  parts="$(_prefs_participants)"
  case " ${parts//$'\n'/ } " in
    *" ${t} "*) printf '%s' "$t" ;;
    *) _prefs_refuse "'${t}' is not a participating profile (primary, plus every [accounts] tag whose profile folder exists): ${parts//$'\n'/, }." ;;
  esac
}

# _prefs_app_check: the writing verbs refuse when the app isn't where
# detection looks (#9): "running profiles are never written" rests on it.
_prefs_app_check() {
  app_binary_present || _prefs_refuse "$(app_binary_refusal "written")"
}

# Starts a writing verb: refuses when the app isn't where detection looks,
# rotates the history log, sets the EXIT trap and takes the lock.
_prefs_begin() {
  _prefs_app_check
  rotate_swap_log_if_needed
  trap _prefs_on_exit EXIT
  _prefs_lock "$1" || exit 2
}

# ---- prefs diff ---------------------------------------------------------------

_prefs_diff() {
  local all=false a table cs ok=0 t why extra="" p_readable p_bad
  local -a p_files
  for a in "$@"; do
    case "$a" in
      --all) all=true ;;
      *) _prefs_usage; _prefs_refuse "prefs diff takes only --all (got: '${a}')." ;;
    esac
  done
  app_binary_warn
  _prefs_state_load || _prefs_refuse "$(_prefs_state_bad)"
  PR_PARTS="$(_prefs_participants)"
  [[ -n "$PR_PARTS" ]] || _prefs_refuse "No participating profile folder exists (primary, plus every [accounts] tag whose profile folder exists)."
  # shellcheck disable=SC2086
  _prefs_read $PR_PARTS
  # shellcheck disable=SC2086
  _prefs_plan "$(_prefs_words $PR_PARTS)" "[]" || _prefs_refuse "The settings files changed while they were being read. Run it again."
  table="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -c "${PREFS_DEFS} ${PREFS_TABLE_JQ}")" || _prefs_refuse "Could not build the report."
  p_readable="$PR_READABLE"
  p_bad="$PR_BAD"
  p_files=(${PR_FILES[@]+"${PR_FILES[@]}"})
  if [[ "$all" == "true" ]]; then
    # Tags only, so word splitting is the point.
    # shellcheck disable=SC2046
    _prefs_read $(_prefs_extra_tags "$PR_PARTS")
    extra="$PR_READABLE"
    p_files+=(${PR_FILES[@]+"${PR_FILES[@]}"})
  fi
  # shellcheck disable=SC2086
  cs="$("$AS_BIN_JQ" -c -n --argjson m "$("$AS_BIN_JQ" -cn --argjson classes "$PREFS_CLASSES" \
      --argjson allow "$PREFS_ALLOW" --argjson tags "$(_prefs_words $p_readable $extra)" \
      --argjson extra "$(_prefs_words $extra)" --arg all "$all" \
      '{classes: $classes, allow: $allow, tags: $tags, extra: $extra, all: ($all == "true")}')" \
      "${PREFS_DEFS} ${PREFS_REPORT_JQ}" ${p_files[@]+"${p_files[@]}"} < /dev/null 2>/dev/null)" \
    || _prefs_refuse "Could not build the report (a settings file changed while it was read). Run it again."
  printf 'Settings in %s across %s\n' "$PREFS_FILE" "$(printf '%s' "${PR_PARTS//$'\n'/, }")"
  while IFS=$'\t' read -r t why; do
    [[ -n "$t" ]] || continue
    ok=1
    case "$why" in
      no-file) printf '  %s: no settings file yet; not compared\n' "$t" ;;
      *) printf '  %s: not valid JSON (read twice, a second apart); not compared\n' "$t" ;;
    esac
  done <<< "$p_bad"
  printf '\nSynced settings (the allowlist): status; fleet value; each profile\n'
  printf '%s' "$table" | "$AS_BIN_JQ" -r '.lines[]'
  printf '\nCapability (C) and security (S) settings that differ (never synced; change them in the app)\n'
  printf '%s' "$cs" | "$AS_BIN_JQ" -r 'if (.cs | length) == 0 then "  none" else .cs[] end'
  printf '\nAccount-keyed (A) and profile-local (L) entries (never synced)\n'
  printf '%s' "$cs" | "$AS_BIN_JQ" -r '.counts[]'
  printf '\nUnclassified (U) settings, by masked name (never synced unless added to the allowlist)\n'
  printf '%s' "$cs" | "$AS_BIN_JQ" -r 'if (.us | length) == 0 then "  none" else .us[] end'
  if [[ "$(printf '%s' "$table" | "$AS_BIN_JQ" -r '.ok')" != "true" ]]; then ok=1; fi
  if [[ $ok -eq 0 ]]; then
    printf '\nResult: in sync; nothing pending.\n'
    exit 0
  fi
  printf "\nResult: not in sync, or something is pending. Decide with 'account-switcher prefs review' (terminal), or run 'account-switcher prefs sync'.\n"
  exit 1
}

# ---- prefs sync ---------------------------------------------------------------

_prefs_sync_cmd() {
  local tag="" dry=false a rc=0 target="all" named
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=true ;;
      -*) _prefs_usage; _prefs_refuse "Unknown flag for prefs sync: ${a}" ;;
      *)
        [[ -z "$tag" ]] || { _prefs_usage; _prefs_refuse "prefs sync takes one tag at most."; }
        tag="$a" ;;
    esac
  done
  if [[ -n "$tag" ]]; then
    tag="$(_prefs_tag "$tag")"
    target="$tag"
  fi
  if [[ "$dry" == "true" ]]; then
    # Read-only: no lock, no log rotation, no state write, no log row.
    app_binary_warn
    _prefs_prepare strict read-only || exit 2
    named="$tag"
    [[ -n "$named" ]] || named="$PR_PARTS"
    # shellcheck disable=SC2086
    _prefs_plan "$(_prefs_words $named)" "$(_prefs_words $PRS_RUNNING)" || _prefs_refuse "The settings files changed while they were being read. Run it again."
    # shellcheck disable=SC2086
    _prefs_detail $named
    _prefs_held_notes
    # shellcheck disable=SC2086
    _prefs_tally dry-run "$target" "$named" "" "$named"
    if [[ "$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r '[.keys[].writes[]] | length')" != "0" \
          || "$PR_REVIEW" -gt 0 || "$PR_SKIPPED" -gt 0 ]]; then
      exit 1
    fi
    exit 0
  fi
  _prefs_app_check
  rotate_swap_log_if_needed
  trap _prefs_on_exit EXIT
  if [[ -n "$tag" ]]; then
    prefs_step sync strict "$target" "$tag" || rc=$?
  else
    # shellcheck disable=SC2046
    prefs_step sync strict all $(_prefs_participants) || rc=$?
  fi
  exit "$rc"
}

# ---- prefs adopt ----------------------------------------------------------------

_prefs_adopt() {
  local id="${1:-}" k tag v dec rc=0
  [[ $# -eq 3 && "${2:-}" == "--from" ]] || { _prefs_usage; _prefs_refuse "Usage: account-switcher prefs adopt <key-id> --from <tag>"; }
  k="$(_prefs_key "$id")"
  tag="$(_prefs_tag "$3")"
  _prefs_begin "adopting a value"
  _prefs_prepare strict || exit 2
  case "$PR_BAD" in
    "${tag}"$'\t'*|*$'\n'"${tag}"$'\t'*) _prefs_refuse "'${tag}' has no settings file that can be read; nothing was adopted." ;;
  esac
  v="$("$AS_BIN_JQ" -c --argjson k "$k" "${PREFS_DEFS}"'
    val($k.path) | if isabs or (type != $k.type) then error("no") else . end' "$(udd_for_tag "$tag")/${PREFS_FILE}" 2>/dev/null)" \
    || _prefs_refuse "'${tag}' holds no ${id} value of the allowlisted type to adopt; nothing was changed."
  dec="$("$AS_BIN_JQ" -cn --arg id "$id" --argjson v "$v" --arg t "$tag" '{($id): {value: $v, by: "adopt", from: $t}}')"
  # shellcheck disable=SC2086
  _prefs_plan "$(_prefs_words $PR_PARTS)" "$(_prefs_words $PRS_RUNNING)" "$dec" true \
    || _prefs_refuse "The settings files changed while they were being read; nothing was written. Run it again."
  # shellcheck disable=SC2086
  _prefs_apply strict replace $PR_PARTS
  # shellcheck disable=SC2086
  _prefs_detail $PR_WRITTEN
  _prefs_commit "$PR_WRITTEN" || warn "The sync state $(_tilde_path "$PREFS_STATE") could not be written."
  _prefs_tally adopt all "$PR_WRITTEN" "$PR_NOTWRITTEN" "$PR_PARTS"
  info "${id} is now $(printf '%s' "$v" | "$AS_BIN_JQ" -r "${PREFS_DEFS} show") for every profile (from '${tag}')."
  if [[ "$PR_SKIPPED" -gt 0 ]]; then rc=1; fi
  exit "$rc"
}

# ---- prefs pin / unpin ------------------------------------------------------------

_prefs_pin() {
  local verb="$1" tag what id="" pins n
  shift
  [[ $# -eq 2 ]] || { _prefs_usage; _prefs_refuse "Usage: account-switcher prefs ${verb} <tag> <key-id>|--all"; }
  tag="$(_prefs_tag "$1")"
  what="$2"
  if [[ "$what" == "--all" ]]; then id="*"; else _prefs_key "$what" > /dev/null; id="$what"; fi
  _prefs_begin "changing pins"
  _prefs_state_load || _prefs_refuse "$(_prefs_state_bad)"
  pins="$(printf '%s' "$PR_STATE_JSON" | "$AS_BIN_JQ" -c --arg t "$tag" --arg id "$id" --arg verb "$verb" '
    (.pins // {})
    | if $verb == "pin" then .[$t] = ((.[$t] // []) + [$id] | unique)
      elif $id == "*" then del(.[$t])
      else .[$t] = ((.[$t] // []) - [$id]) end
    | with_entries(select((.value | length) > 0))')"
  n="$(printf '%s' "$pins" | "$AS_BIN_JQ" -r --arg t "$tag" '(.[$t] // []) | length')"
  _prefs_state_write "$(printf '%s' "$PR_STATE_JSON" | "$AS_BIN_JQ" -c --argjson pins "$pins" \
    '{schema: 1, keys: (.keys // {}), pins: $pins, undo: (.undo // {})}')" \
    || _prefs_refuse "The sync state $(_tilde_path "$PREFS_STATE") could not be written; the pins are unchanged."
  _swap_log_ensure
  printf '[%s] PREFS_PIN cmd=%s target=%s keys=%s pins=%s\n' "$(_prefs_now)" "$verb" "$tag" \
    "$([[ "$id" == "*" ]] && printf 'all' || printf '%s' "$id")" "$n" >> "$SWAP_LOG"
  if [[ "$verb" == "pin" && "$id" == "*" ]]; then
    ok "Pinned all of '${tag}': no command writes any synced key there, and its changes don't spread. Reverse with: account-switcher prefs unpin ${tag} --all"
  elif [[ "$verb" == "pin" ]]; then
    ok "Pinned ${id} in '${tag}': no command writes it there, and a change there doesn't spread. Reverse with: account-switcher prefs unpin ${tag} ${id}"
  elif [[ "$id" == "*" ]]; then
    ok "Removed every pin of '${tag}'."
  else
    ok "Unpinned ${id} in '${tag}'.$(printf '%s' "$pins" | "$AS_BIN_JQ" -r --arg t "$tag" 'if ((.[$t] // []) | index("*")) != null then " It is still pinned as a whole (--all)." else "" end')"
  fi
  exit 0
}

# ---- prefs undo ----------------------------------------------------------------

# _prefs_whole_file_cs <current file> <prior copy>: lists the capability (C)
# and security (S) families whose value differs between the two, through
# prefs diff's report (PREFS_REPORT_JQ, masked values), and says they will
# revert. Always returns 0.
_prefs_whole_file_cs() {
  local meta cs
  meta="$("$AS_BIN_JQ" -cn --argjson classes "$PREFS_CLASSES" --argjson allow "$PREFS_ALLOW" \
    '{classes: $classes, allow: $allow, tags: ["current", "prior-copy"], extra: [], all: false}')" || meta=""
  if [[ -n "$meta" ]] && cs="$("$AS_BIN_JQ" -r -n --argjson m "$meta" "${PREFS_DEFS} ${PREFS_REPORT_JQ} | .cs[]" \
      "$1" "$2" < /dev/null 2>/dev/null)"; then
    if [[ -n "$cs" ]]; then
      printf "Capability (C) and security (S) settings that differ from the prior copy; they will revert to the prior copy's values:\n%s\n" "$cs"
    else
      printf 'No capability (C) or security (S) setting differs from the prior copy.\n'
    fi
  else
    printf "The current settings file can't be read, so the switcher can't list which capability (C) or security (S) settings will change; every setting reverts to the prior copy's value.\n"
  fi
  return 0
}

_prefs_undo() {
  local tag="" whole=false a rec f prev res ops ids rem="" n wrc none='{}'
  for a in "$@"; do
    case "$a" in
      --whole-file) whole=true ;;
      -*) _prefs_usage; _prefs_refuse "Unknown flag for prefs undo: ${a}" ;;
      *) [[ -z "$tag" ]] || { _prefs_usage; _prefs_refuse "prefs undo takes one tag."; }; tag="$a" ;;
    esac
  done
  [[ -n "$tag" ]] || { _prefs_usage; _prefs_refuse "Usage: account-switcher prefs undo <tag> [--whole-file]"; }
  tag="$(_prefs_tag "$tag")"
  f="$(udd_for_tag "$tag")/${PREFS_FILE}"
  _prefs_begin "undoing a sync"
  _prefs_prepare strict || exit 2
  if _prefs_running "$tag"; then _prefs_refuse "'${tag}' is running; quit it, then run prefs undo again. Nothing was changed."; fi
  rec="$(printf '%s' "$PR_STATE_JSON" | "$AS_BIN_JQ" -c --arg t "$tag" '.undo[$t] // empty')" || rec=""
  if [[ "$whole" == "true" ]]; then
    prev="${f}.sync-prev"
    [[ -f "$prev" ]] || _prefs_refuse "'${tag}' has no prior copy to restore (one is made before each sync writes the profile). Nothing was changed."
    "$AS_BIN_JQ" -e 'type == "object"' "$prev" > /dev/null 2>&1 || _prefs_refuse "The prior copy in '${tag}' is not valid JSON; nothing was changed."
    _signin_tty || _prefs_refuse "prefs undo --whole-file needs a terminal to confirm. Nothing was changed."
    # S-03: the whole file goes back, capability (C) and security (S)
    # settings included, so say which of them differ and will revert, in
    # prefs diff's masked rendering, before the confirmation.
    _prefs_whole_file_cs "$f" "$prev"
    printf "This replaces the whole settings file of '%s' with the copy from before the last sync. Changes the app made to it since then will be lost.\n" "$tag"
    _signin_ask "Restore the prior copy of '${tag}'?" || { printf 'Not restoring; nothing was changed.\n'; exit 2; }
    wrc=0
    _prefs_write "$tag" "[]" strict keep "$prev" || wrc=$?
    [[ $wrc -eq 0 ]] || _prefs_refuse "'${tag}' was not restored: ${PR_HOLD:-its settings file could not be written}."
    ids="$(printf '%s' "${rec:-$none}" | "$AS_BIN_JQ" -r '[(.changes // {}) | keys[]] | join(",")')"
    # The prior copy lacks a key the last sync added, so restoring it removed
    # that key.
    rem="$(printf '%s' "${rec:-$none}" | "$AS_BIN_JQ" -r "${PREFS_DEFS}"'
      [(.changes // {}) | to_entries[] | select(.value.before | isabs) | .key] | join(",")')"
  else
    if [[ -z "$rec" ]]; then
      info "Nothing to undo for '${tag}': the sync state has no record of a sync that wrote it."
      exit 1
    fi
    case "$PR_BAD" in
      "${tag}"$'\t'*|*$'\n'"${tag}"$'\t'*) _prefs_refuse "'${tag}' has no settings file that can be read; nothing was changed." ;;
    esac
    # Each key that still holds the value the last sync wrote is undone: back
    # to its previous value, or, when that sync added it (its previous value
    # is the absent marker), removed. That removal is the one exception to
    # "nothing deletes". A key the app changed since is left alone.
    res="$("$AS_BIN_JQ" -c --argjson rec "$rec" --argjson allow "$PREFS_ALLOW" "${PREFS_DEFS}"'
      . as $d
      | [ $rec.changes | to_entries[] | .key as $id | .value as $c
          | ([$allow[] | select(.id == $id)][0]) as $k
          | select($k != null)
          | ($d | val($k.path)) as $cur
          | if $cur == $c.after and ($d | parentok($k.path)) then
              (if ($c.before | isabs) then {id: $id, ok: true, removed: true, op: [$k.path, ABS]}
               else {id: $id, ok: true, removed: false, op: [$k.path, $c.before], v: ($c.before | show)} end)
            else {id: $id, ok: false, why: "it changed since that sync"} end ]' "$f")" \
      || _prefs_refuse "'${tag}''s settings file could not be read; nothing was changed."
    ops="$(printf '%s' "$res" | "$AS_BIN_JQ" -c '[.[] | select(.ok) | .op]')"
    ids="$(printf '%s' "$res" | "$AS_BIN_JQ" -r '[.[] | select(.ok) | .id] | join(",")')"
    rem="$(printf '%s' "$res" | "$AS_BIN_JQ" -r '[.[] | select(.ok and .removed) | .id] | join(",")')"
    printf '%s' "$res" | "$AS_BIN_JQ" -r --arg t "$tag" '.[] | select(.ok | not) | "  Left \(.id) in \($t): \(.why)."' >&2
    if [[ "$ops" == "[]" ]]; then
      info "Nothing to undo for '${tag}': no key still holds the value the last sync wrote."
      exit 1
    fi
    wrc=0
    _prefs_write "$tag" "$ops" strict keep || wrc=$?
    [[ $wrc -eq 0 ]] || _prefs_refuse "'${tag}' was not changed: ${PR_HOLD:-its settings file could not be written}."
    printf '%s' "$res" | "$AS_BIN_JQ" -r --arg t "$tag" '.[] | select(.ok)
      | if .removed then "  Removed \(.id) from \($t): the last sync added it, and it still held the value that sync wrote."
        else "  Restored \(.id) in \($t) to \(.v)." end' >&2
  fi
  # Undone keys need review, so the next sync neither re-applies them nor
  # spreads the restored values (or a removed key's absence) as a new change;
  # the undo record is cleared. A removed key's last-seen value becomes the
  # plain absent marker, not the app's "removed" one, so a later review or
  # adopt can still set it there.
  _prefs_state_write "$(printf '%s' "$PR_STATE_JSON" | "$AS_BIN_JQ" -c --arg t "$tag" --arg ids "$ids" --arg rem "$rem" \
    --arg now "$(_prefs_now)" --argjson rec "${rec:-$none}" '
    ($ids | split(",") | map(select(. != ""))) as $u
    | ($rem | split(",") | map(select(. != ""))) as $r
    | .schema = 1
    | .keys = (reduce $u[] as $id ((.keys // {});
        .[$id] = ((.[$id] // {}) + {pending: {since: $now, reason: "undo",
                   candidates: {($t): ($rec.changes[$id].before // {absent: true})}}})))
    | .keys = (reduce $r[] as $id (.keys; .[$id].seen = ((.[$id].seen // {}) + {($t): {absent: true}})))
    | .undo = ((.undo // {}) | del(.[$t]))')" \
    || warn "The sync state $(_tilde_path "$PREFS_STATE") could not be written; the undone keys are not marked needs review."
  # Counts and key ids, never values: undone, restored (back to the previous
  # value) and removed (the sync had added them).
  local counts n_rst rst n_rem
  counts="$("$AS_BIN_JQ" -rn --arg ids "$ids" --arg rem "$rem" '
    ($ids | split(",") | map(select(. != ""))) as $u | ($rem | split(",") | map(select(. != ""))) as $r
    | ($u - $r) as $s
    | "\($u | length)|\($s | length)|\($s | join(","))|\($r | length)"')"
  IFS='|' read -r n n_rst rst n_rem <<< "$counts"
  _swap_log_ensure
  printf '[%s] PREFS_UNDO cmd=undo target=%s mode=%s undone=%s keys=%s restored=%s restored_keys=%s removed=%s removed_keys=%s\n' \
    "$(_prefs_now)" "$tag" "$([[ "$whole" == "true" ]] && printf 'whole-file' || printf 'keys')" "$n" "${ids:-none}" \
    "$n_rst" "${rst:-none}" "$n_rem" "${rem:-none}" >> "$SWAP_LOG"
  if [[ "$whole" == "true" ]]; then ok "Restored the prior copy of '${tag}'; the copy is kept."; fi
  info "Undid the last sync to '${tag}': ${n_rst} restored (${rst:-none}), ${n_rem} removed (${rem:-none})."
  if [[ -n "$ids" ]]; then
    info "Marked needs review: ${ids//,/, }. Decide with 'account-switcher prefs review' or 'prefs adopt'."
  fi
  exit 0
}

# ---- prefs review ----------------------------------------------------------------

# _prefs_cur <key-id> <tag>: the profile's value of the key in PR_PLAN, as
# JSON, when it holds one of the allowlisted type; nothing otherwise.
_prefs_cur() {
  printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -c --arg id "$1" --arg t "$2" \
    '.keys[] | select(.id == $id) | .recs[] | select(.tag == $t and (.absent | not) and .typeok) | .cur' 2>/dev/null
}

_prefs_review() {
  local ids id table line choice t v dec='{}' pins pins0 plan_ids n_pending n_open
  [[ $# -eq 0 ]] || { _prefs_usage; _prefs_refuse "prefs review takes no arguments."; }
  _signin_tty || _prefs_refuse "prefs review needs a terminal. Without one, use: prefs diff, prefs sync [<tag>] [--dry-run], prefs adopt <key-id> --from <tag>, prefs pin|unpin <tag> <key-id>|--all, prefs undo <tag>."
  _prefs_begin "reviewing settings"
  _prefs_prepare strict || exit 2
  # shellcheck disable=SC2086
  _prefs_plan "$(_prefs_words $PR_PARTS)" "$(_prefs_words $PRS_RUNNING)" \
    || _prefs_refuse "The settings files changed while they were being read. Run it again."
  table="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -c "${PREFS_DEFS} ${PREFS_TABLE_JQ}")"
  ids="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r '.keys[]
    | select(.status == "review" or ((.writes | length) + (.held | length)) > 0
             or ((.status | IN("type", "unset", "untouched") | not) and any(.recs[]; .pinned)))
    | .id')"
  if [[ -z "$ids" ]]; then
    printf 'Nothing to review: every synced key is in sync, nothing is pending and nothing is pinned.\n'
    exit 0
  fi
  n_open="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r '[.keys[] | select(.status == "review" or ((.writes | length) + (.held | length)) > 0)] | length')"
  pins0="$(printf '%s' "$PR_STATE_JSON" | "$AS_BIN_JQ" -c '.pins // {}')"
  pins="$pins0"
  printf 'prefs review: for each key, choose a value for every profile, pin it in one profile, or skip it.\n'
  for id in $ids; do
    line="$(printf '%s' "$table" | "$AS_BIN_JQ" -r --arg id "$id" '.byid[$id]')"
    printf '\n%s\n' "${line#  }"
    v="$(_prefs_cur "$id" primary)" || v=""
    if [[ -n "$v" ]]; then
      printf "  1) use primary's value (%s)\n" "$(printf '%s' "$v" | "$AS_BIN_JQ" -r "${PREFS_DEFS} show")"
    else
      printf "  1) use primary's value (primary has none)\n"
    fi
    printf "  2) use another profile's value\n  3) keep it different in one profile (pin)\n  4) skip (leave it as it is)\n"
    printf 'Choice [%s]: ' "$([[ -n "$v" ]] && printf '1' || printf '4')"
    choice=""
    IFS= read -r choice || choice=""
    [[ -n "$choice" ]] || { if [[ -n "$v" ]]; then choice=1; else choice=4; fi; }
    t=""
    case "$choice" in
      1) t="primary" ;;
      2|3)
        printf 'Which profile (%s)? ' "${PR_PARTS//$'\n'/, }"
        IFS= read -r t || t=""
        if [[ "$t" == "default" ]]; then t="primary"; fi
        case " ${PR_PARTS//$'\n'/ } " in *" ${t} "*) ;; *) printf '  Not a participating profile; skipped.\n'; continue ;; esac
        ;;
      *) printf '  Skipped.\n'; continue ;;
    esac
    if [[ "$choice" == "3" ]]; then
      pins="$(printf '%s' "$pins" | "$AS_BIN_JQ" -c --arg t "$t" --arg id "$id" '.[$t] = ((.[$t] // []) + [$id] | unique)')"
      printf "  %s keeps its own value in '%s' (pinned).\n" "$id" "$t"
      continue
    fi
    v="$(_prefs_cur "$id" "$t")" || v=""
    if [[ -z "$v" ]]; then printf "  '%s' holds no value for %s; skipped.\n" "$t" "$id"; continue; fi
    dec="$(printf '%s' "$dec" | "$AS_BIN_JQ" -c --arg id "$id" --argjson v "$v" --arg t "$t" '.[$id] = {value: $v, by: "review", from: $t}')"
    printf "  %s = %s (from '%s') for every profile not pinned.\n" "$id" "$(printf '%s' "$v" | "$AS_BIN_JQ" -r "${PREFS_DEFS} show")" "$t"
  done
  if [[ "$dec" == "{}" && "$pins" == "$pins0" ]]; then
    printf '\nNothing decided; nothing was written.\n'
    if [[ "$n_open" != "0" ]]; then exit 1; fi
    exit 0
  fi
  # shellcheck disable=SC2086
  _prefs_plan "$(_prefs_words $PR_PARTS)" "$(_prefs_words $PRS_RUNNING)" "$dec" true "$pins" \
    || _prefs_refuse "The settings files changed while they were being read; nothing was written. Run it again."
  printf '\nPlanned writes:\n'
  plan_ids="$(printf '%s' "$PR_PLAN" | "$AS_BIN_JQ" -r '[.keys[].writes[]] | length')"
  if [[ "$plan_ids" == "0" ]]; then printf '  none\n'; fi
  # shellcheck disable=SC2086
  _prefs_detail $PR_PARTS 2>&1
  _prefs_held_notes 2>&1
  if [[ "$pins" != "$pins0" ]]; then
    printf 'Pins after this review: %s\n' "$(printf '%s' "$pins" | "$AS_BIN_JQ" -r 'to_entries | map("\(.key): \(.value | join(", "))") | join("; ") | if . == "" then "none" else . end')"
  fi
  if ! _signin_ask "Apply these changes?"; then
    printf 'Not applied; nothing was written.\n'
    exit 1
  fi
  # shellcheck disable=SC2086
  _prefs_apply strict replace $PR_PARTS
  _prefs_commit "$PR_WRITTEN" "$pins" || warn "The sync state $(_tilde_path "$PREFS_STATE") could not be written."
  _prefs_tally review all "$PR_WRITTEN" "$PR_NOTWRITTEN" "$PR_PARTS"
  n_pending="$(printf '%s' "$PR_STATE_JSON" | "$AS_BIN_JQ" -r '[(.keys // {})[] | select(.pending != null)] | length')"
  if [[ "$n_pending" != "0" || "$PR_SKIPPED" -gt 0 ]]; then exit 1; fi
  exit 0
}

cmd_prefs() {
  local verb="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$verb" in
    diff)   _prefs_diff "$@" ;;
    sync)   _prefs_sync_cmd "$@" ;;
    review) _prefs_review "$@" ;;
    adopt)  _prefs_adopt "$@" ;;
    pin|unpin) _prefs_pin "$verb" "$@" ;;
    undo)   _prefs_undo "$@" ;;
    help|-h|--help) _prefs_usage; exit 0 ;;
    "") _prefs_usage; exit 2 ;;
    *) _prefs_usage; _prefs_refuse "Unknown prefs verb: ${verb}" ;;
  esac
}

# ---- swap (3-step: quit → settings step → launch; H-1, M-15, #11) ---------

# Script-level state used by the M-15 cleanup trap.
__SWAP_IN_PROGRESS="false"
__SWAP_TARGET_TAG=""
# "swap" while swap runs clone-prefs for its settings step (#11): clone-prefs
# then runs that step under swap's running rule and logs it as cmd=swap.
__PREFS_CALLER=""

_swap_cleanup_on_interrupt() {
  # The settings step's temporary files and lock, if it was interrupted.
  _prefs_rm_tmp
  _lock_release
  if [[ "$__SWAP_IN_PROGRESS" == "true" ]]; then
    warn "Swap interrupted before completion. Partial state may exist:"
    warn "  - Mac app may have been quit but not relaunched"
    warn "  - clone-prefs may have been partially applied (check '${__SWAP_TARGET_TAG}' user-data-dir)"
    warn ""
    warn "Recovery:"
    warn "  account-switcher list                 # see running instances"
    warn "  account-switcher launch ${__SWAP_TARGET_TAG:-<tag>}        # relaunch target if needed"
    warn "  account-switcher launch primary       # or fall back to primary"
  fi
}

cmd_swap_app() {
  local target_tag=""
  local skip_mirror="false"
  local skip_handoff="false"
  local operator_note=""
  local force="false"
  local new="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-mirror) skip_mirror="true"; shift ;;
      --no-handoff) skip_handoff="true"; shift ;;
      --force) force="true"; shift ;;
      --new) new="true"; shift ;;
      --note)
        if [[ $# -lt 2 ]]; then
          die "Flag --note requires a value (e.g., --note \"hit primary usage limit\")"
        fi
        operator_note="$2"
        shift 2
        ;;
      --note=*)
        operator_note="${1#--note=}"
        shift
        ;;
      -*) die "Unknown flag: $1" ;;
      *)
        if [[ -z "$target_tag" ]]; then
          target_tag="$1"
        else
          die "Unexpected arg: $1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$target_tag" ]]; then
    "$AS_BIN_CAT" <<EOF >&2
Usage: account-switcher swap <tag> [flags]
  flags:
    --no-mirror              skip the settings step
    --no-handoff             skip handoff-bridge capture (default: capture)
    --note "<text>"          optional operator-supplied note recorded in SWAP_HANDOFF.md
                              (240 char max; not auto-redacted — operator's responsibility)
    --force                  swap even when the target's profile is recorded on
                              another account (MISMATCH; see 'identity')
    --new                    allow a tag that is not in [accounts] and has no
                              profile folder yet (it creates one)
EOF
    return 1
  fi

  # H-1: Validate tag before any FS access.
  validate_tag "$target_tag"

  # #9: its quit and its settings step rely on detection; refuse before the
  # handoff capture, the quit or any profile write when the app isn't where
  # it looks.
  app_binary_present || die "$(app_binary_refusal "captured, quit, opened or written to any profile")"

  # #10: never while update holds its lock, and never a tag that is neither
  # configured nor on disk (--new allows it). Both run before the #6 check,
  # so a refusal quits, captures and writes nothing.
  if _update_lock_held; then die "$(_update_lock_refusal swapping)"; fi
  unknown_tag_guard "$target_tag" "$new" swap

  # #6: check the account the target's profile records before anything else:
  # before the handoff capture and before the M-15 trap, so a MISMATCH
  # refusal (--force overrides) has no side effect at all and leaves the
  # running instances alone. unknown proceeds with a hint.
  identity_gate "$target_tag" "$force" swap

  # #24: an observation, before the handoff and the quit, and after the #6
  # check so a refusal writes nothing.
  open_tags_observe
  open_tags_notice

  # #10, #24: one line while an app update is staged.
  update_wait_warning

  # M-15: Register cleanup trap before any side-effects.
  __SWAP_IN_PROGRESS="true"
  __SWAP_TARGET_TAG="$target_tag"
  trap _swap_cleanup_on_interrupt INT TERM EXIT

  local target_udd
  target_udd=$(udd_for_tag "$target_tag")
  local first_launch="false"
  [[ -d "$target_udd" ]] || first_launch="true"

  local is_primary="false"
  if [[ "$target_tag" == "primary" ]] || [[ "$target_tag" == "default" ]]; then
    is_primary="true"
  fi

  if [[ "$first_launch" == "true" ]] && [[ "$is_primary" == "false" ]]; then
    warn "First launch of '${target_tag}' — Claude will prompt for login in the new window."
  fi

  # ---- Step 0: Capture handoff state -------------------------------------
  # Privacy-safe work-state snapshot to SWAP_HANDOFF.md (under the configured
  # workspace dir). Runs BEFORE any other side-effects so the handoff is
  # preserved even if clone-prefs / quit / launch fail later. Detects the
  # currently-running source for direction; falls back gracefully if no Mac
  # app instance is running.
  #
  # Handoff-bridge model: chats remain ephemeral per-account by Anthropic's
  # design; work STATE carries via SWAP_HANDOFF.md, read at session start by
  # the next session in either account.
  if [[ "$skip_handoff" == "false" ]]; then
    local running_tag_for_handoff
    running_tag_for_handoff=$(detect_running_tag)
    if [[ -z "$running_tag_for_handoff" ]]; then
      # No instance running: the source is unknown, never assumed to be
      # primary (#25).
      running_tag_for_handoff="unknown"
    fi
    capture_handoff "$running_tag_for_handoff" "$target_tag" "$operator_note" 2>&1 | "$AS_BIN_SED" 's/^/    /'
    printf '\n'
  fi

  # ---- Step 1: Quit current Mac app instance(s) --------------------------
  quit_all_claude
  if [[ -n "$QUIT_TAGS" ]]; then
    _swap_log_ensure
    printf '[%s] QUIT_ALL tags=%s by=swap\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$QUIT_TAGS" >> "$SWAP_LOG"
  fi

  # ---- Step 2: The settings step (#11) -----------------------------------
  # After every instance has quit (which flushes each profile's settings
  # file and means the target is not running) and before the target
  # launches. It updates the allowlisted settings keys in the target only,
  # which may be primary, from every participating profile (prefs_step). For
  # a target other than primary, clone-prefs runs it, then copies primary's
  # extension folders and git-worktrees.json as before. --no-mirror skips
  # it. Whatever it returns, the swap goes on to launch: a refusal or a
  # failure here is a warning, never the end of a swap that has already
  # quit everything.
  if [[ "$skip_mirror" == "false" ]]; then
    local primary_udd
    primary_udd=$(udd_for_tag "primary")
    if [[ ! -d "$target_udd" ]]; then
      info "Skipping the settings step (target dir doesn't exist yet; first launch will create it)"
    elif [[ "$is_primary" == "true" ]] || [[ ! -d "$primary_udd" ]]; then
      prefs_step swap swap "$(identity_key "$target_tag")" "$(identity_key "$target_tag")" || :
    else
      info "Settings step and primary's user-facing prefs → ${target_tag}..."
      # A background job, waited for at once: clone-prefs keeps set -e (an
      # `if` or `||` around the pipeline would switch it off inside, and its
      # snapshot rollback depends on it), while its status reaches the swap
      # through wait instead of ending it.
      local clone_rc=0
      __PREFS_CALLER="swap"
      ( cmd_clone_prefs "primary" "$target_tag" 2>&1 | "$AS_BIN_SED" 's/^/    /' ) &
      wait "$!" || clone_rc=$?
      __PREFS_CALLER=""
      if [[ $clone_rc -ne 0 ]]; then
        warn "The settings step did not finish (see above); the swap continues."
      fi
      printf '\n'
    fi
  fi

  # ---- Step 3: Launch target Mac app instance ---------------------------
  info "Launching '${target_tag}' Mac app instance..."
  info "  user-data-dir: ${target_udd}"

  # #8: any main process still listed after the quit, so the wait at the end
  # takes only the instance this swap opens.
  local pre_pids
  pre_pids="$(get_claude_pids)"

  # A failed open ends the swap here, with what was done and the remedy,
  # before the Swapped line, the marker and the APP_SWAP row. The quit and
  # the settings step are complete, so it is not an interrupted swap: the
  # trap still cleans up, without its "interrupted" lines.
  local open_rc=0
  if [[ "$is_primary" == "true" ]]; then
    "$AS_BIN_OPEN" -n -a "Claude" || open_rc=$?
  else
    "$AS_BIN_OPEN" -n -a "Claude" --args --user-data-dir="${target_udd}" || open_rc=$?
  fi
  if [[ $open_rc -ne 0 ]]; then
    __SWAP_IN_PROGRESS="false"
    die "Could not open the '${target_tag}' instance (open failed); every Claude instance was quit. Run: account-switcher launch ${target_tag}"
  fi

  ok "Swapped to '${target_tag}'. Bridged Code billing will follow ${target_tag}'s account auth."

  printf '%s\n' "$target_tag" > "$STATUSLINE_MARKER"
  _swap_log_ensure
  printf '[%s] APP_SWAP target=%s udd=%s first_launch=%s mirror=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$target_tag" "$target_udd" "$first_launch" \
    "$([ "$skip_mirror" == "false" ] && echo "yes" || echo "no")" \
    >> "$SWAP_LOG"
  _open_tags_add "$target_tag"

  if [[ "$first_launch" == "true" ]]; then
    info ""
    info "Next: sign this profile in with: account-switcher signin ${target_tag}"
    info "After sign-in, later 'swap ${target_tag}' runs skip the sign-in screen."
  fi

  # Warn when target tag isn't declared in [accounts]. cmd_add_account is the
  # explicit registration subcommand; no code path writes to [accounts]
  # implicitly. Skip the warning for primary/default since those map to the
  # OS-default udd and don't need explicit registration to work.
  if [[ "$is_primary" == "false" ]] && ! tag_is_in_accounts "$target_tag"; then
    info ""
    warn "Tag '${target_tag}' is not declared in [accounts] in ${CONFIG_FILE}."
    warn "After first-launch login, register the account so 'status' can"
    warn "resolve CLI identity → switcher tag:"
    warn "  account-switcher add-account ${target_tag} <email-of-this-account>"
  fi

  # M-15: Success path — clear in-progress flag so the EXIT trap is a no-op.
  __SWAP_IN_PROGRESS="false"
  trap - INT TERM EXIT

  # #8: the swap is complete; wait for the new instance, bring it to the
  # front and end with its line. This runs after the trap is cleared, so an
  # interrupt during the wait does not report a half-done swap.
  _launch_report "$target_tag" "$pre_pids"
}

# ---- clone-prefs (H-1, M-7, M-10, M-11) ----------------------------------

# Script-level state used by the M-7 snapshot-rollback trap. clone-prefs is
# called both directly and from cmd_swap_app's auto-mirror step, so the
# trap state is reset at function entry/exit.
__CLONE_PREFS_SUCCEEDED="false"
__CLONE_PREFS_SNAPSHOT_DIR=""
__CLONE_PREFS_TARGET_UDD=""
__CLONE_PREFS_SNAPSHOTTED=()

_clone_prefs_restore_on_failure() {
  # The settings step's temporary files and lock, if it was interrupted.
  _prefs_rm_tmp
  _lock_release
  # Restore each snapshotted item back to target_udd, then remove snapshot dir.
  if [[ "$__CLONE_PREFS_SUCCEEDED" != "true" ]] && [[ -d "$__CLONE_PREFS_SNAPSHOT_DIR" ]]; then
    warn "Restoring '${__CLONE_PREFS_TARGET_UDD}' from clone-prefs snapshot due to interruption/failure..."
    local item
    # The list can be empty (the target held none of the items), which bash
    # 3.2 under set -u treats as unbound unless guarded like this.
    for item in ${__CLONE_PREFS_SNAPSHOTTED[@]+"${__CLONE_PREFS_SNAPSHOTTED[@]}"}; do
      if [[ -e "${__CLONE_PREFS_SNAPSHOT_DIR}/${item}" ]]; then
        "$AS_BIN_RM" -rf "${__CLONE_PREFS_TARGET_UDD}/${item}" 2>/dev/null || true
        "$AS_BIN_MV" "${__CLONE_PREFS_SNAPSHOT_DIR}/${item}" "${__CLONE_PREFS_TARGET_UDD}/${item}" 2>/dev/null || true
      fi
    done
  fi
  if [[ -d "$__CLONE_PREFS_SNAPSHOT_DIR" ]]; then
    "$AS_BIN_RM" -rf "$__CLONE_PREFS_SNAPSHOT_DIR" 2>/dev/null || true
  fi
}

# Clean up orphaned clone-prefs snapshots from prior runs that exited via
# SIGKILL or other path that bypassed the EXIT trap. Invariant: never more
# than one backup retained at a time. Called at the start of every
# cmd_clone_prefs invocation, before creating the new snapshot — guarantees
# the ≤1-backup invariant is restored even if a previous run died without
# trap firing.
cleanup_orphan_clone_prefs_snapshots() {
  local target_udd="$1"
  local d count=0
  shopt -s nullglob
  for d in "${target_udd}"/.clone-prefs-bak.*; do
    [[ -d "$d" ]] || continue
    "$AS_BIN_RM" -rf "$d" 2>/dev/null || true
    count=$((count + 1))
  done
  shopt -u nullglob
  if [[ $count -gt 0 ]]; then
    info "Cleaned up ${count} orphan clone-prefs snapshot(s) from interrupted prior run(s)."
  fi
}

cmd_clone_prefs() {
  local source_tag="${1:-primary}"
  local target_tag="${2:-backup}"

  if [[ "$source_tag" == "$target_tag" ]]; then
    die "source and target must differ (got both: ${source_tag})"
  fi

  # H-1: Validate both tags before any FS access.
  validate_tag "$source_tag"
  validate_tag "$target_tag"

  # #9: its running checks rely on detection.
  app_binary_present || die "$(app_binary_refusal "written to any profile")"

  local source_udd
  source_udd=$(udd_for_tag "$source_tag")
  local target_udd
  target_udd=$(udd_for_tag "$target_tag")

  [[ -d "$source_udd" ]] || die "Source profile dir does not exist: ${source_udd}"
  [[ -d "$target_udd" ]] || die "Target profile dir does not exist: ${target_udd}. Run 'launch ${target_tag}' first to create it."

  # Initial running-instance check: refuse if target is currently running
  # (Electron may have config files open; overwrite could corrupt state),
  # and refuse when that cannot be determined (is_tag_running = 2).
  local running_rs=0
  is_tag_running "$target_tag" || running_rs=$?
  if [[ $running_rs -eq 0 ]]; then
    die "Target instance ('${target_tag}') is currently running. Quit it before cloning prefs (e.g., 'account-switcher swap ${source_tag}' or Cmd+Q the target window)."
  fi
  if [[ $running_rs -eq 2 ]]; then
    die "Cannot tell whether '${target_tag}' is running: a running Claude instance's tag is unknown, or the process list could not be read (see 'account-switcher list'). Refusing to write into a profile that may be open. Quit the instance shown as unknown (or run 'account-switcher quit --all') and retry."
  fi

  # #11: like every command but swap, clone-prefs writes nothing when more
  # than one instance runs without --user-data-dir (one could be any
  # profile). swap runs this after every instance has quit, so the rule is
  # swap's own there.
  local prefs_mode="strict"
  if [[ "$__PREFS_CALLER" == "swap" ]]; then prefs_mode="swap"; fi
  if [[ "$prefs_mode" == "strict" ]]; then
    _prefs_scan
    if [[ "$PRS_STATE" != "ok" ]]; then
      die "Not cloning into '${target_tag}': ${PRS_WHY}. Nothing was written."
    fi
  fi

  info "Cloning user-facing prefs: ${source_tag} → ${target_tag}"
  info "  source: ${source_udd}"
  info "  target: ${target_udd}"

  # #11: settings are no longer copied as a whole file. The key-level step
  # updates only the allowlisted keys in the target, from every
  # participating profile (src is not used for them), so the M-10 scan of
  # the source's claude_desktop_config.json, which guarded the whole-file
  # copy, guards nothing and is gone. A refusal here (the settings-sync lock
  # is held, the sync state can't be read) ends clone-prefs before anything
  # is written; under swap it is a warning and the copy below goes on.
  local prefs_rc=0
  prefs_step "$([[ "$prefs_mode" == "swap" ]] && printf 'swap' || printf 'clone-prefs')" \
    "$prefs_mode" "$(identity_key "$target_tag")" "$(identity_key "$target_tag")" || prefs_rc=$?
  if [[ $prefs_rc -eq 2 && "$prefs_mode" == "strict" ]]; then
    die "Not cloning into '${target_tag}': the settings step refused (see above). Nothing was written."
  fi

  # Invariant: never more than one backup retained at a time. Sweep any orphan
  # snapshots from prior interrupted runs before creating the new one.
  cleanup_orphan_clone_prefs_snapshots "$target_udd"

  # M-7: Snapshot existing target items before applying. Snapshot lives
  # inside target_udd to guarantee same-filesystem (atomic rename via
  # rename(2)). On failure or interrupt, the trap restores from snapshot.
  local snapshot_dir
  snapshot_dir="$("$AS_BIN_MKTEMP" -d "${target_udd}/.clone-prefs-bak.XXXXXX")"
  "$AS_BIN_CHMOD" 700 "$snapshot_dir"

  __CLONE_PREFS_SUCCEEDED="false"
  __CLONE_PREFS_SNAPSHOT_DIR="$snapshot_dir"
  __CLONE_PREFS_TARGET_UDD="$target_udd"
  __CLONE_PREFS_SNAPSHOTTED=()

  # N-1: trap registered BEFORE snapshot move loop so a SIGINT or mid-loop mv
  # failure during snapshot capture is recovered. The trap closure handles
  # empty __CLONE_PREFS_SNAPSHOTTED correctly (for-loop no-op).
  trap _clone_prefs_restore_on_failure INT TERM EXIT

  local items_to_clone=("Claude Extensions" "Claude Extensions Settings" "git-worktrees.json")
  local item
  for item in "${items_to_clone[@]}"; do
    if [[ -e "${target_udd}/${item}" ]]; then
      "$AS_BIN_MV" "${target_udd}/${item}" "${snapshot_dir}/${item}"
      __CLONE_PREFS_SNAPSHOTTED+=("$item")
    fi
  done

  # M-11: Re-check target instance running BETWEEN snapshot and apply.
  # The race window is small (the operator clicks Claude in Dock during the
  # snapshot operation), but real. If a new instance launched, abort and
  # let the trap restore.
  running_rs=0
  is_tag_running "$target_tag" || running_rs=$?
  if [[ $running_rs -eq 0 ]]; then
    die "Target instance ('${target_tag}') started while preparing snapshot. Aborting; trap will restore from snapshot (M-11)."
  fi
  if [[ $running_rs -eq 2 ]]; then
    die "Cannot tell whether '${target_tag}' is running after preparing the snapshot (a running instance's tag is unknown; see 'account-switcher list'). Aborting; trap will restore from snapshot (M-11)."
  fi

  local mirrored=()
  local skipped=()

  # 1. claude_desktop_config.json: the settings step above (#11).

  # 2. Claude Extensions/ (rsync without --delete; target was moved to snapshot,
  #    so no stale entries to delete).
  if [[ -d "${source_udd}/Claude Extensions" ]]; then
    "$AS_BIN_RSYNC" -a "${source_udd}/Claude Extensions/" "${target_udd}/Claude Extensions/"
    mirrored+=("Claude Extensions/")
  else
    skipped+=("Claude Extensions/ (source missing)")
  fi

  # 3. Claude Extensions Settings/
  if [[ -d "${source_udd}/Claude Extensions Settings" ]]; then
    "$AS_BIN_RSYNC" -a "${source_udd}/Claude Extensions Settings/" "${target_udd}/Claude Extensions Settings/"
    mirrored+=("Claude Extensions Settings/")
  else
    skipped+=("Claude Extensions Settings/ (source missing)")
  fi

  # 4. git-worktrees.json — MERGE with target's pre-snapshot version (preserves
  #    target's worktree awareness).
  if [[ -f "${source_udd}/git-worktrees.json" ]]; then
    if [[ -f "${snapshot_dir}/git-worktrees.json" ]]; then
      local merged_json
      merged_json=$("$AS_BIN_JQ" -s \
        '(.[1].worktrees // {}) as $tgt | (.[0].worktrees // {}) as $src
         | {worktrees: ($tgt + $src),
            schemaVersion: ([.[0].schemaVersion // 1, .[1].schemaVersion // 1] | max)}' \
        "${source_udd}/git-worktrees.json" \
        "${snapshot_dir}/git-worktrees.json")
      printf '%s\n' "$merged_json" > "${target_udd}/git-worktrees.json"
      local source_count target_count
      source_count=$("$AS_BIN_JQ" -r '.worktrees | length' "${source_udd}/git-worktrees.json" 2>/dev/null || echo 0)
      target_count=$(printf '%s' "$merged_json" | "$AS_BIN_JQ" -r '.worktrees | length')
      mirrored+=("git-worktrees.json (merged: source=${source_count} → target=${target_count})")
    else
      "$AS_BIN_CP" "${source_udd}/git-worktrees.json" "${target_udd}/git-worktrees.json"
      mirrored+=("git-worktrees.json (copied; target had none)")
    fi
  else
    skipped+=("git-worktrees.json (source missing)")
  fi

  # All apply steps succeeded — mark complete, clean up snapshot, clear trap.
  __CLONE_PREFS_SUCCEEDED="true"
  "$AS_BIN_RM" -rf "$snapshot_dir"
  __CLONE_PREFS_SNAPSHOT_DIR=""
  trap - INT TERM EXIT

  local m
  for m in ${mirrored[@]+"${mirrored[@]}"}; do
    ok "Mirrored: ${m}"
  done

  _swap_log_ensure
  printf '[%s] CLONE_PREFS source=%s target=%s mirrored=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$source_tag" "$target_tag" \
    "$(IFS=,; echo "${mirrored[*]+"${mirrored[*]}"}")" \
    >> "$SWAP_LOG"

  printf '\n'
  if [[ ${#mirrored[@]} -eq 0 ]]; then
    # The settings step above ran; only the copies had nothing to copy.
    info "Nothing else to mirror: '${source_tag}' has no Claude Extensions/, Claude Extensions Settings/ or git-worktrees.json."
    return 0
  fi

  ok "Cloned ${#mirrored[@]} item(s) from '${source_tag}' to '${target_tag}'"
  if [[ ${#skipped[@]} -gt 0 ]]; then
    info "Skipped (source missing): ${skipped[*]}"
  fi
  info "Auth state, caches, VM bundles, Code session artifacts, and per-instance"
  info "Mac app fingerprints intentionally left untouched."
  info ""
  info "Next 'swap ${target_tag}' will pick up the mirrored prefs."
}

# ---- quit (H-1) ----------------------------------------------------------

cmd_quit() {
  local target="${1:-all}"

  case "$target" in
    --all|all|"")
      # #9: the quit finds what to close through detection.
      app_binary_present || die "$(app_binary_refusal "quit")"
      quit_all_claude
      _swap_log_ensure
      printf '[%s] QUIT_ALL tags=%s by=quit\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "${QUIT_TAGS:-none}" >> "$SWAP_LOG"
      ;;
    *)
      # H-1: Reject malformed tags even though per-tag quit is not yet
      # implemented (avoids leaking implementation details via error path).
      validate_tag "$target"
      die "Per-tag quit not yet supported (would require PID-to-udd matching). Use 'quit --all' or Cmd+Q in the target window."
      ;;
  esac
}

# ---- update (#10) ---------------------------------------------------------
#
# update [--yes] installs the staged app update on request. It lists each
# instance it will close (tag · PID, from the exact matcher), warns that
# scheduled tasks pause while Claude is closed, and asks (--yes skips; with
# no terminal and no --yes it refuses). Then it takes the lock, reads
# launchAfterInstallation, checks that the open instances are still exactly
# the ones it listed, quits through quit_all_claude in its listed mode
# (graceful, TERM, KILL, final check; it signals only the listed PIDs, never
# the updater's helper, and stops if an instance it didn't list appears),
# waits up to [update] install_timeout_s (default 120) for
# "Installation completed successfully" stamped at or after the quit began,
# reopens every tag that was open through open_tag_instance, prints the
# installed version before and after, and releases the lock.
#
# The helper reopens the app itself when the install request asked it to
# (launchAfterInstallation true; most completed installs did): it opens one
# instance without --user-data-dir, which is primary. update then counts that
# instance as primary's reopen when primary was open, reports it and leaves
# it running when primary was not, and never launches primary a second time.
# It also never opens a tag that is already running again.
#
# Exit codes, with precedence 1 > 3 > 0:
#   0  nothing staged (nothing closed), or installed, every tag reopened
#   1  the installed version did not change (the wait timed out, or the
#      helper finished without changing it), or an instance would not quit;
#      the helper log's last timestamped line is printed
#   2  refused, or declined, before anything was closed (also bad arguments);
#      or stopped during the quit because an instance it hadn't listed
#      appeared (result=unlisted: it is named, nothing more is signalled,
#      nothing is installed, and what update closed is reopened)
#   3  installed, but a tag did not reopen in time (named)
#   130  interrupted (INT or TERM): what was closed, and how to reopen it
# History rows: QUIT_ALL (as quit writes it), one LAUNCH row per tag it opens
# (open_tag_instance), and one UPDATE row: result, both versions, reopened.

UPD_CLOSED=0
UPD_TAGS=""

_update_usage() {
  printf 'Usage: account-switcher update [--yes]\n' >&2
}

# A refusal before anything was closed: one error line, exit 2.
_update_refuse() {
  printf '\033[31mERROR:\033[0m %s\n' "$*" >&2
  exit 2
}

# The EXIT trap: releases the lock if this run took it, then refreshes the
# record (phase idle).
_update_on_exit() {
  local rc=$?
  set +e
  trap '' INT TERM
  if [[ -n "$LOCK_OWNED" ]]; then
    _update_lock_release
    update_observe
  fi
  exit "$rc"
}

# The INT/TERM trap: says what was closed and how to reopen it; the EXIT trap
# then releases the lock.
_update_on_signal() {
  local t
  trap '' INT TERM
  printf '\nInterrupted.\n' >&2
  if [[ "$UPD_CLOSED" == "1" && -n "$UPD_TAGS" ]]; then
    printf "Claude was closed for the update. Once the updater's log no longer ends with 'Beginning installation', reopen each tag:\n" >&2
    for t in $UPD_TAGS; do printf '  account-switcher launch %s\n' "$t" >&2; done
  else
    printf 'Nothing was closed.\n' >&2
  fi
  exit 130
}

_update_history() {
  if [[ -d "$STORE" ]]; then
    _swap_log_ensure
    printf '[%s] UPDATE result=%s before=%s after=%s reopened=%s\n' \
      "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >> "$SWAP_LOG" || :
  fi
}

# _update_reopen <lai: true|false> <installed: 1|0> [<command: update|reopen>]:
# reopens every tag in UPD_TAGS and sets UPD_REOPENED and UPD_MISSING. With
# lai true after an install, primary is the helper's to reopen: it waits for
# it and never opens it. A tag that is already running is not opened again;
# a tag whose state can't be told is not opened either (named, for launch by
# hand). <command> names the caller in its messages (default update, whose
# output is unchanged). Each tag it counts as reopened is seen again in the
# record of closed tags (#24).
_update_reopen() {
  local lai="$1" installed="$2" cmd="${3:-update}" t rs pre npid helper=""
  UPD_REOPENED=0
  UPD_MISSING=""
  if [[ "$lai" == "true" && "$installed" == "1" ]]; then
    helper="$(wait_for_new_instance primary "" "$NEW_INSTANCE_WAIT_S")"
  fi
  if [[ -n "$UPD_TAGS" ]]; then printf 'Reopening:\n'; fi
  for t in $UPD_TAGS; do
    if [[ "$t" == "primary" && "$lai" == "true" && "$installed" == "1" ]]; then
      if [[ -n "$helper" ]]; then
        printf '  primary · PID %s (opened by the updater; not opened again)\n' "$helper"
        _open_tags_back primary
        UPD_REOPENED=$((UPD_REOPENED + 1))
      else
        printf "  primary: not seen within %s s. The updater was asked to reopen it, so %s does not open it a second time; if it does not appear, run: account-switcher launch primary\n" "$NEW_INSTANCE_WAIT_S" "$cmd"
        UPD_MISSING="${UPD_MISSING} primary"
      fi
      continue
    fi
    rs=0
    is_tag_running "$t" || rs=$?
    if [[ $rs -eq 0 ]]; then
      printf '  %s: already running; not opened again\n' "$t"
      _open_tags_back "$t"
      UPD_REOPENED=$((UPD_REOPENED + 1))
      continue
    fi
    if [[ $rs -eq 2 ]]; then
      printf "  %s: can't tell whether it is running (an instance's tag is unknown), so it is not opened; check account-switcher list, then: account-switcher launch %s\n" "$t" "$t"
      UPD_MISSING="${UPD_MISSING} ${t}"
      continue
    fi
    pre="$(get_claude_pids)"
    if ! open_tag_instance "$t" "$(udd_for_tag "$t")" false; then
      printf "  %s: could not be opened (open failed); run: account-switcher launch %s\n" "$t" "$t"
      UPD_MISSING="${UPD_MISSING} ${t}"
      continue
    fi
    npid="$(wait_for_new_instance "$t" "$pre" "$NEW_INSTANCE_WAIT_S")"
    if [[ -n "$npid" ]]; then
      printf '  %s · PID %s\n' "$t" "$npid"
      _open_tags_back "$t"
      UPD_REOPENED=$((UPD_REOPENED + 1))
    else
      printf "  %s: opened, but no new instance appeared within %s s (account-switcher list)\n" "$t" "$NEW_INSTANCE_WAIT_S"
      UPD_MISSING="${UPD_MISSING} ${t}"
    fi
  done
  if [[ -n "$helper" && " ${UPD_TAGS} " != *" primary "* ]]; then
    if [[ "$cmd" == "update" ]]; then
      printf '  primary · PID %s was opened by the updater (primary was not open before); it is left running.\n' "$helper"
    else
      printf '  primary · PID %s was opened by the updater; it is left running.\n' "$helper"
    fi
    _open_tags_primary_seen
  fi
  return 0
}

# _update_install_handoff: an install is running (the caller has printed the
# log's last line), so nothing is reopened: starting the app now would start
# it while its bundle is being replaced (#10). Prints, instead, the launch
# command for each tag in UPD_TAGS.
_update_install_handoff() {
  local t
  printf "Not reopening while the app is being replaced. When the log shows 'Installation completed successfully' (account-switcher list shows the version), reopen each tag:\n"
  for t in $UPD_TAGS; do printf '  account-switcher launch %s\n' "$t"; done
}

cmd_update() {
  local yes="false" arg
  for arg; do
    case "$arg" in
      "") ;;
      --yes) yes="true" ;;
      *) _update_usage; _update_refuse "Unknown argument for update: ${arg}" ;;
    esac
  done
  UPD_CLOSED=0
  UPD_TAGS=""
  trap _update_on_exit EXIT
  trap _update_on_signal INT TERM

  # #9: it lists and closes instances through detection.
  app_binary_present || _update_refuse "$(app_binary_refusal "closed")"

  rotate_swap_log_if_needed

  if _update_lock_held; then _update_refuse "$(_update_lock_refusal updating)"; fi

  # What is installed and staged (the reader; nothing is closed yet).
  update_observe
  local before="$UPD_INSTALLED" staged="$UPD_STAGED"
  if [[ "$before" == "unknown" ]]; then
    _update_refuse "The installed app's version can't be read (${UPD_INSTALLED_WHY}), so update could not tell whether an install worked. Nothing was closed."
  fi
  case "$staged" in
    none)
      printf 'No update is staged (installed: %s). Nothing to install; nothing was closed.\n' "$before"
      exit 0
      ;;
    unknown)
      _update_refuse "Can't tell whether an update is staged (${UPD_WHY}). Nothing was closed."
      ;;
  esac
  if _updater_log_scan "" && _updater_installing; then
    _update_refuse "The updater is installing right now (its log's last line: ${UPD_LOG_LAST}). Nothing was closed; check again in a minute with: account-switcher list"
  fi
  _updater_flag
  if [[ "$UPD_FLAG" == "unknown" ]]; then
    _update_refuse "The updater's state file ($(_tilde_path "$UPDATER_STATE_FILE")) is missing or can't be read, so no install request may be on file, and update can't tell whether the updater will reopen Claude itself. Nothing was closed. Leave Claude open for a minute (each launch files an install request), then retry."
  fi

  # 1. Each instance it will close, from the exact matcher (#9).
  local rows st=0 pid profile method listed="" unknown=""
  rows="$(claude_instances)" || st=$?
  if [[ $st -ne 0 ]]; then
    _update_refuse "The process table could not be read, so update can't name what it would close. Nothing was closed."
  fi
  # #24: an observation from the same read, before anything is listed or
  # closed.
  _open_tags_observe_rows "$rows"
  open_tags_notice
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    if [[ "$profile" == "unknown" ]]; then unknown="${unknown} ${pid}"; continue; fi
    listed="${listed} ${pid}"
    case " ${UPD_TAGS} " in
      *" ${profile} "*) ;;
      *) UPD_TAGS="${UPD_TAGS} ${profile}" ;;
    esac
  done <<< "$rows"
  UPD_TAGS="${UPD_TAGS# }"
  local n_tags=0 t
  for t in $UPD_TAGS; do n_tags=$((n_tags + 1)); done
  if [[ -n "$unknown" ]]; then
    _update_refuse "PID${unknown} runs on a profile update can't determine, so it could not reopen it. Nothing was closed; see account-switcher list, and close that window yourself first."
  fi

  printf 'Install the staged Claude update: %s installed, %s staged.\n' "$before" "$staged"
  printf 'Every tag runs the same app, so the update installs only once every Claude instance, in every account, is closed.\n'
  if [[ -n "$listed" ]]; then
    printf 'It will close:\n'
    while IFS=$'\t' read -r pid profile method; do
      [[ -n "$pid" ]] || continue
      printf '  %s · PID %s\n' "$profile" "$pid"
    done <<< "$rows"
    printf 'Work in progress in those windows may be lost. Afterwards it reopens: %s\n' "$UPD_TAGS"
  else
    printf 'No Claude instance is open; nothing will be closed.\n'
  fi
  # 2. The scheduled-task warning.
  printf 'Scheduled tasks pause while Claude is closed.\n'

  # 3. The confirmation.
  if [[ -n "$listed" && "$yes" != "true" ]]; then
    _signin_tty || _update_refuse "update needs a terminal to confirm the list above, or --yes. Nothing was closed."
    if ! _signin_ask "Close them and install ${staged}?"; then
      printf '\n'
      printf 'Not updating; nothing was closed.\n'
      exit 2
    fi
    printf '\n'
  fi

  # 4. The lock.
  _update_lock_take || _update_refuse "Another update took the lock ($(_tilde_path "$UPDATE_LOCK")) just now. Nothing was closed."
  _update_state_write "$staged" "$before" "$UPD_FIRST_SEEN" updating "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$$"

  # 5. launchAfterInstallation, read immediately before the quit.
  _updater_flag
  local lai="$UPD_FLAG"
  if [[ "$lai" == "unknown" ]]; then
    _update_refuse "The updater's state file can no longer be read, so update can't tell whether the updater will reopen Claude itself. Nothing was closed."
  fi

  # 6. The quit, only of the instances listed (and confirmed): the same
  #    check signin --quit-others makes, immediately before quit_all_claude,
  #    which then signals only the listed PIDs and stops (status 3) if an
  #    instance that wasn't listed appears during the quit.
  local now p since quit_rc=0
  now="$(get_claude_pids)"
  now=" ${now//$'\n'/ } "
  for p in $listed; do
    if [[ "$now" != *" ${p} "* ]]; then
      _update_refuse "The open instances changed since the list (PID ${p} is gone). Nothing was closed; run update again."
    fi
  done
  for p in $now; do
    if [[ " ${listed} " != *" ${p} "* ]]; then
      _update_refuse "The open instances changed since the list (PID ${p} was not listed). Nothing was closed; run update again."
    fi
  done
  # The step's start, in local time like the helper log's stamps (see
  # _updater_log_scan): a completion stamped at or after it counts.
  since="$("$AS_BIN_DATE" '+%Y-%m-%d %H:%M:%S')"
  if [[ -n "$listed" ]]; then
    UPD_CLOSED=1
    # The PIDs are numbers, so word splitting is the point.
    # shellcheck disable=SC2086
    ( quit_all_claude listed $listed ) || quit_rc=$?
    if [[ -d "$STORE" ]]; then
      _swap_log_ensure
      local ut="${UPD_TAGS// /,}"
      printf '[%s] QUIT_ALL tags=%s by=update\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "${ut:-none}" >> "$SWAP_LOG" || :
    fi
  fi
  if [[ $quit_rc -ne 0 ]]; then
    # The quit stopped: status 3, an instance that wasn't listed appeared
    # (nothing more was signalled); otherwise an instance would not close.
    # There is no install wait, but the graceful quit may already have closed
    # every listed instance, and the updater may have begun replacing the
    # bundle. So the log is read first, as after the wait: with an install
    # running nothing is reopened (#10), and the installed version is read
    # either way.
    local stop_result stop_code stop_reopen stop_hold stop_after
    if [[ $quit_rc -eq 3 ]]; then
      stop_result="unlisted"
      stop_code=2
      stop_reopen="The open instances changed during the quit (named above), so update stopped before the install: it closes only what it listed. Reopening what it closed."
      stop_hold="The open instances changed during the quit (named above), so update stopped before the install: it closes only what it listed. The updater's log shows an install running, so nothing is reopened."
    else
      stop_result="quit-failed"
      stop_code=1
      stop_reopen="Could not close every instance (see above), so the updater can't install. Reopening what was closed."
      stop_hold="Could not close every instance (see above), but the updater's log shows an install running, so nothing is reopened."
    fi
    stop_after="$(_plist_version "$APP_INFO_PLIST")" || stop_after="unknown"
    _updater_log_scan "" || UPD_LOG_LAST=""
    if _updater_installing; then
      printf '\033[31mERROR:\033[0m %s\n' "$stop_hold" >&2
      printf "The updater's log shows an install running:\n  %s\n" "$UPD_LOG_LAST"
      _update_install_handoff
      printf 'Installed version: %s before, %s after.\n' "$before" "$stop_after"
      _update_history "$stop_result" "$before" "$stop_after" "0/${n_tags}"
      printf 'update before=%s after=%s result=%s reopened=0/%s exit=%s\n' "$before" "$stop_after" "$stop_result" "$n_tags" "$stop_code"
      exit "$stop_code"
    fi
    printf '\033[31mERROR:\033[0m %s\n' "$stop_reopen" >&2
    _update_reopen false 0
    if [[ "$stop_after" == "$before" ]]; then
      printf 'Installed version: %s before, %s after (nothing was installed).\n' "$before" "$stop_after"
    else
      printf 'Installed version: %s before, %s after.\n' "$before" "$stop_after"
    fi
    _update_history "$stop_result" "$before" "$stop_after" "${UPD_REOPENED}/${n_tags}"
    printf 'update before=%s after=%s result=%s reopened=%s/%s exit=%s\n' "$before" "$stop_after" "$stop_result" "$UPD_REOPENED" "$n_tags" "$stop_code"
    exit "$stop_code"
  fi

  # 7. The bounded wait for the helper's completion line.
  local timeout polls=0 done_seen=0
  timeout="$(_update_config_int install_timeout_s "$UPDATE_TIMEOUT_DEFAULT" 10 3600)"
  printf 'Waiting up to %s s for the updater to install %s...\n' "$timeout" "$staged"
  while [[ $polls -lt $timeout ]]; do
    polls=$((polls + 1))
    if [[ -n "$AS_TEST_POLL_HOOK" ]]; then "$AS_TEST_POLL_HOOK" "$polls" || :; fi
    if _updater_log_scan "$since" && [[ $UPD_LOG_DONE -gt 0 ]]; then
      done_seen=1
      break
    fi
    "$AS_BIN_SLEEP" 1
  done

  # The result, from the installed Info.plist: the version is the evidence.
  local after result
  after="$(_plist_version "$APP_INFO_PLIST")" || after="unknown"
  _updater_log_scan "" || UPD_LOG_LAST=""
  if [[ "$after" != "unknown" && "$after" != "$before" ]]; then
    result="updated"
  elif [[ $done_seen -eq 1 ]]; then
    result="unchanged"
  else
    result="timeout"
  fi

  # An install still running when the wait ends: reopening now would start
  # the app while its bundle is being replaced.
  if [[ "$result" == "timeout" ]] && _updater_installing; then
    printf "No 'Installation completed successfully' within %s s, and the updater's log shows an install still running:\n  %s\n" "$timeout" "$UPD_LOG_LAST"
    _update_install_handoff
    printf 'Installed version: %s before, %s after.\n' "$before" "$after"
    _update_history timeout "$before" "$after" "0/${n_tags}"
    printf 'update before=%s after=%s result=timeout reopened=0/%s exit=1\n' "$before" "$after" "$n_tags"
    exit 1
  fi

  # 8. Reopen every tag that was open.
  local installed=0
  if [[ "$result" != "timeout" ]]; then installed=1; fi
  _update_reopen "$lai" "$installed"

  # 9. The versions, before and after.
  printf 'Installed version: %s before, %s after.\n' "$before" "$after"
  local code=0
  case "$result" in
    updated)
      if [[ $done_seen -eq 0 ]]; then
        warn "The installed version changed, but the updater's log shows no 'Installation completed successfully' since the update began."
      fi
      if [[ -n "$UPD_MISSING" ]]; then
        code=3
        warn "Not every tag reopened:${UPD_MISSING}. Open each with: account-switcher launch <tag>"
      else
        ok "Claude ${after} is installed."
      fi
      ;;
    unchanged)
      code=1
      printf "The updater reported 'Installation completed successfully', but the installed version did not change. The updater log's last line:\n  %s\n" "${UPD_LOG_LAST:-(none)}"
      ;;
    *)
      code=1
      printf "No 'Installation completed successfully' within %s s, and the installed version did not change. The updater log's last line:\n  %s\n" "$timeout" "${UPD_LOG_LAST:-(none)}"
      ;;
  esac
  _update_history "$result" "$before" "$after" "${UPD_REOPENED}/${n_tags}"
  printf 'update before=%s after=%s result=%s reopened=%s/%s exit=%s\n' "$before" "$after" "$result" "$UPD_REOPENED" "$n_tags" "$code"

  # 10. Release the lock, then refresh the record (phase idle). On any other
  #     exit the EXIT trap does the same.
  _update_lock_release
  update_observe
  exit "$code"
}

# ---- reopen (#24) -----------------------------------------------------------
#
# reopen brings back every tag recorded as closed by the app's updater (see
# "Tags Claude closed on its own"), each on its own profile, through update's
# reopen (_update_reopen). It never opens a tag that is already running, and
# within a minute of a completed install whose request asked the updater to
# reopen the app (the flag is read now, and anything but false reads as
# true), primary is the helper's to reopen: reopen waits for it and never
# opens a second one. Like update's reopen, it skips the #6 account check:
# these tags ran on the same profile until the app closed them.
#
# It never reopens in bulk a tag closed for an unknown reason, which may
# have been closed on purpose: each is named with a launch command. Nor one
# that is neither in [accounts] nor on disk, which would open as a new,
# empty profile: named with launch --new.
#
# Exit codes:
#   0  every tag the updater closed is running again, or nothing to reopen
#   2  refused before anything was opened: the app not where detection
#      looks, update running, an install running, or an argument given
#   3  a tag did not reopen (named, and still recorded, so reopen offers it
#      again)
#   130  interrupted; each tag's record clears as it is counted, so the next
#      reopen opens only the rest
# History row: REOPEN tags=<tags> reopened=<n>/<m> missing=<tags>|none.

readonly REOPEN_RECENT_S=60

# _ot_csv <words>: a comma list, or none.
_ot_csv() {
  local w out=""
  for w in $1; do out="${out:+${out},}${w}"; done
  printf '%s' "${out:-none}"
}

cmd_reopen() {
  local arg tok tag seen found cause event t m=0 filtered="" unknown_tags="" code=0
  local lai="true" recent=0 since="" missing="" missing_csv
  for arg; do
    if [[ -n "$arg" ]]; then
      printf 'Usage: account-switcher reopen\n' >&2
      _update_refuse "reopen takes no arguments (got: ${arg})."
    fi
  done
  UPD_TAGS=""
  UPD_REOPENED=0
  UPD_MISSING=""

  # 1. The app must be where detection looks, before the process table is
  #    read or anything is written.
  app_binary_present || _update_refuse "$(app_binary_refusal "opened")"
  rotate_swap_log_if_needed

  # 2. A running update reopens what it closed.
  if _update_lock_held; then _update_refuse "$(_update_lock_refusal reopening)"; fi

  # 3. An observation, so a tag closed since the last one is offered too.
  open_tags_observe

  # 4. Never while the app's bundle may be being replaced.
  if _updater_log_scan "" && _updater_installing; then
    _update_refuse "The updater is installing right now; nothing was opened. Run account-switcher reopen again once account-switcher list shows the new version."
  fi

  # 5. The tags the updater closed, oldest found first; the others are named.
  if [[ $OT_LOADED -eq 0 ]]; then _open_tags_read; fi
  for tok in $OT_CLOSED; do
    IFS='|' read -r tag seen found cause event <<< "$tok"
    if [[ "$cause" != "updater" ]]; then
      unknown_tags="${unknown_tags} ${tag}"
      continue
    fi
    m=$((m + 1))
    if [[ "$tag" == "primary" ]] || tag_is_in_accounts "$tag" || [[ -d "$(udd_for_tag "$tag")" ]]; then
      UPD_TAGS="${UPD_TAGS:+${UPD_TAGS} }${tag}"
    else
      filtered="${filtered} ${tag}"
    fi
  done

  if [[ $m -eq 0 ]]; then
    printf "Nothing to reopen: no tag is recorded as closed by the app's updater.\n"
  else
    # 6. Right after an install, primary may be the helper's to reopen.
    _updater_flag
    if [[ "$UPD_FLAG" == "false" ]]; then lai="false"; fi
    if _open_tags_now; then since="$(_ot_local "$((OT_NOW_EP - REOPEN_RECENT_S))")" || since=""; fi
    if [[ -z "$since" ]]; then
      recent=1
    elif _updater_log_scan "$since" && [[ $UPD_LOG_DONE -gt 0 ]]; then
      recent=1
    fi

    # 7. The reopen.
    if [[ -n "$UPD_TAGS" ]]; then _update_reopen "$lai" "$recent" reopen; fi
    if [[ -n "$filtered" ]]; then
      printf 'Not reopened (not in [accounts] and no profile folder, so it would open as a new, empty profile):\n'
      for t in $filtered; do printf '  account-switcher launch %s --new\n' "$t"; done
    fi
    missing="${UPD_MISSING}${filtered}"
    if [[ -n "${missing// /}" ]]; then code=3; fi
  fi

  # 8. The tags closed for an unknown reason.
  if [[ -n "$unknown_tags" ]]; then
    printf 'Not reopened (closed, cause unknown; it may have been closed on purpose):\n'
    for t in $unknown_tags; do printf '  account-switcher launch %s\n' "$t"; done
  fi

  # 9. The history row.
  missing_csv="$(_ot_csv "$missing")"
  if [[ $m -gt 0 && -d "$STORE" ]]; then
    _swap_log_ensure
    printf '[%s] REOPEN tags=%s reopened=%s/%s missing=%s\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$(_ot_csv "${UPD_TAGS}${filtered}")" "$UPD_REOPENED" "$m" "$missing_csv" >> "$SWAP_LOG" || :
  fi

  # 10. The closing line.
  printf 'reopen reopened=%s/%s missing=%s unknown=%s exit=%s\n' \
    "$UPD_REOPENED" "$m" "$missing_csv" "$(_ot_csv "$unknown_tags")" "$code"
  exit "$code"
}

# ---- status --------------------------------------------------------------

cmd_status() {
  app_binary_warn
  printf '\n=== Claude Code Account Switcher (v%s) ===\n\n' "$VERSION"

  # CLI identity (what bridged Code reads from when displaying the account name).
  local active_email active_uuid
  active_email=$("$AS_BIN_JQ" -r '.oauthAccount.emailAddress // "(none)"' "${CLAUDE_JSON}" 2>/dev/null || echo "(error)")
  active_uuid=$("$AS_BIN_JQ" -r '.oauthAccount.accountUuid // "(none)"' "${CLAUDE_JSON}" 2>/dev/null || echo "(error)")

  printf 'CLI identity (from ~/.claude.json):\n'
  printf '  email:        %s\n' "$active_email"
  printf '  accountUuid:  %s\n' "$active_uuid"

  # Subscription type from keychain (single Claude Code-credentials entry,
  # shared across all CLI invocations regardless of which Mac app instance
  # spawned them).
  local kc_blob
  if kc_blob=$("$AS_BIN_SECURITY" find-generic-password -s "${KEYCHAIN_SVC}" -w 2>/dev/null); then
    local sub rate
    sub=$(printf '%s' "$kc_blob" | "$AS_BIN_JQ" -r '.claudeAiOauth.subscriptionType // "(unknown)"')
    rate=$(printf '%s' "$kc_blob" | "$AS_BIN_JQ" -r '.claudeAiOauth.rateLimitTier // "(unknown)"')
    printf '  subscription: %s (rate=%s)\n' "$sub" "$rate"
    unset kc_blob
  else
    printf '  subscription: (keychain unreadable)\n'
  fi

  local resolved_tag last_swap
  resolved_tag=$(resolve_tag_from_email "$active_email")
  last_swap=$("$AS_BIN_CAT" "$STATUSLINE_MARKER" 2>/dev/null || echo "(unset)")
  printf '  switcher tag: %s\n' "$resolved_tag"
  printf '  last swap target: %s\n\n' "$last_swap"

  printf 'For running Mac app instances and configured profile dirs:\n'
  printf '  account-switcher list\n\n'

  printf 'Subcommands: swap | launch | clone-prefs | quit | list | status | config | add-account | help\n'
}

# ---- config --------------------------------------------------------------

cmd_config() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      if [[ -f "$CONFIG_FILE" ]]; then
        "$AS_BIN_CAT" "$CONFIG_FILE"
      else
        warn "No config.toml exists yet at ${CONFIG_FILE}."
      fi
      ;;
    get)
      shift
      local key="${1:-}"
      [[ -z "$key" ]] && die "Usage: account-switcher config get <key>"
      toml_get "$key"
      ;;
    *)
      die "Unknown config subcommand: ${sub} (try: show, get)"
      ;;
  esac
}

# ---- add-account (H-1) ---------------------------------------------------

# Registers a tag → email mapping in [accounts] of the runtime config.toml.
# No code path writes to [accounts] implicitly; cmd_add_account is the
# explicit, minimal-surface registration subcommand for use after
# first-launch login. The TEMPLATE config.toml is intentionally left empty —
# operator-specific data only ever lives in the runtime instance.
cmd_add_account() {
  local tag="${1:-}"
  local email="${2:-}"
  local label="${3:-}"

  if [[ -z "$tag" ]] || [[ -z "$email" ]]; then
    "$AS_BIN_CAT" <<EOF >&2
Usage: account-switcher add-account <tag> <email> [label]

Registers a tag → email mapping in [accounts] of:
  ${CONFIG_FILE}

After first-launch login of the new tag's Mac app instance, run this so
that 'status' resolves CLI identity → switcher tag and any future tooling
that reads [accounts] sees the new account.

Examples:
  account-switcher add-account backup you@example.com
  account-switcher add-account work-acct work@example.com "Work (primary)"

The TEMPLATE config.toml.template remains empty by design — operator-specific
account metadata lives only in the runtime instance at
~/.claude/account-switcher/config.toml.
EOF
    return 1
  fi

  validate_tag "$tag"

  # Lightweight email format check (catches obvious typos; not RFC-compliant).
  # Refuses any whitespace, requires a '@' followed by something with a '.'.
  if [[ "$email" == *' '* ]] || [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    die "Invalid email format: '${email}' (expected user@host.tld)"
  fi

  # Default label = tag with first letter capitalized.
  if [[ -z "$label" ]]; then
    label="$(printf '%s' "${tag:0:1}" | "$AS_BIN_TR" '[:lower:]' '[:upper:]')${tag:1}"
  fi

  # Reject shell metacharacters in label (slash command surface guard, M-1 layered defence).
  if [[ "$label" == *'"'* ]] || [[ "$label" == *$'\n'* ]] || [[ "$label" == *$'\r'* ]]; then
    die "Label must not contain double-quotes or newlines (got: '${label}')."
  fi

  # Ensure config file exists with [accounts] section.
  if [[ ! -f "$CONFIG_FILE" ]]; then
    "$AS_BIN_INSTALL" -m 600 /dev/null "$CONFIG_FILE"
    printf '# ~/.claude/account-switcher/config.toml\n# Auto-generated on first add-account.\n\nversion = 1\n\n[accounts]\n' >> "$CONFIG_FILE"
  fi

  # Reject duplicate tag declaration. Manual edit is the path for updates
  # — silently overwriting could surprise operators or lose label history.
  if tag_is_in_accounts "$tag"; then
    die "Tag '${tag}' is already declared in [accounts] in ${CONFIG_FILE}. Edit manually to update."
  fi

  # Build new entry line. Quotes around the values are TOML-required for
  # strings — validate_tag and the email/label guards above ensure no
  # quote-escaping is needed.
  local new_entry
  new_entry=$(printf '%s = { label = "%s", profile_email = "%s" }' "$tag" "$label" "$email")

  # Insert new_entry within [accounts] section. Strategy: rewrite via awk,
  # appending new_entry just before the next section header (or EOF if
  # [accounts] is the last section). If [accounts] section is missing,
  # add it at the end of the file.
  local tmp
  tmp="$("$AS_BIN_MKTEMP")"
  "$AS_BIN_AWK" -v new_entry="$new_entry" '
    BEGIN { in_a = 0; inserted = 0; has_accounts = 0 }
    /^\[accounts\]/ { in_a = 1; has_accounts = 1; print; next }
    /^\[/ && in_a {
      # Leaving [accounts] section; insert new_entry before this header.
      if (!inserted) { print new_entry; inserted = 1 }
      in_a = 0
      print
      next
    }
    { print }
    END {
      # If file ends inside [accounts] without exiting, append new_entry.
      if (in_a && !inserted) { print new_entry; inserted = 1 }
      # If [accounts] section never seen, add it at end.
      if (!has_accounts) { print ""; print "[accounts]"; print new_entry }
    }
  ' "$CONFIG_FILE" > "$tmp"

  "$AS_BIN_MV" -f "$tmp" "$CONFIG_FILE"
  "$AS_BIN_CHMOD" 600 "$CONFIG_FILE"

  ok "Registered account: tag=${tag} email=${email} label='${label}'"

  _swap_log_ensure
  printf '[%s] ADD_ACCOUNT tag=%s email=%s label=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$email" "$label" \
    >> "$SWAP_LOG"
}

# ---- identity (#6) -------------------------------------------------------

_identity_usage() {
  "$AS_BIN_CAT" <<EOF >&2
Usage: account-switcher identity [<tag> | --all] [--show-ids]
       account-switcher identity pin <tag> [--yes] [--force]
EOF
}

# identity [<tag> | --all] [--show-ids]
# One row per tag in [accounts] (or the one tag named): the tag, its expected
# account (the configured label), the account its profile records, and
# match, MISMATCH or unknown. Read-only: it opens config.toml and each
# profile's config.json for reading and writes nothing, not even the
# history log (main answers it before log rotation). --show-ids adds the
# pinned and recorded ids, on stdout only, and only when stdout is a
# terminal; otherwise it refuses (exit 2) and prints nothing.
# Exit 0 = no MISMATCH (unknown rows do not fail), 1 = at least one MISMATCH,
# 2 = it cannot run: no config.toml, no tag in [accounts], a tag that is not
# in [accounts], or bad arguments. Empty arguments are skipped.
cmd_identity() {
  local want="" show_ids="false" arg tags t st label current mismatch=0 pinned recorded
  for arg; do
    case "$arg" in
      "") ;;
      --show-ids) show_ids="true" ;;
      --all)
        if [[ -n "$want" && "$want" != "--all" ]]; then _identity_usage; exit 2; fi
        want="--all"
        ;;
      -*) _identity_usage; _die2 "Unknown flag for identity: ${arg}" ;;
      *)
        if [[ -n "$want" ]]; then _identity_usage; exit 2; fi
        want="$arg"
        ;;
    esac
  done

  # S-02: whole ids go to a terminal only, never to a pipe, a file or a
  # transcript. Checked first, so this refusal can't be mistaken for another.
  if [[ "$show_ids" == "true" ]] && ! _stdout_tty; then
    _die2 "identity --show-ids prints whole account ids, so it runs only with its output on a terminal (not a pipe, a file or a transcript). Nothing was printed; without --show-ids, identity shows labels and the last 4 hex digits."
  fi
  app_binary_warn
  [[ -f "$CONFIG_FILE" ]] || _die2 "No config.toml at ${CONFIG_FILE}, so there is nothing to check. Register a tag with: account-switcher add-account <tag> <email>"
  tags="$(accounts_tags)" || tags=""
  [[ -n "$tags" ]] || _die2 "No tag in [accounts] of ${CONFIG_FILE}, so there is nothing to check."
  if [[ -n "$want" && "$want" != "--all" ]]; then
    [[ "$want" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || _die2 "Tag must match [a-z0-9-]{1,32} (got: '${want}')."
    tag_is_in_accounts "$(identity_key "$want")" || _die2 "Tag '${want}' is not in [accounts] of ${CONFIG_FILE}."
    tags="$want"
  fi

  if [[ "$show_ids" == "true" ]]; then
    printf '%-16s %-24s %-44s %-9s %-37s %s\n' TAG EXPECTED CURRENT STATUS PINNED RECORDED
  else
    printf '%-16s %-24s %-44s %s\n' TAG EXPECTED CURRENT STATUS
  fi
  # Tags are [a-z0-9-] only (accounts_tags), so splitting is exact.
  for t in $tags; do
    st="$(identity_status "$t")"
    label="$(account_label "$t")"
    current="$(identity_current_text "$st" "$label")"
    _ids_parse "$st"
    if [[ "$show_ids" == "true" ]]; then
      pinned="$(expected_account_uuid "$t")" || pinned="-"
      recorded="$(profile_account_uuid "$(udd_for_tag "$t")")" || recorded="-"
      printf '%-16s %-24s %-44s %-9s %-37s %s\n' "$t" "\"${label}\"" "$current" "$_IDS_STATUS" "$pinned" "$recorded"
    else
      printf '%-16s %-24s %-44s %s\n' "$t" "\"${label}\"" "$current" "$_IDS_STATUS"
    fi
    case "${_IDS_STATUS}/${_IDS_DETAIL}" in
      MISMATCH/*)
        mismatch=1
        printf "  fix: account-switcher signin %s; or in the '%s' window, sign out and sign back in as \"%s\"\n" "$t" "$t" "$label"
        ;;
      unknown/no-pin)
        printf '  no pin: run account-switcher identity pin %s\n' "$t"
        ;;
    esac
  done
  if [[ $mismatch -ne 0 ]]; then exit 1; fi
  return 0
}

# identity pin <tag> [--yes] [--force]
# Records the account <tag>'s profile holds now as the account <tag> must
# hold: one `<tag> = "<id>"` line in [identity] of config.toml, added to the
# table or replacing the tag's line there (the table is created when
# missing). Check the window's account menu first: the pin trusts what the
# profile records. Refuses with exit 2 when the tag is not in [accounts],
# when its account can't be read (unknown), or when the same account is
# already pinned to another tag, which is the mix-up #6 exists to catch,
# unless --force. Confirms with the label and the id's last 4 hex digits
# (--yes skips; a declined or unanswered prompt writes nothing and exits 1).
# Writes through a temp file, mv and chmod 600, passing the id to awk in the
# environment rather than on its command line, and appends
# IDENTITY_PIN tag=<tag> (no id) to the history log.
cmd_identity_pin() {
  local tag="" yes="false" force="false" arg key udd st label cur="" other="" old="" ans="" tmp
  for arg; do
    case "$arg" in
      "") ;;
      --yes) yes="true" ;;
      --force) force="true" ;;
      -*) _identity_usage; _die2 "Unknown flag for identity pin: ${arg}" ;;
      *)
        if [[ -n "$tag" ]]; then _identity_usage; _die2 "Unexpected arg: ${arg}"; fi
        tag="$arg"
        ;;
    esac
  done
  if [[ -z "$tag" ]]; then _identity_usage; exit 2; fi
  [[ "$tag" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || _die2 "Tag must match [a-z0-9-]{1,32} (got: '${tag}')."
  key="$(identity_key "$tag")"
  tag_is_in_accounts "$key" || _die2 "Tag '${tag}' is not in [accounts] of ${CONFIG_FILE}. Register it first: account-switcher add-account ${tag} <email>"

  udd="$(udd_for_tag "$tag")"
  st="$(identity_status "$tag")"
  _ids_parse "$st"
  if [[ "$_IDS_STATUS" == "unknown" && "$_IDS_DETAIL" != "no-pin" ]]; then
    _die2 "Can't pin '${tag}': its account is unknown ($(identity_current_text "$st" "")). Launch it, sign in, then pin it."
  fi
  cur="$(profile_account_uuid "$udd")" || _die2 "Can't pin '${tag}': its account can't be read."
  label="$(account_label "$tag")"

  other="$(pinned_tag_for_id "$cur" "$key")" || other=""
  if [[ -n "$other" && "$force" != "true" ]]; then
    _die2 "Can't pin '${tag}': its profile records the account already pinned to '${other}'. Two tags on one account is the mix-up this check exists to catch; sign '${tag}' in to its own account first. If the two tags really share one account, re-run with --force."
  fi
  old="$(expected_account_uuid "$key")" || old=""
  if [[ "$old" == "$cur" ]]; then
    ok "'${tag}' is already pinned to \"${label}\" (id …${cur:32:4}). Nothing to change."
    return 0
  fi
  if [[ -n "$other" ]]; then warn "The same account is pinned to '${other}' as well (--force)."; fi
  if [[ -n "$old" ]]; then info "This replaces the current pin (id …${old:32:4})."; fi

  if [[ "$yes" != "true" ]]; then
    printf 'Pin %s as "%s" (id …%s)? [y/N] ' "$tag" "$label" "${cur:32:4}" >&2
    IFS= read -r ans || ans=""
    case "$ans" in
      y|Y|yes|Yes|YES) ;;
      *) info "Not pinned."; exit 1 ;;
    esac
  fi

  tmp="$("$AS_BIN_MKTEMP")"
  if ! AS_PIN_KEY="$key" AS_PIN_LINE="${key} = \"${cur}\"" "$AS_BIN_AWK" '
    function blanks() { while (nb > 0) { print ""; nb-- } }
    BEGIN { k = ENVIRON["AS_PIN_KEY"]; line = ENVIRON["AS_PIN_LINE"]; in_t = 0; done = 0; seen = 0; nb = 0 }
    /^\[/ {
      if (in_t && !done) { print line; done = 1 }
      blanks()
      in_t = ($0 == "[identity]")
      if (in_t) seen = 1
      print
      next
    }
    in_t && index($0, k) == 1 && substr($0, length(k) + 1) ~ /^[[:space:]]*=/ {
      blanks()
      if (!done) { print line; done = 1 }
      next
    }
    in_t && /^[[:space:]]*$/ { nb++; next }
    { blanks(); print }
    END {
      if (in_t && !done) { print line; done = 1 }
      blanks()
      if (!seen) { print ""; print "[identity]"; print line }
    }' "$CONFIG_FILE" > "$tmp"; then
    "$AS_BIN_RM" -f "$tmp"
    _die2 "Could not write the pin; ${CONFIG_FILE} is unchanged."
  fi
  "$AS_BIN_MV" -f "$tmp" "$CONFIG_FILE"
  "$AS_BIN_CHMOD" 600 "$CONFIG_FILE"

  _swap_log_ensure
  printf '[%s] IDENTITY_PIN tag=%s\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$key" >> "$SWAP_LOG"
  ok "Pinned '${tag}' to \"${label}\" (id …${cur:32:4}) in ${CONFIG_FILE}."
}

# ---- signin (#7) -----------------------------------------------------------
#
# signin <tag> signs one tag in and, by default, leaves every other Claude
# instance running. Before the sign-in it records each profile's identity
# state; afterwards it compares them again, so a login callback delivered to
# another open instance is detected after the fact (it is not prevented).
# With --quit-others it quits every instance first (listed, then confirmed)
# and signs in with only the target running.
#
# Exit codes, with precedence 4 > 1 > 3 > 0:
#   0  the target reads match and every other profile is unchanged
#   1  the target reads MISMATCH (and no other profile changed)
#   2  refused before anything was opened or quit (also every argument error)
#   3  the target reads unknown (no pin, not seen in time, exited, stopped)
#   4  another profile changed, or could not be re-checked, or an instance
#      ran on a profile signin can't determine
# No other path exits 1: signin checks its own arguments before the shared
# check in main (whose die exits 1), and an EXIT trap set at entry turns
# any exit that did not come through _signin_exit into 2 before anything
# was opened, or into the final check (result unknown, detail aborted)
# after.
#
# The identity snapshot: a state word (nofolder, nofile, unreadable, absent,
# present) and, for present, a SHA-256 digest of the identity value prefixed
# with a random salt made for this run. jq writes the value into a pipe that
# shasum reads, so the value never reaches a shell variable, an argument
# list, a file or a log row in snapshot_read; only the digest comes back, and
# the digest and salt are never printed, logged, written, exported or passed
# as an argument. History rows carry tags, status words and counts only.

readonly SIGNIN_POLL_S=2
readonly SIGNIN_TIMEOUT_DEFAULT=300
readonly SIGNIN_SETTLE_DEFAULT=20

# The marker jq writes for one profile, no trailing newline: "A" when the key
# is absent or null; "P" + the value for a string (lowercased); "J" + its JSON
# text for any other value, so the number 1 and the string "1" differ. A top
# level that is not one object (null included) is an error, so it reads
# unreadable. -n input makes an empty file an error rather than no output.
# shellcheck disable=SC2016
readonly SNAP_JQ='if type != "object" then error("shape")
  else .lastKnownAccountUuid as $v
    | if $v == null then "A"
      elif ($v | type) == "string" then "P" + ($v | ascii_downcase)
      else "J" + ($v | tojson) end
  end'

SIGNIN_FINAL=0
SIGNIN_PHASE="none"
SIGNIN_POST_STARTED=0
SIGNIN_QUIT_ROW=0
SG_CONFIRMED_TAGS=""
SNAP_SALT=""
SNAP_D_ABSENT=""

_signin_usage() {
  "$AS_BIN_CAT" <<EOF >&2
Usage: account-switcher signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]
       (login is the same command)
  --quit-others  quit every Claude instance first (listed, then confirmed),
                 and sign in with only the target running
  --yes          answer the confirmations: the --quit-others list, and going
                 on with a profile or an instance signin can't check
  --timeout <s>  how long to wait for the sign-in: 30-1800 seconds (default ${SIGNIN_TIMEOUT_DEFAULT})
  --settle <s>   how long to keep watching the other instances once the
                 sign-in is seen: 0-120 seconds (default ${SIGNIN_SETTLE_DEFAULT})
  --new          allow a tag that is not in [accounts]
EOF
}

# Every intended signin exit goes through here, so the EXIT trap can tell an
# intended exit from an unexpected one.
_signin_exit() { SIGNIN_FINAL=1; exit "$1"; }

# A refusal: one error line, exit 2.
_signin_refuse() {
  printf '\033[31mERROR:\033[0m %s\n' "$*" >&2
  _signin_exit 2
}

# Returns 0 when stdin counts as a terminal. AS_TEST_STDIN_IS_TTY is empty
# outside test mode (the seam block unsets it), so production reads -t 0.
_signin_tty() {
  if [[ "${AS_TEST_MODE:-0}" == "1" && -n "$AS_TEST_STDIN_IS_TTY" ]]; then
    [[ "$AS_TEST_STDIN_IS_TTY" == "1" ]]
    return
  fi
  [[ -t 0 ]]
}

# Returns 0 when stdout counts as a terminal (S-02, identity --show-ids).
# AS_TEST_STDOUT_IS_TTY is empty outside test mode (the seam block unsets
# it), so production reads -t 1.
_stdout_tty() {
  if [[ "${AS_TEST_MODE:-0}" == "1" && -n "$AS_TEST_STDOUT_IS_TTY" ]]; then
    [[ "$AS_TEST_STDOUT_IS_TTY" == "1" ]]
    return
  fi
  [[ -t 1 ]]
}

# _signin_ask <question>: prints it and reads one line; returns 0 only for a
# typed y or yes.
_signin_ask() {
  local ans=""
  printf '%s [y/N] ' "$1"
  IFS= read -r ans || ans=""
  case "$ans" in
    y|Y|yes|Yes|YES) return 0 ;;
  esac
  return 1
}

# Reads and discards whatever is waiting on stdin, so a key pressed before a
# question was asked can never answer it.
_signin_drain() {
  local junk=""
  while IFS= read -r -t 1 junk; do :; done
  junk=""
  return 0
}

# _account_email <tag>: the profile_email of the tag's [accounts] entry, or
# nothing. It is printed on stdout only, never written to a log row.
_account_email() {
  local key e=""
  key="$(identity_key "${1:-}")"
  if [[ -f "$CONFIG_FILE" ]]; then
    e="$("$AS_BIN_AWK" -v tag="$key" '
      /^\[/ { in_a = ($0 ~ /^\[accounts\]/); next }
      in_a && $0 ~ "^"tag"[[:space:]]*=" {
        if (match($0, /profile_email[[:space:]]*=[[:space:]]*"[^"]*"/)) {
          v = substr($0, RSTART, RLENGTH)
          sub(/^profile_email[[:space:]]*=[[:space:]]*"/, "", v); sub(/"$/, "", v)
          print v
        }
        exit
      }' "$CONFIG_FILE")" || e=""
  fi
  printf '%s' "$e"
}

# Sets SNAP_SALT (16 random bytes as hex) and SNAP_D_ABSENT (the digest an
# absent or null key reads as). Neither is a secret: the salt only makes this
# run's digests meaningless outside it. Neither is ever printed or exported.
_snap_init() {
  SNAP_SALT="$("$AS_BIN_OD" -An -N16 -tx1 /dev/urandom | "$AS_BIN_TR" -d ' \n')"
  [[ "$SNAP_SALT" =~ ^[0-9a-f]{32}$ ]] || return 1
  SNAP_D_ABSENT="$(printf '%s:A' "$SNAP_SALT" | "$AS_BIN_SHASUM" -a 256 | "$AS_BIN_AWK" '{print $1}')"
  [[ "$SNAP_D_ABSENT" =~ ^[0-9a-f]{64}$ ]] || return 1
  return 0
}

# snapshot_read <user-data-dir> <state-var> <digest-var>
# Sets <state-var> to nofolder, nofile, unreadable, absent or present, and
# <digest-var> to the salted digest when present ("" otherwise). Both names
# must be plain scalar names (printf -v cannot write an array element on
# bash 3.2; the caller copies the results into its arrays), and neither may
# start with _sr_, the prefix of this function's own locals, which a caller's
# name would otherwise shadow, leaving the caller's variable unwritten. A
# refused name returns 2 and writes nothing. A file that does not parse on
# three reads, a second apart, reads unreadable. The value itself only
# travels from jq to shasum through a pipe.
snapshot_read() {
  local _sr_dir="${1:-}" _sr_f="" _sr_d="" _sr_try=1 _sr_re='^[A-Za-z_][A-Za-z0-9_]*$'
  if [[ ! "${2:-}" =~ $_sr_re || ! "${3:-}" =~ $_sr_re || "${2:-}" == _sr_* || "${3:-}" == _sr_* ]]; then
    printf '\033[31mERROR:\033[0m snapshot_read: out-parameters must be scalar names not starting _sr_ (got %s %s)\n' "${2:-}" "${3:-}" >&2
    return 2
  fi
  printf -v "$2" '%s' unreadable
  printf -v "$3" '%s' ''
  if [[ ! -d "$_sr_dir" ]]; then printf -v "$2" '%s' nofolder; return 0; fi
  _sr_f="${_sr_dir}/config.json"
  if [[ ! -e "$_sr_f" ]]; then printf -v "$2" '%s' nofile; return 0; fi
  while [[ $_sr_try -le 3 ]]; do
    if _sr_d="$( { printf '%s:' "$SNAP_SALT"; "$AS_BIN_JQ" -j -n "input | ${SNAP_JQ}" "$_sr_f" 2> /dev/null; } \
          | "$AS_BIN_SHASUM" -a 256 | "$AS_BIN_AWK" '{print $1}' )" && [[ "$_sr_d" =~ ^[0-9a-f]{64}$ ]]; then
      if [[ "$_sr_d" == "$SNAP_D_ABSENT" ]]; then
        printf -v "$2" '%s' absent
      else
        printf -v "$2" '%s' present
        printf -v "$3" '%s' "$_sr_d"
      fi
      _sr_d=""
      return 0
    fi
    _sr_d=""
    # The app rewrites config.json while it runs; a retry covers a torn read.
    # These retries never advance signin's poll count.
    if [[ $_sr_try -lt 3 ]]; then "$AS_BIN_SLEEP" 1; fi
    _sr_try=$((_sr_try + 1))
  done
  return 0
}

# _snap_now <user-data-dir>: snapshot_read into SG_ST and SG_DG, which read
# unreadable and "" unless the read sets them.
_snap_now() {
  SG_ST="unreadable"
  SG_DG=""
  snapshot_read "$1" SG_ST SG_DG
}

# _snap_compare_idx <i>: sets SG_V to unchanged, changed or unverified for
# the other profile at index <i>, its before-state against the read now in
# SG_ST and SG_DG. nofolder, nofile and absent all mean "no recorded
# account"; unreadable on either side can't be compared. The digests are
# compared in [[ ]] only, never passed as an argument.
_snap_compare_idx() {
  local b="${SNAP_STATE0[$1]}"
  if [[ "$b" == "unreadable" || "$SG_ST" == "unreadable" ]]; then SG_V="unverified"; return 0; fi
  if [[ "$b" == "present" && "$SG_ST" == "present" ]]; then
    if [[ "${SNAP_DIGEST0[$1]}" == "$SG_DG" ]]; then SG_V="unchanged"; else SG_V="changed"; fi
    return 0
  fi
  if [[ "$b" == "present" || "$SG_ST" == "present" ]]; then SG_V="changed"; return 0; fi
  SG_V="unchanged"
}

# Prints the tag of each profile folder under the profile root, one per line:
# primary for Claude, <t> for Claude-<t> when <t> is a tag the matcher can
# name (never primary or default, which no Claude-<t> folder stands for).
_signin_profile_tags() {
  local d t
  if [[ -d "${AS_PROFILE_ROOT}/Claude" ]]; then printf 'primary\n'; fi
  for d in "${AS_PROFILE_ROOT}/Claude-"*; do
    [[ -d "$d" ]] || continue
    t="${d#"${AS_PROFILE_ROOT}/Claude-"}"
    if [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$t" != "primary" && "$t" != "default" ]]; then
      printf '%s\n' "$t"
    fi
  done
}

# _snap_index <tag>: the index of <tag> in SNAP_TAG, or nothing.
_snap_index() {
  local i=0
  while [[ $i -lt ${#SNAP_TAG[*]} ]]; do
    if [[ "${SNAP_TAG[$i]}" == "$1" ]]; then printf '%s' "$i"; return 0; fi
    i=$((i + 1))
  done
  return 0
}

# _snap_add <tag> [nofolder]: adds <tag> to the snapshot set with the read
# now in SG_ST and SG_DG as its before-state, or with "no folder before".
_snap_add() {
  SNAP_TAG+=("$1")
  if [[ "${2:-}" == "nofolder" ]]; then
    SNAP_STATE0+=("nofolder")
    SNAP_DIGEST0+=("")
  else
    SNAP_STATE0+=("$SG_ST")
    SNAP_DIGEST0+=("$SG_DG")
  fi
  SNAP_VERDICT+=("unchanged")
}

# Adds every profile folder that is not in the snapshot set yet, and every
# tag in $1 (tags of running instances), as "no folder before": a folder
# that appears during the run, or an instance whose folder does not exist,
# is still compared at the end.
_snap_extend() {
  local t tags
  tags="$(_signin_profile_tags) ${1:-}"
  # Tags are [a-z0-9-] only, so splitting is exact.
  for t in $tags; do
    if [[ "$t" == "$SG_TAG" || "$t" == "unknown" ]]; then continue; fi
    if [[ -n "$(_snap_index "$t")" ]]; then continue; fi
    _snap_add "$t" nofolder
  done
}

# _signin_scan: one process-table read through the exact matcher (#9; argv[0]
# must be the app binary, so a pager or grep whose arguments mention it is
# never an instance). SG_ROWS: claude_instances rows (pid, profile, method).
# SG_RAW_FLAGLESS: the PIDs the matcher's raw class marks FLAGLESS (no
# --user-data-dir), padded with spaces. Returns 1 when ps can't be read.
_signin_scan() {
  local st=0 raw="" pid kind method
  SG_ROWS=""
  SG_RAW_FLAGLESS=" "
  SG_ROWS="$(claude_instances)" || st=$?
  [[ $st -eq 0 ]] || return 1
  raw="$(_claude_main_rows)" || return 1
  while IFS=$'\t' read -r pid kind method; do
    if [[ -n "$pid" && "$kind" == "FLAGLESS" ]]; then SG_RAW_FLAGLESS="${SG_RAW_FLAGLESS}${pid} "; fi
  done <<< "$raw"
  return 0
}

# Writes the QUIT_ALL row (cmd_quit's format) once.
_signin_quit_row() {
  if [[ "$SIGNIN_QUIT_ROW" == "1" ]]; then return 0; fi
  SIGNIN_QUIT_ROW=1
  if [[ -d "$STORE" ]]; then
    _swap_log_ensure
    printf '[%s] QUIT_ALL tags=%s by=signin\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "${SG_CONFIRMED_TAGS:-none}" >> "$SWAP_LOG" || :
  fi
}

# _signin_quit_report [<lead>]: after an interrupt, an unexpected stop, or a
# quit stopped by an instance that wasn't listed, during --quit-others' quit:
# what was listed, what of it was closed, and what is still running. Nothing
# was opened yet. <lead> defaults to the interrupt's wording.
_signin_quit_report() {
  local lead="${1:-Interrupted while quitting.}" now closed="" p
  now="$(get_claude_pids)"
  now="${now//$'\n'/ }"
  for p in $SG_CONFIRMED; do
    case " ${now} " in *" ${p} "*) ;; *) closed="${closed} ${p}" ;; esac
  done
  closed="${closed# }"
  printf '%s Listed before the quit: PIDs%s. Closed: %s. Still running: %s. Nothing was signed in.\n' \
    "$lead" "${SG_CONFIRMED% }" "${closed:-none}" "${now:-none}"
}

# The EXIT trap, set at signin's entry. An exit that came through
# _signin_exit keeps its status. Any other exit (a failed command under set
# -e, a die in a helper) is never allowed to read as exit 1: before anything
# was opened or quit it becomes 2; during the quit, 2 with the QUIT_ALL row;
# after the target was opened or adopted, the final check runs once with
# result unknown, detail aborted.
_signin_on_exit() {
  local rc=$?
  if [[ "$SIGNIN_FINAL" == "1" ]]; then exit "$rc"; fi
  SIGNIN_FINAL=1
  set +e
  trap '' INT TERM
  case "$SIGNIN_PHASE" in
    open|wait|settle)
      printf '\033[33mWARN:\033[0m signin stopped unexpectedly (status %s); checking every profile before it reports.\n' "$rc" >&2
      _signin_finish aborted
      ;;
    post)
      printf "\033[31mERROR:\033[0m signin's final check did not finish (status %s), so no profile is confirmed unchanged. Run: account-switcher identity --all\n" "$rc" >&2
      exit 4
      ;;
    quit|quitdone)
      _signin_quit_row
      printf '\033[31mERROR:\033[0m signin stopped during --quit-others (status %s); nothing was opened or signed in.\n' "$rc" >&2
      exit 2
      ;;
    *)
      printf '\033[31mERROR:\033[0m signin stopped before anything was opened or quit (status %s).\n' "$rc" >&2
      exit 2
      ;;
  esac
  exit 4
}

# The INT/TERM trap, phase-aware: before any quit or open, exit 2; during
# --quit-others' quit, the QUIT_ALL row, what was quit, exit 2; after the
# target was opened or adopted, the final check (result unknown, detail
# aborted), which still reports exit 4 when another profile changed. During
# the final check itself INT and TERM are ignored.
_signin_on_signal() {
  trap '' INT TERM
  printf '\n'
  case "$SIGNIN_PHASE" in
    post) return 0 ;;
    open|wait|settle)
      printf 'Stopping (interrupted); checking every profile before reporting.\n'
      _signin_finish aborted
      ;;
    quit|quitdone)
      _signin_quit_row
      _signin_quit_report
      _signin_exit 2
      ;;
    *)
      printf 'Stopped (interrupted) before anything was opened or quit.\n'
      _signin_exit 2
      ;;
  esac
}

# The new-instance watch for one scan (SG_ROWS). A PID counts as a new
# primary when it was in neither the pre-sign-in primary set (raw FLAGLESS,
# or resolved primary or unknown) nor is the target, and its raw class is
# FLAGLESS or its resolved profile is primary or unknown. Each new PID is
# reported once. In wait mode it also tracks the target: its PID present,
# or another row on its profile (the app restarted itself: follow it), or a
# miss; two misses in a row stop the wait (target-exited).
_signin_watch() {
  local mode="$1" pid profile method seen_target=0 same="" np new tags_now=""
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    if [[ "$profile" != "unknown" ]]; then tags_now="${tags_now} ${profile}"; fi
    if [[ "$pid" == "$TARGET_PID" ]]; then seen_target=1; continue; fi
    # Another process on the target's own profile is the target restarting.
    if [[ "$profile" == "$SG_TAG" ]]; then same="${same} ${pid}"; continue; fi
    if [[ "$SG_SEEN" == *" ${pid} "* ]]; then continue; fi
    np=0
    new=0
    if [[ "$SG_PRE_PRIMARY" != *" ${pid} "* ]] && \
       [[ "$SG_RAW_FLAGLESS" == *" ${pid} "* || "$profile" == "primary" || "$profile" == "unknown" ]]; then
      np=1
    fi
    if [[ "$SG_PRE_ALL" != *" ${pid} "* ]]; then new=1; fi
    if [[ $np -eq 0 && $new -eq 0 ]]; then continue; fi
    SG_SEEN="${SG_SEEN}${pid} "
    if [[ "$SG_MODE" == "quit-others" ]]; then
      printf "\033[33mWARN:\033[0m another Claude instance started during sign-in (%s · PID %s); the one-instance guarantee no longer holds.\n" "$profile" "$pid" >&2
    fi
    if [[ "$profile" == "unknown" ]]; then
      SG_UNKNOWN_PIDS="${SG_UNKNOWN_PIDS}${pid} "
      printf "\033[33mWARN:\033[0m an instance started during sign-in (PID %s) whose profile signin can't determine; it may be primary, and the result will be UNVERIFIED.\n" "$pid" >&2
    elif [[ $np -eq 1 && "$SG_MODE" != "quit-others" ]]; then
      printf '\033[33mWARN:\033[0m a primary instance started during sign-in (PID %s); the login may land in primary. Watching its identity.\n' "$pid" >&2
    fi
  done <<< "$SG_ROWS"
  _snap_extend "$tags_now"

  if [[ "$mode" != "wait" ]]; then return 0; fi
  if [[ $seen_target -eq 1 ]]; then
    SG_MISSES=0
    if [[ "$SG_TAG" == "primary" && -n "$same" && "$SG_TWO_PRIMARY_WARNED" == "0" ]]; then
      SG_TWO_PRIMARY_WARNED=1
      printf '\033[33mWARN:\033[0m two primary instances are running (PIDs %s,%s); they share one profile, and the final check decides.\n' "$TARGET_PID" "${same// /, }" >&2
    fi
    return 0
  fi
  if [[ -n "$same" ]]; then
    TARGET_PID="${same# }"
    TARGET_PID="${TARGET_PID%% *}"
    SG_MISSES=0
    printf "The '%s' instance restarted; following the restarted instance (PID %s).\n" "$SG_TAG" "$TARGET_PID"
    return 0
  fi
  SG_MISSES=$((SG_MISSES + 1))
  if [[ $SG_MISSES -ge 2 ]]; then SG_STOP="target-exited"; fi
  return 0
}

# Compares every other profile with its before-state. The first changed one
# stops the wait (or the settle window) at once; an unreadable read does not
# (it may be a torn write) and is settled by the final check.
_signin_compare_others() {
  local i=0
  while [[ $i -lt ${#SNAP_TAG[*]} ]]; do
    _snap_now "$(udd_for_tag "${SNAP_TAG[$i]}")"
    _snap_compare_idx "$i"
    SG_DG=""
    if [[ "$SG_V" == "changed" ]]; then
      SG_STOP="other-changed"
      printf "Stopping: profile '%s' changed (see below).\n" "${SNAP_TAG[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

# One poll (wait or settle). The test hook, when set, runs first, once per
# poll; time is counted in polls (poll count x 2 s), so snapshot_read's
# retry sleeps never advance it.
_signin_poll() {
  local mode="$1"
  SG_POLL=$((SG_POLL + 1))
  if [[ -n "$AS_TEST_POLL_HOOK" ]]; then "$AS_TEST_POLL_HOOK" "$SG_POLL" || :; fi
  # A process table that can't be read tells nothing this poll (not a miss).
  if _signin_scan; then _signin_watch "$mode"; fi
  if [[ -n "$SG_STOP" ]]; then return 0; fi
  if [[ "$mode" == "wait" ]]; then
    _snap_now "$SG_UDD"
    if [[ "$SG_ST" == "present" && ( "$SG_TSTATE0" != "present" || "$SG_DG" != "$SG_TDIGEST0" ) ]]; then
      SG_COMPLETE="changed"
    fi
    SG_DG=""
  fi
  _signin_compare_others
  return 0
}

# The timer between polls. At a terminal, `read -t 2` is the interval and an
# answer of y completes the sign-in. What happened is decided by the time
# the read took, not its status: on bash 3.2 a timeout returns 1, the same as
# end of input. A read that returns non-zero in under 2 s is end of input,
# so signin stops reading and sleeps from then on.
_signin_timer() {
  local s r el ans=""
  if [[ "$SG_READING" != "1" ]]; then
    "$AS_BIN_SLEEP" "$SIGNIN_POLL_S"
    return 0
  fi
  s=$SECONDS
  if IFS= read -r -t "$SIGNIN_POLL_S" ans; then r=0; else r=$?; fi
  el=$((SECONDS - s))
  if [[ $r -eq 0 ]]; then
    case "$ans" in
      y|Y|yes|Yes|YES) SG_COMPLETE="${SG_COMPLETE:-unchanged}" ;;
      *) printf '%s [y/N] ' "$SG_QUESTION" ;;
    esac
    return 0
  fi
  if [[ $el -ge $SIGNIN_POLL_S ]]; then return 0; fi
  SG_READING=0
  printf '\nInput ended, so signin no longer reads an answer; it finishes when the profile records an account, or after the timeout.\n'
  return 0
}

# _signin_other_status <tag>: identity_status rendered by D-a4's label rule.
_signin_other_status() {
  local st
  st="$(identity_status "$1")"
  _ids_parse "$st"
  case "${_IDS_STATUS}/${_IDS_DETAIL}" in
    match/*)               printf '"%s" (match)' "$(account_label "$1")" ;;
    MISMATCH/other-tag)    printf "%s's account (MISMATCH)" "$_IDS_VALUE" ;;
    MISMATCH/*)            printf 'an unrecognized account (MISMATCH)' ;;
    *)                     printf 'unknown (%s)' "$(identity_current_text "$st" "")" ;;
  esac
}

# The final check: re-reads every profile (an unreadable read gets three
# more reads, 2 s apart), runs #6's identity_status on the target, prints
# the target line, the pin offer or the next step, a MISMATCH or UNVERIFIED
# block for each other profile that changed or could not be re-checked, the
# history rows, and the summary line last. Then exits 4, 1, 3 or 0. Runs
# once (from the end of the wait, an interrupt or the EXIT trap).
_signin_finish() {
  local why="${1:-}" i v t st label current result detail recorded="none" cur="" other_pin=""
  local changed=0 unverified=0 code=0 tries ts p n_unknown=0 note=""
  if [[ "$SIGNIN_POST_STARTED" == "1" ]]; then return 0; fi
  SIGNIN_POST_STARTED=1
  SIGNIN_PHASE="post"
  trap '' INT TERM
  set +e
  if [[ "$why" == "aborted" ]]; then SG_STOP="aborted"; fi

  # 1. Final reads of every other profile, new folders included.
  _snap_extend ""
  i=0
  while [[ $i -lt ${#SNAP_TAG[*]} ]]; do
    _snap_now "$(udd_for_tag "${SNAP_TAG[$i]}")"
    tries=0
    while [[ "$SG_ST" == "unreadable" && $tries -lt 3 ]]; do
      "$AS_BIN_SLEEP" "$SIGNIN_POLL_S"
      _snap_now "$(udd_for_tag "${SNAP_TAG[$i]}")"
      tries=$((tries + 1))
    done
    _snap_compare_idx "$i"
    SG_DG=""
    v="$SG_V"
    SNAP_VERDICT[$i]="$v"
    if [[ "$v" == "changed" ]]; then changed=$((changed + 1)); fi
    if [[ "$v" == "unverified" ]]; then unverified=$((unverified + 1)); fi
    i=$((i + 1))
  done
  for p in $SG_UNKNOWN_PIDS; do n_unknown=$((n_unknown + 1)); done
  unverified=$((unverified + n_unknown))

  # 2. The target, through #6 (always returns 0; the result is on stdout).
  st="$(identity_status "$SG_TAG")"
  _ids_parse "$st"
  label="$(account_label "$SG_TAG")"
  current="$(identity_current_text "$st" "$label")"
  case "${_IDS_STATUS}/${_IDS_DETAIL}" in
    match/*)               recorded="$SG_TAG" ;;
    MISMATCH/other-tag)    recorded="$_IDS_VALUE" ;;
    MISMATCH/*)            recorded="unrecognized" ;;
    unknown/no-pin)
      cur="$(profile_account_uuid "$SG_UDD")" || cur=""
      if [[ -n "$cur" ]]; then other_pin="$(pinned_tag_for_id "$cur" "$SG_TAG")"; fi
      cur=""
      if [[ -n "$other_pin" ]]; then recorded="$other_pin"; else recorded="unrecognized"; fi
      ;;
    unknown/unreadable|unknown/bad-id) recorded="unrecognized" ;;
    *)                     recorded="none" ;;
  esac

  # The result word. A sign-in that was seen (the key appeared or changed, or
  # the operator answered y) is judged by #6. A stop before that (aborted,
  # target-exited, other-changed, timeout) is MISMATCH when #6 says so, and
  # otherwise unknown with the stop as its detail: never match. An abort is
  # never match either, even after the sign-in was seen.
  if [[ -n "$SG_COMPLETE" && "$SG_STOP" != "aborted" ]]; then
    result="$_IDS_STATUS"
    detail="$SG_COMPLETE"
    if [[ "$result" == "unknown" ]]; then
      case "$_IDS_DETAIL" in
        no-pin) detail="unpinned" ;;
        unreadable|bad-id) detail="unreadable" ;;
      esac
    fi
  else
    if [[ "$_IDS_STATUS" == "MISMATCH" ]]; then result="MISMATCH"; else result="unknown"; fi
    detail="${SG_STOP:-aborted}"
  fi

  printf '\n'
  case "$result" in
    match)
      if [[ "$detail" == "unchanged" ]]; then
        printf "✓ '%s' is recorded as \"%s\" (match; the recorded account did not change, so signin could not see the sign-in itself).\n" "$SG_TAG" "$label"
      else
        printf "✓ '%s' is signed into \"%s\" (match).\n" "$SG_TAG" "$label"
      fi
      ;;
    MISMATCH)
      printf "✗ '%s' is recorded as %s, not \"%s\" (MISMATCH). In the '%s' window, sign out, then run: account-switcher signin %s\n" \
        "$SG_TAG" "$current" "$label" "$SG_TAG" "$SG_TAG"
      ;;
    *)
      case "$detail" in
        aborted)       note="signin was stopped before the sign-in was confirmed" ;;
        target-exited) note="the instance exited before sign-in finished" ;;
        other-changed) note="the wait stopped because another profile changed" ;;
        timeout)       note="sign-in not seen within ${SG_TIMEOUT}s" ;;
        unreadable)    note="its identity can't be read" ;;
        unpinned)      note="no pin" ;;
        *)             note="no account is recorded, so signin can't confirm the sign-in" ;;
      esac
      printf "? '%s': %s (unknown).\n" "$SG_TAG" "$note"
      if [[ -n "$other_pin" ]]; then printf "  It is recorded as %s's account.\n" "$other_pin"; fi
      if [[ "$detail" == "unpinned" ]]; then _signin_pin_step "$other_pin" "$changed" "$unverified"; fi
      ;;
  esac

  # 3. Every other profile that changed, or could not be re-checked.
  i=0
  while [[ $i -lt ${#SNAP_TAG[*]} ]]; do
    t="${SNAP_TAG[$i]}"
    case "${SNAP_VERDICT[$i]}" in
      changed)
        if [[ "${SNAP_STATE0[$i]}" == "present" ]]; then v="had a recorded account"; else v="had no recorded account"; fi
        {
          printf "\033[31mMISMATCH:\033[0m profile '%s' changed during this sign-in. Before: %s. Now: %s.\n" "$t" "$v" "$(_signin_other_status "$t")"
          printf "  The '%s' sign-in may have been delivered to the '%s' instance.\n" "$SG_TAG" "$t"
          printf "  Don't use the '%s' window for work until this is resolved.\n" "$t"
          printf '  Recovery:\n'
          printf '    1. account-switcher identity %s        (shows whether it still matches its pin)\n' "$t"
          printf "    2. If it isn't match: sign out in the '%s' window, then\n" "$t"
          printf '       account-switcher signin %s --quit-others\n' "$t"
          printf "    3. Sign '%s' in again with nothing else open:\n" "$SG_TAG"
          printf '       account-switcher signin %s --quit-others\n' "$SG_TAG"
          printf "  If you signed in '%s' yourself during this run, step 1 confirms it and nothing else is needed.\n" "$t"
        } >&2
        ;;
      unverified)
        {
          printf "\033[31mUNVERIFIED:\033[0m profile '%s' could not be re-checked (its identity can't be read). signin can't confirm it is unchanged.\n" "$t"
          printf "  Recovery: account-switcher identity %s; if it isn't match, sign it in again with --quit-others.\n" "$t"
        } >&2
        ;;
    esac
    i=$((i + 1))
  done
  for p in $SG_UNKNOWN_PIDS; do
    {
      printf "\033[31mUNVERIFIED:\033[0m an instance (PID %s) runs on a profile signin can't check, so signin can't confirm the sign-in did not land there.\n" "$p"
      printf "  Recovery: account-switcher list; account-switcher identity --all; sign any tag that isn't match in again with --quit-others.\n"
    } >&2
  done

  # 4. Exit code: 4 > 1 > 3 > 0.
  if [[ $((changed + unverified)) -gt 0 ]]; then code=4
  elif [[ "$result" == "MISMATCH" ]]; then code=1
  elif [[ "$result" == "unknown" ]]; then code=3
  else code=0
  fi

  # 5. History rows, in one block: tags, words and counts only.
  if [[ -d "$STORE" ]]; then
    ts="$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)"
    _swap_log_ensure
    {
      printf '[%s] SIGNIN tag=%s mode=%s result=%s detail=%s others_changed=%s others_unverified=%s\n' \
        "$ts" "$SG_TAG" "$SG_MODE" "$result" "$detail" "$changed" "$unverified"
      printf '[%s] IDENTITY tag=%s status=%s\n' "$ts" "$SG_TAG" "$_IDS_STATUS"
      i=0
      while [[ $i -lt ${#SNAP_TAG[*]} ]]; do
        case "${SNAP_VERDICT[$i]}" in
          changed|unverified)
            printf '[%s] SIGNIN_OTHER tag=%s change=%s during=%s\n' "$ts" "${SNAP_TAG[$i]}" "${SNAP_VERDICT[$i]}" "$SG_TAG" ;;
        esac
        i=$((i + 1))
      done
      for p in $SG_UNKNOWN_PIDS; do
        printf '[%s] SIGNIN_OTHER tag=unknown change=unverified during=%s\n' "$ts" "$SG_TAG"
      done
    } >> "$SWAP_LOG"
  fi

  # 6. The summary line, always last on stdout.
  printf 'signin tag=%s mode=%s result=%s detail=%s recorded_as=%s others_checked=%s others_changed=%s others_unverified=%s exit=%s\n' \
    "$SG_TAG" "$SG_MODE" "$result" "$detail" "$recorded" "${#SNAP_TAG[*]}" "$changed" "$unverified" "$code"
  _signin_exit "$code"
}

# _signin_pin_step <pinned-to-other-tag> <changed> <unverified>: after an
# unpinned sign-in, offers the pin only where `identity pin` can succeed (the
# tag is in [accounts], and its new account is not pinned to another tag),
# at a terminal, with nothing else changed; it asks after draining input,
# and --yes never answers it. Otherwise it prints the next step. The pin
# runs in a subshell, so its exit status never becomes signin's.
_signin_pin_step() {
  local other="$1" key label
  key="$(identity_key "$SG_TAG")"
  label="$(account_label "$SG_TAG")"
  if ! tag_is_in_accounts "$key"; then
    printf '  Not in [accounts]: add it with account-switcher add-account %s <email>, then account-switcher identity pin %s\n' "$SG_TAG" "$SG_TAG"
    return 0
  fi
  if [[ -n "$other" ]]; then
    printf "  identity pin refuses an account already pinned to another tag. If '%s' should be on its own account, sign out in that window, then run: account-switcher signin %s\n" "$SG_TAG" "$SG_TAG"
    return 0
  fi
  if [[ "$SG_STATE_END" != "present" || "$2" != "0" || "$3" != "0" ]] || ! _signin_tty; then
    printf "  Check that the window's account menu shows \"%s\", then run: account-switcher identity pin %s\n" "$label" "$SG_TAG"
    return 0
  fi
  printf "  Check that the window's account menu shows \"%s\".\n" "$label"
  _signin_drain
  if _signin_ask "Pin '${SG_TAG}' to this account now?"; then
    printf '\n'
    if ( cmd_identity_pin "$SG_TAG" --yes ); then
      printf "  Pinned. account-switcher identity %s now reads match; this run's result stays unknown (it was checked before the pin).\n" "$SG_TAG"
    else
      printf '  Not pinned. Run: account-switcher identity pin %s\n' "$SG_TAG"
    fi
  else
    printf '\n  Not pinned. To pin it later: account-switcher identity pin %s\n' "$SG_TAG"
  fi
  return 0
}

# signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]
# See the block comment at the top of this section. main passes at most
# eight arguments, each on its own; an empty one is skipped.
cmd_signin() {
  SIGNIN_FINAL=0
  SIGNIN_PHASE="pre"
  trap _signin_on_exit EXIT
  trap _signin_on_signal INT TERM

  local tag="" arg want="" quit_others="false" yes="false" new="false"
  local timeout="" settle="" timeout_set=0 settle_set=0
  for arg; do
    if [[ -n "$want" ]]; then
      if [[ "$want" == "timeout" ]]; then timeout="$arg"; timeout_set=1; else settle="$arg"; settle_set=1; fi
      want=""
      continue
    fi
    case "$arg" in
      "") ;;
      --quit-others|--yes|--new)
        case "$arg" in
          --quit-others) [[ "$quit_others" == "false" ]] || { _signin_usage; _signin_refuse "--quit-others is given twice."; }; quit_others="true" ;;
          --yes)         [[ "$yes" == "false" ]] || { _signin_usage; _signin_refuse "--yes is given twice."; }; yes="true" ;;
          --new)         [[ "$new" == "false" ]] || { _signin_usage; _signin_refuse "--new is given twice."; }; new="true" ;;
        esac
        ;;
      --timeout) [[ $timeout_set -eq 0 ]] || { _signin_usage; _signin_refuse "--timeout is given twice."; }; want="timeout" ;;
      --settle)  [[ $settle_set -eq 0 ]] || { _signin_usage; _signin_refuse "--settle is given twice."; }; want="settle" ;;
      -*) _signin_usage; _signin_refuse "Unknown flag for signin: ${arg}" ;;
      *)
        if [[ -n "$tag" ]]; then _signin_usage; _signin_refuse "Unexpected argument: ${arg}"; fi
        tag="$arg"
        ;;
    esac
  done
  if [[ -n "$want" ]]; then _signin_usage; _signin_refuse "--${want} needs a number of seconds."; fi
  if [[ -z "$tag" ]]; then _signin_usage; _signin_refuse "signin needs a tag (for example: account-switcher signin backup)."; fi
  # validate_tag's rules, checked here so a bad tag exits 2, not die's 1.
  if [[ "$tag" == -* || ! "$tag" =~ ^[a-z0-9-]{1,32}$ ]]; then
    _signin_refuse "Tag must match [a-z0-9-]{1,32} and must not start with '-' (got: '${tag}')."
  fi
  if [[ "$tag" == "default" ]]; then tag="primary"; fi
  if [[ $timeout_set -eq 0 ]]; then
    timeout="$SIGNIN_TIMEOUT_DEFAULT"
  elif [[ ! "$timeout" =~ ^[0-9]{1,4}$ ]] || [[ $((10#$timeout)) -lt 30 || $((10#$timeout)) -gt 1800 ]]; then
    _signin_refuse "--timeout takes a whole number of seconds from 30 to 1800 (got: '${timeout}')."
  fi
  if [[ $settle_set -eq 0 ]]; then
    settle="$SIGNIN_SETTLE_DEFAULT"
  elif [[ ! "$settle" =~ ^[0-9]{1,3}$ ]] || [[ $((10#$settle)) -gt 120 ]]; then
    _signin_refuse "--settle takes a whole number of seconds from 0 to 120 (got: '${settle}')."
  fi
  timeout=$((10#$timeout))
  settle=$((10#$settle))

  # #10: never while update holds its lock (the app bundle may be being
  # replaced). A refusal, so exit 2 like every other one.
  if _update_lock_held; then _signin_refuse "$(_update_lock_refusal "signing in")"; fi

  # #9: it relies on detection to use a running target instead of opening a
  # second process on its profile, and to quit with --quit-others.
  app_binary_present || _signin_refuse "$(app_binary_refusal "opened, quit or signed in")"

  # signin writes history rows; rotation runs here, inside the trap.
  rotate_swap_log_if_needed

  [[ -f "$CONFIG_FILE" ]] || _signin_refuse "No config.toml at ${CONFIG_FILE}. Register a tag first: account-switcher add-account <tag> <email>"
  local in_accounts="false"
  if tag_is_in_accounts "$(identity_key "$tag")"; then in_accounts="true"; fi
  if [[ "$in_accounts" == "false" && "$new" == "false" ]]; then
    _signin_refuse "Tag '${tag}' is not in [accounts] of ${CONFIG_FILE}. Register it first (account-switcher add-account ${tag} <email>), or sign in without a configured account: account-switcher signin ${tag} --new"
  fi

  # Run state, read by the helpers above.
  SG_TAG="$tag"
  SG_UDD="$(udd_for_tag "$tag")"
  SG_TIMEOUT="$timeout"
  if [[ "$quit_others" == "true" ]]; then SG_MODE="quit-others"; else SG_MODE="others-open"; fi
  SG_ROWS="" SG_RAW_FLAGLESS=" " SG_PRE_PRIMARY=" " SG_PRE_ALL=" " SG_SEEN=" " SG_UNKNOWN_PIDS=""
  SG_CONFIRMED="" SG_POLL=0 SG_COMPLETE="" SG_STOP="" SG_MISSES=0 SG_READING=0 SG_QUESTION=""
  SG_TWO_PRIMARY_WARNED=0 SG_ST="" SG_DG="" SG_TSTATE0="" SG_TDIGEST0="" SG_STATE_END=""
  TARGET_PID=""
  SNAP_TAG=() SNAP_STATE0=() SNAP_DIGEST0=() SNAP_VERDICT=()

  local label email email_txt
  label="$(account_label "$tag")"
  email="$(_account_email "$tag")"
  email_txt="${email:-the account you intend for this tag}"
  if [[ "$in_accounts" == "true" ]]; then
    if [[ -n "$email" ]]; then
      printf "Sign in tag '%s' as \"%s\" (%s).\n" "$tag" "$label" "$email"
    else
      printf "Sign in tag '%s' as \"%s\".\n" "$tag" "$label"
    fi
    SG_QUESTION="Does the '${tag}' window show you signed in as \"${label}\"?"
  else
    printf "Sign in tag '%s' (not in [accounts]; no configured account to check against).\n" "$tag"
    email_txt="the account you intend for this tag"
    SG_QUESTION="Does the '${tag}' window show you signed in with the account you intend for it?"
  fi

  # The identity snapshot of every profile, before anything is opened.
  _snap_init || _signin_refuse "Could not set up the identity snapshot (no random salt); nothing was opened."
  local t
  for t in $(_signin_profile_tags); do
    if [[ "$t" == "$tag" ]]; then continue; fi
    _snap_now "$(udd_for_tag "$t")"
    _snap_add "$t"
  done
  SG_DG=""
  _snap_now "$SG_UDD"
  SG_TSTATE0="$SG_ST"
  SG_TDIGEST0="$SG_DG"
  SG_DG=""

  # The instances, through the exact matcher.
  _signin_scan || _signin_refuse "The process table could not be read, so signin can't tell which instances are open; nothing was opened."
  local pid profile method n_target=0 unknown_now="" listing="" idx state tags_now=""
  while IFS=$'\t' read -r pid profile method; do
    [[ -n "$pid" ]] || continue
    SG_PRE_ALL="${SG_PRE_ALL}${pid} "
    tags_now="${tags_now} ${profile}"
    if [[ "$profile" == "primary" || "$profile" == "unknown" || "$SG_RAW_FLAGLESS" == *" ${pid} "* ]]; then
      SG_PRE_PRIMARY="${SG_PRE_PRIMARY}${pid} "
    fi
    if [[ "$profile" == "$tag" ]]; then
      n_target=$((n_target + 1))
      TARGET_PID="$pid"
      continue
    fi
    if [[ "$profile" == "unknown" ]]; then unknown_now="${unknown_now}${pid} "; fi
    listing="${listing}, ${profile} · PID ${pid}"
  done <<< "$SG_ROWS"
  # A running instance's profile is always in the snapshot set, even when
  # its folder is missing (then "no folder before").
  _snap_extend "$tags_now"
  listing="${listing#, }"

  if [[ $n_target -ge 2 ]]; then
    _signin_refuse "Two instances report profile '${tag}'; run account-switcher list. Nothing was opened."
  fi

  local warn_items=0
  if [[ "$quit_others" == "false" ]]; then
    if [[ -n "$listing" ]]; then
      printf 'Open Claude instances, left running: %s\n' "$listing"
    elif [[ -n "$TARGET_PID" ]]; then
      printf 'Open Claude instances, left running: none besides the target\n'
    else
      printf 'Open Claude instances, left running: none\n'
    fi
    if [[ -z "$TARGET_PID" && -n "$unknown_now" ]]; then
      _signin_refuse "Can't tell whether PID ${unknown_now% } is '${tag}'; run account-switcher list, or use --quit-others. Nothing was opened."
    fi
    for pid in $unknown_now; do
      printf "\033[33mWARN:\033[0m PID %s runs on a profile signin can't determine, so signin can't protect it.\n" "$pid" >&2
      SG_UNKNOWN_PIDS="${SG_UNKNOWN_PIDS}${pid} "
      warn_items=$((warn_items + 1))
    done
  fi
  idx=0
  while [[ $idx -lt ${#SNAP_TAG[*]} ]]; do
    if [[ "${SNAP_STATE0[$idx]}" == "unreadable" ]]; then
      printf "\033[33mWARN:\033[0m can't read the identity of '%s'; signin can't protect it.\n" "${SNAP_TAG[$idx]}" >&2
      warn_items=$((warn_items + 1))
    fi
    idx=$((idx + 1))
  done
  if [[ $warn_items -gt 0 && "$yes" != "true" ]]; then
    _signin_tty || _signin_refuse "signin can't check everything it would need to (see the warnings above), and there is no terminal to ask; nothing was opened. Re-run with --yes to go on anyway (the result is then UNVERIFIED, exit 4)."
    if ! _signin_ask "Continue anyway?"; then
      printf '\n'
      printf 'Not continuing; nothing was opened.\n'
      _signin_exit 2
    fi
    printf '\n'
  fi
  if [[ "$quit_others" == "false" ]]; then
    # X3: an open instance with no recorded account is the likeliest place
    # for a stray login to land.
    while IFS=$'\t' read -r pid profile method; do
      [[ -n "$pid" && "$profile" != "$tag" && "$profile" != "unknown" ]] || continue
      idx="$(_snap_index "$profile")"
      [[ -n "$idx" ]] || continue
      state="${SNAP_STATE0[$idx]}"
      case "$state" in
        absent|nofile|nofolder)
          printf "\033[33mWARN:\033[0m '%s' (PID %s) has no recorded account and may be showing a sign-in screen. A stray login is most likely to land in a window like that; close it first, or use --quit-others.\n" "$profile" "$pid" >&2
          ;;
      esac
    done <<< "$SG_ROWS"
  fi

  # --quit-others: list, confirm, check the quit path would signal exactly
  # the listed PIDs, quit them through quit_all_claude's listed mode (only
  # those PIDs; a new instance stops it), check nothing is left.
  if [[ "$quit_others" == "true" ]]; then
    local mark now p
    if [[ -z "${SG_PRE_ALL// /}" ]]; then
      printf 'Nothing to quit.\n'
    else
      printf 'Open Claude instances:\n'
      while IFS=$'\t' read -r pid profile method; do
        [[ -n "$pid" ]] || continue
        mark=""
        if [[ "$profile" == "$tag" ]]; then mark="  (target: will be quit and reopened)"; fi
        printf '  %s · PID %s%s\n' "$profile" "$pid" "$mark"
        SG_CONFIRMED="${SG_CONFIRMED} ${pid}"
        case ",${SG_CONFIRMED_TAGS}," in
          *",${profile},"*) ;;
          *) SG_CONFIRMED_TAGS="${SG_CONFIRMED_TAGS:+${SG_CONFIRMED_TAGS},}${profile}" ;;
        esac
      done <<< "$SG_ROWS"
      printf -- "--quit-others quits every Claude instance listed above (work in progress in them may be lost), then opens '%s' alone.\n" "$tag"
      if [[ "$yes" != "true" ]]; then
        _signin_tty || _signin_refuse "--quit-others needs a terminal to confirm the list, or --yes. Nothing was quit."
        if ! _signin_ask "Quit them?"; then
          printf '\n'
          printf 'Not quitting; nothing was quit or signed in.\n'
          _signin_exit 2
        fi
        printf '\n'
      fi
      now="$(get_claude_pids)"
      now=" ${now//$'\n'/ } "
      for p in $SG_CONFIRMED; do
        if [[ "$now" != *" ${p} "* ]]; then
          _signin_refuse "The quit path would signal processes that weren't listed (the open instances changed since the list). Nothing was quit; run it again."
        fi
      done
      for p in $now; do
        if [[ " ${SG_CONFIRMED} " != *" ${p} "* ]]; then
          _signin_refuse "The quit path would signal processes that weren't listed (PID ${p}). Nothing was quit; run it again."
        fi
      done
      SIGNIN_PHASE="quit"
      # The listed mode signals only the confirmed PIDs, and stops (status
      # 3) if an instance that wasn't listed appears during the quit.
      local quit_rc=0
      # The PIDs are numbers, so word splitting is the point.
      # shellcheck disable=SC2086
      ( quit_all_claude listed $SG_CONFIRMED ) || quit_rc=$?
      if [[ $quit_rc -eq 3 ]]; then
        _signin_quit_row
        _signin_quit_report "Stopped the quit: an instance that wasn't listed appeared (named above), and signin closes only what it listed."
        _signin_exit 2
      fi
      if [[ $quit_rc -ne 0 ]]; then
        _signin_quit_row
        _signin_refuse "Could not quit every instance; nothing was signed in."
      fi
      _signin_quit_row
      SIGNIN_PHASE="quitdone"
      _signin_scan || _signin_refuse "The process table could not be read after the quit; nothing was signed in."
      if [[ -n "$SG_ROWS" ]]; then
        _signin_refuse "A Claude instance is still running after the quit (account-switcher list); nothing was signed in."
      fi
    fi
    TARGET_PID=""
    SG_PRE_ALL=" "
    SG_PRE_PRIMARY=" "
  fi

  # #24: an observation before the open, so the tag signin opens carries
  # the same seen time as every tag running now (one clock per run).
  open_tags_observe

  # The target: use the running instance (never a second process on a
  # profile whose lock is held), or open it through launch's open path.
  local first_launch="false" pre rung
  [[ -d "$SG_UDD" ]] || first_launch="true"
  if [[ -n "$TARGET_PID" ]]; then
    SIGNIN_PHASE="open"
    printf "Using the running instance for '%s' (PID %s); not opening another.\n" "$tag" "$TARGET_PID"
    printf "In the '%s' window: if it shows you signed in, sign out from the app's account menu first; then sign in as \"%s\".\n" "$tag" "$label"
  else
    pre="$(get_claude_pids)"
    SIGNIN_PHASE="open"
    if ! open_tag_instance "$tag" "$SG_UDD" "$first_launch"; then
      SIGNIN_PHASE="pre"
      _signin_refuse "Could not open the '${tag}' instance; nothing was signed in."
    fi
    TARGET_PID="$(wait_for_new_instance "$tag" "$pre" "$NEW_INSTANCE_WAIT_S")"
    if [[ -n "$TARGET_PID" ]]; then _open_tags_back "$tag"; fi
    if [[ -z "$TARGET_PID" ]]; then
      _signin_refuse "No new '${tag}' instance appeared within ${NEW_INSTANCE_WAIT_S} s of opening it, so signin can't watch it; nothing was signed in by signin. Check with: account-switcher list"
    fi
    printf "Opened '%s' (PID %s).\n" "$tag" "$TARGET_PID"
  fi
  rung="$(bring_to_front "$TARGET_PID")"
  if [[ "$rung" == "none" ]]; then
    printf "Bring the '%s' window (PID %s) to the front first: Cmd-backtick or the Dock.\n" "$tag" "$TARGET_PID"
  fi

  # The prompt block (criterion 2): the account, and how to sign in.
  printf "In the '%s' window, choose \"Continue with email\", enter %s, then type the code you're sent.\n" "$tag" "$email_txt"
  printf 'If you use Google instead, the browser decides the account: make sure the browser is signed into %s first.\n' "$email_txt"
  printf 'Finish the sign-in in that window only, and leave the other Claude windows alone until this command reports.\n'
  if [[ "$quit_others" == "false" ]]; then
    printf 'If any other Claude window shows a sign-in screen, close it before you start.\n'
    printf 'To sign in with nothing else open instead, stop now (Ctrl-C) and run: account-switcher signin %s --quit-others\n' "$tag"
  fi

  # The wait.
  SIGNIN_PHASE="wait"
  if _signin_tty; then
    _signin_drain
    SG_READING=1
    printf 'Waiting up to %ss. When the window shows you signed in, answer y; Ctrl-C stops.\n' "$timeout"
    printf '%s [y/N] ' "$SG_QUESTION"
  else
    printf 'Waiting up to %ss for the profile to record the sign-in; Ctrl-C stops.\n' "$timeout"
  fi
  while :; do
    _signin_poll wait
    if [[ -n "$SG_STOP" || -n "$SG_COMPLETE" ]]; then break; fi
    _signin_timer
    if [[ -n "$SG_COMPLETE" ]]; then
      # Answered y: say "changed" if the key changed since the last poll.
      _snap_now "$SG_UDD"
      if [[ "$SG_ST" == "present" && ( "$SG_TSTATE0" != "present" || "$SG_DG" != "$SG_TDIGEST0" ) ]]; then
        SG_COMPLETE="changed"
      fi
      SG_DG=""
      break
    fi
    if [[ $((SG_POLL * SIGNIN_POLL_S)) -ge $timeout ]]; then SG_STOP="timeout"; break; fi
  done
  if [[ "$SG_READING" == "1" ]]; then printf '\n'; fi
  if [[ "$SG_STOP" == "target-exited" ]]; then
    printf "The '%s' instance exited before sign-in finished. If a browser tab or an emailed code is still pending, don't complete it:\n" "$tag"
    printf 'finishing it now could sign another open instance, or a newly started primary, into this account.\n'
    printf 'Check again in a minute with: account-switcher identity --all\n'
  fi
  _snap_now "$SG_UDD"
  SG_STATE_END="$SG_ST"
  SG_DG=""

  # The settle window: the app has been seen to deliver one login callback
  # several times, so keep watching the other profiles for a while.
  if [[ -n "$SG_COMPLETE" && -z "$SG_STOP" && $settle -gt 0 ]]; then
    SIGNIN_PHASE="settle"
    printf 'Watching the other instances for %s s…\n' "$settle"
    local k=0 n_settle=$(( (settle + SIGNIN_POLL_S - 1) / SIGNIN_POLL_S ))
    while [[ $k -lt $n_settle ]]; do
      "$AS_BIN_SLEEP" "$SIGNIN_POLL_S"
      _signin_poll settle
      if [[ -n "$SG_STOP" ]]; then break; fi
      k=$((k + 1))
    done
  fi
  _signin_finish ""
}

# ---- Help ----------------------------------------------------------------

cmd_help() {
  "$AS_BIN_CAT" <<EOF
Claude desktop app account switcher (v${VERSION})

The bridged Code subprocess proxies API calls through the Mac app's parent
auth (per user-data-dir), NOT the CLI keychain. So the right primitive for
billing-aware account swapping is Electron's --user-data-dir flag, not CLI
surface mutation.

Ships launcher-only — no plaintext tokens persist on disk.
OAuth state lives in:
  - macOS keychain (CLI surface, when used by terminal-direct \`claude\` invocations)
  - Electron safeStorage (Mac-app surface, per --user-data-dir)

What's shared automatically across accounts (no plumbing needed):
  - Local Code session jsonls in ~/.claude/projects/<encoded-cwd>/
  - Skills, hooks, plugins, MCP configs, settings under ~/.claude/
  → 'claude --continue' works cross-instance because session jsonls are
    cwd-keyed and live outside the per-account user-data-dir.

What's per-account (intentional isolation):
  - OAuth tokens (held by the Mac app's instance for its user-data-dir)
  - Mac app preferences (theme, window state)
  - Cloud chat sidebar (Anthropic-server-side; per-account by design)

USAGE:
  account-switcher <subcommand> [args...]

SUBCOMMANDS (Mac desktop app management):

  swap <tag> [flags]     SEAMLESS swap. 3-step flow:
                           1. Quit current Claude instance(s)
                              (graceful 15s → SIGTERM → SIGKILL via PID list)
                           2. The settings step (see prefs): update the
                              synced settings keys in <tag> only, which may
                              be primary, from every profile; for a tag
                              other than primary, also clone-prefs'
                              extension and worktree copy from primary.
                              Prints one line: applied, kept, skipped,
                              needs review.
                           3. Launch target instance and bring its window to
                              the front
                         Result: identity display + Mac-app billing align with tgt.
                         Workspace (~/.claude/) stays bidirectional.
                         Runs the account check (see identity) before it
                         opens or quits anything: on a MISMATCH it refuses
                         before it quits anything or writes any profile.
                         Ends with the same line as launch. Exit 0
                         swapped; 1 refused (a MISMATCH, a tag that is not
                         configured, update running, the app not where
                         detection looks), an instance would not quit, or
                         open failed (every instance was quit; run launch
                         <tag>).
                         Flags:
                           --no-mirror       skip step 2
                           --force           swap even on a MISMATCH
                           --new             allow a tag that is not in
                                             [accounts] and has no folder

  launch <tag> [--force] [--new]
                         ADDITIVE launch. Spawns target instance WITHOUT
                         quitting others. Use for running both side-by-side.
                         Runs the account check (see identity) before it
                         opens or quits anything: on a MISMATCH it refuses
                         and opens nothing; --force launches anyway, with
                         the warning.
                         launch and swap refuse a tag that is not in
                         [accounts] and has no profile folder yet (a typo
                         would create a new, empty profile), naming the
                         configured tags and the closest match; --new
                         allows it. They also refuse while update runs, and,
                         while an app update is staged, warn (one line) that
                         the app may close idle windows on its own to
                         install it.
                         Then waits up to ${NEW_INSTANCE_WAIT_S} s for the new instance, brings
                         its window to the front by PID, and ends with:
                           tag=<tag> pid=<pid> front=yes|no
                           account=<"label"|unrecognized|unknown>
                           status=<match|MISMATCH|unknown>
                         (one line). front=no adds "Switch with Cmd-backtick
                         or the Dock". pid=unknown: no new instance
                         appeared in time; the launch still happened.
                         Exit 0 launched; 1 refused (a MISMATCH, a tag that
                         is not configured, update running, or open failed),
                         nothing opened.

  signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]
                         (or login) Sign one tag in. Other instances stay
                         open by default. It lists them, prints the tag's
                         label and email, and opens the tag (or uses its
                         running instance; never a second one). It then
                         waits for the profile to record an account (at a
                         terminal you can also answer y), keeps watching for
                         ${SIGNIN_SETTLE_DEFAULT} s (--settle), and runs the account check. Before
                         and after, it compares every profile's recorded
                         account (a salted hash, never printed or saved): a
                         change in another profile is a loud MISMATCH naming
                         that tag, detected after the fact, not prevented.
                         --quit-others lists every instance, asks (--yes
                         skips), quits them all, and signs in with only the
                         target running; it signals only the instances it
                         listed, and one it didn't list that appears during
                         the quit stops it (named, exit 2, nothing opened).
                         --timeout 30-1800 (default ${SIGNIN_TIMEOUT_DEFAULT});
                         --new allows a tag not in [accounts]. Ends with:
                           signin tag=<tag> mode=<others-open|quit-others>
                           result=<match|MISMATCH|unknown> detail=<word>
                           recorded_as=<tag|none|unrecognized>
                           others_checked=<n> others_changed=<n>
                           others_unverified=<n> exit=<code>
                         Exit 0 match; 1 MISMATCH; 2 refused, nothing
                         opened; 3 unknown (no pin, not seen in time,
                         exited, stopped); 4 another profile changed or
                         could not be checked (wins over 1, 3 and 0).

  identity [<tag> | --all] [--show-ids]
                         Read-only account check. One row per tag in
                         [accounts]: the expected account (its label), the
                         account its profile records, and match, MISMATCH
                         or unknown. Exit 0 = no MISMATCH, 1 = a MISMATCH,
                         2 = cannot run. Prints labels, never ids;
                         --show-ids prints the ids too, on stdout, and is
                         terminal-only: with stdout not a terminal it
                         refuses (exit 2) and prints nothing. Reads
                         only the profile's config.json (no cookies, Local
                         Storage, keychain items or tokens).

  identity pin <tag> [--yes] [--force]
                         Record the account <tag>'s profile holds now as the
                         account it must hold ([identity] in config.toml).
                         Check the window's account menu first. Refuses when
                         that account is already pinned to another tag,
                         unless --force.

  clone-prefs [src tgt]  Mirror Mac-app user-facing prefs from src to tgt.
                         Default: clone-prefs primary backup.
                           - Settings: the key-level step for tgt (see
                             prefs; src is not used for settings). The
                             whole claude_desktop_config.json is no longer
                             copied.
                           - Claude Extensions/ (installed Anthropic exts)
                           - Claude Extensions Settings/
                           - git-worktrees.json (MERGED with target's existing)
                         Snapshot-rollback semantics for those three: target
                         snapshotted before apply; restored on failure (M-7).
                         Refuses if target instance is running (re-checked
                         after snapshot, before apply, M-11). Exit 0 done;
                         1 refused (nothing written) or failed (the
                         snapshot is restored).

  prefs <verb>           Keep 8 global UI settings (the allowlist) the same
                         in every profile, one key at a time: primary plus
                         each [accounts] tag whose profile folder exists. A
                         change in any profile spreads (latest wins); when
                         the order of two changes can't be known, or a key
                         has no history and the profiles disagree, the key
                         needs review (primary's value is proposed). Nothing
                         else in the file is ever written, and nothing is
                         deleted, except that prefs undo removes a key the
                         last sync added. Runs at swap and on request, never
                         at launch. Running profiles are never written.
                           diff [--all]       every difference, with no ids
                                              or paths (read-only). Exit 0
                                              in sync, 1 not, 2 error
                           sync [<tag>] [--dry-run]
                                              update <tag>, or every profile
                                              not running. Exit 0 done, 1
                                              done but a key needs review or
                                              a write was skipped, 2 refused
                                              (--dry-run: 1 = something to
                                              write or pending)
                           review             decide each differing key: use
                                              primary's or a profile's value,
                                              pin it, or skip; one confirm
                                              at the end. Needs a terminal.
                                              Exit 0 applied, 1 left pending
                                              or declined, 2 refused
                           adopt <key-id> --from <tag>
                                              make <tag>'s value the fleet
                                              value. Exit 0, 1 a profile
                                              skipped, 2 refused
                           pin <tag> <key-id>|--all
                           unpin <tag> <key-id>|--all
                                              keep a key (or the whole
                                              profile) different on purpose.
                                              Exit 0, 2 refused
                           undo <tag> [--whole-file]
                                              reverse the last sync to <tag>,
                                              key by key: a key it changed
                                              goes back to its previous
                                              value, a key it added is
                                              removed; both then need review
                                              (--whole-file: restore the
                                              prior copy, after a
                                              confirmation). Exit 0 restored,
                                              1 nothing to restore, 2 refused
                         Without a terminal, use diff, sync, adopt, pin,
                         unpin and undo.

  quit [--all]           Quit all running Claude instances:
                           - osascript graceful quit
                           - 15s wait
                           - SIGTERM via PID list
                           - SIGKILL via PID list (last resort)
                           - Final check by PID list (die if alive).

  update [--yes]         Install the staged Claude app update. Every tag
                         runs the same app, and its updater installs only
                         once every instance is closed. update lists each
                         instance it will close (tag · PID), warns that
                         scheduled tasks pause while Claude is closed, and
                         asks (--yes skips; no terminal and no --yes
                         refuses). It quits them through the quit path
                         above (never the updater's helper), signalling
                         only the instances it listed: one it didn't list
                         that appears during the quit stops it (named;
                         nothing more is signalled, and what it closed is
                         reopened). It waits up to
                         [update] install_timeout_s (default 120) for the
                         install, reopens the same tags, and prints the
                         installed version before and after. If the
                         updater's log shows an install running when the
                         quit stops (that way, or an instance won't close)
                         or the wait times out, it reopens nothing and
                         prints, per tag, the command to run once the
                         install finishes. When the updater reopens
                         primary itself, update does not open it a second
                         time. Ends with:
                           update before=<v> after=<v>
                           result=<updated|unchanged|timeout|quit-failed|unlisted>
                           reopened=<n>/<m> exit=<code>
                         Exit 0 installed (or nothing staged); 1 the
                         version did not change (the updater log's last
                         line is printed); 2 refused, nothing closed, or
                         stopped by an unlisted instance (result=unlisted);
                         3 installed, but a tag did not reopen; 130
                         interrupted (it says what it closed and how to
                         reopen each tag).

  reopen                 Reopen every tag recorded as closed by the app's
                         updater (list names them), each on its own profile.
                         It never opens a tag that is already running, nor
                         primary a second time right after an install the
                         updater reopens it from. Tags closed for an unknown
                         reason (perhaps on purpose) are named with a launch
                         command instead, never reopened. Ends with:
                           reopen reopened=<n>/<m> missing=<tags|none>
                           unknown=<tags|none> exit=<code>
                         Exit 0 reopened (or nothing to reopen); 2 refused
                         (update or an install running, Claude not where
                         detection looks, or an argument given); 3 a tag
                         did not reopen (named; reopen offers it again).

  list (or instances)    Show running Claude desktop app instances, each with
                         its tag and how the tag was found (via=argv: its
                         --user-data-dir; via=flagless: the only instance
                         without one, primary; via=lsof: the profile folder
                         it holds open), or tag=unknown via=none when it
                         cannot be determined; then the tags the switcher
                         opened that Claude closed without it, each with its
                         cause (closed by the app's updater, or closed,
                         cause unknown) and when it was last seen; then
                         on-disk profile folders with sizes, each Claude-*
                         folder not in [accounts]
                         marked unconfigured (never deleted); then the
                         installed app version, the staged one (or none),
                         and how long it has waited (unknown, never none,
                         when the updater's files can't be read), with a
                         warning while an update is staged and an instance
                         is open.

  status                 Show CLI identity (~/.claude.json + keychain
                         subscription type) + statusline marker.

  config show | get <k>  Display or read a specific config.toml key.

  add-account <tag> <email> [label]
                         Register a tag → email mapping in [accounts] of
                         the runtime config.toml. Run AFTER first-launch
                         login of the new tag's Mac app instance so
                         'status' can resolve CLI identity → switcher tag.
                         This is the explicit [accounts] registration path.

  version (or --version) Print this script's version. To check whether the
                         install matches the repository, run
                         \`bash install.sh --check\` from the repo clone.

  help                   Show this message.

PROFILE TAG CONVENTIONS:
  primary (or default) → uses ~/Library/Application Support/Claude
                         (the OS default; preserves your existing chat history,
                         plugins, MCP, settings.)
  <other-tag>          → uses ~/Library/Application Support/Claude-<tag>
                         (isolated; sign each tag in with: signin <tag>.)

  Tag format enforced (H-1): [a-z0-9-]{1,32}, no leading hyphen.

EXAMPLES:
  # Seamless one-command swap (recommended daily workflow)
  account-switcher swap primary               # quit current → launch primary
  account-switcher swap backup                # quit current → launch backup

  # Additive launch (run both side-by-side; e.g. for parallel work)
  account-switcher launch primary
  account-switcher launch backup
  account-switcher list                       # see both running

  # Account check: is each tag's profile on the account it should be?
  account-switcher identity                   # one row per tag
  account-switcher identity pin backup        # after checking backup's window

  # Sign a tag in (others stay open; any other profile that changes is named)
  account-switcher signin backup
  account-switcher signin backup --quit-others   # with nothing else open

  # Cleanup
  account-switcher quit --all                 # quit all instances

  # A staged app update (list shows it): close every instance, install,
  # reopen the same tags
  account-switcher update

  # A new tag on purpose (otherwise launch refuses a tag with no folder)
  account-switcher launch newtag --new

NOTES:
  - Each non-primary user-data-dir is created on first launch, which shows the
    app's sign-in screen; use \`signin <tag>\` to sign it in and check the result.
  - "primary" maps to the default ~/Library/Application Support/Claude — preserves
    existing chat history, MCP connections, plugins. Don't rename this dir.
  - Multiple instances can run simultaneously. Each has its own dock icon (same
    Claude.app binary; different in-memory state).
  - Running instances are found by the app's main binary at
    ${APP_MAIN_BIN}. When it isn't there (Claude
    installed somewhere else), swap, quit, clone-prefs, signin, update and the
    writing prefs verbs refuse, naming that path, because they can't tell
    which profiles are running; list, identity, status, prefs diff, prefs
    sync --dry-run and launch print one warning line and carry on.
  - To bring a new window forward, launch and swap try lsappinfo setfront,
    then an AppKit activation, then System Events, each for that PID. The
    System Events step may show a one-time macOS prompt asking to control
    System Events; declining only means that step is skipped.
  - To fully reset a profile: quit the instance, then \`trash\`
    \`~/Library/Application Support/Claude-<tag>\`. Next \`launch <tag>\` is a fresh login.

STORE:        ${STORE}
CONFIG:       ${CONFIG_FILE}
SWAP LOG:     ${SWAP_LOG}  (rotated at 1100 lines, archive swap-history.log.1)
EOF
}

cmd_version() {
  printf 'account-switcher %s\n' "$VERSION"
}

# ---- Dispatch ------------------------------------------------------------

main() {
  # M-1: If invoked with a single arg containing whitespace (typical of slash
  # command quoted invocation `script.sh "$ARGUMENTS"`), word-split it inside
  # the script. Safe because the outer shell already treated the whole string
  # as a single literal arg (no command substitution / glob expansion).
  if [[ $# -eq 1 ]] && [[ "$1" == *' '* ]]; then
    local input="$1"
    local args=()
    IFS=' ' read -ra args <<< "$input"
    set -- "${args[@]}"
  fi

  # signin (#7) is dispatched before the shared check below, whose die exits
  # 1, which a caller would read as a MISMATCH: signin runs the same check in
  # a subshell per argument and refuses with 2, and it takes at most eight
  # arguments, each passed on its own (cmd_signin skips an empty one).
  case "${1:-}" in
    signin|login)
      local _a
      if [[ $# -gt 9 ]]; then _signin_usage; printf '\033[31mERROR:\033[0m Too many arguments for signin.\n' >&2; exit 2; fi
      for _a; do
        if ! ( validate_argv_safe "$_a" ); then exit 2; fi
      done
      cmd_signin "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}"
      return 0
      ;;
    update)
      # update (#10) gives exit 1 a meaning of its own (the version did not
      # change), so, like signin, it checks its arguments here and refuses a
      # bad one with 2 rather than through the shared check's die.
      local _u
      for _u; do
        if ! ( validate_argv_safe "$_u" ); then exit 2; fi
      done
      shift
      cmd_update "$@"
      return 0
      ;;
    reopen)
      # reopen (#24) has update's exit codes (2 refused, 3 a tag did not
      # reopen), so it also checks its arguments here and refuses a bad one
      # with 2 rather than through the shared check's die.
      local _r
      for _r; do
        if ! ( validate_argv_safe "$_r" ); then exit 2; fi
      done
      shift
      cmd_reopen "$@"
      return 0
      ;;
    prefs)
      # prefs (#11) also gives exit 1 a meaning of its own (not in sync), so
      # it checks its arguments here and refuses a bad one with 2. It is
      # dispatched before the log rotation below: diff and sync --dry-run
      # write nothing at all, and the writing verbs rotate the log themselves.
      local _p
      for _p; do
        if ! ( validate_argv_safe "$_p" ); then exit 2; fi
      done
      shift
      cmd_prefs "$@"
      return 0
      ;;
  esac

  # M-1: Reject any argv token containing shell metacharacters before
  # dispatching. Layered defence with the slash command's "$ARGUMENTS" quoting.
  # Exception: --note values are markdown content, never shell-executed. Strip
  # them for strict validation, then validate softly via validate_note_safe
  # (still blocks backticks/$(/newline).
  local _strict_argv=()
  local _note_val=""
  local _i=1
  local _n=$#
  while [[ $_i -le $_n ]]; do
    local _cur="${!_i}"
    if [[ "$_cur" == "--note" ]] && [[ $_i -lt $_n ]]; then
      _i=$((_i + 1))
      _note_val="${!_i}"
    elif [[ "$_cur" == --note=* ]]; then
      _note_val="${_cur#--note=}"
    else
      _strict_argv+=("$_cur")
    fi
    _i=$((_i + 1))
  done
  validate_argv_safe "${_strict_argv[@]}"
  [[ -n "$_note_val" ]] && validate_note_safe "$_note_val"

  # Answer `version` before log rotation, so asking for the version touches
  # no files. The read-only `identity` check is answered here too, so it
  # writes nothing; `identity pin` writes, so it is dispatched with the rest.
  # identity takes at most two arguments and pin at most three; each is
  # passed on its own, and an empty one is skipped.
  case "${1:-}" in
    version|--version) cmd_version; return 0 ;;
    identity)
      if [[ "${2:-}" != "pin" ]]; then
        if [[ $# -gt 3 ]]; then _identity_usage; exit 2; fi
        cmd_identity "${2:-}" "${3:-}"
        return 0
      fi
      ;;
  esac

  # M-13: Rotate the swap log at script entry (cheap; runs once per invocation).
  rotate_swap_log_if_needed

  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    swap)            cmd_swap_app "$@" ;;
    launch)          cmd_launch "$@" ;;
    identity)
      # Only `identity pin` reaches here; the read-only form returned above.
      if [[ $# -gt 4 ]]; then _identity_usage; exit 2; fi
      cmd_identity_pin "${2:-}" "${3:-}" "${4:-}"
      ;;
    clone-prefs)     cmd_clone_prefs "$@" ;;
    quit)            cmd_quit "$@" ;;
    list|instances)  cmd_list_instances "$@" ;;
    status)          cmd_status "$@" ;;
    config)          cmd_config "$@" ;;
    add-account)     cmd_add_account "$@" ;;
    help|-h|--help)  cmd_help ;;
    *) die "Unknown subcommand: ${subcmd} (try: account-switcher help)" ;;
  esac
}

main "$@"
