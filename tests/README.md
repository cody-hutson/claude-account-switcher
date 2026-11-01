# Tests

The T1 suite is simulated: every case runs `account-switcher.sh` or
`install.sh` against fakes in a scratch directory, never against a running
Claude app, the keychain, or a real profile. It is plain bash and runs under
the system `/bin/bash` 3.2.

## Running it

From the repository root:

```bash
bash tests/run.sh                      # every check and every tests/t-*.sh file
bash tests/run.sh t-05-install-check   # the checks, then just that file
bash tests/run.sh --check-defaults     # only: every seam default is an executable file
```

Exit status: `0` all passed, `1` a case failed, `2` a harness error. A failing
case prints its last exit code and the first lines of its output. Set
`TEST_KEEP=1` to keep the scratch directories for inspection.

Before the test files, `run.sh` parses every script with `/bin/bash -n`,
runs the seam-coverage lint (no command named by absolute path outside the
seam block, and one default line per `AS_SEAM_BINS` name; each lint has a
control case that proves it can fail), and checks that every default
command path exists on this machine.

## Why a case cannot reach real state

Three layers, all of which have tests in `t-00-seam.sh`:

1. **The seam.** `account-switcher.sh` runs every external command through an
   `AS_BIN_<NAME>` variable and reads every data root through an `AS_<ROOT>`
   variable (`AS_STORE`, `AS_CLAUDE_JSON`, `AS_PROFILE_ROOT`, `AS_APP_BUNDLE`,
   `AS_UPDATER_CACHE`, `AS_APP_LOG_DIR`), plus `AS_KEYCHAIN_SVC`. Outside test
   mode the script unsets every one of them and uses the absolute paths it
   always used, so a value planted in the environment changes nothing.
2. **The interlock.** With `AS_TEST_MODE=1` the script first checks, using
   builtins only, that `AS_TEST_ROOT` is an absolute directory carrying the
   `.as-test-root` sentinel; that `HOME`, `AS_FAKES_DIR` and every root sit
   under it; that every `AS_BIN_*` is an executable fake in `AS_FAKES_DIR`
   of the right class; and that `AS_KEYCHAIN_SVC` begins with `as-test-`. The
   first failed check prints one `ERROR: AS_TEST_MODE=1 but ...` line and
   exits 78, before any command runs. A child process that lost part of its
   environment (the installer runs `status` as a child) refuses the same way.
3. **The fakes.** The recording fakes run nothing real: `kill` exits 99 for a
   PID the scenario did not list, and `security` exits 99 for any service
   name not beginning `as-test-`. The write-tool fakes refuse any absolute
   path outside `AS_TEST_ROOT`, and any `..` path component, before running
   the real tool.

`tests/lib.sh` also refuses to start a case whose `HOME` would be, or sit
under, the invoking user's home. Each case runs from inside its scratch
root, and the `git` fake refuses a path outside it, so no case runs git
against this checkout.

## Layout

| Path | What it is |
|---|---|
| `run.sh` | entry point (above) |
| `lib.sh` | sourced by every test file: `new_case`, `run_switcher`, `run_install`, fixtures, assertions, `result`, `finish` |
| `fakes/*.sh` | one template per fake class or command; `new_case` copies each to `$AS_FAKES_DIR/<name>` |
| `fixtures/` | masked inputs, rendered per case (see the masking rule below) |
| `t-00-seam.sh` | production neutrality, the interlock, and the guards in the fakes |
| `t-01-detect.sh` | `list` and the running-tag detection; its former CHARACTERIZATION #9 cases now pin the corrected behaviour |
| `t-09-detect.sh` | #9: the exact instance matcher and every caller (`list`, `clone-prefs`, the swap handoff, `quit`), the `lsof` path, the `pgrep` lint, a large table |
| `t-06-identity.sh` | #6: the per-tag account check (`identity`, `identity pin`, the check before `launch` and `swap`), `identity_status`'s always-0 contract, and a leak scan with its own control arm |
| `t-07-signin.sh` | #7: `signin` with other instances open and with `--quit-others`; the identity snapshot before and after (another profile changing is exit 4, naming it); the terminal answer with `read -t`; refusals and the exit-code invariant (no exit 1 but a `MISMATCH`); interrupts; a secret scan (placeholder tokens, ids, 64-hex digests) after every case, with its own control arm |
| `t-08-front.sh` | #8: after `launch` and `swap`, the wait for the new PID, the bring-to-front ladder (`setfront`, AppKit, System Events, none) with each rung checked by `front_pid`, the closing line, and the always-0 contracts of `wait_for_new_instance` and `bring_to_front` |
| `t-11-prefs.sh` | #11: the key-level settings sync. Three fixture profiles hold every key class, with every id, session key and path generated when the case runs. One case per acceptance criterion (only allowlisted keys change, by `jq -S` and `delpaths` for every writing command; literal dotted names; latest wins; behind; review; pins; running profiles, including the raw `FLAGLESS` and `unknown` refusals; swap's order from the recording fakes and launch; clone-prefs; read-only; `prefs diff`; the prior copy and undo; a half-written file; the summary line and rows; the docs), plus type changes, removed keys, the lock, `install.sh --check` and every verb's exit codes. After each case its output, `PREFS_*` rows and sync state are scanned for a uuid, a session id or a path, with a control arm |
| `t-10-update.sh` | #10: `list`'s installed, staged and waiting rows (`unknown`, never `none`, when the updater's files can't be read) and its `unconfigured` folders; `update` (nothing staged, the list and confirmation, the bounded wait, the reopen with and without the updater's own relaunch, the exit codes); the lock; the `launch`/`swap` warning and unknown-tag guard; the reader's scope through the recording fakes, with its own control arm; `install.sh --check` with the new state files. The per-poll hook plays the updater's helper; cases run in a zone 5 hours from UTC |
| `t-05-install-check.sh` | `install.sh --check`, version reporting, install mode through the fakes |

