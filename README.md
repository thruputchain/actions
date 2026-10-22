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

### crates-io-publish

Publishes a group of same-version crates to crates.io, and is safe to re-run. Crates that don't exist
yet are created with a bootstrap token, which also registers the calling workflow as their trusted
publisher. New versions of existing crates publish through trusted publishing (GitHub OIDC), with no
stored token. Versions already published are skipped.

It runs in two modes around `cargo-release-tag`: `check` decides whether this commit releases the
group and verifies everything publishing would reject, before anything is tagged; `publish` then
publishes from the tagged commit.

**Usage:**
```yaml
- id: check
  uses: thruputchain/actions/crates-io-publish@v1
  with:
    mode: check
    packages: my-crate-macros my-crate
    bootstrap-token: ${{ secrets.CRATES_IO_BOOTSTRAP_TOKEN }}
- id: tag
  if: steps.check.outputs.release == 'true'
  uses: thruputchain/actions/cargo-release-tag@v1
  with:
    packages: my-crate-macros my-crate
    github-token: ${{ github.token }}
- if: steps.check.outputs.release == 'true'
  uses: thruputchain/actions/crates-io-publish@v1
  with:
    mode: publish
    packages: my-crate-macros my-crate
    git-tag: ${{ steps.tag.outputs.tag }}
    bootstrap-token: ${{ secrets.CRATES_IO_BOOTSTRAP_TOKEN }}
```

The job needs `permissions: { contents: write, id-token: write }`.

See [crates-io-publish/README.md](./crates-io-publish/README.md) for a full release workflow.

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
