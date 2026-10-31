#!/usr/bin/env bash
# account-switcher.sh - Claude desktop app account switcher
#
# Swap, launch, and manage multiple Claude desktop app accounts via the
# Electron --user-data-dir flag. An earlier CLI-mutation approach was
# removed after a security review; only the Mac-app launcher surface ships.
#
# Subcommands: swap | launch | signin | identity | clone-prefs | quit | list | status | config | add-account | version | help
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
  local write=" RM MV CP RSYNC CHMOD INSTALL MKTEMP "
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

  # 8. signin's per-poll test hook (#7), when set, is an executable file
  #    under the scratch root.
  if [[ -n "${AS_TEST_POLL_HOOK:-}" ]]; then
    _as_test_under "${AS_TEST_POLL_HOOK:-}" "$root" || _as_test_refuse "AS_TEST_POLL_HOOK is not under AS_TEST_ROOT (got '${AS_TEST_POLL_HOOK:-}')"
    [[ -f "${AS_TEST_POLL_HOOK:-}" && -x "${AS_TEST_POLL_HOOK:-}" ]] || _as_test_refuse "AS_TEST_POLL_HOOK is not an executable file (got '${AS_TEST_POLL_HOOK:-}')"
  fi
}

AS_SEAM_BINS="AWK BASENAME CAT CHMOD COMMAND CP CUT DATE DU GIT GREP HEAD INSTALL JQ KILL LSAPPINFO LSOF MKTEMP MV OD OPEN OSASCRIPT PS PYTHON3 RM RSYNC SECURITY SED SHASUM SLEEP TAIL TR WC"
AS_SEAM_ROOTS="STORE CLAUDE_JSON PROFILE_ROOT APP_BUNDLE UPDATER_CACHE APP_LOG_DIR"
# Two test-only names for signin (#7), honoured only in test mode like every
# seam name: AS_TEST_STDIN_IS_TTY=1 makes stdin count as a terminal, and
# AS_TEST_POLL_HOOK names a scratch script signin runs once per poll, so a
# case can change the scenario between polls in either timer mode.
if [[ "${AS_TEST_MODE:-0}" != "1" ]]; then
  # Production: the environment is ignored.
  for _n in $AS_SEAM_BINS; do unset "AS_BIN_${_n}"; done
  for _n in $AS_SEAM_ROOTS; do unset "AS_${_n}"; done
  unset _n AS_TEST_ROOT AS_FAKES_DIR AS_KEYCHAIN_SVC AS_TEST_STDIN_IS_TTY AS_TEST_POLL_HOOK
fi
: "${AS_BIN_AWK:=/usr/bin/awk}"
: "${AS_BIN_BASENAME:=/usr/bin/basename}"
: "${AS_BIN_CAT:=/bin/cat}"
: "${AS_BIN_CHMOD:=/bin/chmod}"
: "${AS_BIN_COMMAND:=/usr/bin/command}"
: "${AS_BIN_CP:=/bin/cp}"
: "${AS_BIN_CUT:=/usr/bin/cut}"
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
: "${AS_BIN_MKTEMP:=/usr/bin/mktemp}"
: "${AS_BIN_MV:=/bin/mv}"
: "${AS_BIN_OD:=/usr/bin/od}"
: "${AS_BIN_OPEN:=/usr/bin/open}"
: "${AS_BIN_OSASCRIPT:=/usr/bin/osascript}"
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
  AS_BIN_CP AS_BIN_CUT AS_BIN_DATE AS_BIN_DU AS_BIN_GIT AS_BIN_GREP \
  AS_BIN_HEAD AS_BIN_INSTALL AS_BIN_JQ AS_BIN_KILL AS_BIN_LSAPPINFO AS_BIN_LSOF \
  AS_BIN_MKTEMP AS_BIN_MV AS_BIN_OD \
  AS_BIN_OPEN AS_BIN_OSASCRIPT AS_BIN_PS AS_BIN_PYTHON3 \
  AS_BIN_RM AS_BIN_RSYNC AS_BIN_SECURITY AS_BIN_SED AS_BIN_SHASUM AS_BIN_SLEEP AS_BIN_TAIL \
  AS_BIN_TR AS_BIN_WC
