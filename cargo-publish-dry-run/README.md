# Cargo Publish Dry Run Action

A GitHub composite action that validates Rust crates before publishing: it vendors dependencies, then
packages each crate and build-verifies every feature combination offline, exactly as a consumer would
build the published `.crate`.

It does **not** run your tests. Keep a separate test job if tests should gate a release.

## Usage

```yaml
name: Validate

on:
  pull_request:
    branches:
      - main
  push:
    branches:
      - main

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy

      - uses: taiki-e/install-action@v2
        with:
          tool: cargo-hack

      - uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
        with:
          cargo-toml-path: './Cargo.toml'
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `registry-name` | Private registry name in `.cargo/config.toml` | No | `thruput` |
| `cargo-toml-path` | Path to Cargo.toml file | No | `./Cargo.toml` |
| `packages` | Space-separated list of package names to validate. If not provided, all workspace packages will be processed. | No | - |
| `cargo-hack-feature-options` | Feature options for cargo-hack on the host | No | `--feature-powerset` |
| `cargo-hack-wasm32-packages` | Space-separated packages to also verify for `wasm32-unknown-unknown`. Step skipped if empty. | No | `''` |
| `cargo-hack-wasm32-feature-options` | Feature options for cargo-hack on `wasm32-unknown-unknown` | No | `--feature-powerset` |
| `cargo-hack-rv32-packages` | Space-separated packages to also verify for `riscv32im-unknown-none-elf`. Step skipped if empty. | No | `''` |
| `cargo-hack-rv32-feature-options` | Feature options for cargo-hack on `riscv32im-unknown-none-elf` | No | `--feature-powerset` |
| `arch-only-packages` | Space-separated packages that only build for a non-host target. Still packaged, but skipped by the host verify, clippy, and doc steps; list them in a per-target input instead. | No | `''` |
| `vendor-workspace-deps` | Space-separated workspace packages to package into `vendor/` first, without verifying or publishing them. Use when the validated packages depend on workspace crates that are already published. | No | `''` |
| `skip-clippy` | Skip clippy checks | No | `false` |
| `skip-fmt` | Skip formatting checks | No | `false` |

## Prerequisites

Your workflow must:
1. Checkout the repository
2. Install Rust toolchain with `rustfmt` and `clippy` components (plus the `wasm32-unknown-unknown` /
   `riscv32im-unknown-none-elf` targets if you use the per-target inputs)
3. Install [`cargo-hack`](https://github.com/taiki-e/cargo-hack), e.g. with `taiki-e/install-action`
4. Have `jq` available (included in GitHub-hosted runners)
5. Commit an up-to-date `Cargo.lock`: every cargo command that resolves dependencies runs with
   `--locked`, so the action builds exactly the committed lockfile and fails if it is missing or
   stale

## What This Action Does

The action performs the following validations:

1. **Vendor Dependencies**: Creates a `vendor/` directory with all dependencies to ensure reproducible builds
2. **Package**: Creates package archives for each crate and adds them to `vendor/`, so workspace crates
   resolve against each other as published `.crate` files
3. **Feature Verification**: Uses `cargo-hack ... package` to build each packaged crate offline under every
   feature combination (and, if configured, for wasm32 / rv32)
4. **Publish Dry Run**: Runs `cargo publish --dry-run` for each publishable crate
5. **Format Check**: Validates code formatting (can be skipped with `skip-fmt: true`)
6. **Clippy**: Runs linter checks with all features and warnings as errors (can be skipped with `skip-clippy: true`)
7. **Metadata**: Requires `license`, `description`, and `repository` on every publishable crate
8. **Documentation**: Verifies documentation builds successfully

Tests are not run.

## Example: Minimal Configuration

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
```

## Example: A Different Private Registry

The default registry name is `thruput`. To validate against another one:

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
  with:
    registry-name: other-registry
```

Configure that registry and its source in `.cargo/config.toml`; cargo rejects a source override
for a registry that is not defined there. Provide its
credentials through the normal Cargo environment when dependency acquisition
requires authentication. The action replaces that source with `vendor/` for
packaging, verification, clippy, and documentation checks.

## Example: Custom Feature Testing

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
  with:
    cargo-hack-feature-options: '--feature-powerset --exclude-no-default-features'
```

## Example: Skip Optional Checks

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
  with:
    skip-fmt: true
    skip-clippy: true
```

## Example: Validating Specific Packages

To validate only selected packages from a workspace:

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>
  with:
    packages: 'package1 package2 package3'
```

When `packages` is specified, only those packages will be validated. If not provided, all workspace packages will be processed.

## Example: Pre-Publish Workflow

Use this action before publishing to catch issues early:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy

      - uses: thruputchain/actions/cargo-publish-dry-run@<commit-sha>

  publish:
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: dtolnay/rust-toolchain@stable

      - uses: thruputchain/actions/cargo-publish@<commit-sha>
        with:
          git-tag: ${{ github.ref_name }}
          registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
          registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

## Why Vendor Dependencies?

Vendoring dependencies ensures that:
- Your crate can be built with only the dependencies declared in `Cargo.toml`
- No hidden dependencies are required from your local environment
- The build is reproducible and matches what consumers will experience
- You catch missing dependency declarations before publishing

## Relationship to cargo-publish

This action is designed to work alongside the `cargo-publish` action:
- Use `cargo-publish-dry-run` in PR validation and pre-publish checks
- Use `cargo-publish` for actual publishing to the registry

Both actions perform comprehensive validation, but this action focuses on build verification without requiring registry credentials.
