#!/usr/bin/env bash
# Inputs (env): REDSKAP_INSTANCE, REDSKAP_VHOST, REDSKAP_AUDIENCE, REDSKAP_TOKEN_INPUT, REDSKAP_USERNAME
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl jq docker

base=$(normalize_url "${REDSKAP_INSTANCE:?instance input is required}")
# docker login takes a bare host[:port]: the vhost, or the instance host for
# path-style repositories.
registry=$(url_host "$(vhost_url "${REDSKAP_VHOST:-$base}" "$base")")

resolve_token "$base" "${REDSKAP_AUDIENCE:-}" "${REDSKAP_TOKEN_INPUT:-}"

printf '%s' "$REDSKAP_RESOLVED_TOKEN" |
  docker login "$registry" --username "${REDSKAP_USERNAME:-redskap}" --password-stdin

set_output registry "$registry"
