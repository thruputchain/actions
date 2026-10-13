# Cargo Doc Publish

Builds rustdoc for each publishable workspace crate and uploads it to the
versioned static docs site (served by Caddy at `groundhog.dev/docs`) via
[`../publish-docs/publish-docs.sh`](../publish-docs/README.md).

It mirrors **docs.rs**: each crate is built `--no-deps` (small, isolated), and
cross-crate links are rewritten to absolute URLs by the nightly rustdoc map
(`-Z rustdoc-map`):

- deps from the **private registry** → `<docs-base-url>/<dep>/<version>/<dep>/…`
  (this site)
- deps from **crates.io** → `https://docs.rs/<dep>/<version>/…` (built-in default)
- **same-workspace** crates (path deps) → `<docs-base-url>/<crate>/<version>/…`,
  injected as `--extern-html-root-url` per published member (the registry map
  does *not* cover path deps, which otherwise render as plain unlinked text)

Because that URL pattern is exactly the layout `publish-docs.sh` produces, links
to sibling crates and to crates in other repos resolve as soon as those crates'
docs have been uploaded.

Note on re-exports: a glob `pub use other_crate::*` is **inlined** by rustdoc by
default (the type looks defined locally). Add `#[doc(no_inline)]` to such
re-exports to render them as a link to the canonical crate instead — combined
with the maps above, that link points at the dependency's hosted page.

> Doc generation requires a **nightly** toolchain with `cargo` (the rustdoc map
> is nightly-only). The build runs online so it can resolve registry deps; pass
> `registry-token` when crates depend on private-registry crates.

## Inputs

| Input | Required | Default | Notes |
|-------|----------|---------|-------|
| `version` | yes | — | Docs version, e.g. `0.16.2`. Must equal every selected crate's `Cargo.toml` version (validated). Usually `cargo-version-tag`'s `version` output. |
| `cargo-toml-path` | no | `./Cargo.toml` | Workspace/crate manifest. |
| `packages` | no | all | Space-separated; default is all workspace packages minus `publish=false` and `arch-only-packages`. |
| `arch-only-packages` | no | — | Packages that only build for wasm/rv32; skipped (same as the dry-run host steps). |
| `toolchain` | no | `nightly` | Nightly toolchain with cargo, e.g. `nightly-2026-01-30`. |
| `registry-name` | no | `groundhog` | Private registry name from `.cargo/config.toml`; its deps map to `docs-base-url`. |
| `registry-token` | no | — | Token so the doc build can fetch private-registry deps. |
| `docs-base-url` | no | `https://groundhog.dev/docs` | Public base URL used for cross-crate link rewriting. |
| `docs-root` | no | `/home/hog12/www/docs` | Filesystem root of the docs site (runner must be able to write it). |
| `force` | no | `false` | Overwrite existing doc versions (used by the regenerator). |
| `expected-tag` | no | — | If set (e.g. `v0.16.2`), assert `HEAD` is exactly this tag before doing anything. |

## 1. As part of the publish workflow

Add a step to `publish.yml` **after** the `cargo-publish` step, so docs upload
only once the crates actually publish:

```yaml
      - name: publish docs
        uses: ./actions/cargo-doc
        with:
          version: ${{ steps.publish-tag.outputs.version }}
          registry-name: groundhog
          registry-token: ${{ secrets.GROUNDHOG_REGISTRY_TOKEN }}
          toolchain: nightly-2026-01-30
          # packages / arch-only-packages: pass the same values as cargo-publish-dry-run if set
```

## 2. Idempotent regeneration (re-run any time)

A `workflow_dispatch` workflow that checks out the tag, asserts it, and rebuilds
with `force: true`. Safe to re-run from scratch; the tag check guarantees the
uploaded docs match the tagged source.

```yaml
name: Regenerate docs
on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to regenerate (e.g. 0.16.2)'
        required: true
      packages:
        description: 'Optional space-separated package list'
        required: false
        default: ''
env:
  CARGO_NET_GIT_FETCH_WITH_CLI: "true"
jobs:
  regenerate-docs:
    runs-on: hog1
    steps:
      - name: Clean up .gitconfig
        run: rm -f /home/hogci/.gitconfig
      - name: Setup SSH Agent
        uses: webfactory/ssh-agent@v0.9.1
        with:
          ssh-private-key: ${{ secrets.ACTIONS_KEY }}
      - name: Checkout at tag
        uses: actions/checkout@v4
        with:
          ref: v${{ github.event.inputs.version }}
          fetch-depth: 0
          persist-credentials: true
      - name: Configure git to use SSH
        run: git config --global url."git@github.com:".insteadOf "https://github.com/"
      - name: Checkout actions repository
        uses: actions/checkout@v4
        with:
          repository: thruputchain/actions
          path: actions
          ref: main
      - name: Regenerate and upload docs
        uses: ./actions/cargo-doc
        with:
          version: ${{ github.event.inputs.version }}
          packages: ${{ github.event.inputs.packages }}
          registry-name: groundhog
          registry-token: ${{ secrets.GROUNDHOG_REGISTRY_TOKEN }}
          toolchain: nightly-2026-01-30
          force: 'true'
          expected-tag: v${{ github.event.inputs.version }}
```

## Notes

- **Layout per crate:** `<docs-root>/<crate>/<version>/` contains only that crate
  (plus shared rustdoc assets) — the doc dir is cleared between crates.
- **`latest`** is repointed to the newest stable version by semver (see
  `publish-docs`).
- **Cross-crate links 404** only when the depended-on crate's docs for the
  resolved version haven't been uploaded yet — self-healing once they are.
