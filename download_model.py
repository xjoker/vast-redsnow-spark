#!/usr/bin/env python3
"""补齐本地模型目录。完整则不动，缺文件则多线程下载。"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path

LOG = logging.getLogger("redsnow.download")


class ModelIndexError(Exception):
    """模型索引不可读，或里面的文件名不能用。"""


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [redsnow] %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        stream=sys.stderr,
    )
    logging.Formatter.converter = time.gmtime


def parse_workers(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"MODEL_DOWNLOAD_WORKERS 不是整数: {raw}") from exc
    if value < 1:
        raise SystemExit(f"MODEL_DOWNLOAD_WORKERS 必须为正: {value}")
    return value


def missing_shards(dest: Path) -> list[str]:
    index_path = dest / "model.safetensors.index.json"
    if not (dest / "tokenizer_config.json").is_file() or not index_path.is_file():
        return ["tokenizer_config.json", "model.safetensors.index.json"]
    try:
        payload = json.loads(index_path.read_text(encoding="utf-8"))
        names = payload["weight_map"].values()
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, AttributeError) as exc:
        raise ModelIndexError(f"模型索引无法读取: {index_path}: {exc}") from exc
    missing: list[str] = []
    seen: list[str] = []
    for name in names:
        if (
            not isinstance(name, str)
            or name == ""
            or Path(name).is_absolute()
            or ".." in Path(name).parts
        ):
            raise ModelIndexError(f"模型索引里的文件名无效: {name!r}")
        if name in seen:
            continue
        seen.append(name)
        if not (dest / name).is_file():
            missing.append(name)
    if not seen:
        raise ModelIndexError(f"模型索引没有权重文件: {index_path}")
    return missing


def is_complete(dest: Path) -> bool:
    try:
        return missing_shards(dest) == []
    except ModelIndexError:
        LOG.exception("模型索引无法读取: %s", dest)
        return False


def run_download(repo_id: str, revision: str, dest: Path, max_workers: int, snapshot) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    if not (dest / "model.safetensors.index.json").is_file():
        LOG.info(
            "目录里没有模型索引，将下载整个修订版本 repo=%s revision=%s dest=%s workers=%s",
            repo_id,
            revision,
            dest,
            max_workers,
        )
    else:
        try:
            missing = missing_shards(dest)
        except ModelIndexError:
            LOG.exception("模型索引无法读取，改为重新下载: %s", dest)
            missing = []
        LOG.info(
            "下载开始 repo=%s revision=%s dest=%s workers=%s 缺少=%s",
            repo_id,
            revision,
            dest,
            max_workers,
            len(missing),
        )
    try:
        snapshot(
            repo_id=repo_id,
            revision=revision,
            local_dir=str(dest),
            max_workers=max_workers,
        )
    except Exception:
        LOG.exception(
            "下载失败 repo=%s revision=%s dest=%s workers=%s",
            repo_id,
            revision,
            dest,
            max_workers,
        )
        raise SystemExit(1) from None
    try:
        still = missing_shards(dest)
    except ModelIndexError:
        LOG.exception("下载结束但模型索引仍不可读: %s", dest)
        raise SystemExit(1) from None
    if still:
        LOG.error("下载结束仍缺少 %s", ", ".join(still))
        raise SystemExit(1)
    LOG.info("下载结束 repo=%s revision=%s dest=%s", repo_id, revision, dest)


def main() -> None:
    configure_logging()
    parser = argparse.ArgumentParser(description="检查或下载 RED-SNOW 权重")
    parser.add_argument("--check", metavar="DIR")
    parser.add_argument("--repo")
    parser.add_argument("--revision")
    parser.add_argument("--dest")
    parser.add_argument("--workers", default="8")
    args = parser.parse_args()
    if args.check:
        raise SystemExit(0 if is_complete(Path(args.check)) else 1)
    if not args.repo or not args.revision or not args.dest:
        raise SystemExit("下载需要 --repo --revision --dest")
    workers = parse_workers(args.workers)
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        LOG.exception("没有 huggingface_hub，无法下载模型")
        raise SystemExit(1) from None
    run_download(args.repo, args.revision, Path(args.dest), workers, snapshot_download)


if __name__ == "__main__":
    main()
