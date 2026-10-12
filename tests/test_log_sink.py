import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SINK = os.path.join(ROOT, "log_sink.py")


def run_sink(directory: str, max_mb: int, data: bytes) -> subprocess.CompletedProcess:
    # Files instead of pipes: a multi-MB input through communicate() stalls on some platforms.
    with tempfile.TemporaryFile() as stdin, tempfile.TemporaryFile() as stdout:
        stdin.write(data)
        stdin.seek(0)
        subprocess.run(
            [sys.executable, "-u", SINK, directory, str(max_mb)],
            stdin=stdin, stdout=stdout, check=True,
        )
        stdout.seek(0)
        return subprocess.CompletedProcess([], 0, stdout.read())


def test_passthrough_and_file():
    with tempfile.TemporaryDirectory() as d:
        r = run_sink(d, 3, b"one\ntwo\nno newline")
        assert r.stdout == b"one\ntwo\nno newline"
        with open(os.path.join(d, "redsnow.log"), "rb") as f:
            assert f.read() == b"one\ntwo\nno newline"


def test_rotation_keeps_total_under_cap():
    with tempfile.TemporaryDirectory() as d:
        line = b"x" * 1023 + b"\n"
        r = run_sink(d, 1, line * 5000)
        assert len(r.stdout) == 5000 * 1024
        sizes = [os.path.getsize(os.path.join(d, n)) for n in os.listdir(d)]
        assert len(sizes) == 2, sorted(os.listdir(d))
        assert sum(sizes) <= 1 << 20, sizes


def test_unwritable_dir_keeps_passthrough():
    with tempfile.TemporaryDirectory() as d:
        blocked = os.path.join(d, "file")
        open(blocked, "w").close()
        r = run_sink(os.path.join(blocked, "logs"), 3, b"a\nb\nc\n")
        assert r.stdout.count(b"warn") == 1, r.stdout
        assert r.stdout.endswith(b"a\nb\nc\n")


if __name__ == "__main__":
    test_passthrough_and_file()
    test_rotation_keeps_total_under_cap()
    test_unwritable_dir_keeps_passthrough()
    print("log_sink ok")
