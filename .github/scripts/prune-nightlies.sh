#!/usr/bin/env bash
#
# Rolling cleanup of nightly prereleases: keeps the KEEP most recently
# published nightly releases and deletes the rest together with their remote
# tags. Only prereleases with a strict SemVer nightly tag participate; stable
# releases, drafts and non-conforming tags are never touched.

set -euo pipefail

KEEP="${KEEP:-14}"
[[ "${KEEP}" =~ ^[0-9]+$ ]] \
  || { echo "error: KEEP must be a non-negative integer, got '${KEEP}'" >&2; exit 1; }

NIGHTLY_TAG_PATTERN='v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-nightly\.[1-9][0-9]{7}(\.(0|[1-9][0-9]*))?'

stale_tags="$(
  gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=100" --paginate \
    --jq '.[] | select(.prerelease == true and .draft == false) | "\(.published_at) \(.tag_name)"' \
    | { grep -E "^[^ ]+ ${NIGHTLY_TAG_PATTERN}$" || true; } \
    | sort -r \
    | tail -n "+$(( 10#${KEEP} + 1 ))" \
    | cut -d' ' -f2
)"

if [ -z "${stale_tags}" ]; then
  echo "Nothing to prune: at most ${KEEP} nightly releases exist."
  exit 0
fi

echo "${stale_tags}" | while read -r tag; do
  echo "Deleting nightly release ${tag} (and its tag)"
  gh release delete "${tag}" --cleanup-tag --yes
done
