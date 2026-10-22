#!/usr/bin/env bash
# Test harness for publish-docs.sh. Runs everything against a temp DOCS_ROOT,
# so it needs no privileges and never touches the real docs site.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/publish-docs.sh"
pass=0; fail=0

assert() { # assert "name" "test-expression"
  if eval "$2"; then echo "ok   - $1"; pass=$((pass+1));
  else echo "FAIL - $1"; fail=$((fail+1)); fi
}

# Build a fake `target/doc` tree containing one crate's rustdoc entry.
# $1 = lib_name (underscored). Echoes the doc dir path.
make_doc() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/$1"
  echo "<html>real docs for $1</html>" > "$d/$1/index.html"
  echo "$d"
}

# As make_doc, but shaped like a real rustdoc tree: content-hashed shared
# assets under static.files/, a nested src/ view, and cargo's .lock.
make_full_doc() {
  local d; d="$(make_doc "$1")"
  mkdir -p "$d/static.files" "$d/src/$1"
  echo "body{}"      > "$d/static.files/rustdoc-77263533.css"
  echo "/*norm*/"    > "$d/static.files/normalize-9960930a.css"
  echo "<html>src</html>" > "$d/src/$1/lib.rs.html"
  echo "lock" > "$d/.lock"; chmod 600 "$d/.lock"
  echo "$d"
}

# ---- Test 1: happy path ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
doc="$(make_doc thruput_gateway)"
"$SCRIPT" thruput-gateway 0.1.0 "$doc" >/dev/null
assert "1.1 version dir + entry copied" \
  '[ -f "$T/docs/thruput-gateway/0.1.0/thruput_gateway/index.html" ]'
assert "1.2 redirect index points at lib entry" \
  'grep -q "thruput_gateway/index.html" "$T/docs/thruput-gateway/0.1.0/index.html"'
assert "1.3 latest -> 0.1.0" \
  '[ "$(readlink "$T/docs/thruput-gateway/latest")" = "0.1.0" ]'

# ---- Test 2: latest = newest stable by semver ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" mycrate 0.9.0  "$(make_doc mycrate)" >/dev/null
"$SCRIPT" mycrate 0.10.0 "$(make_doc mycrate)" >/dev/null
"$SCRIPT" mycrate 0.2.0  "$(make_doc mycrate)" >/dev/null   # publishing older last
assert "2.1 latest is highest semver, not last-published" \
  '[ "$(readlink "$T/docs/mycrate/latest")" = "0.10.0" ]'
"$SCRIPT" mycrate 0.11.0-nightly.1 "$(make_doc mycrate)" >/dev/null
assert "2.2 pre-release does not become latest over a stable" \
  '[ "$(readlink "$T/docs/mycrate/latest")" = "0.10.0" ]'

# ---- Test 3: only pre-releases -> highest pre-release is latest ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" pre 0.1.0-rc.1 "$(make_doc pre)" >/dev/null
"$SCRIPT" pre 0.1.0-rc.2 "$(make_doc pre)" >/dev/null
assert "3.1 highest pre-release wins when no stable exists" \
  '[ "$(readlink "$T/docs/pre/latest")" = "0.1.0-rc.2" ]'

# ---- Test 4: path-traversal / bad names rejected, nothing written ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
doc="$(make_doc x)"
assert "4.1 traversal crate rejected (nonzero exit)" \
  '! "$SCRIPT" "../evil" 1.0.0 "$doc" 2>/dev/null'
assert "4.2 slash in version rejected" \
  '! "$SCRIPT" ok "1/0" "$doc" 2>/dev/null'
assert "4.3 nothing escaped DOCS_ROOT" \
  '[ ! -e "$T/evil" ]'

# ---- Test 5: re-publishing a version is refused unless FORCE=1 ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" c 1.0.0 "$(make_doc c)" >/dev/null
assert "5.1 second publish of same version fails" \
  '! "$SCRIPT" c 1.0.0 "$(make_doc c)" 2>/dev/null'
assert "5.2 FORCE=1 allows overwrite" \
  'FORCE=1 "$SCRIPT" c 1.0.0 "$(make_doc c)" >/dev/null'

