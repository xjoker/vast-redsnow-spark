# Hand-off

For the next AI or engineer. Deployment steps, update, troubleshooting and release are in [docs/DEPLOY.md](../docs/DEPLOY.md); variables and connection details in [README.md](../README.md). This file records current status, verified findings, pitfalls not covered there and open items.

## Current status

Test hosts are named by hardware, not by marketplace ID: host A = GB10, kernel 6.17.0-1022, MemTotal 121.6 GiB; host B = GB10, kernel 6.17.0-1026, MemTotal 119.6 GiB.

- `main` == image `ghcr.io/xjoker/redsnow-exl3:20261012.3` (commit `56a08ed` and later docs commits). The 20261012.3 features (3 default slots, metrics history from startup, persistent logs) were verified on host A by hot-patching 20261012.2; the official 20261012.3 image has not yet been re-checked on a real machine. Base: exllamav3 vcruz305 fork `aa86ccd7` (rebased on upstream v1.6.1). Vast ENTRYPOINT mode (instance created by CLI) downloads and loads automatically and prints the connection banner for an AI when ready; the anonymous Cloudflare tunnel, EasyTier and periodic metrics are in the image.
- Verified on host A with 20261012.1: load 205 s; decode 32.6 tok/s weighted (previous version 31.8); prefill 707 tok/s at 200K and 699 tok/s at 250K, needle answered correctly; decode 28.7 tok/s at 250K. 4 slots with `CACHE_SIZE=131072 NUM_DRAFT_TOKENS=1`: 4x1K 34.8 tok/s aggregate, 4x32K passed 3/3 (previously OOM), 4x60K pass. Official openai SDK compatibility 17/17; vision OK. Host B (low MemTotal) was not re-tested on this version.
- New `/metrics` (Prometheus) and `/dashboard` (read-only page) are served by the auth proxy; verified on host A by hot-patching 20261012.1 before the 20261012.2 build: 401 without/with a wrong token, host/GPU/inference metrics present, and after a real request the prompt/completion/prefill/generation counters match `usage` exactly (prefill is settled up from `prompt_tokens - cached_tokens` at the end of each request, so short single-chunk prompts are counted too).
- 20261011.8-.10 on host A and host B both loaded on a cold start in one go, and the 17 compatibility checks passed (host B over Vast direct, host A over the tunnel).
- EasyTier two-node test: joins even when the loopback public peer among three is unreachable; after two nodes collided on DHCP one moved automatically; the other node's 8898 is reachable via the virtual IP (401 without token, OK with token); when all peers are dead EasyTier logs nothing, only the entrypoint warns once after 60 s.
- When the upstream generation thread hits OOM only the affected request returns 503 `out_of_memory` and the service stays healthy (reproduced on host B with an 8 GiB reserve).
- Container output is teed by `log_sink.py` (PID 1 re-execs its fds through it) into `LOG_DIR/redsnow.log` with rotation, `LOG_MAX_MB` total cap (default 3072; 64 MiB files); `vastai logs` still shows everything. Verified on host A (hot-patched): PID 1 fds go through the sink, the file holds cloudflared, auth proxy, banner and request lines, the exit line is written before a restart and the next boot appends to the same file; a 1 MiB cap rotates to two files totalling 806 KB. The inference output now goes straight into `format_serve_output` (no /tmp file); the page-cache dropper waits on `SERVE_READY_FILE`.
- 20261012.3 defaults to 3 slots at `CACHE_SIZE=262144`, `NUM_DRAFT_TOKENS=2`. On host A (20261012.2 with the slot override) 3x1K/3x32K/3x60K/3x80K all answered the needle with no OOM; per request ~11 tok/s decode and ~240 tok/s prefill (the slots split the single-stream throughput); lowest MemAvailable 7.99/5.83/4.70/3.25 GiB.
- The auth proxy records metrics history from startup (in memory, lost on restart) at `/metrics/history`; the dashboard seeds its charts from it. `redsnow_disk_*` is `statvfs("/")`: after a Vast recycle it reports the host disk (3.2 TB on host A), not the instance's disk quota.
- CI on `main` runs `tests/`; release steps are in docs/DEPLOY.md.

## Constraints (unchanged)

- Do not commit secrets, instance addresses or tokens; no force push; ask the user before `git push`, `docker push`, deleting instances or deleting files.
- Version is `YYYYMMDD.N`; run `date -u` before bumping.
- No vLLM / llama.cpp; weights stay out of the image; exllamav3 is pinned to `aa86ccd7...` (vcruz305 fork).
- The upstream server layer (Weschera repo, `SERVER_REF=b96fac22...`) is never edited in place: all changes live in `server.patch`, applied by the Dockerfile with `git apply` after cloning, touching only `protocol.py`, `serve_glm.py` and `worker.py`. A new `SERVER_REF` means redoing the patch.
- Repository docs, comments and log messages are in English.

