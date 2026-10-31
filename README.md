# Claude Code Account Switcher

One-command swap between Anthropic Claude Code accounts on macOS. Billing
isolation lives in per-account `--user-data-dir` Electron user-data-dirs;
workspace continuity is preserved by the shared `~/.claude/` tree that holds
session JSONLs, skills, hooks, plugins, MCP, and settings.

## Why this exists

Anthropic's Mac desktop app does not expose a built-in account switcher.
Each Anthropic subscription (Pro / Max-5x / Max-20x / Enterprise) has its
own usage envelope; anyone who needs to fluidly swap between billing
identities benefits from a small, audited launcher script that quits the
current app instance and re-launches against a different `--user-data-dir`.

This tool is intentionally minimal: bash + jq + `open` + `osascript`. No
Python. No Node. No tokens ever touch disk under this script's authority.
OAuth state lives in the macOS keychain (CLI surface) or Electron
`safeStorage` per `--user-data-dir` (Mac-app surface).

## Install

### Prerequisites

- macOS 12 (Monterey) or later
- bash 5+ (the system `/bin/bash` 3.2 also works, but 5+ is recommended)
- `jq` (`brew install jq`)
- `gh` CLI (optional — only required for the `SWAP_HANDOFF.md` enrichment block)
- Anthropic Claude Code desktop app installed at `/Applications/Claude.app`

### Install steps

```bash
git clone https://github.com/cody-hutson/claude-account-switcher ~/claude-account-switcher
cd ~/claude-account-switcher
bash install.sh
```

`install.sh` is idempotent — safe to re-run. It performs:

1. Creates `~/.claude/account-switcher/` if not exists
2. Copies `account-switcher.sh` to `~/.claude/account-switcher/account-switcher.sh` (overwrite — source of truth)
3. Copies `commands/account-switcher.md` to `~/.claude/commands/account-switcher.md` (registers the `/account-switcher` slash command)
4. Copies `config.toml.template` to `~/.claude/account-switcher/config.toml` ONLY if the runtime instance does not exist (preserves your customization across re-installs)
5. Verifies install by invoking `account-switcher status`

### Verify

Check that the installed files match the repo you installed from:

```bash
cd ~/claude-account-switcher
bash install.sh --check
```

The check compares each installed file byte for byte with its copy in the
repo and prints both versions:

```
Installed version: <version>
Repo version:      <version> (commit <sha>)

  ok        ~/.claude/account-switcher/account-switcher.sh
  ok        ~/.claude/commands/account-switcher.md

Install matches this repo.
```

It exits `0` when everything matches. It exits `1` and names the problem
when an installed file **differs**, is **missing**, or is a **leftover** — a
file in `~/.claude/account-switcher/` that this version does not install,
usually from an older install. Remove a leftover with `trash <path>`; the
installer never deletes files. Exit `2` means the check could not run (run it
from the repo root).

The check is read-only. It skips your runtime state and never opens it:
`config.toml`, `swap-history.log`, `swap-history.log.1`, `.statusline-marker`,
`prefs-sync.json` and `.DS_Store`.

To see which version is installed without the repo:

```bash
~/.claude/account-switcher/account-switcher.sh version
```

To confirm the switcher runs, in a fresh Claude Code terminal session:

```
/account-switcher help
```

## Updating

Fixes ship to `main`. To update an existing install, pull, re-run the
installer, then check the result:

```bash
cd ~/claude-account-switcher
git pull
bash install.sh
bash install.sh --check
```

`install.sh` overwrites `account-switcher.sh` and the `/account-switcher` slash
command with the new versions, but **preserves your runtime
`~/.claude/account-switcher/config.toml`** — the template is only copied on a
first install. Your account mappings, notification channels, and handoff
settings survive updates untouched.

Because your `config.toml` is never rewritten, settings added in a newer
version show up only in `config.toml.template`. Until you add them, the
switcher uses their defaults. After updating, compare the two and copy across
any section you want:

```bash
diff ~/claude-account-switcher/config.toml.template ~/.claude/account-switcher/config.toml
```

`bash install.sh --check` then confirms the update landed. If it lists a
leftover, that file came from an older install and is no longer used.

## Quick start

```bash
# Show CLI identity (~/.claude.json + keychain subscription)
account-switcher status

# Register a tag → email mapping in [accounts] of the runtime config.toml.
# Run this after first-launch login under the tagged user-data-dir.
account-switcher add-account backup you@example.com

# List configured tags + running instances
account-switcher list

# SEAMLESS swap: clone prefs from current → target, quit current, launch target
account-switcher swap backup

# ADDITIVE launch: spawn target without quitting others (side-by-side mode)
account-switcher launch backup

# Quit all running Claude instances (graceful → SIGTERM → SIGKILL via PID list)
account-switcher quit --all
```

