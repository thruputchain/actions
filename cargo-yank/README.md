# Cargo Yank

A GitHub composite action that yanks (or un-yanks) one published version of the workspace
crates from a cargo registry: crates.io, or a private registry configured in the calling
repository's `.cargo/config.toml`.

## Usage

```yaml
name: Yank

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to yank (bare semver, e.g. 1.2.3 or 1.2.3-rc.1)'
        required: true
      undo:
        description: 'Un-yank instead'
        type: boolean
        default: false

jobs:
  yank:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<commit-sha>

      - uses: dtolnay/rust-toolchain@<commit-sha>

      - uses: thruputchain/actions/cargo-yank@<commit-sha>
        with:
          version: ${{ inputs.version }}
          undo: ${{ inputs.undo }}
          registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
          registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

For crates.io, pass `registry-name: crates-io` and an API token with the `yank` scope. Trusted
publishing tokens cannot yank.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `version` | Version to yank, as bare semver with an optional pre-release suffix (`1.2.3`, `1.2.3-rc.1`). No tag prefix | Yes | - |
| `undo` | Pass `--undo` to `cargo yank`, restoring a previously yanked version | No | `false` |
| `registry-name` | Registry name as defined in `.cargo/config.toml`, or `crates-io` | Yes | - |
| `registry-token` | Token for that registry (pass from secrets) | Yes | - |
| `cargo-toml-path` | Path to the workspace `Cargo.toml` | No | `./Cargo.toml` |
| `packages` | Space-separated package names to yank. All workspace packages if empty | No | - |

## Behavior

1. **Version format**: validated against the shared grammar in the repo-root `semver.sh`, the
   same one `cargo-publish` applies to tags, so any version that could be published can be
   yanked. Covered by `test_validate_version.sh`.
2. **Package selection**: the `packages` input (each must exist in the workspace), or every
   workspace package. Packages with `publish = false` are skipped.
3. **Yank**: `cargo yank --version <version> --registry <name> [--undo] <package>` per package,
   with the token supplied through `CARGO_REGISTRY_TOKEN` (crates.io) or
   `CARGO_REGISTRIES_<NAME>_TOKEN` (private registries, name upper-cased with `-` as `_`).
4. **Skips**: a package is skipped only when the registry itself answers that the crate or
   version does not exist (a crate added to the workspace after that version shipped, say).
   Cargo's own errors, such as an unknown registry name, a missing token, or a network failure,
   and any other registry error fail the run. `registry-missing.sh` makes that call, covered
   by `test_registry_missing.sh`.
5. **Nothing yanked is a failure**: if every package was skipped, the run fails, so a mistyped
   version or registry cannot leave the release in place behind a green job.

## Testing

```bash
bash cargo-yank/test_validate_version.sh
bash cargo-yank/test_registry_missing.sh
```

## Security

- Always pass `registry-token` from GitHub secrets, never hardcode it
- The action masks the token using `::add-mask::`, and GitHub also masks secrets in logs
