#!/usr/bin/env python3
"""临时抓包：记录请求结构（长字符串截短）后原样转发到 8899。"""
import json, sys, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = "http://127.0.0.1:8899"
LOG = open("/root/capture.jsonl", "a")


def shrink(v):
    if isinstance(v, str):
        return v if len(v) <= 300 else v[:120] + f"...<{len(v)} chars>"
    if isinstance(v, list):
        return [shrink(x) for x in v]
    if isinstance(v, dict):
        return {k: shrink(x) for k, x in v.items()}
    return v


class H(BaseHTTPRequestHandler):
    def _fwd(self, method):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0)) if method == "POST" else None
        rec = {"method": method, "path": self.path}
        if body:
            try:
                rec["body"] = shrink(json.loads(body))
            except ValueError:
                rec["raw"] = body[:300].decode(errors="replace")
        req = urllib.request.Request(UP + self.path, data=body, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            r = urllib.request.urlopen(req, timeout=3600)
            status, headers = r.status, r.headers
        except urllib.error.HTTPError as e:
            r, status, headers = e, e.code, e.headers
        rec["status"] = status
        if status >= 400:
            rec["error"] = r.read().decode(errors="replace")[:500]
            data = rec["error"].encode()
            chunks = [data]
        else:
            chunks = iter(lambda: r.read1(65536), b"")
        LOG.write(json.dumps(rec) + "\n"); LOG.flush()
        self.send_response(status)
        self.send_header("Content-Type", headers.get("Content-Type", "application/json"))
        self.send_header("Connection", "close")
        self.end_headers()
        for c in chunks:
            self.wfile.write(c); self.wfile.flush()

    def do_GET(self):
        self._fwd("GET")

    def do_POST(self):
        self._fwd("POST")

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", 8897), H).serve_forever()
