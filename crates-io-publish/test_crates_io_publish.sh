#!/usr/bin/env bash
# Offline tests for check.sh and publish.sh against a mock crates.io
# (mock_crates_io.py), with `cargo publish` and `cargo owner` stubbed to
# upload to it. Needs cargo, jq, curl and python3.
# Run: bash crates-io-publish/test_crates_io_publish.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILED=1; fi
}

TMP="$(mktemp -d)"
python3 "$HERE/mock_crates_io.py" "$TMP/port" &
MOCK_PID=$!
trap 'kill "$MOCK_PID"; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
MOCK="http://127.0.0.1:$(cat "$TMP/port")"

export CRATES_IO_API_URL="$MOCK/api/v1" CRATES_IO_INDEX_URL="$MOCK/index" CRATES_IO_DL_URL="$MOCK/dl"
export CRATES_IO_API_DELAY=0 RATE_LIMIT_WAIT=0 CARGO_NET_OFFLINE=true
export GITHUB_REPOSITORY=o/r GITHUB_WORKFLOW_REF="o/r/.github/workflows/publish.yml@refs/heads/main"
export ACTIONS_ID_TOKEN_REQUEST_URL="$MOCK/oidc?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=reqtok

# cargo stub: publish and owner go to the mock (and insist on --registry
# crates-io), publish uploading the .crate cargo package builds; everything
# else is the real cargo.
REAL_CARGO="$(command -v cargo)"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
  publish | owner)
    [[ " \$* " == *" --registry crates-io "* ]] || { echo "stub: missing --registry crates-io" >&2; exit 2; }
    ;;
esac
case "\$1" in
  publish)
    pkg=\$(sed -n 's/.* -p \([^ ]*\).*/\1/p' <<<"\$*")
    vers=\$("$REAL_CARGO" metadata --no-deps --format-version 1 | jq -r --arg p "\$pkg" '.packages[] | select(.name == \$p) | .version')
    "$REAL_CARGO" package --quiet --no-verify --allow-dirty -p "\$pkg" --target-dir "$TMP/stub-package" >&2
    crate=\$(base64 -w0 "$TMP/stub-package/package/\$pkg-\$vers.crate")
    code=\$(jq -n --arg n "\$pkg" --arg v "\$vers" --arg t "\$CARGO_REGISTRY_TOKEN" --arg c "\$crate" \
        --arg s "\$(git rev-parse HEAD)" '{name: \$n, vers: \$v, token: \$t, crate: \$c, sha: \$s}' \
      | curl -sS -o "$TMP/stub-response" -w '%{http_code}' -H 'Content-Type: application/json' --data @- "$MOCK/_test/publish")
    case "\$code" in
      200) echo "Uploaded \$pkg v\$vers" ;;
      429)
        echo "error: failed to publish to registry at https://crates.io"
        echo
        echo "Caused by:"
        echo "  the remote server responded with an error (status 429 Too Many Requests): \$(jq -r '.errors[0].detail' "$TMP/stub-response")"
        exit 101
        ;;
      *) echo "error: failed to publish (HTTP \$code)"; exit 101 ;;
    esac
    ;;
  owner)
    curl -sSf -o /dev/null -H "Authorization: \$CARGO_REGISTRY_TOKEN" --data '{}' "$MOCK/_test/owner"
    ;;
  *) exec "$REAL_CARGO" "\$@" ;;
esac
EOF
chmod +x "$TMP/bin/cargo"
export PATH="$TMP/bin:$PATH"

# A git workspace: zz-new and zz-old at 0.2.0, the latter with a README from
# outside its directory and a dependency inherited from the workspace.
WS="$TMP/ws"
mkdir -p "$WS/new/src" "$WS/old/src"
: > "$WS/new/src/lib.rs"
: > "$WS/old/src/lib.rs"
echo "readme v1" > "$WS/README.md"
cat > "$WS/Cargo.toml" <<'EOF'
[workspace]
resolver = "2"
members = ["new", "old"]

[workspace.package]
version = "0.2.0"
EOF
for p in new old; do
  printf '[package]\nname = "zz-%s"\nversion.workspace = true\nedition = "2021"\nlicense = "MIT"\ndescription = "t"\n' "$p" > "$WS/$p/Cargo.toml"
