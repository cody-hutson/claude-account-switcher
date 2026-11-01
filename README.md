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

# Register a tag → email mapping in [accounts] of the runtime config.toml,
# then sign the tag in (see § Signing in a tag).
account-switcher add-account backup you@example.com
account-switcher signin backup

# List configured tags + running instances
account-switcher list

# SEAMLESS swap: quit current, sync the shared settings into target, launch target
account-switcher swap backup

# See how the profiles' settings differ (read-only), then decide at a terminal
account-switcher prefs diff
account-switcher prefs review

# ADDITIVE launch: spawn target without quitting others (side-by-side mode)
account-switcher launch backup

# Account check: which account each tag's profile is recorded as signed into
account-switcher identity
# Pin backup's current account as its expected one (check its window first)
account-switcher identity pin backup

# Quit all running Claude instances (graceful → SIGTERM → SIGKILL via PID list)
account-switcher quit --all

# Install a waiting app update: close every instance, install, reopen the same tags
account-switcher update
```

## How `swap` works internally (5 steps)

**Step 0 — Pre-flight validation.** Validates the target tag against
`^[a-z0-9-]{1,32}$`; refuses to proceed when the target user-data-dir is
the same as the current. Runs the account check (see § Checking each tag's
account) before anything else, so a refused swap has quit, captured and
written nothing. Captures the active PID list at function entry.

**Step 1 — handoff capture.** Writes a privacy-safe `SWAP_HANDOFF.md`
(metadata + pointers only — no chat text, no file contents, no tokens) so the
next session in either account can resume coherently. By default it lands in
`~/.claude/account-switcher/`; point `[swap_handoff].workspace_dir` elsewhere
to relocate it. When `[swap_handoff].git_root` is set (or the current directory
is a git repo) it summarizes recent commits + uncommitted files; when
`[swap_handoff].gh_repo` is set it also captures recent issue + PR activity.
All of this is optional — skip it per-swap with `--no-handoff`.

**Step 2 — quit.** Quits all running Claude instances (graceful → SIGTERM →
SIGKILL via the tracked PID list). Quitting also makes each instance write
its settings file, and means the target is not running for the next step.

**Step 3 — the settings step.** After every instance has quit and before
the target launches, swap updates the 8 synced settings keys (see
§ Settings sync between profiles) in the target only, which may be
`primary`, from every participating profile, and prints one line:

```
settings: 2 applied to backup (new-session-worktree from primary, transcript-links-in-preview from primary), 1 kept (pinned), 0 skipped, 1 needs review: run 'account-switcher prefs review'
```

For a target other than `primary`, the step runs through `clone-prefs
primary <tag>`, which then copies `Claude Extensions/`, `Claude Extensions
Settings/` and the `git-worktrees.json` merge from primary as before
(snapshot-rollback semantics: ≤1 backup retained per target). Nothing else in
the settings file is written, and OAuth state is never touched
(per-user-data-dir Electron safeStorage is isolated by design).
`--no-mirror` skips the step. Whatever it reports (a key that needs review,
a held lock, a settings file that isn't valid JSON), the swap goes on to
launch.

**Step 4 — relaunch.** Launches the target via `open -n -a Claude.app --args
--user-data-dir "~/Library/Application Support/Claude-<tag>"`. The Electron
parent process loads from the tagged user-data-dir; its OAuth state is
isolated from every other tagged dir. Then it brings the new window to the
front and prints the closing line described in the next section.

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

## Signing in a tag (`signin`)

A new tag's first launch opens the app on its sign-in screen. The app
signs in one of two ways:

- **Email code** (recommended): choose "Continue with email", enter the
  address, then type the code you are emailed into that window. The account
  is the address you typed.
- **Google**: the app sends you to the system browser, and the browser
  returns you to the app through a `claude://` callback. The browser decides
  the account, so it must already be signed into the right one.

`account-switcher signin <tag>` (or `login <tag>`) runs that sign-in for one
tag and checks the result:

