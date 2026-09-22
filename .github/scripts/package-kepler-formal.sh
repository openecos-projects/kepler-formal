#!/usr/bin/env bash

# Copyright 2026 keplertech.io
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

build_dir="${BUILD_DIR:-build}"
binary="${BINARY_PATH:-${build_dir}/src/bin/kepler-formal}"
naja_module="${NAJA_MODULE_PATH:-${build_dir}/src/bin/naja.so}"
dist_dir="${DIST_DIR:-dist}"
package_name="${PACKAGE_NAME:-kepler-formal}"
archive_name="${ARCHIVE_NAME:-kepler-formal-linux-x64.tar.gz}"
package_root="${dist_dir}/${package_name}"

if ! command -v lddtree >/dev/null 2>&1; then
  echo "lddtree is required; install pax-utils before packaging." >&2
  exit 1
fi

if [[ ! -x "${binary}" ]]; then
  echo "kepler-formal binary not found at ${binary}." >&2
  exit 1
fi

if [[ ! -f "${naja_module}" ]]; then
  echo "Naja python module not found at ${naja_module}." >&2
  exit 1
fi

rm -rf "${dist_dir}"
mkdir -p "${package_root}/bin" "${package_root}/lib" "${package_root}/libexec"

cp "${binary}" "${package_root}/libexec/kepler-formal"
# CppDriver prepends the running executable's directory to PYTHONPATH, so the
# naja python module must sit next to the real binary in libexec.
cp "${naja_module}" "${package_root}/libexec/naja.so"
install -m 0644 LICENSE.rst "${package_root}/LICENSE.rst"
install -m 0644 README.md "${package_root}/README.md"
cp -a mcp "${package_root}/mcp"

copy_library() {
  local lib="$1"
  local lib_base
  local soname

  lib_base="$(basename "${lib}")"
  cp -nL "${lib}" "${package_root}/lib/"

  soname="$(
    readelf -d "${lib}" 2>/dev/null |
      awk '/SONAME/ { name=$0; sub(/.*\[/, "", name); sub(/\].*/, "", name); print name; exit }'
  )"

  if [[ -n "${soname}" && "${soname}" != "${lib_base}" && ! -e "${package_root}/lib/${soname}" ]]; then
    ln -s "${lib_base}" "${package_root}/lib/${soname}"
  fi
}

dependency_list="$(mktemp)"
dynload_list="$(mktemp)"
needed_list="$(mktemp)"
available_list="$(mktemp)"
missing_list="$(mktemp)"
trap 'rm -f "${dependency_list}" "${dynload_list}" "${needed_list}" "${available_list}" "${missing_list}"' EXIT

# Collect the full shared-library closure of the driver binary and the naja
# python module. The build-tree RPATHs let lddtree resolve the in-tree naja
# libraries, so they end up in the bundle like any other dependency.
for elf in "${package_root}/libexec/kepler-formal" "${package_root}/libexec/naja.so"; do
  lddtree -l "${elf}" | tail -n +2 | awk '/^\// { print }'
done | sort -u > "${dependency_list}"

while IFS= read -r lib; do
  copy_library "${lib}"
done < "${dependency_list}"

if [[ ! -f "${package_root}/lib/ld-linux-x86-64.so.2" && -f /lib64/ld-linux-x86-64.so.2 ]]; then
  cp -nL /lib64/ld-linux-x86-64.so.2 "${package_root}/lib/"
fi

if [[ ! -f "${package_root}/lib/ld-linux-x86-64.so.2" ]]; then
  echo "Could not bundle the dynamic loader (ld-linux-x86-64.so.2)." >&2
  exit 1
fi

# glibc name-service modules are dlopen'ed at runtime and never show up in the
# lddtree closure; bundle them so lookups keep working with the bundled glibc.
for lib in \
  /lib/x86_64-linux-gnu/libnss_dns.so.2 \
  /lib/x86_64-linux-gnu/libnss_files.so.2 \
  /lib/x86_64-linux-gnu/libnss_compat.so.2 \
  /lib/x86_64-linux-gnu/libresolv.so.2 \
  /lib/x86_64-linux-gnu/libnss_hesiod.so.2
do
  if [[ -f "${lib}" ]]; then
    cp -nL "${lib}" "${package_root}/lib/"
  fi
done