done
printf 'readme = "../README.md"\n' >> "$WS/old/Cargo.toml"
git -C "$WS" init -q
git -C "$WS" config user.email t@example.com
git -C "$WS" config user.name t
(cd "$WS" && "$REAL_CARGO" generate-lockfile --offline -q)
git -C "$WS" add -A
git -C "$WS" commit -qm base

mock() { curl -sSf -o /dev/null -H 'Content-Type: application/json' --data "${2-}" "$MOCK/_test/$1"; }
state() { curl -sSf "$MOCK/_test/state" | jq -c "$1"; }
reset() { mock reset '{}'; mock seed '{"crates": {"zz-old": ["0.1.0"]}}'; }
# seed_file <package> <version>: uploads, as <version> of <package>
# published with an API token, the .crate cargo package builds from the
# workspace as it stands.
seed_file() {
  (cd "$WS" && "$REAL_CARGO" package --quiet --no-verify --allow-dirty -p "$1" --target-dir "$TMP/seed-package")
  mock seed "$(jq -n --arg p "$1" --arg v "$2" --arg c "$(base64 -w0 "$TMP/seed-package/package/$1-$2.crate")" \
    '{files: {($p): {($v): $c}}}')"
}
# seed_tampered <package> <version>: as seed_file, from a changed lib.rs.
seed_tampered() {
  local src="$WS/${1#zz-}/src/lib.rs"
  echo "// not from this repository" >> "$src"
  seed_file "$1" "$2"
  git -C "$WS" checkout -q -- "$src"
}

# run <check|publish> [VAR=value...]: runs the mode in the workspace; prints
# its GITHUB_OUTPUT lines, then "exit <status>".
run() {
  local mode="$1" out rc=0
  shift
  out="$(mktemp)"
  (cd "$WS" && env PACKAGES="zz-new zz-old" TAG_PREFIX=v ON_EXISTING_TAG=fail BOOTSTRAP_TOKEN= \
    CRATE_OWNERS= PUBLISH_ARGS= GIT_TAG=v0.2.0 GITHUB_OUTPUT="$out" "$@" \
    bash "$HERE/$mode.sh" > "$TMP/last.log" 2>&1) || rc=$?
  cat "$out"
  echo "exit $rc"
}
result() { tail -n1 <<<"$1"; }
output() { sed -n "s/^$2=//p" <<<"$1"; }

# ---- check ----
reset
r=$(run check)
check "new crate without bootstrap token is refused" "exit 1" "$(result "$r")"
r=$(run check BOOTSTRAP_TOKEN=boot)
check "new crate with bootstrap token releases" "exit 0" "$(result "$r")"
check "release output" true "$(output "$r" release)"
check "new-crates output" zz-new "$(output "$r" new-crates)"
check "tag output" v0.2.0 "$(output "$r" tag)"
r=$(run check BOOTSTRAP_TOKEN=boot ON_EXISTING_TAG=sometimes)
check "unknown on-existing-tag" "exit 1" "$(result "$r")"

# Existing crates must require trusted publishing (zz-old doesn't, after reset).
r=$(run check PACKAGES=zz-old)
check "existing crate open to API-token publishes fails the check" "exit 1" "$(result "$r")"
check "... naming the setting to tick" 1 "$(grep -c 'Require trusted publishing for all new versions' "$TMP/last.log" || true)"
r=$(run check PACKAGES=zz-old BOOTSTRAP_TOKEN=boot)
check "... unless publish turns it on with bootstrap-token" "exit 0 true" "$(result "$r") $(output "$r" release)"
r=$(run check PACKAGES=zz-old REQUIRE_TRUSTED_PUBLISHING=false)
check "... or require-trusted-publishing is false" "exit 0" "$(result "$r")"
mock seed '{"trustpub_only": ["zz-old"]}'
r=$(run check PACKAGES=zz-old)
check "existing crate requiring trusted publishing passes without a token" "exit 0 true" "$(result "$r") $(output "$r" release)"
reset

