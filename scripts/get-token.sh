#!/usr/bin/env bash
# Inputs (env): REDSKAP_URL, REDSKAP_AUDIENCE, REDSKAP_EXCHANGE, REDSKAP_EXPORT_ENV
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl jq

base=$(normalize_url "${REDSKAP_URL:?url input is required}")
audience="${REDSKAP_AUDIENCE:-$base}"

fetch_id_token "$audience"

if [[ "${REDSKAP_EXCHANGE:-true}" == "true" ]]; then
  exchange_token "$base" "$GH_ID_TOKEN"
  resp="$EXCHANGE_RESPONSE"
  token=$(jq -r .token <<<"$resp")
  expires=$(jq -r '.expires_at // empty' <<<"$resp")
  subject=$(jq -r '.subject // empty' <<<"$resp")
  echo "Obtained redskap token for ${subject} (bindings: $(jq -r '.bindings // [] | join(", ")' <<<"$resp"); scopes: $(jq -r '.scopes // [] | join(", ")' <<<"$resp"); expires ${expires})"
else
  # Raw GitHub ID token: only valid for a few minutes.
  token="$GH_ID_TOKEN"
  claims=$(cut -d. -f2 <<<"$token" | tr '_-' '/+')
  while (( ${#claims} % 4 )); do claims+="="; done
  claims=$(base64 -d <<<"$claims" 2>/dev/null || true)
  expires=$(jq -r '.exp // empty | todate' <<<"$claims" 2>/dev/null || true)
  subject="github:$(jq -r '.repository // empty' <<<"$claims" 2>/dev/null || true)"
  echo "Using the GitHub OIDC ID token directly (expires ${expires:-soon})"
fi

set_output token "$token"
set_output expires-at "$expires"
set_output subject "$subject"

if [[ "${REDSKAP_EXPORT_ENV:-false}" == "true" && -n "${GITHUB_ENV:-}" ]]; then
  printf 'REDSKAP_TOKEN=%s\n' "$token" >>"$GITHUB_ENV"
  echo "Exported REDSKAP_TOKEN to later steps"
fi
