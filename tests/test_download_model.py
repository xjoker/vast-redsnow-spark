import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import download_model


def write_model(dest: Path, *, shard: bool) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "tokenizer_config.json").write_text("{}\n", encoding="utf-8")
    (dest / "model.safetensors.index.json").write_text(
        '{"weight_map":{"block":"model-00001-of-00015.safetensors"}}\n',
        encoding="utf-8",
    )
    if shard:
        (dest / "model-00001-of-00015.safetensors").write_text("x", encoding="utf-8")


def test_workers():
    assert download_model.parse_workers("8") == 8
    assert download_model.parse_workers("16") == 16
    for bad in ("0", "-1", "nope", ""):
        try:
            download_model.parse_workers(bad)
        except SystemExit:
            continue
        raise SystemExit(f"should reject {bad!r}")


def test_complete_and_missing(tmp: Path):
    ready = tmp / "ready"
    write_model(ready, shard=True)
    assert download_model.is_complete(ready) is True
    partial = tmp / "partial"
    write_model(partial, shard=False)
    missing = download_model.missing_shards(partial)
    assert missing == ["model-00001-of-00015.safetensors"]
    assert download_model.is_complete(tmp / "absent") is False


def test_rejects_parent_segment(tmp: Path):
    dest = tmp / "bad"
    dest.mkdir()
    (dest / "tokenizer_config.json").write_text("{}\n", encoding="utf-8")
    (dest / "model.safetensors.index.json").write_text(
        '{"weight_map":{"block":"../secret"}}\n',
        encoding="utf-8",
    )
    assert download_model.is_complete(dest) is False


def test_download_passes_workers(tmp: Path):
    seen = {}

    def fake(**kwargs):
        seen.update(kwargs)
        write_model(Path(kwargs["local_dir"]), shard=True)

    dest = tmp / "dest"
    download_model.run_download("repo", "rev", dest, 4, fake)
    assert seen["repo_id"] == "repo"
    assert seen["revision"] == "rev"
    assert seen["local_dir"] == str(dest)
    assert seen["max_workers"] == 4


def test_download_failure(tmp: Path):
    def boom(**_kwargs):
        raise RuntimeError("disk full")

    try:
        download_model.run_download("repo", "rev", tmp / "dest", 2, boom)
    except SystemExit as exc:
        if exc.code == 1:
            return
    raise SystemExit("download failure should exit 1")


if __name__ == "__main__":
    import tempfile

    test_workers()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        test_complete_and_missing(root)
        test_rejects_parent_segment(root)
        test_download_passes_workers(root)
        test_download_failure(root)
    print("download_model ok")
