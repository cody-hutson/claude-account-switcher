#!/usr/bin/env bash
# tests/t-05-install-check.sh - install.sh --check and version reporting.
#
# Cases 1 to 11 are the issue-5 runner's, moved here with four edits: REPO
# comes from lib.sh, `check` is run_install --check, `populate` is kept, and
# the runner's own log capture is dropped (run.sh captures). Each case gets
# its own scratch root from new_case. The runner's case 12 read the real
# HOME, so it is not a simulated case and is not here. Cases 13 and 14 run
# install mode against the real script through the fakes; case 15 shows that
# --check run from the repo never reaches the checkout with git.

set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh" || exit 2

EXPECT_V="$(/usr/bin/sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' "$SWITCHER")"

populate() {  # $1 = scratch HOME; copies the repo files where install puts them
  /bin/mkdir -p "$1/.claude/account-switcher" "$1/.claude/commands"
  /bin/cp "$REPO/account-switcher.sh" "$1/.claude/account-switcher/account-switcher.sh"
  /bin/chmod 755 "$1/.claude/account-switcher/account-switcher.sh"
  /bin/cp "$REPO/commands/account-switcher.md" "$1/.claude/commands/account-switcher.md"
}

case_01_clean() {
  new_case; H="$HOME"; populate "$H"; run_install --check
  [[ $rc -eq 0 && "$out" == *"Install matches this repo."* && "$out" == *"Installed version: ${EXPECT_V}"* ]]
  result "1. clean -> exit 0, versions shown" $?
}

case_02_altered() {
  new_case; H="$HOME"; populate "$H"; printf '# local edit\n' >> "$H/.claude/account-switcher/account-switcher.sh"; run_install --check
  [[ $rc -eq 1 && "$out" == *"differs   ~/.claude/account-switcher/account-switcher.sh"* && "$out" == *"ok        ~/.claude/commands/account-switcher.md"* ]]
  result "2. altered -> exit 1, file named" $?
}

case_03_missing() {
  new_case; H="$HOME"; populate "$H"; /bin/rm "$H/.claude/commands/account-switcher.md"; run_install --check
  [[ $rc -eq 1 && "$out" == *"missing   ~/.claude/commands/account-switcher.md"* ]]
  result "3. missing -> exit 1, file named" $?
}

case_04_state_files() {
  local D f before after
  new_case; H="$HOME"; populate "$H"; D="$H/.claude/account-switcher"
  for f in config.toml swap-history.log swap-history.log.1 .statusline-marker prefs-sync.json .DS_Store; do
    printf 'state %s\n' "$f" > "$D/$f"
  done
  before="$(cd "$D" && /usr/bin/shasum config.toml swap-history.log swap-history.log.1 .statusline-marker prefs-sync.json .DS_Store)"
  /bin/chmod 000 "$D/config.toml" "$D/swap-history.log" "$D/swap-history.log.1" "$D/.statusline-marker" "$D/prefs-sync.json" "$D/.DS_Store"
  run_install --check
  /bin/chmod 600 "$D/config.toml" "$D/swap-history.log" "$D/swap-history.log.1" "$D/.statusline-marker" "$D/prefs-sync.json" "$D/.DS_Store"
  after="$(cd "$D" && /usr/bin/shasum config.toml swap-history.log swap-history.log.1 .statusline-marker prefs-sync.json .DS_Store)"
  [[ $rc -eq 0 && "$before" == "$after" && "$out" != *"leftover"* ]]
  result "4. state files (mode 000) -> exit 0, bytes unchanged" $?
}

case_05_leftovers() {
  new_case; H="$HOME"; populate "$H"; printf 'old\n' > "$H/.claude/account-switcher/README.md"; printf 'old\n' > "$H/.claude/account-switcher/AUTO_SWAP_DEFERRAL.md"; run_install --check
  [[ $rc -eq 1 && "$out" == *"leftover  ~/.claude/account-switcher/AUTO_SWAP_DEFERRAL.md"* && "$out" == *"leftover  ~/.claude/account-switcher/README.md"* && "$out" == *"trash <path>"* && -f "$H/.claude/account-switcher/README.md" ]]
  result "5. leftovers -> exit 1, both named, not deleted" $?
}

