#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from normalize_apt_sources import rewrite

samples = {
    "http://cn.archive.ubuntu.com/ubuntu": "http://archive.ubuntu.com/ubuntu",
    "http://us.archive.ubuntu.com/ubuntu": "http://archive.ubuntu.com/ubuntu",
    "https://mirrors.aliyun.com/ubuntu": "https://archive.ubuntu.com/ubuntu",
    "http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports": "http://ports.ubuntu.com/ubuntu-ports",
    "http://archive.ubuntu.com/ubuntu": "http://archive.ubuntu.com/ubuntu",
    "http://ports.ubuntu.com/ubuntu-ports": "http://ports.ubuntu.com/ubuntu-ports",
    "http://security.ubuntu.com/ubuntu": "http://security.ubuntu.com/ubuntu",
    "https://developer.download.nvidia.com/devtools/repos/ubuntu2404/arm64": (
        "https://developer.download.nvidia.com/devtools/repos/ubuntu2404/arm64"
    ),
    "http://mirrors.ustc.edu.cn/debian": "http://deb.debian.org/debian",
}

for raw, expected in samples.items():
    got = rewrite(f"deb {raw} noble main\n")
    if f"deb {expected} noble main\n" != got:
        raise SystemExit(f"FAIL {raw} -> {got}")

print("normalize_apt_sources ok")
