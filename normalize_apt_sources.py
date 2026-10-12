#!/usr/bin/env python3
"""Rewrite country mirrors and mainland mirror sites in apt sources back to the official hosts. No region is pinned."""

from __future__ import annotations

import re
import sys
from pathlib import Path

CN_HOSTS = {
    "mirrors.aliyun.com",
    "mirrors.cloud.aliyuncs.com",
    "mirrors.tuna.tsinghua.edu.cn",
    "mirrors.ustc.edu.cn",
    "mirrors.huaweicloud.com",
    "repo.huaweicloud.com",
    "mirrors.cloud.tencent.com",
    "mirrors.tencent.com",
    "mirrors.163.com",
    "mirror.sjtu.edu.cn",
    "mirrors.sjtu.edu.cn",
    "mirrors.bfsu.edu.cn",
    "mirrors.pku.edu.cn",
    "mirrors.hit.edu.cn",
}

URL_RE = re.compile(r"https?://[^\s]+")


def official_host(host: str, path: str) -> str | None:
    host = host.lower().rstrip(".")
    if re.fullmatch(r"[a-z]{2}\.archive\.ubuntu\.com", host):
        return "archive.ubuntu.com"
    if re.fullmatch(r"[a-z]{2}\.ports\.ubuntu\.com", host):
        return "ports.ubuntu.com"
    if host not in CN_HOSTS:
        return None
    if "ubuntu-ports" in path:
        return "ports.ubuntu.com"
    if "ubuntu" in path:
        return "archive.ubuntu.com"
    if "debian" in path:
        return "deb.debian.org"
    return None


def rewrite_url(url: str) -> str:
    matched = re.fullmatch(r"(https?)://([^/\s]+)(/.*)?", url)
    if matched is None:
        return url
    scheme, host, path = matched.group(1), matched.group(2), matched.group(3) or ""
    new_host = official_host(host, path)
    if new_host is None:
        return url
    return f"{scheme}://{new_host}{path}"


def rewrite(text: str) -> str:
    return URL_RE.sub(lambda match: rewrite_url(match.group(0)), text)


def files_under(raw: str) -> list[Path]:
    path = Path(raw)
    if not path.exists():
        return []
    if path.is_dir():
        return [item for item in path.rglob("*") if item.is_file()]
    return [path]


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: normalize_apt_sources.py <sources.list or directory>...", file=sys.stderr)
        return 2
    for raw in argv[1:]:
        for file in files_under(raw):
            text = file.read_text(encoding="utf-8")
            updated = rewrite(text)
            if updated != text:
                file.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
