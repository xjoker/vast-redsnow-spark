#!/bin/bash
# 容器内直接启动推理。对外网络只接 EasyTier。推理只听 127.0.0.1。
set -euo pipefail

have_tun() {
  [[ -c /dev/net/tun ]]
}

MODEL_NAME="RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw"

resolve_model_dir() {
  local explicit="$1"
  shift
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  local candidate
  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "${candidate}/tokenizer_config.json" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_ssh_pubkey() {
  local key="$1" file="$2"
  [[ -n "$key" ]] || return 0
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  if ! grep -qxF "$key" "$file"; then
    printf '%s\n' "$key" >>"$file"
  fi
}

valid_ssh_user() {
  local user="$1"
  [[ "$user" =~ ^[a-z][-a-z0-9_]{0,31}$ && "$user" != "root" ]]
}

valid_permit_open() {
  local spec="$1" host port octet
  [[ "$spec" =~ ^(.+):([0-9]{1,5})$ ]] || return 1
  host="${BASH_REMATCH[1]}"
  port="${BASH_REMATCH[2]}"
  ((port >= 1 && port <= 65535)) || return 1
  [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" ]] && return 1
  if [[ "$host" =~ ^\[(.+)\]$ ]]; then
    [[ "${BASH_REMATCH[1]}" =~ ^[0-9A-Fa-f:.]+$ ]]
    return
  fi
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    local -a octets=()
    read -ra octets <<< "$host"
    for octet in "${octets[@]}"; do
      ((10#$octet <= 255)) || return 1
    done
    return 0
  fi
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

tunnel_targets() {
  local raw="$1" proxy="${2:-8898}" item trimmed count=0
  if [[ -z "$raw" ]]; then
    printf '127.0.0.1:%s\n' "$proxy"
    return 0
  fi
  local IFS=,
  local -a items=()
  read -ra items <<< "$raw"
  for item in "${items[@]}"; do
    trimmed="${item#"${item%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || continue
    count=$((count + 1))
    if ((count > 16)); then
      echo "SSH_TUNNELS 超过 16 个目标" >&2
      return 1
    fi
    printf '%s\n' "$trimmed"
  done
  ((count > 0))
}

render_tunnel_match() {
  local user="$1" password_on="$2"
  shift 2
  printf '# redsnow-tunnel-begin\n'
  printf 'Match User %s\n' "$user"
  if [[ "$password_on" == 1 ]]; then
    printf '    PasswordAuthentication yes\n'
  else
    printf '    PasswordAuthentication no\n'
  fi
  printf '    KbdInteractiveAuthentication no\n'
  printf '    AllowTcpForwarding local\n'
  printf '    X11Forwarding no\n'
  printf '    AllowAgentForwarding no\n'
  printf '    PermitTunnel no\n'
  printf '    PermitListen none\n'
  local dest
  for dest in "$@"; do
    printf '    PermitOpen %s\n' "$dest"
  done
  printf '# redsnow-tunnel-end\n'
}

# 未配置返回 1。用户名、密码或转发目标无效返回 2。配置文本里没有密码。
tunnel_sshd_block() {
  local password="${SSH_PASSWORD:-}" pubkey="${SSH_USER_PUBLIC_KEY:-}"
  if [[ -z "$password" && -z "$pubkey" ]]; then
    if [[ -n "${SSH_USER:-}" || -n "${SSH_TUNNELS:-}" ]]; then
      echo "warn: 要建隧道用户，还要填 SSH_PASSWORD 或 SSH_USER_PUBLIC_KEY。" >&2
    fi
    return 1
  fi
  local user="${SSH_USER:-tunnel}"
  if ! valid_ssh_user "$user"; then
    echo "SSH_USER 无效: ${user}。小写字母开头，不能是 root。" >&2
    return 2
  fi
  if [[ "$password" == *$'\n'* || "$password" == *$'\r'* ]]; then
    echo "SSH_PASSWORD 不能包含换行" >&2
    return 2
  fi
  if [[ -n "$password" && ${#password} -lt 12 ]]; then
    echo "warn: SSH_PASSWORD 短于 12 字符。22 端口在租用平台上常常是公网。" >&2
  fi
  local targets_text="" targets_rc=0 line
  targets_text="$(tunnel_targets "${SSH_TUNNELS:-}" "${PROXY_PORT:-8898}")" || targets_rc=$?
  if [[ "$targets_rc" -ne 0 || -z "$targets_text" ]]; then
    if [[ -z "$targets_text" ]]; then
      echo "SSH_TUNNELS 是空的" >&2
    fi
    return 2
  fi
  local -a targets=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! valid_permit_open "$line"; then
      echo "SSH_TUNNELS 目标无效: ${line}" >&2
      return 2
    fi
    targets+=("$line")
  done <<< "$targets_text"
  local password_on=0
  [[ -n "$password" ]] && password_on=1
  render_tunnel_match "$user" "$password_on" "${targets[@]}"
}

upsert_sshd_tunnel() {
  local file="$1" block="$2" tmp dir
  dir="$(dirname "$file")"
  tmp="$(mktemp "$dir/sshd.XXXXXX")"
  if [[ -f "$file" ]]; then
    awk '
      /^# redsnow-tunnel-begin$/ { skip = 1; next }
      /^# redsnow-tunnel-end$/ { skip = 0; next }
      skip { next }
      { print }
    ' "$file" >"$tmp"
  fi
  if [[ -n "$block" ]]; then
    printf '\n%s\n' "$block" >>"$tmp"
  fi
  mv "$tmp" "$file"
  chmod 644 "$file"
}

ensure_tunnel_user() {
  local user="$1" password="$2" pubkey="$3" home random
  if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --user-group "$user"
  fi
  home="$(getent passwd "$user" | awk -F: 'NR==1 { print $6 }')"
  [[ -n "$home" && -d "$home" ]] || return 1
  if [[ -n "$password" ]]; then
    printf '%s:%s\n' "$user" "$password" | chpasswd
  else
    random="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    printf '%s:%s\n' "$user" "$random" | chpasswd
  fi
  if [[ -n "$pubkey" ]]; then
    install_ssh_pubkey "$pubkey" "${home}/.ssh/authorized_keys"
    chown -R "$user:$user" "${home}/.ssh"
  fi
  install_sudoers "$user" /etc/sudoers.d/redsnow-tunnel
}

install_sudoers() {
  local user="$1" path="$2" old
  valid_ssh_user "$user" || return 1
  mkdir -p "$(dirname "$path")"
  old="$(umask)"
  umask 022
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"$path"
  chmod 440 "$path"
  umask "$old"
}

activate_tunnel_user() {
  local block rc=0
  block="$(tunnel_sshd_block)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ -f /etc/ssh/sshd_config ]]; then
      upsert_sshd_tunnel /etc/ssh/sshd_config ""
    fi
    if [[ "$rc" -eq 2 ]]; then
      echo "warn: 隧道用户这次不启用。推理继续。" >&2
    fi
    return 0
  fi
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    echo "warn: 没有 /etc/ssh/sshd_config，隧道用户不启用。" >&2
    return 0
  fi
  upsert_sshd_tunnel /etc/ssh/sshd_config "$block"
  if [[ -x /usr/sbin/sshd ]] && ! /usr/sbin/sshd -t; then
    echo "warn: sshd 拒绝隧道配置，已撤回。" >&2
    upsert_sshd_tunnel /etc/ssh/sshd_config ""
    return 0
  fi
  local user="${SSH_USER:-tunnel}"
  if ! ensure_tunnel_user "$user" "${SSH_PASSWORD:-}" "${SSH_USER_PUBLIC_KEY:-}"; then
    echo "warn: 建隧道用户失败。推理继续。" >&2
    upsert_sshd_tunnel /etc/ssh/sshd_config ""
    return 0
  fi
  local first
  first="$(tunnel_targets "${SSH_TUNNELS:-}" "${PROXY_PORT:-8898}")"
  first="${first%%$'\n'*}"
  echo "隧道用户 ${user} 已就绪，sudo 免密码。ssh ${user}@<主机> 之后 sudo -i。转发：ssh -N -L <本地端口>:${first} ${user}@<主机>" >&2
}

start_sshd_daemon() {
  mkdir -p /var/run/sshd
  # 主机密钥按容器生成。打进镜像的话，所有拉取同一 tag 的机器会共用一把私钥。
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A || echo "warn: 没能生成 SSH 主机密钥。" >&2
  fi
  if [[ ! -x /usr/sbin/sshd ]]; then
    echo "warn: 镜像里没有 sshd。" >&2
    return 0
  fi
  if ! /usr/sbin/sshd -t; then
    echo "warn: sshd 配置无效。" >&2
    return 0
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1; then
    pkill -HUP -x sshd || true
    echo "sshd 已在运行，已重新加载。现在可以连 22。" >&2
    return 0
  fi
  (
    fails=0
    status=0
    while true; do
      start="$(date +%s)"
      status=0
      /usr/sbin/sshd -D -e || status=$?
      now="$(date +%s)"
      if ((now - start < 2)); then
        fails=$((fails + 1))
      else
        fails=0
      fi
      if ((fails >= 3)); then
        echo "warn: sshd 连续启动失败。若 22 已被占用，沿用已有的 sshd。" >&2
        exit 0
      fi
      echo "warn: sshd 退出，状态 ${status:-0}，1 秒后重启" >&2
      sleep 1
    done
  ) &
  echo "sshd 已在后台监听 22。模型还在加载时就可以走隧道。" >&2
}

publish_runtime_env() {
  local path="$1"
  shift
  umask 077
  touch "$path"
  chmod 600 "$path"
  local key line
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || continue
    line="${key}=${!key}"
    if ! grep -qxF "$line" "$path"; then
      printf '%s\n' "$line" >>"$path"
    fi
  done
}

choose_gpu_split() {
  local explicit="$1" free_gib="$2"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [[ ! "$free_gib" =~ ^[0-9]+$ ]]; then
    echo "无法读取显存空闲 GiB: ${free_gib}" >&2
    return 1
  fi
  local gs=$((free_gib - 2))
  if ((gs > 112)); then gs=112; fi
  if ((gs < 1)); then
    echo "显存空闲 ${free_gib} GiB，切分后没有可用空间" >&2
    return 1
  fi
  printf '%s\n' "$gs"
}

split_warning() {
  local gs="$1" cache="$2"
  if ((cache >= 262144 && gs < 108)); then
    printf '切分 %s GiB 低于 256K 加载成功时的 110。空闲显存不够时这次上下文会加载失败。\n' "$gs"
  fi
}

read_free_gib() {
  python3 -c 'import torch; print(int(torch.cuda.mem_get_info()[0] // 2**30))'
}

prepare_easytier() {
  local name="${ET_NETWORK_NAME:-}" secret="${ET_NETWORK_SECRET:-}"
  if [[ -z "$name" && -z "$secret" ]]; then
    return 1
  fi
  if [[ -z "$name" || -z "$secret" ]]; then
    echo "warn: EasyTier 需要同时填写 ET_NETWORK_NAME 和 ET_NETWORK_SECRET，这次不启动。" >&2
    return 1
  fi
  if [[ -n "${ET_ENABLE_EXIT_NODE:-}" || -n "${ET_EXIT_NODES:-}" ]]; then
    echo "warn: 已忽略出口节点。这个容器不做流量出口。" >&2
    unset ET_ENABLE_EXIT_NODE ET_EXIT_NODES
  fi
  export ET_HOSTNAME="${ET_HOSTNAME:-redsnow}"
  export ET_DEV_NAME="${ET_DEV_NAME:-ets0}"
  if ! have_tun; then
    echo "warn: 没有 /dev/net/tun，EasyTier 不建虚拟网卡。节点仍会连 peer，API 只在 127.0.0.1。" >&2
    export ET_NO_TUN=true
    return 0
  fi
  if [[ -z "${ET_IPV4:-}" && -z "${ET_DHCP:-}" ]]; then
    export ET_DHCP=true
  fi
  return 0
}

easytier_ipv4() {
  ip -4 -o addr show dev "${ET_DEV_NAME:-ets0}" 2>/dev/null \
    | awk 'NR==1 { split($4, a, "/"); print a[1]; exit }'
}

start_auth_proxy() {
  local host="$1"
  # nohup：虚拟网地址可能在后台循环里才拿到，循环退出不能把代理一起收掉。
  PROXY_HOST="$host" nohup python3 /opt/redsnow/auth_proxy.py >/proc/1/fd/2 2>&1 &
}

watch_easytier_proxy() {
  local ip=""
  local _
  for _ in $(seq 1 30); do
    ip="$(easytier_ipv4 || true)"
    if [[ -n "$ip" ]]; then
      start_auth_proxy "$ip"
      echo "EasyTier API http://${ip}:${PROXY_PORT}" >&2
      return 0
    fi
    sleep 1
  done
  echo "warn: 30 秒内没有 EasyTier 地址。节点已启动，API 仍在 127.0.0.1:${PROXY_PORT}。" >&2
}

main() {
  if [[ $# -gt 0 ]]; then
    echo "忽略启动引数。上下文和显存切分请用环境变量 CACHE_SIZE、GPU_SPLIT_GB。" >&2
  fi

  : "${API_TOKEN:?需要环境变量 API_TOKEN}"

  CACHE_SIZE="${CACHE_SIZE:-262144}"
  NUM_DRAFT_TOKENS="${NUM_DRAFT_TOKENS:-2}"
  SERVE_PORT="${SERVE_PORT:-8899}"
  PROXY_PORT="${PROXY_PORT:-8898}"
  PROXY_TIMEOUT="${PROXY_TIMEOUT:-7200}"
  export TRITON_PTXAS_PATH="${TRITON_PTXAS_PATH:-/usr/local/cuda/bin/ptxas}"

  # 22 先起来。EasyTier 在后台连，不挡住权重加载。
  install_ssh_pubkey "${SSH_PUBLIC_KEY:-}" /root/.ssh/authorized_keys
  activate_tunnel_user
  start_sshd_daemon

  local data_models=""
  if [[ -n "${DATA_DIRECTORY:-}" ]]; then
    data_models="${DATA_DIRECTORY}/models/${MODEL_NAME}"
  fi
  if ! MODEL_DIR="$(resolve_model_dir "${MODEL_DIR:-}" \
    "$data_models" \
    "/vault/models/${MODEL_NAME}" \
    "/workspace/models/${MODEL_NAME}")"; then
    echo "找不到模型。填写 MODEL_DIR，或把权重放在 /vault/models/${MODEL_NAME} 或 /workspace/models/${MODEL_NAME}。" >&2
    exit 1
  fi
  export MODEL_DIR
  if [[ ! -f "${MODEL_DIR}/tokenizer_config.json" ]]; then
    echo "模型目录不可用，缺少 tokenizer_config.json: ${MODEL_DIR}" >&2
    exit 1
  fi
  if [[ ! -x "$TRITON_PTXAS_PATH" ]]; then
    echo "找不到 ptxas: ${TRITON_PTXAS_PATH}" >&2
    exit 1
  fi

  publish_runtime_env /etc/environment \
    API_TOKEN MODEL_DIR CACHE_SIZE NUM_DRAFT_TOKENS PROXY_PORT SERVE_PORT PROXY_TIMEOUT
  export UPSTREAM="http://127.0.0.1:${SERVE_PORT}"
  export PROXY_PORT API_TOKEN
  start_auth_proxy 127.0.0.1

  if prepare_easytier; then
    echo "EasyTier peer 启动。默认监听 tcp/udp 11010。未设置 ET_PEERS 时只等别人来连。" >&2
    nohup easytier-core >/proc/1/fd/2 2>&1 &
    if have_tun; then
      watch_easytier_proxy &
    fi
  fi

  local free_gib gs warning
  free_gib="$(read_free_gib)"
  gs="$(choose_gpu_split "${GPU_SPLIT_GB:-}" "$free_gib")"
  warning="$(split_warning "$gs" "$CACHE_SIZE")"
  if [[ -n "$warning" ]]; then
    echo "warn: ${warning}" >&2
  fi
  echo "GPU_SPLIT_GB=${gs} CACHE_SIZE=${CACHE_SIZE} 空闲显存约 ${free_gib} GiB" >&2
  if echo 3 >/proc/sys/vm/drop_caches 2>/dev/null; then
    :
  else
    echo "warn: 容器内不能丢页缓存。切分按上面的空闲显存取值，不要把上下文降到 131072 当作唯一办法。" >&2
  fi
  GPU_SPLIT_GB="$gs"
  publish_runtime_env /etc/environment GPU_SPLIT_GB

  python3 /opt/redsnow/server/serve_glm.py \
    -m "${MODEL_DIR}" \
    -gs "${gs}" \
    --cache_size "${CACHE_SIZE}" \
    --cache_quant 4 \
    --mtp \
    --num_draft_tokens "${NUM_DRAFT_TOKENS}" \
    --max-model-len "${CACHE_SIZE}" \
    --host 127.0.0.1 \
    --port "${SERVE_PORT}" \
    --served-model-name RED-SNOW-5.3-FLASH-EXL3-2.49 \
    --request-timeout 7200 &
  local serve_pid=$!
  echo "推理只监听 127.0.0.1:${SERVE_PORT}。对外走认证代理 ${PROXY_PORT}。权重在盘上时，加载大约还要一分钟。" >&2
  wait "${serve_pid}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
