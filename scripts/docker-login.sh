#!/usr/bin/env bash
# Inputs (env): REDSKAP_URL, REDSKAP_REGISTRY, REDSKAP_AUDIENCE, REDSKAP_TOKEN_INPUT, REDSKAP_USERNAME
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl jq docker

base=$(normalize_url "${REDSKAP_URL:?url input is required}")
registry="${REDSKAP_REGISTRY:-$(url_host "$base")}"
registry="${registry#*://}"
registry="${registry%/}"

resolve_token "$base" "${REDSKAP_AUDIENCE:-}" "${REDSKAP_TOKEN_INPUT:-}"

printf '%s' "$REDSKAP_RESOLVED_TOKEN" |
  docker login "$registry" --username "${REDSKAP_USERNAME:-redskap}" --password-stdin

set_output registry "$registry"