mock seed '{"crates": {"zz_new": []}}'
r=$(run check BOOTSTRAP_TOKEN=boot)
check "name held by zz_new on crates.io" "exit 1" "$(result "$r")"

reset
mock seed '{"crates": {"zz-old": ["0.1.0", "0.2.0"]}}'
r=$(run check BOOTSTRAP_TOKEN=boot)
check "version published without a tag here" "exit 1" "$(result "$r")"

# Release 0.2.0 at the base commit, then move HEAD on.
reset
mock seed '{"crates": {"zz-new": ["0.2.0"], "zz-old": ["0.1.0", "0.2.0"]}, "trustpub_only": ["zz-new", "zz-old"]}'
git -C "$WS" tag v0.2.0
seed_file zz-new 0.2.0
seed_file zz-old 0.2.0
echo "// more" > "$WS/new/src/lib.rs"
git -C "$WS" commit -qam "change zz-new"

r=$(run check PACKAGES=zz-old)
check "tag on another commit fails by default" "exit 1" "$(result "$r")"
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "unchanged published group skips" "exit 0 false" "$(result "$r") $(output "$r" release)"
mock seed '{"crates": {"zz-old": ["0.1.0", "0.2.0"]}}'
seed_file zz-old 0.2.0
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published BOOTSTRAP_TOKEN=boot)
check "a skipped group open to API-token publishes fails, token or not" "exit 1" "$(result "$r")"
mock seed '{"trustpub_only": ["zz-old"]}'
seed_tampered zz-old 0.2.0
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "a published version that isn't the tag's fails the skip" "exit 1" "$(result "$r")"
check "... because it differs from crates.io's" 1 "$(grep -c 'its contents differ from zz-old at this commit' "$TMP/last.log" || true)"
seed_file zz-old 0.2.0
trustpub() { # trustpub <commit>: zz-old 0.2.0's provenance, published from o/r at <commit>
  mock seed "$(jq -n --arg s "$1" '{provenance: {"zz-old": {"0.2.0": {provider: "github", repository: "o/r", run_id: "1", sha: $s}}}}')"
}
trustpub "$(git -C "$WS" rev-parse v0.2.0)"
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "a version trusted publishing released from the tag skips" "exit 0 false" "$(result "$r") $(output "$r" release)"
trustpub "$(git -C "$WS" rev-parse HEAD)"
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "a version trusted publishing released from another commit fails the skip" "exit 1" "$(result "$r")"
mock seed '{"provenance": {"zz-old": {"0.2.0": null}}}'
r=$(run check PACKAGES="zz-new zz-old" ON_EXISTING_TAG=skip-if-published)
check "a changed crate without a bump fails the skip" "exit 1" "$(result "$r")"
git -C "$WS" reset -q --hard HEAD~1
echo "readme v2" > "$WS/README.md"
git -C "$WS" commit -qam "change README"
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "README outside the crate dir counts as a change" "exit 1" "$(result "$r")"
git -C "$WS" reset -q --hard HEAD~1
sed -i 's/^version = "0.2.0"/version = "0.2.0"\nlicense = "MIT"/' "$WS/Cargo.toml"
git -C "$WS" commit -qam "workspace change zz-old doesn't inherit"
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "workspace change that doesn't reach the crate still skips" "exit 0 false" "$(result "$r") $(output "$r" release)"
mock seed '{"crates": {"zz-old": ["0.1.0"]}}'
r=$(run check PACKAGES=zz-old ON_EXISTING_TAG=skip-if-published)
check "tagged elsewhere but unpublished fails the skip" "exit 1" "$(result "$r")"
git -C "$WS" reset -q --hard HEAD~1
git -C "$WS" tag -d v0.2.0 >/dev/null

# ---- publish ----
reset
r=$(run publish BOOTSTRAP_TOKEN=boot)
check "publish refuses an untagged HEAD" "exit 1" "$(result "$r")"
git -C "$WS" tag v0.2.0
r=$(run publish BOOTSTRAP_TOKEN=boot GIT_TAG=v0.3.0)
check "publish refuses a tag that doesn't match the version" "exit 1" "$(result "$r")"

