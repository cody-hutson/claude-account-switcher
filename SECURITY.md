# Security Policy

## Supported Versions

Only the latest commit on `main` is supported. Tagged releases are historical reference only — fixes ship to `main`.

## Reporting a Vulnerability

If you believe you have found a security vulnerability in this repository, please report it privately:

- **Email:** chutson.git@gmail.com
- **Subject:** `[claude-account-switcher security] <short description>`
- **Include:** affected file(s) or commit, steps to reproduce, expected vs. actual behavior, and any proof-of-concept

Please do **not** open a public issue, PR, or discussion for security reports.

## Response Expectations

This is a personal project maintained by a single maintainer. Response targets are best-effort:

| Severity | Acknowledgement | Initial Response |
|----------|-----------------|------------------|
| Critical (RCE, credential exposure, data loss) | Within 1 business day | Within 3 business days |
| High (privilege escalation, secrets leakage) | Within 3 business days | Within 7 business days |
| Medium / Low | Within 7 business days | Best-effort |

You will receive an acknowledgement, an initial assessment, and a remediation plan or rationale for non-action.

## Scope

**In scope:**
- Bash scripts at repo root (`account-switcher.sh`, `install.sh`) and supporting subdirectories
- GitHub Actions workflows in `.github/workflows/`
- Repository configuration (Dependabot, branch settings, CODEOWNERS)
- Slash command definitions under `commands/`

**Out of scope:**
- Runtime configuration the tool manages on your machine (`~/.claude/account-switcher/config.toml`, `~/.claude/account-switcher/swap-history.log`, `~/.claude/account-switcher/.statusline-marker`) — these are local instance state, not source content
- Third-party dependencies pinned in `.github/workflows/security.yml` (gitleaks, actionlint, shellcheck — report CVEs to upstream maintainers; Dependabot tracks GitHub Action versions)
- The Claude desktop app itself (proprietary, managed by Anthropic) — this tool only launches it with a different `--user-data-dir`

## Defenses Currently in Place

| Control | Status |
|---------|--------|
| Dependabot vulnerability alerts | Auto-enabled on public repositories |
| Dependabot security updates (auto-PR) | Maintainer-enabled |
| Dependabot version updates (scheduled) | See `.github/dependabot.yml` |
| Bash SAST (shellcheck) | See `.github/workflows/security.yml` |
| Workflow YAML SAST (actionlint) | See `.github/workflows/security.yml` |
| Secret scanning (gitleaks, full history) | See `.github/workflows/security.yml` |
| Native GitHub Secret Scanning + Push Protection | Enabled |
| Branch protection on `main` | Enabled — 3 required status checks (Bash SAST + Workflow SAST + Secret scanning); force-push and deletions blocked; stale-review dismissal; required conversation resolution |
| Commit signing | Maintainer practice; not enforced via branch protection (single-maintainer model) |

## Automated Security PRs

Dependabot version-update PRs and Dependabot security-update PRs are tagged with the `dependabot` label.

Dependency bumps are self-contained, reversible, and CI-validated. The `cluster: security` label is retained on these PRs so they remain discoverable in security audits.
