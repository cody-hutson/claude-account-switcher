#!/usr/bin/env bash
# account-switcher.sh - Claude desktop app account switcher
#
# Swap, launch, and manage multiple Claude desktop app accounts via the
# Electron --user-data-dir flag. An earlier CLI-mutation approach was
# removed after a security review; only the Mac-app launcher surface ships.
#
# Subcommands: swap | launch | clone-prefs | quit | list | status | config | add-account | version | help
#
# Primitives: bash + jq + open + osascript. No Python, no node.
# No tokens are persisted on disk by this script. OAuth state lives in the
# macOS keychain (CLI surface, when used) or Electron safeStorage per
# user-data-dir (Mac app surface).

set -euo pipefail

# ---- Constants & paths ---------------------------------------------------

# Bump on every change to this script. `install.sh --check` reads this line
# from both the repo copy and the installed copy (without running either), so
# keep it a single `readonly VERSION="..."` assignment.
readonly VERSION="11.0.0-dev"

readonly STORE="${HOME}/.claude/account-switcher"
readonly CLAUDE_JSON="${HOME}/.claude.json"
readonly KEYCHAIN_SVC="Claude Code-credentials"
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
  total=$(/usr/bin/wc -l < "$SWAP_LOG" 2>/dev/null | /usr/bin/tr -d ' ')
  [[ -n "$total" ]] || return 0
  if [[ "$total" -gt 1100 ]]; then
    local tmp
    tmp="$(/usr/bin/mktemp)"
    /usr/bin/tail -n 1000 "$SWAP_LOG" > "$tmp"
    /bin/mv -f "$SWAP_LOG" "${SWAP_LOG}.1"
    /bin/mv -f "$tmp" "$SWAP_LOG"
    /bin/chmod 600 "$SWAP_LOG"
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
    /usr/bin/awk -v table="[${table}]" -v sk="${subkey}" '
      BEGIN { in_t = 0 }
      /^\[/  { in_t = ($0 == table); next }
      in_t && $0 ~ "^"sk"[[:space:]]*=" {
        sub("^"sk"[[:space:]]*=[[:space:]]*", ""); sub("[[:space:]]*$", "")
        gsub("^\"|\"$", ""); print; exit
      }
    ' "$file"
  else
    /usr/bin/awk -v sk="${key}" '
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
  /usr/bin/awk -v email="$email" '
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
  /usr/bin/awk -v tag="$tag" '
    /^\[accounts\]/ { in_a = 1; next }
    /^\[/           { in_a = 0 }
    in_a && $0 ~ "^"tag"[[:space:]]*=" { print "FOUND"; exit }
  ' "$CONFIG_FILE" | /usr/bin/grep -qx "FOUND"
}

# ---- Process helpers (M-12) ----------------------------------------------

# Returns newline-separated PIDs of running Claude.app main processes
# (excluding helpers/grep self-matches). Used in place of `pkill -f` to
# eliminate argv-substring overmatch.
get_claude_pids() {
  /bin/ps -axo pid,args 2>/dev/null \
    | /usr/bin/grep "Claude.app/Contents/MacOS/Claude" \
    | /usr/bin/grep -v "Claude Helper" \
    | /usr/bin/grep -v grep \
    | /usr/bin/awk '{print $1}'
  # F2-bis: force return 0. When no Claude
  # process matches, the first grep exits 1; pipefail propagates it. With
  # set -euo pipefail, var=$(get_claude_pids) then triggers script exit
  # (bash 3.2.57 quirk: pipefail-amplified pipeline failure escapes the
  # assignment-exempt set -e rule that protects var=$(false) and
  # var=$(fn_returning_1)). Callers detect "no Claude running" via empty
  # stdout, not via exit status — this return preserves that contract.
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
    /bin/kill "-${sig}" "$pid" 2>/dev/null || true
  done <<< "$pids"
}

# Returns 0 if a Claude.app instance is currently running with the given
# user-data-dir argv. Used by clone-prefs and as race-detection.
is_instance_running_for_udd() {
  local udd="$1"
  /bin/ps -axo args 2>/dev/null \
    | /usr/bin/grep "Claude.app/Contents/MacOS/Claude" \
    | /usr/bin/grep -v "Claude Helper" \
    | /usr/bin/grep -v grep \
    | /usr/bin/grep -F -q -- "--user-data-dir=${udd}"
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
    printf '%s' "${HOME}/Library/Application Support/Claude"
  else
    printf '%s' "${HOME}/Library/Application Support/Claude-${tag}"
  fi
}

# ---- detect_running_tag --------------------------------------------------

# Returns the tag of the currently-running Claude.app main process by
# parsing its --user-data-dir argv, or empty string if no instance is
# running. Used by cmd_swap_app to determine the SOURCE account for the
# handoff capture (the currently-active account at swap time, regardless
# of swap direction).
#
# Behavior:
#   - Claude.app main process WITH --user-data-dir=<path> argv → parse the
#     path and reverse-lookup the tag from its basename (Claude→primary,
#     Claude-<tag>→<tag>).
#   - Claude.app main process WITHOUT --user-data-dir argv → primary
#     (Mac app's OS-default udd is the unflagged primary path).
#   - No Claude.app main process running → empty string; caller decides
#     fallback (typically: skip session-index mirror).
detect_running_tag() {
  local udd_arg
  udd_arg=$(/bin/ps -axo args 2>/dev/null \
    | /usr/bin/grep "Claude.app/Contents/MacOS/Claude" \
    | /usr/bin/grep -v "Claude Helper" \
    | /usr/bin/grep -v grep \
    | /usr/bin/grep -oE '\-\-user-data-dir=[^[:space:]]+' \
    | /usr/bin/sed -E 's|^--user-data-dir=||' \
    | /usr/bin/head -1 || true)

  if [[ -n "$udd_arg" ]]; then
    # Preferred: parse from argv (most accurate at moment of capture).
    local bn
    bn=$(/usr/bin/basename "$udd_arg")
    case "$bn" in
      Claude)        printf '%s' "primary"; return 0 ;;
      Claude-*)      printf '%s' "${bn#Claude-}"; return 0 ;;
    esac
  fi

  # Argv-detection failed. Two reasons this happens:
  # (1) Mac app launched without --user-data-dir flag (OS-default primary
  #     path), in which case argv genuinely doesn't carry the flag.
  # (2) Mac app WAS launched with --user-data-dir but Electron stripped it
  #     from visible argv post-launch. Empirically observed in an e2e test
  #     (reverse-swap from backup): the backup Mac app instance had no
  #     --user-data-dir in ps output despite being launched against
  #     Claude-backup. Without this fallback, the swapper incorrectly
  #     recorded handoff direction as 'primary → primary'.
  #
  # Fallback chain when argv-parse is empty:
  #   (a) If $STATUSLINE_MARKER exists, use its value (the swapper writes
  #       this after every successful swap, so it reflects the
  #       currently-active account regardless of Electron argv munging).
  #   (b) If Claude.app is running but no marker, default to primary
  #       (covers cold-start / first-ever-launch scenarios).
  #   (c) If no Claude.app running at all, return empty (caller decides).
  if /usr/bin/pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
    if [[ -f "$STATUSLINE_MARKER" ]]; then
      local marker_tag
      marker_tag=$(/bin/cat "$STATUSLINE_MARKER" 2>/dev/null | /usr/bin/head -1 | /usr/bin/tr -d '[:space:]')
      if [[ -n "$marker_tag" ]]; then
        printf '%s' "$marker_tag"
        return 0
      fi
    fi
    printf '%s' "primary"
  fi
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
  if [[ -z "$git_root" ]] && /usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_root="$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null)"
  fi

  local handoff_file="${ws_dir}/SWAP_HANDOFF.md"
  local handoff_dir="${ws_dir}"

  if [[ ! -d "$handoff_dir" ]]; then
    warn "SWAP_HANDOFF.md parent dir doesn't exist: $handoff_dir. Skipping handoff capture."
    return 0
  fi

  # ---- Compute time cutoff -----------------------------------------------
  local now_ts cutoff_ts last_swap_ts twenty_four_hours_ago
  now_ts=$(/bin/date +%s)
  twenty_four_hours_ago=$((now_ts - 86400))

  last_swap_ts=$(/usr/bin/grep '^\[' "$SWAP_LOG" 2>/dev/null \
    | /usr/bin/grep ' APP_SWAP ' \
    | /usr/bin/tail -1 \
    | /usr/bin/awk -F'[][]' '{print $2}' \
    | /usr/bin/python3 -c '
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
  cutoff_iso=$(/usr/bin/python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp($cutoff_ts).isoformat() + 'Z')")
  now_iso=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)

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
    active_branch=$(/usr/bin/git -C "${git_root}" branch --show-current 2>/dev/null || echo "")
    if [[ -z "$active_branch" ]]; then
      # Detached HEAD — report the SHA short form for traceability.
      local detached_sha
      detached_sha=$(/usr/bin/git -C "${git_root}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
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
    commits_block=$(/usr/bin/git -C "${git_root}" log \
      --since="${cutoff_iso}" \
      --pretty=format:'- `%h` %s' \
      --max-count=50 \
      2>/dev/null \
      | /usr/bin/sed -E "$redact" \
      | /usr/bin/awk "$truncate" \
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
  if [[ -n "$gh_repo" ]] && /usr/bin/command -v gh >/dev/null 2>&1; then
    issues_block=$(gh issue list \
      --repo "$gh_repo" \
      --state all \
      --limit 20 \
      --search "updated:>=${cutoff_iso%T*}" \
      --json number,state,title,updatedAt \
      --jq '.[] | "- #\(.number) [\(.state)] \(.title)"' \
      2>/dev/null \
      | /usr/bin/sed -E "$redact" \
      | /usr/bin/awk "$truncate" \
      || true)
    [[ -z "$issues_block" ]] && issues_block="(no issues touched since cutoff)"
  elif ! /usr/bin/command -v gh >/dev/null 2>&1; then
    issues_block="(gh CLI unavailable)"
  fi

  # Open PRs (current state, not historical)
  local prs_block="(gh repo not configured — see config.toml [swap_handoff].gh_repo)"
  if [[ -n "$gh_repo" ]] && /usr/bin/command -v gh >/dev/null 2>&1; then
    prs_block=$(gh pr list \
      --repo "$gh_repo" \
      --state open \
      --limit 20 \
      --json number,isDraft,title,headRefName \
      --jq '.[] | "- #\(.number) [\(if .isDraft then "DRAFT" else "OPEN" end)] \(.title) (\(.headRefName))"' \
      2>/dev/null \
      | /usr/bin/sed -E "$redact" \
      | /usr/bin/awk "$truncate" \
      || true)
    [[ -z "$prs_block" ]] && prs_block="(no open PRs)"
  elif ! /usr/bin/command -v gh >/dev/null 2>&1; then
    prs_block="(gh CLI unavailable)"
  fi

  # Uncommitted changes (point-in-time, paths only)
  local files_block="(no git workspace configured)"
  if [[ -n "$git_root" ]] && [[ -d "${git_root}/.git" ]]; then
    files_block="(no uncommitted changes)"
    local porcelain
    porcelain=$(/usr/bin/git -C "${git_root}" status --porcelain 2>/dev/null \
      | /usr/bin/awk 'NR<=50 {print "- " $0}' \
      || true)
    [[ -n "$porcelain" ]] && files_block="$porcelain"
  fi

  # Active project — peek at PORTFOLIO.md under the workspace dir if present
  local active_project="(none configured)"
  if [[ -f "${ws_dir}/PORTFOLIO.md" ]]; then
    active_project=$(/usr/bin/grep -m 1 -E '^### [A-Z]' "${ws_dir}/PORTFOLIO.md" 2>/dev/null \
      | /usr/bin/sed 's/^### //;s/[[:space:]]*$//' \
      | /usr/bin/awk "$truncate" \
      || echo "(none)")
  fi

  # ---- Write the handoff document (always overwrite; single source) ------
  local note_line=""
  if [[ -n "$operator_note" ]]; then
    # Operator-supplied note — operator's responsibility for content; we don't
    # auto-redact (operator may want to reference specific identifiers). Just
    # truncate to a reasonable length.
    local note_truncated
    note_truncated=$(printf '%s' "$operator_note" | /usr/bin/awk '{ if (length > 240) print substr($0, 1, 240) "…"; else print $0 }')
    note_line="- **Operator note:** ${note_truncated}"
  fi

  /bin/cat > "$handoff_file" <<HANDOFF_EOF
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

  /bin/chmod 644 "$handoff_file"

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
    if /bin/kill -0 "$pid" 2>/dev/null; then
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
  /usr/bin/osascript -e 'tell application "Claude" to quit' 2>/dev/null || true

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
    /bin/sleep 1
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
      /bin/kill -TERM "$p" 2>/dev/null || true
    done <<< "$alive_initial"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      /bin/kill -TERM "$p" 2>/dev/null || true
    done <<< "$fresh_pids"
    /bin/sleep 2
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
      /bin/kill -KILL "$p" 2>/dev/null || true
    done <<< "$alive_initial"
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      /bin/kill -KILL "$p" 2>/dev/null || true
    done <<< "$fresh_pids"
    /bin/sleep 1
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
    if ! /usr/bin/grep -qx "$p" <<< "$initial_pids"; then
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
  local tag="${1:-}"
  if [[ -z "$tag" ]]; then
    die "Usage: account-switcher launch <tag>  (e.g. primary, backup)"
  fi
  validate_tag "$tag"

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
    /usr/bin/open -n -a "Claude"
  else
    /usr/bin/open -n -a "Claude" --args --user-data-dir="$udd"
  fi

  ok "Launched. Look for the new Claude window."

  printf '%s\n' "$tag" > "$STATUSLINE_MARKER"

  printf '[%s] LAUNCH tag=%s udd=%s first_launch=%s\n' \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$udd" "$first_launch" \
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

  local found=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found=1
    local pid
    pid=$(printf '%s' "$line" | /usr/bin/awk '{print $1}')
    local args
    args=$(printf '%s' "$line" | /usr/bin/cut -d' ' -f2-)

    local udd tag
    if printf '%s' "$args" | /usr/bin/grep -q -- '--user-data-dir='; then
      udd=$(printf '%s' "$args" | /usr/bin/sed -E 's/.*--user-data-dir=//')
      udd=$(printf '%s' "$udd" | /usr/bin/sed -E 's/ -[-]?[a-z][a-z-]*([= ].*)?$//')
      local base
      base=$(/usr/bin/basename "$udd")
      if [[ "$base" == "Claude" ]]; then
        tag="primary"
      elif [[ "$base" == Claude-* ]]; then
        tag="${base#Claude-}"
      else
        tag="(unknown)"
      fi
    else
      udd="${HOME}/Library/Application Support/Claude"
      tag="primary"
    fi

    printf '  PID %-7s tag=%-12s data-dir=%s\n' "$pid" "$tag" "$udd"
  done < <(/bin/ps -axo pid,args 2>/dev/null \
            | /usr/bin/grep "Claude.app/Contents/MacOS/Claude" \
            | /usr/bin/grep -v "Claude Helper" \
            | /usr/bin/grep -v grep)

  if [[ $found -eq 0 ]]; then
    printf '  (no Claude desktop app instances running)\n'
  fi
  printf '\n'

  printf 'Configured profiles (under "%s"):\n' "${HOME}/Library/Application Support/"
  for d in "${HOME}/Library/Application Support/Claude" "${HOME}/Library/Application Support/Claude-"*; do
    [[ -d "$d" ]] || continue
    local tag
    tag=$(/usr/bin/basename "$d" | /usr/bin/sed 's/^Claude-//; s/^Claude$/primary/')
    local size
    size=$(/usr/bin/du -sh "$d" 2>/dev/null | /usr/bin/awk '{print $1}')
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-mirror) skip_mirror="true"; shift ;;
      --no-handoff) skip_handoff="true"; shift ;;
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
    /bin/cat <<EOF >&2
