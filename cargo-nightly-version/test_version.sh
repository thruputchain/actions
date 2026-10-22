#!/usr/bin/env bash
# Local tests for version.sh. Run: bash cargo-nightly-version/test_version.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/version.sh"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

# next-version: bumps patch and appends suffix with leading-g sha
check "next-version basic" \
  "0.17.2-nightly.20260622.gabc1234" \
  "$(bash "$SCRIPT" next-version 0.17.1 20260622 abc1234)"

# next-version rejects non X.Y.Z
set +e
bash "$SCRIPT" next-version "1.2" 20260622 abc1234 >/dev/null 2>&1
rc=$?
set -e
check "next-version rejects bad base (nonzero exit)" "nonzero" "$([ $rc -ne 0 ] && echo nonzero || echo zero)"

# apply: rewrites workspace.package version and internal '=' pins, leaves external deps alone
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<'EOF'
[workspace.package]
version = "0.17.1"

[workspace.dependencies]
thruput-xdr = { path = "thruput-xdr", version = "=0.17.1", registry = "thruput" }
thruput_rpc = { path = "thruput_rpc", version = "=0.17.1", registry = "thruput" }
xdrs = { registry = "thruput", version = "0.7.1" }
rpc_driver = { version = "0.8.2", registry = "thruput" }
EOF

bash "$SCRIPT" apply "0.17.1" "0.17.2-nightly.20260622.gabc1234" "$TMP"

check "workspace.package rewritten" \
  'version = "0.17.2-nightly.20260622.gabc1234"' \
  "$(grep -m1 '^version = ' "$TMP")"
check "internal pin thruput-xdr rewritten" \
  '1' \
  "$(grep -c 'thruput-xdr = { path = "thruput-xdr", version = "=0.17.2-nightly.20260622.gabc1234"' "$TMP")"
# both internal pins rewritten => two occurrences total
check "both internal pins rewritten" \
  '2' \
  "$(grep -c '"=0.17.2-nightly.20260622.gabc1234"' "$TMP")"
check "external xdrs untouched" \
  '1' \
  "$(grep -c 'version = "0.7.1"' "$TMP")"
check "external rpc_driver untouched" \
  '1' \
  "$(grep -c 'version = "0.8.2"' "$TMP")"
if [ "$FAILED" -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
