#!/usr/bin/env bash
#
# Bundles the runtime dependency closure of shipped ELF files into the
# distribution lib/ directory (default mode), or checks that the closure
# is fully satisfied from base-system libraries plus DEST_DIR (--check).
#
# Base-system means the glibc family and the dynamic loader, which any
# Linux userland provides; everything else (TBB, the Naja runtime, the
# embedded CPython from the host python3-config and its own libexpat/zlib
# deps, ...) must travel inside the tarball. Libraries are resolved
# through ldconfig, so host version bumps (e.g. python3.10 -> 3.12) are
# followed automatically. Bazel-produced libraries (libnaja_*, TBB) are
# invisible to ldconfig: the caller bundles those beforehand and this
# script treats anything already inside DEST_DIR as done.
#
# Usage: bundle-runtime-deps.sh [--check] DEST_DIR ELF...

set -euo pipefail

MODE=bundle
if [ "${1:-}" = "--check" ]; then
  MODE=check
  shift
fi

DEST="${1:?usage: bundle-runtime-deps.sh [--check] DEST_DIR ELF...}"
shift
[ "$#" -ge 1 ] || { echo "usage: bundle-runtime-deps.sh [--check] DEST_DIR ELF..." >&2; exit 1; }

SYSTEM_LIB='^(linux-vdso\.so.*|ld-linux.*|ld64\.so.*|libc\.so.*|libm\.so.*|libdl\.so.*|libpthread\.so.*|librt\.so.*|libutil\.so.*|libgcc_s\.so.*|libresolv\.so.*|libnsl\.so.*|libnss_.*|libanl\.so.*|libcrypt\.so.*)$'

needed_by() {
  objdump -p "$1" | awk '/NEEDED/ {print $2}'
}

resolve() { # soname -> host path via ldconfig, empty when unknown
  ldconfig -p | awk -v lib="$1" '$1 == lib {print $NF; exit}'
}

fail() {
  echo "error: $*" >&2
  exit 1
}

seen=" "
rc=0

visit() {
  local file="$1" lib src
  case "${seen}" in
    *" ${file} "*) return 0 ;;
  esac
  seen="${seen}${file} "
  for lib in $(needed_by "${file}"); do
    if [[ "${lib}" =~ ${SYSTEM_LIB} ]]; then
      continue
    fi
    if [ -f "${DEST}/${lib}" ]; then
      visit "${DEST}/${lib}"
      continue
    fi
    if [ "${MODE}" = "check" ]; then
      echo "unbundled non-system dependency: ${lib} (needed by ${file})" >&2
      rc=1
      continue
    fi
    src="$(resolve "${lib}")"
    [ -n "${src}" ] \
      || fail "cannot resolve runtime dependency '${lib}' (needed by ${file}) on this host"
    cp -L "${src}" "${DEST}/${lib}"
    echo "bundled ${lib} <- ${src}"
    visit "${DEST}/${lib}"
  done
}

for elf in "$@"; do
  visit "${elf}"
done

exit "${rc}"
