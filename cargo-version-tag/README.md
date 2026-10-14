# Cargo Version Tag

A GitHub Action that parses a Cargo workspace's `Cargo.toml`, validates that all workspace crates have the same version, and creates a git tag based on that version.

## Features

- Extracts version from the workspace root `Cargo.toml`
- Validates that ALL workspace crates share the same version
- Creates a git tag in the format `vX.Y.Z` (configurable prefix)
- Optionally pushes the tag to the remote repository
- Configurable behavior for existing tags

## Usage

### Basic Usage

```yaml
- uses: thruputchain/actions/cargo-version-tag@v1
  with:
    cargo-toml-path: './Cargo.toml'
```

### With Tag Push

```yaml
- uses: thruputchain/actions/cargo-version-tag@v1
  with:
    cargo-toml-path: './Cargo.toml'
    push-tag: 'true'
```

### Custom Tag Prefix

```yaml
- uses: thruputchain/actions/cargo-version-tag@v1
  with:
    cargo-toml-path: './Cargo.toml'
    tag-prefix: 'release-'
```

### Complete Example Workflow

```yaml
name: Create Version Tag

on:
  workflow_dispatch:

jobs:
  tag-version:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Create version tag
        uses: thruputchain/actions/cargo-version-tag@v1
        with:
          cargo-toml-path: './Cargo.toml'
          push-tag: 'true'
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `cargo-toml-path` | Path to the workspace root Cargo.toml file | No | `./Cargo.toml` |
| `tag-prefix` | Prefix for the git tag | No | `v` |
| `push-tag` | Whether to push the tag to remote | No | `false` |
| `fail-if-exists` | Fail if the tag already exists at a different commit (a tag already at `HEAD` always succeeds) | No | `true` |

## Outputs

| Output | Description |
|--------|-------------|
| `version` | The version extracted from Cargo.toml (e.g., `1.2.3`) |
| `tag` | The full git tag name created (e.g., `v1.2.3`) |

## Validation

This action performs strict validation:

1. **Version Extraction**: Reads the version from the workspace root `Cargo.toml`
2. **Workspace Validation**: Checks that every crate in the workspace has the exact same version
3. **Tag Existence**: Succeeds without changes if the tag already points at `HEAD` (so re-runs are idempotent); otherwise can optionally fail if the tag exists at another commit
4. **Tag Creation**: Creates a git tag with the specified prefix

If any workspace crate has a different version, the action will fail with an error message identifying the mismatched crate.

## Example Output

```
Extracting version from ./Cargo.toml...
Root workspace version: 1.2.3
Validating all workspace crate versions...
OK: Package 'my-crate-core' version matches: 1.2.3
OK: Package 'my-crate-utils' version matches: 1.2.3
OK: Package 'my-crate-api' version matches: 1.2.3
OK: All workspace crates have version 1.2.3
Creating git tag: v1.2.3
OK: Created tag v1.2.3
```

## Error Cases

### Version Mismatch

```
ERROR: Package 'my-crate-utils' has version 1.2.4, expected 1.2.3
ERROR: Not all workspace crates have the same version!
```

### Tag Already Exists

```
ERROR: Tag v1.2.3 already exists at <tag-sha>, which is not this commit (<head-sha>)!
```

## Requirements

- Rust toolchain must be installed (e.g., via `dtolnay/rust-toolchain@stable`)
- Repository must be checked out (e.g., via `actions/checkout@v4`)
- Git must be configured for tag creation and pushing

## License

Licensed under the Apache License, Version 2.0 ([LICENSE](../LICENSE) or http://www.apache.org/licenses/LICENSE-2.0).