## The scratch root

`new_case` creates one directory per case under `${TMPDIR:-/tmp}`:

| Inside `$AS_TEST_ROOT` | Use |
|---|---|
| `.as-test-root` | the sentinel the interlock looks for |
| `home` | the case's `HOME`; `AS_STORE`, `AS_PROFILE_ROOT` and the other roots sit beneath it, except `AS_APP_BUNDLE` (`$AS_TEST_ROOT/Applications/Claude.app`) |
| `Applications/Claude.app/Contents/MacOS/Claude` | an empty placeholder for the app's main binary (`APP_MAIN_BIN`), where the matcher looks; the commands that rely on detection refuse without it, and a case removes it to test that |
| `fakes` | the fakes (`AS_FAKES_DIR`) |
| `calls.log` | one line per fake call: the fake's name, then each argument, tab-separated |
| `ps.txt` | the process table the `ps` fake prints (`AS_FIXTURE_PS`) |
| `ps-next.txt` | optional: the table the `ps` fake installs after its next call (`set_ps_next_fixture`) |
| `lsof/<pid>.txt` | the open-file names (`lsof -Fn` records) the `lsof` fake prints for that PID (`set_lsof_fixture <pid> <file>`) |
| `alive.txt` | the PIDs the `kill` fake treats as alive |
| `front.txt` | the PID of the front application, which the `lsappinfo` and `osascript` fakes share; absent until a rung moves it (then `AS_FAKE_FRONT_PID`, default `400`) |
| `git-fixture` | a scratch git repository with one commit (`TEST_GIT_ROOT`); point `[swap_handoff].git_root` at it when a case needs git content |
| `tmp` | `TMPDIR` for the code under test |

`run_switcher <args>` runs the script under `/bin/bash` from inside the
root, with the fakes first on a system `PATH`, and sets `out`, `err` and
`rc`. `run_install <args>` does the same for `install.sh` (stdout and
stderr merged in `out`); set `INSTALL_SRC` to run a copy of the repository.
The harness's own commands never go through the fakes.

## Fakes

Line 1 of every fake is its shebang and line 2 its class, which the
interlock reads:

| Class | Commands | Behaviour |
|---|---|---|
| `recording` | `kill` `security` `osascript` `open` `ps` `lsof` `lsappinfo` (required), `sleep` | record the call, run nothing real, act on the scenario files |
| `guarded-passthrough` | `rm` `mv` `cp` `rsync` `chmod` `install` `mktemp` `mkdir` `PlistBuddy` `plutil` (required), `git` | record, refuse a path outside the root, then run the real tool |
| `passthrough` | every other command | record, then run the real tool |

The `sleep` fake returns at once: every wait in the script counts polls
rather than reading the clock, and every fake changes state on a call,
never with time, so a 15 s wait runs its full count without waiting.

Scenario controls, all exported and reset by `new_case`:

