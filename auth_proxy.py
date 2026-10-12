#!/usr/bin/env python3
"""Bearer gate. The inference process listens on 127.0.0.1 only; this layer listens on 0.0.0.0 by default and requires API_TOKEN on every request."""

from __future__ import annotations

import hmac
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

UPSTREAM = os.environ["UPSTREAM"]
TOKEN = os.environ["API_TOKEN"]
ALLOWED = {
    "/health",
    "/v1/health",
    "/v1/models",
    "/models",
    "/v1/chat/completions",
    "/chat/completions",
}
HEALTH_PATHS = {"/health", "/v1/health"}
METRICS_PATH = "/metrics"
DASHBOARD_PATH = "/dashboard"
DASHBOARD_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.html")
# Paths polled by the dashboard and Prometheus; logging them would flood the access log.
QUIET_PATHS = HEALTH_PATHS | {METRICS_PATH, DASHBOARD_PATH}
CPU_MODES = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal")
GPU_QUERY = "utilization.gpu,temperature.gpu,power.draw,clocks.sm"
# nvidia-smi takes ~100 ms per call; the dashboard and Prometheus share one cached result.
GPU_CACHE_SECONDS = 2.0
_gpu_cache = {"at": 0.0, "lines": []}
_gpu_lock = threading.Lock()
MODEL_PREFIXES = ("/v1/models/", "/models/")
DROP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "authorization",
    "host",
    "content-length",
}


def authorized(header: str) -> bool:
    if not TOKEN:
        return False
    return hmac.compare_digest(header, f"Bearer {TOKEN}")


# Non-JSON-object upstream bodies (callers never get here on non-2xx) are returned as-is; we do not guess the upstream format.
def with_build_info(body: bytes) -> bytes:
    try:
        doc = json.loads(body)
    except ValueError:
        return body
    if not isinstance(doc, dict):
        return body
    doc["image_version"] = os.environ.get("IMAGE_VERSION") or "unknown"
    doc["git_commit"] = os.environ.get("GIT_COMMIT") or "unknown"
    return json.dumps(doc, ensure_ascii=False).encode()


def is_health_path(path: str) -> bool:
    return urlsplit(path).path in HEALTH_PATHS


def metric(name: str, kind: str, help_text: str, samples: list[tuple[str, object]]) -> str:
    out = f"# HELP {name} {help_text}\n# TYPE {name} {kind}\n"
    return out + "".join(f"{name}{labels} {value}\n" for labels, value in samples)


# One line of nvidia-smi --format=csv,noheader,nounits. Fields GB10 cannot read are [N/A]; the whole group is then omitted.
def gpu_metrics(csv: str) -> list[str]:
    fields = [f.strip() for f in csv.strip().splitlines()[0].split(",")] if csv.strip() else []
    try:
        util, temp, power, clock = int(fields[0]), int(fields[1]), float(fields[2]), int(fields[3])
    except (IndexError, ValueError):
        return []
    return [
        metric("redsnow_gpu_utilization_percent", "gauge", "GPU utilization.", [("", util)]),
        metric("redsnow_gpu_temperature_celsius", "gauge", "GPU temperature.", [("", temp)]),
        metric("redsnow_gpu_power_watts", "gauge", "GPU power draw.", [("", power)]),
        metric("redsnow_gpu_sm_clock_hertz", "gauge", "GPU SM clock.", [("", clock * 1_000_000)]),
    ]


def read_gpu() -> list[str]:
    with _gpu_lock:
        if time.monotonic() - _gpu_cache["at"] >= GPU_CACHE_SECONDS:
            try:
                out = subprocess.run(
                    ["nvidia-smi", f"--query-gpu={GPU_QUERY}", "--format=csv,noheader,nounits"],
                    capture_output=True, text=True, timeout=5, check=False,
                ).stdout
            except (OSError, subprocess.TimeoutExpired):
                out = ""
            _gpu_cache["lines"] = gpu_metrics(out)
            _gpu_cache["at"] = time.monotonic()
        return list(_gpu_cache["lines"])


def read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


