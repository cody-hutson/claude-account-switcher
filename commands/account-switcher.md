---
description: Seamlessly swap Claude desktop app accounts via --user-data-dir
argument-hint: <subcommand> [args...] e.g. swap <tag> | launch <tag> | signin <tag> | identity | prefs diff | list | update | quit
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

- `swap <tag>` — SEAMLESS swap. 3-step flow: quit current → the settings step for tgt (the synced settings keys, see `prefs`; for a tag other than primary also clone-prefs' extension and worktree copy from primary) → launch tgt. tgt may be `primary`; `--no-mirror` skips the settings step. It prints one `settings:` line (applied, kept, skipped, needs review); pass it on. Runs the account check before it opens or quits anything and refuses on a `MISMATCH`; `--force` swaps anyway. Ends with the same closing line as `launch`. Exit 0 swapped, 1 refused (or an instance would not quit, or `open` failed: every instance was quit, so tell the user to run `account-switcher launch <tag>`).
- `launch` and `swap` refuse a tag that is not in `[accounts]` and has no profile folder (a typo would create an empty profile), naming the configured tags and the closest match; `--new` allows it. Pass that message on, and suggest `--new` only if the user means a new tag. Both also refuse while `update` runs, and print a one-line warning naming `update` when an app update has waited longer than `[update] warn_after_hours` (default 24).
- `launch <tag> [--force] [--new]` — ADDITIVE launch. Spawns target without quitting others. Use for side-by-side. Runs the account check before it opens or quits anything: on a `MISMATCH` it refuses, opening nothing; `--force` launches anyway, with the warning. Exit 0 launched, 1 refused. Then brings the new window to the front by its PID and ends with `tag=<tag> pid=<pid> front=yes|no account=<label|unrecognized|unknown> status=<match|MISMATCH|unknown>`. When summarizing, report that line: which tag and account the window in front is on, and with `front=no` pass on its hint to switch with Cmd-backtick or the Dock. `pid=unknown` means no new instance appeared within 15 s (the launch still happened). The System Events step may show a one-time macOS permission prompt.
- `signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]` (or `login`) — Sign one tag in. Other instances stay open by default: it lists them, prints the tag's label and email, opens the tag (or uses its running instance), waits for the profile to record an account, then compares every profile's recorded account with the one before. Another profile that changed is a loud `MISMATCH` naming that tag, exit 4: a callback delivered to another open instance is detected after the fact, not prevented. `--quit-others` lists every instance, asks (`--yes` skips; this command has no terminal, so without `--yes` it refuses), quits them, and signs in with only the target running; it signals only the instances it listed, and one it didn't list that appears during the quit stops it (named, exit 2, nothing opened). It waits for the sign-in up to `--timeout` seconds (default 300), so tell the user to finish the sign-in in that tag's window. When summarizing, report the last line (`signin tag=… result=… detail=… others_changed=… exit=…`) and any `MISMATCH` or `UNVERIFIED` block word for word. Exit 0 match, 1 MISMATCH, 2 refused (nothing opened), 3 unknown (no pin, not seen in time, exited, stopped), 4 another profile changed or could not be checked.
- `identity [<tag> | --all]` — Read-only account check: one row per tag in `[accounts]` with its expected account (label), the account its profile is recorded as signed into, and `match`, `MISMATCH` or `unknown`. Exit 0 = no MISMATCH, 1 = a MISMATCH, 2 = can't run. Labels only. Reads only each profile's `config.json` (no cookies, Local Storage, keychain items or tokens).
- `identity pin <tag> [--yes] [--force]` — Pin the account the tag's profile holds now as its expected account (`[identity]` in config.toml). Check the tag's window first. Refuses an account already pinned to another tag unless `--force`.
- `clone-prefs [src tgt]` — Mirror Mac-app user-facing prefs from src to tgt: the key-level settings step for tgt (the whole `claude_desktop_config.json` is no longer copied; src is not used for settings), then `Claude Extensions/`, `Claude Extensions Settings/` and the `git-worktrees.json` merge (snapshot-rollback semantics; ≤1 backup retained). Exit 0 done, 1 refused or failed.
- `prefs <verb>` — Keep 8 global UI settings the same in every profile (primary plus each `[accounts]` tag whose folder exists), one key at a time. Key classes: G (the 8 allowlisted keys, the only ones ever written), C capability toggles and S security settings (shown, never synced), A account-keyed and L profile-local entries (counted, never synced), U unclassified (listed by masked name, never synced). A change in one profile spreads (latest wins); a key with no history that the profiles disagree on, or two different changes seen at once, needs review, with primary's value proposed. Running profiles are never written; nothing is ever deleted, except that `prefs undo` removes a key the last sync added; output never shows an id, a path or an email.
  - `prefs diff [--all]` — read-only; show it to the user as printed. Exit 0 in sync and nothing pending, 1 otherwise, 2 error.
  - `prefs sync [<tag>] [--dry-run]` — update `<tag>`, or every profile not running. Exit 0 done, 1 done but a key needs review or a write was skipped, 2 refused (nothing written). `--dry-run` writes nothing (1 = something to write or pending).
  - `prefs review` — needs a terminal, which this command doesn't have: tell the user to run `account-switcher prefs review` in Terminal, or use the verbs below.
  - `prefs adopt <key-id> --from <tag>` — make `<tag>`'s value the value for every profile (exit 0, 1 a profile was skipped, 2 refused).
  - `prefs pin <tag> <key-id>|--all` and `prefs unpin <tag> <key-id>|--all` — keep a key (or the whole profile) different on purpose (exit 0, 2 refused).
  - `prefs undo <tag> [--whole-file]` — reverse the last sync to `<tag>`, key by key: a key it changed goes back to its previous value, and a key it added is removed (the one exception to nothing being deleted); the undone keys then need review. Report how many were restored and how many removed. `--whole-file` restores the prior copy after a confirmation, so it needs a terminal too. Exit 0 restored, 1 nothing to restore, 2 refused.
- `quit [--all]` — Quit all running Claude instances (graceful → SIGTERM → SIGKILL via PID list).
- `update [--yes]` — Install the waiting Claude app update. All tags share one app and one updater, and the update installs only once every instance is closed. It lists each instance it will close (tag · PID), warns that scheduled tasks pause while Claude is closed, and asks; this command has no terminal, so without `--yes` it refuses. Run it with `--yes` only after the user has seen that list and agreed to close every Claude window. It closes them through the quit path, signalling only the instances it listed (one it didn't list that appears during the quit stops it: named, what it closed reopened, `result=unlisted`; if the updater's log shows an install running when the quit stops, that way or because an instance won't close, or when the wait times out, it reopens nothing and prints a launch command per tag to run once the install finishes), waits up to `[update] install_timeout_s` (default 120) for the install, reopens the same tags and prints the version before and after; when summarizing, report the last line (`update before=… after=… result=… reopened=… exit=…`). Exit 0 installed or nothing staged, 1 the version did not change (it prints the updater log's last line), 2 refused with nothing closed, or stopped by an unlisted instance, 3 installed but a tag did not reopen, 130 interrupted.
- `list` (or `instances`) — Show running instances + configured profile dirs. Each instance shows its tag and how it was found (`via=argv`, `via=flagless` for primary, `via=lsof`), or `tag=unknown via=none` when it can't be determined. Profile folders not in `[accounts]` are marked `unconfigured` (never deleted). The last block shows the installed app version, the staged one (`none` when nothing waits, `unknown` when the updater's files can't be read) and how long it has waited.
- `status` — Show CLI identity (~/.claude.json + keychain subscription).
- `config show | get <key>` — Display or read config.toml.
- `add-account <tag> <email> [label]` — Register a tag → email mapping in `[accounts]` of the runtime config.toml.
- `version` (or `--version`) — Print the installed script's version. To check the install against the repo, run `bash install.sh --check` from the clone.

**App location:** running instances are found only by the app's main binary at `/Applications/Claude.app/Contents/MacOS/Claude`. When it isn't there, `swap`, `quit`, `clone-prefs`, `signin`, `update` and the writing `prefs` verbs refuse and name that path; `list`, `identity`, `status`, `prefs diff`, `prefs sync --dry-run` and `launch` print one warning line and go on. Pass the message on: Claude has to be in `/Applications`.

**Profile tag mapping (validated regex `^[a-z0-9-]{1,32}$`):**
- `primary` (default) → `~/Library/Application Support/Claude` — preserves chat history
- `<tag>` → `~/Library/Application Support/Claude-<tag>` — isolated; sign it in with `signin <tag>`

**What's shared automatically across accounts** (no symlinks needed):
- Local Code session jsonls (`~/.claude/projects/<cwd>/`) — `claude --continue` works cross-instance
- Skills, hooks, plugins, MCP, settings (all under `~/.claude/`)

**What's per-account** (intentional isolation):
- OAuth tokens (in user-data-dir's Electron safeStorage)
- Mac app preferences (theme, window state), except the 8 synced settings keys (`prefs`)
- Account-keyed, security and capability settings in `claude_desktop_config.json` (never synced)
- Cloud chat sidebar (Anthropic-server-side)
