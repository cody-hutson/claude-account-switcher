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

# Account check: which account each tag's profile is recorded as signed into
account-switcher identity
# Pin backup's current account as its expected one (check its window first)
account-switcher identity pin backup

# Quit all running Claude instances (graceful → SIGTERM → SIGKILL via PID list)
account-switcher quit --all
```

## How `swap` works internally (4 steps)

**Step 0 — Pre-flight validation.** Validates the target tag against
`^[a-z0-9-]{1,32}$`; refuses to proceed when the target user-data-dir is
the same as the current. Runs the account check (see § Checking each tag's
account) before anything else, so a refused swap has quit, captured and
written nothing. Captures the active PID list at function entry.

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
Then it brings the new window to the front and prints the closing line
described in the next section.

## The window in front after `launch` and `swap`

With several instances open, the window in front after a launch is not
always the new one, and work done in the wrong window runs on the wrong
account. So after `open`, `launch <tag>` and `swap <tag>` wait up to 15 s
for the new instance's process (a process for that tag that was not
running before), ask macOS to bring that process to the front, check with
`lsappinfo front` that it is in front, and end with one line:

```
tag=backup pid=4242 front=yes account="Backup" status=match
```

- `pid` is the new instance's process; `pid=unknown` means no new process
  for the tag appeared within 15 s. The launch itself still happened, and
  the command still exits `0`.
- `front=yes` means the check saw that process in front. `front=no` adds
  `Switch with Cmd-backtick or the Dock`.
- `account` and `status` come from the account check (see § Checking each
  tag's account): the label, in double quotes, of the account the profile
  is recorded as signed into (the tag's own label, or another tag's label
  on a `MISMATCH`); or `unrecognized`, or `unknown`. Labels only, never ids.

To bring the window forward it tries, in order, and stops at the first that
the check confirms: `lsappinfo setfront` for that process; an AppKit
activation of that process (through `osascript`); asking System Events to
make that process frontmost. The last one can show a one-time macOS prompt
asking to let your terminal (or Claude) control System Events; allowing it
is optional, and if you decline, that step just reads as not confirmed. It
never uses `open -a Claude` or `tell application "Claude" to activate`,
because with several instances open those can pick any of them.

## Checking each tag's account (`identity`)

Each tag is meant to stay on one account, but a profile can end up signed
into another tag's account (for example, when a sign-in that finishes in the
browser lands in the wrong instance). The app keeps the sessions sidebar
per account, so the previous account's work looks gone, and anything you do
in that window runs on the wrong account.

The switcher reads the account a profile is recorded as signed into, the
`lastKnownAccountUuid` value in `<user-data-dir>/config.json`, and compares
it with the account you pinned for that tag in `[identity]` of `config.toml`:

```bash
account-switcher identity            # one row per tag in [accounts]
account-switcher identity backup     # just one tag
```

```
TAG              EXPECTED                 CURRENT                                      STATUS
primary          "Primary"                "Primary"                                    match
backup           "Backup"                 primary's account                            MISMATCH
  fix: account-switcher signin backup; or in the 'backup' window, sign out and sign back in as "Backup"
