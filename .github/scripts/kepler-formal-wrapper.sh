#!/usr/bin/env bash

# Copyright 2026 keplertech.io
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

release_bindir="$(dirname "${BASH_SOURCE[0]}")"
release_bindir_abs="$(readlink -f "${release_bindir}")"
release_topdir_abs="$(readlink -f "${release_bindir_abs}/..")"

export PATH="${release_bindir_abs}:${PATH}"

# The bundled Python standard library (when present) pairs with the bundled
# libpython; point the embedded interpreter at it for a deterministic runtime.
for python_home in "${release_topdir_abs}"/lib/python3.*; do
  if [[ -d "${python_home}" ]]; then
    export PYTHONHOME="${release_topdir_abs}"
    break
  fi
done

exec "${release_topdir_abs}/lib/ld-linux-x86-64.so.2" \
  --inhibit-cache \
  --inhibit-rpath "" \
  --library-path "${release_topdir_abs}/lib" \
  "${release_topdir_abs}/libexec/kepler-formal" "$@"
