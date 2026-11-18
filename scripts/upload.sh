#!/usr/bin/env bash
# Inputs (env): REDSKAP_URL, REDSKAP_REPOSITORY, REDSKAP_TYPE, REDSKAP_FILES,
#   REDSKAP_TOKEN_INPUT, REDSKAP_AUDIENCE, REDSKAP_DIST, REDSKAP_COMPONENT,
#   REDSKAP_FORCE, REDSKAP_VHOST
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd curl jq

base=$(normalize_url "${REDSKAP_URL:?url input is required}")
type="${REDSKAP_TYPE:?type input is required}"
repo="${REDSKAP_REPOSITORY:-}"
force="${REDSKAP_FORCE:-false}"

case "$type" in
  helm | debian) ;;
  *) die "Unsupported type '$type'. Supported: helm, debian" ;;
esac

# Repository endpoint: path style (/r/{repo}/{frontend}) or vhost (domain root).
if [[ "${REDSKAP_VHOST:-false}" == "true" ]]; then
  endpoint="$base"
else
  [[ -n "$repo" ]] || die "repository input is required (or set vhost: true and point url at the repository's domain)"
  endpoint="${base}/r/${repo}/${type}"
fi

# Expand the newline-separated glob list.
shopt -s nullglob globstar
files=()
while IFS= read -r pattern || [[ -n "$pattern" ]]; do
  pattern="${pattern#"${pattern%%[![:space:]]*}"}"
  pattern="${pattern%"${pattern##*[![:space:]]}"}"
  [[ -z "$pattern" || "$pattern" == \#* ]] && continue
  # shellcheck disable=SC2206 # intentional glob expansion, split on newlines only
  IFS=$'\n' matches=($pattern)
  ((${#matches[@]})) || die "No files match '$pattern'"
  for f in "${matches[@]}"; do
    [[ -f "$f" ]] || continue
    # Provenance files are uploaded together with their chart.
    [[ "$type" == "helm" && "$f" == *.prov ]] && continue
    files+=("$f")
  done
done <<<"${REDSKAP_FILES:?files input is required}"
((${#files[@]})) || die "No files to upload"

resolve_token "$base" "${REDSKAP_AUDIENCE:-}" "${REDSKAP_TOKEN_INPUT:-}"
auth=(-H "Authorization: Bearer ${REDSKAP_RESOLVED_TOKEN}")

query=""
[[ "$force" == "true" ]] && query="force=true"

upload_one() {
  local f="$1" url resp
  local -a args
  case "$type" in
    helm)
      if [[ -f "${f}.prov" ]]; then
        # ChartMuseum API carries the chart and its provenance file together.
        url="${endpoint}/api/charts${query:+?$query}"
        args=(-X POST -F "chart=@${f}" -F "prov=@${f}.prov")
        echo "Uploading ${f} (+ ${f}.prov) -> ${url}"
      else
        url="${endpoint}/upload${query:+?$query}"
        args=(-X PUT -T "$f")
        echo "Uploading ${f} -> ${url}"
      fi
      ;;
    debian)
      [[ "$f" == *.deb ]] || die "'$f' is not a .deb file"
      [[ -n "${REDSKAP_DIST:-}" ]] || die "dist input is required for debian uploads"
      [[ -n "${REDSKAP_COMPONENT:-}" ]] || die "component input is required for debian uploads"
      local q
      q="dist=$(jq -rn --arg v "$REDSKAP_DIST" '$v|@uri')&component=$(jq -rn --arg v "$REDSKAP_COMPONENT" '$v|@uri')"
      [[ -n "$query" ]] && q+="&${query}"
      url="${endpoint}/upload?${q}"
      args=(-X PUT -T "$f")
      echo "Uploading ${f} -> ${url}"
      ;;
  esac

  if ! resp=$(curl -sS --fail-with-body --retry 2 "${auth[@]}" "${args[@]}" "$url"); then
    echo "::error file=${f}::Upload failed: ${resp:-no response}"
    return 1
  fi
  [[ -n "$resp" ]] && echo "  ${resp}"
  return 0
}

failed=0
uploaded=()
for f in "${files[@]}"; do
  if upload_one "$f"; then
    uploaded+=("$f")
  else
    failed=$((failed + 1))
  fi
done

set_output uploaded "$(printf '%s\n' "${uploaded[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
set_output count "${#uploaded[@]}"

if ((failed)); then
  die "${failed} of ${#files[@]} uploads failed"
fi
echo "Uploaded ${#uploaded[@]} file(s) to ${endpoint}"