readonly AS_STORE AS_CLAUDE_JSON AS_PROFILE_ROOT AS_APP_BUNDLE AS_UPDATER_CACHE \
  AS_APP_LOG_DIR AS_KEYCHAIN_SVC
AS_TEST_STDIN_IS_TTY="${AS_TEST_STDIN_IS_TTY:-}"
AS_TEST_POLL_HOOK="${AS_TEST_POLL_HOOK:-}"
readonly AS_TEST_STDIN_IS_TTY AS_TEST_POLL_HOOK

# ---- End of test seam -----------------------------------------------------

# ---- Constants & paths ---------------------------------------------------

# Bump on every change to this script. `install.sh --check` reads this line
# from both the repo copy and the installed copy (without running either), so
# keep it a single `readonly VERSION="..."` assignment.
readonly VERSION="11.0.0-dev"

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
  local raw st=0 pid kind method flagless=0 argv_primary=0
  raw="$(_claude_main_rows)" || st=$?
  [[ $st -eq 0 ]] || return 2
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
# whole id (`identity --show-ids` prints whole ids on stdout, for a
# terminal). History rows carry a tag and a status word, never an id or a
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
# with the recovery steps, and nothing has been opened, quit or written.
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

quit_all_claude() {
  # F2: Capture initial PID list at function entry. We track THESE
  # specific processes through the quit lifecycle via /bin/kill -0 instead
  # of pgrep -f. The pgrep approach was unreliable: during AppleScript-
  # induced quit handlers (e.g., "Save changes?" dialogs, exec transitions,
  # argv modifications) pgrep -f could transiently fail to match a live
  # process, causing the wait loop and SIGTERM/SIGKILL guards to clause
  # through and return "success" while the process remained alive.
  local initial_pids
  initial_pids=$(get_claude_pids)

  if [[ -z "$initial_pids" ]]; then
    return 0
  fi

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
    "$AS_BIN_SLEEP" 1
    n=$((n + 1))
  done

  # M-4 + F2: SIGTERM step. Send SIGTERM to any initial PID still alive
  # per kill -0, plus any new Claude processes started during the wait
  # (e.g., LaunchAgent re-spawn, user clicked Dock icon).
  local alive_initial
  alive_initial=$(_alive_pids "$initial_pids" 2>/dev/null || true)
  local fresh_pids
  fresh_pids=$(get_claude_pids)
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
  fresh_pids=$(get_claude_pids)
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
  fresh_pids=$(get_claude_pids)
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

# ---- launch (additive; H-1) ----------------------------------------------

# open_tag_instance <tag> <user-data-dir> <first_launch: true|false>
# The open path launch and signin (#7) share: starts a new instance for the
# tag (primary without the flag), records the tag in the statusline marker
# and appends the LAUNCH row.
open_tag_instance() {
  local tag="$1" udd="$2" first_launch="$3"
  if [[ "$tag" == "primary" ]] || [[ "$tag" == "default" ]]; then
    "$AS_BIN_OPEN" -n -a "Claude"
  else
    "$AS_BIN_OPEN" -n -a "Claude" --args --user-data-dir="$udd"
  fi

  printf '%s\n' "$tag" > "$STATUSLINE_MARKER"

  printf '[%s] LAUNCH tag=%s udd=%s first_launch=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$udd" "$first_launch" \
    >> "$SWAP_LOG"
}

cmd_launch() {
  local tag="" force="false" arg
  for arg; do
    case "$arg" in
      --force) force="true" ;;
      -*) die "Unknown flag: ${arg} (launch takes <tag> [--force])" ;;
      *)
        if [[ -z "$tag" ]]; then tag="$arg"; else die "Unexpected arg: ${arg}"; fi
        ;;
    esac
  done
  if [[ -z "$tag" ]]; then
    die "Usage: account-switcher launch <tag> [--force]  (e.g. primary, backup)"
  fi
  validate_tag "$tag"

  # #6: check the account the profile records before opening anything. A
  # MISMATCH refuses here (--force overrides); unknown proceeds with a hint.
  identity_gate "$tag" "$force" launch

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

  open_tag_instance "$tag" "$udd" "$first_launch"

  ok "Launched. Look for the new Claude window."

  if [[ "$first_launch" == "true" ]]; then
    info ""
    info "Next: in the new Claude window, log in with the account for this profile."
    info "After login, the user-data-dir will hold that account's auth + chat + plugins."
    info "Future 'launch ${tag}' invocations will skip the login prompt."
  fi

  # #8: wait for the new instance, bring it to the front, end with its line.
  # The launch itself has happened, so this never changes the exit status.
  _launch_report "$tag" "$pre_pids"
}

