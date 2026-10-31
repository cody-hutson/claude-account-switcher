---
description: Seamlessly swap Claude desktop app accounts via --user-data-dir
argument-hint: <subcommand> [args...] e.g. swap <tag> | launch <tag> | list | quit
---

Run the account switcher with the user-supplied subcommand and arguments.

!`~/.claude/account-switcher/account-switcher.sh "$ARGUMENTS"`

If `$ARGUMENTS` is empty, the script prints help. After the script completes,
summarize the result for the user.

**Token handling:** ships launcher-only — no plaintext tokens
persist on disk. OAuth state lives in:
- macOS keychain (CLI surface, when used by terminal-direct `claude` invocations)
- Electron `safeStorage` per `--user-data-dir` (Mac-app surface)

**Subcommands (Mac desktop app management):**

- `swap <tag>` — SEAMLESS swap. 3-step flow: clone-prefs primary→tgt → quit current → launch tgt.
- `launch <tag>` — ADDITIVE launch. Spawns target without quitting others. Use for side-by-side.
- `clone-prefs [src tgt]` — Mirror Mac-app user-facing prefs from src to tgt (snapshot-rollback semantics; ≤1 backup retained).
- `quit [--all]` — Quit all running Claude instances (graceful → SIGTERM → SIGKILL via PID list).
- `list` (or `instances`) — Show running instances + configured profile dirs. Each instance shows its tag and how it was found (`via=argv`, `via=flagless` for primary, `via=lsof`), or `tag=unknown via=none` when it can't be determined.
- `status` — Show CLI identity (~/.claude.json + keychain subscription).
- `config show | get <key>` — Display or read config.toml.
- `add-account <tag> <email> [label]` — Register a tag → email mapping in `[accounts]` of the runtime config.toml.
- `version` (or `--version`) — Print the installed script's version. To check the install against the repo, run `bash install.sh --check` from the clone.

**Profile tag mapping (validated regex `^[a-z0-9-]{1,32}$`):**
- `primary` (default) → `~/Library/Application Support/Claude` — preserves chat history
- `<tag>` → `~/Library/Application Support/Claude-<tag>` — isolated; first launch prompts login

**What's shared automatically across accounts** (no symlinks needed):
- Local Code session jsonls (`~/.claude/projects/<cwd>/`) — `claude --continue` works cross-instance
- Skills, hooks, plugins, MCP, settings (all under `~/.claude/`)

**What's per-account** (intentional isolation):
- OAuth tokens (in user-data-dir's Electron safeStorage)
- Mac app preferences (theme, window state)
- Cloud chat sidebar (Anthropic-server-side)
