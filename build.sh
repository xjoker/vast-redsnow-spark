#!/bin/bash
# Build only the linux/arm64 image for GPUtw DGX Spark. Does not push.
set -euo pipefail
cd "$(dirname "$0")"

os=$(uname -s)
arch=$(uname -m)
if [[ "$os" == "Darwin" && "$arch" == "arm64" ]]; then
  :
elif [[ "$arch" == "aarch64" ]]; then
  :
elif [[ "${ALLOW_EMULATED_BUILD:-}" != "1" ]]; then
  echo "Builds only on arm64. Current host is ${os}/${arch}. Set ALLOW_EMULATED_BUILD=1 explicitly for an emulated build." >&2
  exit 1
fi

version=$(tr -d '[:space:]' < VERSION)
image="${IMAGE:-redsnow-exl3:${version}}"

exec docker buildx build \
  --platform linux/arm64 \
  --build-arg "IMAGE_VERSION=${version}" \
  -t "${image}" \
  "$@" \
  .
