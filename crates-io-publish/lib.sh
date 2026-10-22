#!/usr/bin/env bash
# Shared helpers for check.sh and publish.sh. Sourced, not run.
#
# CRATES_IO_API_URL and CRATES_IO_INDEX_URL default to crates.io; the tests
# point them at a local mock.

CRATES_IO_API_URL="${CRATES_IO_API_URL:-https://crates.io/api/v1}"
CRATES_IO_INDEX_URL="${CRATES_IO_INDEX_URL:-https://index.crates.io}"
# crates.io asks API clients for at most one request per second.
CRATES_IO_API_DELAY="${CRATES_IO_API_DELAY:-1}"
USER_AGENT="thruputchain-actions/crates-io-publish (https://github.com/thruputchain/actions)"

METADATA=$(cargo metadata --no-deps --format-version 1 --locked)

# package_field <package> <jq filter>: the filter applied to the package's
# `cargo metadata` entry, as compact JSON; empty when there's no such package.
package_field() {
  jq -c --arg name "$1" ".packages[] | select(.name == \$name) | $2" <<<"$METADATA"
}

# package_version <package>
package_version() {
  package_field "$1" .version | jq -r .
}

index_path() {
  local name="${1,,}"
  case ${#name} in
    1) echo "1/$name" ;;
    2) echo "2/$name" ;;
    3) echo "3/${name:0:1}/$name" ;;
    *) echo "${name:0:2}/${name:2:2}/$name" ;;
  esac
}

# on_index <crate> <version>: whether the crates.io index lists the version
# (yanked or not). Exits when the index can't be read, so an outage is never
# mistaken for "not published".
on_index() {
  local body code
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' "$CRATES_IO_INDEX_URL/$(index_path "$1")")
  case "$code" in
    # Not grep -q: exiting at the first match can fail jq with SIGPIPE,
    # which pipefail would report as "not listed".
    200) jq -r '.vers' "$body" | grep -xF "$2" >/dev/null ;;
    404 | 410 | 451) return 1 ;;
    *)
      echo "::error::crates.io index probe for '$1' failed (HTTP $code)"
      exit 1
      ;;
  esac
}

# crates_io_name <crate>: "missing", or the name crates.io knows the crate
# by. crates.io treats - and _ (and case) as the same name, so this differs
# from <crate> when someone else's crate holds the name.
crates_io_name() {
  local body code
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' -H "User-Agent: $USER_AGENT" \
    "$CRATES_IO_API_URL/crates/$1")
  sleep "$CRATES_IO_API_DELAY"
  case "$code" in
    200) jq -r '.crate.name' "$body" ;;
    404) echo missing ;;
    *)
      echo "::error::crates.io lookup of '$1' failed (HTTP $code)" >&2
      return 1
      ;;
  esac
}

# check_packages: every package in PACKAGES exists, may publish to crates.io,
# and shares one version, which it sets as VERSION.
check_packages() {
  local pkg version
  VERSION=""
  if [ -z "${PACKAGES// /}" ]; then
    echo "::error::packages is empty"
    exit 1
  fi
  for pkg in $PACKAGES; do
    version=$(package_version "$pkg")
    if [ -z "$version" ]; then
      echo "::error::'$pkg' is not a package in this workspace"
      exit 1
    fi
    # null: publishable anywhere; [] is publish = false.
    if ! package_field "$pkg" .publish | jq -e '. == null or index("crates-io") != null' >/dev/null; then
      echo "::error::$pkg sets publish = $(package_field "$pkg" .publish), which excludes crates.io"
      echo "::error::Set publish = [\"crates-io\"] (or remove the field) and drop registry = \"...\" from its dependencies"
      exit 1
    fi
    if [ -z "$VERSION" ]; then
      VERSION="$version"
    elif [ "$version" != "$VERSION" ]; then
      echo "::error::$pkg is at $version but ${PACKAGES%% *} is at $VERSION; one call releases one version"
      exit 1
    fi
  done
}
