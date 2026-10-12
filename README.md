# redsnow-spark

Docker image that serves RED-SNOW-5.3-Flash (GLM-5.3-Flash multimodal, 2.49bpw EXL3) on a single DGX Spark (GB10, linux/arm64, 128 GB unified memory). It runs the vcruz305 exllamav3 fork behind Weschera's OpenAI-compatible server (patched by `server.patch`) and adds a Bearer auth proxy, a Cloudflare quick tunnel and optional EasyTier. Context up to 262,144 tokens, tool calls, JSON output, image input.

Image: `ghcr.io/xjoker/redsnow-exl3:<VERSION>` (tag = `VERSION` file, `YYYYMMDD.N`: UTC date plus a same-day counter). The ~97 GiB of weights are not in the image; they are downloaded from Hugging Face at start. Only the auth proxy is public; inference listens on `127.0.0.1`.

## Quick start

Prerequisites, fixed URL, update and troubleshooting: [docs/DEPLOY.md](docs/DEPLOY.md).

1. Create the instance with the CLI in ENTRYPOINT mode (not the web form):
   ```bash
   vastai create instance <OFFER_ID> --image ghcr.io/xjoker/redsnow-exl3:<VERSION> --disk 150 \
     --env "-e API_TOKEN=<API_TOKEN> -e MODEL_DIR=/workspace/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw -p 22:22 -p 8898:8898" \
     --entrypoint /opt/redsnow/entrypoint.sh --args serve
   ```

2. Watch `vastai logs <INSTANCE_ID>`. Startup: ~20 s to proxy and tunnel, ~6 min download, ~3.5 min load.
3. When the `Model ready: connection info` banner appears, copy the block: base URL, model, limits, curl example (the token is never logged).
4. Open `<Base URL without /v1>/dashboard` and enter `API_TOKEN`.
5. Update later with `vastai update instance` + `vastai recycle instance` (see the runbook).

## Connect

- Base URL: your named Cloudflare tunnel hostname (fixed, set `CF_TUNNEL_TOKEN`), the quick tunnel `https://<random>.trycloudflare.com/v1` (random, changes on every restart, also in `/run/redsnow/tunnel_url`), or Vast direct `http://<PUBLIC_IPADDR>:<VAST_TCP_PORT_8898>/v1` (plain HTTP).
- Auth: `Authorization: Bearer <API_TOKEN>` on every path except the static `/dashboard` page (401 otherwise). `GET /health` returns `image_version` and `git_commit`.
- Model id: `RED-SNOW-5.3-FLASH-EXL3-2.49`. Endpoints: `GET /v1/models`, `POST /v1/chat/completions`.
- Always stream through Cloudflare: non-streaming requests over 100 s get 524.
- Context is `CACHE_SIZE` (default 262144); input plus `max_tokens` beyond it returns 400. Keep `max_tokens` at or below 32000 and compact long conversations on the client.

