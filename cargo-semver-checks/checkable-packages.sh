#!/usr/bin/env bash
# Prints, one per line, the workspace packages cargo-semver-checks selects:
# those with a library-like target (lib, rlib, dylib, cdylib or staticlib; not
# proc-macro or bin), publish = false or not, as is_lib_like_checkable_target
# in cargo-semver-checks 0.50.0 does. It skips publish = false packages only
# after selecting, and fails with "no crates with library targets selected"
# when the selection is empty, so the action checks this before running it.
#
# Usage: checkable-packages.sh <manifest-path>
# Run tests: bash cargo-semver-checks/test_new_packages.sh
set -euo pipefail
export LC_ALL=C

cargo metadata --no-deps --format-version 1 --manifest-path "$1" \
  | jq -r '.packages[]
      | select(any(.targets[].kind[]; IN("lib", "rlib", "dylib", "cdylib", "staticlib")))
      | .name' \
  | sort -u
