#!/usr/bin/env python3
"""从同一个发布包安装 easytier-core 和 easytier-cli。不走会装成 latest 的 install.sh。"""
import os
import sys
import zipfile

NAMES = ("easytier-core", "easytier-cli")


def install(archive: str, dest: str) -> None:
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        for name in NAMES:
            path = os.path.join(dest, name)
            with open(path, "wb") as out:
                out.write(bundle.read(f"easytier-linux-aarch64/{name}"))
            os.chmod(path, 0o755)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <zip> <dest>")
    install(sys.argv[1], sys.argv[2])
