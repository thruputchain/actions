#!/usr/bin/env bash
# mode: check. Decides, without side effects, whether this commit releases
# the group, and verifies everything the tag and publish steps would reject,
# so a failure here leaves no tag behind.
#
# Env: PACKAGES, TAG_PREFIX, ON_EXISTING_TAG, BOOTSTRAP_TOKEN, GITHUB_OUTPUT.
# Outputs: version, tag, release ("true"/"false"), new-crates.
# Run tests: bash crates-io-publish/test_crates_io_publish.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

case "$ON_EXISTING_TAG" in
  fail | skip-if-published) ;;
  *)
    echo "::error::on-existing-tag must be \"fail\" or \"skip-if-published\", not \"$ON_EXISTING_TAG\""
    exit 1
    ;;
esac

check_packages
TAG="${TAG_PREFIX}${VERSION}"
echo "version=$VERSION" >> "$GITHUB_OUTPUT"
echo "tag=$TAG" >> "$GITHUB_OUTPUT"

HEAD_SHA=$(git rev-parse HEAD)
TAG_SHA=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)

if [ -n "$TAG_SHA" ] && [ "$TAG_SHA" != "$HEAD_SHA" ]; then
  if [ "$ON_EXISTING_TAG" = fail ]; then
    echo "::error::Tag $TAG already exists at $TAG_SHA, not at HEAD ($HEAD_SHA)"
    echo "::error::Bump the version to release this commit, or delete the tag if $VERSION was never published"
    exit 1
  fi

  # skip-if-published: the group was released from an earlier commit. That
  # holds only if every crate is on crates.io, published from the tag, and
  # crates.io would receive the same crate from HEAD. Comparing the packages
  # `cargo package` builds covers what a diff of the crate's directory
  # misses: inherited
  # [workspace.package] and [workspace.dependencies] values, and files from
  # outside it (readme = "../README.md"); and it ignores workspace changes
  # that don't reach the crate. No lockfile: it doesn't affect a library's
  # consumers, and packaging one needs every workspace dependency on
  # crates.io already.
  SCRATCH=$(mktemp -d)
  packaged() { # packaged <checkout> <package> <dir>
    local target
    target=$(mktemp -d -p "$SCRATCH")
    (cd "$1" && cargo package --quiet --locked --no-verify --allow-dirty --exclude-lockfile \
      -p "$2" --target-dir "$target")
    mkdir -p "$3"
    tar -xzf "$target/package/$2-$VERSION.crate" -C "$3" --strip-components=1
    rm -f "$3/.cargo_vcs_info.json" "$3/Cargo.toml.orig"
  }
  TAG_TREE=$(mktemp -d)
  git worktree add --quiet --detach "$TAG_TREE" "$TAG_SHA"
  trap 'git worktree remove --force "$TAG_TREE"; rm -rf "$SCRATCH"' EXIT

  for pkg in $PACKAGES; do
    if ! on_index "$pkg" "$VERSION"; then
      echo "::error::Tag $TAG points at $TAG_SHA (not this commit) but $pkg@$VERSION is not on crates.io"
      echo "::error::A previous release likely died between tag push and publish. Re-run it from the tagged commit, or delete the stale tag"
      exit 1
    fi
    cmp=$(mktemp -d -p "$SCRATCH")
    packaged "$TAG_TREE" "$pkg" "$cmp/tag"
    packaged . "$pkg" "$cmp/head"
    if ! diff -r "$cmp/tag" "$cmp/head"; then
      echo "::error::$pkg changed since $TAG ($TAG_SHA) but its version was not bumped"
      exit 1
    fi
    if ! published_from "$pkg" "$VERSION" "$TAG_SHA"; then
      echo "::error::crates.io's $pkg@$VERSION isn't the one $TAG releases: check who published it"
      exit 1
    fi
  done
  echo "::notice::$TAG is already released from $TAG_SHA and nothing changed since; this commit doesn't release it"
  echo "release=false" >> "$GITHUB_OUTPUT"
  echo "new-crates=" >> "$GITHUB_OUTPUT"
  exit 0
fi

NEW_CRATES=""
for pkg in $PACKAGES; do
  name=$(crates_io_name "$pkg")
  if [ "$name" = missing ]; then
    NEW_CRATES="$NEW_CRATES $pkg"
    echo "OK: $pkg is a new crate"
    continue
  fi
  if [ "$name" != "$pkg" ]; then
    echo "::error::crates.io already has a crate named '$name', which it treats as the same name as '$pkg'"
    exit 1
  fi
  # A re-run of a release commit finds its own versions published; without
  # the tag, the version was released from somewhere else.
  if [ -z "$TAG_SHA" ] && on_index "$pkg" "$VERSION"; then
    echo "::error::$pkg@$VERSION is already on crates.io but $TAG does not exist in this repository"
    echo "::error::Bump the version to release it from here"
    exit 1
  fi
  echo "OK: $pkg exists on crates.io"
done
NEW_CRATES="${NEW_CRATES# }"

if [ -n "$NEW_CRATES" ] && [ -z "$BOOTSTRAP_TOKEN" ]; then
  echo "::error::Creating new crates ($NEW_CRATES) needs bootstrap-token: a crates.io API token with the scopes publish-new and trusted-publishing"
  exit 1
fi

echo "release=true" >> "$GITHUB_OUTPUT"
echo "new-crates=$NEW_CRATES" >> "$GITHUB_OUTPUT"
