#!/bin/bash
# 只构建 GPUtw DGX Spark 用的 linux/arm64 镜像。不推送。
set -euo pipefail
cd "$(dirname "$0")"

os=$(uname -s)
arch=$(uname -m)
if [[ "$os" == "Darwin" && "$arch" == "arm64" ]]; then
  :
elif [[ "$arch" == "aarch64" ]]; then
  :
elif [[ "${ALLOW_EMULATED_BUILD:-}" != "1" ]]; then
  echo "只在 arm64 上构建。当前是 ${os}/${arch}。模拟构建要显式设置 ALLOW_EMULATED_BUILD=1。" >&2
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
