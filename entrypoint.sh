#!/bin/bash
# 容器内直接启动推理。推理只听 127.0.0.1。认证代理听 0.0.0.0，必须带 API_TOKEN。
# EasyTier 留空则用服务器 IP 和认证端口。
set -euo pipefail

log() {
  printf '%s [redsnow] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

DOWNLOAD_MODEL_PY="${DOWNLOAD_MODEL_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/download_model.py}"
MODEL_REPO_DEFAULT="vcruz305/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw"
MODEL_REVISION_DEFAULT="071adefe6c1c8de379d76977985811b7d4385454"

have_tun() {
  [[ -c /dev/net/tun ]]
}

MODEL_NAME="RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw"
# 唯一模型目录。挂盘时把存储挂到 /models，文件就落在这一层。
MODEL_LOCK="/models/${MODEL_NAME}"

locked_model_dir() {
  if [[ -n "${MODEL_DIR:-}" ]]; then
    printf '%s\n' "$MODEL_DIR"
    return 0
  fi
  printf '%s\n' "$MODEL_LOCK"
}

model_is_complete() {
  python3 "$DOWNLOAD_MODEL_PY" --check "$1" >/dev/null
}

# 默认目录必须是挂载点，避免把约 97GiB 写进容器层。MODEL_DIR 由调用方指定位置。
weights_mount_ok() {
  local dest="$1"
  [[ "$dest" == "$MODEL_LOCK" ]] || return 0
  [[ -f /proc/mounts ]] || return 1
  awk -v p="/models" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
}

# 0：目录可加载。2：不下载，调用方保持 sshd 和认证代理。1：配置或下载失败。
ensure_model_dir() {
  local dest
  case "${MODEL_DOWNLOAD:-1}" in
    0 | 1) ;;
    *)
      log "MODEL_DOWNLOAD 只能是 0 或 1，当前是 ${MODEL_DOWNLOAD}"
      return 1
      ;;
  esac
  dest="$(locked_model_dir)"
  if model_is_complete "$dest"; then
    log "使用已有模型 ${dest}"
    printf '%s\n' "$dest"
    return 0
  fi
  if [[ "${MODEL_DOWNLOAD:-1}" == "0" ]]; then
    log "MODEL_DOWNLOAD=0，目录没有完整模型，不下载: ${dest}"
    return 2
  fi
  if ! weights_mount_ok "$dest"; then
    log "模型目录 ${dest} 没有挂载存储，不下载。把盘挂到 /models，或设置 MODEL_DIR。本次跳过推理。"
    return 2
  fi
  log "目录没有完整模型，开始下载 repo=${MODEL_REPO} revision=${MODEL_REVISION} 目录=${dest} 线程=${MODEL_DOWNLOAD_WORKERS}"
  python3 "$DOWNLOAD_MODEL_PY" \
    --repo "$MODEL_REPO" \
    --revision "$MODEL_REVISION" \
    --dest "$dest" \
    --workers "$MODEL_DOWNLOAD_WORKERS" >&2
  if ! model_is_complete "$dest"; then
    log "下载结束但模型仍不完整: ${dest}"
    return 1
  fi
  log "模型下载完成 ${dest}"
  printf '%s\n' "$dest"
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