## Verified findings

These are real measurements on a Vast DGX Spark (GB10), `NUM_DRAFT_TOKENS=2`, thinking off, taken on the exllamav3 version before the `aa86ccd7` upgrade unless noted; the new figures are under Current status.

**Prefill and decode**

| Prompt tokens | First token | Prefill tok/s | Needle |
|---|---|---|---|
| 12,144 | 21.9 s | 554 | OK |
| 48,523 | 74.8 s | 648 | OK |
| 99,047 | 148.5 s | 667 | OK |
| 200,687 | 299.5 s | 670 | OK |
| 249,761 | 378.4 s | 660 | OK |

- Prefill of ~660 tok/s is with the GPU at 96%; the prefix cache works: for the same 94K-token document the first token is 0.8 s from the second request on.
- Decode: 33-34 tok/s when writing code (MTP accept rate 0.86-0.89), 19-26 tok/s near 250K tokens.
- Concurrency slots default to 3 (`MAX_ACTIVE_REQUESTS`, since 20261012.3; previously 1). Total throughput stays 24-31 tok/s regardless of slots; with 4 slots a single request drops to 9-10 tok/s. With a 262K cache, 2 slots hit CUDA OOM from 2x60K and 4 slots from 4x32K; 4 slots with `CACHE_SIZE=131072`: 4x60K passes because the page pool staggers prefill, 4x32K was one pass and one fail (borderline); for short requests `NUM_DRAFT_TOKENS=1` gives 13-15 tok/s per request and ~30 tok/s total. OOM now only fails that request with 503 and the worker survives (`server.patch` changes worker.py). These OOM results predate the upgrade; see Current status for the 4-slot re-test.
- `NUM_DRAFT_TOKENS=3` is ~5% faster but the accept rate drops to 0.73-0.80, so 2 stays; prefill `chunk_size` 8192 causes `Generator drained`, so 4096 stays.
- The DFlash2 drafter (`incoai/GLM-5.3-Flash-DFlash2`, `-dm` instead of `--mtp`) was evaluated and not integrated. Same machine, same prompts (code, Chinese, JSON, reasoning, greedy and default sampling, 600 tokens), weighted decode: MTP draft 2 is 31.8 tok/s (accept 0.78); DFlash2 draft 3/5/7/7-dynamic gives 30.9/33.7/30.0/30.4 tok/s (accept 0.69/0.58/0.46/0.56). Best case only 6% faster, similar to MTP draft 3; it uses ~1.5-2 GiB more after loading, 2.2 GB more to download, license cc-by-nc-nd-4.0. The drafter was trained on the original GLM-5.3-Flash, so accept rate falls quickly with longer drafts on RED-SNOW; only short JSON output reaches 45-58 tok/s.

**Memory (vision, `MAX_IMAGE_TOKENS` 8000)**

| Test | Prompt tokens | Time | Result | Min MemAvailable |
|---|---|---|---|---|
| One 2400x1600 dense-text image | 5,188 | 13.7 s | correct | 6.82 GB |
| Same request, 3 large images | 15,179 | 31.1 s | all correct | 6.32 GB |
| 1 large image + ~250K-token needle | 254,763 | 390.5 s | both answers correct | 4.68 GB |

cgroup `memory.events` stayed at oom=0 throughout; the KV cache is allocated once at start from `CACHE_SIZE`. With vision loaded and idle `MemAvailable` is ~10 GB, GPU 68-79 C, no thermal throttling.

**opencode and context**

- opencode auto-compacts at ~229K (262144-32768); with `max_tokens` 32000, 17 turns reached 231,572 tokens with no 4xx.
- Two coding rounds took 52 s + 19 s with all tests passing; an image-reading task took 29 s and was correct; a 640x400 test image took ~5 s.
- The recommended `limit.context` 230000 / `limit.output` 32000 has **not** been verified on its own.

**Real task comparison (RED-SNOW vs Claude Sonnet)**

| Task | RED-SNOW | Sonnet |
|---|---|---|
| t1: single-model query endpoint | 276 s, tests pass, duplicated code | 42 s |
| t2: dgxtop into the image | 147 s, tests pass, Dockerfile lacks the curl download URL so the build would fail | 52 s, builds |

Conclusion: 3-6x slower and misses details; fine for it to write and a human to review.

**Deploy times**: with the image cached on the host the container is running in ~20 s; downloading 97 GiB takes ~6 min; loading ~3 min.

## Known pitfalls

