# crates.io Publish

A GitHub composite action that publishes a group of same-version Rust crates to crates.io, creating
any crate that doesn't exist there yet. It is safe to re-run: a release that fails partway resumes
by re-running it on the tagged commit.

For each package, in the order given:

| On crates.io | What happens |
|--------------|--------------|
| Crate doesn't exist | Created with `bootstrap-token`. `crate-owners` are invited and the job's workflow is registered as the crate's trusted publisher, so later releases need no stored token. |
| Crate exists, version doesn't | Published through trusted publishing: the job's GitHub OIDC token is exchanged for a crates.io token, used for that crate, then revoked. |
| Version exists | Skipped. |

## Modes

The action runs twice in a release job, around [`cargo-release-tag`](../cargo-release-tag/README.md):

- **`check`**, before tagging, with no side effects. It decides whether this commit releases the
  group (`release` output), and fails on anything publishing would reject:
  - a package that can't publish to crates.io (its `publish` field excludes it), or packages at
    different versions;
  - a release tag already on another commit (see `on-existing-tag`);
  - a version already on crates.io with no release tag here;
  - a new crate whose name crates.io already has. It treats `-`, `_` and case as the same, so
    `rpc_api` clashes with an existing `rpc-api`;
  - a new crate without `bootstrap-token`.
- **`publish`**, from the tagged commit. It checks that `git-tag` points at HEAD and matches the
  packages' version, then publishes as above.

A failed `check` leaves nothing tagged, so the fix can be released from a new commit.

## Usage

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      dry-run:
        description: 'Check only: no tag, no publish'
        type: boolean
        default: false

concurrency:
  group: release

jobs:
  release:
    runs-on: ubuntu-latest
    # Optional: gate releases on an environment's protection rules. Trusted
    # publishers this action registers are then scoped to it.
    environment: release
    permissions:
      contents: write # pushes the release tag
      id-token: write # crates.io trusted publishing
    env:
      PACKAGES: my-crate-macros my-crate # dependency order
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0 # check reads the release tags
          persist-credentials: false

      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy, rustfmt

      - uses: taiki-e/install-action@v2
        with:
          tool: cargo-hack

      - uses: thruputchain/actions/cargo-publish-dry-run@v1
        with:
          packages: ${{ env.PACKAGES }}
          registry-name: crates-io

      - id: check
        uses: thruputchain/actions/crates-io-publish@v1
        with:
          mode: check
          packages: ${{ env.PACKAGES }}
          bootstrap-token: ${{ secrets.CRATES_IO_BOOTSTRAP_TOKEN }}

      - id: tag
        if: steps.check.outputs.release == 'true' && !inputs.dry-run
        uses: thruputchain/actions/cargo-release-tag@v1
        with:
          packages: ${{ env.PACKAGES }}
          github-token: ${{ github.token }}

      - if: steps.check.outputs.release == 'true' && !inputs.dry-run
        uses: thruputchain/actions/crates-io-publish@v1
        with:
          mode: publish
          packages: ${{ env.PACKAGES }}
          git-tag: ${{ steps.tag.outputs.tag }}
          bootstrap-token: ${{ secrets.CRATES_IO_BOOTSTRAP_TOKEN }}
          crate-owners: github:my-org:my-team
```

### Several version groups

A workspace whose crates release under different versions and tags (an API crate on its own
`my-api-v<version>` tag, say) repeats the check, tag and publish steps for each group, earlier
groups first. Give the group that doesn't release every time `on-existing-tag: skip-if-published`
on its check. The tag and publish steps keep their `release == 'true'` conditions, so that group is
skipped when it's unchanged. Run every group's check before any tag step, so nothing is tagged
until all of them pass.

## Credentials

**Trusted publishing** needs no secret. crates.io matches the job against each crate's trusted
publishers: the repository, the job's top-level workflow file (e.g. `release.yml`, not a reusable
workflow it calls), and the environment, if the publisher names one.

**`bootstrap-token`** is needed only while the group has a crate that doesn't exist on crates.io,
because trusted publishing can't create a crate. Create a crates.io API token with the scopes
`publish-new` and `trusted-publishing`, plus `change-owners` if you set `crate-owners`, and keep its
crate scope and expiry tight. Its owner's crates.io account needs a verified email to register
trusted publishers. While the token is passed, `publish` also registers the trusted publisher for
existing crates in the group that lack one (for example, crates first published by hand), and the
run fails if any crate is left without one. Once every crate exists, remove the secret and revoke
the token.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `mode` | `check` or `publish` (see Modes) | Yes | |
| `packages` | Space-separated packages in dependency order, all at one version | Yes | |
| `tag-prefix` | Release tag prefix: the tag is `<tag-prefix><version>` | No | `v` |
| `on-existing-tag` | `check`: `fail`, or `skip-if-published` to report `release=false` when the tag is on another commit and every crate there is published and unchanged (`cargo package` builds the same crate) | No | `fail` |
| `git-tag` | `publish`: the release tag; must point at HEAD | For `publish` | |
| `bootstrap-token` | crates.io API token for creating crates (see Credentials) | While creating crates | |
| `crate-owners` | `publish`: owners invited to each crate this run creates (`github:org:team` or a username) | No | |
| `publish-args` | `publish`: extra `cargo publish` arguments, e.g. `--all-features` | No | |

## Outputs (`check`)

| Output | Description |
|--------|-------------|
| `version` | The group's version |
| `tag` | The release tag |
| `release` | `true` when this commit releases the group; `false` when `skip-if-published` found it already released |
| `new-crates` | Packages that don't exist on crates.io yet |

## Requirements

- Rust toolchain, `jq`, `curl` and `git` on the runner
- The repository checked out at the commit to release with `fetch-depth: 0`, run from its root
- A committed, up-to-date `Cargo.lock` (both modes run cargo with `--locked`)

## Testing

`bash crates-io-publish/test_crates_io_publish.sh` runs both modes offline against a mock crates.io
(`mock_crates_io.py`), with `cargo publish` and `cargo owner` stubbed to upload to it.

## License

Licensed under the Apache License, Version 2.0 ([LICENSE](../LICENSE) or http://www.apache.org/licenses/LICENSE-2.0).
