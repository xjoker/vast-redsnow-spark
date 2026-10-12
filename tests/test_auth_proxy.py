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


def _run_quiet_probe(upstream_port, paths):
    import contextlib
    import io
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import urllib.error
    import urllib.request

    class Upstream(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    servers = [ThreadingHTTPServer(("127.0.0.1", 0), auth_proxy.Handler)]
    upstream = None
    if upstream_port is None:
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        servers.append(upstream)
        target = f"http://127.0.0.1:{upstream.server_port}"
    else:
        target = f"http://127.0.0.1:{upstream_port}"
    proxy = servers[0]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    old_upstream = auth_proxy.UPSTREAM
    auth_proxy.UPSTREAM = target
    buf = io.StringIO()
    statuses = {}
    try:
        with contextlib.redirect_stderr(buf):
            for path in paths:
                req = urllib.request.Request(
                    f"http://127.0.0.1:{proxy.server_port}{path}",
                    headers={"Authorization": f"Bearer {auth_proxy.TOKEN}"},
                )
                try:
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        statuses[path] = resp.status
                        resp.read()
                except urllib.error.HTTPError as exc:
                    statuses[path] = exc.code
                    exc.read()
    finally:
        auth_proxy.UPSTREAM = old_upstream
        for server in servers:
            server.shutdown()
            server.server_close()
    return buf.getvalue(), statuses


def test_health_requests_are_not_logged():
    logged, statuses = _run_quiet_probe(None, ["/health", "/v1/health", "/v1/models"])
    assert statuses == {"/health": 200, "/v1/health": 200, "/v1/models": 200}, statuses
    assert "health" not in logged, logged
    assert "/v1/models" in logged, logged


def test_unreachable_upstream_health_is_quiet():
    logged, statuses = _run_quiet_probe(1, ["/health", "/v1/models"])
    assert statuses == {"/health": 503, "/v1/models": 503}, statuses
    assert "upstream unreachable GET /v1/models" in logged, logged
    assert "upstream unreachable GET /health" not in logged, logged
    assert "/health" not in logged, logged


def _serve_metrics(upstream_metrics, paths, token=None):
    """Start a fake upstream (/metrics returns the given text; None means unreachable) and the proxy, then GET paths in order."""
    import contextlib
    import io
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer
    import urllib.error
    import urllib.request

    class Upstream(BaseHTTPRequestHandler):
        def do_GET(self):
            body = (upstream_metrics or "").encode()
            self.send_response(200 if self.path == "/metrics" else 404)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    servers = [ThreadingHTTPServer(("127.0.0.1", 0), auth_proxy.Handler)]
    if upstream_metrics is None:
        import socket

        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            target = f"http://127.0.0.1:{sock.getsockname()[1]}"
    else:
        servers.append(HTTPServer(("127.0.0.1", 0), Upstream))
        target = f"http://127.0.0.1:{servers[1].server_port}"
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    old_upstream = auth_proxy.UPSTREAM
    auth_proxy.UPSTREAM = target
    buf = io.StringIO()
    results = {}
    try:
        with contextlib.redirect_stderr(buf):
            for path in paths:
                headers = {} if token == "" else {"Authorization": f"Bearer {token or auth_proxy.TOKEN}"}
                req = urllib.request.Request(f"http://127.0.0.1:{servers[0].server_port}{path}", headers=headers)
                try:
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        results[path] = (resp.status, resp.headers.get("Content-Type"), resp.read().decode())
                except urllib.error.HTTPError as exc:
                    results[path] = (exc.code, exc.headers.get("Content-Type"), exc.read().decode())
    finally:
        auth_proxy.UPSTREAM = old_upstream
        for server in servers:
            server.shutdown()
            server.server_close()
    return results, buf.getvalue()


def test_metrics_requires_token():
    results, _ = _serve_metrics("", ["/metrics"], token="wrong")
    assert results["/metrics"][0] == 401, results
    results, _ = _serve_metrics("", ["/metrics"], token="")
    assert results["/metrics"][0] == 401, results


def test_metrics_merges_host_and_upstream():
    upstream = "# TYPE redsnow_generation_tokens_total counter\nredsnow_generation_tokens_total 42\n"
    results, logged = _serve_metrics(upstream, ["/metrics"])
    status, ctype, body = results["/metrics"]
    assert status == 200, results
    assert ctype.startswith("text/plain"), ctype
    assert "redsnow_generation_tokens_total 42\n" in body, body
    assert "redsnow_upstream_up 1\n" in body, body
    assert "redsnow_memory_available_bytes " in body or not os.path.exists("/proc/meminfo"), body
    assert 'redsnow_build_info{' in body, body
    # The dashboard polls every 2 s and must not flood the access log.
    assert "/metrics" not in logged, logged


def test_metrics_when_upstream_down():
    results, _ = _serve_metrics(None, ["/metrics"])
    status, _, body = results["/metrics"]
    assert status == 200, results
    assert "redsnow_upstream_up 0\n" in body, body


def test_host_metrics_from_proc_files():
    import tempfile

    with tempfile.TemporaryDirectory() as root:
        def put(name, text):
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write(text)
            return path

        meminfo = put("meminfo", "MemTotal:       125442396 kB\nMemFree: 1 kB\nMemAvailable:    12800000 kB\n")
        stat = put("stat", "cpu  100 5 50 1000 20 0 3 0 0 0\ncpu0 1 1 1 1 1 1 1 1 1 1\n")
        loadavg = put("loadavg", "3.17 3.23 2.05 2/400 12345\n")
        put("cgroup/memory.current", "9663676416\n")
        put("cgroup/memory.events", "low 0\nhigh 0\nmax 2\noom 1\noom_kill 1\noom_group_kill 0\n")
        text = "".join(
            auth_proxy.host_metrics(
                meminfo=meminfo, stat=stat, loadavg=loadavg, cgroup=os.path.join(root, "cgroup"), clk_tck=100
            )
        )
    assert "redsnow_memory_total_bytes 128453013504\n" in text, text
    assert "redsnow_memory_available_bytes 13107200000\n" in text, text
    assert 'redsnow_cpu_seconds_total{mode="user"} 1.0\n' in text, text
    assert 'redsnow_cpu_seconds_total{mode="idle"} 10.0\n' in text, text
    assert "redsnow_load1 3.17\n" in text, text
    assert "redsnow_cgroup_memory_current_bytes 9663676416\n" in text, text
    assert "redsnow_cgroup_oom_kills_total 1\n" in text, text


def test_host_metrics_skip_missing_files():
    text = "".join(
        auth_proxy.host_metrics(
            meminfo="/nonexistent/meminfo", stat="/nonexistent/stat", loadavg="/nonexistent/loadavg",
            cgroup="/nonexistent/cgroup", clk_tck=100,
        )
    )
    assert "redsnow_memory_total_bytes" not in text, text
    assert "redsnow_cgroup" not in text, text


def test_gpu_metrics_parse():
    lines = "".join(auth_proxy.gpu_metrics("96, 75, 51.23, 2171\n"))
    assert "redsnow_gpu_utilization_percent 96\n" in lines, lines
    assert "redsnow_gpu_temperature_celsius 75\n" in lines, lines
    assert "redsnow_gpu_power_watts 51.23\n" in lines, lines
    assert "redsnow_gpu_sm_clock_hertz 2171000000\n" in lines, lines
    assert auth_proxy.gpu_metrics("[N/A], [N/A], [N/A], [N/A]\n") == []
    assert auth_proxy.gpu_metrics("") == []


def test_dashboard_served_without_token():
    results, logged = _serve_metrics("", ["/dashboard"], token="")
    status, ctype, body = results["/dashboard"]
    assert status == 200, results
    assert ctype.startswith("text/html"), ctype
    assert "/metrics" in body, "dashboard must fetch data from /metrics"
    assert auth_proxy.TOKEN not in body
    assert "/dashboard" not in logged, logged


if __name__ == "__main__":
    test_bind_host()
    test_empty_token_rejects()
    test_timeout_default()
    test_health_carries_build_info()
    test_get_model_found()
    test_get_model_not_found()
    test_get_model_requires_token()
    test_stream_is_not_buffered()
    test_health_requests_are_not_logged()
    test_unreachable_upstream_health_is_quiet()
    test_metrics_requires_token()
    test_metrics_merges_host_and_upstream()
    test_metrics_when_upstream_down()
    test_host_metrics_from_proc_files()
    test_host_metrics_skip_missing_files()
    test_gpu_metrics_parse()
    test_dashboard_served_without_token()
    print("auth_proxy ok")
