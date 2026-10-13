#!/usr/bin/env bash
# Publish rustdoc output into the static docs tree served by Caddy.
#
# Usage: publish-docs.sh <crate> <version> <doc_dir> [lib_name]
#   <crate>    crate name, e.g. groundhog-gateway
#   <version>  semver, e.g. 0.16.2  (pre-releases contain a '-', e.g. 0.1.1-nightly.x)
#   <doc_dir>  path to a freshly-built target/doc tree
#   [lib_name] rustdoc entry subdir; defaults to <crate> with '-' replaced by '_'
# Env:
#   DOCS_ROOT      base docs directory (default /home/hog12/www/docs)
#   FORCE=1        overwrite an already-published version (otherwise refused)
#   SHARED_STATIC  1 (default) to serve rustdoc's static assets from one shared
#                  directory instead of a private copy per crate; 0 to embed
#   PUBLISH_JOBS   concurrent file copies into the docs tree (default 4, 1 = serial)
#
# NOTE ON COST. The docs tree is a shared, high-latency filesystem: every
# create, stat and chmod on it is a synchronous round trip, so publishing time
# tracks the NUMBER of remote operations far more closely than the number of
# bytes. Everything below is arranged to keep that count down -- see the
# comments at each step before "simplifying" one away.
#
# $doc_dir is treated as scratch: its modes are normalised in place (it is a
# build directory, and doing it here is what keeps the far side cheap).
set -euo pipefail

DOCS_ROOT="${DOCS_ROOT:-/home/hog12/www/docs}"
SHARED_STATIC="${SHARED_STATIC:-1}"
PUBLISH_JOBS="${PUBLISH_JOBS:-4}"
# Shared rustdoc assets live here, beside the crate directories. The leading
# underscore keeps it out of the crate namespace.
STATIC_DIR="_static"
die() { echo "publish-docs: $*" >&2; exit 1; }

# Regenerate the top-level docs landing page: one entry per crate -> its latest.
# The `latest` test also filters out non-crate entries such as $STATIC_DIR.
gen_index() {
  local idx="$DOCS_ROOT/index.html" c v
  {
    echo '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Crate docs</title>'
    echo '<style>body{font:14px sans-serif;margin:2rem}</style></head><body>'
    echo '<h1>Crate documentation</h1><ul>'
    find "$DOCS_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | while read -r c; do
      [ -L "$DOCS_ROOT/$c/latest" ] || continue
      v="$(readlink "$DOCS_ROOT/$c/latest")"
      printf '<li><a href="%s/latest/">%s</a> (latest: %s)</li>\n' "$c" "$c" "$v"
    done
    echo '</ul></body></html>'
  } > "$idx"
}

# Install rustdoc's shared CSS/JS/font bundle into $DOCS_ROOT/$STATIC_DIR.
#
# rustdoc emits ~34 files / ~1.9 MB of these per crate, byte-identical for every
# crate built with the same toolchain -- so a 12-crate release used to ship ~400
# redundant remote creates and ~22 MB. The filenames are content-hashed
# (rustdoc-77263533.css, normalize-9960930a.css), so one shared directory holds
# the union of every toolchain's assets and an existing name is already the
# right bytes: the common case costs one stat per file and copies nothing.
install_shared_static() {
  local src="$1" dest="$DOCS_ROOT/$STATIC_DIR" f base t
  mkdir -p "$dest"
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    [ -e "$dest/$base" ] && continue
    # Install via a temp name so a concurrent publish never sees a partial file.
    t="$(mktemp "$dest/.tmp.XXXXXX")"
    cp "$f" "$t" && chmod a+r "$t" && mv -f "$t" "$dest/$base" \
      || { rm -f "$t"; die "failed to install shared asset: $base"; }
  done
  chmod a+rX "$dest"
}

# Copy a built doc tree into the staging directory.
#   - static.files is skipped when it is shared (installed once, above).
#   - cargo's .lock is a build-directory artifact and never belongs on the site.
copy_tree() {
  local src="$1" dst="$2"
  local -a excl=( ! -path './.lock' )
  [ "$SHARED_STATIC" = "1" ] && excl+=( ! -path './static.files' ! -path './static.files/*' )

  # Create the directory skeleton first, serially: parallel `cp --parents`
  # workers would otherwise race to create the same parent. `find` walks
  # pre-order, so every parent is created before its children and plain `mkdir`
  # needs exactly one call per directory -- `mkdir -p` would re-issue one per
  # path component, which on a remote filesystem is a round trip each.
  (cd "$src" && find . -mindepth 1 -type d "${excl[@]}" -print0) \
    | (cd "$dst" && xargs -0 -r mkdir --)

  # Then copy the files with bounded concurrency. Staging is private until the
  # mv below, so completion order does not matter, and overlapping the round
  # trips is the only thing that gets a few thousand small files done in
  # seconds on a synchronous remote filesystem. PUBLISH_JOBS=1 restores the
  # old serial behaviour if the docs host ever needs the pressure taken off.
  (cd "$src" && find . ! -type d "${excl[@]}" -print0) \
    | (cd "$src" && xargs -0 -r -P "$PUBLISH_JOBS" -n 64 cp -a --parents -t "$dst" --)
}

