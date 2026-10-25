# Cargo Semver Checks

A GitHub Action that runs [`cargo-semver-checks`](https://github.com/obi1kenobi/cargo-semver-checks)
against a baseline to catch API-breaking changes that the version bump does not
account for.

By default the baseline is the nearest release tag reachable from `HEAD`, so a
pull request is checked against the last release of its own branch history.

## Features

- Discovers the baseline automatically from release tags (`git describe`), with
  explicit git-revision and registry-version overrides
- Checks the whole workspace by default; `cargo-semver-checks` skips
  `publish = false` crates on its own
- Authenticates against a private cargo registry so both the baseline and the
  current build can resolve dependencies
- Installs and pins `cargo-semver-checks`, reusing an already-installed binary
  on self-hosted runners
- Skips (with a notice, not a failure) when a repo has no release tag yet
- Skips (with a notice) packages a git baseline doesn't have, such as crates
  added or renamed since the last release; see
  [New and renamed packages](#new-and-renamed-packages)

## Requirements

- `actions/checkout` with `fetch-depth: 0`. The git baseline is checked out from
  local history, so a shallow clone has neither the tags nor the commits.
- A Rust toolchain on the runner. `cargo-semver-checks` emits rustdoc JSON from
  whichever toolchain the repo resolves to (`rust-toolchain.toml` or the runner
  default); no nightly is needed.
- `jq` on the runner, to compare the workspace's packages with a git baseline's.

## Usage

### Basic Usage

```yaml
- uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
  with:
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

### Pin the tool version

Pinning keeps a new `cargo-semver-checks` release from turning CI red without a
repo change. Pin the Rust toolchain too (via `rust-toolchain.toml` or the
workflow), since the rustdoc JSON format the tool reads comes from it.

```yaml
- uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
  with:
    semver-checks-version: '0.50.0'
    registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}
```

### Check specific packages

```yaml
- uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
  with:
    packages: 'thruput-xdr thruput-syscall'
```

### Compare against an explicit baseline

```yaml
- uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
  with:
    baseline-rev: 'v0.25.0'
```

```yaml
- uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
  with:
    baseline-version: '0.25.0'
```

### Complete Example Workflow

Gate a release on the check, running it *before* the tag is created — once
`vX.Y.Z` exists at `HEAD`, the baseline resolves to that new tag and the
release is compared against itself.

```yaml
name: Release package

on:
  workflow_dispatch:

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - uses: dtolnay/rust-toolchain@stable

      - uses: thruputchain/actions/cargo-semver-checks@<commit-sha>
        with:
          exclude: 'some-internal-crate'
          semver-checks-version: '0.50.0'
          registry-token: ${{ secrets.CARGO_REGISTRY_TOKEN }}

      # ... tag and publish steps follow
```

At publish time the workspace version is already bumped, so the check
validates that the bump is large enough for the API changes since the previous
release. Run on a pull request instead and the version is usually unchanged, so
the tool assumes a minor release and only breaking changes fail — a weaker
check, and one that carries the credential caveat below.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `cargo-toml-path` | No | `./Cargo.toml` | Path to `Cargo.toml`. |
| `packages` | No | `''` | Space-separated packages to check. Empty checks the whole workspace. |
| `exclude` | No | `''` | Space-separated packages to exclude. Only meaningful for a workspace check. |
| `baseline-rev` | No | `''` | Git revision to compare against. Takes precedence over `baseline-version` and tag discovery. |
| `baseline-version` | No | `''` | Registry version (`X.Y.Z`) to compare against, instead of a git revision. |
| `tag-pattern` | No | `v[0-9]*.[0-9]*.[0-9]*` | `glob(7)` pattern for release tags, used to discover the baseline. |
| `require-baseline` | No | `false` | Fail instead of skipping when no baseline can be discovered. |
| `feature-mode` | No | `heuristic` | `heuristic`, `all`, `default`, or `only-explicit`. |
| `features` | No | `''` | Space-separated extra features enabled in both builds. |
| `release-type` | No | `''` | Force `major`, `minor`, or `patch` instead of deriving it from version numbers. |
| `target` | No | `''` | Build target, e.g. `x86_64-unknown-linux-gnu`. Defaults to the host target. |
| `registry-name` | No | `thruput` | Private registry name as defined in `.cargo/config.toml`. |
| `registry-token` | No | `''` | Auth token for the private registry. |
| `semver-checks-version` | No | `''` | `cargo-semver-checks` version to install. Empty installs the latest release. |

## Outputs

| Output | Description |
| --- | --- |
| `baseline` | The baseline compared against, e.g. `rev:v0.25.0` or `version:0.25.0`. Empty when skipped. |
| `skipped` | `true` when the check did not run: no baseline could be discovered, or the baseline has none of the packages to check. |

## Credentials and untrusted code

`registry-token` is exported as `CARGO_REGISTRIES_<NAME>_TOKEN` for the
`cargo semver-checks` invocation, so every Cargo subprocess inherits it —
including build scripts and procedural macros compiled from the checked-out
workspace and its dependencies. `::add-mask::` redacts the value from logs; it
does not keep code that runs during the build from reading it.

So do not pass `registry-token` in a job that builds code you would not
otherwise trust with the token. Concretely: a `pull_request`-triggered job in a
repo where contributors can push branches gets the secret on a same-repository
PR, and a build script in that PR can exfiltrate it. Prefer running this on
`workflow_dispatch` release workflows, or on `push` to a protected branch.

If you do need it on pull requests, scope the token to read-only on the
registry, so a leak cannot be used to publish.

## New and renamed packages

A package the baseline doesn't have, because it was added or renamed since,
has no earlier API to break, and `cargo-semver-checks` fails on it
("package `x` not found"). With a git baseline (`baseline-rev`, or a
discovered tag) the action lists the baseline's packages with
`cargo metadata --no-deps` and leaves the missing ones out, with a notice for
each: from a whole-workspace check as if they were in `exclude`, and from
`packages`. If that leaves nothing to check, the action skips the check with a
notice. A renamed package is checked again once a release that contains it is
the baseline.

`cargo metadata` reads the baseline's manifests with the caller's cargo
configuration, as `cargo-semver-checks` does, so a baseline that names a
registry needs that registry defined, by `.cargo/config.toml` or by a
`CARGO_REGISTRIES_<NAME>_INDEX` variable on the step. A registry baseline
(`baseline-version`) isn't inspected, so a package it lacks still fails the
check.

## Feature selection

`feature-mode: heuristic` is the `cargo-semver-checks` default: it enables every
feature except `unstable`, `nightly`, `bench`, `no_std`, and any feature starting
with `_`, `unstable_`, or `unstable-`. This gives the widest useful API surface
without turning on features that are not meant to be stable.

Use `all` to include those excluded features too, `default` for only the
crate-defined default features, and `only-explicit` for nothing but what
`features` names.

## Interpreting failures

`cargo-semver-checks` compares the baseline and current versions to decide which
release type is expected, then reports API changes that need a larger bump than
the manifest declares. When the version has not been bumped yet it assumes a
minor release, so a failure means the change is breaking and needs a major bump.

For `0.x` crates, cargo's semver rules make a minor bump (`0.25` -> `0.26`) the
breaking one, and `cargo-semver-checks` accounts for that.

Two ways to resolve a failure:

- Bump the version to the release type the tool asks for, or
- Change the API back so the bump you intend is accurate.