## How `swap` works internally (4 steps)

**Step 0 — Pre-flight validation.** Validates the target tag against
`^[a-z0-9-]{1,32}$`; refuses to proceed when the target user-data-dir is
the same as the current. Captures the active PID list at function entry.

**Step 1 — clone-prefs (idempotent prefs mirror).** Mirrors Mac-app
user-facing prefs from `~/Library/Application Support/Claude` (current) to
`~/Library/Application Support/Claude-<tag>` (target). Snapshot-rollback
semantics: ≤1 backup retained per target. Prefs include theme, window
state, sidebar layout — NOT OAuth state (per-user-data-dir Electron
safeStorage is isolated by design).

**Step 2 — handoff capture.** Writes a privacy-safe `SWAP_HANDOFF.md`
(metadata + pointers only — no chat text, no file contents, no tokens) so the
next session in either account can resume coherently. By default it lands in
`~/.claude/account-switcher/`; point `[swap_handoff].workspace_dir` elsewhere
to relocate it. When `[swap_handoff].git_root` is set (or the current directory
is a git repo) it summarizes recent commits + uncommitted files; when
`[swap_handoff].gh_repo` is set it also captures recent issue + PR activity.
All of this is optional — skip it per-swap with `--no-handoff`.

**Step 3 — quit + relaunch.** Quits all running Claude instances (graceful
→ SIGTERM → SIGKILL via the tracked PID list), then launches the target via
`open -n -a Claude.app --args --user-data-dir "~/Library/Application
Support/Claude-<tag>"`. The Electron parent process loads from the tagged
user-data-dir; its OAuth state is isolated from every other tagged dir.

## What's shared automatically across accounts

| Surface | Path | Why shared |
|---|---|---|
| Local Code session JSONLs | `~/.claude/projects/<cwd>/` | `claude --continue` works cross-instance; conversations are filesystem-rooted |
| Skills | `~/.claude/skills/` | Operator-installed capability surfaces |
| Hooks | `~/.claude/hooks/` | PreToolUse / PostToolUse / Stop / UserPromptSubmit |
| Plugins | `~/.claude/plugins/` | Operator-installed plugin capabilities |
| MCP servers | `~/.claude/mcp.json` or `~/.claude.json` MCP section | Tool-call surface |
| Settings | `~/.claude/settings.json` | Permissions, model defaults, hook config |

## What's strictly per-account (intentional isolation)

| Surface | Path | Why isolated |
|---|---|---|
| OAuth tokens | Inside `--user-data-dir`'s Electron `safeStorage` | Billing identity isolation |
| Mac app preferences | `~/Library/Application Support/Claude-<tag>/Preferences` | Per-app-instance UI state |
| Cloud chat sidebar | Server-side per Anthropic | Anthropic owns the cloud sidebar source |
| Subscription state | Server-side per Anthropic | Bound to OAuth identity |

## Configuration

The runtime config lives at `~/.claude/account-switcher/config.toml`. The
template ships at `config.toml.template` in this repo and is copied to the
runtime path only on first install (your state preserved on re-install — see
§ Updating).

Key sections:

- `[accounts]` — map of tag → `{ label, profile_email }`. Populate via
  `account-switcher add-account <tag> <email> [label]` after first-launch
  login under the tagged user-data-dir.
- `[notifications]` — channels for swap-success awareness signals
  (statusline / log / stderr).
