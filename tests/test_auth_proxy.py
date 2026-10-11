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


if __name__ == "__main__":
    test_bind_host()
    test_empty_token_rejects()
    test_timeout_default()
    test_health_carries_build_info()
    print("auth_proxy ok")
