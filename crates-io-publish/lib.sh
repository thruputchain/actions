#!/usr/bin/env bash
# Shared helpers for check.sh and publish.sh. Sourced, not run.
#
# CRATES_IO_API_URL and CRATES_IO_INDEX_URL default to crates.io; the tests
# point them at a local mock.

CRATES_IO_API_URL="${CRATES_IO_API_URL:-https://crates.io/api/v1}"
CRATES_IO_INDEX_URL="${CRATES_IO_INDEX_URL:-https://index.crates.io}"
CRATES_IO_DL_URL="${CRATES_IO_DL_URL:-https://static.crates.io/crates}"
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
  local body code rc
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' "$CRATES_IO_INDEX_URL/$(index_path "$1")")
  case "$code" in
    # Not grep -q: exiting at the first match can fail jq with SIGPIPE,
    # which pipefail would report as "not listed".
    200)
      if jq -r '.vers' "$body" | grep -xF "$2" >/dev/null; then rc=0; else rc=1; fi
      rm -f "$body"
      return "$rc"
      ;;
    404 | 410 | 451) rm -f "$body"; return 1 ;;
    *)
      echo "::error::crates.io index probe for '$1' failed (HTTP $code)"
      exit 1
      ;;
  esac
}

# published_from <package> <version> <commit>: whether <version> on
# crates.io is this repository's <package> as of <commit>. A version found
# there isn't necessarily this repository's: a release that died partway
# leaves the names of crates it hadn't created yet to whoever claims them
# first. A version published through trusted publishing must come from this
# repository at <commit>. One published with an API token (a crate's first
# version, created with the bootstrap token, or one published by hand)
# records no source, so its contents must match the crate `cargo package`
# builds from the working tree. Exits when crates.io can't be read.
published_from() {
  local pkg="$1" vers="$2" sha="$3" body code trustpub
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' -H "User-Agent: $USER_AGENT" \
    "$CRATES_IO_API_URL/crates/$pkg/$vers")
  sleep "$CRATES_IO_API_DELAY"
  if [ "$code" != 200 ] || ! trustpub=$(jq -c '.version | if has("trustpub_data") then .trustpub_data else error("no trustpub_data") end' "$body"); then
    rm -f "$body"
    echo "::error::crates.io lookup of $pkg@$vers failed (HTTP $code)"
    exit 1
  fi
  rm -f "$body"
  if [ "$trustpub" = null ]; then
    if matches_published "$pkg" "$vers"; then
      return 0
    fi
    echo "::error::$pkg@$vers on crates.io was published with an API token, and its contents differ from $pkg at this commit (a cargo version other than the one that published it can also make them differ)"
    return 1
  fi
  if jq -e --arg r "${GITHUB_REPOSITORY,,}" --arg s "$sha" \
      '.provider == "github" and (.repository | ascii_downcase) == $r and .sha == $s' <<<"$trustpub" >/dev/null; then
    return 0
  fi
  echo "::error::$pkg@$vers on crates.io was published from $(jq -r '"\(.provider) \(.repository) at \(.sha)"' <<<"$trustpub"), not $GITHUB_REPOSITORY at $sha"
  return 1
}

# matches_published <package> <version>: whether the crate `cargo package`
# builds from the working tree has the same contents as <version> on
# crates.io, after checking the download against the index's checksum. Left
# out of the comparison: Cargo.lock (consumers of a library don't use it,
# and packaging it needs every workspace dependency on crates.io already),
# .cargo_vcs_info.json (the commit it came from) and Cargo.toml.orig (cargo
# builds from the normalized Cargo.toml). Exits when the crate can't be
# fetched or verified.
matches_published() {
  local pkg="$1" vers="$2" dir want got rc=0
  dir=$(mktemp -d)
  if ! want=$(curl -sSf "$CRATES_IO_INDEX_URL/$(index_path "$pkg")" \
      | jq -er --arg v "$vers" 'select(.vers == $v) | .cksum'); then
    echo "::error::Could not read the checksum of $pkg@$vers from the crates.io index"
    exit 1
  fi
  if ! curl -sSfL -o "$dir/published.crate" "$CRATES_IO_DL_URL/$pkg/$pkg-$vers.crate"; then
    echo "::error::Could not download $pkg@$vers from crates.io"
    exit 1
  fi
  got=$(sha256sum "$dir/published.crate" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "::error::The download of $pkg@$vers has sha256 $got, but the crates.io index lists $want"
    exit 1
  fi
  if ! cargo package --quiet --locked --no-verify --allow-dirty --exclude-lockfile \
      -p "$pkg" --target-dir "$dir/target"; then
    echo "::error::cargo package failed for $pkg"
    exit 1
  fi
  mkdir "$dir/local" "$dir/published"
  if ! tar -xzf "$dir/target/package/$pkg-$vers.crate" -C "$dir/local" --strip-components=1 ||
    ! tar -xzf "$dir/published.crate" -C "$dir/published" --strip-components=1; then
    echo "::error::Could not unpack $pkg@$vers to compare it"
    exit 1
  fi
  rm -f "$dir"/{local,published}/{Cargo.lock,.cargo_vcs_info.json,Cargo.toml.orig}
  diff -r "$dir/published" "$dir/local" || rc=1
  rm -rf "$dir"
  return "$rc"
}

# crates_io_name <crate>: "missing", or the name crates.io knows the crate
# by. crates.io treats - and _ (and case) as the same name, so this differs
# from <crate> when someone else's crate holds the name.
crates_io_name() {
  local body code name rc
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w '%{http_code}' -H "User-Agent: $USER_AGENT" \
    "$CRATES_IO_API_URL/crates/$1")
  sleep "$CRATES_IO_API_DELAY"
  case "$code" in
    # Callers run this in a command substitution, where errexit is off, so
    # jq's status must survive the cleanup explicitly: a 200 with a body
    # jq cannot read is a failed lookup, never an empty (= "published") name.
    200)
      if name=$(jq -er '.crate.name' "$body"); then rc=0; else rc=1; fi
      rm -f "$body"
      if [ "$rc" -ne 0 ]; then
        echo "::error::crates.io lookup of '$1' returned an unreadable body" >&2
        return 1
      fi
      printf '%s\n' "$name"
      ;;
    404) rm -f "$body"; echo missing ;;
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
