# Deployment runbook

Order of work for a new or updated RED-SNOW instance on Vast.ai. Variable reference: [README](../README.md#environment-variables). Current status and open items: [handoff/HANDOFF.md](../handoff/HANDOFF.md).

## Prerequisites

- `vastai` CLI with an API key (`vastai set api-key <KEY>`).
- An account-level SSH key (Vast console -> Account -> SSH Keys). In ENTRYPOINT mode Vast injects only account keys as `SSH_PUBLIC_KEY`; keys attached to a single instance never reach the container.
- A positive account balance. With a negative balance Vast stops the instance (`intended_status=stopped`) without any message; the container log just ends mid-line.
- Optional: a domain on Cloudflare for a fixed URL.

## Generate secrets locally

```bash
mkdir -p ~/.redsnow && chmod 700 ~/.redsnow && cd ~/.redsnow
umask 077
python3 -c 'import secrets;print(secrets.token_urlsafe(32))' > api_token.txt   # API_TOKEN
python3 -c 'import secrets;print(secrets.token_urlsafe(32))' > ssh_password.txt # SSH_PASSWORD
python3 -c 'import secrets;print(secrets.token_urlsafe(32))' > et_secret.txt    # EASYTIER_NETWORK_SECRET
```

They stay outside the repository, readable only by you; never paste them into shared logs or chats. Values must not contain spaces.

## Fixed public URL with a Cloudflare named tunnel

Without this the quick tunnel URL is random and changes on every container restart.

1. Cloudflare Zero Trust -> Networks -> Tunnels -> Create a tunnel -> Cloudflared. Copy the token: this is `CF_TUNNEL_TOKEN` (a secret).
2. Add a public hostname (e.g. `redsnow.example.com`) with service type `HTTP`, URL `localhost:8898`. This is the auth proxy; never point it at 8899 (inference, no auth).
3. Pass `-e CF_TUNNEL_TOKEN=<token>` at create time.

Use one token per running machine: two connectors on one token load-balance requests between machines. The ready banner prints a placeholder (`https://<hostname configured in Cloudflare>/v1`) for named tunnels; use your own hostname.

## Choose an offer

Search GB10 (DGX Spark) offers. Some hosts get stuck at `docker_build() error writing dockerfile`; they cannot be told apart in the listing: destroy the instance if it is not running within 3 minutes (Loading is not billed).

## Create

```bash
vastai create instance <OFFER_ID> --image ghcr.io/xjoker/redsnow-exl3:<VERSION> --disk 150 \
  --env "-e API_TOKEN=<API_TOKEN> -e MODEL_DIR=/workspace/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw -p 22:22 -p 8898:8898" \
  --entrypoint /opt/redsnow/entrypoint.sh --args serve
```

- Use the CLI: the web form fails with `unknown flag --runtime`.
- `--entrypoint` and a non-empty `--args` are both required; without `--args` the instance is created in SSH mode (the content is ignored).
- `create --env` is a space-separated docker-style string, so values cannot contain spaces. Add more `-e NAME=value` there (`CF_TUNNEL_TOKEN`, `SSH_PASSWORD`, ...).
- EasyTier: add `-p 11010:11010 -p 11010:11010/udp` and `EASYTIER_NETWORK_NAME`/`EASYTIER_NETWORK_SECRET`.
- Without a mounted volume set `MODEL_DIR` under `/workspace`; the default `/models/...` must be a mount point or nothing is downloaded.

## Startup timeline

| Time | Event |
|---|---|
| ~20 s | Container running, sshd, auth proxy and tunnel up |
| ~6 min | Download of 97 GiB (skipped when the weights are on the disk) |
| ~3.5 min | Load into GPU memory |

The first request after load is slower (warm-up).

## Verify

- `vastai logs <INSTANCE_ID>` shows the `Model ready: connection info` banner.
- `GET /health` returns `image_version` and `git_commit` (should match the release you deployed).
- A streaming chat request answers (curl example is in the banner).
- `<Base URL without /v1>/dashboard` opens and accepts `API_TOKEN`.
- On the instance: `tail -F /workspace/logs/redsnow.log` (persistent copy of the container log).

Prometheus scrape example for `/metrics`:

```yaml
scrape_configs:
  - job_name: redsnow
    scheme: https
    metrics_path: /metrics
    authorization: {type: Bearer, credentials_file: /etc/prometheus/redsnow_token}
    static_configs:
      - targets: ['<tunnel host>']
```

## Connect opencode

Put the snippet from the [README](../README.md#connect) into `~/.config/opencode/opencode.json` and set `baseURL` to the banner's Base URL. When the tunnel URL changes, update `baseURL`. New opencode sessions pick it up; an already open session keeps the old URL and fails with `ECONNRESET` or `UNKNOWN_CERTIFICATE_VERIFICATION_ERROR` until opencode is restarted.

## Update an existing instance

```bash
vastai update instance <INSTANCE_ID> --image ghcr.io/xjoker/redsnow-exl3:<NEW_VERSION> --env '<JSON>'
vastai recycle instance <INSTANCE_ID>
```

- `update --env` takes a JSON object, not the docker-style string of `create`: `{"API_TOKEN": "<API_TOKEN>", "-p 8898:8898": "1"}`. On a parse error the CLI echoes the whole value, secrets included: build the JSON from the secret files and mask the output.
- `--image` without `--env` makes the console show no variables; the container still keeps them.
- `update --env` does not remove variables set at creation: they leave `extra_env` but the container keeps the old value. To drop one, set it to its default explicitly or recreate the instance.
- Recycle can still boot the OLD image even when `vastai show instance` reports the new `image_uuid`. Check the `container start, image <VERSION>` line in `vastai logs` (or `/health`) and recycle again if it shows the old version.

## Restart vs recycle

| | Restart | Recycle |
|---|---|---|
| Container disk (weights, `/workspace/logs`) | kept | recreated; weights may be downloaded again, logs and in-memory metrics history are gone |
| SSH port, tunnel URL | kept (quick tunnel URL changes anyway) | change |
| Tunnel user `authorized_keys` | kept | must be re-added |

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| 401 | Missing or wrong Bearer token; every path except `/dashboard` needs `Authorization: Bearer <API_TOKEN>` |
| 524 through Cloudflare | Non-streaming request over 100 s; use `stream: true` |
| 400 | Input plus `max_tokens` exceeds `CACHE_SIZE`, or `n>1`, or `logprobs` (unsupported) |
| 503 `out_of_memory` | Several long prompts prefilled at once; only that request fails, the service keeps running; retry |
| `ECONNRESET` / `UNKNOWN_CERTIFICATE_VERIFICATION_ERROR` in opencode | Old tunnel URL in an open session; update `baseURL`, restart opencode |
| No EasyTier IP | Check peers (public addresses, not `127.0.0.1`) and the shared secret; DHCP needs a second node |
| Root SSH denied | root accepts only account-level SSH keys; use the tunnel user (`SSH_PASSWORD`) then `sudo -i` |
| Dashboard disk numbers look wrong | They are `statvfs("/")`; after a recycle this is the host disk, not the 150 GB quota |
| Log ends mid-line, instance stopped | Negative account balance |
| Stuck at `docker_build() error writing dockerfile` | Bad host; destroy and pick another offer |

## Release

1. `date -u`, then set `VERSION` to today's UTC `YYYYMMDD.N` (same-day counter) and `ARG IMAGE_VERSION` in `Dockerfile` to the same value.
2. Commit and push, then run the manual `release.yml` workflow. Kernels are rebuilt only when `EXL3_REF` changes.
3. After deploying, compare `/health` `image_version`/`git_commit` with the release.