# ---- Test 6: lib_name override ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
doc="$(mktemp -d)"; mkdir -p "$doc/custom_entry"; echo hi > "$doc/custom_entry/index.html"
"$SCRIPT" some-crate 2.0.0 "$doc" custom_entry >/dev/null
assert "6.1 redirect honors lib_name override" \
  'grep -q "custom_entry/index.html" "$T/docs/some-crate/2.0.0/index.html"'

# ---- Test 7: top-level index lists each crate + its latest ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" alpha 1.0.0 "$(make_doc alpha)" >/dev/null
"$SCRIPT" beta  2.1.0 "$(make_doc beta)"  >/dev/null
assert "7.1 index links alpha latest" \
  'grep -q "alpha/latest/" "$T/docs/index.html"'
assert "7.2 index links beta latest" \
  'grep -q "beta/latest/" "$T/docs/index.html"'
assert "7.3 index shows beta version" \
  'grep -q "2.1.0" "$T/docs/index.html"'

# ---- Test 8: install touches only the version being published ----
# Re-walking every published version is what made a publish on the real
# (shared, high-latency) docs filesystem take minutes and get slower with each
# release. A sentinel mode on an already-published version detects the walk.
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" walk 1.0.0 "$(make_doc walk)" >/dev/null
chmod 600 "$T/docs/walk/1.0.0/walk/index.html"
"$SCRIPT" walk 1.1.0 "$(make_doc walk)" >/dev/null
assert "8.1 already-published version not re-walked" \
  '[ "$(stat -c %a "$T/docs/walk/1.0.0/walk/index.html")" = "600" ]'
assert "8.2 new version files are world-readable" \
  '[ "$(stat -c %a "$T/docs/walk/1.1.0/walk/index.html")" = "644" ]'
assert "8.3 new version dirs are world-traversable" \
  '[ "$(stat -c %a "$T/docs/walk/1.1.0")" = "755" ] &&
   [ "$(stat -c %a "$T/docs/walk/1.1.0/walk")" = "755" ]'
assert "8.4 landing page stays world-readable" \
  '[ -r "$T/docs/index.html" ] && [ "$(stat -c %a "$T/docs/index.html")" = "644" ]'

# ---- Test 9: rustdoc's static assets are shared, not copied per crate ----
# ~34 files / ~1.9 MB of identical CSS/JS/fonts per crate is most of a small
# crate's publish cost, and every one of those files is a remote create.
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" one 1.0.0 "$(make_full_doc one)" >/dev/null
assert "9.1 version dir points at the shared assets by symlink" \
  '[ -L "$T/docs/one/1.0.0/static.files" ]'
assert "9.2 assets resolve through the symlink" \
  '[ -f "$T/docs/one/1.0.0/static.files/rustdoc-77263533.css" ]'
assert "9.3 assets installed once, at the docs root" \
  '[ -f "$T/docs/_static/rustdoc-77263533.css" ]'
assert "9.4 shared assets are world-readable" \
  '[ "$(stat -c %a "$T/docs/_static/rustdoc-77263533.css")" = "644" ] &&
   [ "$(stat -c %a "$T/docs/_static")" = "755" ]'
# A second crate must reuse the existing files rather than rewriting them:
# content-hashed names mean an existing entry is already the right bytes.
touch -d "2000-01-01" "$T/docs/_static/rustdoc-77263533.css"
"$SCRIPT" two 1.0.0 "$(make_full_doc two)" >/dev/null
assert "9.5 second crate reuses shared assets, does not rewrite them" \
  '[ "$(stat -c %Y "$T/docs/_static/rustdoc-77263533.css")" = "946684800" ]'
assert "9.6 a new asset from another toolchain is added alongside" \
  'd="$(make_full_doc three)"; echo new > "$d/static.files/rustdoc-deadbeef.css";
   "$SCRIPT" three 1.0.0 "$d" >/dev/null;
   [ -f "$T/docs/_static/rustdoc-deadbeef.css" ] &&
   [ -f "$T/docs/_static/rustdoc-77263533.css" ]'
assert "9.7 shared asset dir is not listed as a crate on the landing page" \
  '! grep -q "_static/latest/" "$T/docs/index.html"'