```bash
account-switcher signin backup                 # other instances stay open
account-switcher signin backup --quit-others   # sign in with nothing else open
```

1. It prints the tag's label and email from `[accounts]`, says which account
   to use, and lists the Claude instances that are open (tag and PID).
2. It opens the tag, or, when the tag is already running, uses that
   instance and opens no second process for it.
3. It waits up to `--timeout` seconds (default 300) for the profile to
   record an account. At a terminal you can also answer `y` when the window
   shows you signed in, which is how a sign-in back into the same account
   finishes (nothing on disk changes then). Then it keeps watching the other
   instances for `--settle` seconds (default 20).
4. It runs the account check (§ Checking each tag's account) and reports
   `match`, `MISMATCH` or `unknown` for the tag, then a summary line:
   `signin tag=<tag> mode=<others-open|quit-others> result=<...> detail=<...>
   recorded_as=<...> others_checked=<n> others_changed=<n>
   others_unverified=<n> exit=<code>`.

**Other instances stay open, and afterwards signin checks that no other
profile's account changed.** Before the sign-in it records each profile's
identity state: whether the account key is there, and a hash of its value
with a random salt made for that run. The hash is never printed, logged or
written to a file. After the sign-in it compares them again. If any profile
other than the target changed, can't be re-read, or runs in an instance
whose profile can't be determined, it prints `MISMATCH` (or `UNVERIFIED`)
naming that tag or PID, with recovery steps, and exits `4`, even when the
target reads `match`.

**A callback delivered to another open instance is detected after the fact,
not prevented.** With several instances open, macOS may hand the
`claude://` login callback to a different instance than the one you are
signing in, and that instance's profile can then be signed into this
account. `signin` sees that only afterwards, when that profile's recorded
account changes. It can't see a change in an instance that was already on
the same account, or a login that lands after it has exited. Email-code
sign-in may avoid the callback altogether. To remove the risk, close the
other windows first, or use `--quit-others`.

**`signin <tag> --quit-others` signs in with nothing else open.** It lists
every open instance (the target too, when it is running: it is quit and
reopened), asks before quitting them (`--yes` skips the question; without a
terminal and without `--yes` it quits nothing and exits `2`), quits them the
way `quit` does, and signs the tag in with only its instance running. It
signals only the instances it listed: if one it didn't list appears while
it quits (opened from the Dock, say), it signals nothing more, names it
(tag and PID), says what it closed and what is still running, opens nothing
and exits `2`.

Exit codes: `0` match; `1` MISMATCH; `2` refused before anything was opened
or quit (including every argument error); `3` unknown (no pin yet, not seen
before the timeout, the instance exited, or stopped); `4` another profile
changed or could not be checked, which wins over the others. A tag with no
pin ends `unknown`; at a terminal signin offers to pin it when
`identity pin` would accept it, and otherwise prints the next step.
`--new` signs in a tag that is not in `[accounts]` (it then ends `unknown`
with the `add-account` and `identity pin` steps).

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

## App updates (`update`)

Every tag runs the same app (`/Applications/Claude.app`); only its
`--user-data-dir` differs. So there is **one app and one updater for all
tags**. When an instance downloads an update, the updater's helper stages
it in `~/Library/Caches/com.anthropic.claudefordesktop.ShipIt/` and installs
it **only once every Claude instance is closed**, in every account. With
tags open side by side, that rarely happens, so an update can wait for days.
The "Relaunch to retry update" banner that some windows show and others
don't is a sign of this; all the windows still run the same build.

`account-switcher list` ends with the update state:

```
App update (one app and one updater serve every tag):
  installed: 4.29.0
  staged:    4.4212.0
  waiting:   2d 6h (since 2026-10-29T17:37:33Z)
```

`staged` reads `none` when nothing is waiting, and `unknown` (with the
reason) whenever the updater's files can't be read, never `none`. Versions
are shown as written and never compared as numbers. "Waiting since" is the
switcher's own record (`~/.claude/account-switcher/update-state.json`):
the updater rewrites its cache files at every launch, so their times say
nothing; the first time the switcher sees a staged version, it takes the
time from the updater log's first install request after the last
completed install. Once an update has waited longer than
`[update] warn_after_hours` (default 24), `launch` and `swap` print a
one-line warning naming `update`.

To install it:

```bash
account-switcher update          # lists what it will close, then asks
account-switcher update --yes    # the same, without the question
```

`update` lists every instance it will close (tag and PID) and warns that
scheduled tasks pause while Claude is closed. It asks before closing
anything; without a terminal it needs `--yes`. It then closes the instances
through the same path as `quit` (graceful, then `TERM`, then `KILL`, then a
final check), never signalling the updater's helper, and waits up to
`[update] install_timeout_s` (default 120) for the install. Afterwards it
reopens every tag that was open and prints the installed version before
and after. When the install request asked the updater to reopen the app
itself, the updater opens `primary`; `update` counts that window as
primary's and never opens primary a second time. It refuses, closing
nothing, when it can't name every open instance's tag, when an install is
already running, or when the instances change between the list and the
quit. It signals only the instances it listed: if one it didn't list
appears while it quits (opened from the Dock, say), it signals nothing
more, names it (tag and PID), skips the install wait, reopens what it
closed and ends with `result=unlisted`, exit `2`.

Exit codes: `0` installed (or nothing staged), `1` the installed version
did not change (it prints the updater log's last line), `2` refused before
anything closed, or stopped during the quit by an instance it hadn't
listed, `3` installed but a tag did not reopen in time.

While `update` runs it holds a lock, the directory
`~/.claude/account-switcher/.update.lock`, and `launch`, `swap` and
`signin` refuse until it is gone, so the switcher never starts the app
while its bundle is being replaced. (Opening Claude from the Dock is not
stopped.) A lock older than 10 minutes is reported as stale, with how to
remove it, and still refuses: its age alone does not prove the update that
took it has stopped, so the switcher never removes another run's lock.
Check that no update is running (`account-switcher list`), then
`trash ~/.claude/account-switcher/.update.lock`.

Installing automatically when the Mac is idle is not part of this; `update`
runs only when you ask.

## New tags and `--new`

`launch <tag>` and `swap <tag>` refuse a tag that is not in `[accounts]` and
has no profile folder yet, because opening it would quietly create a new,
empty profile, which is what a typo does. The message lists the configured
tags and the closest match:

```
ERROR: Tag 'bakup' is not in [accounts] and has no profile folder, so launch would create a new, empty profile. Configured tags: primary, backup. Closest match: backup. ...
```

When the new tag is intended, say so with `--new` (the same flag `signin`
takes):

```bash
account-switcher launch newtag --new
```

A folder that already exists is accepted. `list` marks every `Claude-*`
folder whose tag is not in `[accounts]` as `unconfigured`, so a stray
profile is visible. The switcher never deletes one; register it with
`add-account`, or trash the folder yourself once you are sure nothing in it
is needed.

## Settings sync between profiles (`prefs`)

Each profile keeps its own `claude_desktop_config.json`. The switcher keeps a
short allowlist of global UI preferences the same in every participating
profile, one key at a time, and never writes anything else in the file.
**Participating profiles** are `primary` plus every tag in `[accounts]` whose
profile folder exists (`default` is `primary`). It runs at `swap` (for the
target) and on request, never at `launch`.

**Key classes.** A family is a top-level key, a direct child of
`preferences`, or a direct child of `preferences.epitaxyPrefs`; many of the
last are flat names that contain dots (`projects.library.layout`), which the
switcher always treats as one literal key name.

| Class | What | Synced? |
|---|---|---|
| **G** | global UI preference: the 8 keys below | **Yes**, the only keys ever written |
| **C** | capability toggle (Chrome extension, browser tools, web search) | No; `prefs diff` shows where it differs |
| **S** | security or policy (bypass-permissions mode, trusted folders, remote control, scheduled tasks, the draft permission mode) | No; `prefs diff` shows where it differs |
| **A** | account-keyed (a name ending in an account id, or a map keyed by account or account/org) | No; `prefs diff` counts the entries and accounts |
| **L** | profile-local (device pairing, layout, a name holding a session, project or path) | No; `prefs diff` counts them |
| **U** | unclassified (a key a later app version added) | No; `prefs diff` lists it by masked name. It syncs only once it joins the allowlist |

The class G allowlist, by key id: `sidebar-mode`, `keep-awake`,
`preferred-browser` (under `preferences`), and `new-session-worktree`,
`transcript-links-in-preview`, `preferred-editor`,
`projects-library-layout`, `projects-library-small-icons` (under
`preferences.epitaxyPrefs`). A key whose JSON type differs from the
allowlist's in any profile is left alone for that run.

**How a value is chosen.** The switcher remembers, per key, the value it
last saw in each profile and the agreed *fleet value*, in
`~/.claude/account-switcher/prefs-sync.json` (mode 600; allowlisted values
only). A profile *changed* a key when its value differs from the one last
seen; a profile that differs from the fleet value without having changed is
*behind*.

| Situation | Result |
|---|---|
| No history; every profile holds the key with the same value | initialized; nothing written |
| No history; the profiles disagree, or some lack the key | **needs review**, with `primary`'s value proposed (no default when `primary` lacks it) |
| No profile changed it | behind profiles get the fleet value |
| Profiles changed it, all to one value | that value wins (latest wins) and goes to the others |
| Profiles changed it to different values | **needs review**: the order of two changes seen in one run is unknown |
| Only a pinned profile changed it | kept (pinned); it doesn't spread |
| The app removed it from a profile | not re-added there; the removal doesn't spread |

A key that needs review stays that way, and nothing is written for it, until
`prefs review` or `prefs adopt` settles it, or every unpinned profile holds
the same value again. A running profile is never written; it catches up at
its next sync. Deleting `prefs-sync.json` resets the change memory: the next
run sends every disagreement to review, never to a whole-file copy.

**What each command touches.**

| Command | Profile settings files | Prior copy | Sync state | History log |
|---|---|---|---|---|
| `launch <tag>` | not read, not written | not touched | not touched | `LAUNCH` row |
| `swap <tag>` | after every instance quit, before the launch: reads every profile, updates `<tag>` (may be `primary`); `--no-mirror` skips it | replaced in `<tag>` | read and updated | `PREFS_SYNC` row (and `CLONE_PREFS` for a tag other than primary) |
| `clone-prefs [src] <tgt>` | reads every profile, updates `<tgt>`; `src` drives only the extension and worktree copy | replaced in `<tgt>` | read and updated | `PREFS_SYNC` and `CLONE_PREFS` rows |
| `prefs diff [--all]` | read only | not touched | read only | none |
| `prefs sync [<tag>] [--dry-run]` | reads every profile, updates `<tag>` or every profile not running | replaced in each profile written | updated (not with `--dry-run`) | `PREFS_SYNC` (not with `--dry-run`) |
| `prefs review` | after the final confirmation, updates the profiles not running | replaced in each profile written | fleet values, pins, pending keys | `PREFS_SYNC` |
| `prefs adopt <key-id> --from <tag>` | updates that key in every unpinned profile not running | replaced in each profile written | fleet value set, pending cleared | `PREFS_SYNC` |
| `prefs pin`, `prefs unpin` | not touched | not touched | pins | `PREFS_PIN` |
| `prefs undo <tag> [--whole-file]` | updates `<tag>` | read for `--whole-file`, and kept | undone keys need review; undo record cleared | `PREFS_UNDO` |
| `quit`, `list`, `status`, `config`, `add-account`, `help` | not touched | not touched | not touched | as before |

**Nothing deletes.** No command removes a profile's settings file, a key in
it, or a prior copy. Before a write, the switcher replaces
`claude_desktop_config.json.sync-prev` in that profile's own folder with the
current file (mode 600): exactly one per profile, and no copy of a profile's
settings outside its folder. Every write builds the new file inside the
profile folder, checks that it equals the old one once the 8 allowlisted
paths are removed from both, re-checks that the profile isn't running, and
renames it into place, all under the lock `~/.claude/account-switcher/.prefs-sync.lock`
(stale after 10 minutes, reported and never removed, like `update`'s).

**Running checks.** A profile is running when an instance's row in `list`
resolves to it (a process without `--user-data-dir` is `primary`). Every
command except `swap` writes nothing, and says why, when more than one
instance runs without `--user-data-dir`, when an instance reads `unknown`
(it could be any profile), or when the process list can't be read. `swap`
runs its settings step after quitting every instance, so only the re-check
before each write applies; when the process list can't be read then, it
skips the step with a warning and still launches.

**See the differences.** `prefs diff` lists, for each synced key, its
status, the fleet value and each profile's value, marked *changed*,
*behind*, *pinned* or *removed by the app*; then the C and S settings that
differ (booleans as they are, lists as entry counts); the number of
account-keyed entries per profile, for how many accounts, and of local
entries; and U settings by masked name. It never prints an account, org,
session or project id, a path or an email. `--all` adds profile folders that
don't participate (run it after each app update and classify any U family).
Exit `0` in sync with nothing pending, `1` otherwise, `2` on error.

**Decide.** `prefs review` (it needs a terminal) walks every key that needs
review, is behind, or is pinned somewhere, shows each profile's value and
offers: use `primary`'s value (the default when there's no fleet value and
`primary` has one), use another profile's value, keep the key different in
one profile (a pin), or skip. At the end it shows the planned writes per
profile and asks once. Without a terminal, use `prefs adopt <key-id> --from
<tag>` (it always sets the fleet value), `prefs pin <tag> <key-id>` (or
`--all` for the whole profile) and `prefs unpin`.

**Undo.** `prefs undo <tag>` works key by key from the record of the last
sync that wrote `<tag>`: each key that still holds the synced value goes back
to its previous value, everything else in the file stays as it is now, and
the undone keys need review, so the next `swap` neither re-applies them nor
spreads the restored values. A key that sync added is left, since nothing
deletes. `--whole-file` restores the prior copy, after a confirmation that
says changes the app made since the sync will be lost. Both refuse while
`<tag>` is running.

**Exit codes.** `prefs sync`: `0` done with nothing pending or skipped, `1`
done but a key needs review or a write was skipped, `2` refused (nothing
written); with `--dry-run`, `1` means something would be written or is
pending. `prefs review`: `0` applied with nothing left pending, `1` something
left pending or the plan declined, `2` refused. `prefs adopt`: `0`, `1` a
profile was skipped, `2` refused. `prefs pin` and `unpin`: `0`, `2` refused.
`prefs undo`: `0` restored, `1` nothing to restore, `2` refused.

**Still to confirm on a live machine** (the issue's open assumptions): that
the app reads the file at startup and doesn't restore these keys from
another store, and that they behave the same on every account.

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
| Desktop settings (`claude_desktop_config.json`) | In each profile folder | Account-keyed, security, capability and local entries stay per profile; only the 8 class G keys are kept the same, by `swap` and `prefs` (see § Settings sync between profiles) |
| Cloud chat sidebar | Server-side per Anthropic | Anthropic owns the cloud sidebar source |
| Subscription state | Server-side per Anthropic | Bound to OAuth identity |

## Configuration

The runtime config lives at `~/.claude/account-switcher/config.toml`. The
template ships at `config.toml.template` in this repo and is copied to the
runtime path only on first install (your state preserved on re-install — see
§ Updating).

Key sections:

- `[accounts]` — map of tag → `{ label, profile_email }`. Populate via
  `account-switcher add-account <tag> <email> [label]`, then sign the tag in
  with `account-switcher signin <tag>`.
- `[identity]` — map of tag → the account id the tag's profile must be
  signed into, written by `account-switcher identity pin <tag>` (don't type
  ids by hand). A tag with no line here reads `unknown`. The header must be
  exactly `[identity]`. An install from before this check has no such table;
  the first `identity pin` adds it.
- `[update]` — `warn_after_hours` (default 24): when `launch` and `swap`
  warn about a waiting app update; `install_timeout_s` (default 120): how
  long `update` waits for the install. See § App updates.
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
- `<tag>` → `~/Library/Application Support/Claude-<tag>` — isolated; its first launch shows the app's sign-in screen (see § Signing in a tag)

Tag validation regex: `^[a-z0-9-]{1,32}$`. Whitespace, uppercase, and
non-ASCII characters are rejected (prevents shell injection in the
`--user-data-dir` path argument).

## Subcommand reference

| Subcommand | Action |
|---|---|
| `swap <tag> [flags]` | Quit current, run the settings step for the target (see § Settings sync between profiles), launch target. Flags: `--no-mirror` (skip the settings step), `--no-handoff` (skip SWAP_HANDOFF.md capture), `--note "<text>"` (context for the handoff, max 240 chars), `--force` (swap even when the account check reads `MISMATCH`), `--new` (allow a tag that is not in `[accounts]` and has no folder). Ends with the same closing line as `launch`. |
| `launch <tag> [--force] [--new]` | ADDITIVE launch. Spawns target without quitting others; use for side-by-side mode. Refuses on an account-check `MISMATCH` unless `--force`, a tag neither configured nor on disk unless `--new` (see § New tags), and while `update` runs. Brings the new window to the front and ends with `tag=<tag> pid=<pid> front=yes\|no account=<label\|unrecognized\|unknown> status=<match\|MISMATCH\|unknown>`; see § The window in front. |
| `update [--yes]` | Install the waiting app update: list the instances it will close, ask (`--yes` skips), close them through the quit path, wait for the install, reopen the same tags, print the version before and after. Exit `0` installed or nothing staged, `1` version unchanged, `2` refused, `3` a tag did not reopen. See § App updates. |
| `signin <tag> [--quit-others] [--yes] [--timeout <s>] [--settle <s>] [--new]` (or `login`) | Sign one tag in. Other instances stay open by default; afterwards it checks that no other profile's account changed (a change is detected after the fact, not prevented), and reports `match`, `MISMATCH` or `unknown` for the tag. `--quit-others` signs in with nothing else open. Exit `0`/`1`/`3` for the tag, `2` refused, `4` another profile changed. See § Signing in a tag. |
| `identity [<tag> \| --all] [--show-ids]` | Read-only account check: one row per tag in `[accounts]` with its expected account (label), the account its profile records, and `match`, `MISMATCH` or `unknown`. Exit `0` no MISMATCH, `1` a MISMATCH, `2` cannot run. See § Checking each tag's account. |
| `identity pin <tag> [--yes] [--force]` | Pin the account the tag's profile holds now as its expected account, in `[identity]` of config.toml. Refuses an account already pinned to another tag unless `--force`. |
| `clone-prefs [src] [tgt]` | The key-level settings step for tgt (the whole settings file is no longer copied), then mirror `Claude Extensions/`, `Claude Extensions Settings/` and `git-worktrees.json` src → tgt with snapshot-rollback. Defaults to `primary → <last-target>` when invoked without args. |
| `prefs diff [--all]` | Read-only: every difference between the profiles' settings, with no ids or paths. Exit `0` in sync, `1` not, `2` error. |
| `prefs sync [<tag>] [--dry-run]` | Sync the 8 allowlisted keys into `<tag>`, or every profile not running. Exit `0`, `1` a key needs review or a write was skipped, `2` refused. |
| `prefs review` | Decide each key that differs (needs a terminal). Exit `0`, `1` left pending or declined, `2` refused. |
| `prefs adopt <key-id> --from <tag>` | Make `<tag>`'s value the fleet value. Exit `0`, `1` a profile skipped, `2` refused. |
| `prefs pin <tag> <key-id>\|--all`, `prefs unpin …` | Keep a key (or a whole profile) different on purpose. Exit `0`, `2` refused. |
| `prefs undo <tag> [--whole-file]` | Reverse the last sync to `<tag>`. Exit `0`, `1` nothing to restore, `2` refused. |
| `quit [--all]` | Quit running Claude instances. `--all` quits every instance; bare `quit` quits only the current foreground instance. Graceful → SIGTERM → SIGKILL escalation. |
| `list` (or `instances`) | Show running instances + configured profile dirs. Each instance row gives its tag and how the tag was found: `via=argv` (its `--user-data-dir`), `via=flagless` (the only instance started without one, which is primary) or `via=lsof` (the one profile folder it holds open). When none of these settles it, the row reads `tag=unknown via=none` rather than guessing `primary`. Profile folders whose tag is not in `[accounts]` are marked `unconfigured` (never deleted), and the last block shows the installed app version, the staged one (or `none`, or `unknown`) and how long it has waited. |
| `status` | Show CLI identity (`~/.claude.json` + keychain subscription). |
| `config show` | Display the active config.toml. |
| `config get <key>` | Read a single config.toml key (supports flat keys and one-level `table.key` form). |
| `add-account <tag> <email> [label]` | Register a tag → email mapping in `[accounts]` of the runtime config.toml. Run it before `signin <tag>`, which prints the label and email from it. |
| `version` (or `--version`) | Print the installed script's version. To check the install against the repo, run `bash install.sh --check` from the clone (see § Verify). |

## Security & input validation

- Tag regex `^[a-z0-9-]{1,32}$` rejects shell-injection vectors in the `--user-data-dir` path argument.
- Email validation in `add-account` is intentionally lightweight (not RFC-compliant): refuses whitespace, requires a `@` followed by a `.`.
- `quit` uses PID-based tracking (`/bin/kill -0` per PID) rather than `pgrep -f` argv-pattern matching. The pattern-match approach is brittle when Anthropic ships new Electron flags; PID tracking is kernel-truth.
- Every running-instance check (`list`, `quit`, `clone-prefs`, the swap handoff's source, and the wait for the new instance after `launch` and `swap`) uses one matcher: a process is a Claude instance only when its first argument (argv[0]) is exactly `/Applications/Claude.app/Contents/MacOS/Claude`, so helper processes and other processes that merely mention that path are never counted or signalled. A profile folder is compared whole, so primary's `Claude` folder never matches a `Claude-<tag>` folder and `alt` never matches `alt-2`. `clone-prefs` refuses when it cannot tell whether its target is running.
- No plaintext tokens persist on disk under this script's authority. OAuth state lives in the macOS keychain (CLI surface) or Electron `safeStorage` per `--user-data-dir` (Mac-app surface).
- `signin` compares every profile's identity before and after the sign-in without holding the value: `jq` writes it into a pipe that `shasum` reads, and only a salted SHA-256 digest comes back. The digests and the salt are never printed, logged, written to a file or passed to another program; history rows carry tags, status words and counts only.
- The account check reads one non-secret value, `lastKnownAccountUuid`, from each profile's `config.json`. That file also holds the app's token caches, so `jq` reads it in place and only that one value (at most 36 characters, and only when it is shaped like an account id) reaches the script; no shell variable ever holds the file's contents, the file is never copied, and core dumps are turned off for the run. Nothing else in a profile is opened.
- Update detection (`list`, `update`, and the `launch` / `swap` warning) reads only the updater's state file, the installed and staged `Info.plist` files, the updater's log, and the process list. It opens no cookies, Local Storage, keychain items or tokens, and nothing in any profile folder. The updater's cache is found by the app's bundle id, never by a pattern that could match another app's updater.
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
