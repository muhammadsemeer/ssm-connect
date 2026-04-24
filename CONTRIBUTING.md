# Contributing to SSM Connect

Thanks for taking the time to contribute! This document explains how to report issues, propose changes, and submit pull requests.

By participating in this project you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).

---

## Ways to contribute

- **Report bugs** — open a [GitHub issue](https://github.com/muhammadsemeer/ssm-connect/issues) describing the problem, how to reproduce it, and what you expected.
- **Suggest features** — open an issue first so we can discuss the idea before you spend time on a PR.
- **Improve docs** — fixes to `README.md`, `CHANGELOG.md`, or inline help text are always welcome.
- **Submit code** — bug fixes and features, following the workflow below.

---

## Reporting bugs

When filing a bug, please include:

1. What you did (exact command invocation)
2. What you expected to happen
3. What actually happened (full error output — redact account IDs/ARNs if sensitive)
4. Your environment:
   - OS and version (`uname -a` on Linux/macOS)
   - `aws --version`
   - `ssm-connect --version`
   - Shell (`bash`, `zsh`, etc.)

---

## Development setup

### Prerequisites

- `bash` 4+
- `aws` CLI v2 (SSO support requires v2)
- `fzf` (for the interactive instance selector)
- An AWS account you can test against with Session Manager enabled on an instance

### Clone and run locally

```bash
git clone https://github.com/muhammadsemeer/ssm-connect.git
cd ssm-connect

# run directly without installing
./ssm-connect.sh --help

# or symlink for convenience during development
sudo ln -sf "$(pwd)/ssm-connect.sh" /usr/local/bin/ssm-connect-dev
ssm-connect-dev --help
```

### Project layout

| File | Purpose |
| --- | --- |
| `ssm-connect.sh` | Main CLI script (everything lives here) |
| `install.sh` | One-liner installer — downloads `ssm-connect.sh` to `/usr/local/bin` |
| `update-version.sh` | Maintainer helper for bumping the version and updating the changelog |
| `version` | Current released version (single line) |
| `CHANGELOG.md` | Keep-a-Changelog style release notes |
| `README.md` | User-facing docs |

---

## Making changes

### Branch naming

Create a feature branch off `master`:

```bash
git checkout -b feat/short-description
git checkout -b fix/short-description
git checkout -b docs/short-description
```

### Commit messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <short summary>

[optional body explaining the why]
```

Common types:

- `feat:` — new feature
- `fix:` — bug fix
- `docs:` — documentation-only change
- `chore:` — tooling, version bumps, non-user-facing maintenance
- `refactor:` — code change that neither fixes a bug nor adds a feature

Examples from this repo:

```
feat: enhance AWS profile management for SSO support in ssm-connect script
fix: improve instance ID retrieval in ssm-connect script
docs: update README for version 2.0.0 with SSO authentication and new file transfer syntax
```

### Code style

Since this is a single Bash script:

- Keep `set -euo pipefail` at the top — do not disable it per-command; handle errors with explicit `if` checks or `|| true`.
- Quote variable expansions (`"$VAR"`, not `$VAR`) unless word-splitting is intentional.
- Use `[[ ... ]]` over `[ ... ]` for tests.
- Prefer `$( ... )` over backticks for command substitution.
- Match the existing `[emoji] message` pattern for user-facing output (e.g., `[✅]`, `[⚠️]`, `[ℹ️]`, `[❌]`).
- New subcommands go in the `case "${1:-}"` block and must `exit 0` (or appropriate code) when handled.
- Update `show_help()` whenever you add or change a flag.

### Testing your change

There's no automated test suite yet — please manually verify:

- [ ] `./ssm-connect.sh --help` still renders correctly
- [ ] Your change works on a fresh machine (no existing `~/.ssm-connect/` or AWS profile)
- [ ] Your change works on an existing install (profile already configured)
- [ ] Any relevant flow: interactive select, direct connect, scp upload, scp download, alias add/remove/list, update check
- [ ] Both `bash` and `zsh` users can run the script (the shebang is `#!/bin/bash` so it runs in bash, but it must be invocable from either shell)

If you add a new command or flag, also test:

- [ ] `--help` documents it
- [ ] Missing-argument cases print a useful error and exit non-zero

### Changelog

For anything user-visible (new feature, fix, behavior change), add an entry under a new version heading in `CHANGELOG.md`. Maintainers handle the version bump and release via `update-version.sh`, so you don't need to touch `version`.

Format:

```markdown
## [X.Y.Z] - YYYY-MM-DD
### Added
- New thing

### Changed
- Existing behavior that changed

### Fixed
- Bug that was fixed
```

---

## Submitting a pull request

1. Fork the repo and push your branch.
2. Open a PR against `master` with:
   - A clear title using Conventional Commits format
   - A description explaining **what** changed and **why**
   - A note on how you tested it
   - A link to the related issue (if any)
3. Keep the PR focused on one change. If you spot unrelated issues, open separate PRs.
4. Be ready to iterate on review feedback.

### Review expectations

Maintainers will look for:

- The change solves a real user problem (linked issue or clear rationale)
- No breaking changes without a major version bump and migration notes
- Reasonable test coverage for the affected flows
- Docs updated (`README.md`, `--help`, `CHANGELOG.md`) if behavior changed

---

## Security

If you discover a security vulnerability, **do not open a public issue**. Instead, email the maintainer directly (see the commit history for contact). We'll respond as quickly as we can and credit you in the fix once it ships.

---

## Questions?

Open a [GitHub Discussion](https://github.com/muhammadsemeer/ssm-connect/discussions) or file an issue labeled `question`.