- After an SSH-mode recycle `/root/.ssh/authorized_keys` was sometimes written with the host uid (128:988); the entrypoint changes it back to root (since 20261011.4).
- Vast injects `CONTAINER_RUNTIME=gvisor`, so `/proc/sys/vm/drop_caches` cannot be written; freshly downloaded weights hold ~88 GiB of page cache, and the image default `EXL3_UMA=1` (judge by `MemAvailable`) avoids load failures.
- Also GB10, but on kernel 6.17.0-1026 (host B) MemTotal is 119.63 GiB, 2 GiB less than host A on 1022. With the fork default `EXL3_UMA_RESERVE_MB=8192` the first load reported `Insufficient VRAM`, and after a restart the load succeeded but the first request OOMed on the MTP vocab mirror (1.18 GiB). The entrypoint now picks 6144 from MemTotal: 200K tokens and 60K tokens plus 3 images pass with min MemAvailable 2.5 GiB; with 5120 only 0.55 GiB was left and prefill also slowed.
- SSH uses the direct path, not `sshN.vast.ai`; the network path dropped once at the moment inference restarted and memory was released in bulk (sshd did not die).
- EasyTier is no-tun only: the container has no `/dev/net/tun` and no `CAP_NET_ADMIN`. Other nodes reach `PROXY_PORT` via the virtual IP only after this node gets one (DHCP or `EASYTIER_IPV4`); a node without a virtual IP only forwards. `EASYTIER_PEERS` must be publicly reachable addresses; `127.0.0.1` is useless.
- The anonymous tunnel allows at most 200 concurrent requests.
- The auth proxy must forward chunks with `read1`; `read` waits for 64 KiB, which holds back SSE (fixed, `c616b86`).
- The model card positions the model as an offensive-security model, and the security classifier interrupted work sessions several times (writing the large-image test script, reading server-layer response code, reproducing failures) for unknown reasons; the large-image tests were finally done with `handoff/scripts/mem_test.py`.

## Open items

- Re-check 20261012.3 on a real machine (3 slots, metrics history, persistent logs, `/dashboard`).
- opencode 2.0.26 logs the `reasoning` and `attachment` model keys as "omitted unsupported legacy setting": verify end to end whether reasoning output and image input still work, and adjust the README snippet if not.
- The named tunnel path (`CF_TUNNEL_TOKEN`) has not been run on a real machine.
- Optional: a `CF_TUNNEL_HOSTNAME`-style variable so the banner can print the real hostname instead of a placeholder.
- OpenAI gaps (as needed): `n>1`, `logprobs` (return 400, do not fake them), `/v1/completions`, `/v1/responses`. `response_format` has no constrained decoding.
- The opencode recommendation `limit.context 230000` is untested.

## handoff/scripts

Test and troubleshooting scripts, not in the image. All assume they run inside the instance container (hard-coded `/root/...` and `127.0.0.1:8899`); the Python scripts use only the standard library, except `compat.py`, `mem_test.py` and `vtest.py`, which also need Pillow, and `compat.py`, which also needs `openai`.

| Script | Purpose |
|---|---|
| `bench.py` | Benchmark: `--tests smoke,tool,ctx,conc`; smoke, tool calls, context sweep (prefill/decode speed + needle; the nominal `--ctx` yields ~1.5x tokens), concurrency (`--conc`); `--url` defaults to `http://127.0.0.1:8899`, add `--token` when going through the proxy |
| `prefix.py` | Ask about the same long document three times and see whether the 2nd and 3rd first-token times reuse the prefix cache; the argument is the document token count |
| `compat.py` | 17 compatibility checks with the official openai SDK: `compat.py <base_url> <api_key>` |
| `vtest.py` | Vision smoke test: draw an image locally, send it as an `image_url` data URI, once streaming and once not: `vtest.py [url] [token]` |
| `mem_test.py` | Memory boundary test, argument `A` (one large image), `A2` (three large images), `B` (vision + long context); each case prints one JSON line; `MEM_URL` overrides the address |
| `mem_driver.sh` | Runs A / A2 / B in turn, recording cgroup `memory.events` before and after each and probing liveness after each, stopping if the service is down; results go to `/root/mem_results.jsonl` and `/root/mem_events.log` |
| `capture.py` | Temporary capture proxy: listens on `127.0.0.1:8897`, logs request structure (long strings truncated) to `/root/capture.jsonl`, then forwards unchanged to 8899; shows what a client such as opencode actually sends |
| `vstart.sh` | Restart inference using the server layer in `/root/vserver` (bring your own) and `/root/redsnow.env`, so `server.patch` can be debugged without rebuilding the image; kills the entrypoint process first |