- `[swap_handoff]` — optional handoff tuning (all default-safe):
  - `workspace_dir` — where `SWAP_HANDOFF.md` is written (default
    `~/.claude/account-switcher/`).
  - `git_root` — repo whose commits + uncommitted files are summarized
    (default: current dir if it's a git repo, else skipped).
  - `gh_repo` — `owner/repo` to enrich the handoff with recent issue + PR
    activity (default: skipped).

## Profile tag conventions

- `primary` (default) → `~/Library/Application Support/Claude` — preserves the existing chat history of the workspace's primary account
- `<tag>` → `~/Library/Application Support/Claude-<tag>` — isolated; first launch prompts login

Tag validation regex: `^[a-z0-9-]{1,32}$`. Whitespace, uppercase, and
non-ASCII characters are rejected (prevents shell injection in the
`--user-data-dir` path argument).

## Subcommand reference

| Subcommand | Action |
|---|---|
| `swap <tag> [flags]` | Quit current + launch target. Flags: `--no-mirror` (skip clone-prefs), `--no-handoff` (skip SWAP_HANDOFF.md capture), `--note "<text>"` (context for the handoff, max 240 chars) |
| `launch <tag>` | ADDITIVE launch. Spawns target without quitting others; use for side-by-side mode. |
| `clone-prefs [src] [tgt]` | Mirror Mac-app prefs src → tgt with snapshot-rollback. Defaults to `primary → <last-target>` when invoked without args. |
| `quit [--all]` | Quit running Claude instances. `--all` quits every instance; bare `quit` quits only the current foreground instance. Graceful → SIGTERM → SIGKILL escalation. |
| `list` (or `instances`) | Show running instances + configured profile dirs. |
| `status` | Show CLI identity (`~/.claude.json` + keychain subscription). |
| `config show` | Display the active config.toml. |
| `config get <key>` | Read a single config.toml key (supports flat keys and one-level `table.key` form). |
| `add-account <tag> <email> [label]` | Register a tag → email mapping in `[accounts]` of the runtime config.toml. Run after first-launch login under the tagged user-data-dir. |
| `version` (or `--version`) | Print the installed script's version. To check the install against the repo, run `bash install.sh --check` from the clone (see § Verify). |

## Security & input validation

- Tag regex `^[a-z0-9-]{1,32}$` rejects shell-injection vectors in the `--user-data-dir` path argument.
- Email validation in `add-account` is intentionally lightweight (not RFC-compliant): refuses whitespace, requires a `@` followed by a `.`.
- `quit` uses PID-based tracking (`/bin/kill -0` per PID) rather than `pgrep -f` argv-pattern matching. The pattern-match approach is brittle when Anthropic ships new Electron flags; PID tracking is kernel-truth.
- No plaintext tokens persist on disk under this script's authority. OAuth state lives in the macOS keychain (CLI surface) or Electron `safeStorage` per `--user-data-dir` (Mac-app surface).
- The `SWAP_HANDOFF.md` capture applies redaction patterns to commit messages, branch names, and gh issue/PR titles before write: `eyJ[A-Za-z0-9_.-]{20,}` (JWT-like), `sk-ant-[A-Za-z0-9_-]{20,}` (Anthropic API key prefix), `[A-Za-z0-9_-]{60,}` (long token-like sequences) get replaced with `[REDACTED-TOKEN-LIKE]` before write.

## Safety

This script keeps its file operations tightly scoped. Specifically, it:

- Does NOT invoke `rm` / `trash` / `unlink` outside the directories it owns.
- Does NOT touch `.git/` directories of any repo it reads (it only runs read-only `git log` / `git status` against the configured `git_root`).
- Does NOT read or exfiltrate credentials from `~/.ssh`, `~/.aws`, or `~/.config/gh`.
- Does NOT write to `~/.claude/settings.json`, `~/.claude/hooks/*`, or other tooling-config files.
- Confines its writes to `~/.claude/account-switcher/` (and the configurable `[swap_handoff].workspace_dir`) and `~/Library/Application Support/Claude*/`.

## Uninstall

```bash
# Remove the runtime install (uses macOS trash mechanism so files are recoverable)
trash ~/.claude/account-switcher/
trash ~/.claude/commands/account-switcher.md

# Optional: remove the source clone
trash ~/claude-account-switcher/
```

Per-account user-data-dirs at `~/Library/Application Support/Claude-<tag>`
are NOT removed by the uninstall — they hold per-account OAuth state and
Mac-app preferences. Remove them manually only if you intend to fully
deauthorize the tagged identity.

## Contributing / Bug reports

Bug reports and feature ideas are welcome — open an issue using the templates.
You're also free to **fork** the project and adapt it under the MIT license.

This is a single-maintainer project: you can propose changes via a fork PR, but
the maintainer is the only merger (there are no other write collaborators).
Please report **security issues privately** — see [SECURITY.md](SECURITY.md), not
a public issue. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guidelines.

## License

MIT — see [LICENSE](LICENSE).

## Provenance

This tool was extracted and generalized from the maintainer's personal Claude
Code toolkit and refactored to be operator-agnostic — no account-, machine-,
or workspace-specific assumptions are baked into what ships here. The handoff
workspace is configurable (see `[swap_handoff]` in `config.toml.template`) so
the tool adapts to your own layout rather than assuming one.
