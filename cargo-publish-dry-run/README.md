# Cargo Publish Dry Run Action

A GitHub composite action that validates Rust crates before publishing by vendoring dependencies, building, testing, and packaging.

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

      - uses: thruputchain/actions/cargo-publish-dry-run@v1
        with:
          cargo-toml-path: './Cargo.toml'
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `registry-name` | Private registry name in `.cargo/config.toml` | No | `thruput` |
| `cargo-toml-path` | Path to Cargo.toml file | No | `./Cargo.toml` |
| `packages` | Space-separated list of package names to validate. If not provided, all workspace packages will be processed. | No | - |
| `cargo-hack-feature-options` | Feature testing options for cargo-hack | No | `--feature-powerset` |
| `skip-tests` | Skip running tests | No | `false` |
| `skip-clippy` | Skip clippy checks | No | `false` |
| `skip-fmt` | Skip formatting checks | No | `false` |

## Prerequisites

Your workflow must:
1. Checkout the repository
2. Install Rust toolchain with `rustfmt` and `clippy` components
3. Have `jq` available (included in GitHub-hosted runners)

## What This Action Does

The action performs the following validations:

1. **Vendor Dependencies**: Creates a `vendor/` directory with all dependencies to ensure reproducible builds
2. **Build**: Compiles all workspace packages with all features enabled
3. **Test**: Runs all tests (can be skipped with `skip-tests: true`)
4. **Package**: Creates package archives for each crate (dry-run, doesn't publish)
5. **Feature Verification**: Uses `cargo-hack` to verify all feature combinations
6. **Format Check**: Validates code formatting (can be skipped with `skip-fmt: true`)
7. **Clippy**: Runs linter checks with warnings as errors (can be skipped with `skip-clippy: true`)
8. **Documentation**: Verifies documentation builds successfully

## Example: Minimal Configuration

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@v1
```

## Example: A Different Private Registry

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@v1
  with:
    registry-name: thruput
```

Configure that registry and its source in `.cargo/config.toml`. Provide its
credentials through the normal Cargo environment when dependency acquisition
requires authentication. The action replaces that source with `vendor/` for
packaging, verification, clippy, and documentation checks.

## Example: Custom Feature Testing

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@v1
  with:
    cargo-hack-feature-options: '--feature-powerset --exclude-no-default-features'
```

## Example: Skip Optional Checks

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@v1
  with:
    skip-fmt: true
    skip-clippy: true
```

## Example: Validating Specific Packages

To validate only selected packages from a workspace:

```yaml
- uses: thruputchain/actions/cargo-publish-dry-run@v1
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

      - uses: thruputchain/actions/cargo-publish-dry-run@v1

  publish:
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: dtolnay/rust-toolchain@stable

      - uses: thruputchain/actions/cargo-publish@v1
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
