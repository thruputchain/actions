#!/usr/bin/env bash
# Local tests for registry-missing.sh. Run: bash cargo-yank/test_registry_missing.sh
#
# The fixtures are real `cargo yank` output, captured against a local
# registry. A change that lets a configuration, auth or network failure count
# as "not published" would make a yank silently do nothing, so it fails here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/registry-missing.sh"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

verdict() { # verdict <cargo-output> -> "skip" | "fail"
  if bash "$SCRIPT" <<<"$1" >/dev/null 2>&1; then echo skip; else echo fail; fi
}

registry_error() { # registry_error <status> <detail>
  printf '    Updating `local` index\n        Yank foo@1.0.0\nerror: failed to yank from the registry at http://127.0.0.1:8765\n\nCaused by:\n  the remote server responded with an error (status %s): %s\n' "$1" "$2"
}

# ---- Skip: the registry says the crate or version isn't there ----
check "version not published (404)" skip \
  "$(verdict "$(registry_error '404 Not Found' 'crate `foo` does not have a version `9.9.9`')")"
check "crate not published (404)"   skip \
  "$(verdict "$(registry_error '404 Not Found' 'crate `nocrate` does not exist')")"
check "older cargo wording (404)"   skip \
  "$(verdict 'error: failed to yank from the registry at https://example.net

Caused by:
  api errors (status 404 Not Found): crate `foo` does not have a version `9.9.9`')"
check "missing version without 404" skip \
  "$(verdict "$(registry_error '400 Bad Request' 'crate `foo` does not have a version `9.9.9`')")"

# ---- Fail: anything else ----
check "unknown registry name"       fail \
  "$(verdict 'error: registry index was not found in any configuration: `typo`')"
check "registry rejects the token"  fail \
  "$(verdict "$(registry_error '403 Forbidden' 'authentication failed: the token is invalid')")"
check "403 mentioning 'does not exist'" fail \
  "$(verdict "$(registry_error '403 Forbidden' 'user `ci` does not exist')")"
check "registry server error"       fail \
  "$(verdict "$(registry_error '500 Internal Server Error' 'internal error')")"
check "missing token"               fail \
  "$(verdict 'error: failed to yank from the registry at http://127.0.0.1:8765

Caused by:
  please provide a non-empty token')"
check "registry unreachable"        fail \
  "$(verdict 'warning: spurious network error (1 try remaining): [7] Could not connect to server (Failed to connect to 127.0.0.1 port 1 after 0 ms: Could not connect to server)
error: failed to update registry `down`

Caused by:
  download of config.json failed

Caused by:
  [7] Could not connect to server (Failed to connect to 127.0.0.1 port 1 after 0 ms: Could not connect to server)')"
check "empty output"                fail "$(verdict '')"

if [ "$FAILED" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
