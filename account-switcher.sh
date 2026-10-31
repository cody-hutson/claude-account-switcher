#!/usr/bin/env bash
# account-switcher.sh - Claude desktop app account switcher
#
# Swap, launch, and manage multiple Claude desktop app accounts via the
# Electron --user-data-dir flag. An earlier CLI-mutation approach was
# removed after a security review; only the Mac-app launcher surface ships.
#
# Subcommands: swap | launch | identity | clone-prefs | quit | list | status | config | add-account | version | help
#
# Primitives: bash + jq + open + osascript. No Python, no node.
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
  local danger=" KILL SECURITY OSASCRIPT OPEN PS LSOF "
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
}

AS_SEAM_BINS="AWK BASENAME CAT CHMOD COMMAND CP CUT DATE DU GIT GREP HEAD INSTALL JQ KILL LSOF MKTEMP MV OPEN OSASCRIPT PS PYTHON3 RM RSYNC SECURITY SED SLEEP TAIL TR WC"
AS_SEAM_ROOTS="STORE CLAUDE_JSON PROFILE_ROOT APP_BUNDLE UPDATER_CACHE APP_LOG_DIR"
if [[ "${AS_TEST_MODE:-0}" != "1" ]]; then
  # Production: the environment is ignored.
  for _n in $AS_SEAM_BINS; do unset "AS_BIN_${_n}"; done
  for _n in $AS_SEAM_ROOTS; do unset "AS_${_n}"; done
  unset _n AS_TEST_ROOT AS_FAKES_DIR AS_KEYCHAIN_SVC
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
: "${AS_BIN_LSOF:=/usr/sbin/lsof}"
: "${AS_BIN_MKTEMP:=/usr/bin/mktemp}"
: "${AS_BIN_MV:=/bin/mv}"
: "${AS_BIN_OPEN:=/usr/bin/open}"
: "${AS_BIN_OSASCRIPT:=/usr/bin/osascript}"
: "${AS_BIN_PS:=/bin/ps}"
: "${AS_BIN_PYTHON3:=/usr/bin/python3}"
: "${AS_BIN_RM:=/bin/rm}"
: "${AS_BIN_RSYNC:=/usr/bin/rsync}"
: "${AS_BIN_SECURITY:=/usr/bin/security}"
: "${AS_BIN_SED:=/usr/bin/sed}"
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
  AS_BIN_HEAD AS_BIN_INSTALL AS_BIN_JQ AS_BIN_KILL AS_BIN_LSOF AS_BIN_MKTEMP AS_BIN_MV \
  AS_BIN_OPEN AS_BIN_OSASCRIPT AS_BIN_PS AS_BIN_PYTHON3 \
  AS_BIN_RM AS_BIN_RSYNC AS_BIN_SECURITY AS_BIN_SED AS_BIN_SLEEP AS_BIN_TAIL \
  AS_BIN_TR AS_BIN_WC
readonly AS_STORE AS_CLAUDE_JSON AS_PROFILE_ROOT AS_APP_BUNDLE AS_UPDATER_CACHE \
  AS_APP_LOG_DIR AS_KEYCHAIN_SVC

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

# ---- launch (additive; H-1) ----------------------------------------------

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

  if [[ "$tag" == "primary" ]] || [[ "$tag" == "default" ]]; then
    "$AS_BIN_OPEN" -n -a "Claude"
  else
    "$AS_BIN_OPEN" -n -a "Claude" --args --user-data-dir="$udd"
  fi

  ok "Launched. Look for the new Claude window."

  printf '%s\n' "$tag" > "$STATUSLINE_MARKER"

  printf '[%s] LAUNCH tag=%s udd=%s first_launch=%s\n' \
    "$("$AS_BIN_DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$udd" "$first_launch" \
    >> "$SWAP_LOG"

  if [[ "$first_launch" == "true" ]]; then
    info ""
    info "Next: in the new Claude window, log in with the account for this profile."
    info "After login, the user-data-dir will hold that account's auth + chat + plugins."
    info "Future 'launch ${tag}' invocations will skip the login prompt."
  fi
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
                           3. Launch target instance
                         Result: identity display + Mac-app billing align with tgt.
                         Workspace (~/.claude/) stays bidirectional.
                         Runs the account check (see identity) first: on a
                         MISMATCH it refuses before quitting or writing
                         anything.
                         Flags:
                           --no-mirror       skip step 1
                           --force           swap even on a MISMATCH

  launch <tag> [--force] ADDITIVE launch. Spawns target instance WITHOUT
                         quitting others. Use for running both side-by-side.
                         Runs the account check (see identity) first: on a
                         MISMATCH it refuses and opens nothing; --force
                         launches anyway, with the warning.

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
                         (isolated; first launch of each tag prompts for OAuth login.)

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

  # Cleanup
  account-switcher quit --all                 # quit all instances

NOTES:
  - Each non-primary user-data-dir is created on first launch; first launch of
    a new tag prompts for OAuth login.
  - "primary" maps to the default ~/Library/Application Support/Claude — preserves
    existing chat history, MCP connections, plugins. Don't rename this dir.
  - Multiple instances can run simultaneously. Each has its own dock icon (same
    Claude.app binary; different in-memory state).
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
