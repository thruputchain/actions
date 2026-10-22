#!/usr/bin/env bash
# Validates that a git tag is <prefix><semver>, where the semver core may carry
# an optional pre-release suffix (v0.15.1-rc.1, v0.15.2-nightly.20260905.gabc1234).
#
# Usage: validate-tag.sh <git-tag> [tag-prefix]
# Run tests: bash cargo-publish/test_validate_tag.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../semver.sh
. "$HERE/../semver.sh"

TAG="${1?git tag required}"
PREFIX="${2-}"

# Escape special regex characters in the prefix so a prefix like "thruput-erc20-if-v"
# (or one containing '.') is matched literally.
ESCAPED_PREFIX=$(printf '%s\n' "$PREFIX" | sed 's/[[\.*^$()+?{|]/\\&/g')

SEMVER_REGEX="$(semver_regex "$ESCAPED_PREFIX")"

if [ -z "$PREFIX" ]; then
  EXPECTED_FORMAT="1.2.3 or 1.2.3-rc.1 (semver without prefix)"
  EXAMPLES="1.0.0, 2.3.4, 0.15.1-rc.1"
  INVALID_EXAMPLES="v1.2.3 (has prefix), 1.2 (incomplete), 1.2.3- (empty pre-release)"
else
  EXPECTED_FORMAT="${PREFIX}1.2.3 or ${PREFIX}1.2.3-rc.1 (semver with '${PREFIX}' prefix)"
  EXAMPLES="${PREFIX}1.0.0, ${PREFIX}2.3.4, ${PREFIX}0.15.1-rc.1"
  INVALID_EXAMPLES="1.2.3 (no prefix), ${PREFIX}1.2 (incomplete), ${PREFIX}1.2.3- (empty pre-release)"
fi

if [[ ! "$TAG" =~ $SEMVER_REGEX ]]; then
  echo "::error::Invalid git tag format: '$TAG'"
  echo "::error::Expected format: $EXPECTED_FORMAT"
  echo "::error::Examples: $EXAMPLES"
  echo "::error::Invalid: $INVALID_EXAMPLES"
  exit 1
fi

echo "OK: Git tag format is valid: $TAG"