# ---- list (running instances + configured profile dirs) ------------------

cmd_list_instances() {
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

  printf 'Configured profiles (under "%s"):\n' "${AS_PROFILE_ROOT}/"
  for d in "${AS_PROFILE_ROOT}/Claude" "${AS_PROFILE_ROOT}/Claude-"*; do
    [[ -d "$d" ]] || continue
    local tag
    tag=$("$AS_BIN_BASENAME" "$d" | "$AS_BIN_SED" 's/^Claude-//; s/^Claude$/primary/')
    local size
    size=$("$AS_BIN_DU" -sh "$d" 2>/dev/null | "$AS_BIN_AWK" '{print $1}')
    printf '  %-12s %s  (%s)\n' "$tag" "$d" "${size:-?}"
  done
  printf '\n'
}

# ---- swap (3-step: clone-prefs → quit → launch; H-1, M-15) ---------------

# Script-level state used by the M-15 cleanup trap.
__SWAP_IN_PROGRESS="false"
__SWAP_TARGET_TAG=""

_swap_cleanup_on_interrupt() {
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-mirror) skip_mirror="true"; shift ;;
      --no-handoff) skip_handoff="true"; shift ;;
      --force) force="true"; shift ;;
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
    --no-mirror              skip auto-clone-prefs (default: auto-mirror primary→target)
    --no-handoff             skip handoff-bridge capture (default: capture)
    --note "<text>"          optional operator-supplied note recorded in SWAP_HANDOFF.md
                              (240 char max; not auto-redacted — operator's responsibility)
    --force                  swap even when the target's profile is recorded on
                              another account (MISMATCH; see 'identity')
EOF
    return 1
  fi

  # H-1: Validate tag before any FS access.
  validate_tag "$target_tag"

  # #6: check the account the target's profile records before anything else:
  # before the handoff capture and before the M-15 trap, so a MISMATCH
  # refusal (--force overrides) has no side effect at all and leaves the
  # running instances alone. unknown proceeds with a hint.
  identity_gate "$target_tag" "$force" swap

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
      # No instance running — fallback: assume operator is swapping from a
      # cold-start; use "primary" as nominal source so handoff still records
      # the swap event. Operator can override via --note if needed.
      running_tag_for_handoff="primary"
    fi
    capture_handoff "$running_tag_for_handoff" "$target_tag" "$operator_note" 2>&1 | "$AS_BIN_SED" 's/^/    /'
    printf '\n'
  fi

  # ---- Step 1: Auto-mirror prefs primary → target ------------------------
  # Skip if target IS primary (nothing to mirror to) or --no-mirror was set.
  # Direction is one-way primary → target: primary is the curator of CONFIG
  # items (Mac app prefs, Extensions, MCP connectors, git-worktrees).
  if [[ "$is_primary" == "false" ]] && [[ "$skip_mirror" == "false" ]]; then
    local primary_udd
    primary_udd=$(udd_for_tag "primary")
    if [[ -d "$primary_udd" ]] && [[ -d "$target_udd" ]]; then
      # clone-prefs refuses when it cannot tell whether the target is
      # running (is_tag_running = 2). swap does not stop for that: it quits
      # every instance next, so it skips the mirror, says why, and goes on.
      local mirror_rs=0
      is_tag_running "$target_tag" || mirror_rs=$?
      if [[ $mirror_rs -eq 2 ]]; then
        warn "Skipping auto-mirror: cannot tell whether '${target_tag}' is running (an instance's tag is unknown; see 'account-switcher list'). The swap continues."
      else
        info "Auto-mirroring primary's user-facing prefs → ${target_tag}..."
        cmd_clone_prefs "primary" "$target_tag" 2>&1 | "$AS_BIN_SED" 's/^/    /'
        printf '\n'
      fi
    elif [[ ! -d "$target_udd" ]]; then
      info "Skipping auto-mirror (target dir doesn't exist yet; first launch will create it)"
    fi
  fi

  # ---- Step 2: Quit current Mac app instance(s) --------------------------
  quit_all_claude

  # ---- Step 3: Launch target Mac app instance ---------------------------
  info "Launching '${target_tag}' Mac app instance..."
  info "  user-data-dir: ${target_udd}"

  # #8: any main process still listed after the quit, so the wait at the end
  # takes only the instance this swap opens.
  local pre_pids
  pre_pids="$(get_claude_pids)"

  if [[ "$is_primary" == "true" ]]; then
    "$AS_BIN_OPEN" -n -a "Claude"
  else
    "$AS_BIN_OPEN" -n -a "Claude" --args --user-data-dir="${target_udd}"
  fi

  ok "Swapped to '${target_tag}'. Bridged Code billing will follow ${target_tag}'s account auth."

  printf '%s\n' "$target_tag" > "$STATUSLINE_MARKER"
  printf '[%s] APP_SWAP target=%s udd=%s first_launch=%s mirror=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$target_tag" "$target_udd" "$first_launch" \
    "$([ "$skip_mirror" == "false" ] && echo "yes" || echo "no")" \
    >> "$SWAP_LOG"

  if [[ "$first_launch" == "true" ]]; then
    info ""
    info "After login, future 'swap ${target_tag}' invocations skip the login prompt."
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
  # Restore each snapshotted item back to target_udd, then remove snapshot dir.
  if [[ "$__CLONE_PREFS_SUCCEEDED" != "true" ]] && [[ -d "$__CLONE_PREFS_SNAPSHOT_DIR" ]]; then
    warn "Restoring '${__CLONE_PREFS_TARGET_UDD}' from clone-prefs snapshot due to interruption/failure..."
    local item
    for item in "${__CLONE_PREFS_SNAPSHOTTED[@]}"; do
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

  info "Cloning user-facing prefs: ${source_tag} → ${target_tag}"
  info "  source: ${source_udd}"
  info "  target: ${target_udd}"

  # M-10: Pre-clone scan source claude_desktop_config.json for sensitive keys.
  # If Anthropic ever stores OAuth/device/secret material in this file in a
  # future Mac-app version, refuse to mirror it across accounts.
  if [[ -f "${source_udd}/claude_desktop_config.json" ]]; then
    if "$AS_BIN_GREP" -qiE '"(oauth|tokenCache|accessToken|refreshToken|clientSecret|authToken|sessionToken|deviceId|deviceToken|bearerToken)"' "${source_udd}/claude_desktop_config.json" 2>/dev/null; then
      die "Source claude_desktop_config.json contains sensitive-looking keys (oauth/tokenCache/accessToken/etc.). Refusing to mirror credentials across accounts (M-10). Manual review required."
    fi
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

  local items_to_clone=("claude_desktop_config.json" "Claude Extensions" "Claude Extensions Settings" "git-worktrees.json")
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

  # 1. claude_desktop_config.json
  if [[ -f "${source_udd}/claude_desktop_config.json" ]]; then
    "$AS_BIN_CP" "${source_udd}/claude_desktop_config.json" "${target_udd}/claude_desktop_config.json"
    mirrored+=("claude_desktop_config.json")
  else
    skipped+=("claude_desktop_config.json (source missing)")
  fi

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
  for m in "${mirrored[@]}"; do
    ok "Mirrored: ${m}"
  done

  printf '[%s] CLONE_PREFS source=%s target=%s mirrored=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$source_tag" "$target_tag" \
    "$(IFS=,; echo "${mirrored[*]}")" \
    >> "$SWAP_LOG"

  printf '\n'
  if [[ ${#mirrored[@]} -eq 0 ]]; then
    warn "Nothing was mirrored. Source dir may be missing the expected files."
    [[ ${#skipped[@]} -gt 0 ]] && warn "Skipped: ${skipped[*]}"
    return 1
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
      quit_all_claude
      printf '[%s] QUIT_ALL\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SWAP_LOG"
      ;;
    *)
      # H-1: Reject malformed tags even though per-tag quit is not yet
      # implemented (avoids leaking implementation details via error path).
      validate_tag "$target"
      die "Per-tag quit not yet supported (would require PID-to-udd matching). Use 'quit --all' or Cmd+Q in the target window."
      ;;
  esac
}

# ---- status --------------------------------------------------------------

cmd_status() {
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
# pinned and recorded ids, on stdout only.
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
    printf '[%s] QUIT_ALL\n' "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SWAP_LOG" || :
  fi
}

# After an interrupt or an unexpected stop during --quit-others' quit: what
# was listed and what is still running. Nothing was opened yet.
_signin_quit_report() {
  local now
  now="$(get_claude_pids)"
  now="${now//$'\n'/ }"
  printf 'Interrupted while quitting. Listed before the quit: PIDs%s. Still running: %s. Nothing was signed in.\n' \
    "${SG_CONFIRMED% }" "${now:-none}"
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
  # the listed PIDs, quit through quit_all_claude, check nothing is left.
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
      if ! ( quit_all_claude ); then
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
                           1. Auto-clone-prefs primary→tgt (if tgt is non-primary)
                           2. Quit current Claude instance(s)
                              (graceful 15s → SIGTERM → SIGKILL via PID list)
                           3. Launch target instance and bring its window to
                              the front
                         Result: identity display + Mac-app billing align with tgt.
                         Workspace (~/.claude/) stays bidirectional.
                         Runs the account check (see identity) first: on a
                         MISMATCH it refuses before quitting or writing
                         anything. Ends with the same line as launch.
                         Flags:
                           --no-mirror       skip step 1
                           --force           swap even on a MISMATCH

  launch <tag> [--force] ADDITIVE launch. Spawns target instance WITHOUT
                         quitting others. Use for running both side-by-side.
                         Runs the account check (see identity) first: on a
                         MISMATCH it refuses and opens nothing; --force
                         launches anyway, with the warning.
                         Then waits up to ${NEW_INSTANCE_WAIT_S} s for the new instance, brings
                         its window to the front by PID, and ends with:
                           tag=<tag> pid=<pid> front=yes|no
                           account=<"label"|unrecognized|unknown>
                           status=<match|MISMATCH|unknown>
                         (one line). front=no adds "Switch with Cmd-backtick
                         or the Dock". pid=unknown: no new instance
                         appeared in time; the launch still happened.

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
                         target running. --timeout 30-1800 (default ${SIGNIN_TIMEOUT_DEFAULT});
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
                         --show-ids prints the ids too, on stdout. Reads
                         only the profile's config.json (no cookies, Local
                         Storage, keychain items or tokens).

  identity pin <tag> [--yes] [--force]
                         Record the account <tag>'s profile holds now as the
                         account it must hold ([identity] in config.toml).
                         Check the window's account menu first. Refuses when
                         that account is already pinned to another tag,
                         unless --force.

  clone-prefs [src tgt]  Mirror Mac-app user-facing prefs from src to tgt.
                         Default: clone-prefs primary backup. Mirrors:
                           - claude_desktop_config.json (sidebar mode,
                             trusted folders, permissions, web search)
                             Pre-scanned for sensitive keys; refuses if any
                             oauth/token-shaped key present (M-10).
                           - Claude Extensions/ (installed Anthropic exts)
                           - Claude Extensions Settings/
                           - git-worktrees.json (MERGED with target's existing)
                         Snapshot-rollback semantics: target snapshotted before
                         apply; restored on failure (M-7).
                         Refuses if target instance is running (re-checked
                         after snapshot, before apply, M-11).

  quit [--all]           Quit all running Claude instances:
                           - osascript graceful quit
                           - 15s wait
                           - SIGTERM via PID list
                           - SIGKILL via PID list (last resort)
                           - Final check by PID list (die if alive).

  list (or instances)    Show running Claude desktop app instances, each with
                         its tag and how the tag was found (via=argv: its
                         --user-data-dir; via=flagless: the only instance
                         without one, primary; via=lsof: the profile folder
                         it holds open), or tag=unknown via=none when it
                         cannot be determined; then on-disk profile dirs
                         with sizes.

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

NOTES:
  - Each non-primary user-data-dir is created on first launch, which shows the
    app's sign-in screen; use \`signin <tag>\` to sign it in and check the result.
  - "primary" maps to the default ~/Library/Application Support/Claude — preserves
    existing chat history, MCP connections, plugins. Don't rename this dir.
  - Multiple instances can run simultaneously. Each has its own dock icon (same
    Claude.app binary; different in-memory state).
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
