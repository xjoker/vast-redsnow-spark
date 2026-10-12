#!/bin/bash
# Start inference directly inside the container. Inference listens on 127.0.0.1 only; the auth proxy listens on 0.0.0.0 and requires API_TOKEN.
# If EasyTier is left empty, use the server IP and the auth port.
set -euo pipefail

log() {
  printf '%s [redsnow] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

DOWNLOAD_MODEL_PY="${DOWNLOAD_MODEL_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/download_model.py}"
LOG_SINK_PY="${LOG_SINK_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log_sink.py}"
# format_serve_output touches this when inference is ready; the page-cache dropper waits for it.
SERVE_READY_FILE="${SERVE_READY_FILE:-/run/redsnow/serve_ready}"
MODEL_REPO_DEFAULT="vcruz305/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw"
MODEL_REVISION_DEFAULT="071adefe6c1c8de379d76977985811b7d4385454"
SERVED_MODEL_NAME="RED-SNOW-5.3-FLASH-EXL3-2.49"

have_tun() {
  [[ -c /dev/net/tun ]]
}

MODEL_NAME="RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw"
# The single model directory. When storage is mounted, mount it at /models and the files land here.
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

# The default directory must be a mount point so ~97 GiB is not written into the container layer. MODEL_DIR sets the location explicitly.
weights_mount_ok() {
  local dest="$1"
  [[ "$dest" == "$MODEL_LOCK" ]] || return 0
  [[ -f /proc/mounts ]] || return 1
  awk -v p="/models" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
}

# 0: directory is loadable. 2: not downloading; caller keeps sshd and the auth proxy. 1: config or download failed.
ensure_model_dir() {
  local dest
  case "${MODEL_DOWNLOAD:-1}" in
    0 | 1) ;;
    *)
      log "MODEL_DOWNLOAD must be 0 or 1, got ${MODEL_DOWNLOAD}"
      return 1
      ;;
  esac
  dest="$(locked_model_dir)"
  if model_is_complete "$dest"; then
    log "using existing model ${dest}"
    printf '%s\n' "$dest"
    return 0
  fi
  if [[ "${MODEL_DOWNLOAD:-1}" == "0" ]]; then
    log "MODEL_DOWNLOAD=0, directory has no complete model, not downloading: ${dest}"
    return 2
  fi
  if ! weights_mount_ok "$dest"; then
    log "model directory ${dest} has no mounted storage, not downloading. Mount a disk at /models or set MODEL_DIR. Skipping inference this time."
    return 2
  fi
  log "directory has no complete model, downloading repo=${MODEL_REPO} revision=${MODEL_REVISION} dir=${dest} workers=${MODEL_DOWNLOAD_WORKERS}"
  python3 "$DOWNLOAD_MODEL_PY" \
    --repo "$MODEL_REPO" \
    --revision "$MODEL_REVISION" \
    --dest "$dest" \
    --workers "$MODEL_DOWNLOAD_WORKERS" >&2
  if ! model_is_complete "$dest"; then
    log "download finished but model is still incomplete: ${dest}"
    return 1
  fi
  log "model download complete ${dest}"
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

