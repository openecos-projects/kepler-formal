#!/usr/bin/env bash
#
# Resolves the release tag and version for the current run and writes them to
# $GITHUB_OUTPUT:
#
#   tag          - release tag (stable: the pushed tag; nightly: computed)
#   version      - tag without the leading "v"; names the assets and the
#                  tarball top-level directory in both modes
#   title        - release title
#   nightly      - "true" when the run publishes a nightly prerelease
#   skip         - "true" when nothing must be built or published
#   previous_tag - newest published nightly tag (nightly mode, possibly empty)
#
# Nightly tags are strict SemVer 2.0.0: v<base>-nightly.<yyyymmdd>[.<n>] with
# <base> read from KEPLER_VERSION in src/bin/KeplerVersion.h.in. Once the
# stable v<base> tag exists, the patch component is bumped so nightlies sort
# strictly above the released stable. Published tags are never overwritten: a
# scheduled run whose tag already exists exits with skip=true, and a manual
# rerun must pass an integer suffix >= 2. Nightly runs must execute on the
# repository's default branch.

set -euo pipefail

VERSION_HEADER="src/bin/KeplerVersion.h.in"
NIGHTLY_TAG_PATTERN='v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-nightly\.[1-9][0-9]{7}(\.(0|[1-9][0-9]*))?'
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?$'

write_outputs() {
  local tag="$1" version="$2" title="$3" nightly="$4" skip="$5" previous_tag="$6"
  {
    echo "tag=${tag}"
    echo "version=${version}"
    echo "title=${title}"
    echo "nightly=${nightly}"
    echo "skip=${skip}"
    echo "previous_tag=${previous_tag}"
  } >> "${GITHUB_OUTPUT}"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

tag_exists() {
  local rc=0
  git ls-remote --exit-code --tags origin "refs/tags/$1" > /dev/null 2>&1 || rc=$?
  case "${rc}" in
    0) return 0 ;;
    2) return 1 ;; # --exit-code: no matching ref on the remote
    *) fail "could not query remote tags (git ls-remote exited ${rc})" ;;
  esac
}

# Prints "<published_at> <tag> <target_commitish>" for every published nightly
# prerelease, newest first. published_at (not created_at, which carries the
# tagged commit's date) reflects when the release went out. The tag pattern
# follows strict SemVer 2.0.0, rejecting numeric identifiers with leading
# zeros.
list_nightlies() {
  gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=100" --paginate \
    --jq '.[] | select(.prerelease == true and .draft == false) | "\(.published_at) \(.tag_name) \(.target_commitish)"' \
    | { grep -E "^[^ ]+ ${NIGHTLY_TAG_PATTERN} " || true; } \
    | sort -r
}

if [ "${GITHUB_EVENT_NAME}" = "push" ]; then
  version="${GITHUB_REF_NAME#v}"
  write_outputs "${GITHUB_REF_NAME}" "${version}" "kepler-formal ${version}" false false ""
  exit 0
fi

# Nightly mode (scheduled or manual run). Nightlies are always built from the
# default branch, never from an arbitrarily dispatched ref.
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
[ "${GITHUB_REF_NAME}" = "${DEFAULT_BRANCH}" ] \
  || fail "nightly runs must execute on the default branch (${DEFAULT_BRANCH}), got '${GITHUB_REF_NAME}'"

# sed prints every match; parameter expansion keeps the first one, so no
# downstream consumer closes the pipe early under pipefail.
base="$(sed -n 's/.*KEPLER_VERSION[^0-9"]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' "${VERSION_HEADER}")"
base="${base%%$'\n'*}"
[ -n "${base}" ] || fail "could not parse KEPLER_VERSION from ${VERSION_HEADER}"

# Once the stable v<base> tag exists, nightlies target the next patch so they
# sort above the released stable and below the next stable.
if tag_exists "v${base}"; then
  base="${base%.*}.$(( 10#${base##*.} + 1 ))"
fi

suffix=""
if [ -n "${SUFFIX:-}" ]; then
  { [[ "${SUFFIX}" =~ ^[1-9][0-9]*$ ]] && [ "${SUFFIX}" -ge 2 ]; } \
    || fail "suffix must be an integer >= 2, got '${SUFFIX}'"
  suffix=".${SUFFIX}"
fi

# Capture the UTC date once so the tag and title can never straddle midnight.
date_compact="$(date -u +%Y%m%d)"
date_dashed="${date_compact:0:4}-${date_compact:4:2}-${date_compact:6:2}"
tag="v${base}-nightly.${date_compact}${suffix}"
version="${tag#v}"
title="kepler-formal nightly ${date_dashed}${suffix:+ (${SUFFIX})}"

[[ "${version}" =~ ${SEMVER_PATTERN} ]] \
  || fail "computed nightly version '${version}' is not strict SemVer 2.0.0"

# Never overwrite a published tag: downstream consumers pin sha256 per URL.
if tag_exists "${tag}"; then
  if [ "${GITHUB_EVENT_NAME}" = "schedule" ]; then
    echo "Nightly tag ${tag} already exists; skipping this run."
    write_outputs "${tag}" "${version}" "" true true ""
    exit 0
  fi
  [ -n "${suffix}" ] \
    || fail "nightly tag ${tag} already exists; re-run with a suffix input (integer >= 2)"
  fail "nightly tag ${tag} already exists; choose a higher suffix"
fi

# Skip when the newest nightly already covers the current commit. sed reads
# the full stream, so the producer never dies on SIGPIPE under pipefail.
latest="$(list_nightlies | sed -n '1p')"
previous_tag=""
if [ -n "${latest}" ]; then
  previous_tag="$(echo "${latest}" | cut -d' ' -f2)"
  latest_target="$(echo "${latest}" | cut -d' ' -f3)"
  if [ "${latest_target}" = "${GITHUB_SHA}" ]; then
    echo "Newest nightly ${previous_tag} already covers commit ${GITHUB_SHA}; skipping."
    write_outputs "${tag}" "${version}" "" true true "${previous_tag}"
    exit 0
  fi
fi

write_outputs "${tag}" "${version}" "${title}" true false "${previous_tag}"
