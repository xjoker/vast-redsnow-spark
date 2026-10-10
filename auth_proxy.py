#!/usr/bin/env python3
"""只监听本机的 Bearer 门。推理进程不直接对网络开放。"""

from __future__ import annotations

import hmac
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

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
    return hmac.compare_digest(header, f"Bearer {TOKEN}")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

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

    def proxy(self) -> None:
        if not authorized(self.headers.get("Authorization", "")):
            self.reject(401, "unauthorized")
            return
        path = urlsplit(self.path).path
        if path not in ALLOWED:
            self.reject(404, "not found")
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
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
            upstream = urllib.request.urlopen(request, timeout=120)
        except urllib.error.HTTPError as exc:
            upstream = exc
        except urllib.error.URLError:
            self.reject(503, "model is still loading")
            return
        self.send_response(upstream.status)
        for key, value in upstream.headers.items():
            if key.lower() in DROP_HEADERS or key.lower() == "content-length":
                continue
            self.send_header(key, value)
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
    host = os.environ.get("PROXY_HOST", "127.0.0.1")
    port = int(os.environ["PROXY_PORT"])
    if host != "127.0.0.1":
        raise SystemExit("auth proxy must bind 127.0.0.1")
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