Usage: account-switcher swap <tag> [flags]
  flags:
    --no-mirror              skip auto-clone-prefs (default: auto-mirror primary→target)
    --no-handoff             skip handoff-bridge capture (default: capture)
    --note "<text>"          optional operator-supplied note recorded in SWAP_HANDOFF.md
                              (240 char max; not auto-redacted — operator's responsibility)
EOF
    return 1
  fi

  # H-1: Validate tag before any FS access.
  validate_tag "$target_tag"

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
    capture_handoff "$running_tag_for_handoff" "$target_tag" "$operator_note" 2>&1 | /usr/bin/sed 's/^/    /'
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
      info "Auto-mirroring primary's user-facing prefs → ${target_tag}..."
      cmd_clone_prefs "primary" "$target_tag" 2>&1 | /usr/bin/sed 's/^/    /'
      printf '\n'
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
    /usr/bin/open -n -a "Claude"
  else
    /usr/bin/open -n -a "Claude" --args --user-data-dir="${target_udd}"
  fi

  ok "Swapped to '${target_tag}'. Bridged Code billing will follow ${target_tag}'s account auth."

  printf '%s\n' "$target_tag" > "$STATUSLINE_MARKER"
  printf '[%s] APP_SWAP target=%s udd=%s first_launch=%s mirror=%s\n' \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$target_tag" "$target_udd" "$first_launch" \
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
        /bin/rm -rf "${__CLONE_PREFS_TARGET_UDD}/${item}" 2>/dev/null || true
        /bin/mv "${__CLONE_PREFS_SNAPSHOT_DIR}/${item}" "${__CLONE_PREFS_TARGET_UDD}/${item}" 2>/dev/null || true
      fi
    done
  fi
  if [[ -d "$__CLONE_PREFS_SNAPSHOT_DIR" ]]; then
    /bin/rm -rf "$__CLONE_PREFS_SNAPSHOT_DIR" 2>/dev/null || true
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
    /bin/rm -rf "$d" 2>/dev/null || true
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
  # (Electron may have config files open; overwrite could corrupt state).
  if is_instance_running_for_udd "$target_udd"; then
    die "Target instance ('${target_tag}') is currently running. Quit it before cloning prefs (e.g., 'account-switcher swap ${source_tag}' or Cmd+Q the target window)."
  fi

  info "Cloning user-facing prefs: ${source_tag} → ${target_tag}"
  info "  source: ${source_udd}"
  info "  target: ${target_udd}"

  # M-10: Pre-clone scan source claude_desktop_config.json for sensitive keys.
  # If Anthropic ever stores OAuth/device/secret material in this file in a
  # future Mac-app version, refuse to mirror it across accounts.
  if [[ -f "${source_udd}/claude_desktop_config.json" ]]; then
    if /usr/bin/grep -qiE '"(oauth|tokenCache|accessToken|refreshToken|clientSecret|authToken|sessionToken|deviceId|deviceToken|bearerToken)"' "${source_udd}/claude_desktop_config.json" 2>/dev/null; then
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
  snapshot_dir="$(/usr/bin/mktemp -d "${target_udd}/.clone-prefs-bak.XXXXXX")"
  /bin/chmod 700 "$snapshot_dir"

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
      /bin/mv "${target_udd}/${item}" "${snapshot_dir}/${item}"
      __CLONE_PREFS_SNAPSHOTTED+=("$item")
    fi
  done

  # M-11: Re-check target instance running BETWEEN snapshot and apply.
  # The race window is small (the operator clicks Claude in Dock during the
  # snapshot operation), but real. If a new instance launched, abort and
  # let the trap restore.
  if is_instance_running_for_udd "$target_udd"; then
    die "Target instance ('${target_tag}') started while preparing snapshot. Aborting; trap will restore from snapshot (M-11)."
  fi

  local mirrored=()
  local skipped=()

  # 1. claude_desktop_config.json
  if [[ -f "${source_udd}/claude_desktop_config.json" ]]; then
    /bin/cp "${source_udd}/claude_desktop_config.json" "${target_udd}/claude_desktop_config.json"
    mirrored+=("claude_desktop_config.json")
  else
    skipped+=("claude_desktop_config.json (source missing)")
  fi

  # 2. Claude Extensions/ (rsync without --delete; target was moved to snapshot,
  #    so no stale entries to delete).
  if [[ -d "${source_udd}/Claude Extensions" ]]; then
    /usr/bin/rsync -a "${source_udd}/Claude Extensions/" "${target_udd}/Claude Extensions/"
    mirrored+=("Claude Extensions/")
  else
    skipped+=("Claude Extensions/ (source missing)")
  fi

  # 3. Claude Extensions Settings/
  if [[ -d "${source_udd}/Claude Extensions Settings" ]]; then
    /usr/bin/rsync -a "${source_udd}/Claude Extensions Settings/" "${target_udd}/Claude Extensions Settings/"
    mirrored+=("Claude Extensions Settings/")
  else
    skipped+=("Claude Extensions Settings/ (source missing)")
  fi

  # 4. git-worktrees.json — MERGE with target's pre-snapshot version (preserves
  #    target's worktree awareness).
  if [[ -f "${source_udd}/git-worktrees.json" ]]; then
    if [[ -f "${snapshot_dir}/git-worktrees.json" ]]; then
      local merged_json
      merged_json=$(/usr/bin/jq -s \
        '(.[1].worktrees // {}) as $tgt | (.[0].worktrees // {}) as $src
         | {worktrees: ($tgt + $src),
            schemaVersion: ([.[0].schemaVersion // 1, .[1].schemaVersion // 1] | max)}' \
        "${source_udd}/git-worktrees.json" \
        "${snapshot_dir}/git-worktrees.json")
      printf '%s\n' "$merged_json" > "${target_udd}/git-worktrees.json"
      local source_count target_count
      source_count=$(/usr/bin/jq -r '.worktrees | length' "${source_udd}/git-worktrees.json" 2>/dev/null || echo 0)
      target_count=$(printf '%s' "$merged_json" | /usr/bin/jq -r '.worktrees | length')
      mirrored+=("git-worktrees.json (merged: source=${source_count} → target=${target_count})")
    else
      /bin/cp "${source_udd}/git-worktrees.json" "${target_udd}/git-worktrees.json"
      mirrored+=("git-worktrees.json (copied; target had none)")
    fi
  else
    skipped+=("git-worktrees.json (source missing)")
  fi

  # All apply steps succeeded — mark complete, clean up snapshot, clear trap.
  __CLONE_PREFS_SUCCEEDED="true"
  /bin/rm -rf "$snapshot_dir"
  __CLONE_PREFS_SNAPSHOT_DIR=""
  trap - INT TERM EXIT

  local m
  for m in "${mirrored[@]}"; do
    ok "Mirrored: ${m}"
  done

  printf '[%s] CLONE_PREFS source=%s target=%s mirrored=%s\n' \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$source_tag" "$target_tag" \
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
      printf '[%s] QUIT_ALL\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SWAP_LOG"
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
  active_email=$(/usr/bin/jq -r '.oauthAccount.emailAddress // "(none)"' "${CLAUDE_JSON}" 2>/dev/null || echo "(error)")
  active_uuid=$(/usr/bin/jq -r '.oauthAccount.accountUuid // "(none)"' "${CLAUDE_JSON}" 2>/dev/null || echo "(error)")

  printf 'CLI identity (from ~/.claude.json):\n'
  printf '  email:        %s\n' "$active_email"
  printf '  accountUuid:  %s\n' "$active_uuid"

  # Subscription type from keychain (single Claude Code-credentials entry,
  # shared across all CLI invocations regardless of which Mac app instance
  # spawned them).
  local kc_blob
  if kc_blob=$(/usr/bin/security find-generic-password -s "${KEYCHAIN_SVC}" -w 2>/dev/null); then
    local sub rate
    sub=$(printf '%s' "$kc_blob" | /usr/bin/jq -r '.claudeAiOauth.subscriptionType // "(unknown)"')
    rate=$(printf '%s' "$kc_blob" | /usr/bin/jq -r '.claudeAiOauth.rateLimitTier // "(unknown)"')
    printf '  subscription: %s (rate=%s)\n' "$sub" "$rate"
    unset kc_blob
  else
    printf '  subscription: (keychain unreadable)\n'
  fi

  local resolved_tag last_swap
  resolved_tag=$(resolve_tag_from_email "$active_email")
  last_swap=$(/bin/cat "$STATUSLINE_MARKER" 2>/dev/null || echo "(unset)")
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
        /bin/cat "$CONFIG_FILE"
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
    /bin/cat <<EOF >&2
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
    label="$(printf '%s' "${tag:0:1}" | /usr/bin/tr '[:lower:]' '[:upper:]')${tag:1}"
  fi

  # Reject shell metacharacters in label (slash command surface guard, M-1 layered defence).
  if [[ "$label" == *'"'* ]] || [[ "$label" == *$'\n'* ]] || [[ "$label" == *$'\r'* ]]; then
    die "Label must not contain double-quotes or newlines (got: '${label}')."
  fi

  # Ensure config file exists with [accounts] section.
  if [[ ! -f "$CONFIG_FILE" ]]; then
    /usr/bin/install -m 600 /dev/null "$CONFIG_FILE"
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
  tmp="$(/usr/bin/mktemp)"
  /usr/bin/awk -v new_entry="$new_entry" '
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

  /bin/mv -f "$tmp" "$CONFIG_FILE"
  /bin/chmod 600 "$CONFIG_FILE"

  ok "Registered account: tag=${tag} email=${email} label='${label}'"

  printf '[%s] ADD_ACCOUNT tag=%s email=%s label=%s\n' \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$tag" "$email" "$label" \
    >> "$SWAP_LOG"
}

# ---- Help ----------------------------------------------------------------

cmd_help() {
  /bin/cat <<EOF
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
                         Flags:
                           --no-mirror       skip step 1

  launch <tag>           ADDITIVE launch. Spawns target instance WITHOUT
                         quitting others. Use for running both side-by-side.

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
                           - Final pgrep verification (die if alive).

  list (or instances)    Show running Claude desktop app instances + their
                         user-data-dirs + on-disk profile dirs with sizes.

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
  # no files.
  case "${1:-}" in
    version|--version) cmd_version; return 0 ;;
  esac

  # M-13: Rotate the swap log at script entry (cheap; runs once per invocation).
  rotate_swap_log_if_needed

  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    swap)            cmd_swap_app "$@" ;;
    launch)          cmd_launch "$@" ;;
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