# zz-old already exists and was first published by hand (no publisher).
reset
mock seed '{"rate_limited": ["zz-new"], "retry_after": 3, "claims": {"environment": "Release"}}'
start=$(date +%s)
r=$(run publish BOOTSTRAP_TOKEN=boot CRATE_OWNERS=github:o:team)
waited=$(($(date +%s) - start))
check "first release: creates, adopts and publishes" "exit 0" "$(result "$r")"
check "both versions published" '["0.2.0"] ["0.1.0","0.2.0"]' \
  "$(state '.crates["zz-new"].versions') $(state '.crates["zz-old"].versions')"
check "publishers registered in the job's environment" '["Release"] ["Release"]' \
  "$(state '[.crates["zz-new"].configs[].environment]') $(state '[.crates["zz-old"].configs[].environment]')"
check "zz-new created with the bootstrap token, after a 429" 2 \
  "$(state '[.log[] | select(.[1] == "/_test/publish" and .[3].name == "zz-new" and .[3].token == "boot")] | length')"
check "zz-old published through OIDC" 1 \
  "$(state '[.log[] | select(.[1] == "/_test/publish" and .[3].name == "zz-old" and (.[3].token | startswith("oidc-")))] | length')"
check "429 waits for the time crates.io gives" 1 \
  "$(grep -cE 'retrying after [A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9:]{8} GMT, in [2-4]s' "$TMP/last.log" || true)"
check "... and actually waits" true "$([ "$waited" -ge 2 ] && echo true || echo false)"
check "trusted publishing required on the crate it created and the one it adopted" 'true true' \
  "$(state '.crates["zz-new"].trustpub_only // false') $(state '.crates["zz-old"].trustpub_only // false')"
check "owners invited" 1 "$(state '[.log[] | select(.[1] == "/_test/owner")] | length')"
check "OIDC tokens revoked" '{}' "$(state .oidc_tokens)"

r=$(run check BOOTSTRAP_TOKEN=boot)
check "check on the tagged commit passes versions it published" "exit 0 true" "$(result "$r") $(output "$r" release)"
r=$(run publish BOOTSTRAP_TOKEN=boot)
check "re-run skips everything" "exit 0" "$(result "$r")"
check "re-run uploads nothing" 0 \
  "$(grep -c '^Uploaded' "$TMP/last.log" || true)"
check "re-run adds no publishers" '1 1' \
  "$(state '.crates["zz-new"].configs | length') $(state '.crates["zz-old"].configs | length')"
seed_tampered zz-new 0.2.0
r=$(run check BOOTSTRAP_TOKEN=boot)
check "check on the tagged commit refuses a published version that isn't the tag's" "exit 1" "$(result "$r")"
r=$(run publish BOOTSTRAP_TOKEN=boot)
check "re-run refuses a published version that isn't the tag's" "exit 1" "$(result "$r")"
check "... because it differs from crates.io's" 1 "$(grep -c 'its contents differ from zz-new at this commit' "$TMP/last.log" || true)"
check "refused re-run uploads nothing" 0 "$(grep -c '^Uploaded' "$TMP/last.log" || true)"
seed_file zz-new 0.2.0
mock seed '{"cksums": {"zz-new": {"0.2.0": "0000000000000000000000000000000000000000000000000000000000000000"}}}'
r=$(run publish BOOTSTRAP_TOKEN=boot)
check "re-run refuses a download that doesn't match the index checksum" "exit 1" "$(result "$r")"
check "... as a checksum mismatch" 1 "$(grep -c 'but the crates.io index lists 0000' "$TMP/last.log" || true)"
check "... uploading nothing" 0 "$(grep -c '^Uploaded' "$TMP/last.log" || true)"
mock seed '{"cksums": {"zz-new": {"0.2.0": null}}}'

# Next version, no bootstrap token: OIDC only.
sed -i 's/^version = "0.2.0"/version = "0.2.1"/' "$WS/Cargo.toml"
(cd "$WS" && "$REAL_CARGO" generate-lockfile --offline -q)
git -C "$WS" commit -qam "0.2.1"
git -C "$WS" tag v0.2.1
r=$(run publish GIT_TAG=v0.2.1)
check "next release publishes through OIDC alone" "exit 0" "$(result "$r")"
check "0.2.1 published" '["0.2.0","0.2.1"] ["0.1.0","0.2.0","0.2.1"]' \
  "$(state '.crates["zz-new"].versions') $(state '.crates["zz-old"].versions')"
