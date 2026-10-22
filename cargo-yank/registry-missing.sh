#!/usr/bin/env bash
# Decides whether a failed `cargo yank` failed only because the registry has
# no such crate or version -- the one failure the action may count as a skip
# (e.g. a crate added to the workspace after that version was published).
#
# Only an answer from the registry itself qualifies. Cargo's own errors -- an
# unconfigured registry ("registry index was not found in any
# configuration"), a missing token, a network failure -- and any other
# registry error (401/403/5xx) must fail the yank instead, or a mistyped
# input turns a yank into a green no-op.
#
# Usage: registry-missing.sh < cargo-output   (exit 0: missing, 1: real failure)
# Run tests: bash cargo-yank/test_registry_missing.sh
set -euo pipefail

OUTPUT="$(cat)"

# "the remote server responded with an error (status N ...)": current cargo.
# "api errors (status N ...)": older cargo.
REGISTRY_ERROR='(the remote server responded with an error|api errors) \(status [0-9]+'
MISSING_404='(the remote server responded with an error|api errors) \(status 404'
# Registries that report a missing version without a 404 still say so.
MISSING_TEXT='does not have a version|has not been published'

grep -qE "$REGISTRY_ERROR" <<<"$OUTPUT" || exit 1
grep -qE "$MISSING_404" <<<"$OUTPUT" && exit 0
grep -qiE "$MISSING_TEXT" <<<"$OUTPUT" && exit 0
exit 1