case_06_no_version_line() {
  new_case; H="$HOME"; populate "$H"; /usr/bin/grep -v '^readonly VERSION=' "$REPO/account-switcher.sh" > "$H/.claude/account-switcher/account-switcher.sh"; run_install --check
  [[ $rc -eq 1 && "$out" == *"Installed version: unknown"* && "$out" == *"differs   ~/.claude/account-switcher/account-switcher.sh"* ]]
  result "6. no VERSION line -> 'unknown', exit 1" $?
}

case_07_nothing_installed() {
  new_case; H="$HOME"; /bin/mkdir -p "$H"; run_install --check
  [[ $rc -eq 1 && "$out" == *"missing   ~/.claude/account-switcher/account-switcher.sh"* && "$out" == *"missing   ~/.claude/commands/account-switcher.md"* ]]
  result "7. empty HOME -> exit 1, both missing" $?
}

case_08_unknown_option() {
  new_case; run_install --bogus
  [[ $rc -eq 2 ]]
  result "8. unknown option -> exit 2" $?
}

case_09_outside_repo() {
  new_case; H="$HOME"; populate "$H"
  /bin/mkdir -p "$AS_TEST_ROOT/notrepo"; /bin/cp "$REPO/install.sh" "$AS_TEST_ROOT/notrepo/install.sh"
  INSTALL_SRC="$AS_TEST_ROOT/notrepo"; run_install --check
  [[ $rc -eq 2 && "$out" == *"repo file missing"* ]]
  result "9. repo files absent -> exit 2" $?
}

case_10_version_touches_nothing() {
  local L i v v2 calls_after_version lines_after_version rotated_after_version lines_after_help rotated_after_help
  new_case; H="$HOME"; /bin/mkdir -p "$H/.claude/account-switcher"; L="$H/.claude/account-switcher/swap-history.log"
  for i in $(/usr/bin/seq 1 1200); do echo "line $i"; done > "$L"
  run_switcher version; v="$out"; run_switcher --version; v2="$out"
  calls_after_version="$(< "$AS_TEST_ROOT/calls.log")"
  lines_after_version="$(/usr/bin/wc -l < "$L" | /usr/bin/tr -d ' ')"; rotated_after_version=no; [[ -f "$L.1" ]] && rotated_after_version=yes
  run_switcher help
  lines_after_help="$(/usr/bin/wc -l < "$L" | /usr/bin/tr -d ' ')"; rotated_after_help=no; [[ -f "$L.1" ]] && rotated_after_help=yes
  [[ "$v" == "account-switcher ${EXPECT_V}" && "$v2" == "$v" && "$lines_after_version" == 1200 && "$rotated_after_version" == no && "$lines_after_help" == 1000 && "$rotated_after_help" == yes && -z "$calls_after_version" ]]
  result "10. version prints ${EXPECT_V}, runs no command and skips rotation; help rotates" $?
}