```

- `match`: the profile is recorded as signed into the pinned account.
- `MISMATCH`: it is recorded as signed into another tag's account, or into
  an account no tag is pinned to (shown as `an unrecognized account (…1a2b)`,
  the last 4 hex digits of its id). The command exits `1`.
- `unknown`: the tag has no pin yet, or the profile's account can't be read
  (no profile folder, no `config.json`, a file that doesn't parse, or no id
  in it). `unknown` is never treated as `match`. The command exits `0`
  when no row is `MISMATCH`, and `2` when it can't run (no `config.toml`, or
  no tag in `[accounts]`).

**Pinning.** Open the tag's window, check its account menu shows the account
the tag's label names, then run `account-switcher identity pin <tag>`. It
asks before writing (`--yes` skips the question) and refuses when the tag
isn't in `[accounts]`, when the profile's account can't be read, or when the
same account is already pinned to another tag (`--force` overrides that
last one, for two tags that really share an account). A tag with no pin
reads `unknown` until you pin it.

**On launch and swap.** `launch <tag>` and `swap <tag>` run the check before
they open, quit or capture anything:

- `match` prints the tag's label and carries on.
- `unknown` carries on and prints a one-line hint naming `identity pin`.
- `MISMATCH` refuses: nothing is opened, quit or written, and every running
  instance is left alone. `--force` launches or swaps anyway and still
  prints the warning.

**Recovering from a mismatch.**

1. Run `account-switcher identity` to see which tags are affected.
2. Open the affected tag (`account-switcher launch <tag> --force`, or switch
   to its window if it is already running), sign out in the app, and sign
   back in with the account the tag's label names.
3. Run `account-switcher identity <tag>` again; it should read `match`. If
   you meant to move the tag to a different account, check the window's
   account menu and pin it again with `identity pin <tag>`.

**What the check reads.** Only the profile's `config.json`, read in place
with `jq` for that one value. It never opens cookies, Local Storage,
IndexedDB, keychain items or tokens, never copies `config.json`, and never
writes to it. Output names labels, never ids; `identity --show-ids` adds the
full ids to its rows, on stdout only. History rows read
`IDENTITY tag=<tag> status=<word>` and `IDENTITY_PIN tag=<tag>`, never an id
or a label.

**Limits.** The value is the app's *last known* account: it persists after
you sign out, so a signed-out profile still reads as its last account.
`config.json` is an undocumented app file; if a future app version changes
it, rows read `unknown` rather than `match`.

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
- `[identity]` — map of tag → the account id the tag's profile must be
  signed into, written by `account-switcher identity pin <tag>` (don't type
  ids by hand). A tag with no line here reads `unknown`. The header must be
  exactly `[identity]`. An install from before this check has no such table;
  the first `identity pin` adds it.
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
| `swap <tag> [flags]` | Quit current + launch target. Flags: `--no-mirror` (skip clone-prefs), `--no-handoff` (skip SWAP_HANDOFF.md capture), `--note "<text>"` (context for the handoff, max 240 chars), `--force` (swap even when the account check reads `MISMATCH`). Ends with the same closing line as `launch`. |
| `launch <tag> [--force]` | ADDITIVE launch. Spawns target without quitting others; use for side-by-side mode. Refuses on an account-check `MISMATCH` unless `--force`. Brings the new window to the front and ends with `tag=<tag> pid=<pid> front=yes\|no account=<label\|unrecognized\|unknown> status=<match\|MISMATCH\|unknown>`; see § The window in front. |
| `identity [<tag> \| --all] [--show-ids]` | Read-only account check: one row per tag in `[accounts]` with its expected account (label), the account its profile records, and `match`, `MISMATCH` or `unknown`. Exit `0` no MISMATCH, `1` a MISMATCH, `2` cannot run. See § Checking each tag's account. |
| `identity pin <tag> [--yes] [--force]` | Pin the account the tag's profile holds now as its expected account, in `[identity]` of config.toml. Refuses an account already pinned to another tag unless `--force`. |
| `clone-prefs [src] [tgt]` | Mirror Mac-app prefs src → tgt with snapshot-rollback. Defaults to `primary → <last-target>` when invoked without args. |
| `quit [--all]` | Quit running Claude instances. `--all` quits every instance; bare `quit` quits only the current foreground instance. Graceful → SIGTERM → SIGKILL escalation. |
| `list` (or `instances`) | Show running instances + configured profile dirs. Each instance row gives its tag and how the tag was found: `via=argv` (its `--user-data-dir`), `via=flagless` (the only instance started without one, which is primary) or `via=lsof` (the one profile folder it holds open). When none of these settles it, the row reads `tag=unknown via=none` rather than guessing `primary`. |
| `status` | Show CLI identity (`~/.claude.json` + keychain subscription). |
| `config show` | Display the active config.toml. |
| `config get <key>` | Read a single config.toml key (supports flat keys and one-level `table.key` form). |
| `add-account <tag> <email> [label]` | Register a tag → email mapping in `[accounts]` of the runtime config.toml. Run after first-launch login under the tagged user-data-dir. |
| `version` (or `--version`) | Print the installed script's version. To check the install against the repo, run `bash install.sh --check` from the clone (see § Verify). |

## Security & input validation

- Tag regex `^[a-z0-9-]{1,32}$` rejects shell-injection vectors in the `--user-data-dir` path argument.
- Email validation in `add-account` is intentionally lightweight (not RFC-compliant): refuses whitespace, requires a `@` followed by a `.`.
- `quit` uses PID-based tracking (`/bin/kill -0` per PID) rather than `pgrep -f` argv-pattern matching. The pattern-match approach is brittle when Anthropic ships new Electron flags; PID tracking is kernel-truth.
- Every running-instance check (`list`, `quit`, `clone-prefs`, the swap handoff's source, and the wait for the new instance after `launch` and `swap`) uses one matcher: a process is a Claude instance only when its first argument (argv[0]) is exactly `/Applications/Claude.app/Contents/MacOS/Claude`, so helper processes and other processes that merely mention that path are never counted or signalled. A profile folder is compared whole, so primary's `Claude` folder never matches a `Claude-<tag>` folder and `alt` never matches `alt-2`. `clone-prefs` refuses when it cannot tell whether its target is running.
- No plaintext tokens persist on disk under this script's authority. OAuth state lives in the macOS keychain (CLI surface) or Electron `safeStorage` per `--user-data-dir` (Mac-app surface).
- The account check reads one non-secret value, `lastKnownAccountUuid`, from each profile's `config.json`. That file also holds the app's token caches, so `jq` reads it in place and only that one value (at most 36 characters, and only when it is shaped like an account id) reaches the script; no shell variable ever holds the file's contents, the file is never copied, and core dumps are turned off for the run. Nothing else in a profile is opened.
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

## Testing

`bash tests/run.sh` runs the simulated test suite from the repository root.
Every case runs against fakes in a scratch directory with its own `HOME`, so
no case can signal a real Claude process, bring a real window to the front,
read your keychain, or write a real profile. Three things keep it there: the script runs every external
command and data root through an `AS_*` variable (the seam), which it
ignores outside test mode; in test mode it refuses to start (exit 78) unless
every one of those variables points into the scratch directory; and the
fakes themselves refuse a stray PID, a real keychain service name, or a
path outside the scratch directory. `tests/README.md` describes the layout
and how to add a case.

CI runs the suite on a macOS runner under the system `/bin/bash` 3.2 (the
`T1 simulated suite (macOS)` job in `.github/workflows/tests.yml`). The
`/account-switcher` slash command runs the installed script with whichever
`bash` comes first on your `PATH`, so if that is a newer bash, a green CI run
speaks for `/bin/bash` rather than for the bash your slash command uses.

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
