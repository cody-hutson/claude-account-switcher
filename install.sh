#!/usr/bin/env bash
# install.sh — Claude Code Account Switcher installer
#
# Idempotent installer. Run from the repo root:
#   bash install.sh           install, or update an existing install
#   bash install.sh --check   report whether the install matches this repo
#
# What install does:
#   1. Creates ~/.claude/account-switcher/ (if not exists)
#   2. Copies account-switcher.sh -> ~/.claude/account-switcher/account-switcher.sh
#      (preserves +x bit; overwrites if existing — operator-state preserved
#      for runtime files that this script does NOT touch)
#   3. Copies commands/account-switcher.md -> ~/.claude/commands/account-switcher.md
#      (registers the /account-switcher slash command)
#   4. Copies config.toml.template -> ~/.claude/account-switcher/config.toml
#      ONLY if ~/.claude/account-switcher/config.toml does not exist
#      (preserves operator customization on re-run)
#   5. Verifies install: ~/.claude/account-switcher/account-switcher.sh status
#
# What --check does (read-only: it writes nothing and runs nothing it installed):
#   - Compares each installed file byte for byte with its repo copy, and lists
#     each one that differs or is missing.
#   - Lists anything else in ~/.claude/account-switcher/ that this version does
#     not install (left over from an older install). Operator-state files are
#     skipped and never opened — see OPERATOR_STATE below.
#   - Prints the installed and repo versions, read from each script's
#     `readonly VERSION=` line.
#   Exit status: 0 = install matches this repo; 1 = a file differs, is missing,
#   or is left over; 2 = the check could not run.
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

# Files this installer manages, as "<repo path>|<installed path>|<mode>".
# Install and --check both read this list, so they cannot disagree about what
# an install contains.
MANAGED=(
  "account-switcher.sh|${INSTALL_DIR}/account-switcher.sh|755"
  "commands/account-switcher.md|${COMMANDS_DIR}/account-switcher.md|644"
)
readonly MANAGED

# Operator-state files in ~/.claude/account-switcher/. Install never
# overwrites them (config.toml is only created when absent) and --check never
# opens them. prefs-sync.json is reserved for the planned profile-settings
# sync; .DS_Store is Finder metadata.
OPERATOR_STATE=(
  config.toml
  swap-history.log
  swap-history.log.1
  .statusline-marker
  prefs-sync.json
  .DS_Store
)
readonly OPERATOR_STATE

usage() {
  printf 'Usage: bash install.sh [--check]\n'
  printf '  (no option)  install, or update an existing install\n'
  printf '  --check      report whether the install matches this repo (read-only)\n'
}

# ---- --check helpers -------------------------------------------------------

# Prints the version from a script's `readonly VERSION="..."` line without
# running the script. Prints nothing if the file is absent or predates
# version reporting.
read_version() {
  local file="$1" line
  local re='^readonly VERSION="([^"]*)"'
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
}

