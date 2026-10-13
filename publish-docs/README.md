# Publish Rust Docs

Installs a built `target/doc` tree into the versioned static docs site served by
Caddy at `sfgh.stellar.org` / `groundhog.dev` under `/docs/`.

This replaces the broken kellnr doc-generation path. It is the **receive + serve**
half: it takes an already-built `target/doc` and places it on the site. You still
need a `cargo doc` step before it to produce `target/doc` (see *Generating docs*).

## Layout produced

```
<docs-root>/
  index.html                       # auto-generated: each crate -> its latest
  _static/                         # rustdoc's shared CSS/JS/fonts (see below)
  <crate>/
    <version>/                     # immutable; contents of target/doc
      index.html                   # redirect -> <lib-name>/index.html
      <lib-name>/index.html        # rustdoc entry point
      static.files -> ../../_static
      ...                          # rustdoc assets + dependency docs
    latest -> <newest-stable>      # symlink, newest STABLE version by semver
```

`latest` points at the highest version with **no pre-release suffix** (no `-`);
if every version is a pre-release, it points at the highest of those. So a hotfix
to an old line, or a `-nightly`/`-rc` build, never hijacks `latest`.

Versions are **immutable**: re-publishing an existing version fails unless
`force: true`.

## Usage

```yaml
- name: Build docs
  shell: bash
  run: cargo doc --no-deps   # or full; see "Generating docs" below

- name: Publish docs
  uses: ./actions/publish-docs
  with:
    crate: groundhog-gateway
    version: ${{ steps.publish-tag.outputs.version }}
    # doc-dir defaults to ./target/doc
    # lib-name defaults to <crate> with '-' -> '_'
```

### Inputs

| Input       | Required | Default                  | Notes |
|-------------|----------|--------------------------|-------|
| `crate`     | yes      | —                        | Crate name, e.g. `groundhog-gateway`. |
| `version`   | yes      | —                        | e.g. `0.16.2`; pre-releases contain a `-`. |
| `doc-dir`   | no       | `./target/doc`           | The built rustdoc tree to publish. |
| `lib-name`  | no       | `<crate>` with `-`→`_`   | rustdoc entry subdir; override if the lib name differs. |
| `docs-root` | no       | `/home/hog12/www/docs`   | Base dir of the static site (must be writable by the runner). |
| `force`     | no       | `false`                  | Overwrite an already-published version. |
| `shared-static` | no   | `true`                   | Serve rustdoc's asset bundle from one shared `_static/` dir. |
| `publish-jobs`  | no   | `4`                      | Concurrent file copies into the docs tree; `1` is serial. |

## Cost model

The docs tree is a shared, high-latency filesystem: every create, stat and
chmod on it is a synchronous round trip, so publish time tracks the **number of
remote operations**, not the number of bytes. For one real rustdoc tree (817
files, 80 directories) the script issues:

| | operations against the docs tree |
|---|---|
| naive copy + `chmod -R` on the installed tree | ~1890 |
| this script, first crate of a release | ~950 |
| this script, steady state | ~880 |

Three things keep that count down, and each is easy to undo by accident:

* **Modes are normalised on the source tree, on local disk, before copying.**
  `cp -a` preserves modes, so the installed copy lands correct. Running
  `chmod -R` on the *installed* tree instead costs a second full walk of it —
  one synchronous chmod per file (~980 of the ~1890 above).
* **rustdoc's `static.files/` is installed once into `<docs-root>/_static`** and
  every version directory symlinks to it. It is ~34 files / ~1.9 MB, identical
  for every crate built with the same toolchain, so a 12-crate release used to
  ship ~400 redundant remote creates and ~22 MB of duplicate bytes. The
  filenames are content-hashed (`rustdoc-77263533.css`), so the shared directory
  safely holds the union of every toolchain's assets and an existing name is
  already the right bytes.
* **Files are copied with bounded concurrency** (`publish-jobs`). Staging is
  private until the final `mv`, so completion order does not matter, and
  overlapping the round trips is the only thing that gets a few thousand small
  files done in seconds. Set it to `1` to take pressure off the docs host.

Already-published versions are never touched: a publish walks only the version
being installed, so cost does not grow with release count.

## Generating docs

Full (with-deps) `cargo doc` output is self-contained (relative links; only
`std`/`core` link out to `doc.rust-lang.org`), so the tree is portable across
machines. `--no-deps` is smaller but breaks links to dependency types. Pick per
crate and pass the resulting `target/doc` as `doc-dir`.

## Local testing

The script honors `DOCS_ROOT`, so the test suite runs against a temp dir with no
privileges and never touches the real site:

```bash
./test/run-tests.sh
```

## Access

`/docs/*` is served behind the same basic auth as `/builds/*` in the Caddy
config. The publish script `chmod`s output group/other-readable so the `caddy`
user can serve it.
