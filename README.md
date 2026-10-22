# Groundhog Chain GitHub Actions

A collection of reusable GitHub Actions for the thruputchain organization.

## Available Actions

### cargo-publish

Publishes Rust crates to a private cargo registry with strict version validation, from a git tag that
matches the workspace version. Handles stable and pre-release tags alike (`v1.2.3`, `v1.2.3-rc.1`).

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-publish@v1
  with:
    git-tag: ${{ github.ref_name }}
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

See [cargo-publish/README.md](./cargo-publish/README.md) for detailed documentation.

### cargo-publish-dry-run

Validates Rust crates before publishing by vendoring dependencies, building, testing, and packaging.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@v1
  with:
    cargo-toml-path: './Cargo.toml'
```

See [cargo-publish-dry-run/README.md](./cargo-publish-dry-run/README.md) for detailed documentation.

### cargo-semver-checks

Runs `cargo-semver-checks` against a baseline (by default the nearest release tag reachable from `HEAD`) to catch API-breaking changes that the version bump does not account for.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-semver-checks@v1
  with:
    semver-checks-version: '0.50.0'
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

Requires `actions/checkout` with `fetch-depth: 0`, since the git baseline comes from local history. Pass `registry-token` only in jobs that build code you trust with it — Cargo build scripts inherit the credential.

**Outputs:** `baseline` (the baseline compared against), `skipped` (`true` when no baseline was found).

See [cargo-semver-checks/README.md](./cargo-semver-checks/README.md) for detailed documentation.

### cargo-version-tag

Parses Cargo workspace version, validates all crates have matching versions, and creates a git tag.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-version-tag@v1
  with:
    cargo-toml-path: './Cargo.toml'
    push-tag: 'true'
```

See [cargo-version-tag/README.md](./cargo-version-tag/README.md) for detailed documentation.

### cargo-nightly-version

Computes a `<next-patch>-nightly.<date>.g<sha>` prerelease version and rewrites the workspace Cargo.toml in place (uncommitted). Used as the first step in a nightly release workflow.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-nightly-version@main
  with:
    cargo-toml-path: './Cargo.toml'
```

**Outputs:** `version` (the computed nightly version string), `sha` (7-char git SHA used in the version).

### cargo-publish-prerelease

Publishes workspace crates to a cargo registry at their current Cargo.toml version, with no git-tag
coupling. For **untagged** snapshots — nightlies whose version is synthesized at CI time by
`cargo-nightly-version` and never committed, so there is no tag to validate against, and re-runs must
tolerate an already-uploaded version. A tagged release candidate belongs in `cargo-publish`, which
accepts pre-release tags and keeps the tag, version-match, dependency-pin and doc-build checks.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-publish-prerelease@main
  with:
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

**Outputs:** `published-version` (the version that was published).

## Reusable Workflows

### crates-io-publish

Releases a group of same-version workspace crates to crates.io, and is safe to re-run. For each
crate it checks crates.io first:

- **Not on crates.io:** creates it with the `crates-io-bootstrap-token` secret, invites
  `crate-owners`, and registers the calling workflow as the crate's trusted publisher.
- **On crates.io:** publishes the new version through trusted publishing (GitHub OIDC), with no
  stored token.
- **This version already published:** skips it, so a run that failed partway is resumed by
  re-running it on the tagged commit.

Before tagging `<tag-prefix><version>` or publishing anything, it runs `cargo-publish-dry-run` and a
preflight. The preflight checks that every crate can go to crates.io, that the tag is free or already
on HEAD, and that each new crate's name is free. crates.io treats `-` and `_` as the same, so
`rpc_api` clashes with an existing `rpc-api`.

**Usage:**
```yaml
on:
  workflow_dispatch:
    inputs:
      dry-run:
        type: boolean
        default: false

concurrency:
  group: publish

jobs:
  publish:
    permissions:
      contents: write # pushes the release tag
      id-token: write # crates.io trusted publishing
    uses: thruputchain/actions/.github/workflows/crates-io-publish.yml@<sha>
    with:
      packages: my-crate-macros my-crate # dependency order
      dry-run: ${{ inputs.dry-run }}
      crate-owners: github:thruputchain:<team> # optional, for new crates
    secrets:
      # Only while a crate in `packages` doesn't exist on crates.io yet.
      crates-io-bootstrap-token: ${{ secrets.CRATES_IO_BOOTSTRAP_TOKEN }}
```

The bootstrap token is a crates.io API token with the scopes `publish-new` and `trusted-publishing`,
plus `change-owners` if you set `crate-owners`. When it is set, the workflow also registers the
trusted publisher for existing crates that lack one, such as crates first published by hand. Once
every crate exists, remove the secret and revoke the token. crates.io matches trusted publishers on
the **calling** workflow's file name, which is the name the workflow registers.

A release made of independently versioned groups (for example, an API crate with its own tag) calls
the workflow once per group. Chain the jobs with `needs:`, pass `on-existing-tag: skip-if-published`
for groups that don't release every time, and list earlier groups in later calls'
`vendor-workspace-deps`.

**Outputs:** `version`, `tag`, `released` (`false` when `skip-if-published` found the group already
released).

## Notes

### semver.sh

Not an action: the single definition of the semver grammar the publish and yank actions accept
(`X.Y.Z` with an optional pre-release suffix, no build metadata). `cargo-publish/validate-tag.sh` and
`cargo-yank/validate-version.sh` both build their pattern from it, so a version that can be published
can always also be yanked. Each has its own test script; run both after changing the grammar:

```bash
bash cargo-publish/test_validate_tag.sh
bash cargo-yank/test_validate_version.sh
```

## License

Licensed under the Apache License, Version 2.0 ([LICENSE](LICENSE) or http://www.apache.org/licenses/LICENSE-2.0).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be licensed as above, without any additional terms or conditions.
