---
description: Seamlessly swap Claude desktop app accounts via --user-data-dir
argument-hint: <subcommand> [args...] e.g. swap <tag> | launch <tag> | signin <tag> | identity | list | quit
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

- `swap <tag>` — SEAMLESS swap. 3-step flow: clone-prefs primary→tgt → quit current → launch tgt. Runs the account check first and refuses on a `MISMATCH` before quitting anything; `--force` swaps anyway. Ends with the same closing line as `launch`.
- `launch <tag> [--force]` — ADDITIVE launch. Spawns target without quitting others. Use for side-by-side. Refuses on an account-check `MISMATCH`, opening nothing; `--force` launches anyway, with the warning. Then brings the new window to the front by its PID and ends with `tag=<tag> pid=<pid> front=yes|no account=<label|unrecognized|unknown> status=<match|MISMATCH|unknown>`. When summarizing, report that line: which tag and account the window in front is on, and with `front=no` pass on its hint to switch with Cmd-backtick or the Dock. `pid=unknown` means no new instance appeared within 15 s (the launch still happened). The System Events step may show a one-time macOS permission prompt.
- `signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]` (or `login`) — Sign one tag in. Other instances stay open by default: it lists them, prints the tag's label and email, opens the tag (or uses its running instance), waits for the profile to record an account, then compares every profile's recorded account with the one before. Another profile that changed is a loud `MISMATCH` naming that tag, exit 4: a callback delivered to another open instance is detected after the fact, not prevented. `--quit-others` lists every instance, asks (`--yes` skips; this command has no terminal, so without `--yes` it refuses), quits them, and signs in with only the target running. It waits for the sign-in up to `--timeout` seconds (default 300), so tell the user to finish the sign-in in that tag's window. When summarizing, report the last line (`signin tag=… result=… detail=… others_changed=… exit=…`) and any `MISMATCH` or `UNVERIFIED` block word for word. Exit 0 match, 1 MISMATCH, 2 refused (nothing opened), 3 unknown (no pin, not seen in time, exited, stopped), 4 another profile changed or could not be checked.
- `identity [<tag> | --all] [--show-ids]` — Read-only account check: one row per tag in `[accounts]` with its expected account (label), the account its profile is recorded as signed into, and `match`, `MISMATCH` or `unknown`. Exit 0 = no MISMATCH, 1 = a MISMATCH, 2 = can't run. Labels only; `--show-ids` adds ids on stdout. Reads only each profile's `config.json` (no cookies, Local Storage, keychain items or tokens).
- `identity pin <tag> [--yes] [--force]` — Pin the account the tag's profile holds now as its expected account (`[identity]` in config.toml). Check the tag's window first. Refuses an account already pinned to another tag unless `--force`.
- `clone-prefs [src tgt]` — Mirror Mac-app user-facing prefs from src to tgt (snapshot-rollback semantics; ≤1 backup retained).
- `quit [--all]` — Quit all running Claude instances (graceful → SIGTERM → SIGKILL via PID list).
- `list` (or `instances`) — Show running instances + configured profile dirs. Each instance shows its tag and how it was found (`via=argv`, `via=flagless` for primary, `via=lsof`), or `tag=unknown via=none` when it can't be determined.
- `status` — Show CLI identity (~/.claude.json + keychain subscription).
- `config show | get <key>` — Display or read config.toml.
- `add-account <tag> <email> [label]` — Register a tag → email mapping in `[accounts]` of the runtime config.toml.
- `version` (or `--version`) — Print the installed script's version. To check the install against the repo, run `bash install.sh --check` from the clone.

**Profile tag mapping (validated regex `^[a-z0-9-]{1,32}$`):**
- `primary` (default) → `~/Library/Application Support/Claude` — preserves chat history
- `<tag>` → `~/Library/Application Support/Claude-<tag>` — isolated; sign it in with `signin <tag>`

**What's shared automatically across accounts** (no symlinks needed):
- Local Code session jsonls (`~/.claude/projects/<cwd>/`) — `claude --continue` works cross-instance
- Skills, hooks, plugins, MCP, settings (all under `~/.claude/`)

**What's per-account** (intentional isolation):
- OAuth tokens (in user-data-dir's Electron safeStorage)
- Mac app preferences (theme, window state)
- Cloud chat sidebar (Anthropic-server-side)