[ $# -ge 3 ] || die "usage: publish-docs.sh <crate> <version> <doc_dir> [lib_name]"
crate="$1"; version="$2"; doc_dir="$3"; lib_name="${4:-}"
[ -d "$doc_dir" ] || die "doc_dir not a directory: $doc_dir"
[ -n "$lib_name" ] || lib_name="${crate//-/_}"

# Validate names: conservative charset, and explicitly reject traversal.
valid='^[A-Za-z0-9._-]+$'
[[ "$crate"   =~ $valid ]] || die "invalid crate name: $crate"
[[ "$version" =~ $valid ]] || die "invalid version: $version"
case "$crate/$version" in *..*) die "path traversal rejected: $crate/$version";; esac
[ "$crate" = "$STATIC_DIR" ] && die "crate name reserved for shared assets: $crate"

crate_dir="$DOCS_ROOT/$crate"
dest="$crate_dir/$version"
mkdir -p "$crate_dir"

# Versions are immutable. Check before building anything: the re-check after
# staging closes the race, but this one avoids copying a whole tree to throw
# it away.
if [ -e "$dest" ] && [ "${FORCE:-0}" != "1" ]; then
  die "version already published: $dest (set FORCE=1 to overwrite)"
fi

# Make the tree readable by the Caddy user HERE, on local disk, while it is
# still cheap: `cp -a` preserves modes, so the installed copy lands correct.
# Doing it on the far side instead means a second full walk of the tree on the
# shared filesystem -- one synchronous chmod per file, for files that rustdoc
# already emits as 644/755.
chmod -R a+rX "$doc_dir"

# Atomic install: build the tree in a staging dir, then mv it into place. The
# staging dir is a sibling of $dest so the mv is a rename, not a copy.
tmp="$(mktemp -d "$crate_dir/.tmp.${version}.XXXXXX")"
# Never leave a half-built staging tree behind on the shared filesystem.
cleanup() { [ -n "${tmp:-}" ] && [ -d "$tmp" ] && rm -rf "$tmp"; return 0; }
trap cleanup EXIT
tmp_abs="$(cd "$tmp" && pwd)"

if [ "$SHARED_STATIC" = "1" ] && [ -d "$doc_dir/static.files" ]; then
  install_shared_static "$doc_dir/static.files"
  # rustdoc pages reference ../static.files/<asset> relative to this version
  # dir, so a symlink here redirects them at the shared copy with no rewriting.
  # Resolves identically from the staging dir and from $dest (same depth).
  ln -sfn "../../$STATIC_DIR" "$tmp_abs/static.files"
fi

copy_tree "$doc_dir" "$tmp_abs"
printf '<!DOCTYPE html><meta http-equiv="refresh" content="0; url=%s/index.html">\n' \
  "$lib_name" > "$tmp/index.html"
# Only the staging root itself still needs opening up: mktemp -d makes it 0700,
# and everything under it was already correct before it was copied.
chmod a+rX "$tmp"

if [ -e "$dest" ]; then
  if [ "${FORCE:-0}" = "1" ]; then rm -rf "$dest"
  else die "version already published: $dest (set FORCE=1 to overwrite)"; fi
fi
mv "$tmp" "$dest"

# Repoint `latest`: newest STABLE version (no '-') by semver; else newest overall.
# (sort -V ranks pre-releases like 0.1.1-nightly ABOVE 0.1.1, so stable must be
# selected explicitly. The `latest` symlink is excluded from the version list
# because `find -type d` without -L does not follow it.)
latest="$(
  versions="$(find "$crate_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')"
  stable="$(printf '%s\n' "$versions" | grep -v -- '-' || true)"
  if [ -n "$stable" ]; then printf '%s\n' "$stable"   | sort -V | tail -1
  else                      printf '%s\n' "$versions" | sort -V | tail -1; fi
)"
ln -sfn "$latest" "$crate_dir/latest"

gen_index

# The version tree was made readable before install; only the containing dir
# and the regenerated landing page still need it.
chmod a+rX "$crate_dir" "$DOCS_ROOT/index.html"

echo "published $crate $version (latest -> $latest)"
