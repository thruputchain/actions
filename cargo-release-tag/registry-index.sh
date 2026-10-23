#!/usr/bin/env bash
# Resolves the registry a package publishes to and that registry's sparse
# index URL, for the skip-if-published probe.
#
# The registry comes from the package's `publish` field: unset or
# ["crates-io"] is crates.io; a single named registry is that registry. A
# registry-name argument picks one when `publish` allows several (or any),
# and must be one the package may publish to.
#
# A named registry's index comes from CARGO_REGISTRIES_<NAME>_INDEX when set
# (as cargo reads it), else from .cargo/config.toml (or the legacy
# .cargo/config) next to the manifest or in the working directory, written
# either way:
#   [registries]
#   name = { index = "sparse+https://..." }
# or
#   [registries.name]
#   index = "sparse+https://..."
#
# Usage: registry-index.sh <cargo-toml-path> <package> [registry-name]
# Prints: <registry> <index-url-with-trailing-slash>
# Run tests: bash cargo-release-tag/test_registry_index.sh
set -euo pipefail

MANIFEST="${1?cargo-toml-path required}"
PACKAGE="${2?package required}"
REQUESTED="${3-}"

PUBLISH=$(cargo metadata --manifest-path "$MANIFEST" --format-version 1 --no-deps \
  | jq -c --arg name "$PACKAGE" '[.packages[] | select(.name == $name)] | if length == 0 then "missing" else .[0].publish end')

case "$PUBLISH" in
  '"missing"')
    echo "::error::Package '$PACKAGE' not found in workspace" >&2
    exit 1
    ;;
  '[]')
    echo "::error::Package '$PACKAGE' has publish = false; it has no registry to check" >&2
    exit 1
    ;;
esac

if [ -n "$REQUESTED" ]; then
  if [ "$PUBLISH" != null ] && ! jq -e --arg r "$REQUESTED" 'index($r) != null' <<<"$PUBLISH" >/dev/null; then
    echo "::error::registry-name is '$REQUESTED', but $PACKAGE publishes only to $PUBLISH" >&2
    exit 1
  fi
  REGISTRY="$REQUESTED"
elif [ "$PUBLISH" = null ]; then
  REGISTRY=crates-io
elif [ "$(jq length <<<"$PUBLISH")" = 1 ]; then
  REGISTRY=$(jq -r '.[0]' <<<"$PUBLISH")
else
  echo "::error::$PACKAGE may publish to $PUBLISH; set registry-name to the one to check" >&2
  exit 1
fi

if [ "$REGISTRY" = crates-io ]; then
  echo "crates-io https://index.crates.io/"
  exit 0
fi

# cargo's environment form of registries.<name>.index: upper-cased, - to _.
ENV_NAME="CARGO_REGISTRIES_$(printf '%s' "$REGISTRY" | tr '[:lower:]-' '[:upper:]_')_INDEX"
INDEX="${!ENV_NAME-}"
config_index() { # config_index <config file> -> the index for $REGISTRY, or nothing
  # The inline table under [registries], or the first `index =` inside the
  # [registries.<name>] table (and before the next table header). The name
  # is compared literally, never as a pattern.
  awk -v name="$REGISTRY" '
    function unquote(s) { sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); return s }
    /^[[:space:]]*\[/ {
      registries = ($0 ~ /^[[:space:]]*\[registries\][[:space:]]*$/)
      named = ($0 == "[registries." name "]")
      next
    }
    registries && index($0, name) == 1 && substr($0, length(name) + 1) ~ /^[[:space:]]*=.*index[[:space:]]*=/ { print unquote($0); exit }
    named && /^[[:space:]]*index[[:space:]]*=/ { print unquote($0); exit }
  ' "$1"
}
MANIFEST_DIR=$(dirname "$MANIFEST")
for cfg in "$MANIFEST_DIR/.cargo/config.toml" "$MANIFEST_DIR/.cargo/config" .cargo/config.toml .cargo/config; do
  [ -n "$INDEX" ] && break
  [ -f "$cfg" ] && INDEX=$(config_index "$cfg")
done
if [ -z "$INDEX" ]; then
  echo "::error::No index for registry '$REGISTRY': set $ENV_NAME or add it to .cargo/config.toml" >&2
  exit 1
fi
case "$INDEX" in
  sparse+*) ;;
  *)
    echo "::error::Registry '$REGISTRY' has index '$INDEX'; only sparse indexes can be probed" >&2
    exit 1
    ;;
esac
INDEX="${INDEX#sparse+}"
echo "$REGISTRY ${INDEX%/}/"
