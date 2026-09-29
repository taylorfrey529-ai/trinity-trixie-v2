#!/usr/bin/env bash
set -euo pipefail
if [[ ! -r /etc/os-release ]]; then echo 'missing /etc/os-release' >&2; exit 2; fi
. /etc/os-release
if [[ "${ID:-}" != ubuntu ]]; then
  echo "This bootstrap targets Ubuntu; current ID=${ID:-unknown}." >&2
  exit 3
fi
case "${VERSION_ID:-}" in
  24.04|24.04.*) ;;
  *) echo "Expected Ubuntu 24.04.x; got ${VERSION_ID:-unknown}." >&2; exit 3 ;;
esac

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build git ccache pkg-config \
  libboost-dev libboost-filesystem-dev libboost-locale-dev \
  libboost-program-options-dev libboost-regex-dev libboost-thread-dev \
  libssl-dev libreadline-dev zlib1g-dev libbz2-dev \
  xauth xvfb openbox unzip zstd python3 ca-certificates

echo "ubuntu_bootstrap=ready version=${VERSION_ID}"
