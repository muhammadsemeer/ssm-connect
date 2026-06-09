# Changelog

## [1.0.0] - 2025-07-03
### Added
- Initial release of `ssm-connect` with basic functionality to connect to AWS SSM instances
- Support for creating aliases for instances
- Interactive connection setup
- Basic help and usage instructions
- Installation script for Linux and Mac
- Support for AWS CLI configuration during first use
- Documentation for installation and usage in README.md
- Basic error handling for missing AWS profile

## [1.1.0] - 2025-08-05
### Added
- Added scp functionality to copy files to and from instances

### Changed
- Improved SSM connection handling

## [1.2.0] - 2025-08-12
### Changed
- Improved Instance Id retrieval
- Refactored update logic

### Fixed
- Changelog file missing

## [1.3.0] - 2025-08-13
### Added
- Usage tracking for instance selection in ssm-connect script and sort by usage in interactive mode

## [1.4.0] - 2025-08-13
### Added
- command to check for updates

## [1.4.1] - 2025-08-13
### Fixed
- Showing duplicate update info in --check-update

## [1.5.0] - 2025-09-23
### Added
- add AWS CLI profile option for S3 commands in ssm-connect script

## [1.6.0] - 2026-04-22
### Changed
- Same usage like original scp

### Fixed
- Scp Upload issues

## [2.0.0] - 2026-04-24
### Changed
- AWS profile management to SSO

## [2.0.1] - 2026-04-28
### Fixed
- Auto-trigger SSO login for `--scp` when session is expired or missing

## [2.1.0] - 2026-05-06
### Added
- Alias groups: optional third column in the aliases file lets you tag aliases with a group name (e.g. `api`, `tiles`)
- `ssm-connect --add-alias` accepts an optional group: `ssm-connect -a <alias> <id> [group]`
- `ssm-connect --set-group <alias> <group>` and `ssm-connect --unset-group <alias>` to manage the group of an existing alias without re-entering the instance id
- `ssm-connect <group>` opens an fzf picker scoped to instances in that group when the argument isn't an alias

### Changed
- `--list-aliases` now renders sectioned by group, with bold-cyan group headers and a dim `ungrouped` section for aliases without a group
- Interactive picker shows a `GROUP` column (when any alias has a group), pinned aligned header, and sorts by group then recent usage
- Usage tracking is now keyed by alias name instead of the full alias-file line (existing usage data will rebuild from the next few interactive picks)

## [2.2.0] - 2026-06-05
### Added
- Bash completion: completes flags, alias names, group names, and `alias:` targets for `--scp`, driven by `~/.ssm-connect/aliases`
- `install.sh` installs the completion script to the platform's bash-completion directory
- `ssm-connect --update` now installs/refreshes bash completion for existing users

## [2.3.0] - 2026-06-09
### Added
- `ssm-connect --install-bash-completion` installs or refreshes bash completion on demand

### Changed
- Update checks now use proper semantic-version comparison, so they're correct across multi-digit versions (e.g. `2.10.0` is newer than `2.9.0`) and tolerant of stray whitespace or a leading `v`
- `--update` verifies the remote version itself and downloads to temporary files first, swapping them into place only after every download succeeds — a failed update can no longer leave a half-written install
- `--check-update` now reports when the update server is unreachable instead of silently treating it as up to date

### Fixed
- A failed network call during the daily update check no longer counts as that day's check, so the next run retries

## [2.4.0] - 2026-06-09
### Fixed
- Aliases containing regex/glob metacharacters (e.g. a `.` or `/`) no longer match or delete the wrong entry — all alias lookups now use exact matching
- `--whats-new` and `--update` now work on macOS (replaced a GNU-only `head` invocation that fails on BSD)
- Interactive picker no longer drops the first alias on the very first run (before any usage history exists)
- Alias edits no longer leave `.bak` files behind in `~/.ssm-connect`

### Changed
- Hardened `--scp`: remote paths are validated and safely quoted before being run on the instance, preventing command injection
- Alias and group names containing whitespace (which would corrupt the alias file) are now rejected with a clear error; instance IDs that don't look like `i-xxxxxxxx` produce a warning
- `--uninstall` now also removes the installed bash-completion file
- All scripts restructured into functions behind a single dispatch entry point; `--help`/`--version`/alias management no longer require `fzf` to be installed

