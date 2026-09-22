#!/usr/bin/env bash

# Copyright 2026 keplertech.io
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

sudo apt-get \
  -o Acquire::Retries=3 \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  update

sudo apt-get \
  -o Acquire::Retries=3 \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  -o DPkg::Lock::Timeout=60 \
  install -y --no-install-recommends \
  build-essential \
  cmake \
  ninja-build \
  pkg-config \
  libboost-dev \
  libboost-iostreams-dev \
  libfl-dev \
  capnproto \
  libcapnp-dev \
  libtbb-dev \
  libspdlog-dev \
  libfmt-dev \
  zlib1g-dev \
  python3-dev \
  pax-utils