# Metrics whose source file is unreadable are omitted rather than reported as 0.
def host_metrics(
    meminfo: str = "/proc/meminfo",
    stat: str = "/proc/stat",
    loadavg: str = "/proc/loadavg",
    cgroup: str = "/sys/fs/cgroup",
    clk_tck: int | None = None,
) -> list[str]:
    out = []
    mem = {}
    for line in (read_text(meminfo) or "").splitlines():
        key, _, rest = line.partition(":")
        if rest.strip().endswith(" kB"):
            mem[key] = int(rest.split()[0]) * 1024
    if "MemTotal" in mem:
        out.append(metric("redsnow_memory_total_bytes", "gauge", "Host MemTotal.", [("", mem["MemTotal"])]))
    if "MemAvailable" in mem:
        out.append(metric("redsnow_memory_available_bytes", "gauge",
                          "Host MemAvailable; GB10 GPU memory comes from the same pool.", [("", mem["MemAvailable"])]))
    first = (read_text(stat) or "").splitlines()[:1]
    if first and first[0].startswith("cpu "):
        ticks = first[0].split()[1:1 + len(CPU_MODES)]
        hz = clk_tck or os.sysconf("SC_CLK_TCK")
        out.append(metric("redsnow_cpu_seconds_total", "counter", "CPU time summed over all cores.",
                          [(f'{{mode="{mode}"}}', int(t) / hz) for mode, t in zip(CPU_MODES, ticks)]))
    load = (read_text(loadavg) or "").split()
    if load:
        out.append(metric("redsnow_load1", "gauge", "1-minute load average.", [("", float(load[0]))]))
    current = (read_text(os.path.join(cgroup, "memory.current")) or "").strip()
    if current.isdigit():
        out.append(metric("redsnow_cgroup_memory_current_bytes", "gauge", "Container cgroup memory.current.",
                          [("", int(current))]))
    for line in (read_text(os.path.join(cgroup, "memory.events")) or "").splitlines():
        key, _, value = line.partition(" ")
        if key == "oom_kill" and value.strip().isdigit():
            out.append(metric("redsnow_cgroup_oom_kills_total", "counter", "Container cgroup OOM kills.",
                              [("", int(value))]))
    try:
        disk = os.statvfs("/")
    except OSError:
        disk = None
    if disk is not None:
        out.append(metric("redsnow_disk_total_bytes", "gauge", "Root filesystem size.",
                          [("", disk.f_blocks * disk.f_frsize)]))
        out.append(metric("redsnow_disk_free_bytes", "gauge", "Root filesystem free space.",
                          [("", disk.f_bavail * disk.f_frsize)]))
    return out


def label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# If upstream /metrics is unreachable only the inference section is missing; host metrics are still emitted.
def metrics_text() -> str:
    parts = [
        metric("redsnow_build_info", "gauge", "Image build.", [(
            '{version="%s",git_commit="%s"}' % (
                label_value(os.environ.get("IMAGE_VERSION") or "unknown"),
                label_value(os.environ.get("GIT_COMMIT") or "unknown"),
            ), 1)]),
    ]
    parts += host_metrics()
    parts += read_gpu()
    try:
        with urllib.request.urlopen(UPSTREAM + METRICS_PATH, timeout=2) as upstream:
            inference = upstream.read().decode()
        up = 1
    except (urllib.error.URLError, OSError, UnicodeError):
        inference, up = "", 0
    parts.append(metric("redsnow_upstream_up", "gauge", "Inference server reachable.", [("", up)]))
    parts.append(inference)
    return "".join(parts)


def check_bind_host(host: str) -> str:
    if host in {"::", ""}:
        raise SystemExit(f"invalid auth proxy bind address: {host!r}")
    return host


