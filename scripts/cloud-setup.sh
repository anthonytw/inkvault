#!/usr/bin/env bash
# Setup script for a Claude Code cloud environment (Ubuntu 24.04, runs as root).
# Paste into the environment's "Setup script" box. Installs a Swift toolchain so
# `swift build` / `swift test` work natively; if the swift.org download is
# blocked, pre-pulls the Docker image used by scripts/test-linux.sh instead.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q zlib1g-dev age binutils gnupg2 libc6-dev libcurl4-openssl-dev \
  libedit2 libgcc-13-dev libncurses-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
  libz3-dev pkg-config tzdata unzip python3-lldb-18 || true

SWIFT_VER="${SWIFT_VER:-6.4}"
if ! command -v swift >/dev/null; then
  URL="https://download.swift.org/swift-${SWIFT_VER}-release/ubuntu2404/swift-${SWIFT_VER}-RELEASE/swift-${SWIFT_VER}-RELEASE-ubuntu24.04.tar.gz"
  if curl -fsSL "$URL" -o /tmp/swift.tgz; then
    mkdir -p /opt/swift && tar -xzf /tmp/swift.tgz -C /opt/swift --strip-components=1
    echo 'export PATH=/opt/swift/usr/bin:$PATH' > /etc/profile.d/swift.sh
    export PATH=/opt/swift/usr/bin:$PATH
    swift --version
  else
    echo "swift.org download blocked; pre-pulling Docker image for scripts/test-linux.sh"
    docker pull swift:6.4-noble || true
  fi
fi
if command -v swift >/dev/null && [ -f Package.swift ]; then
  swift package resolve || true
fi
