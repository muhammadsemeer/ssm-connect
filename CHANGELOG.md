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

