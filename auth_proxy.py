#!/usr/bin/env python3
"""Bearer 门。推理进程只听 127.0.0.1。这层默认听 0.0.0.0，请求必须带 API_TOKEN。"""

from __future__ import annotations

import hmac
import json
import os
import sys
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


# 上游非 JSON 对象（或非 2xx 时调用方不会进来）原样返回，不替上游猜格式。
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


def check_bind_host(host: str) -> str:
    if host in {"::", ""}:
        raise SystemExit(f"认证代理绑定地址无效: {host!r}")
    return host


def proxy_timeout() -> int:
    raw = os.environ.get("PROXY_TIMEOUT", "7200")
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"PROXY_TIMEOUT 不是整数: {raw}") from exc
    if value < 1:
        raise SystemExit(f"PROXY_TIMEOUT 必须为正: {value}")
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
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

    # 上游只有列表接口，单个模型只能从 /v1/models 的 data 里挑。
    def get_model(self, model: str) -> None:
        try:
            with urllib.request.urlopen(
                UPSTREAM + "/v1/models", timeout=proxy_timeout()
            ) as upstream:
                items = json.loads(upstream.read())["data"]
        except urllib.error.URLError as exc:
            sys.stderr.write(
                "%s [redsnow] 上游不可达 GET %s: %s\n"
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

    def proxy(self) -> None:
        if not authorized(self.headers.get("Authorization", "")):
            self.reject(401, "unauthorized")
            return
        path = urlsplit(self.path).path
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
            sys.stderr.write(
                "%s [redsnow] 上游不可达 %s %s: %s\n"
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
        while True:
            chunk = upstream.read(65536)
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
        raise SystemExit("需要环境变量 API_TOKEN")
    host = check_bind_host(os.environ.get("PROXY_HOST", "0.0.0.0"))
    port = int(os.environ["PROXY_PORT"])
    sys.stderr.write(
        "%s [redsnow] 认证代理监听 %s:%s 上游 %s\n"
        % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), host, port, UPSTREAM)
    )
    try:
        ThreadingHTTPServer((host, port), Handler).serve_forever()
    except OSError as exc:
        raise SystemExit(f"认证代理无法监听 {host}:{port}: {exc}") from exc


if __name__ == "__main__":
    main()
