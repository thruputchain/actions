#!/usr/bin/env bash
# Local tests for new-packages.sh and checkable-packages.sh.
# Run: bash cargo-semver-checks/test_new_packages.sh
#
# Each new-packages.sh case builds a throwaway git repository with a cargo
# workspace, tags a baseline, changes the workspace, and checks which packages
# the script reports as missing from the baseline. Needs cargo, git and jq.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/new-packages.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

repo() { # repo <dir>: an empty repository to build a fixture in
  mkdir -p "$1"
  git -C "$1" init -q
  # Only where no identity is configured (a CI runner): commit hooks may
  # refuse an author that differs from the configured one.
  git -C "$1" config user.email >/dev/null || git -C "$1" config user.email t@example.com
  git -C "$1" config user.name >/dev/null || git -C "$1" config user.name t
}

crate() { # crate <dir> <name> [<dependency line>]
  mkdir -p "$1/src"
  : > "$1/src/lib.rs"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n%s\n' \
    "$2" "${3:-}" > "$1/Cargo.toml"
}

kind() { # kind <dir> <name> <manifest lines>: a crate with no default lib target
  mkdir -p "$1/src"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n%s\n' "$2" "$3" > "$1/Cargo.toml"
}

workspace() { # workspace <dir> <member>...
  local dir="$1"; shift
  local members=""
  for m in "$@"; do members+="\"$m\", "; done
  printf '[workspace]\nresolver = "2"\nmembers = [%s]\n' "${members%, }" > "$dir/Cargo.toml"
}

commit() { # commit <dir> [<tag>]
  git -C "$1" add -A
  git -C "$1" commit -qm fixture
  if [ -n "${2:-}" ]; then git -C "$1" tag "$2"; fi
}

new_packages() { # new_packages <repo> <manifest> <rev>: the script's output, one line
  (cd "$1" && bash "$SCRIPT" "$2" "$3") | paste -sd ' ' -
}

# ---- Added and renamed crates are reported; unchanged ones aren't ----
R="$TMP/added"
repo "$R"
crate "$R/a" a; crate "$R/b" b
workspace "$R" a b
commit "$R" v0.1.0
check "nothing changed" "" "$(new_packages "$R" Cargo.toml v0.1.0)"
git -C "$R" mv b d
crate "$R/d" d; crate "$R/c" c
workspace "$R" a c d
commit "$R"
check "an added crate and a renamed one" "c d" "$(new_packages "$R" Cargo.toml v0.1.0)"

# ---- Paths marked export-ignore are still part of the baseline ----
R="$TMP/export-ignore"
repo "$R"
crate "$R/a" a; crate "$R/b" b
workspace "$R" a b
echo 'b export-ignore' > "$R/.gitattributes"
commit "$R" v0.1.0
crate "$R/c" c
workspace "$R" a b c
commit "$R"
check "a crate under an export-ignore path isn't new" "c" "$(new_packages "$R" Cargo.toml v0.1.0)"

# ---- A baseline from before the workspace existed: every package is new ----
R="$TMP/fresh"
repo "$R"
echo readme > "$R/README.md"
commit "$R" v0.0.1
crate "$R/a" a
workspace "$R" a
commit "$R"
check "baseline without the workspace manifest" "a" "$(new_packages "$R" Cargo.toml v0.0.1)"

# ---- A workspace below the repository root ----
R="$TMP/nested"
repo "$R"
mkdir -p "$R/rust"
crate "$R/rust/a" a
workspace "$R/rust" a
commit "$R" v0.1.0
crate "$R/rust/b" b
workspace "$R/rust" a b
commit "$R"
check "workspace in a subdirectory" "b" "$(new_packages "$R" rust/Cargo.toml v0.1.0)"
check "... named from inside it" "b" "$(new_packages "$R/rust" Cargo.toml v0.1.0)"

# ---- A baseline naming a registry: the caller's cargo configuration applies ----
R="$TMP/registry"
repo "$R"
crate "$R/a" a
crate "$R/b" b 'a = { path = "../a", version = "0.1.0", registry = "old" }'
workspace "$R" a b
commit "$R" v0.1.0
crate "$R/b" b 'a = { path = "../a", version = "0.1.0" }'
crate "$R/c" c
workspace "$R" a b c
commit "$R"
if (cd "$R" && bash "$SCRIPT" Cargo.toml v0.1.0) >/dev/null 2>"$TMP/err"; then
  check "unknown baseline registry fails" "error" "exit 0"
else
  check "unknown baseline registry fails" "error" "error"
fi
check "... saying why" 1 "$(grep -c "can't read the workspace at v0.1.0" "$TMP/err")"
check "baseline registry the caller defines" "c" \
  "$(CARGO_REGISTRIES_OLD_INDEX=sparse+https://registry.invalid/ new_packages "$R" Cargo.toml v0.1.0)"

# ---- The current manifest must be tracked ----
R="$TMP/untracked"
repo "$R"
echo readme > "$R/README.md"
commit "$R" v0.1.0
crate "$R/a" a
workspace "$R" a
if (cd "$R" && bash "$SCRIPT" Cargo.toml v0.1.0) >/dev/null 2>"$TMP/err"; then
  check "untracked manifest fails" "error" "exit 0"
else
  check "untracked manifest fails" "error" "error"
fi

# ---- checkable-packages.sh: what cargo-semver-checks can select ----
R="$TMP/kinds"
mkdir -p "$R"
crate "$R/lib" lib
kind "$R/bin" bin ''; echo 'fn main() {}' > "$R/bin/src/main.rs"
kind "$R/pmacro" pmacro $'[lib]\nproc-macro = true'; : > "$R/pmacro/src/lib.rs"
kind "$R/private" private 'publish = false'; : > "$R/private/src/lib.rs"
kind "$R/cdylib" cdylib $'[lib]\ncrate-type = ["cdylib"]'; : > "$R/cdylib/src/lib.rs"
workspace "$R" lib bin pmacro private cdylib
check "library-like targets, publish = false included" "cdylib lib private" \
  "$(bash "$HERE/checkable-packages.sh" "$R/Cargo.toml" | paste -sd ' ' -)"

exit "$FAILED"
