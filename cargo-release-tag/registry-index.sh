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
# (as cargo reads it), else from an inline
# `name = { index = "sparse+https://..." }` entry in .cargo/config.toml.
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
if [ -z "$INDEX" ] && [ -f .cargo/config.toml ]; then
  INDEX=$(sed -n "s/^${REGISTRY} *= *{ *index *= *\"\([^\"]*\)\".*/\1/p" .cargo/config.toml | head -1)
fi
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
