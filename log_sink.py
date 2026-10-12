"""Tee stdin to stdout and to a size-capped rotating log on disk.

Usage: log_sink.py DIR MAX_MB. Lines go to stdout immediately; the same bytes are appended to
DIR/redsnow.log, rotating to redsnow.log.1, .2, ... so the total never exceeds MAX_MB.
A disk failure disables file logging with one warning; stdout passthrough keeps working.
"""
import os
import sys

NAME = "redsnow.log"
FILE_MB = 64


class RotatingLog:
    def __init__(self, directory: str, max_bytes: int):
        count = max(2, max_bytes // (FILE_MB << 20))
        self.limit = max_bytes // count
        self.backups = count - 1
        self.base = os.path.join(directory, NAME)
        self.f = open(self.base, "ab")
        self.size = self.f.tell()

    def write(self, data: bytes) -> None:
        if self.size and self.size + len(data) > self.limit:
            self.rotate()
        self.f.write(data)
        self.f.flush()
        self.size += len(data)

    def rotate(self) -> None:
        self.f.close()
        for i in range(self.backups - 1, 0, -1):
            if os.path.exists(f"{self.base}.{i}"):
                os.replace(f"{self.base}.{i}", f"{self.base}.{i + 1}")
        os.replace(self.base, f"{self.base}.1")
        self.f = open(self.base, "ab")
        self.size = 0


def main() -> int:
    directory, max_mb = sys.argv[1], int(sys.argv[2])
    out = sys.stdout.buffer
    try:
        log = RotatingLog(directory, max_mb << 20)
    except OSError as e:
        log = None
        out.write(f"[log_sink] warn: file logging disabled: {e}\n".encode())
        out.flush()
    for line in sys.stdin.buffer:
        out.write(line)
        out.flush()
        if log is not None:
            try:
                log.write(line)
            except OSError as e:
                log = None
                out.write(f"[log_sink] warn: file logging disabled: {e}\n".encode())
                out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
