# shellcheck shell=bash
# Shared helpers for the redskap actions. Source this file; do not execute it.

die() {
  echo "::error::$*" >&2
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but was not found on the runner"
  done
}

# normalize_url strips trailing slashes and requires a scheme.
normalize_url() {
  local u="${1%/}"
  while [[ "$u" == */ ]]; do u="${u%/}"; done
  [[ "$u" =~ ^https?:// ]] || die "instance must start with https:// or http:// (got '$1')"
  printf '%s' "$u"
}

# vhost_url prints the vhost as a URL without trailing slash. A bare host
# (docker.example.com) gets the scheme of the instance URL.
#   vhost_url <vhost> <instance-url>
vhost_url() {
  local v="$1" scheme="${2%%://*}"
  [[ "$v" =~ ^https?:// ]] || v="${scheme}://${v}"
  while [[ "$v" == */ ]]; do v="${v%/}"; done
  printf '%s' "$v"
}

# url_host prints the host[:port] part of a URL.
url_host() {
  local h="${1#*://}"
  printf '%s' "${h%%/*}"
}

# fetch_id_token sets GH_ID_TOKEN to a GitHub Actions OIDC ID token for the
# audience. Results go into globals (not stdout) so ::add-mask:: reaches the
# runner instead of being captured.
fetch_id_token() {
  local audience="$1" resp
  if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
    die "No GitHub OIDC token available. Add 'permissions: id-token: write' to the workflow or job."
  fi
  resp=$(curl -sS --fail-with-body --retry 3 \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    --get --data-urlencode "audience=${audience}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}") || die "Requesting the GitHub OIDC token failed: ${resp:-no response}"
  GH_ID_TOKEN=$(jq -r '.value // empty' <<<"$resp")
  [[ -n "$GH_ID_TOKEN" ]] || die "GitHub returned no OIDC token"
  echo "::add-mask::${GH_ID_TOKEN}"
}

# exchange_token trades an ID token for a redskap token. Sets EXCHANGE_RESPONSE
# to the JSON response ({token, expires_at, subject, bindings, scopes}).
exchange_token() {
  local base="$1" id_token="$2" resp
  resp=$(curl -sS --fail-with-body --retry 3 -X POST \
    -H "Authorization: Bearer ${id_token}" \
    "${base}/api/v1/auth/github/exchange") \
    || die "redskap token exchange failed: ${resp:-no response}"
  local tok
  tok=$(jq -r '.token // empty' <<<"$resp") || die "redskap returned an invalid exchange response: ${resp}"
  [[ -n "$tok" ]] || die "redskap returned no token: ${resp}"
  echo "::add-mask::${tok}"
  EXCHANGE_RESPONSE="$resp"
}

# resolve_token sets REDSKAP_RESOLVED_TOKEN: the given token if non-empty,
# otherwise one obtained through trusted publishing.
#   resolve_token <base-url> <audience> <token>
resolve_token() {
  local base="$1" audience="${2:-$1}" given="${3:-}"
  if [[ -n "$given" ]]; then
    echo "::add-mask::${given}"
    REDSKAP_RESOLVED_TOKEN="$given"
    return
  fi
  fetch_id_token "$audience"
  exchange_token "$base" "$GH_ID_TOKEN"
  REDSKAP_RESOLVED_TOKEN=$(jq -r .token <<<"$EXCHANGE_RESPONSE")
  echo "Obtained redskap token for $(jq -r '.subject' <<<"$EXCHANGE_RESPONSE") (expires $(jq -r '.expires_at' <<<"$EXCHANGE_RESPONSE"))"
}

set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}
