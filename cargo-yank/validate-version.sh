#!/usr/bin/env bash
# Validates that a version is bare semver (no tag prefix), with an optional
# pre-release suffix, so a published 0.15.1-rc.1 can also be yanked.
#
# The grammar comes from the shared semver.sh, the same one
# cargo-publish/validate-tag.sh applies with a tag prefix, so anything
# publishable stays yankable.
#
# Usage: validate-version.sh <version>
# Run tests: bash cargo-yank/test_validate_version.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../semver.sh
. "$HERE/../semver.sh"

VERSION="${1?version required}"

SEMVER_REGEX="$(groundhog_semver_regex)"

if [[ ! "$VERSION" =~ $SEMVER_REGEX ]]; then
  echo "::error::Invalid version format: '$VERSION'"
  echo "::error::Expected format: 1.2.3 or 1.2.3-rc.1 (bare semver, no prefix)"
  echo "::error::Examples: 1.0.0, 2.3.4, 0.15.1-rc.1"
  echo "::error::Invalid: v1.2.3 (has prefix), 1.2 (incomplete), 1.2.3- (empty pre-release)"
  exit 1
fi

echo "OK: Version format is valid: $VERSION"
