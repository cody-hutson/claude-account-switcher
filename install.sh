#!/usr/bin/env bash
# install.sh — Claude Code Account Switcher installer
#
# Idempotent installer. Run from the repo root:
#   bash install.sh
#
# What this does:
#   1. Creates ~/.claude/account-switcher/ (if not exists)
#   2. Copies account-switcher.sh -> ~/.claude/account-switcher/account-switcher.sh
#      (preserves +x bit; overwrites if existing — operator-state preserved
#      for runtime files that this script does NOT touch)
#   3. Copies config.toml.template -> ~/.claude/account-switcher/config.toml
#      ONLY if ~/.claude/account-switcher/config.toml does not exist
#      (preserves operator customization on re-run)
#   4. Copies commands/account-switcher.md -> ~/.claude/commands/account-switcher.md
#      (registers the /account-switcher slash command)
#   5. Verifies install: ~/.claude/account-switcher/account-switcher.sh status
#
# Re-runnable: safe to run multiple times. Operator-state files
# (swap-history.log, .statusline-marker, runtime config.toml) are preserved
# across re-runs.
#
# Uninstall: see README.md "Uninstall".

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${HOME}/.claude/account-switcher"
readonly COMMANDS_DIR="${HOME}/.claude/commands"

# Pre-flight: macOS + jq
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'ERROR: macOS-only installer (uname=%s)\n' "$(uname -s)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq is required (try: brew install jq)\n' >&2
  exit 1
fi

# Pre-flight: source files present in this repo
for required in account-switcher.sh config.toml.template commands/account-switcher.md; do
  if [[ ! -f "${SCRIPT_DIR}/${required}" ]]; then
    printf 'ERROR: required file missing from repo: %s\n' "${required}" >&2
    printf 'Are you running install.sh from the repo root?\n' >&2
    exit 1
  fi
done

mkdir -p "${INSTALL_DIR}"
mkdir -p "${COMMANDS_DIR}"

# Step 1: account-switcher.sh (overwrite — source of truth for the executable)
install -m 755 "${SCRIPT_DIR}/account-switcher.sh" "${INSTALL_DIR}/account-switcher.sh"
printf 'Installed: %s\n' "${INSTALL_DIR}/account-switcher.sh" >&2

# Step 2: config.toml.template -> config.toml (only-if-not-exists; preserves operator state)
if [[ ! -f "${INSTALL_DIR}/config.toml" ]]; then
  install -m 600 "${SCRIPT_DIR}/config.toml.template" "${INSTALL_DIR}/config.toml"
  printf 'Installed: %s (from template — edit to add account entries)\n' "${INSTALL_DIR}/config.toml" >&2
else
  printf 'Preserved: %s (already exists; not overwriting)\n' "${INSTALL_DIR}/config.toml" >&2
fi

# Step 3: slash command
install -m 644 "${SCRIPT_DIR}/commands/account-switcher.md" "${COMMANDS_DIR}/account-switcher.md"
printf 'Installed: %s\n' "${COMMANDS_DIR}/account-switcher.md" >&2

# Step 4: verify install
printf '\nVerifying install via account-switcher status...\n' >&2
"${INSTALL_DIR}/account-switcher.sh" status >&2 || true

printf '\nInstall complete. Next steps:\n' >&2
printf '  1. In a fresh Claude Code terminal: /account-switcher help\n' >&2
printf '  2. Edit %s to add account entries via:\n' "${INSTALL_DIR}/config.toml" >&2
printf '       account-switcher add-account <tag> <email> [label]\n' >&2
printf '  3. (Optional) Set [swap_handoff].gh_repo in %s to enrich SWAP_HANDOFF.md\n' "${INSTALL_DIR}/config.toml" >&2
