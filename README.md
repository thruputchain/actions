# Thruput GitHub Actions

A collection of reusable GitHub Actions for the thruputchain organization.

## Versioning

There are no release tags. Pin every `uses:` line to a full commit SHA from `main`, which is
what the `workflow-lint` workflow's zizmor policy requires of callers anyway:

```yaml
- uses: thruputchain/actions/cargo-publish@0123456789abcdef0123456789abcdef01234567 # main 2026-10-22
```

`<commit-sha>` in the examples below stands for such a pin. Dependabot keeps the pins in this
repository's own workflows current (`.github/dependabot.yml`); the actionlint and zizmor
binaries that `workflow-lint` downloads are pinned by version and checksum in that workflow's
inputs and need a manual bump.

## Available Actions

### cargo-publish

Publishes Rust crates to a private cargo registry with strict version validation, from a git tag that
matches the workspace version. Handles stable and pre-release tags alike (`v1.2.3`, `v1.2.3-rc.1`).

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-publish@<commit-sha>
  with:
    git-tag: ${{ github.ref_name }}
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

See [cargo-publish/README.md](./cargo-publish/README.md) for detailed documentation.

### cargo-publish-dry-run

Validates Rust crates before publishing by vendoring dependencies, then packaging and build-verifying
every feature combination offline. It does not run tests.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
  with:
    cargo-toml-path: './Cargo.toml'
```

See [cargo-publish-dry-run/README.md](./cargo-publish-dry-run/README.md) for detailed documentation.

### cargo-semver-checks

Runs `cargo-semver-checks` against a baseline (by default the nearest release tag reachable from `HEAD`) to catch API-breaking changes that the version bump does not account for.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
  with:
    semver-checks-version: '0.50.0'
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

Requires `actions/checkout` with `fetch-depth: 0`, since the git baseline comes from local history. Pass `registry-token` only in jobs that build code you trust with it — Cargo build scripts inherit the credential.

**Outputs:** `baseline` (the baseline compared against), `skipped` (`true` when no baseline was found).

See [cargo-semver-checks/README.md](./cargo-semver-checks/README.md) for detailed documentation.

### cargo-version-tag

Parses Cargo workspace version, validates all crates have matching versions, and creates a local
git tag (it does not push it).

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-version-tag@<commit-sha>
  with:
    cargo-toml-path: './Cargo.toml'
```

See [cargo-version-tag/README.md](./cargo-version-tag/README.md) for detailed documentation.

### cargo-release-tag

Tags HEAD with the crate version, pushes the tag, and decides whether this commit is the release
commit for that version, consulting the registry when the remote tag already sits on another
commit. Gate the publish steps on its `released` output.

**Usage:**
```yaml
- id: tag
  uses: thruputchain/actions/cargo-release-tag@<commit-sha>
  with:
    packages: crate-a crate-b
    github-token: ${{ github.token }}
```

See [cargo-release-tag/README.md](./cargo-release-tag/README.md) for detailed documentation.

### cargo-yank

Yanks (or un-yanks) one version of the workspace crates from crates.io or a private registry.
A version the registry has never seen is skipped per crate, but the run fails if nothing was
yanked at all.

**Usage:**
```yaml
- uses: thruputchain/actions/cargo-yank@<commit-sha>
  with:
    version: '1.2.3'
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

See [cargo-yank/README.md](./cargo-yank/README.md) for detailed documentation.

### crates-io-publish

Publishes a group of same-version crates to crates.io, and is safe to re-run. Crates that don't exist
yet are created with a bootstrap token, which also registers the calling workflow as their trusted
publisher. New versions of existing crates publish through trusted publishing (GitHub OIDC), with no
stored token. Versions already published are skipped, once shown to come from the release tag.

It runs in two modes around `cargo-release-tag`: `check` decides whether this commit releases the
group and verifies everything publishing would reject, before anything is tagged; `publish` then
publishes from the tagged commit.

**Usage:**
```yaml
- id: check
  uses: thruputchain/actions/crates-io-publish@<commit-sha>
  with:
    mode: check
    packages: my-crate-macros my-crate
    bootstrap-token: ${{ secrets.CRATES_IO_BOOTSTRAP_TOKEN }}
- id: tag
  if: steps.check.outputs.release == 'true'
  uses: thruputchain/actions/cargo-release-tag@<commit-sha>
  with:
    packages: my-crate-macros my-crate
    github-token: ${{ github.token }}
- if: steps.check.outputs.release == 'true'
  uses: thruputchain/actions/crates-io-publish@<commit-sha>
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

## Reusable Workflows

Called as a job with `uses:` (not as a step). Each file's header comment shows the call.

### workflow-lint

Runs actionlint (with shellcheck and pyflakes), then zizmor, over the caller's workflows and
action definitions. Optionally shellchecks tracked `*.sh` files and runs an advisory zizmor
pedantic pass. Requires a Linux x86-64 runner.

```yaml
jobs:
  workflow-lint:
    permissions:
      contents: read
    uses: thruputchain/actions/.github/workflows/workflow-lint.yml@<commit-sha>
```

### rust-dependency-policy

Runs `cargo deny check` against the caller's `deny.toml`, all four checks by default or the
subset given in `checks`. Takes an optional private registry name and token.

The root workspace is always checked. To check other workspaces with their own lockfiles,
list their manifests in `manifest-paths`; the root `deny.toml` applies to each:

```yaml
    with:
      manifest-paths: tools/runner/Cargo.toml
```

```yaml
jobs:
  dependency-policy:
    permissions:
      contents: read
    uses: thruputchain/actions/.github/workflows/rust-dependency-policy.yml@<commit-sha>
```

### rust-advisory-issue

Files (or comments on) a tracking issue when a scheduled advisory scan fails. Pair it with
`rust-dependency-policy` as a job that runs on its failure; the job needs `issues: write`.

```yaml
jobs:
  scan:
    permissions:
      contents: read
    uses: thruputchain/actions/.github/workflows/rust-dependency-policy.yml@<commit-sha>
    with: { checks: advisories }
  notify:
    needs: scan
    if: failure()
    permissions:
      contents: read
      issues: write
    uses: thruputchain/actions/.github/workflows/rust-advisory-issue.yml@<commit-sha>
```

## License

Licensed under the Apache License, Version 2.0 ([LICENSE](LICENSE) or http://www.apache.org/licenses/LICENSE-2.0).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be licensed as above, without any additional terms or conditions.
