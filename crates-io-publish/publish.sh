#!/usr/bin/env bash
# mode: publish. Publishes each package in PACKAGES, in order, from the
# commit GIT_TAG marks:
#
#   - version already on crates.io: skipped, so a re-run resumes a release;
#   - crate not on crates.io: created with BOOTSTRAP_TOKEN, CRATE_OWNERS
#     invited, and this job's workflow registered as its trusted publisher;
#   - otherwise: published through trusted publishing, with a crates.io
#     token exchanged from the job's GitHub OIDC token and revoked after.
#
# Env: PACKAGES, GIT_TAG, TAG_PREFIX, BOOTSTRAP_TOKEN, CRATE_OWNERS,
# PUBLISH_ARGS, GITHUB_REPOSITORY, GITHUB_WORKFLOW_REF,
# ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN (from id-token: write), and
# RATE_LIMIT_WAIT (seconds between 429 retries; default 120).
# Run tests: bash crates-io-publish/test_crates_io_publish.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

RATE_LIMIT_WAIT="${RATE_LIMIT_WAIT:-120}"
API="$CRATES_IO_API_URL"

check_packages
if [ "$GIT_TAG" != "${TAG_PREFIX}${VERSION}" ]; then
  echo "::error::git-tag is '$GIT_TAG', but the packages are at $VERSION (expected ${TAG_PREFIX}${VERSION})"
  exit 1
fi
if [ "$(git rev-parse -q --verify "refs/tags/$GIT_TAG^{commit}" || true)" != "$(git rev-parse HEAD)" ]; then
  echo "::error::Tag $GIT_TAG doesn't point at HEAD; publish from the commit it tags"
  exit 1
fi

REPO_OWNER="${GITHUB_REPOSITORY%%/*}"
REPO_NAME="${GITHUB_REPOSITORY#*/}"
# crates.io matches trusted publishers on the job's top-level workflow file:
# owner/repo/.github/workflows/publish.yml@refs/heads/main -> publish.yml
WORKFLOW_FILE="${GITHUB_WORKFLOW_REF%%@*}"
WORKFLOW_FILE="${WORKFLOW_FILE##*/}"
FAILED=0

# Tokens travel in headers read from a file descriptor, never in argv.
api() { # api <auth-header-value> <curl args...>: prints the body, then the status on its own line
  local auth="$1"
  shift
  curl -sS -w '\n%{http_code}' -H "User-Agent: $USER_AGENT" \
    -H @<(printf 'Authorization: %s\n' "$auth") "$@"
}
status() { tail -n1 <<<"$1"; }
body() { sed '$d' <<<"$1"; }
detail() { body "$1" | jq -r '[.errors[]?.detail] | join("; ")' 2>/dev/null || true; }

