#!/bin/bash
# GPUtw 实例本身就是容器。这里直接启动推理，不再套一层 docker run。
set -euo pipefail

if [[ $# -gt 0 ]]; then
  echo "忽略启动引数。上下文和显存切分请用环境变量 CACHE_SIZE、GPU_SPLIT_GB。" >&2
fi

: "${API_TOKEN:?需要环境变量 API_TOKEN}"
: "${TS_AUTHKEY:?需要环境变量 TS_AUTHKEY}"

MODEL_DIR="${MODEL_DIR:-/vault/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw}"
GPU_SPLIT_GB="${GPU_SPLIT_GB:-112}"
CACHE_SIZE="${CACHE_SIZE:-262144}"
SERVE_PORT="${SERVE_PORT:-8899}"
PROXY_PORT="${PROXY_PORT:-8898}"
TS_HOSTNAME="${TS_HOSTNAME:-redsnow}"
TS_STATE="${TS_STATE:-/vault/redsnow/tailscale}"

if [[ ! -f "${MODEL_DIR}/tokenizer_config.json" ]]; then
  echo "模型目录不可用，缺少 tokenizer_config.json: ${MODEL_DIR}" >&2
  exit 1
fi

mkdir -p /var/run/sshd
if [[ -x /usr/sbin/sshd ]]; then
  /usr/sbin/sshd || echo "warn: sshd 未由本脚本启动，若平台已拉起则可忽略" >&2
fi

if echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; then
  (
    for _ in $(seq 1 180); do
      echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || exit 0
      sleep 2
    done
  ) &
else
  echo "warn: 容器内不能丢页缓存。若 262144 上下文加载失败，把 CACHE_SIZE 降到 131072 后重新部署。" >&2
fi

export UPSTREAM="http://127.0.0.1:${SERVE_PORT}"
export PROXY_HOST=127.0.0.1
export PROXY_PORT API_TOKEN
python3 /opt/redsnow/auth_proxy.py &

python3 /opt/redsnow/server/serve_glm.py \
  -m "${MODEL_DIR}" \
  -gs "${GPU_SPLIT_GB}" \
  --cache_size "${CACHE_SIZE}" \
  --cache_quant 4 \
  --mtp \
  --num_draft_tokens 2 \
  --max-model-len "${CACHE_SIZE}" \
  --host 127.0.0.1 \
  --port "${SERVE_PORT}" \
  --served-model-name RED-SNOW-5.3-FLASH-EXL3-2.49 \
  --request-timeout 7200 &
serve_pid=$!

mkdir -p "${TS_STATE}"
chmod 700 "${TS_STATE}"
tailscaled \
  --tun=userspace-networking \
  --statedir="${TS_STATE}" \
  --socket=/tmp/tailscaled.sock &

for _ in $(seq 1 50); do
  [[ -S /tmp/tailscaled.sock ]] && break
  sleep 0.2
done

if ! timeout 60 tailscale --socket=/tmp/tailscaled.sock up \
  --auth-key="${TS_AUTHKEY}" \
  --hostname="${TS_HOSTNAME}" \
  --accept-dns=false
then
  echo "warn: Tailscale 未连上。权重仍会加载，可用 SSH 隧道访问 127.0.0.1:${PROXY_PORT}。" >&2
fi
if ! timeout 60 tailscale --socket=/tmp/tailscaled.sock serve --bg "${PROXY_PORT}"; then
  echo "warn: Tailscale Serve 未就绪。先在 tailnet 打开 HTTPS Certificates，再执行 tailscale serve --bg ${PROXY_PORT}。" >&2
fi
tailscale --socket=/tmp/tailscaled.sock serve status || true

echo "推理只监听 127.0.0.1:${SERVE_PORT}。对外地址是 Tailscale HTTPS，加载权重还要数分钟。" >&2
wait "${serve_pid}"