# Bundle the Python standard library matching the linked libpython so the
# embedded interpreter works on machines without a compatible system Python.
python_stdlib=""
python_version=""
libpython="$(find "${package_root}/lib" -maxdepth 1 -type f -name 'libpython*.so.*' | sort | head -1)"
if [[ -n "${libpython}" ]]; then
  python_version="$(basename "${libpython}" | sed -E 's/^libpython([0-9]+\.[0-9]+).*/\1/')"
  source_libpython="$(grep -m1 "/libpython${python_version}" "${dependency_list}" || true)"
  if [[ -z "${source_libpython}" ]]; then
    echo "Bundled libpython${python_version} is missing from the dependency list." >&2
    exit 1
  fi
  libpython_dir="$(dirname "$(readlink -f "${source_libpython}")")"
  for candidate in "${libpython_dir}" "${libpython_dir}/.." "${libpython_dir}/../.."; do
    if [[ -d "${candidate}/python${python_version}" ]]; then
      python_stdlib="$(readlink -f "${candidate}/python${python_version}")"
      break
    fi
  done
  if [[ -z "${python_stdlib}" ]]; then
    echo "Found ${source_libpython} but no python${python_version} standard library next to it." >&2
    exit 1
  fi
  cp -a "${python_stdlib}" "${package_root}/lib/python${python_version}"

  # Dynamic stdlib extensions (ssl, ctypes, ...) link libraries the main
  # binaries do not reference; bundle the ones that resolve on this host.
  find "${package_root}/lib/python${python_version}/lib-dynload" -name '*.so' -print0 2>/dev/null |
    while IFS= read -r -d '' module; do
      lddtree -l "${module}" | tail -n +2 | awk '/^\// { print }'
    done | sort -u > "${dynload_list}"
  while IFS= read -r lib; do
    if [[ -e "${lib}" ]]; then
      copy_library "${lib}"
    else
      echo "WARNING: unresolved dependency ${lib} of a python stdlib module; skipping" >&2
    fi
  done < "${dynload_list}"
fi

install -m 0755 .github/scripts/kepler-formal-wrapper.sh "${package_root}/bin/kepler-formal"

# Strict closure check: every NEEDED entry of the binaries and the top-level
# bundled libraries must resolve inside the bundle.
find "${package_root}/lib" -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | sort -u > "${available_list}"
find "${package_root}/libexec" "${package_root}/lib" -maxdepth 1 \( -type f -o -type l \) -print0 |
  while IFS= read -r -d '' elf; do
    readelf -h "${elf}" >/dev/null 2>&1 || continue
    readelf -d "${elf}" 2>/dev/null |
      awk '/NEEDED/ { name=$0; sub(/.*\[/, "", name); sub(/\].*/, "", name); print name }'
  done | sort -u > "${needed_list}"

while IFS= read -r soname; do
  if ! grep -Fxq "${soname}" "${available_list}"; then
    echo "${soname}" >> "${missing_list}"
  fi
done < "${needed_list}"

if [[ -s "${missing_list}" ]]; then
  echo "Missing bundled shared libraries:" >&2
  cat "${missing_list}" >&2
  exit 1
fi

# Python stdlib extensions may reference libraries that only exist on the
# build host; report instead of failing (imports degrade gracefully).
if [[ -n "${python_version}" && -d "${package_root}/lib/python${python_version}" ]]; then
  : > "${missing_list}"
  find "${package_root}/lib/python${python_version}" \( -type f -o -type l \) -print0 |
    while IFS= read -r -d '' elf; do
      readelf -h "${elf}" >/dev/null 2>&1 || continue
      readelf -d "${elf}" 2>/dev/null |
        awk '/NEEDED/ { name=$0; sub(/.*\[/, "", name); sub(/\].*/, "", name); print name }'
    done | sort -u > "${needed_list}"
  while IFS= read -r soname; do
    if ! grep -Fxq "${soname}" "${available_list}"; then
      echo "${soname}" >> "${missing_list}"
    fi
  done < "${needed_list}"
  if [[ -s "${missing_list}" ]]; then
    echo "WARNING: python stdlib modules reference unbundled libraries:" >&2
    cat "${missing_list}" >&2
  fi
fi

"${package_root}/lib/ld-linux-x86-64.so.2" \
  --inhibit-cache \
  --inhibit-rpath "" \
  --library-path "${package_root}/lib" \
  --list \
  "${package_root}/libexec/kepler-formal" >/dev/null

"${package_root}/lib/ld-linux-x86-64.so.2" \
  --inhibit-cache \
  --inhibit-rpath "" \
  --library-path "${package_root}/lib" \
  --list \
  "${package_root}/libexec/naja.so" >/dev/null

# Source trees may be read-only (e.g. the Nix store); make the bundle
# writable so the tarball is easy to unpack and delete.
chmod -R u+rwX "${package_root}"

tar --owner=root --group=root -czf "${dist_dir}/${archive_name}" -C "${dist_dir}" "${package_name}"

echo "Packaged ${dist_dir}/${archive_name}"
