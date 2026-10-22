# Cargo Publish Action

A GitHub composite action that publishes Rust crates to a private cargo registry with strict version validation.

## Usage

```yaml
name: Publish

on:
  push:
    tags:
      - 'v*'

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Required to fetch tags

      - uses: dtolnay/rust-toolchain@stable

      - uses: thruputchain/actions/cargo-publish@<commit-sha>
        with:
          git-tag: ${{ github.ref_name }}
          registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
          registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `git-tag` | Git tag in v1.2.3 format (or custom prefix format if tag-prefix is set) | Yes | - |
| `tag-prefix` | Prefix for git tags (e.g., "v" for v1.2.3, or "" for 1.2.3) | No | `v` |
| `registry-name` | Name of the registry as defined in .cargo/config.toml | Yes | - |
| `registry-token` | Authentication token (pass from secrets) | Yes | - |
| `cargo-toml-path` | Path to Cargo.toml file | No | `./Cargo.toml` |
| `packages` | Space-separated list of package names to publish. If not provided, all workspace packages will be processed. | No | - |
| `publish-delay-seconds` | Seconds to wait after each successful publish so the registry can propagate before the next crate resolves against it | No | `30` |
| `no-verify` | Pass `--no-verify` to `cargo publish`, skipping the publish-time verify build. Use when `cargo-publish-dry-run` already verified the crates; required for architecture-only crates that cannot build on the host | No | `false` |

## Outputs

| Output | Description |
|--------|-------------|
| `published-version` | The version that was published (without tag prefix) |

## Prerequisites

Your workflow must:
1. Checkout the repository with `fetch-depth: 0` to include tags
2. Install Rust toolchain (e.g., `dtolnay/rust-toolchain@stable`)
3. Have the git tag already created and pushed

## Validation

The action performs these validations (only on packages that will be published):

1. **Git tag format**: Must match semver format with optional prefix (default: `vX.Y.Z`, configurable via
   `tag-prefix`). Pre-release versions are accepted (`v0.15.1-rc.1`), so a release candidate publishes
   through the same tagged, fully validated path as a stable release; cargo excludes pre-releases from
   version-range resolution, so they are not handed to ordinary consumers. Build metadata (`+sha`) is not
   accepted. The grammar lives in the repo-root `semver.sh`, shared with `cargo-yank` so a version that can
   be published can always also be yanked; `validate-tag.sh` applies it here, covered by
   `test_validate_tag.sh`.
2. **Tag exists**: Verifies the tag exists in the repository
3. **Current commit**: Ensures HEAD is tagged with the specified tag
4. **Cargo.toml exists**: Checks the file exists at the specified path
5. **Version match**: Git tag version must exactly match Cargo.toml version for selected packages
6. **Dependency versions**: Workspace internal dependencies must match the tag version. A requirement
   with a pre-release suffix (`=0.15.1-rc.1`) is checked like any other; only wildcards and
   requirements that are not a single `X.Y.Z` (`0.15`, `>=0.15, <0.16`) are passed through
7. **Required metadata**: License, description, and repository fields must be present

Documentation builds are checked by `cargo-publish-dry-run`, which should run before this action.

Steps 2, 3 and 6, plus prefix stripping and package selection, are covered by
`test_action_steps.py`, which runs them straight from `action.yml` against fixture workspaces
(needs Python with PyYAML, cargo, git and jq):

```bash
python3 cargo-publish/test_action_steps.py
```

## Publishing

The action:
- Determines which packages to publish (from `packages` input or discovers all workspace packages)
- Configures registry via environment variables (`CARGO_REGISTRIES_*_TOKEN`)
- Masks the token in logs
- Publishes each selected package individually using `cargo publish --registry <name> --package <package>`
- Skips packages with `publish = false` in Cargo.toml

## Example with Output

```yaml
- uses: thruputchain/actions/cargo-publish@<commit-sha>
  id: publish
  with:
    git-tag: ${{ github.ref_name }}
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}

- name: Create Release
  run: |
    echo "Published version: ${{ steps.publish.outputs.published-version }}"
```

## Example: Publishing Specific Packages

To publish only selected packages from a workspace:

```yaml
- uses: thruputchain/actions/cargo-publish@<commit-sha>
  with:
    git-tag: ${{ github.ref_name }}
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
    packages: 'package1 package2 package3'
```

When `packages` is specified, only those packages will be validated and published. If not provided, all workspace packages will be processed.

## Example: Custom Tag Prefix

To use a different tag prefix (or no prefix):

```yaml
# Using 'release-' prefix (e.g., release-1.2.3)
- uses: thruputchain/actions/cargo-publish@<commit-sha>
  with:
    git-tag: ${{ github.ref_name }}
    tag-prefix: 'release-'
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}

# Using no prefix (e.g., 1.2.3)
- uses: thruputchain/actions/cargo-publish@<commit-sha>
  with:
    git-tag: ${{ github.ref_name }}
    tag-prefix: ''
    registry-name: ${{ vars.CARGO_REGISTRY_NAME }}
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

## Security

- Always pass `registry-token` from GitHub secrets, never hardcode it
- The action masks the token using `::add-mask::`
- GitHub also automatically masks secrets in logs
