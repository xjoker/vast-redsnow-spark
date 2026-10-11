import os
import sys

os.environ.setdefault("UPSTREAM", "http://127.0.0.1:8899")
os.environ.setdefault("API_TOKEN", "test-token")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import auth_proxy


def test_bind_host():
    assert auth_proxy.check_bind_host("127.0.0.1") == "127.0.0.1"
    assert auth_proxy.check_bind_host("10.144.144.2") == "10.144.144.2"
    for blocked in ("0.0.0.0", "::", ""):
        try:
            auth_proxy.check_bind_host(blocked)
        except SystemExit:
            continue
        raise SystemExit(f"should reject {blocked!r}")


def test_timeout_default():
    os.environ.pop("PROXY_TIMEOUT", None)
    assert auth_proxy.proxy_timeout() == 7200
    os.environ["PROXY_TIMEOUT"] = "nope"
    try:
        auth_proxy.proxy_timeout()
    except SystemExit:
        return
    raise SystemExit("bad timeout should fail")


if __name__ == "__main__":
    test_bind_host()
    test_timeout_default()
    print("auth_proxy ok")
