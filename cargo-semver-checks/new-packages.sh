#!/usr/bin/env bash
# Prints, one per line, the workspace packages that a baseline git revision
# doesn't have: crates added or renamed since then. cargo-semver-checks fails
# on such a package ("package `x` not found"), and a package with no earlier
# release has no API to break, so the action leaves these out.
#
# Both package lists come from `cargo metadata --no-deps`. The baseline's is
# read from a copy of that revision, but run from the current directory, so
# the caller's cargo configuration applies to it as it does to
# cargo-semver-checks (registries the baseline's manifests name, say). A
# baseline that lacks the workspace manifest makes every package new; one
# whose manifests cargo can't read is an error, as it is for
# cargo-semver-checks.
#
# Usage: new-packages.sh <manifest-path> <baseline-rev>
# Run tests: bash cargo-semver-checks/test_new_packages.sh
set -euo pipefail
export LC_ALL=C

MANIFEST="$1"
REV="$2"

package_names() { # package_names <manifest-path>
  cargo metadata --no-deps --format-version 1 --manifest-path "$1" \
    | jq -r '.packages[].name' | sort -u
}

CURRENT=$(package_names "$MANIFEST")

# The manifest's path within the repository, to find it in the baseline.
TOP=$(git -C "$(dirname "$MANIFEST")" rev-parse --show-toplevel)
REL=$(git -C "$(dirname "$MANIFEST")" ls-files --full-name -- "$(basename "$MANIFEST")")
if [ -z "$REL" ]; then
  echo "::error::$MANIFEST is not tracked by git, so it can't be compared with $REV" >&2
  exit 1
fi

if ! git -C "$TOP" cat-file -e "$REV:$REL" 2>/dev/null; then
  if [ -n "$CURRENT" ]; then printf '%s\n' "$CURRENT"; fi
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# From the top level: run in a subdirectory, git archive takes only that.
git -C "$TOP" archive "$REV" | tar -x -C "$TMP"
if ! BASELINE=$(package_names "$TMP/$REL"); then
  echo "::error::cargo can't read the workspace at $REV, so its packages are unknown" >&2
  exit 1
fi

comm -23 <(echo "$CURRENT") <(echo "$BASELINE")