def proxy_timeout() -> int:
    raw = os.environ.get("PROXY_TIMEOUT", "7200")
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"PROXY_TIMEOUT is not an integer: {raw}") from exc
    if value < 1:
        raise SystemExit(f"PROXY_TIMEOUT must be positive: {value}")
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        # The load-time health check runs every few seconds and the dashboard polls metrics every 2 s; logging them would flood the log.
        if urlsplit(getattr(self, "path", "")).path in QUIET_PATHS:
            return
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        sys.stderr.write("%s [redsnow] %s %s\n" % (stamp, self.address_string(), fmt % args))

    def reject(self, status: int, message: str) -> None:
        body = ('{"error":{"message":"%s","type":"server_error"}}' % message).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if status == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status: int, doc: dict) -> None:
        body = json.dumps(doc, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    # Upstream only has the list endpoint, so a single model is picked from the data array of /v1/models.
    def get_model(self, model: str) -> None:
        try:
            with urllib.request.urlopen(
                UPSTREAM + "/v1/models", timeout=proxy_timeout()
            ) as upstream:
                items = json.loads(upstream.read())["data"]
        except urllib.error.URLError as exc:
            sys.stderr.write(
                "%s [redsnow] upstream unreachable GET %s: %s\n"
                % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), self.path, exc.reason)
            )
            self.reject(503, "model is still loading")
            return
        except (ValueError, KeyError, TypeError):
            self.reject(502, "bad upstream models response")
            return
        for item in items:
            if isinstance(item, dict) and item.get("id") == model:
                self.send_json(200, item)
                return
        self.send_json(
            404,
            {
                "error": {
                    "message": "The model '%s' does not exist" % model,
                    "type": "invalid_request_error",
                    "code": "model_not_found",
                }
            },
        )

    def send_body(self, ctype: str, body: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def proxy(self) -> None:
        path = urlsplit(self.path).path
        # The dashboard page itself contains no data; the browser asks for the token and then fetches /metrics with a Bearer header.
        if self.command == "GET" and path == DASHBOARD_PATH:
            with open(DASHBOARD_FILE, "rb") as handle:
                self.send_body("text/html; charset=utf-8", handle.read())
            return
        if not authorized(self.headers.get("Authorization", "")):
            self.reject(401, "unauthorized")
            return
        if self.command == "GET" and path == METRICS_PATH:
            self.send_body("text/plain; version=0.0.4; charset=utf-8", metrics_text().encode())
            return
        if self.command == "GET":
            for prefix in MODEL_PREFIXES:
                if path.startswith(prefix) and len(path) > len(prefix):
                    self.get_model(unquote(path[len(prefix):]))
                    return
        if path not in ALLOWED:
            self.reject(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            self.reject(400, "bad content length")
            return
        if length < 0:
            self.reject(400, "bad content length")
            return
        payload = self.rfile.read(length) if length else None
        request = urllib.request.Request(
            UPSTREAM + self.path, data=payload, method=self.command
        )
        for key, value in self.headers.items():
            if key.lower() in DROP_HEADERS:
                continue
            request.add_header(key, value)
        if payload is not None:
            request.add_header("Content-Length", str(len(payload)))
        try:
            upstream = urllib.request.urlopen(request, timeout=proxy_timeout())
        except urllib.error.HTTPError as exc:
            upstream = exc
        except urllib.error.URLError as exc:
            if not is_health_path(self.path):
                sys.stderr.write(
                    "%s [redsnow] upstream unreachable %s %s: %s\n"
                    % (
                        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        self.command,
                        self.path,
                        exc.reason,
                    )
                )
            self.reject(503, "model is still loading")
            return
        self.send_response(upstream.status)
        for key, value in upstream.headers.items():
            if key.lower() in DROP_HEADERS or key.lower() == "content-length":
                continue
            self.send_header(key, value)
        if self.command == "GET" and path in HEALTH_PATHS and 200 <= upstream.status < 300:
            body = with_build_info(upstream.read())
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        size = upstream.headers.get("Content-Length")
        if size:
            self.send_header("Content-Length", size)
        self.send_header("Connection", "close")
        self.end_headers()
        # read() blocks until 65536 bytes or EOF, which would hold back SSE and keepalives; read1() forwards whatever is available.
        while True:
            chunk = upstream.read1(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def do_GET(self) -> None:
        self.proxy()

    def do_POST(self) -> None:
        self.proxy()


def main() -> None:
    if not TOKEN:
        raise SystemExit("API_TOKEN environment variable is required")
    host = check_bind_host(os.environ.get("PROXY_HOST", "0.0.0.0"))
    port = int(os.environ["PROXY_PORT"])
    sys.stderr.write(
        "%s [redsnow] auth proxy listening on %s:%s upstream %s\n"
        % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), host, port, UPSTREAM)
    )
    try:
        ThreadingHTTPServer((host, port), Handler).serve_forever()
    except OSError as exc:
        raise SystemExit(f"auth proxy cannot listen on {host}:{port}: {exc}") from exc


if __name__ == "__main__":
    main()