# Shows a path with $HOME as ~, so the report can be pasted into an issue.
pretty() {
  # A literal ~ is the point here (display text), so SC2088 does not apply.
  # shellcheck disable=SC2088
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

is_operator_state() {
  local name="$1" state
  for state in "${OPERATOR_STATE[@]}"; do
    [[ "$name" == "$state" ]] && return 0
  done
  return 1
}

is_managed_path() {
  local path="$1" entry src dest mode
  for entry in "${MANAGED[@]}"; do
    IFS='|' read -r src dest mode <<< "$entry"
    [[ "$path" == "$dest" ]] && return 0
  done
  return 1
}

run_check() {
  local entry src dest mode path name
  local differs=0 missing=0 leftover=0
  local repo_version installed_version repo_commit

  for entry in "${MANAGED[@]}"; do
    IFS='|' read -r src dest mode <<< "$entry"
    if [[ ! -f "${SCRIPT_DIR}/${src}" ]]; then
      printf 'ERROR: repo file missing: %s — run --check from the repo root.\n' "${src}" >&2
      exit 2
    fi
  done

  repo_version="$(read_version "${SCRIPT_DIR}/account-switcher.sh")"
  installed_version="$(read_version "${INSTALL_DIR}/account-switcher.sh")"
  repo_commit="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || true)"

  printf 'Installed version: %s\n' "${installed_version:-unknown (installed before version reporting, or not installed)}"
  printf 'Repo version:      %s%s\n\n' "${repo_version:-unknown}" "${repo_commit:+ (commit ${repo_commit})}"

  for entry in "${MANAGED[@]}"; do
    IFS='|' read -r src dest mode <<< "$entry"
    if [[ ! -f "$dest" ]]; then
      printf '  missing   %s\n' "$(pretty "$dest")"
      missing=$((missing + 1))
    elif cmp -s "${SCRIPT_DIR}/${src}" "$dest"; then
      printf '  ok        %s\n' "$(pretty "$dest")"
    else
      printf '  differs   %s\n' "$(pretty "$dest")"
      differs=$((differs + 1))
    fi
  done

  # Anything else in the install directory is left over from an older install.
  # The three globs cover plain and dot names without changing shell options;
  # an unmatched glob stays literal and fails the existence test.
  if [[ -d "$INSTALL_DIR" ]]; then
    for path in "$INSTALL_DIR"/* "$INSTALL_DIR"/.[!.]* "$INSTALL_DIR"/..?*; do
      [[ -e "$path" || -L "$path" ]] || continue
      name="${path##*/}"
      is_managed_path "$path" && continue
      is_operator_state "$name" && continue
      printf '  leftover  %s  (not installed by this version)\n' "$(pretty "$path")"
      leftover=$((leftover + 1))
    done
  fi

  printf '\n'
  if [[ $((differs + missing + leftover)) -eq 0 ]]; then
    printf 'Install matches this repo.\n'
    return 0
  fi

  printf 'Install does not match this repo: %d differ, %d missing, %d left over.\n' \
    "$differs" "$missing" "$leftover"
  if [[ $((differs + missing)) -gt 0 ]]; then
    printf 'To update the install:  bash install.sh\n'
  fi
  if [[ "$leftover" -gt 0 ]]; then
    printf 'To remove a leftover:   trash <path>   (install.sh never deletes files)\n'
  fi
  return 1
}

# ---- Entry -----------------------------------------------------------------

case "${1:-}" in
  "") ;;
  --check)
    run_check && exit 0 || exit 1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    printf 'ERROR: unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

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

# Steps 1-3: managed files (overwrite — the repo is the source of truth)
for entry in "${MANAGED[@]}"; do
  IFS='|' read -r src dest mode <<< "$entry"
  install -m "${mode}" "${SCRIPT_DIR}/${src}" "${dest}"
  printf 'Installed: %s\n' "${dest}" >&2
done

# Step 4: config.toml.template -> config.toml (only-if-not-exists; preserves operator state)
if [[ ! -f "${INSTALL_DIR}/config.toml" ]]; then
  install -m 600 "${SCRIPT_DIR}/config.toml.template" "${INSTALL_DIR}/config.toml"
  printf 'Installed: %s (from template — edit to add account entries)\n' "${INSTALL_DIR}/config.toml" >&2
else
  printf 'Preserved: %s (already exists; not overwriting)\n' "${INSTALL_DIR}/config.toml" >&2
  printf '  Settings added in newer versions appear in config.toml.template, not in\n' >&2
  printf '  your config.toml. Compare the two and copy across any section you want:\n' >&2
  printf '    diff %s %s\n' "${SCRIPT_DIR}/config.toml.template" "${INSTALL_DIR}/config.toml" >&2
fi

# Step 5: verify install
printf '\nVerifying install via account-switcher status...\n' >&2
"${INSTALL_DIR}/account-switcher.sh" status >&2 || true

printf '\nInstall complete. Next steps:\n' >&2
printf '  1. Confirm the install matches this repo: bash install.sh --check\n' >&2
printf '  2. In a fresh Claude Code terminal: /account-switcher help\n' >&2
printf '  3. Edit %s to add account entries via:\n' "${INSTALL_DIR}/config.toml" >&2
printf '       account-switcher add-account <tag> <email> [label]\n' >&2
printf '  4. (Optional) Set [swap_handoff].gh_repo in %s to enrich SWAP_HANDOFF.md\n' "${INSTALL_DIR}/config.toml" >&2
