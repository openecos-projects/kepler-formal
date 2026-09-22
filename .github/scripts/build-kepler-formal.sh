#!/usr/bin/env bash

# Copyright 2026 keplertech.io
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

build_dir="${BUILD_DIR:-build}"

cmake_compiler_launcher_args=()
if command -v sccache >/dev/null 2>&1; then
  echo "sccache detected at $(command -v sccache); enabling CMake compiler launcher"
  cmake_compiler_launcher_args=(
    -DCMAKE_C_COMPILER_LAUNCHER=sccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
  )
else
  echo "sccache not found on PATH; building without a compiler cache"
fi

# PYTHON_INTERFACE is honored by the Naja submodule on some revisions; keep it
# off for parity with the other CI builds in this repository.
cmake -S . -B "${build_dir}" -GNinja \
  "${cmake_compiler_launcher_args[@]}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPYTHON_INTERFACE=OFF \
  -DENABLE_UNIT_TESTS=OFF

if [[ ${#cmake_compiler_launcher_args[@]} -gt 0 ]]; then
  if grep -q "sccache" "${build_dir}/CMakeFiles/rules.ninja"; then
    echo "Verified: generated compile rules invoke sccache"
  else
    echo "WARNING: sccache is missing from the generated compile rules" >&2
  fi
fi

cmake --build "${build_dir}" --target kepler-formal -j "${NPROC:-$(nproc)}"