assert "9.8 crate named _static is rejected" \
  '! "$SCRIPT" _static 1.0.0 "$(make_doc _static)" 2>/dev/null'

# ---- Test 10: SHARED_STATIC=0 keeps the old self-contained layout ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
SHARED_STATIC=0 "$SCRIPT" solo 1.0.0 "$(make_full_doc solo)" >/dev/null
assert "10.1 assets embedded in the version dir" \
  '[ -f "$T/docs/solo/1.0.0/static.files/rustdoc-77263533.css" ] &&
   [ ! -L "$T/docs/solo/1.0.0/static.files" ]'
assert "10.2 no shared dir created" '[ ! -e "$T/docs/_static" ]'

# ---- Test 11: cargo's .lock is a build artifact, not site content ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" locked 1.0.0 "$(make_full_doc locked)" >/dev/null
assert "11.1 .lock not published" '[ ! -e "$T/docs/locked/1.0.0/.lock" ]'

# ---- Test 12: the whole tree arrives, whatever the copy concurrency ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
doc="$(make_full_doc wide)"
for i in $(seq 1 40); do
  mkdir -p "$doc/wide/mod$i"; echo "<html>$i</html>" > "$doc/wide/mod$i/index.html"
done
PUBLISH_JOBS=8 "$SCRIPT" wide 1.0.0 "$doc" >/dev/null
got="$(find "$T/docs/wide/1.0.0" -type f | wc -l)"
want="$(find "$doc" -type f ! -path "*/static.files/*" ! -name .lock | wc -l)"
assert "12.1 every file copied under concurrency ($got == $want + redirect)" \
  '[ "$got" -eq "$((want + 1))" ]'
assert "12.2 nested source view preserved" \
  '[ -f "$T/docs/wide/1.0.0/src/wide/lib.rs.html" ]'
assert "12.3 serial mode produces the same tree" \
  'PUBLISH_JOBS=1 "$SCRIPT" wide 1.0.1 "$(make_full_doc wide)" >/dev/null;
   [ -f "$T/docs/wide/1.0.1/src/wide/lib.rs.html" ]'

# ---- Test 13: a failed publish leaves no staging dir on the docs tree ----
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
"$SCRIPT" clean 1.0.0 "$(make_doc clean)" >/dev/null
"$SCRIPT" clean 1.0.0 "$(make_doc clean)" 2>/dev/null || true
assert "13.1 no .tmp staging dir left behind after a refused publish" \
  '[ -z "$(find "$T/docs/clean" -maxdepth 1 -name ".tmp.*")" ]'

# ---- Test 14: a failed copy publishes nothing at all ----
# The copy runs concurrently into a staging dir, so a failure part-way through
# must abort the publish rather than install a partial tree. Injects a `cp`
# that fails on one file (permission tricks are useless when tests run as root).
T="$(mktemp -d)"; export DOCS_ROOT="$T/docs"
bin="$T/bin"; mkdir -p "$bin"
cat > "$bin/cp" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in *poison*) echo "cp: simulated failure" >&2; exit 1;; esac; done
exec /bin/cp "$@"
STUB
chmod +x "$bin/cp"
doc="$(make_full_doc part)"
for i in $(seq 1 30); do echo x > "$doc/part/f$i.html"; done
echo x > "$doc/part/poison.html"
assert "14.1 a failed copy exits nonzero" \
  '! PATH="$bin:$PATH" "$SCRIPT" part 1.0.0 "$doc" >/dev/null 2>&1'
assert "14.2 no partial version published" '[ ! -e "$T/docs/part/1.0.0" ]'
assert "14.3 latest not repointed at a failed publish" '[ ! -e "$T/docs/part/latest" ]'
assert "14.4 no staging dir leaked onto the docs tree" \
  '[ -z "$(find "$T/docs/part" -maxdepth 1 -name ".tmp.*" 2>/dev/null)" ]'
assert "14.5 the same tree publishes cleanly with a working cp" \
  '"$SCRIPT" part 1.0.0 "$doc" >/dev/null && [ -f "$T/docs/part/1.0.0/part/poison.html" ]'

echo; echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