# 平台重建容器时把公钥写成宿主 uid 属主，sshd StrictModes 会拒绝 root 公钥登录，所以启动时改回来。
fix_root_ssh_perms() {
  local dir="${1:-/root/.ssh}" path owner
  [[ -d "$dir" ]] || return 0
  for path in "$dir" "$dir/authorized_keys" "$dir/authorized_keys2"; do
    [[ -e "$path" ]] || continue
    if [[ "$EUID" -eq 0 ]]; then
      owner="$(stat -c '%u:%g' "$path")"
      if [[ "$owner" != "0:0" ]]; then
        chown root:root "$path"
        log "${path} 属主是 ${owner}，已改回 root。平台注入公钥时用了宿主 uid，sshd StrictModes 会拒绝。"
      fi
    fi
  done
  chmod 700 "$dir"
  for path in "$dir/authorized_keys" "$dir/authorized_keys2"; do
    [[ -e "$path" ]] || continue
    chmod 600 "$path"
  done
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
      log "SSH_TUNNELS 超过 16 个目标"
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
      log "warn: 要建隧道用户，还要填 SSH_PASSWORD 或 SSH_USER_PUBLIC_KEY。"
    fi
    return 1
  fi
  local user="${SSH_USER:-tunnel}"
  if ! valid_ssh_user "$user"; then
    log "SSH_USER 无效: ${user}。小写字母开头，不能是 root。"
    return 2
  fi
  if [[ "$password" == *$'\n'* || "$password" == *$'\r'* ]]; then
    log "SSH_PASSWORD 不能包含换行"
    return 2
  fi
  if [[ -n "$password" && ${#password} -lt 12 ]]; then
    log "warn: SSH_PASSWORD 短于 12 字符。22 端口在租用平台上常常是公网。"
  fi
  local targets_text="" targets_rc=0 line
  targets_text="$(tunnel_targets "${SSH_TUNNELS:-}" "${PROXY_PORT:-8898}")" || targets_rc=$?
  if [[ "$targets_rc" -ne 0 || -z "$targets_text" ]]; then
    if [[ -z "$targets_text" ]]; then
      log "SSH_TUNNELS 是空的"
    fi
    return 2
  fi
  local -a targets=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! valid_permit_open "$line"; then
      log "SSH_TUNNELS 目标无效: ${line}"
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
      log "warn: 隧道用户这次不启用。推理继续。"
    fi
    return 0
  fi
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    log "warn: 没有 /etc/ssh/sshd_config，隧道用户不启用。"
    return 0
  fi
  upsert_sshd_tunnel /etc/ssh/sshd_config "$block"
  if [[ -x /usr/sbin/sshd ]] && ! /usr/sbin/sshd -t; then
    log "warn: sshd 拒绝隧道配置，已撤回。"
    upsert_sshd_tunnel /etc/ssh/sshd_config ""
    return 0
  fi
  local user="${SSH_USER:-tunnel}"
  if ! ensure_tunnel_user "$user" "${SSH_PASSWORD:-}" "${SSH_USER_PUBLIC_KEY:-}"; then
    log "warn: 建隧道用户失败。推理继续。"
    upsert_sshd_tunnel /etc/ssh/sshd_config ""
    return 0
  fi
  local first
  first="$(tunnel_targets "${SSH_TUNNELS:-}" "${PROXY_PORT:-8898}")"
  first="${first%%$'\n'*}"
  log "隧道用户 ${user} 已就绪，sudo 免密码。ssh ${user}@<主机> 之后 sudo -i。转发：ssh -N -L <本地端口>:${first} ${user}@<主机>"
}

# Vast 在启动时注入公网地址和随机外部端口。没有这些变量时不记。
log_vast_access() {
  local ip="${PUBLIC_IPADDR:-}" ssh_ext="${VAST_TCP_PORT_22:-}"
  local api_name="VAST_TCP_PORT_${PROXY_PORT:-8898}" api_ext=""
  if [[ -v "$api_name" ]]; then
    api_ext="${!api_name}"
  fi
  [[ -n "$ip" ]] || return 0
  if [[ -n "$ssh_ext" ]]; then
    log "Vast SSH：ssh -p ${ssh_ext} root@${ip} 。root 只用账号公钥。密码登录是镜像内的用户，不是 root。"
  fi
  if [[ -n "$api_ext" ]]; then
    log "Vast API：http://${ip}:${api_ext} 对应容器端口 ${PROXY_PORT:-8898}。请求头 Authorization: Bearer，值是 API_TOKEN。这条映射是 HTTP。"
  fi
}

start_sshd_daemon() {
  mkdir -p /var/run/sshd
  # 主机密钥按容器生成。打进镜像的话，所有拉取同一 tag 的机器会共用一把私钥。
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A || log "warn: 没能生成 SSH 主机密钥。"
  fi
  if [[ ! -x /usr/sbin/sshd ]]; then
    log "warn: 镜像里没有 sshd。"
    return 0
  fi
  if ! /usr/sbin/sshd -t; then
    log "warn: sshd 配置无效。"
    return 0
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1; then
    # 只给最早的监听进程发 HUP。会话进程也叫 sshd，一起 HUP 会断掉已连上的 SSH。
    pkill -HUP -o -x sshd || true
    log "sshd 已在运行，已重新加载。现在可以连 22。"
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
        log "warn: sshd 连续启动失败。若 22 已被占用，沿用已有的 sshd。"
        exit 0
      fi
      log "warn: sshd 退出，状态 ${status:-0}，1 秒后重启"
      sleep 1
    done
  ) &
  log "sshd 已在后台监听 22。模型还在加载时就可以连。"
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

read_free_gib() {
  python3 -c 'import torch; print(int(torch.cuda.mem_get_info()[0] // 2**30))'
}

choose_gpu_split() {
  local explicit="$1" free_gib="$2"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [[ ! "$free_gib" =~ ^[0-9]+$ ]]; then
    log "无法读取显存空闲 GiB: ${free_gib}"
    return 1
  fi
  # Weschera serve.sh 固定 -gs 112。空闲不够时由调用方警告，不改这个切分。
  printf '112\n'
}

split_warning() {
  local gs="$1" cache="$2"
  if ((cache >= 262144 && gs < 108)); then
    printf '切分 %s GiB 低于 256K 加载成功时的 110。空闲显存不够时这次上下文会加载失败。\n' "$gs"
  fi
}

# 结果写 VISION_ARGS。MAX_IMAGE_TOKENS 留空时不传，由上游处理器决定默认值。
vision_serve_args() {
  VISION_ARGS=()
  if [[ "$VISION" == 1 ]]; then
    VISION_ARGS+=(--vision)
  fi
  if [[ -n "$MAX_IMAGE_TOKENS" ]]; then
    VISION_ARGS+=(--max-image-tokens "$MAX_IMAGE_TOKENS")
  fi
}

# 上游 serve.sh：加载前丢一次，加载过程中每 2 秒再丢，直到出现 Native API listening。
# 必须在当前 shell 调用，结果写 DROPPER_PID。不能放进 $()，否则后台循环会随子 shell 退出。
start_load_cache_dropper() {
  DROPPER_PID=""
  if ! echo 3 >/proc/sys/vm/drop_caches 2>/dev/null; then
    log "warn: 容器内不能丢页缓存。上游 serve.sh 在加载前和加载中都会丢。切分仍用 112，不要把上下文降到 131072 当作唯一办法。"
    return 0
  fi
  log "按上游 serve.sh，加载期间每 2 秒丢一次页缓存。"
  (
    local _
    for _ in $(seq 1 300); do
      echo 1 >/proc/sys/vm/drop_caches 2>/dev/null || exit 0
      sleep 2
    done
  ) &
  DROPPER_PID=$!
}

stop_load_cache_dropper() {
  local dropper="$1" serve_pid="$2" serve_log="$3" _
  [[ -n "$dropper" ]] || return 0
  for _ in $(seq 1 180); do
    if grep -q "Native API listening" "$serve_log" 2>/dev/null; then
      break
    fi
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      break
    fi
    sleep 2
  done
  kill "$dropper" 2>/dev/null || true
}

prepare_easytier() {
  local name="${ET_NETWORK_NAME:-}" secret="${ET_NETWORK_SECRET:-}"
  if [[ -z "$name" && -z "$secret" ]]; then
    return 1
  fi
  if [[ -z "$name" || -z "$secret" ]]; then
    log "warn: EasyTier 需要同时填写 ET_NETWORK_NAME 和 ET_NETWORK_SECRET，这次不启动。"
    return 1
  fi
  if [[ -n "${ET_ENABLE_EXIT_NODE:-}" || -n "${ET_EXIT_NODES:-}" ]]; then
    log "warn: 已忽略出口节点。这个容器不做流量出口。"
    unset ET_ENABLE_EXIT_NODE ET_EXIT_NODES
  fi
  export ET_HOSTNAME="${ET_HOSTNAME:-redsnow}"
  export ET_DEV_NAME="${ET_DEV_NAME:-ets0}"
  if ! have_tun; then
    log "warn: 没有 /dev/net/tun，EasyTier 不建虚拟网卡。节点仍会连 peer。认证代理仍在 0.0.0.0:${PROXY_PORT:-8898}。"
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
  PROXY_HOST="$host" nohup python3 /opt/redsnow/auth_proxy.py >/proc/1/fd/2 2>&1 &
  log "认证代理 pid=$! 监听 ${host}:${PROXY_PORT} 上游 ${UPSTREAM}"
}

# 只指向认证代理 PROXY_PORT，绝不指向推理端口。匿名地址写到 TUNNEL_URL_FILE，方便 cat，不用翻日志。
start_cloudflared() {
  [[ "$CF_TUNNEL" == 1 ]] || return 0
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "warn: 镜像里没有 cloudflared，公网隧道不启动。"
    return 0
  fi
  local url_file="${TUNNEL_URL_FILE:-/run/redsnow/tunnel_url}"
  mkdir -p "$(dirname "$url_file")"
  rm -f "$url_file"
  # token 只进子进程环境变量，不放命令行参数，不写日志。
  if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    log "Cloudflare 具名隧道启动。公网主机名在 Cloudflare 控制台配置，服务地址要填 http://localhost:${PROXY_PORT}。"
    (
      status=0
      TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" cloudflared tunnel --no-autoupdate run 2>&1 \
        | while IFS= read -r line; do printf '%s\n' "$line" >&2; done || status=$?
      log "warn: cloudflared 退出 status=${status}"
    ) &
    return 0
  fi
  log "Cloudflare 匿名隧道启动，正在申请公网地址。"
  (
    status=0
    url=""
    cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${PROXY_PORT}" 2>&1 \
      | while IFS= read -r line; do
          printf '%s\n' "$line" >&2
          if [[ -z "$url" && "$line" =~ https://[A-Za-z0-9-]+\.trycloudflare\.com ]]; then
            url="${BASH_REMATCH[0]}"
            printf '%s\n' "$url" >"$url_file"
            log_banner "Cloudflare 公网地址" \
              "公网  ${url}" \
              "鉴权  请求头 Authorization: Bearer，值是 API_TOKEN" \
              "只用串流请求，非串流超过 100 秒会被 Cloudflare 返回 524"
          fi
        done || status=$?
    log "warn: cloudflared 退出 status=${status}"
  ) &
}

watch_easytier_proxy() {
  local ip=""
  local _
  for _ in $(seq 1 30); do
    ip="$(easytier_ipv4 || true)"
    if [[ -n "$ip" ]]; then
      log "EasyTier 地址 ${ip}。端口 ${PROXY_PORT} 已在 0.0.0.0 监听，这个地址和服务器 IP 都要带 Bearer token。"
      return 0
    fi
    sleep 1
  done
  log "warn: 30 秒内没有 EasyTier 地址。认证代理仍在 0.0.0.0:${PROXY_PORT}。"
}

# 标题用等号框起来，方便在长日志里找到公网地址和就绪信息。
log_banner() {
  local title="$1" row
  shift
  log "==== ${title} ===="
  for row in "$@"; do
    log "  ${row}"
  done
  log "========================================"
}

# 没有的项不输出。鉴权行固定带字面量 <API_TOKEN>，真实 token 不进日志。
access_lines() {
  local url_file="${TUNNEL_URL_FILE:-/run/redsnow/tunnel_url}" url=""
  local ip="${PUBLIC_IPADDR:-}" ssh_ext="${VAST_TCP_PORT_22:-}"
  local api_name="VAST_TCP_PORT_${PROXY_PORT:-8898}" api_ext=""
  if [[ -s "$url_file" ]]; then
    url="$(head -n 1 "$url_file")"
  fi
  if [[ -n "$url" ]]; then
    echo "公网  ${url}"
  elif [[ "${CF_TUNNEL:-}" == 1 && -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    echo "公网  Cloudflare 具名隧道，主机名见 Cloudflare 控制台"
  fi
  if [[ -v "$api_name" ]]; then
    api_ext="${!api_name}"
  fi
  if [[ -n "$ip" && -n "$api_ext" ]]; then
    echo "Vast API  http://${ip}:${api_ext}"
  fi
  if [[ -n "$ip" && -n "$ssh_ext" ]]; then
    echo "Vast SSH  ssh -p ${ssh_ext} root@${ip}（root 只认账号公钥，密码登录用隧道用户）"
  fi
  echo "鉴权  请求头 Authorization: Bearer <API_TOKEN>"
}

json_num() {
  local re="\"$1\":([-+0-9.eE]+)"
  [[ "$2" =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# 上游每个请求结束打印一行 usage JSON。字段缺任何一个返回 1，调用方原样输出那行。
usage_summary() {
  local line="$1" reason pt ct dts da tp te
  local re_reason='"finish_reason":"([^"]*)"'
  [[ "$line" =~ $re_reason ]] || return 1
  reason="${BASH_REMATCH[1]}"
  pt="$(json_num prompt_tokens "$line")" || return 1
  ct="$(json_num completion_tokens "$line")" || return 1
  dts="$(json_num decode_tok_s "$line")" || return 1
  da="$(json_num draft_accept "$line")" || return 1
  tp="$(json_num time_prefill "$line")" || return 1
  te="$(json_num time_enqueued "$line")" || return 1
  awk -v reason="$reason" -v pt="$pt" -v ct="$ct" -v dts="$dts" \
    -v da="$da" -v tp="$tp" -v te="$te" '
  BEGIN {
    rate = ""
    if (tp + 0 > 0) rate = sprintf("（%d tok/s）", pt / tp + 0.5)
    printf "请求完成 %s｜输入 %d tok 预填 %.2f s%s｜输出 %d tok 解码 %.1f tok/s｜MTP 接受 %.0f%%｜排队 %.2f s",
      reason, pt, tp, rate, ct, dts, da * 100, te
  }'
}

# 推理的 stdout/stderr 经 tail 进入这里：usage 行压成一行，加载期的 Mixed-K 噪音只留层进度，Native API 就绪时打印访问信息。
format_serve_output() {
  local line summary start_at=$SECONDS
  local re_layer='^ -- Mixed-K experts in model\.language_model\.layers\.([0-9]+)\.'
  local -a rows=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *'"usage":{'* ]] && summary="$(usage_summary "$line")"; then
      log "$summary"
      continue
    fi
    case "$line" in
      *'"GET /health HTTP/'*|*'"GET /v1/health HTTP/'*)
        ;;
      " -- Mixed-K "*)
        if [[ "$line" =~ $re_layer ]] && ((10#${BASH_REMATCH[1]} % 10 == 0)); then
          log "加载权重 第 ${BASH_REMATCH[1]} 层"
        fi
        ;;
      *"Native API listening"*)
        printf '%s\n' "$line" >&2
        rows=()
        while IFS= read -r row; do
          rows+=("$row")
        done < <(access_lines)
        log_banner "模型就绪" "加载用时 $((SECONDS - start_at)) 秒" "上下文 ${CACHE_SIZE:-未设置}" "${rows[@]}"
        ;;
      *)
        printf '%s\n' "$line" >&2
        ;;
    esac
  done
}

# 一行运行指标。nvidia-smi 缺失或失败时省略 GPU 段；上游 /health 不通写推理未就绪。
metrics_line() {
  local url_file="${TUNNEL_URL_FILE:-/run/redsnow/tunnel_url}" meminfo="${MEMINFO:-/proc/meminfo}"
  local gpu="" mem="" health="" public="" body="" url="" out="" seg
  local re_requests='"requests":[[:space:]]*([0-9]+)'
  gpu="$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,clocks.sm --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' 'NR == 1 && NF == 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9.]+$/ && $4 ~ /^[0-9]+$/ {
        printf "GPU %s%% %s°C %.0f W SM %s MHz", $1, $2, $3, $4 }')" || true
  if [[ -r "$meminfo" ]]; then
    mem="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
      END { if (t > 0 && a > 0) printf "内存可用 %.1f/%.1f GiB", a / 1048576, t / 1048576 }' "$meminfo")"
  fi
  body="$(curl -fsS --max-time 2 "http://127.0.0.1:${SERVE_PORT:-8899}/health" 2>/dev/null)" || body=""
  if [[ -z "$body" ]]; then
    health="推理未就绪"
  elif [[ "$body" =~ $re_requests ]]; then
    health="进行中请求 ${BASH_REMATCH[1]}"
  fi
  if [[ -s "$url_file" ]]; then
    url="$(head -n 1 "$url_file")"
    public="公网 ${url}"
  fi
  for seg in "$gpu" "$mem" "$health" "$public"; do
    [[ -n "$seg" ]] || continue
    out="${out:+${out}｜}${seg}"
  done
  printf '指标 %s\n' "$out"
}

start_metrics_loop() {
  METRICS_PID=""
  if ((${METRICS_INTERVAL:-60} == 0)); then
    return 0
  fi
  (
    while true; do
      sleep "$METRICS_INTERVAL"
      log "$(metrics_line)"
    done
  ) &
  METRICS_PID=$!
}

main() {
  if [[ $# -gt 0 ]]; then
    log "忽略启动引数。上下文和显存切分请用环境变量 CACHE_SIZE、GPU_SPLIT_GB。"
  fi

  : "${API_TOKEN:?需要环境变量 API_TOKEN}"
  log "启动 version=${IMAGE_VERSION:-unknown}。API_TOKEN 已设置。"

  CACHE_SIZE="${CACHE_SIZE:-262144}"
  NUM_DRAFT_TOKENS="${NUM_DRAFT_TOKENS:-2}"
  SERVE_PORT="${SERVE_PORT:-8899}"
  PROXY_PORT="${PROXY_PORT:-8898}"
  PROXY_TIMEOUT="${PROXY_TIMEOUT:-7200}"
  VISION="${VISION:-1}"
  MAX_IMAGE_TOKENS="${MAX_IMAGE_TOKENS:-}"
  CF_TUNNEL="${CF_TUNNEL:-1}"
  METRICS_INTERVAL="${METRICS_INTERVAL:-60}"
  MODEL_REPO="${MODEL_REPO:-$MODEL_REPO_DEFAULT}"
  MODEL_REVISION="${MODEL_REVISION:-$MODEL_REVISION_DEFAULT}"
  MODEL_DOWNLOAD="${MODEL_DOWNLOAD:-1}"
  MODEL_DOWNLOAD_WORKERS="${MODEL_DOWNLOAD_WORKERS:-8}"
  export TRITON_PTXAS_PATH="${TRITON_PTXAS_PATH:-/usr/local/cuda/bin/ptxas}"
  log "CACHE_SIZE=${CACHE_SIZE} NUM_DRAFT_TOKENS=${NUM_DRAFT_TOKENS} PROXY_PORT=${PROXY_PORT} SERVE_PORT=${SERVE_PORT} PROXY_TIMEOUT=${PROXY_TIMEOUT} MODEL_DOWNLOAD=${MODEL_DOWNLOAD} 下载线程=${MODEL_DOWNLOAD_WORKERS} VISION=${VISION} MAX_IMAGE_TOKENS=${MAX_IMAGE_TOKENS:-处理器默认} CF_TUNNEL=${CF_TUNNEL} METRICS_INTERVAL=${METRICS_INTERVAL}"
  log "模型目录 $(locked_model_dir) 仓库 ${MODEL_REPO} 修订 ${MODEL_REVISION}"

  case "$VISION" in
    0 | 1) ;;
    *)
      log "VISION 只能是 0 或 1，当前是 ${VISION}"
      exit 1
      ;;
  esac
  if [[ -n "$MAX_IMAGE_TOKENS" && ! "$MAX_IMAGE_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
    log "MAX_IMAGE_TOKENS 必须是正整数，当前是 ${MAX_IMAGE_TOKENS}"
    exit 1
  fi
  case "$CF_TUNNEL" in
    0 | 1) ;;
    *)
      log "CF_TUNNEL 只能是 0 或 1，当前是 ${CF_TUNNEL}"
      exit 1
      ;;
  esac
  if [[ ! "$METRICS_INTERVAL" =~ ^[0-9]+$ ]]; then
    log "METRICS_INTERVAL 必须是非负整数，当前是 ${METRICS_INTERVAL}"
    exit 1
  fi

  # 22 先起来。后面的下载和加载都不挡 SSH。
  install_ssh_pubkey "${SSH_PUBLIC_KEY:-}" /root/.ssh/authorized_keys
  fix_root_ssh_perms /root/.ssh
  activate_tunnel_user
  start_sshd_daemon

  if [[ ! -x "$TRITON_PTXAS_PATH" ]]; then
    log "找不到 ptxas: ${TRITON_PTXAS_PATH}"
    exit 1
  fi
  log "ptxas ${TRITON_PTXAS_PATH}"

  publish_runtime_env /etc/environment \
    API_TOKEN CACHE_SIZE NUM_DRAFT_TOKENS PROXY_PORT SERVE_PORT PROXY_TIMEOUT \
    MODEL_REPO MODEL_REVISION MODEL_DOWNLOAD MODEL_DOWNLOAD_WORKERS IMAGE_VERSION GIT_COMMIT \
    VISION MAX_IMAGE_TOKENS CF_TUNNEL METRICS_INTERVAL
  export UPSTREAM="http://127.0.0.1:${SERVE_PORT}"
  export PROXY_PORT API_TOKEN PROXY_TIMEOUT
  start_auth_proxy 0.0.0.0
  log "用服务器 IP 和端口 ${PROXY_PORT} 访问。请求头 Authorization: Bearer，值是 API_TOKEN。不要访问 ${SERVE_PORT}，那里没有鉴权。"
  log_vast_access
  start_cloudflared
  start_metrics_loop

  if [[ -z "${ET_NETWORK_NAME:-}" && -z "${ET_NETWORK_SECRET:-}" ]]; then
    log "EasyTier 未配置。走服务器 IP 和端口 ${PROXY_PORT}。"
  elif prepare_easytier; then
    log "EasyTier 启动。默认监听 tcp/udp 11010。未设置 ET_PEERS 时只等别人来连。认证方式与服务器 IP 相同。"
    nohup easytier-core >/proc/1/fd/2 2>&1 &
    log "easytier-core pid=$!"
    if have_tun; then
      watch_easytier_proxy &
    fi
  else
    log "EasyTier 未启动。认证代理仍在 0.0.0.0:${PROXY_PORT}。"
  fi

  local model_rc=0
  MODEL_DIR="$(ensure_model_dir)" || model_rc=$?
  if [[ "$model_rc" -eq 2 ]]; then
    log "推理未启动。sshd 和认证代理继续。"
    wait || true
    exit 0
  fi
  if [[ "$model_rc" -ne 0 ]]; then
    exit "$model_rc"
  fi
  export MODEL_DIR
  publish_runtime_env /etc/environment MODEL_DIR
  log "推理将使用模型目录 ${MODEL_DIR}"

  local free_gib gs warning serve_status=0 serve_log tail_pid
  free_gib="$(read_free_gib)"
  gs="$(choose_gpu_split "${GPU_SPLIT_GB:-}" "$free_gib")"
  warning="$(split_warning "$gs" "$CACHE_SIZE")"
  if [[ -n "$warning" ]]; then
    log "warn: ${warning}"
  fi
  # EXL3_UMA=1 时 exllamav3 按 MemAvailable 算余量，页缓存会被回收，这里读到的空闲偏低不代表会失败。
  if [[ "${EXL3_UMA:-}" != 1 ]] && (( free_gib < gs + 2 )); then
    log "warn: 空闲 ${free_gib} GiB，上游 serve.sh 仍用 -gs ${gs}。页缓存占满时这次加载会失败。"
  fi
  log "GPU_SPLIT_GB=${gs} CACHE_SIZE=${CACHE_SIZE} 空闲显存约 ${free_gib} GiB"
  start_load_cache_dropper
  GPU_SPLIT_GB="$gs"
  publish_runtime_env /etc/environment GPU_SPLIT_GB

  serve_log="$(mktemp)"
  vision_serve_args
  log "启动推理，参数对齐上游 serve.sh：-m ${MODEL_DIR} -gs ${gs} --cache_size ${CACHE_SIZE} --cache_quant 4 --mtp --num_draft_tokens ${NUM_DRAFT_TOKENS} --max-model-len ${CACHE_SIZE} --port ${SERVE_PORT} ${VISION_ARGS[*]}"
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
    --request-timeout 7200 \
    "${VISION_ARGS[@]}" >>"$serve_log" 2>&1 &
  local serve_pid=$!
  tail -n +0 -F "$serve_log" > >(format_serve_output) &
  tail_pid=$!
  if [[ -n "${DROPPER_PID:-}" ]]; then
    stop_load_cache_dropper "$DROPPER_PID" "$serve_pid" "$serve_log" &
  fi
  log "推理 pid=${serve_pid} 只监听 127.0.0.1:${SERVE_PORT}。对外是 0.0.0.0:${PROXY_PORT}。上游冷加载大约 4 到 6 分钟，权重已在页缓存里时大约一分钟。日志出现 Native API listening 后才能调用。"
  wait "${serve_pid}" || serve_status=$?
  kill "$tail_pid" ${DROPPER_PID:+"$DROPPER_PID"} ${METRICS_PID:+"$METRICS_PID"} 2>/dev/null || true
  log "推理进程退出 status=${serve_status}"
  exit "${serve_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
