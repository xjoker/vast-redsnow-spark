#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
log_test_dir="$(mktemp -d)"
trap 'rm -rf "$log_test_dir"' EXIT
# File logging is off by default in tests; the cases that need it set LOG_MAX_MB themselves.
export LOG_MAX_MB=0 SERVE_READY_FILE="$log_test_dir/serve_ready"
# shellcheck disable=SC1091
source ./entrypoint.sh

fail() {
  echo "FAIL $*" >&2
  exit 1
}

[[ "$(choose_gpu_split "" 114)" == "112" ]] || fail "114 -> 112"
[[ "$(choose_gpu_split "" 112)" == "112" ]] || fail "112 stays 112"
[[ "$(choose_gpu_split "" 101)" == "112" ]] || fail "101 stays 112"
[[ "$(choose_gpu_split 110 114)" == "110" ]] || fail "explicit"
# MemTotal (kB): 151363 old kernel 127535260, 146927 new kernel 125442396.
[[ -z "$(choose_uma_reserve "" 127535260)" ]] || fail "big machine keeps fork default"
[[ "$(choose_uma_reserve "" 125442396)" == "6144" ]] || fail "small machine reserve 6144"
[[ "$(choose_uma_reserve 4096 125442396)" == "4096" ]] || fail "explicit reserve wins"
[[ -z "$(split_warning 110 262144)" ]] || fail "110 should not warn"
[[ -n "$(split_warning 99 262144)" ]] || fail "99 should warn"

root=$(mktemp -d)
unset MODEL_DIR MODEL_DOWNLOAD
[[ "$(locked_model_dir)" == "$MODEL_LOCK" ]] || fail "default lock"
MODEL_DIR="$root/only-this"
[[ "$(locked_model_dir)" == "$root/only-this" ]] || fail "explicit lock"
mkdir -p "$root/elsewhere/models/${MODEL_NAME}"
make_complete() {
  local dir="$1"
  mkdir -p "$dir"
  printf '{}\n' >"$dir/tokenizer_config.json"
  printf '%s\n' '{"weight_map":{"block":"model-00001-of-00015.safetensors"}}' >"$dir/model.safetensors.index.json"
  printf x >"$dir/model-00001-of-00015.safetensors"
}
make_complete "$root/elsewhere/models/${MODEL_NAME}"
if model_is_complete "$root/only-this"; then fail "empty dir is complete"; fi
model_is_complete "$root/elsewhere/models/${MODEL_NAME}" || fail "real layout"

stub=$(mktemp)
cat >"$stub" <<'EOF'
import sys
from pathlib import Path

args = sys.argv[1:]
if args[:1] == ["--check"]:
    raise SystemExit(0 if Path(args[1], ".complete").is_file() else 1)
dest = Path(args[args.index("--dest") + 1])
dest.mkdir(parents=True, exist_ok=True)
(dest / ".complete").write_text("ok", encoding="utf-8")
Path("/tmp/redsnow-model-downloaded").write_text(str(dest), encoding="utf-8")
EOF
rm -f /tmp/redsnow-model-downloaded
(
  export DOWNLOAD_MODEL_PY="$stub" MODEL_DIR="$root/only-this" MODEL_DOWNLOAD=0
  export MODEL_REPO=repo MODEL_REVISION=rev MODEL_DOWNLOAD_WORKERS=2
  rc=0
  out="$(ensure_model_dir 2>/tmp/redsnow-model.err)" || rc=$?
  [[ "$rc" -eq 2 ]] || exit 1
  [[ -z "$out" ]] || exit 1
  grep -q "not downloading" /tmp/redsnow-model.err || exit 1
  [[ ! -f /tmp/redsnow-model-downloaded ]] || exit 1
) || fail "download gate"
(
  export DOWNLOAD_MODEL_PY="$stub" MODEL_DIR="$root/ready" MODEL_DOWNLOAD=0
  export MODEL_REPO=repo MODEL_REVISION=rev MODEL_DOWNLOAD_WORKERS=2
  mkdir -p "$MODEL_DIR"
  printf ok >"$MODEL_DIR/.complete"
  rc=0
  out="$(ensure_model_dir 2>/tmp/redsnow-model.err)" || rc=$?
  [[ "$rc" -eq 0 && "$out" == "$root/ready" ]] || exit 1
  [[ ! -f /tmp/redsnow-model-downloaded ]] || exit 1
) || fail "gate still reads complete dir"
(
  export DOWNLOAD_MODEL_PY="$stub" MODEL_DIR="$root/fetch" MODEL_DOWNLOAD=1
  export MODEL_REPO=repo MODEL_REVISION=rev MODEL_DOWNLOAD_WORKERS=4
  rc=0
  out="$(ensure_model_dir 2>/tmp/redsnow-model.err)" || rc=$?
  [[ "$rc" -eq 0 && "$out" == "$root/fetch" ]] || exit 1
  [[ "$(cat /tmp/redsnow-model-downloaded)" == "$root/fetch" ]] || exit 1
) || fail "download into locked dir"
(
  unset MODEL_DIR
  export DOWNLOAD_MODEL_PY="$stub" MODEL_DOWNLOAD=1
  export MODEL_REPO=repo MODEL_REVISION=rev MODEL_DOWNLOAD_WORKERS=2
  rm -f /tmp/redsnow-model-downloaded
  rc=0
  ensure_model_dir >/tmp/redsnow-model.out 2>/tmp/redsnow-model.err || rc=$?
  [[ "$rc" -eq 2 ]] || exit 1
  grep -q "no mounted storage" /tmp/redsnow-model.err || exit 1
  [[ ! -f /tmp/redsnow-model-downloaded ]] || exit 1
) || fail "default path refuses overlay"
(
  export MODEL_DIR="$root/only-this" MODEL_DOWNLOAD=maybe
  rc=0
  ensure_model_dir >/dev/null 2>/tmp/redsnow-model.err || rc=$?
  [[ "$rc" -eq 1 ]] || exit 1
  grep -q "must be 0 or 1" /tmp/redsnow-model.err || exit 1
) || fail "bad download flag"
unset MODEL_DIR MODEL_DOWNLOAD