case_11_install_mode_stub() {
  local R cfg_mode sh_mode md_mode cbefore cafter
  new_case
  R="$AS_TEST_ROOT/repo-copy"; /bin/mkdir -p "$R/commands"
  /bin/cp "$REPO/install.sh" "$REPO/config.toml.template" "$R/"; /bin/cp "$REPO/commands/account-switcher.md" "$R/commands/"
  printf '#!/usr/bin/env bash\nreadonly VERSION="9.9.9-stub"\necho "stub $*"\n' > "$R/account-switcher.sh"
  H="$HOME"; INSTALL_SRC="$R"
  run_install
  cfg_mode="$(/usr/bin/stat -f '%Lp' "$H/.claude/account-switcher/config.toml")"; sh_mode="$(/usr/bin/stat -f '%Lp' "$H/.claude/account-switcher/account-switcher.sh")"; md_mode="$(/usr/bin/stat -f '%Lp' "$H/.claude/commands/account-switcher.md")"
  [[ $rc -eq 0 && "$cfg_mode" == 600 && "$sh_mode" == 755 && "$md_mode" == 644 && "$out" == *"stub status"* && "$out" == *"bash install.sh --check"* ]]
  result "11a. fresh install (stub switcher) -> files + modes, check hint" $?
  printf 'operator customization\n' > "$H/.claude/account-switcher/config.toml"; cbefore="$(/usr/bin/shasum < "$H/.claude/account-switcher/config.toml")"
  run_install
  cafter="$(/usr/bin/shasum < "$H/.claude/account-switcher/config.toml")"
  [[ $rc -eq 0 && "$cbefore" == "$cafter" && "$out" == *"Preserved:"* && "$out" == *"config.toml.template"* ]]
  result "11b. re-install -> config.toml untouched, template hint" $?
  run_install --check
  [[ $rc -eq 0 && "$out" == *"Installed version: 9.9.9-stub"* ]]
  result "11c. check after install -> exit 0" $?
}

# A copy of the repo under the scratch root, with the real switcher.
copy_repo() {
  R="$AS_TEST_ROOT/repo-real"; /bin/mkdir -p "$R/commands"
  /bin/cp "$REPO/install.sh" "$REPO/config.toml.template" "$REPO/account-switcher.sh" "$R/"
  /bin/cp "$REPO/commands/account-switcher.md" "$R/commands/"
  INSTALL_SRC="$R"
}

case_13_install_through_seam() {
  local f
  new_case; copy_repo
  run_install
  local calls_ok=0
  for f in kill osascript open ps pgrep; do
    assert_never_called "$f" || calls_ok=1
  done
  assert_rc 0 &&
    assert_contains "$out" "subscription: fake (rate=fake)" &&
    assert_not_contains "$out" "ERROR: AS_TEST_MODE=1" &&
    assert_eq "$(calls_of security)" "security"$'\tfind-generic-password\t-s\t'"${AS_KEYCHAIN_SVC}"$'\t-w' "security calls" &&
    assert_eq "$calls_ok" "0" "danger fakes other than security"
  result "13. install mode runs the real status through the fakes: one security call, test service only; no other danger fake runs" $?
}

case_14_install_child_refuses() {
  new_case; copy_repo
  # The installer's child (status) loses AS_BIN_SECURITY: it must refuse
  # with 78 rather than fall back to the real binary. install.sh runs the
  # child with `|| true`, so the evidence is the refusal line and calls.log,
  # not install.sh's exit code.
  unset AS_BIN_SECURITY
  run_install
  local refusals=0 l
  while IFS= read -r l; do
    [[ "$l" == *"ERROR: AS_TEST_MODE=1 but AS_BIN_SECURITY is not under AS_FAKES_DIR (got '/usr/bin/security')"* ]] && refusals=$((refusals + 1))
  done <<< "$out"
  assert_rc 0 &&
    assert_eq "$refusals" "1" "refusal lines naming AS_BIN_SECURITY" &&
    assert_never_called security &&
    assert_not_contains "$out" "subscription:"
  result "14. install-mode child without AS_BIN_SECURITY -> one refusal line, security never called" $?
}

case_15_check_git_contained() {
  new_case; H="$HOME"; populate "$H"; run_install --check
  assert_rc 0 &&
    assert_called git $'\t-C\t'"${REPO}"$'\trev-parse' &&
    assert_called git $'\tREFUSED\t'"${REPO}" &&
    assert_eq "$(count_lines "$(calls_of git)")" "2" "git lines in calls.log (the call, its refusal)"
  result "15. --check from the repo: the git fake refuses -C <repo>, so no git runs against the checkout" $?
}

case_01_clean
case_02_altered
case_03_missing
case_04_state_files
case_05_leftovers
case_06_no_version_line
case_07_nothing_installed
case_08_unknown_option
case_09_outside_repo
case_10_version_touches_nothing
case_11_install_mode_stub
case_13_install_through_seam
case_14_install_child_refuses
case_15_check_git_contained
finish