# A GitHub OIDC token for crates.io. Each is single-use at crates.io.
github_jwt() {
  local jwt
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    echo "::error::No GitHub OIDC token available: the job must grant id-token: write" >&2
    return 1
  fi
  jwt=$(curl -sSf -H @<(printf 'Authorization: Bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN") \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=crates.io" | jq -r .value)
  echo "::add-mask::$jwt" >&2
  echo "$jwt"
}

# The job's GitHub environment, read from its OIDC token's `environment`
# claim: the value crates.io matches a publisher's environment against.
# Empty when the job runs in no environment. Checks every step explicitly:
# it runs inside conditions, where set -e doesn't apply.
ENVIRONMENT=""
ENVIRONMENT_READ=false
job_environment() {
  local jwt payload claims
  if [ "$ENVIRONMENT_READ" = true ]; then
    return 0
  fi
  jwt=$(github_jwt) || return 1
  payload=$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')
  while [ $((${#payload} % 4)) -ne 0 ]; do payload="$payload="; done
  claims=$(base64 -d <<<"$payload") || return 1
  ENVIRONMENT=$(jq -er '.environment // ""' <<<"$claims") || return 1
  ENVIRONMENT_READ=true
}

OIDC_TOKEN=""
revoke_oidc() {
  if [ -n "$OIDC_TOKEN" ]; then
    api "Bearer $OIDC_TOKEN" -o /dev/null -X DELETE "$API/trusted_publishing/tokens" >/dev/null || true
    OIDC_TOKEN=""
  fi
}
trap revoke_oidc EXIT

# A fresh token per crate: each lives 30 minutes, which a slow verify build
# or the new-crate rate limit could otherwise outlast.
exchange_oidc() {
  local jwt resp
  jwt=$(github_jwt)
  resp=$(jq -n --arg jwt "$jwt" '{jwt: $jwt}' \
    | curl -sS -w '\n%{http_code}' -H "User-Agent: $USER_AGENT" -H 'Content-Type: application/json' \
        --data @- "$API/trusted_publishing/tokens")
  if [ "$(status "$resp")" != 200 ]; then
    echo "::error::crates.io refused the trusted publishing exchange (HTTP $(status "$resp")): $(detail "$resp")"
    echo "::error::Add $GITHUB_REPOSITORY, workflow $WORKFLOW_FILE as a trusted publisher on crates.io, or pass bootstrap-token so this action adds it"
    exit 1
  fi
  OIDC_TOKEN=$(body "$resp" | jq -r .token)
  echo "::add-mask::$OIDC_TOKEN"
}

# Registers this job's workflow (in its environment, if any) as $1's trusted
# publisher, unless a config already lets this job publish. As crates.io
# matches them, a config with no environment accepts any job; one with an
# environment accepts only jobs in it, compared case-insensitively. Returns
# non-zero on failure.
ensure_trusted_publisher() {
  local crate="$1" resp
  if ! job_environment; then
    echo "::warning::Could not read this job's environment from its GitHub OIDC token"
    return 1
  fi
  resp=$(api "$BOOTSTRAP_TOKEN" "$API/trusted_publishing/github_configs?crate=$crate")
  if [ "$(status "$resp")" != 200 ]; then
    echo "::warning::Could not list trusted publishers of $crate (HTTP $(status "$resp")): $(detail "$resp")"
    return 1
  fi
  if body "$resp" | jq -e --arg o "${REPO_OWNER,,}" --arg r "${REPO_NAME,,}" --arg w "$WORKFLOW_FILE" \
      --arg e "${ENVIRONMENT,,}" \
      '.github_configs[] | select((.repository_owner | ascii_downcase) == $o
        and (.repository_name | ascii_downcase) == $r and .workflow_filename == $w
        and (.environment == null or (.environment | ascii_downcase) == $e))' >/dev/null; then
    echo "OK: $crate already trusts $GITHUB_REPOSITORY $WORKFLOW_FILE${ENVIRONMENT:+ in $ENVIRONMENT}"
    return 0
  fi
  resp=$(jq -n --arg c "$crate" --arg o "$REPO_OWNER" --arg r "$REPO_NAME" --arg w "$WORKFLOW_FILE" \
      --arg e "$ENVIRONMENT" \
      '{github_config: {crate: $c, repository_owner: $o, repository_name: $r, workflow_filename: $w,
        environment: (if $e == "" then null else $e end)}}' \
    | api "$BOOTSTRAP_TOKEN" -X POST -H 'Content-Type: application/json' --data @- \
        "$API/trusted_publishing/github_configs")
  if [ "$(status "$resp")" != 200 ]; then
    echo "::warning::Could not add $GITHUB_REPOSITORY $WORKFLOW_FILE as trusted publisher of $crate (HTTP $(status "$resp")): $(detail "$resp")"
    return 1
  fi
  echo "OK: $crate now trusts $GITHUB_REPOSITORY $WORKFLOW_FILE${ENVIRONMENT:+ in $ENVIRONMENT}"
}

# crates.io rate-limits new crates (a small burst, then one every few
# minutes), so a 429 waits and retries instead of failing a first release
# halfway. --registry: a [registry] default elsewhere must not redirect it.
publish() { # publish <package> <token>
  local pkg="$1" token="$2" attempt output rc
  for attempt in $(seq 1 15); do
    rc=0
    # shellcheck disable=SC2086 # PUBLISH_ARGS is a list of flags
    output=$(CARGO_REGISTRY_TOKEN="$token" cargo publish --registry crates-io --locked -p "$pkg" $PUBLISH_ARGS 2>&1) || rc=$?
    echo "$output"
    if [ "$rc" -eq 0 ]; then
      echo "OK: published $pkg"
      return 0
    fi
    if grep -q 'status 429' <<<"$output" && [ "$attempt" -lt 15 ]; then
      echo "crates.io rate limit (attempt $attempt); retrying in ${RATE_LIMIT_WAIT}s"
      sleep "$RATE_LIMIT_WAIT"
      continue
    fi
    echo "::error::Failed to publish $pkg"
    exit 1
  done
}

for pkg in $PACKAGES; do
  ENSURED=false
  NAME=""
  if ! on_index "$pkg" "$VERSION"; then
    NAME=$(crates_io_name "$pkg")
  fi
  if [ -z "$NAME" ]; then
    echo "SKIP: $pkg@$VERSION is already on crates.io"
  elif [ "$NAME" != missing ] && [ "$NAME" != "$pkg" ]; then
    echo "::error::crates.io already has a crate named '$NAME', which it treats as the same name as '$pkg'"
    exit 1
  elif [ "$NAME" = missing ]; then
    if [ -z "$BOOTSTRAP_TOKEN" ]; then
      echo "::error::$pkg doesn't exist on crates.io yet; creating it needs bootstrap-token"
      exit 1
    fi
    echo "Creating $pkg@$VERSION with the bootstrap token"
    publish "$pkg" "$BOOTSTRAP_TOKEN"
    for owner in $CRATE_OWNERS; do
      if CARGO_REGISTRY_TOKEN="$BOOTSTRAP_TOKEN" cargo owner --registry crates-io --add "$owner" "$pkg"; then
        echo "OK: invited $owner to own $pkg"
      else
        echo "::warning::Could not add $owner as an owner of $pkg; add it with cargo owner --add"
      fi
    done
  else
    # A crate first published by hand gets its trusted publisher here;
    # without the bootstrap token it must already have one. Either way,
    # publishing through OIDC proves it does.
    if [ -n "$BOOTSTRAP_TOKEN" ]; then
      ensure_trusted_publisher "$pkg" || true
    fi
    exchange_oidc
    publish "$pkg" "$OIDC_TOKEN"
    revoke_oidc
    ENSURED=true
  fi

  # Also on SKIP, so re-running a release whose first run died right after
  # creating a crate still registers its publisher. A failure fails the run
  # (after the remaining crates), so the bootstrap token isn't retired with
  # a crate left unable to publish through OIDC.
  if [ -n "$BOOTSTRAP_TOKEN" ] && [ "$ENSURED" = false ] && ! ensure_trusted_publisher "$pkg"; then
    echo "::error::$pkg is published, but can't use trusted publishing until $GITHUB_REPOSITORY $WORKFLOW_FILE${ENVIRONMENT:+ (environment $ENVIRONMENT)} is added as its trusted publisher on crates.io"
    FAILED=1
  fi
done

exit "$FAILED"
