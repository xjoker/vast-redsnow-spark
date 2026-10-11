import os
import sys

os.environ.setdefault("UPSTREAM", "http://127.0.0.1:8899")
os.environ.setdefault("API_TOKEN", "test-token")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import auth_proxy


def test_bind_host():
    assert auth_proxy.check_bind_host("127.0.0.1") == "127.0.0.1"
    assert auth_proxy.check_bind_host("10.144.144.2") == "10.144.144.2"
    assert auth_proxy.check_bind_host("0.0.0.0") == "0.0.0.0"
    for blocked in ("::", ""):
        try:
            auth_proxy.check_bind_host(blocked)
        except SystemExit:
            continue
        raise SystemExit(f"should reject {blocked!r}")


def test_empty_token_rejects():
    old = auth_proxy.TOKEN
    auth_proxy.TOKEN = ""
    try:
        assert auth_proxy.authorized("Bearer ") is False
        assert auth_proxy.authorized("Bearer test-token") is False
    finally:
        auth_proxy.TOKEN = old


def test_timeout_default():
    os.environ.pop("PROXY_TIMEOUT", None)
    assert auth_proxy.proxy_timeout() == 7200
    os.environ["PROXY_TIMEOUT"] = "nope"
    try:
        auth_proxy.proxy_timeout()
    except SystemExit:
        return
    raise SystemExit("bad timeout should fail")


def test_health_carries_build_info():
    import json
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
    import urllib.request

    class Upstream(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    upstream = HTTPServer(("127.0.0.1", 0), Upstream)
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), auth_proxy.Handler)
    for server in (upstream, proxy):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    old_upstream = auth_proxy.UPSTREAM
    auth_proxy.UPSTREAM = f"http://127.0.0.1:{upstream.server_port}"
    os.environ.pop("PROXY_TIMEOUT", None)
    os.environ["IMAGE_VERSION"] = "20261011.1"
    os.environ["GIT_COMMIT"] = "abc123"
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{proxy.server_port}/health",
            headers={"Authorization": f"Bearer {auth_proxy.TOKEN}"},
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            doc = json.loads(resp.read())
        assert doc == {"status": "ok", "image_version": "20261011.1", "git_commit": "abc123"}, doc
    finally:
        auth_proxy.UPSTREAM = old_upstream
        os.environ.pop("IMAGE_VERSION", None)
        os.environ.pop("GIT_COMMIT", None)
        for server in (proxy, upstream):
            server.shutdown()
            server.server_close()


def _get_model(path, token=None):
    import json
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
    import urllib.error
    import urllib.request

    class Upstream(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'{"object":"list","data":[{"id":"a/b","object":"model"},{"id":"c","object":"model"}]}'
            self.send_response(200 if self.path == "/v1/models" else 404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    upstream = HTTPServer(("127.0.0.1", 0), Upstream)
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), auth_proxy.Handler)
    for server in (upstream, proxy):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    old_upstream = auth_proxy.UPSTREAM
    auth_proxy.UPSTREAM = f"http://127.0.0.1:{upstream.server_port}"
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{proxy.server_port}{path}",
            headers={"Authorization": f"Bearer {token or auth_proxy.TOKEN}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())
    finally:
        auth_proxy.UPSTREAM = old_upstream
        for server in (proxy, upstream):
            server.shutdown()
            server.server_close()


def test_get_model_found():
    for path in ("/v1/models/c", "/models/c"):
        status, doc = _get_model(path)
        assert status == 200, (path, status, doc)
        assert doc == {"id": "c", "object": "model"}, doc
    status, doc = _get_model("/v1/models/a/b")
    assert status == 200 and doc["id"] == "a/b", (status, doc)


def test_get_model_not_found():
    status, doc = _get_model("/v1/models/nope")
    assert status == 404, (status, doc)
    assert doc["error"]["code"] == "model_not_found", doc
    assert doc["error"]["type"] == "invalid_request_error", doc


def test_get_model_requires_token():
    status, _ = _get_model("/v1/models/c", token="wrong")
    assert status == 401, status


def test_stream_is_not_buffered():
    import threading
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import urllib.request

    class Upstream(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b'data: {"a":1}\n\n')
            self.wfile.flush()
            time.sleep(2)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

        def log_message(self, *args):
            pass

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), auth_proxy.Handler)
    for server in (upstream, proxy):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    old_upstream = auth_proxy.UPSTREAM
    auth_proxy.UPSTREAM = f"http://127.0.0.1:{upstream.server_port}"
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{proxy.server_port}/v1/chat/completions",
            data=b'{"stream":true}',
            method="POST",
            headers={
                "Authorization": f"Bearer {auth_proxy.TOKEN}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            started = time.monotonic()
            first = resp.readline()
            elapsed = time.monotonic() - started
            rest = resp.read()
        assert first == b'data: {"a":1}\n', first
        assert elapsed < 1, f"first SSE line was buffered for {elapsed:.2f}s"
        assert b"data: [DONE]" in rest, rest
    finally:
        auth_proxy.UPSTREAM = old_upstream
        for server in (proxy, upstream):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    test_bind_host()
    test_empty_token_rejects()
    test_timeout_default()
    test_health_carries_build_info()
    test_get_model_found()
    test_get_model_not_found()
    test_get_model_requires_token()
    test_stream_is_not_buffered()
    print("auth_proxy ok")
