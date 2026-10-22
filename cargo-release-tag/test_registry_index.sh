#!/usr/bin/env bash
# Offline tests for registry-index.sh. Run: bash cargo-release-tag/test_registry_index.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/registry-index.sh"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT

package() { # package <name> [publish TOML value]
  mkdir -p "$WS/$1/src"
  : > "$WS/$1/src/lib.rs"
  {
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "$1"
    if [ -n "${2-}" ]; then printf 'publish = %s\n' "$2"; fi
  } > "$WS/$1/Cargo.toml"
}
package unset
package cratesio '["crates-io"]'
package private '["thruput"]'
package gitindex '["gitreg"]'
package noindex '["elsewhere"]'
package several '["thruput", "crates-io"]'
package unpublished 'false'
cat > "$WS/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["unset", "cratesio", "private", "gitindex", "noindex", "several", "unpublished"]
EOF
mkdir -p "$WS/.cargo"
cat > "$WS/.cargo/config.toml" <<'EOF'
[registries]
thruput = { index = "sparse+https://crates.example.net/api/v1/crates" }
gitreg = { index = "https://github.com/example/index" }
EOF

resolve() { # resolve <package> [registry-name] -> "<registry> <index>" | "error"
  (cd "$WS" && bash "$SCRIPT" ./Cargo.toml "$@" 2>/dev/null) || echo error
}

# ---- The package's publish field picks the registry ----
check "publish unset is crates.io"           "crates-io https://index.crates.io/" "$(resolve unset)"
check "publish crates-io is crates.io"       "crates-io https://index.crates.io/" "$(resolve cratesio)"
check "named registry from config.toml"      "thruput https://crates.example.net/api/v1/crates/" "$(resolve private)"
check "env index overrides config.toml" \
  "thruput https://env.example.net/index/" \
  "$(CARGO_REGISTRIES_THRUPUT_INDEX=sparse+https://env.example.net/index resolve private)"

# ---- registry-name chooses among allowed registries ----
check "several registries need a choice"     error "$(resolve several)"
check "registry-name picks crates.io"        "crates-io https://index.crates.io/" "$(resolve several crates-io)"
check "registry-name picks the private one"  "thruput https://crates.example.net/api/v1/crates/" "$(resolve several thruput)"
check "registry-name with publish unset"     "thruput https://crates.example.net/api/v1/crates/" "$(resolve unset thruput)"
check "registry-name outside publish"        error "$(resolve private crates-io)"

# ---- Nothing to probe ----
check "publish = false"                      error "$(resolve unpublished)"
check "package not in workspace"             error "$(resolve nosuchpackage)"
check "registry with no index"               error "$(resolve noindex)"
check "git index can't be probed"            error "$(resolve gitindex)"

exit "$FAILED"
