#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./entrypoint.sh

fail() {
  echo "FAIL $*" >&2
  exit 1
}

[[ "$(choose_gpu_split "" 114)" == "112" ]] || fail "114 -> 112"
[[ "$(choose_gpu_split "" 112)" == "110" ]] || fail "112 -> 110"
[[ "$(choose_gpu_split "" 101)" == "99" ]] || fail "101 -> 99"
[[ "$(choose_gpu_split 110 114)" == "110" ]] || fail "explicit"
[[ -z "$(split_warning 110 262144)" ]] || fail "110 should not warn"
[[ -n "$(split_warning 99 262144)" ]] || fail "99 should warn"

root=$(mktemp -d)
mkdir -p "$root/vault/models/${MODEL_NAME}" "$root/workspace/models/${MODEL_NAME}" "$root/workspace"
touch "$root/vault/models/${MODEL_NAME}/tokenizer_config.json"
touch "$root/workspace/models/${MODEL_NAME}/tokenizer_config.json"
[[ "$(resolve_model_dir /opt/weights)" == "/opt/weights" ]] || fail "explicit model"
[[ "$(resolve_model_dir "" "$root/vault/models/${MODEL_NAME}" "$root/workspace/models/${MODEL_NAME}")" == "$root/vault/models/${MODEL_NAME}" ]] || fail "vault first"
[[ "$(resolve_model_dir "" "" "$root/missing" "$root/workspace/models/${MODEL_NAME}")" == "$root/workspace/models/${MODEL_NAME}" ]] || fail "workspace fallback"
if resolve_model_dir "" "$root/missing"; then fail "model should be missing"; fi

install_ssh_pubkey "ssh-ed25519 AAAA test" "$root/ssh/authorized_keys"
install_ssh_pubkey "ssh-ed25519 AAAA test" "$root/ssh/authorized_keys"
[[ "$(grep -c . "$root/ssh/authorized_keys")" == "1" ]] || fail "ssh key duplicated"
[[ "$(stat -f '%Lp' "$root/ssh/authorized_keys" 2>/dev/null || stat -c '%a' "$root/ssh/authorized_keys")" == "600" ]] || fail "ssh key mode"

API_TOKEN=tok MODEL_DIR=/models SSH_PASSWORD=secret \
  publish_runtime_env "$root/environment" API_TOKEN MODEL_DIR
grep -qx 'API_TOKEN=tok' "$root/environment" || fail "published token"
grep -q 'SSH_PASSWORD' "$root/environment" && fail "published ssh password"
rm -rf "$root"

( unset API_TOKEN; main ) >/tmp/redsnow-token.out 2>/tmp/redsnow-token.err && fail "token should be required"
grep -q "API_TOKEN" /tmp/redsnow-token.err || fail "token error text"

(
  ET_NETWORK_NAME=net ET_NETWORK_SECRET=UNIQUESECRET ET_ENABLE_EXIT_NODE=true ET_EXIT_NODES=10.0.0.9
  unset ET_IPV4 ET_DHCP ET_NO_TUN ET_HOSTNAME ET_DEV_NAME
  have_tun() { return 0; }
  prepare_easytier
  [[ "${ET_DHCP:-}" == "true" ]] || fail "dhcp"
  [[ -z "${ET_ENABLE_EXIT_NODE:-}" && -z "${ET_EXIT_NODES:-}" ]] || fail "exit node leaked"
  [[ "$ET_NETWORK_SECRET" == "UNIQUESECRET" ]] || fail "secret changed"
  [[ "$ET_DEV_NAME" == "ets0" ]] || fail "dev"
) || fail "easytier with tun"

(
  ET_NETWORK_NAME=net ET_NETWORK_SECRET=UNIQUESECRET ET_PEERS='tcp://a:11010,udp://b:11010'
  unset ET_IPV4 ET_DHCP ET_NO_TUN
  have_tun() { return 1; }
  prepare_easytier
  [[ "${ET_NO_TUN:-}" == "true" ]] || fail "no tun"
  [[ -z "${ET_DHCP:-}" ]] || fail "dhcp without tun"
  [[ "$ET_PEERS" == 'tcp://a:11010,udp://b:11010' ]] || fail "peers rewritten"
) || fail "easytier without tun"

(
  unset ET_NETWORK_NAME ET_NETWORK_SECRET
  if prepare_easytier; then fail "should not start"; fi
) || fail "easytier absent"

(
  ET_NETWORK_NAME=onlyname
  unset ET_NETWORK_SECRET
  if prepare_easytier; then fail "half should not start"; fi
) || fail "easytier half"

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
  [[ "$(stat -f '%Lp' "$sudo_file" 2>/dev/null || stat -c '%a' "$sudo_file")" == "440" ]] || fail "sudoers mode"
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
cuda_at=$(awk '/^main\(\)/{p=1} p && /read_free_gib/{print NR; exit}' entrypoint.sh)
net_at=$(awk '/^main\(\)/{p=1} p && /easytier-core/{print NR; exit}' entrypoint.sh)
serve_at=$(awk '/^main\(\)/{p=1} p && /serve_glm.py/{print NR; exit}' entrypoint.sh)
[[ -n "$sshd_at" && -n "$cuda_at" && -n "$net_at" && -n "$serve_at" ]] || fail "startup markers"
[[ "$sshd_at" -lt "$cuda_at" && "$net_at" -lt "$serve_at" && "$cuda_at" -lt "$serve_at" ]] || fail "startup order"
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

echo "entrypoint ok"
