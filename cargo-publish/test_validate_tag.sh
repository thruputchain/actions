#!/usr/bin/env bash
# Local tests for validate-tag.sh. Run: bash cargo-publish/test_validate_tag.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/validate-tag.sh"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

verdict() { # verdict <tag> [prefix] -> "accept" | "reject"
  if bash "$SCRIPT" "$@" >/dev/null 2>&1; then echo accept; else echo reject; fi
}

# ---- Accepted: stable releases (the pre-existing contract) ----
check "stable with default 'v' prefix"   accept "$(verdict v1.2.3 v)"
check "stable, multi-digit components"   accept "$(verdict v10.20.30 v)"
check "stable with empty prefix"         accept "$(verdict 1.2.3 '')"
check "stable with crate-scoped prefix"  accept "$(verdict groundhog-erc20-if-v0.1.23 groundhog-erc20-if-v)"

# ---- Accepted: pre-releases (the point of this change) ----
# v0.15.1-rc.1 is what cargo-version-tag derives from a 0.15.1-rc.1 workspace,
# and what cargo-publish rejected before this script existed.
check "rc pre-release"                   accept "$(verdict v0.15.1-rc.1 v)"
check "single-identifier pre-release"    accept "$(verdict v1.0.0-beta v)"
check "dotted pre-release"               accept "$(verdict v1.0.0-alpha.1 v)"
# The shape cargo-nightly-version emits.
check "nightly pre-release"              accept "$(verdict v0.15.2-nightly.20260905.gabc1234 v)"
check "pre-release with empty prefix"    accept "$(verdict 0.15.1-rc.1 '')"
check "pre-release, scoped prefix"       accept "$(verdict groundhog-erc20-if-v0.1.23-rc.2 groundhog-erc20-if-v)"

# ---- Rejected: malformed tags ----
check "missing required prefix"          reject "$(verdict 1.2.3 v)"
check "incomplete core version"          reject "$(verdict v1.2 v)"
check "prefix present when none wanted"  reject "$(verdict v1.2.3 '')"
check "empty pre-release after hyphen"   reject "$(verdict v1.2.3- v)"
check "leading zero in core"             reject "$(verdict v01.2.3 v)"
# semver forbids leading zeros in numeric pre-release identifiers.
check "leading zero in pre-release"      reject "$(verdict v1.2.3-01 v)"
check "trailing text after version"      reject "$(verdict v1.2.3.4 v)"
# Build metadata is intentionally out of scope; nothing here emits it.
check "build metadata"                   reject "$(verdict v1.2.3+build.1 v)"

if [ "$FAILED" -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