check "every crate's OIDC token revoked" '{}' "$(state .oidc_tokens)"
r=$(run publish GIT_TAG=v0.2.1)
check "re-run skips versions trusted publishing released from the tag" "exit 0" "$(result "$r")"
mock seed '{"provenance": {"zz-old": {"0.2.1": {"provider": "github", "repository": "o/r", "run_id": "2", "sha": "0000000000000000000000000000000000000000"}}}}'
r=$(run publish GIT_TAG=v0.2.1)
check "re-run refuses a version trusted publishing released from another commit" "exit 1" "$(result "$r")"
check "... naming where it came from" 1 "$(grep -c 'published from github o/r at 0000000' "$TMP/last.log" || true)"
mock seed '{"provenance": {"zz-old": {"0.2.1": {"provider": "github", "repository": "x/r", "run_id": "2", "sha": "'"$(git -C "$WS" rev-parse HEAD)"'"}}}}'
r=$(run publish GIT_TAG=v0.2.1)
check "re-run refuses a version trusted publishing released from another repository" "exit 1" "$(result "$r")"

# A job outside the publishers' environment can't publish.
mock seed '{"claims": {"environment": "other"}}'
sed -i 's/^version = "0.2.1"/version = "0.2.2"/' "$WS/Cargo.toml"
(cd "$WS" && "$REAL_CARGO" generate-lockfile --offline -q)
git -C "$WS" commit -qam "0.2.2"
git -C "$WS" tag v0.2.2
r=$(run publish GIT_TAG=v0.2.2)
check "job in the wrong environment is refused" "exit 1" "$(result "$r")"

# A publisher scoped to another environment doesn't count as this job's.
reset
mock seed '{"crates": {"zz-new": ["0.2.2"], "zz-old": ["0.1.0", "0.2.2"]}, "claims": {"environment": "release"},
  "configs": [{"crate": "zz-new", "repository_owner": "o", "repository_name": "r",
               "workflow_filename": "publish.yml", "environment": "staging"}]}'
seed_file zz-new 0.2.2
seed_file zz-old 0.2.2
r=$(run publish GIT_TAG=v0.2.2 BOOTSTRAP_TOKEN=boot)
check "publisher in another environment gets one for this job's" '["staging","release"]' \
  "$(state '[.crates["zz-new"].configs[].environment]')"

# A re-run whose publisher setup fails (token rejected) fails the run.
reset
mock seed '{"crates": {"zz-new": ["0.2.2"], "zz-old": ["0.1.0", "0.2.2"]}}'
seed_file zz-new 0.2.2
seed_file zz-old 0.2.2
r=$(run publish GIT_TAG=v0.2.2 BOOTSTRAP_TOKEN=bad)
check "failed publisher setup fails a re-run" "exit 1" "$(result "$r")"

# Creating a crate with require-trusted-publishing off leaves the setting alone.
reset
r=$(run publish GIT_TAG=v0.2.2 BOOTSTRAP_TOKEN=boot REQUIRE_TRUSTED_PUBLISHING=false)
check "require-trusted-publishing false creates the crate" "exit 0" "$(result "$r")"
check "... without requiring trusted publishing" false "$(state '.crates["zz-new"].trustpub_only // false')"

# A crate left accepting API-token publishes fails the run, after publishing.
reset
mock seed '{"reject_patch": true}'
r=$(run publish GIT_TAG=v0.2.2 BOOTSTRAP_TOKEN=boot)
check "failing to require trusted publishing fails the run" "exit 1" "$(result "$r")"
check "... once both crates are published" '["0.2.2"] ["0.1.0","0.2.2"]' \
  "$(state '.crates["zz-new"].versions') $(state '.crates["zz-old"].versions')"
check "... naming the setting to tick for each crate" 2 "$(grep -c 'still accepts new versions published with API tokens' "$TMP/last.log" || true)"

exit "$FAILED"
