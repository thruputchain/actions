# Cargo Release Tag

A GitHub Action that tags HEAD with the crate version, pushes the tag, and
decides whether **this commit is the release commit for that version** — the
invariant it protects is that a version is only ever published from the
commit its tag points at.

## Why not just tag and push?

Release workflows re-run: after a partial failure, on a later commit by
mistake, or for crates that deliberately don't bump every release. The naive
`git tag && git push || true` pattern has two silent failure modes:

- a rejected push gets ignored, and the run publishes crate content from a
  commit **other** than the one the tag marks;
- a "tag already exists" skip drops a genuinely bumped crate from the
  release without anyone noticing.

This action distinguishes the cases explicitly, consulting the registry when
git alone cannot tell them apart. Each package is checked in the registry it
publishes to, as its `publish` field says: crates.io when the field is unset
or `["crates-io"]`, otherwise the named registry.

## Behavior

1. Extracts the version (like `cargo-version-tag`: the first listed
   package's version is the reference, and every listed package must match).
2. Creates the tag `<tag-prefix><version>` at HEAD and pushes it.
3. Decides:

| Situation | Result |
|-----------|--------|
| Tag pushed (new), or remote tag already points at HEAD | `released=true` |
| Push rejected, tag absent on the remote | **fail** (push problem) |
| Remote tag on another commit, `on-existing-tag: fail` | **fail** — bump the version or re-run from the tagged commit |
| Remote tag on another commit, `skip-if-published`, version **published** | `released=false` — the crate wasn't bumped this release; skip its publish/docs |
| Remote tag on another commit, `skip-if-published`, version **not published** | **fail** — a previous run died between tag push and publish; publishing HEAD would ship content that doesn't match the tag |

The registry probe fails closed: if the index can't be reached, the action
fails rather than guessing.

## Usage

Strict release tag (the whole workspace releases together — any pre-existing
tag on another commit means someone forgot to bump):

```yaml
- name: Tag commit with version
  id: publish-tag
  uses: thruputchain/actions/cargo-release-tag@<commit-sha>
  with:
    packages: crate-a crate-b crate-c
    github-token: ${{ github.token }}
```

Independently-versioned crate that doesn't bump every release:

```yaml
- name: Tag my-crate
  id: tag-my-crate
  uses: thruputchain/actions/cargo-release-tag@<commit-sha>
  with:
    packages: my-crate
    tag-prefix: 'my-crate-v'
    github-token: ${{ github.token }}
    on-existing-tag: 'skip-if-published'
    # Only for a private registry, whose index needs auth. crates.io needs
    # nothing: the crate's `publish` field already says where to look.
    registry-token: ${{ secrets.REGISTRY_TOKEN }}

- name: Publish my-crate
  if: ${{ steps.tag-my-crate.outputs.released == 'true' }}
  uses: thruputchain/actions/cargo-publish@<commit-sha>
  with:
    packages: my-crate
    git-tag: ${{ steps.tag-my-crate.outputs.tag }}
    tag-prefix: 'my-crate-v'
    ...
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `cargo-toml-path` | Path to the workspace root Cargo.toml | No | `./Cargo.toml` |
| `packages` | Space-separated packages that must share one version (first is the reference); all workspace packages if empty | No | |
| `tag-prefix` | Prefix for the git tag | No | `v` |
| `github-token` | Token used to push the tag | Yes | |
| `on-existing-tag` | `fail` or `skip-if-published` (see Behavior) | No | `fail` |
| `registry-name` | Under `skip-if-published`, the registry to check for packages whose `publish` field allows several (or, unset, any); otherwise the field decides | No | |
| `registry-token` | Token for a private registry's index probe, sent verbatim in `Authorization` exactly as cargo sends it; not used for crates.io | No | |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The version extracted from Cargo.toml |
| `tag` | The full git tag name |
| `released` | `true` iff this commit is the release commit for the version; gate publish/docs steps on it |

## Requirements

- Rust toolchain, `jq`, and `curl` on the runner
- Repository checked out at the commit to release, run from the repo root
- For `skip-if-published` with a private registry: its sparse index in
  `CARGO_REGISTRIES_<NAME>_INDEX` or in `.cargo/config.toml`, as either
  `name = { index = "sparse+https://..." }` under `[registries]` or an
  `index = "..."` line under `[registries.name]`.
  Run the resolver's tests with `bash cargo-release-tag/test_registry_index.sh`.

The action reaches GitHub over HTTPS with `github-token` and leaves the local
git configuration untouched, so `origin` keeps the credentials
`actions/checkout` persisted and later steps in the job can use it.

## License

Licensed under the Apache License, Version 2.0 ([LICENSE](../LICENSE) or http://www.apache.org/licenses/LICENSE-2.0).