opencode (`~/.config/opencode/opencode.json`, `baseURL` from the banner; after a URL change see [Connect opencode](docs/DEPLOY.md#connect-opencode)):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "redsnow": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "RED-SNOW",
      "options": { "baseURL": "<BASE_URL>", "apiKey": "{env:API_TOKEN}" },
      "models": {
        "RED-SNOW-5.3-FLASH-EXL3-2.49": {
          "name": "RED-SNOW 5.3 Flash",
          "tool_call": true, "reasoning": true, "attachment": true,
          "modalities": { "input": ["text", "image"], "output": ["text"] },
          "limit": { "context": 230000, "output": 32000 }
        }
      }
    }
  },
  "model": "redsnow/RED-SNOW-5.3-FLASH-EXL3-2.49"
}
```

## Monitoring

- Logs: everything also goes to `vastai logs`; the persistent copy survives restarts: `tail -F /workspace/logs/redsnow.log` (3 GiB cap by default).
- `/dashboard`: read-only page; open `<Base URL without /v1>/dashboard` and enter `API_TOKEN`. The page itself holds no data; it polls `/metrics` every 2 s with the Bearer token (kept in sessionStorage).
- `/metrics/history`: Bearer required; JSON samples the proxy has recorded since container start (`?since=<unix ts>` for newer ones only), which the dashboard uses to draw its charts.
- `/metrics`: Prometheus text format (prefix `redsnow_`), Bearer required. `redsnow_upstream_up` 0 means inference is down and only host metrics remain. Scrape example: [docs/DEPLOY.md](docs/DEPLOY.md#verify).

## Environment variables

Only `API_TOKEN` is required. Everything else has a default; `.env.example` has the same list with comments.

| Variable | Default | Purpose |
|---|---|---|
| `API_TOKEN` | required | Bearer value of the auth proxy (never printed) |
| `MODEL_DIR` | `/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw` | The only model directory; the default must be a mount point |
| `MODEL_REPO` / `MODEL_REVISION` | `vcruz305/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw` / pinned commit | Hugging Face repo and revision to download |
| `MODEL_DOWNLOAD_WORKERS` | `8` | Files downloaded in parallel |
| `MODEL_DOWNLOAD` | `1` | `0`: never download; without a complete model inference is skipped while SSH and the proxy keep running |
| `CACHE_SIZE` | `262144` | KV cache and `--max-model-len` (tokens) |
| `NUM_DRAFT_TOKENS` | `2` | MTP draft tokens |
| `MAX_ACTIVE_REQUESTS` | `3` | Concurrent generation slots; they share the `CACHE_SIZE` pool and the total throughput. Above 3 use `CACHE_SIZE=131072 NUM_DRAFT_TOKENS=1` |
| `VISION` | `1` | `0` skips the vision tower; requests with images return 400 |
| `MAX_IMAGE_TOKENS` | processor default (8000) | Per-image token cap |
| `GPU_SPLIT_GB` | `112` | VRAM split (`-gs`), aligned with upstream `serve.sh` |
| `EXL3_UMA_RESERVE_MB` | auto | Memory kept for the system; 6144 is chosen automatically on ~119.6 GiB hosts (fork default 8192). Do not go below 6144 |
| `PROXY_PORT` / `SERVE_PORT` | `8898` / `8899` | Auth proxy (public, `0.0.0.0`) and inference (`127.0.0.1` only, no auth, never map it) |
| `PROXY_TIMEOUT` | `7200` | Proxy-to-inference timeout (seconds) |
| `CF_TUNNEL` | `1` | `0` disables the tunnel |
| `CF_TUNNEL_TOKEN` | empty | Secret. Switches to your named tunnel (fixed URL); see [docs/DEPLOY.md](docs/DEPLOY.md#fixed-public-url-with-a-cloudflare-named-tunnel) |
| `HISTORY_INTERVAL` | `5` | Seconds between samples the proxy records for the dashboard charts |
| `HISTORY_HOURS` | `24` | Hours of samples kept in memory (about 8 MB at the defaults) |
| `METRICS_INTERVAL` | `60` | Seconds between one-line metrics in the log, `0` disables |
| `LOG_DIR` | `/workspace/logs` | Directory for the persistent copy of the container log (`redsnow.log`, rotated) |
| `LOG_MAX_MB` | `3072` | Total size cap of the persistent log across rotated files, `0` disables it |
| `SSH_USER` / `SSH_PASSWORD` / `SSH_USER_PUBLIC_KEY` / `SSH_TUNNELS` | `tunnel` / empty | Tunnel user and allowed forward targets. root accepts public keys only, and on Vast only account-level SSH Keys |
| `EASYTIER_NETWORK_NAME` / `EASYTIER_NETWORK_SECRET` / `EASYTIER_PEERS` | empty | EasyTier starts only when name and secret are both set; no-tun mode, peers reach `PROXY_PORT` via the virtual IP |
| `EASYTIER_IPV4` / `EASYTIER_HOSTNAME` / `EASYTIER_PRIVATE_MODE` | empty (DHCP) / `redsnow` / `1` | Pinned virtual IP, node name, reject nodes with another secret |

## Measured performance

DGX Spark (GB10), exllamav3 fork aa86ccd7, thinking off.

| Test | Result |
|---|---|
| Single-stream decode (`NUM_DRAFT_TOKENS=2`) | ~32 tok/s |
| Prefill, 200K / 250K tokens | ~700 tok/s, needle test OK |
| 4 slots, `CACHE_SIZE=131072`, `NUM_DRAFT_TOKENS=1` | 4x1K: 34.8 tok/s aggregate; 4x32K and 4x60K pass |
| 3 slots (default), `CACHE_SIZE=262144`, 3x32K / 3x60K / 3x80K | pass, ~11 tok/s decode and ~240 tok/s prefill per request, lowest free memory 3.25 GiB |

## Limits

- Not supported: `n>1` and `logprobs` (400), `/v1/completions`, `/v1/responses`, `/v1/embeddings`.
- `response_format` (`json_object`, `json_schema`) is guided by a system instruction only; there is no constrained decoding, so valid JSON is not guaranteed.
- Several long prompts prefilling at once can run out of GPU memory; that request returns 503 `out_of_memory` and the server keeps running.

## Build and release

`Dockerfile.kernels` builds the exllamav3 sm_121 wheel on arm64; `Dockerfile` builds the app image (copies the wheel, applies `server.patch` to the pinned upstream server commit); `./build.sh` builds locally on arm64. Releases: see [Release](docs/DEPLOY.md#release). Tests: `bash tests/entrypoint_test.sh` and `python3 tests/test_*.py`.

## License and credits

Pinned third-party components: exllamav3 (MIT, vcruz305 fork), Weschera's OpenAI-compatible server, EasyTier (LGPL/GPL, texts in `/usr/share/licenses/`), cloudflared (Apache-2.0), nv-monitor (MIT), dgxtop.
