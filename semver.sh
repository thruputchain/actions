#!/usr/bin/env bash
# The one definition of the semver grammar this repo's actions accept.
#
# Sourced, not executed. cargo-publish/validate-tag.sh and
# cargo-yank/validate-version.sh both build their pattern from it, so a
# version that can be published can always also be yanked -- the two drifting
# apart is what let a v0.15.1-rc.1 tag reach cargo-publish and be rejected
# after cargo-version-tag had already created it.

# Emits an ERE matching <prefix>X.Y.Z with an optional pre-release suffix.
# The prefix is interpolated verbatim, so callers escape regex metacharacters
# in it first. Build metadata ('+sha') is deliberately not accepted -- nothing
# in this pipeline emits it.
groundhog_semver_regex() { # groundhog_semver_regex [escaped-prefix]
  local prefix="${1-}"
  # Core: no leading zeros in any component.
  local core='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
  # Pre-release: dot-separated identifiers, each numeric (no leading zeros) or
  # alphanumeric (at least one non-digit), per semver.org.
  local ident='(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)'
  printf '%s\n' "^${prefix}${core}(-${ident}(\.${ident})*)?\$"
}