# When the platform recreates the container it writes the public key owned by the host uid, which makes sshd StrictModes reject root key logins, so chown it back at startup.
fix_root_ssh_perms() {
  local dir="${1:-/root/.ssh}" path owner
  [[ -d "$dir" ]] || return 0
  for path in "$dir" "$dir/authorized_keys" "$dir/authorized_keys2"; do
    [[ -e "$path" ]] || continue
    if [[ "$EUID" -eq 0 ]]; then
      owner="$(stat -c '%u:%g' "$path")"
      if [[ "$owner" != "0:0" ]]; then
        chown root:root "$path"
        log "${path} is owned by ${owner}, changed back to root. The platform injected the key with a host uid, which sshd StrictModes rejects."
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
      log "SSH_TUNNELS has more than 16 targets"
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

# Returns 1 if not configured. Returns 2 if the user name, password or forward target is invalid. The config text contains no password.
tunnel_sshd_block() {
  local password="${SSH_PASSWORD:-}" pubkey="${SSH_USER_PUBLIC_KEY:-}"
  if [[ -z "$password" && -z "$pubkey" ]]; then
    if [[ -n "${SSH_USER:-}" || -n "${SSH_TUNNELS:-}" ]]; then
      log "warn: creating the tunnel user also needs SSH_PASSWORD or SSH_USER_PUBLIC_KEY."
    fi
    return 1
  fi
  local user="${SSH_USER:-tunnel}"
  if ! valid_ssh_user "$user"; then
    log "invalid SSH_USER: ${user}. Must start with a lowercase letter and cannot be root."
    return 2
  fi
  if [[ "$password" == *$'\n'* || "$password" == *$'\r'* ]]; then
    log "SSH_PASSWORD cannot contain newlines"
    return 2
  fi
  if [[ -n "$password" && ${#password} -lt 12 ]]; then
    log "warn: SSH_PASSWORD is shorter than 12 characters. Port 22 is often public on rental platforms."
  fi
  local targets_text="" targets_rc=0 line
  targets_text="$(tunnel_targets "${SSH_TUNNELS:-}" "${PROXY_PORT:-8898}")" || targets_rc=$?
  if [[ "$targets_rc" -ne 0 || -z "$targets_text" ]]; then
    if [[ -z "$targets_text" ]]; then
      log "SSH_TUNNELS is empty"
    fi
    return 2
  fi
  local -a targets=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if ! valid_permit_open "$line"; then
      log "invalid SSH_TUNNELS target: ${line}"
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
      log "warn: tunnel user not enabled this time. Inference continues."
    fi
    return 0
  fi
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    log "warn: no /etc/ssh/sshd_config, tunnel user not enabled."
    return 0
  fi
  upsert_sshd_tunnel /etc/ssh/sshd_config "$block"
  if [[ -x /usr/sbin/sshd ]] && ! /usr/sbin/sshd -t; then
    log "warn: sshd rejected the tunnel config, rolled back."
    upsert_sshd_tunnel /etc/ssh/sshd_config ""
    return 0
  fi
  local user="${SSH_USER:-tunnel}"
  if ! ensure_tunnel_user "$user" "${SSH_PASSWORD:-}" "${SSH_USER_PUBLIC_KEY:-}"; then
    log "warn: creating the tunnel user failed. Inference continues."
    upsert_sshd_tunnel /etc/ssh/sshd_config ""
    return 0
  fi
  local first
  first="$(tunnel_targets "${SSH_TUNNELS:-}" "${PROXY_PORT:-8898}")"
  first="${first%%$'\n'*}"
  log "tunnel user ${user} is ready, passwordless sudo. ssh ${user}@<host> then sudo -i. Forward: ssh -N -L <local-port>:${first} ${user}@<host>"
}

# Vast injects the public address and random external ports at startup. Do not log when these variables are absent.
log_vast_access() {
  local ip="${PUBLIC_IPADDR:-}" ssh_ext="${VAST_TCP_PORT_22:-}"
  local api_name="VAST_TCP_PORT_${PROXY_PORT:-8898}" api_ext=""
  if [[ -v "$api_name" ]]; then
    api_ext="${!api_name}"
  fi
  [[ -n "$ip" ]] || return 0
  if [[ -n "$ssh_ext" ]]; then
    log "Vast SSH: ssh -p ${ssh_ext} root@${ip} . root accepts only the account public key. Password login is for the in-image user, not root."
  fi
  if [[ -n "$api_ext" ]]; then
    log "Vast API: http://${ip}:${api_ext} maps to container port ${PROXY_PORT:-8898}. Send header Authorization: Bearer with API_TOKEN as the value. This mapping is plain HTTP."
  fi
}

start_sshd_daemon() {
  mkdir -p /var/run/sshd
  # Host keys are generated per container. Baking them into the image would make every machine pulling the same tag share one private key.
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A || log "warn: could not generate SSH host keys."
  fi
  if [[ ! -x /usr/sbin/sshd ]]; then
    log "warn: no sshd in the image."
    return 0
  fi
  if ! /usr/sbin/sshd -t; then
    log "warn: invalid sshd config."
    return 0
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x sshd >/dev/null 2>&1; then
    # HUP only the oldest listening process. Session processes are also named sshd, and HUPing them would drop connected SSH sessions.
    pkill -HUP -o -x sshd || true
    log "sshd already running, reloaded. Port 22 is reachable now."
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
        log "warn: sshd failed to start repeatedly. If port 22 is already taken, keep using the existing sshd."
        exit 0
      fi
      log "warn: sshd exited with status ${status:-0}, restarting in 1 second"
      sleep 1
    done
  ) &
  log "sshd is listening on 22 in the background. You can connect while the model is still loading."
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
    log "cannot read free GiB: ${free_gib}"
    return 1
  fi
  # Weschera serve.sh fixes -gs at 112. If free memory is insufficient the caller warns; this split is not changed.
  printf '112\n'
}

# On newer kernels (e.g. 6.17.0-1026) GB10 MemTotal is ~119.6 GiB, 2 GiB less than on older kernels. With the fork default of 8 GiB left for the system,
# such machines may report Insufficient VRAM on first load, and after a successful load the first request's MTP vocab mirror (1.18 GiB) can also OOM.
# Measured with 6 GiB reserved: 200K tokens, and 60K tokens plus 3 images, both pass, with system MemAvailable at least 2.5 GiB; with 5 GiB reserved only 0.55 GiB was left.
# Empty output keeps the fork default (8192).
choose_uma_reserve() {
  local explicit="$1" mem_total_kib="$2"
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
  elif ((mem_total_kib < 126500000)); then
    printf '6144\n'
  fi
}

split_warning() {
  local gs="$1" cache="$2"
  if ((cache >= 262144 && gs < 108)); then
    printf 'split %s GiB is below the 110 that loads 256K successfully. If free VRAM is insufficient this context size will fail to load.\n' "$gs"
  fi
}

# The result goes into VISION_ARGS. When MAX_IMAGE_TOKENS is empty it is not passed and the upstream processor picks the default.
vision_serve_args() {
  VISION_ARGS=()
  if [[ "$VISION" == 1 ]]; then
    VISION_ARGS+=(--vision)
  fi
  if [[ -n "$MAX_IMAGE_TOKENS" ]]; then
    VISION_ARGS+=(--max-image-tokens "$MAX_IMAGE_TOKENS")
  fi
}

# Upstream serve.sh drops once before loading, then every 2 seconds during loading until Native API listening appears.
# Must be called in the current shell; the result goes into DROPPER_PID. Do not put it in $(), or the background loop exits with the subshell.
start_load_cache_dropper() {
  DROPPER_PID=""
  if ! echo 3 >/proc/sys/vm/drop_caches 2>/dev/null; then
    log "warn: cannot drop page cache inside the container. Upstream serve.sh drops it before and during loading. The split stays at 112; do not treat lowering context to 131072 as the only fix."
    return 0
  fi
  log "following upstream serve.sh: dropping page cache every 2 seconds while loading."
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
  local dropper="$1" serve_pid="$2" _
  [[ -n "$dropper" ]] || return 0
  for _ in $(seq 1 180); do
    if [[ -e "$SERVE_READY_FILE" ]]; then
      break
    fi
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      break
    fi
    sleep 2
  done
  kill "$dropper" 2>/dev/null || true
}

# Validate before startup so the mistake shows at the entrypoint instead of easytier-core silently failing to connect.
check_easytier_peers() {
  local item re='^(tcp|udp)://[^,[:space:]]+:[0-9]+$'
  local -a items=()
  [[ -n "$1" ]] || return 0
  IFS=, read -ra items <<<"$1"
  for item in "${items[@]}"; do
    if [[ ! "$item" =~ $re ]]; then
      log "invalid EASYTIER_PEERS item: ${item}. Expected tcp://host:port or udp://host:port, comma separated."
      return 1
    fi
  done
}

# Map EASYTIER_* to easytier-core's ET_*. Users only know the EASYTIER_* prefix; ET_* is no longer read.
# A node without a virtual IP only forwards and is unreachable, so an empty IPV4 always requests DHCP.
prepare_easytier() {
  local name="${EASYTIER_NETWORK_NAME:-}" secret="${EASYTIER_NETWORK_SECRET:-}"
  # On container restart a stale virtual IP from the previous run may remain; without deleting it the banner would point to a dead address.
  rm -f "${EASYTIER_IP_FILE:-/run/redsnow/easytier_ip}"
  if [[ -z "$name" && -z "$secret" ]]; then
    log "EasyTier not configured. Use the server IP and port ${PROXY_PORT:-8898}."
    return 1
  fi
  if [[ -z "$name" || -z "$secret" ]]; then
    log "warn: EasyTier needs both EASYTIER_NETWORK_NAME and EASYTIER_NETWORK_SECRET, not starting this time."
    return 1
  fi
  export ET_NETWORK_NAME="$name" ET_NETWORK_SECRET="$secret"
  export ET_HOSTNAME="${EASYTIER_HOSTNAME:-redsnow}"
  # warn level also floods: a dead TCP peer logs one connector::manual reconnect failure every 3 s, a dead UDP peer two tunnel::udp lines every 3 s,
  # and each easytier-cli call by the virtual IP watcher adds a bidirect "read aborted". Keep error only; joining, IP change and drop are reported by watch_easytier_vip.
  export ET_CONSOLE_LOG_LEVEL=error
  if [[ "${EASYTIER_PRIVATE_MODE:-1}" == 1 ]]; then
    export ET_PRIVATE_MODE=true
  else
    export ET_PRIVATE_MODE=false
  fi
  if [[ -n "${EASYTIER_PEERS:-}" ]]; then
    export ET_PEERS="$EASYTIER_PEERS"
  fi
  if [[ -n "${EASYTIER_IPV4:-}" ]]; then
    export ET_IPV4="$EASYTIER_IPV4"
  else
    export ET_DHCP=true
  fi
  # The container has no /dev/net/tun or CAP_NET_ADMIN, so no-tun is the only option.
  if ! have_tun; then
    log "warn: no /dev/net/tun, EasyTier runs in no-tun mode. Peers on the same network reach ${PROXY_PORT:-8898} via the virtual IP."
    export ET_NO_TUN=true
  fi
  return 0
}

# easytier-cli outputs JSON; a node's ipv4_addr looks like 10.144.144.1/24 and the mask is stripped here.
easytier_vip() {
  local out re='"ipv4_addr"[[:space:]]*:[[:space:]]*"([0-9.]+)/[0-9]+"'
  out="$(easytier-cli -o json node 2>/dev/null)" || return 1
  [[ "$out" =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

start_auth_proxy() {
  local host="$1"
  PROXY_HOST="$host" nohup python3 /opt/redsnow/auth_proxy.py >/proc/1/fd/2 2>&1 &
  log "auth proxy pid=$! listening on ${host}:${PROXY_PORT} upstream ${UPSTREAM}"
}

# Points only at the auth proxy PROXY_PORT, never at the inference port. The anonymous URL is written to TUNNEL_URL_FILE so it can be cat'ed instead of digging through logs.
start_cloudflared() {
  [[ "$CF_TUNNEL" == 1 ]] || return 0
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "warn: no cloudflared in the image, public tunnel not started."
    return 0
  fi
  local url_file="${TUNNEL_URL_FILE:-/run/redsnow/tunnel_url}"
  mkdir -p "$(dirname "$url_file")"
  rm -f "$url_file"
  # The token goes only into the child process environment, not command-line arguments or logs.
  if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    log "Cloudflare named tunnel started. Configure the public hostname in the Cloudflare dashboard with service URL http://localhost:${PROXY_PORT}."
    (
      status=0
      TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" cloudflared tunnel --no-autoupdate run 2>&1 \
        | while IFS= read -r line; do printf '%s\n' "$line" >&2; done || status=$?
      log "warn: cloudflared exited status=${status}"
    ) &
    return 0
  fi
  log "Cloudflare quick tunnel started, requesting a public URL."
  (
    status=0
    url=""
    cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${PROXY_PORT}" 2>&1 \
      | while IFS= read -r line; do
          printf '%s\n' "$line" >&2
          if [[ -z "$url" && "$line" =~ https://[A-Za-z0-9-]+\.trycloudflare\.com ]]; then
            url="${BASH_REMATCH[0]}"
            printf '%s\n' "$url" >"$url_file"
            log_banner "Cloudflare public URL" \
              "Public  ${url}" \
              "Auth    header Authorization: Bearer, value is API_TOKEN" \
              "Use streaming requests only; non-streaming requests over 100 s get 524 from Cloudflare"
          fi
        done || status=$?
    log "warn: cloudflared exited status=${status}"
  ) &
}

start_easytier() {
  nohup easytier-core >/proc/1/fd/2 2>&1 &
  local pid=$!
  if [[ -n "${EASYTIER_PEERS:-}" ]]; then
    log "EasyTier started pid=${pid}, peer: ${EASYTIER_PEERS}"
  else
    log "EasyTier started pid=${pid}. With EASYTIER_PEERS empty it only waits for others to connect."
  fi
  watch_easytier_vip &
}

# Resident poll: DHCP assigns only after a same-network node connects, so late joins, IP changes and drops all need to be followed; one check is not enough.
# Write the file and print the banner only when the IP changes, to avoid logging every round. EASYTIER_WATCH_INTERVAL exists only so tests can speed it up.
watch_easytier_vip() {
  local ip="" last="" file="${EASYTIER_IP_FILE:-/run/redsnow/easytier_ip}"
  local interval="${EASYTIER_WATCH_INTERVAL:-5}" began=$SECONDS seen=0 warned=0
  while :; do
    ip="$(easytier_vip || true)"
    if [[ -n "$ip" && "$ip" != "$last" ]]; then
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "$ip" >"$file"
      seen=1
      log_banner "EasyTier joined" \
        "Virtual IP  ${ip}" \
        "Access     http://${ip}:${PROXY_PORT}/v1 (for peers on the same network, with Bearer)"
      last="$ip"
    elif [[ -z "$ip" && -n "$last" ]]; then
      rm -f "$file"
      log "warn: EasyTier virtual IP lost, waiting to rejoin"
      last=""
    fi
    if [[ "$seen" == 0 && "$warned" == 0 ]] && (( SECONDS - began >= 60 )); then
      warned=1
      log "warn: no EasyTier virtual IP within 60 seconds. DHCP assigns one only after at least one same-network node connects; check EASYTIER_PEERS and the network secret. The auth proxy is still on 0.0.0.0:${PROXY_PORT}."
    fi
    sleep "$interval"
  done
}

# Frame the title with equals signs so the public URL and ready info are easy to find in a long log.
log_banner() {
  local title="$1" row
  shift
  log "==== ${title} ===="
  for row in "$@"; do
    log "  ${row}"
  done
  log "========================================"
}

# The connection block is copied whole to an AI, so the URL and example are filled in and only <API_TOKEN> is left for the user.
# The tunnel takes priority over Vast direct because the tunnel is HTTPS and the Vast mapping is plain HTTP. The auth line carries a literal, so the real token never enters the log. Absent items are not printed.
connect_lines() {
  local url_file="${TUNNEL_URL_FILE:-/run/redsnow/tunnel_url}" tunnel_url=""
  local ip_file="${EASYTIER_IP_FILE:-/run/redsnow/easytier_ip}"
  local ip="${PUBLIC_IPADDR:-}" api_name="VAST_TCP_PORT_${PROXY_PORT:-8898}" api_ext=""
  local vast="" base="" tunnel=0 caps body
  if [[ -s "$url_file" ]]; then
    tunnel_url="$(head -n 1 "$url_file")"
  fi
  if [[ -v "$api_name" ]]; then
    api_ext="${!api_name}"
  fi
  if [[ -n "$ip" && -n "$api_ext" ]]; then
    vast="http://${ip}:${api_ext}/v1"
  fi
  if [[ -n "$tunnel_url" ]]; then
    base="${tunnel_url}/v1"
    tunnel=1
  elif [[ "${CF_TUNNEL:-}" == 1 && -n "${CF_TUNNEL_TOKEN:-}" ]]; then
    base="https://<hostname configured in Cloudflare>/v1"
    tunnel=1
  elif [[ -n "$vast" ]]; then
    base="$vast"
  else
    base="http://<server address>:${PROXY_PORT:-8898}/v1"
  fi
  caps="text, tool calls (tools/tool_choice), response_format json_object/json_schema"
  if [[ "${VISION:-}" == 1 ]]; then
    caps+=", images (image_url, data:image base64 or http(s) URL)"
  fi
  body='{"model":"'"${SERVED_MODEL_NAME}"'","stream":true,"messages":[{"role":"user","content":"Hello"}]}'
  echo "Protocol  OpenAI Chat Completions compatible"
  echo "Base URL  ${base}"
  if [[ "$tunnel" == 1 && -n "$vast" ]]; then
    echo "Fallback  ${vast} (Vast direct, plain HTTP)"
  fi
  if [[ -s "$ip_file" ]]; then
    echo "EasyTier  http://$(head -n 1 "$ip_file"):${PROXY_PORT:-8898}/v1 (peers on the same network)"
  fi
  echo "Model     ${SERVED_MODEL_NAME}"
  echo "Auth      header Authorization: Bearer <API_TOKEN>"
  echo "Context   ${CACHE_SIZE} tok; input plus max_tokens beyond this returns 400"
  echo "Slots     ${MAX_ACTIVE_REQUESTS} concurrent request(s) generate; the rest queue"
  echo "Advice    keep max_tokens at or below 32000; compact or truncate the conversation beyond $((CACHE_SIZE - 32768)) tok"
  if [[ "$tunnel" == 1 ]]; then
    echo "Stream    stream: true is required; non-streaming requests over 100 s get 524 from Cloudflare"
  else
    echo "Stream    stream: true recommended"
  fi
  echo "Features  ${caps}"
  echo "Limits    n>1 and logprobs are not supported"
  echo "Endpoints GET /v1/models, POST /v1/chat/completions"
  echo "Example   curl -N ${base}/chat/completions -H 'Authorization: Bearer <API_TOKEN>' -H 'Content-Type: application/json' -d '${body}'"
}

# The ready banner keeps only the Vast SSH line; connect_lines already gives all other access info.
access_lines() {
  local ip="${PUBLIC_IPADDR:-}" ssh_ext="${VAST_TCP_PORT_22:-}"
  if [[ -n "$ip" && -n "$ssh_ext" ]]; then
    echo "Vast SSH  ssh -p ${ssh_ext} root@${ip} (root accepts only the account public key; use the tunnel user for password login)"
  fi
}

json_num() {
  local re="\"$1\":([-+0-9.eE]+)"
  [[ "$2" =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# Upstream prints one usage JSON line when each request ends. Returns 1 if any field is missing, and the caller prints that line unchanged.
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
    if (tp + 0 > 0) rate = sprintf(" (%d tok/s)", pt / tp + 0.5)
    printf "request done %s | in %d tok prefill %.2f s%s | out %d tok decode %.1f tok/s | MTP accept %.0f%% | queued %.2f s",
      reason, pt, tp, rate, ct, dts, da * 100, te
  }'
}

# Send everything PID 1 and its children print through log_sink.py, which keeps a size-capped copy on disk.
# Must run before anything else starts so /proc/1/fd/2 and inherited fds all go through the sink.
setup_file_logging() {
  local dir="${LOG_DIR:-/workspace/logs}" mb="${LOG_MAX_MB:-3072}"
  if [[ ! "$mb" =~ ^[0-9]+$ ]]; then
    log "LOG_MAX_MB must be a non-negative integer, got ${mb}"
    exit 1
  fi
  ((mb > 0)) || return 0
  if ! { mkdir -p "$dir" && [[ -w "$dir" ]]; } 2>/dev/null; then
    log "warn: LOG_DIR ${dir} is not writable; logging to stdout only."
    return 0
  fi
  exec > >(python3 -u "$LOG_SINK_PY" "$dir" "$mb") 2>&1
  log "logging to ${dir}/redsnow.log, capped at ${mb} MiB in total"
}

# The inference stdout/stderr comes in here: usage lines are squashed into one line, load-time Mixed-K noise keeps only layer progress, and access info is printed when Native API is ready.
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
      *'"GET /health HTTP/'*|*'"GET /v1/health HTTP/'*|*'"GET /metrics HTTP/'*)
        ;;
      " -- Mixed-K "*)
        if [[ "$line" =~ $re_layer ]] && ((10#${BASH_REMATCH[1]} % 10 == 0)); then
          log "loading weights layer ${BASH_REMATCH[1]}"
        fi
        ;;
      *"Native API listening"*)
        printf '%s\n' "$line" >&2
        mkdir -p "$(dirname "$SERVE_READY_FILE")" && : >"$SERVE_READY_FILE"
        rows=("load time $((SECONDS - start_at)) s")
        while IFS= read -r row; do
          rows+=("$row")
        done < <(connect_lines; access_lines)
        log_banner "Model ready: connection info (copy this block to an AI; only API_TOKEN needs filling in)" "${rows[@]}"
        ;;
      *)
        printf '%s\n' "$line" >&2
        ;;
    esac
  done
}

# One line of runtime metrics. The GPU segment is omitted when nvidia-smi is missing or fails; if upstream /health is unreachable it says inference is not ready.
metrics_line() {
  local url_file="${TUNNEL_URL_FILE:-/run/redsnow/tunnel_url}" meminfo="${MEMINFO:-/proc/meminfo}"
  local ip_file="${EASYTIER_IP_FILE:-/run/redsnow/easytier_ip}"
  local gpu="" mem="" health="" et="" public="" body="" url="" out="" seg
  local re_requests='"requests":[[:space:]]*([0-9]+)'
  gpu="$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,clocks.sm --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' 'NR == 1 && NF == 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9.]+$/ && $4 ~ /^[0-9]+$/ {
        printf "GPU %s%% %s°C %.0f W SM %s MHz", $1, $2, $3, $4 }')" || true
  if [[ -r "$meminfo" ]]; then
    mem="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
      END { if (t > 0 && a > 0) printf "mem avail %.1f/%.1f GiB", a / 1048576, t / 1048576 }' "$meminfo")"
  fi
  body="$(curl -fsS --max-time 2 "http://127.0.0.1:${SERVE_PORT:-8899}/health" 2>/dev/null)" || body=""
  if [[ -z "$body" ]]; then
    health="inference not ready"
  elif [[ "$body" =~ $re_requests ]]; then
    health="active ${BASH_REMATCH[1]}"
  fi
  if [[ -s "$ip_file" ]]; then
    et="EasyTier $(head -n 1 "$ip_file")"
  fi
  if [[ -s "$url_file" ]]; then
    url="$(head -n 1 "$url_file")"
    public="public ${url}"
  fi
  for seg in "$gpu" "$mem" "$health" "$et" "$public"; do
    [[ -n "$seg" ]] || continue
    out="${out:+${out} | }${seg}"
  done
  printf 'metrics %s\n' "$out"
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
  setup_file_logging
  log "container start, image ${IMAGE_VERSION:-unknown}"
  if [[ $# -gt 0 ]]; then
    log "ignoring startup arguments. Set context and VRAM split with the environment variables CACHE_SIZE and GPU_SPLIT_GB."
  fi

  : "${API_TOKEN:?API_TOKEN environment variable is required}"
  log "starting version=${IMAGE_VERSION:-unknown}. API_TOKEN is set."

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
  # -ambs makes exllamav3 reserve memory for the same batch size at load time, so it must be at least the number of concurrent slots; use the same value here.
  MAX_ACTIVE_REQUESTS="${MAX_ACTIVE_REQUESTS:-3}"
  EASYTIER_PRIVATE_MODE="${EASYTIER_PRIVATE_MODE:-1}"
  export TRITON_PTXAS_PATH="${TRITON_PTXAS_PATH:-/usr/local/cuda/bin/ptxas}"
  log "CACHE_SIZE=${CACHE_SIZE} NUM_DRAFT_TOKENS=${NUM_DRAFT_TOKENS} MAX_ACTIVE_REQUESTS=${MAX_ACTIVE_REQUESTS} PROXY_PORT=${PROXY_PORT} SERVE_PORT=${SERVE_PORT} PROXY_TIMEOUT=${PROXY_TIMEOUT} MODEL_DOWNLOAD=${MODEL_DOWNLOAD} download_workers=${MODEL_DOWNLOAD_WORKERS} VISION=${VISION} MAX_IMAGE_TOKENS=${MAX_IMAGE_TOKENS:-processor default} CF_TUNNEL=${CF_TUNNEL} METRICS_INTERVAL=${METRICS_INTERVAL}"
  log "model dir $(locked_model_dir) repo ${MODEL_REPO} revision ${MODEL_REVISION}"

  case "$VISION" in
    0 | 1) ;;
    *)
      log "VISION must be 0 or 1, got ${VISION}"
      exit 1
      ;;
  esac
  if [[ -n "$MAX_IMAGE_TOKENS" && ! "$MAX_IMAGE_TOKENS" =~ ^[1-9][0-9]*$ ]]; then
    log "MAX_IMAGE_TOKENS must be a positive integer, got ${MAX_IMAGE_TOKENS}"
    exit 1
  fi
  case "$CF_TUNNEL" in
    0 | 1) ;;
    *)
      log "CF_TUNNEL must be 0 or 1, got ${CF_TUNNEL}"
      exit 1
      ;;
  esac
  if [[ ! "$METRICS_INTERVAL" =~ ^[0-9]+$ ]]; then
    log "METRICS_INTERVAL must be a non-negative integer, got ${METRICS_INTERVAL}"
    exit 1
  fi
  if [[ ! "$MAX_ACTIVE_REQUESTS" =~ ^[1-9][0-9]*$ ]]; then
    log "MAX_ACTIVE_REQUESTS must be a positive integer, got ${MAX_ACTIVE_REQUESTS}"
    exit 1
  fi
  # Measured: with a cache pool above 131072 several long prompts prefill at once, and 2x60K already hits CUDA OOM; at 131072 the pool staggers most prefills.
  if (( MAX_ACTIVE_REQUESTS > 3 )) && [[ "$CACHE_SIZE" =~ ^[0-9]+$ ]] && (( CACHE_SIZE > 131072 )); then
    log "warn: MAX_ACTIVE_REQUESTS=${MAX_ACTIVE_REQUESTS} with CACHE_SIZE=${CACHE_SIZE} has not passed the long-prompt test; several long requests prefilling at once will OOM (the single request gets 503). Up to 3 slots passed 3x80K at 262144; for more slots use CACHE_SIZE=131072 NUM_DRAFT_TOKENS=1."
  fi
  case "$EASYTIER_PRIVATE_MODE" in
    0 | 1) ;;
    *)
      log "EASYTIER_PRIVATE_MODE must be 0 or 1, got ${EASYTIER_PRIVATE_MODE}"
      exit 1
      ;;
  esac
  check_easytier_peers "${EASYTIER_PEERS:-}" || exit 1

  # Start 22 first. Neither the download nor the load below blocks SSH.
  install_ssh_pubkey "${SSH_PUBLIC_KEY:-}" /root/.ssh/authorized_keys
  fix_root_ssh_perms /root/.ssh
  activate_tunnel_user
  start_sshd_daemon

  if [[ ! -x "$TRITON_PTXAS_PATH" ]]; then
    log "ptxas not found: ${TRITON_PTXAS_PATH}"
    exit 1
  fi
  log "ptxas ${TRITON_PTXAS_PATH}"

  publish_runtime_env /etc/environment \
    API_TOKEN CACHE_SIZE NUM_DRAFT_TOKENS MAX_ACTIVE_REQUESTS PROXY_PORT SERVE_PORT PROXY_TIMEOUT \
    MODEL_REPO MODEL_REVISION MODEL_DOWNLOAD MODEL_DOWNLOAD_WORKERS IMAGE_VERSION GIT_COMMIT \
    VISION MAX_IMAGE_TOKENS CF_TUNNEL METRICS_INTERVAL
  export UPSTREAM="http://127.0.0.1:${SERVE_PORT}"
  export PROXY_PORT API_TOKEN PROXY_TIMEOUT
  start_auth_proxy 0.0.0.0
  log "Use the server IP and port ${PROXY_PORT}. Send header Authorization: Bearer with API_TOKEN as the value. Do not use ${SERVE_PORT}; it has no auth."
  log_vast_access
  start_cloudflared
  start_metrics_loop

  if prepare_easytier; then
    start_easytier
  fi

  local model_rc=0
  MODEL_DIR="$(ensure_model_dir)" || model_rc=$?
  if [[ "$model_rc" -eq 2 ]]; then
    log "inference not started. sshd and the auth proxy continue."
    wait || true
    exit 0
  fi
  if [[ "$model_rc" -ne 0 ]]; then
    exit "$model_rc"
  fi
  export MODEL_DIR
  publish_runtime_env /etc/environment MODEL_DIR
  log "inference will use model dir ${MODEL_DIR}"

  local free_gib gs warning serve_status=0
  free_gib="$(read_free_gib)"
  gs="$(choose_gpu_split "${GPU_SPLIT_GB:-}" "$free_gib")"
  warning="$(split_warning "$gs" "$CACHE_SIZE")"
  if [[ -n "$warning" ]]; then
    log "warn: ${warning}"
  fi
  # With EXL3_UMA=1 exllamav3 computes headroom from MemAvailable and page cache is reclaimed, so a low free reading here does not mean failure.
  if [[ "${EXL3_UMA:-}" != 1 ]] && (( free_gib < gs + 2 )); then
    log "warn: ${free_gib} GiB free, upstream serve.sh still uses -gs ${gs}. If page cache fills memory this load will fail."
  fi
  local mem_total_kib uma_reserve
  mem_total_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  uma_reserve="$(choose_uma_reserve "${EXL3_UMA_RESERVE_MB:-}" "$mem_total_kib")"
  if [[ -n "$uma_reserve" ]]; then
    export EXL3_UMA_RESERVE_MB="$uma_reserve"
    log "MemTotal $((mem_total_kib / 1048576)) GiB, EXL3_UMA_RESERVE_MB=${uma_reserve} (memory kept for the system; fork default 8192)."
  fi
  log "GPU_SPLIT_GB=${gs} CACHE_SIZE=${CACHE_SIZE} free VRAM about ${free_gib} GiB"
  start_load_cache_dropper
  GPU_SPLIT_GB="$gs"
  publish_runtime_env /etc/environment GPU_SPLIT_GB

  rm -f "$SERVE_READY_FILE"
  vision_serve_args
  log "starting inference, args aligned with upstream serve.sh: -m ${MODEL_DIR} -gs ${gs} --cache_size ${CACHE_SIZE} --cache_quant 4 --mtp --num_draft_tokens ${NUM_DRAFT_TOKENS} --max-model-len ${CACHE_SIZE} --max-active-requests ${MAX_ACTIVE_REQUESTS} -ambs ${MAX_ACTIVE_REQUESTS} --port ${SERVE_PORT} ${VISION_ARGS[*]}"
  python3 /opt/redsnow/server/serve_glm.py \
    -m "${MODEL_DIR}" \
    -gs "${gs}" \
    --cache_size "${CACHE_SIZE}" \
    --cache_quant 4 \
    --mtp \
    --num_draft_tokens "${NUM_DRAFT_TOKENS}" \
    --max-model-len "${CACHE_SIZE}" \
    --max-active-requests "${MAX_ACTIVE_REQUESTS}" -ambs "${MAX_ACTIVE_REQUESTS}" \
    --host 127.0.0.1 \
    --port "${SERVE_PORT}" \
    --served-model-name "${SERVED_MODEL_NAME}" \
    --request-timeout 7200 \
    "${VISION_ARGS[@]}" > >(format_serve_output) 2>&1 &
  local serve_pid=$!
  if [[ -n "${DROPPER_PID:-}" ]]; then
    stop_load_cache_dropper "$DROPPER_PID" "$serve_pid" &
  fi
  log "inference pid=${serve_pid} listening on 127.0.0.1:${SERVE_PORT} only. Public side is 0.0.0.0:${PROXY_PORT}. A cold upstream load takes about 4 to 6 minutes, about one minute when the weights are already in page cache. Calls work only after Native API listening appears."
  wait "${serve_pid}" || serve_status=$?
  # Give the output formatter a moment to drain the last lines before PID 1 exits.
  sleep 1
  kill ${DROPPER_PID:+"$DROPPER_PID"} ${METRICS_PID:+"$METRICS_PID"} 2>/dev/null || true
  log "inference process exited status=${serve_status}"
  exit "${serve_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
