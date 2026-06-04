# Contributing

Thanks for your interest in `claude-account-switcher`. It's a single bash script
plus an installer and a slash-command definition — there's no build step.

## Ground rules

- **Commit with a GitHub no-reply email, not a personal one.** Turn on
  *Settings → Emails → Keep my email address private*, then set your repo identity
  to the `…@users.noreply.github.com` address (`git config user.email`). A CI gate
  (`.github/workflows/depersonalization.yml`) blocks personal email addresses and
  OS user-home paths from entering the repo — in file content, in commit messages,
  and in commit author/committer identity.
- **No personal data.** Don't add real emails, tokens, machine paths, or private
  references to scripts, docs, or examples. `config.toml.template` ships empty by
  design — real account metadata lives only in your local runtime config.
- **Keep links valid and the shell clean.** CI runs shellcheck, actionlint, and
  gitleaks; broken or unsafe changes fail the build.

## Making a change

1. Branch from `main`.
2. Make the change. For script edits, run `bash -n account-switcher.sh` and try a
   dry run (install into a scratch `HOME`, then `account-switcher help`).
3. Open a PR and fill in the template. Put any `Closes #N` **only** in the
   *Issue References* block at the bottom of the PR body (the auto-close parser is lexical).
4. CI must be green: shellcheck, actionlint, secret scan, and the depersonalization gate.

This is a single-maintainer project — you can propose changes via a fork PR, but
the maintainer is the only merger (there are no other write collaborators).

## Reporting security issues

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md). Do not
open a public issue, PR, or discussion.