| Variable | Read by | Effect |
|---|---|---|
| `AS_FIXTURE_PS` | `ps` | path of the process table (set it with `set_ps_fixture <file> [after-quit-file]`) |
| `AS_FIXTURE_PS_AFTER_QUIT` | `osascript` | the table that replaces it on a graceful quit |
| `AS_FAKE_QUIT=graceful` | `osascript` | on the quit script only, every app quits: `alive.txt` empties, the after-quit table is installed |
| `AS_FAKE_FRONT_PID=<n>` | `lsappinfo` | the front application before any rung moves it (default `400`) |
| `AS_FAKE_FRONT_AFTER_SETFRONT` | `lsappinfo` | what `setfront` leaves in front: `target` (the PID it named), a PID, or unset/empty for no change |
| `AS_FAKE_FRONT_AFTER_APPKIT` | `osascript` | the same, for the AppKit activation (`-l JavaScript`, recorded as `osascript ACTIVATE appkit <pid>`) |
| `AS_FAKE_FRONT_AFTER_SYSEVENTS` | `osascript` | the same, for the System Events activation (recorded as `osascript ACTIVATE system-events <pid>`) |
| `AS_FAKE_ACTIVATE_RC=<n>` | `lsappinfo`, `osascript` | the exit status of `setfront` and of both activations (default `0`) |
| `AS_FAKE_KILL_EFFECTIVE=0` | `kill` | a signalled PID stays alive |
| `AS_FAKE_OPEN_SPAWNS_PID=<n>` | `open` | a new main process with that PID joins the table (with its `--user-data-dir` unless `AS_FAKE_OPEN_UDD=0`) |
| `AS_FIXTURE_KEYCHAIN_JSON` | `security` | the item it prints (fake values only) |
| `AS_FAKE_KEYCHAIN=absent` | `security` | the item is missing (exit 44) |

Two more names are read by `account-switcher.sh` itself, for `signin` and
`update`, and only in test mode (production unsets them with the seam
names): `AS_TEST_STDIN_IS_TTY=1` makes stdin count as a terminal, and
`AS_TEST_POLL_HOOK` names an executable under `AS_TEST_ROOT` (the interlock
checks) that `signin` and `update` run once per poll, before the poll's
reads, with the poll number. `t-07-signin.sh` uses the hook to change the
scenario between polls, so a case whose timer is `read -t` (a terminal) can
stage changes mid-wait as well as one whose timer is the `sleep` fake;
`t-10-update.sh` uses it to play the updater's helper during the install
wait.

## Writing a case

One file per area: `t-<NN>-<slug>.sh`, where `00` is the seam, `01` to `04`
existing behaviour, and a two-digit issue number for that issue's
behaviour. Inside it, one `case_<slug>` function per case, ending in
`result "<name>" $?`, and `finish` at the end of the file:

```bash
case_list_empty() {
  new_case
  set_ps_fixture ps-no-claude.txt
  run_switcher list
  assert_rc 0 && assert_contains "$out" "(no Claude desktop app instances running)"
  result "list with no instance running" $?
}
```

Assertions: `assert_rc`, `assert_eq`, `assert_contains`,
`assert_not_contains`, `assert_called <fake> <substring>`,
`assert_never_called <fake>`, `assert_call_order <fake> <fake>`,
`assert_unchanged <path> <shasum-before>`, `assert_tree_unchanged <dir>
<tree_digest-before>`; `calls_of <fake>` prints one fake's lines from
`calls.log`. Bash 3.2 only: no `mapfile`, `readarray`, `declare -A`,
`[[ -v`, `${x^^}` or `|&`.

A case that needs a new command adds, in the same change: the name to
`AS_SEAM_BINS`, its default line in the seam block, and its fake (a
`fakes/<name>.sh` template for a recording fake, or the name in
`FAKE_GUARDED` in `lib.sh` for a guarded one). A new data root adds an
`AS_SEAM_ROOTS` entry and its default line. The lint fails the suite
otherwise.

## Fixture masking rule

Every committed fixture is masked:

- no real account, organisation or session id, and no committed id-shaped
  value at all, not even an all-zero one (a personal-data scan matches the
  shape); where a case needs an id, generate it at test time and write it
  under the scratch root, as `t-06-identity.sh` does with `fid`;
- no email address;
- no home folder path: write `__HOME__`, which `render_fixture` replaces with
  the case's scratch `HOME`;
- no app path: write `__APP__` for the app bundle, which `render_fixture`
  replaces with the case's `AS_APP_BUNDLE` (the matcher only accepts a main
  process whose argv[0] is `$AS_APP_BUNDLE/Contents/MacOS/Claude`);
- no real tag name: fixtures use `primary`, `tag-a` and `tag-b`;
- token-shaped keys hold the literal value `fake`, or, in a case that must
  prove a value never leaks, a placeholder such as `FIXTURE-NOT-A-TOKEN-1`
  that the case then asserts is absent from every output.

Name a fixture so `.gitignore` cannot swallow it: a log excerpt is stored as
`*.txt` (never `*.log`), a marker or backup-shaped file as `*.tmpl`.