install_ssh_pubkey "ssh-ed25519 AAAA test" "$root/ssh/authorized_keys"
install_ssh_pubkey "ssh-ed25519 AAAA test" "$root/ssh/authorized_keys"
[[ "$(grep -c . "$root/ssh/authorized_keys")" == "1" ]] || fail "ssh key duplicated"
[[ "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$root/ssh/authorized_keys")" == "600" ]] || fail "ssh key mode"

mkdir -p "$root/fixssh"
printf 'ssh-ed25519 AAAA fix\n' >"$root/fixssh/authorized_keys"
chmod 777 "$root/fixssh"
chmod 666 "$root/fixssh/authorized_keys"
fix_root_ssh_perms "$root/fixssh"
[[ "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$root/fixssh")" == "700" ]] || fail "fix ssh dir mode"
[[ "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$root/fixssh/authorized_keys")" == "600" ]] || fail "fix ssh key mode"
fix_root_ssh_perms "$root/missing-ssh" || fail "missing ssh dir should return 0"

API_TOKEN=tok MODEL_DIR=/models SSH_PASSWORD=secret \
  publish_runtime_env "$root/environment" API_TOKEN MODEL_DIR
grep -qx 'API_TOKEN=tok' "$root/environment" || fail "published token"
grep -q 'SSH_PASSWORD' "$root/environment" && fail "published ssh password"
rm -rf "$root"

( unset API_TOKEN; main ) >/tmp/redsnow-token.out 2>/tmp/redsnow-token.err && fail "token should be required"
grep -q "API_TOKEN" /tmp/redsnow-token.err || fail "token error text"

# EasyTier: the stub easytier-core writes the ET_* it receives to a file; the stub easytier-cli supplies the virtual IP.
# env -i isolates the host environment so stale local ET_* / EASYTIER_* variables are not picked up.
et_dir=$(mktemp -d)
cat >"$et_dir/easytier-core" <<'EOF'
#!/bin/bash
env | grep '^ET_' | sort >"$ET_STUB_ENV"
EOF
cat >"$et_dir/easytier-cli" <<'EOF'
#!/bin/bash
printf '{"ipv4_addr": "10.144.144.7/24"}\n'
EOF
chmod +x "$et_dir/easytier-core" "$et_dir/easytier-cli"
# Arguments: TUN (1 has tun, 0 none), the ET_* output file, the rest are environment assignments.
run_easytier() {
  local tun="$1" out="$2"
  shift 2
  env -i PATH="$et_dir:/usr/bin:/bin" ET_STUB_ENV="$out" TUN="$tun" \
    EASYTIER_IP_FILE="$et_dir/ip" "$@" \
    "$BASH" -c 'source ./entrypoint.sh; have_tun() { [[ "$TUN" == 1 ]]; }; prepare_easytier && easytier-core'
}
has_line() { grep -qx -- "$2" "$1"; }

stale_ip="$et_dir/ip"
printf '10.144.144.99\n' >"$stale_ip"
rc=0
run_easytier 1 "$et_dir/none.env" 2>"$et_dir/none.err" || rc=$?
[[ "$rc" -ne 0 ]] || fail "none should not start"
[[ ! -e "$et_dir/none.env" ]] || fail "none started core"
[[ "$(grep -c . "$et_dir/none.err")" == 1 ]] || fail "none should log one line"
grep -q 'EasyTier not configured' "$et_dir/none.err" || fail "none text"
[[ ! -e "$stale_ip" ]] || fail "stale vip file kept"

rc=0
run_easytier 1 "$et_dir/half.env" EASYTIER_NETWORK_NAME=onlyname 2>"$et_dir/half.err" || rc=$?
[[ "$rc" -ne 0 ]] || fail "half should not start"
[[ ! -e "$et_dir/half.env" ]] || fail "half started core"
grep -q 'warn' "$et_dir/half.err" || fail "half should warn"

run_easytier 0 "$et_dir/full.env" EASYTIER_NETWORK_NAME=net EASYTIER_NETWORK_SECRET=UNIQUESECRET \
  EASYTIER_PEERS='tcp://a:11010,udp://b:11010' 2>"$et_dir/full.err" || fail "full config should start"
has_line "$et_dir/full.env" 'ET_NETWORK_NAME=net' || fail "network name mapped"
has_line "$et_dir/full.env" 'ET_NETWORK_SECRET=UNIQUESECRET' || fail "network secret mapped"
has_line "$et_dir/full.env" 'ET_HOSTNAME=redsnow' || fail "default hostname"
has_line "$et_dir/full.env" 'ET_CONSOLE_LOG_LEVEL=error' || fail "console log level"
has_line "$et_dir/full.env" 'ET_PRIVATE_MODE=true' || fail "default private mode"
has_line "$et_dir/full.env" 'ET_DHCP=true' || fail "dhcp without ipv4"
has_line "$et_dir/full.env" 'ET_NO_TUN=true' || fail "no tun"
has_line "$et_dir/full.env" 'ET_PEERS=tcp://a:11010,udp://b:11010' || fail "peers verbatim"
grep -q '^ET_IPV4=' "$et_dir/full.env" && fail "ipv4 should be unset"
grep -q UNIQUESECRET "$et_dir/full.err" && fail "secret leaked to log"

run_easytier 1 "$et_dir/ipv4.env" EASYTIER_NETWORK_NAME=net EASYTIER_NETWORK_SECRET=s \
  EASYTIER_IPV4=10.144.144.2/24 2>/dev/null || fail "ipv4 config should start"
has_line "$et_dir/ipv4.env" 'ET_IPV4=10.144.144.2/24' || fail "ipv4 mapped"
grep -q '^ET_DHCP=' "$et_dir/ipv4.env" && fail "dhcp with fixed ipv4"
grep -q '^ET_NO_TUN=' "$et_dir/ipv4.env" && fail "no-tun with tun"

run_easytier 1 "$et_dir/dhcp-tun.env" EASYTIER_NETWORK_NAME=net EASYTIER_NETWORK_SECRET=s \
  2>/dev/null || fail "tun dhcp should start"
has_line "$et_dir/dhcp-tun.env" 'ET_DHCP=true' || fail "dhcp with tun"

run_easytier 1 "$et_dir/private0.env" EASYTIER_NETWORK_NAME=net EASYTIER_NETWORK_SECRET=s \
  EASYTIER_PRIVATE_MODE=0 2>/dev/null || fail "private mode 0 should start"
has_line "$et_dir/private0.env" 'ET_PRIVATE_MODE=false' || fail "private mode 0 mapped"

vip="$(PATH="$et_dir:$PATH" easytier_vip)" || fail "easytier_vip failed"
[[ "$vip" == "10.144.144.7" ]] || fail "vip mask stripped: $vip"

# The resident watch runs in the background: a state file decides the virtual IP the stub easytier-cli prints; switch it step by step and assert the log and IP file follow.
watch_dir=$(mktemp -d)
cat >"$watch_dir/easytier-cli" <<EOF
#!/bin/bash
printf '{"ipv4_addr": "%s"}\n' "\$(cat "$watch_dir/state")"
EOF
chmod +x "$watch_dir/easytier-cli"
: >"$watch_dir/state"
watch_log="$watch_dir/watch.log"
PATH="$watch_dir:$PATH" EASYTIER_WATCH_INTERVAL=0.1 PROXY_PORT=8898 \
  EASYTIER_IP_FILE="$watch_dir/ip" watch_easytier_vip 2>"$watch_log" &
watch_pid=$!
# Poll until a line appears in the log, ~10 s timeout; on timeout kill the background process before failing so the test does not hang.
wait_log() {
  local i
  for i in $(seq 1 100); do
    grep -q -- "$1" "$watch_log" && return 0
    sleep 0.1
  done
  kill "$watch_pid" 2>/dev/null || true
  fail "watch: no '$1'"
}
printf '10.144.144.7/24' >"$watch_dir/state"
wait_log 'Virtual IP  10.144.144.7'
[[ "$(cat "$watch_dir/ip")" == "10.144.144.7" ]] || fail "vip file 7"
grep -q 'http://10.144.144.7:8898/v1' "$watch_log" || fail "vip banner access"
printf '10.144.144.8/24' >"$watch_dir/state"
wait_log 'Virtual IP  10.144.144.8'
[[ "$(cat "$watch_dir/ip")" == "10.144.144.8" ]] || fail "vip file 8"
: >"$watch_dir/state"
wait_log 'virtual IP lost'
[[ ! -e "$watch_dir/ip" ]] || fail "vip file kept after loss"
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
[[ "$(grep -c 'EasyTier joined' "$watch_log")" == 2 ]] || fail "two banners"
# The startup log must list peers when configured. nohup is stubbed to look at the log only; watch is stubbed too to avoid the background loop.
start_out="$(env -i PATH=/usr/bin:/bin EASYTIER_PEERS='tcp://a:11010,udp://b:11010' "$BASH" -c \
  'source ./entrypoint.sh; nohup() { :; }; watch_easytier_vip() { :; }; start_easytier' 2>&1)" || fail "start_easytier"
grep -q 'peer: tcp://a:11010,udp://b:11010' <<<"$start_out" || fail "start log lists peers"

printf '10.144.144.7\n' >"$et_dir/ip"
conn_out="$(EASYTIER_IP_FILE="$et_dir/ip" PROXY_PORT=8898 CACHE_SIZE=262144 MAX_ACTIVE_REQUESTS=1 \
  TUNNEL_URL_FILE="$et_dir/no-url" connect_lines)"
grep -q 'EasyTier  http://10.144.144.7:8898/v1' <<<"$conn_out" || fail "connect lines easytier"
grep -q 'Slots     1 concurrent request(s)' <<<"$conn_out" || fail "connect lines concurrency"

for bad_peers in 'http://x:1' 'tcp://x' 'tcp://a:1,, udp://b:2'; do
  (
    API_TOKEN=tok EASYTIER_PEERS="$bad_peers"
    rc=0
    (main) >/dev/null 2>"$et_dir/peer.err" || rc=$?
    [[ "$rc" -eq 1 ]] && grep -q 'EASYTIER_PEERS' "$et_dir/peer.err"
  ) || fail "bad peer rejected: $bad_peers"
done
(
  API_TOKEN=tok EASYTIER_PRIVATE_MODE=2
  rc=0
  (main) >/dev/null 2>"$et_dir/pm.err" || rc=$?
  [[ "$rc" -eq 1 ]] && grep -q 'EASYTIER_PRIVATE_MODE' "$et_dir/pm.err"
) || fail "private mode validation"
(
  API_TOKEN=tok MAX_ACTIVE_REQUESTS=abc
  rc=0
  (main) >/dev/null 2>"$et_dir/max.err" || rc=$?
  [[ "$rc" -eq 1 ]] && grep -q 'MAX_ACTIVE_REQUESTS' "$et_dir/max.err"
) || fail "max active requests validation"
(
  # Give private mode an invalid value so main exits right after the warning.
  API_TOKEN=tok MAX_ACTIVE_REQUESTS=2 EASYTIER_PRIVATE_MODE=2
  (main) >/dev/null 2>"$et_dir/slots.err" || true
  grep -q 'warn: MAX_ACTIVE_REQUESTS=2 with CACHE_SIZE=262144' "$et_dir/slots.err"
  CACHE_SIZE=131072
  (main) >/dev/null 2>"$et_dir/slots2.err" || true
  ! grep -q 'warn: MAX_ACTIVE_REQUESTS' "$et_dir/slots2.err"
) || fail "multi-slot cache warning"
grep -q 'MAX_ACTIVE_REQUESTS="${MAX_ACTIVE_REQUESTS:-1}"' entrypoint.sh || fail "max active default"
grep -q -- '--max-active-requests "${MAX_ACTIVE_REQUESTS}" -ambs "${MAX_ACTIVE_REQUESTS}"' entrypoint.sh || fail "max active serve args"
if grep -Eq '[$][{]?ET_' entrypoint.sh; then fail "reads user ET_ variables"; fi
rm -rf "$et_dir"

valid_permit_open "127.0.0.1:8898" || fail "permit local"
valid_permit_open "10.144.144.2:1" || fail "permit overlay"
valid_permit_open "[::1]:8898" || fail "permit v6"
if valid_permit_open "0.0.0.0:8898"; then fail "permit any"; fi
if valid_permit_open "127.0.0.1:0"; then fail "permit port 0"; fi
if valid_ssh_user root; then fail "root user"; fi
valid_ssh_user tunnel || fail "tunnel user"

(
  unset SSH_PASSWORD SSH_USER SSH_USER_PUBLIC_KEY SSH_TUNNELS
  rc=0
  tunnel_sshd_block >/tmp/redsnow-tunnel.out 2>/tmp/redsnow-tunnel.err || rc=$?
  [[ "$rc" -eq 1 ]] || fail "tunnel absent rc=$rc"
  [[ ! -s /tmp/redsnow-tunnel.err ]] || fail "tunnel absent should be quiet"
) || fail "tunnel absent"

(
  SSH_USER=tunnel
  unset SSH_PASSWORD SSH_USER_PUBLIC_KEY SSH_TUNNELS
  rc=0
  tunnel_sshd_block >/tmp/redsnow-tunnel.out 2>/tmp/redsnow-tunnel.err || rc=$?
  [[ "$rc" -eq 1 ]] || fail "tunnel half rc=$rc"
  grep -q "SSH_PASSWORD" /tmp/redsnow-tunnel.err || fail "tunnel half text"
) || fail "tunnel half"

(
  SSH_USER=root SSH_PASSWORD='correct-horse-battery'
  unset SSH_USER_PUBLIC_KEY SSH_TUNNELS
  rc=0
  tunnel_sshd_block >/tmp/redsnow-tunnel.out 2>/tmp/redsnow-tunnel.err || rc=$?
  [[ "$rc" -eq 2 ]] || fail "root tunnel rc=$rc"
) || fail "root tunnel"

(
  SSH_PASSWORD=$'correct-horse\nbattery' SSH_USER=tunnel
  unset SSH_USER_PUBLIC_KEY SSH_TUNNELS
  rc=0
  tunnel_sshd_block >/tmp/redsnow-tunnel.out 2>/tmp/redsnow-tunnel.err || rc=$?
  [[ "$rc" -eq 2 ]] || fail "newline password rc=$rc"
) || fail "newline password"

(
  SSH_USER=tunnel SSH_PASSWORD='correct-horse-battery' PROXY_PORT=8898
  unset SSH_USER_PUBLIC_KEY SSH_TUNNELS
  block="$(tunnel_sshd_block)"
  [[ "$block" != *correct-horse-battery* ]] || fail "password leaked into sshd"
  grep -q "Match User tunnel" <<<"$block" || fail "match user"
  grep -q "PasswordAuthentication yes" <<<"$block" || fail "password auth"
  grep -q "AllowTcpForwarding local" <<<"$block" || fail "local forward"
  if grep -q "ForceCommand" <<<"$block"; then fail "tunnel should have a shell"; fi
  grep -q "PermitOpen 127.0.0.1:8898" <<<"$block" || fail "default open"
  sudo_file="$(mktemp -d)/redsnow-tunnel"
  install_sudoers tunnel "$sudo_file"
  grep -qx 'tunnel ALL=(ALL) NOPASSWD:ALL' "$sudo_file" || fail "sudoers"
  [[ "$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$sudo_file")" == "440" ]] || fail "sudoers mode"
  cfg="$(mktemp -d)/sshd_config"
  printf 'PasswordAuthentication no\n' >"$cfg"
  upsert_sshd_tunnel "$cfg" "$block"
  upsert_sshd_tunnel "$cfg" "$block"
  [[ "$(grep -c redsnow-tunnel-begin "$cfg")" == "1" ]] || fail "tunnel block duplicated"
  upsert_sshd_tunnel "$cfg" ""
  if grep -q redsnow-tunnel-begin "$cfg"; then fail "tunnel block remained"; fi
  grep -qx "PasswordAuthentication no" "$cfg" || fail "global password auth changed"
) || fail "tunnel password"

(
  SSH_USER=jumper SSH_USER_PUBLIC_KEY="ssh-ed25519 AAAA jumper"
  SSH_TUNNELS='127.0.0.1:8898, 10.144.144.2:8898'
  unset SSH_PASSWORD
  block="$(tunnel_sshd_block 2>/tmp/redsnow-tunnel.err)"
  if grep -q "PasswordAuthentication yes" <<<"$block"; then fail "key-only password auth"; fi
  grep -q "PasswordAuthentication no" <<<"$block" || fail "key-only keeps password off"
  grep -q "Match User jumper" <<<"$block" || fail "custom user"
  grep -q "PermitOpen 127.0.0.1:8898" <<<"$block" || fail "custom open 1"
  grep -q "PermitOpen 10.144.144.2:8898" <<<"$block" || fail "custom open 2"
  if grep -q "AAAA jumper" <<<"$block"; then fail "pubkey copied into sshd"; fi
) || fail "tunnel key"

(
  SSH_PASSWORD='correct-horse-battery' SSH_USER=tunnel
  unset SSH_USER_PUBLIC_KEY
  targets=""
  for n in $(seq 1 17); do
    targets+="127.0.0.1:${n},"
  done
  SSH_TUNNELS="$targets"
  rc=0
  tunnel_sshd_block >/tmp/redsnow-tunnel.out 2>/tmp/redsnow-tunnel.err || rc=$?
  [[ "$rc" -eq 2 ]] || fail "too many tunnels rc=$rc"
  grep -q "16" /tmp/redsnow-tunnel.err || fail "too many text"
) || fail "too many tunnels"

sshd_at=$(awk '/^main\(\)/{p=1} p && /start_sshd_daemon/{print NR; exit}' entrypoint.sh)
model_at=$(awk '/^main\(\)/{p=1} p && /ensure_model_dir/{print NR; exit}' entrypoint.sh)
cuda_at=$(awk '/^main\(\)/{p=1} p && /read_free_gib/{print NR; exit}' entrypoint.sh)
net_at=$(awk '/^main\(\)/{p=1} p && /start_easytier/{print NR; exit}' entrypoint.sh)
serve_at=$(awk '/^main\(\)/{p=1} p && /serve_glm.py/{print NR; exit}' entrypoint.sh)
[[ -n "$sshd_at" && -n "$model_at" && -n "$cuda_at" && -n "$net_at" && -n "$serve_at" ]] || fail "startup markers"
[[ "$sshd_at" -lt "$model_at" && "$model_at" -lt "$cuda_at" && "$cuda_at" -lt "$serve_at" ]] || fail "startup order"
[[ "$net_at" -lt "$serve_at" ]] || fail "easytier before serve"
grep -q 'start_auth_proxy 0.0.0.0' entrypoint.sh || fail "proxy bind"
if grep -q 'start_auth_proxy 127.0.0.1' entrypoint.sh; then fail "proxy still loopback only"; fi
grep -q '071adefe6c1c8de379d76977985811b7d4385454' entrypoint.sh || fail "revision pin"
main_body=$(awk '/^main\(\)/,/^}/' entrypoint.sh)
if grep -Eq 'start_tailscale|start_wireguard|TS_AUTHKEY|WG_|tailscaled' <<<"$main_body"; then
  fail "ablation leftover in main"
fi
if grep -q SSH_PASSWORD <<<"$main_body"; then fail "password published from main"; fi
if grep -Eq 'tailscale|wireguard' Dockerfile; then fail "ablation leftover in image"; fi
grep -q 'pypi.org/simple' Dockerfile || fail "pypi index"
grep -q 'HF_ENDPOINT=https://huggingface.co' Dockerfile || fail "hf endpoint"
grep -q 'ssh-keygen -A' entrypoint.sh || fail "host keys at start"
if grep -q 'ssh-keygen -A' Dockerfile; then fail "host keys baked into image"; fi
grep -q '/usr/share/licenses/easytier/LICENSE' Dockerfile || fail "easytier license"
grep -q '/usr/share/licenses/easytier/GPL-3.0.txt' Dockerfile || fail "gpl text"
grep -q '/usr/share/licenses/redsnow-server/LICENSE' Dockerfile || fail "server license"
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' licenses/easytier-v2.6.4-LICENSE || fail "lgpl body"
grep -q 'GNU GENERAL PUBLIC LICENSE' licenses/GPL-3.0.txt || fail "gpl body"
grep -q 'download_model.py' Dockerfile || fail "download script in image"
grep -q 'huggingface_hub\[hf_xet\]>=0.32' Dockerfile || fail "hub pin"
grep -q '^EXPOSE 22 8898$' Dockerfile || fail "expose"
grep -q 'EXL3_UMA=1' Dockerfile || fail "uma default"
grep -q 'ClientAliveInterval' Dockerfile || fail "sshd keepalive"
grep -q '/usr/share/licenses/nv-monitor/LICENSE' Dockerfile || fail "nv-monitor license"
grep -q 'ARG DGXTOP_SHA256=[0-9a-f]\{64\}$' Dockerfile || fail "dgxtop sha256 pin"
grep -q 'DGXTOP_SHA256}  /tmp/dgxtop.tar.gz" | sha256sum -c -' Dockerfile || fail "dgxtop sha256 check"
grep -q '/usr/share/licenses/dgxtop/LICENSE' Dockerfile || fail "dgxtop license"
grep -q 'useradd --create-home --shell /bin/bash --user-group tunnel' Dockerfile || fail "builtin user"
grep -q 'tunnel ALL=(ALL) NOPASSWD:ALL' Dockerfile || fail "builtin sudo"
user_line=$(awk '/useradd --create-home/{print NR; exit}' Dockerfile)
pip_line=$(awk '/pip install/{print NR; exit}' Dockerfile)
copy_line=$(awk '/COPY auth_proxy.py/{print NR; exit}' Dockerfile)
ver_line=$(awk '/^ENV IMAGE_VERSION=/{print NR; exit}' Dockerfile)
[[ -n "$user_line" && -n "$pip_line" && -n "$copy_line" && -n "$ver_line" ]] || fail "layer markers"
[[ "$user_line" -lt "$pip_line" && "$pip_line" -lt "$copy_line" && "$copy_line" -lt "$ver_line" ]] || fail "layer order"
if awk -v cut="$copy_line" 'NR < cut && /IMAGE_VERSION/' Dockerfile | grep -q .; then
  fail "version busts lower layers"
fi
PUBLIC_IPADDR=1.2.3.4 VAST_TCP_PORT_22=50983 VAST_TCP_PORT_8898=33526 PROXY_PORT=8898 \
  log_vast_access >/tmp/redsnow-vast.out 2>/tmp/redsnow-vast.err
grep -q 'ssh -p 50983 root@1.2.3.4' /tmp/redsnow-vast.err || fail "vast ssh"
grep -q 'http://1.2.3.4:33526' /tmp/redsnow-vast.err || fail "vast api"
if grep -q 'SSH_PASSWORD' /tmp/redsnow-vast.err; then fail "vast log leaked password"; fi
( unset PUBLIC_IPADDR VAST_TCP_PORT_22 VAST_TCP_PORT_8898
  log_vast_access >/tmp/redsnow-vast.out 2>/tmp/redsnow-vast.err
  [[ ! -s /tmp/redsnow-vast.err ]] ) || fail "vast quiet off platform"
if grep -q NGC_API_KEY .github/workflows/ci.yml .github/workflows/release.yml; then
  fail "ngc key still required"
fi
if grep -q 'nvcc' Dockerfile; then fail "app image still compiles"; fi
if grep -q 'pip install -e' Dockerfile; then fail "editable install"; fi
if grep -q 'MAX_JOBS' Dockerfile; then fail "app compile jobs"; fi
app_base=$(grep -E '^ARG BASE_IMAGE=' Dockerfile)
kernel_base=$(grep -E '^ARG BASE_IMAGE=' Dockerfile.kernels)
[[ -n "$app_base" && "$app_base" == "$kernel_base" ]] || fail "base image pin"
grep -q 'MAX_JOBS=2' Dockerfile.kernels || fail "kernel jobs"
grep -q 'TORCH_CUDA_ARCH_LIST=12.1' Dockerfile.kernels || fail "kernel arch"
if grep -q 'ubuntu-24.04-arm' .github/workflows/ci.yml; then fail "ci still builds on arm"; fi

(
  VISION=1 MAX_IMAGE_TOKENS=
  vision_serve_args
  [[ "${VISION_ARGS[*]}" == "--vision" ]] || fail "vision default"
)
(
  VISION=0 MAX_IMAGE_TOKENS=
  vision_serve_args
  [[ "${#VISION_ARGS[@]}" -eq 0 ]] || fail "vision off"
)
(
  VISION=1 MAX_IMAGE_TOKENS=4096
  vision_serve_args
  [[ "${VISION_ARGS[*]}" == "--vision --max-image-tokens 4096" ]] || fail "max image tokens"
)
(
  API_TOKEN=tok VISION=maybe
  rc=0
  (main) >/tmp/redsnow-vision.out 2>/tmp/redsnow-vision.err || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad VISION rc=$rc"
  grep -q "VISION" /tmp/redsnow-vision.err || fail "bad VISION text"
) || fail "vision flag"
(
  API_TOKEN=tok VISION=1 MAX_IMAGE_TOKENS=0
  rc=0
  (main) >/tmp/redsnow-vision.out 2>/tmp/redsnow-vision.err || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad MAX_IMAGE_TOKENS rc=$rc"
  grep -q "MAX_IMAGE_TOKENS" /tmp/redsnow-vision.err || fail "bad MAX_IMAGE_TOKENS text"
) || fail "max image tokens validation"

grep -q 'ARG CLOUDFLARED_SHA256=[0-9a-f]\{64\}$' Dockerfile || fail "cloudflared sha256 pin"
grep -q 'CLOUDFLARED_SHA256}  /usr/local/bin/cloudflared" | sha256sum -c -' Dockerfile || fail "cloudflared sha256 check"
grep -q '/usr/share/licenses/cloudflared/LICENSE' Dockerfile || fail "cloudflared license path"
grep -q 'Apache License' licenses/cloudflared-2026.9.3-LICENSE || fail "cloudflared license body"

(
  API_TOKEN=tok CF_TUNNEL=yes
  rc=0
  (main) >/tmp/redsnow-cf.out 2>/tmp/redsnow-cf.err || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad CF_TUNNEL rc=$rc"
  grep -q "CF_TUNNEL" /tmp/redsnow-cf.err || fail "bad CF_TUNNEL text"
) || fail "cf tunnel flag"

cf_dir=$(mktemp -d)
cat >"$cf_dir/cloudflared" <<'EOF'
#!/bin/bash
printf 'TUNNEL_TOKEN=%s\n' "${TUNNEL_TOKEN:-}" >>"$CF_STUB_ENV"
printf '%s\n' "$*" >>"$CF_STUB_ARGS"
echo "https://quiet-stub-words.trycloudflare.com" >&2
EOF
chmod +x "$cf_dir/cloudflared"
(
  CF_TUNNEL=0 PROXY_PORT=8898
  export CF_STUB_ARGS="$cf_dir/off-args" CF_STUB_ENV="$cf_dir/off-env"
  unset CF_TUNNEL_TOKEN
  export PATH="$cf_dir:$PATH" TUNNEL_URL_FILE="$cf_dir/off-url"
  start_cloudflared
  [[ ! -e "$cf_dir/off-args" && ! -e "$cf_dir/off-url" ]] || exit 1
) || fail "cf tunnel off"
(
  CF_TUNNEL=1 PROXY_PORT=8898
  export CF_STUB_ARGS="$cf_dir/anon-args" CF_STUB_ENV="$cf_dir/anon-env"
  unset CF_TUNNEL_TOKEN
  export PATH="$cf_dir:$PATH" TUNNEL_URL_FILE="$cf_dir/anon-url"
  start_cloudflared
  for _ in $(seq 1 50); do [[ -s "$cf_dir/anon-url" ]] && break; sleep 0.1; done
  grep -q -- '--url http://127.0.0.1:8898' "$cf_dir/anon-args" || exit 1
  grep -qx 'https://quiet-stub-words.trycloudflare.com' "$cf_dir/anon-url" || exit 1
) || fail "cf anonymous tunnel"
(
  CF_TUNNEL=1 PROXY_PORT=8898 CF_TUNNEL_TOKEN=named-token-value-123
  export CF_STUB_ARGS="$cf_dir/named-args" CF_STUB_ENV="$cf_dir/named-env"
  export PATH="$cf_dir:$PATH" TUNNEL_URL_FILE="$cf_dir/named-url"
  start_cloudflared
  for _ in $(seq 1 50); do [[ -s "$cf_dir/named-args" ]] && break; sleep 0.1; done
  grep -qx 'tunnel --no-autoupdate run' "$cf_dir/named-args" || exit 1
  if grep -q 'named-token-value-123' "$cf_dir/named-args"; then exit 1; fi
  if grep -q -- '--url' "$cf_dir/named-args"; then exit 1; fi
  grep -qx 'TUNNEL_TOKEN=named-token-value-123' "$cf_dir/named-env" || exit 1
) || fail "cf named tunnel"
rm -rf "$cf_dir"

serve_out=$(printf '%s\n' \
  '{"request_id":"chatcmpl-d39e","finish_reason":"stop","usage":{"prompt_tokens":188,"completion_tokens":88,"total_tokens":276,"decode_tok_s":31.09,"draft_accept":0.7571428571428571,"time_prefill":0.9676179885864258,"time_generate":2.8301398754119873,"time_enqueued":0.001661539077758789}}' \
  | format_serve_output 2>&1)
grep -q 'in 188 tok' <<<"$serve_out" || fail "usage prompt tokens"
grep -q 'decode 31.1 tok/s' <<<"$serve_out" || fail "usage decode rate"
grep -q 'MTP accept 76%' <<<"$serve_out" || fail "usage mtp accept"
grep -q 'prefill 0.97 s (194 tok/s)' <<<"$serve_out" || fail "usage prefill rate"

mixed_out=$(printf '%s\n' \
  ' -- Mixed-K experts in model.language_model.layers.31.mlp: dense per-expert path' \
  ' -- Mixed-K experts in model.language_model.layers.30.mlp: dense per-expert path' \
  ' -- Mixed-K fused groups in model.language_model.layers.30.mlp' \
  | format_serve_output 2>&1)
if grep -q 'layers.31\|layer 31' <<<"$mixed_out"; then fail "layer 31 should be dropped"; fi
grep -q 'loading weights layer 30' <<<"$mixed_out" || fail "layer 30 progress"
if grep -q 'Mixed-K' <<<"$mixed_out"; then fail "mixed-k noise leaked"; fi
health_out=$(printf '%s\n' '127.0.0.1 "GET /health HTTP/1.1" 200 -' '127.0.0.1 "GET /metrics HTTP/1.1" 200 -' '127.0.0.1 "GET /v1/models HTTP/1.1" 200 -' \
  | format_serve_output 2>&1)
if grep -q 'GET /health' <<<"$health_out"; then fail "upstream health access leaked"; fi
if grep -q 'GET /metrics' <<<"$health_out"; then fail "upstream metrics access leaked"; fi
grep -q 'GET /v1/models' <<<"$health_out" || fail "upstream access kept"

tunnel_dir=$(mktemp -d)
printf 'https://a-b.trycloudflare.com\n' >"$tunnel_dir/url"
ready_out=$(printf '%s\n' 'Native API listening 127.0.0.1:8899; max_active=1' \
  | (API_TOKEN=secret-xyz CACHE_SIZE=262144 MAX_ACTIVE_REQUESTS=1 VISION=1 CF_TUNNEL=1 CF_TUNNEL_TOKEN= \
     PUBLIC_IPADDR=1.2.3.4 VAST_TCP_PORT_8898=33526 \
     PROXY_PORT=8898 TUNNEL_URL_FILE="$tunnel_dir/url" format_serve_output) 2>&1)
grep -q 'Model ready: connection info' <<<"$ready_out" || fail "ready banner"
grep -q 'Base URL  https://a-b.trycloudflare.com/v1' <<<"$ready_out" || fail "ready base url"
grep -q 'Fallback  http://1.2.3.4:33526/v1' <<<"$ready_out" || fail "ready vast backup"
grep -q 'Model     RED-SNOW-5.3-FLASH-EXL3-2.49' <<<"$ready_out" || fail "ready model"
grep -q 'Context   262144 tok' <<<"$ready_out" || fail "ready context"
grep -q '229376' <<<"$ready_out" || fail "ready max_tokens threshold"
grep -q 'stream: true is required' <<<"$ready_out" || fail "ready tunnel stream"
grep -q 'images' <<<"$ready_out" || fail "ready vision"
grep -q 'curl -N https://a-b.trycloudflare.com/v1/chat/completions' <<<"$ready_out" || fail "ready curl example"
grep -q 'Authorization: Bearer <API_TOKEN>' <<<"$ready_out" || fail "ready auth line"
if grep -q 'secret-xyz' <<<"$ready_out"; then fail "api token leaked into log"; fi
rm -rf "$tunnel_dir"

vast_dir=$(mktemp -d)
vast_out=$(printf '%s\n' 'Native API listening 127.0.0.1:8899; max_active=1' \
  | (API_TOKEN=secret-xyz CACHE_SIZE=262144 MAX_ACTIVE_REQUESTS=1 CF_TUNNEL=0 \
     PUBLIC_IPADDR=1.2.3.4 VAST_TCP_PORT_8898=33526 \
     PROXY_PORT=8898 TUNNEL_URL_FILE="$vast_dir/none" format_serve_output) 2>&1)
grep -q 'Base URL  http://1.2.3.4:33526/v1' <<<"$vast_out" || fail "vast base url"
grep -q 'stream: true recommended' <<<"$vast_out" || fail "vast stream hint"
if grep -q 'Fallback' <<<"$vast_out"; then fail "vast-only should have no backup"; fi
vision_out=$(printf '%s\n' 'Native API listening 127.0.0.1:8899; max_active=1' \
  | (API_TOKEN=secret-xyz CACHE_SIZE=262144 MAX_ACTIVE_REQUESTS=1 VISION=0 CF_TUNNEL=0 \
     PUBLIC_IPADDR=1.2.3.4 VAST_TCP_PORT_8898=33526 \
     PROXY_PORT=8898 TUNNEL_URL_FILE="$vast_dir/none" format_serve_output) 2>&1)
if grep -q 'images' <<<"$vision_out"; then fail "vision off should not advertise images"; fi
rm -rf "$vast_dir"

[[ "$(grep -c 'RED-SNOW-5.3-FLASH-EXL3-2.49' entrypoint.sh)" == 1 ]] || fail "served model name defined once"
grep -q -- '--served-model-name "${SERVED_MODEL_NAME}"' entrypoint.sh || fail "served model name flag"

stub_dir=$(mktemp -d)
cat >"$stub_dir/nvidia-smi" <<'STUB'
#!/bin/bash
printf '95, 64, 42.15, 2177\n'
STUB
chmod +x "$stub_dir/nvidia-smi"
printf 'MemTotal:       127543204 kB\nMemAvailable:    9437184 kB\n' >"$stub_dir/meminfo"
metrics=$(PATH="$stub_dir:$PATH" MEMINFO="$stub_dir/meminfo" SERVE_PORT=1 \
  TUNNEL_URL_FILE="$stub_dir/no-url" metrics_line 2>/dev/null)
grep -q 'GPU 95%' <<<"$metrics" || fail "metrics gpu"
grep -q 'mem avail' <<<"$metrics" || fail "metrics memory"
grep -q 'inference not ready' <<<"$metrics" || fail "metrics not ready"
if grep -q 'public' <<<"$metrics"; then fail "metrics without url file"; fi
rm -rf "$stub_dir"

(
  API_TOKEN=tok METRICS_INTERVAL=abc
  rc=0
  (main) >/tmp/redsnow-metrics.out 2>/tmp/redsnow-metrics.err || rc=$?
  [[ "$rc" -eq 1 ]] || exit 1
  grep -q "METRICS_INTERVAL" /tmp/redsnow-metrics.err || exit 1
) || fail "metrics interval validation"

(
  API_TOKEN=tok LOG_MAX_MB=abc
  rc=0
  (main) >/dev/null 2>"$log_test_dir/lm.err" || rc=$?
  [[ "$rc" -eq 1 ]] && grep -q "LOG_MAX_MB" "$log_test_dir/lm.err"
) || fail "log max validation"

# With file logging on, main output goes through the sink: stdout and the log file both get the lines.
(
  API_TOKEN=tok METRICS_INTERVAL=abc LOG_MAX_MB=5 LOG_DIR="$log_test_dir/logs" LOG_SINK_PY="$PWD/log_sink.py"
  (main) >"$log_test_dir/sink.out" 2>&1 || true
  for _ in $(seq 1 50); do
    grep -q "METRICS_INTERVAL must" "$log_test_dir/logs/redsnow.log" 2>/dev/null && break
    sleep 0.1
  done
  grep -q "container start" "$log_test_dir/logs/redsnow.log" &&
    grep -q "METRICS_INTERVAL must" "$log_test_dir/logs/redsnow.log" &&
    grep -q "container start" "$log_test_dir/sink.out"
) || fail "file logging through sink"

# An unusable LOG_DIR only warns.
(
  : >"$log_test_dir/notdir"
  API_TOKEN=tok METRICS_INTERVAL=abc LOG_MAX_MB=5 LOG_DIR="$log_test_dir/notdir/x"
  (main) >/dev/null 2>"$log_test_dir/bad.err" || true
  grep -q "LOG_DIR" "$log_test_dir/bad.err" && grep -q "METRICS_INTERVAL must" "$log_test_dir/bad.err"
) || fail "unusable log dir falls back to stdout"

# The ready marker appears when inference prints Native API listening.
rm -f "$SERVE_READY_FILE"
(API_TOKEN=tok CACHE_SIZE=262144 MAX_ACTIVE_REQUESTS=1 VISION=1 CF_TUNNEL=0 \
  format_serve_output <<<'loading' >/dev/null 2>&1)
[[ ! -e "$SERVE_READY_FILE" ]] || fail "no marker before ready"
(API_TOKEN=tok CACHE_SIZE=262144 MAX_ACTIVE_REQUESTS=1 VISION=1 CF_TUNNEL=0 \
  format_serve_output <<<'Native API listening 127.0.0.1:8899; max_active=1' >/dev/null 2>&1)
[[ -e "$SERVE_READY_FILE" ]] || fail "marker after ready"

echo "entrypoint ok"
