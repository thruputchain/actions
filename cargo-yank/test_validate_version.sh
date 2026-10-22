#!/usr/bin/env bash
# Local tests for validate-version.sh. Run: bash cargo-yank/test_validate_version.sh
#
# Mirrors the bare-version cases in cargo-publish/test_validate_tag.sh, so a
# grammar or escaping change that makes a publishable version un-yankable
# fails here rather than surfacing at yank time.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/validate-version.sh"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

verdict() { # verdict <version> -> "accept" | "reject"
  if bash "$SCRIPT" "$@" >/dev/null 2>&1; then echo accept; else echo reject; fi
}

# ---- Accepted: stable releases (the pre-existing contract) ----
check "stable release"                   accept "$(verdict 1.2.3)"
check "stable, multi-digit components"   accept "$(verdict 10.20.30)"
check "zero version"                     accept "$(verdict 0.0.0)"

# ---- Accepted: pre-releases, so a published RC can be yanked ----
check "rc pre-release"                   accept "$(verdict 0.15.1-rc.1)"
check "single-identifier pre-release"    accept "$(verdict 1.0.0-beta)"
check "dotted pre-release"               accept "$(verdict 1.0.0-alpha.1)"
# A dated pre-release suffix.
check "nightly pre-release"              accept "$(verdict 0.15.2-nightly.20260905.gabc1234)"

# ---- Rejected: malformed versions ----
check "tag prefix not accepted"          reject "$(verdict v1.2.3)"
check "incomplete core version"          reject "$(verdict 1.2)"
check "empty pre-release after hyphen"   reject "$(verdict 1.2.3-)"
check "leading zero in core"             reject "$(verdict 01.2.3)"
# semver forbids leading zeros in numeric pre-release identifiers.
check "leading zero in pre-release"      reject "$(verdict 1.2.3-01)"
check "trailing text after version"      reject "$(verdict 1.2.3.4)"
# Build metadata is intentionally out of scope; nothing here emits it.
check "build metadata"                   reject "$(verdict 1.2.3+build.1)"

if [ "$FAILED" -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
