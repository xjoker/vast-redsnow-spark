#!/usr/bin/env python3
"""补齐本地模型目录。完整则不动。缺的分片多线程下载，中断后接着传。"""

from __future__ import annotations

import argparse
import errno
import json
import logging
import os
import sys
import time
from pathlib import Path

LOG = logging.getLogger("redsnow.download")

ATTEMPTS = 6
BACKOFF_SECONDS = (5, 10, 20, 40, 60, 60)
PERMANENT_ERRORS = {
    "RepositoryNotFoundError",
    "RevisionNotFoundError",
    "GatedRepoError",
    "LocalEntryNotFoundError",
    "EntryNotFoundError",
    "DisabledRepoError",
    "BadRequestError",
}
FATAL_ERRNO = {errno.ENOSPC, errno.EROFS, errno.EACCES, errno.EPERM}


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
    # huggingface_hub 走 httpx，每个 HEAD/GET 都打一条 INFO，几十个文件就刷满启动日志。
    logging.getLogger("httpx").setLevel(logging.WARNING)


def parse_workers(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"MODEL_DOWNLOAD_WORKERS 不是整数: {raw}") from exc
    if value < 1:
        raise SystemExit(f"MODEL_DOWNLOAD_WORKERS 必须为正: {value}")
    return value


def prepare_hub_env(dest: Path) -> Path:
    """分片缓存跟模型放在同一块盘上，容器重建后还能接着传。"""
    cache = dest / ".hf-cache"
    cache.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(cache))
    os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")
    os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", "60")
    os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")
    if os.environ.get("HF_HUB_ENABLE_HF_TRANSFER"):
        LOG.warning("HF_HUB_ENABLE_HF_TRANSFER 已废弃，Xet 会忽略它。不要靠它加速。")
    return cache


def retryable(exc: BaseException) -> bool:
    if isinstance(exc, (KeyboardInterrupt, SystemExit)):
        return False
    if type(exc).__name__ in PERMANENT_ERRORS:
        return False
    text = str(exc).lower()
    if "no space left" in text or "disk full" in text or "read-only file system" in text:
        return False
    if isinstance(exc, OSError) and exc.errno in FATAL_ERRNO:
        return False
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if isinstance(status, int):
        return status in {408, 429} or status >= 500
    return True


def discard_orphan_incomplete(dest: Path) -> None:
    """临时文件名每次下载都变，留着也不能续传。分片缓存 .hf-cache 不动。"""
    removed = 0
    nbytes = 0
    for dirpath, dirnames, filenames in os.walk(dest):
        dirnames[:] = [name for name in dirnames if name != ".hf-cache"]
        for name in filenames:
            if not name.endswith(".incomplete"):
                continue
            path = Path(dirpath) / name
            nbytes += path.stat().st_size
            path.unlink()
            removed += 1
    if removed:
        LOG.info(
            "清掉 %s 个无法续传的临时文件，共 %s 字节。已完成分片和 .hf-cache 保留。",
            removed,
            nbytes,
        )


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


def run_download(
    repo_id: str,
    revision: str,
    dest: Path,
    max_workers: int,
    snapshot,
    *,
    sleep=time.sleep,
    attempts: int = ATTEMPTS,
) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    cache = prepare_hub_env(dest)
    LOG.info(
        "下载 repo=%s revision=%s dest=%s workers=%s 缓存=%s 高速=%s",
        repo_id,
        revision,
        dest,
        max_workers,
        cache,
        os.environ.get("HF_XET_HIGH_PERFORMANCE"),
    )
    LOG.info("已完成的分片会跳过。未完成的块留在缓存里，中断后继续，不从头下载。")
    last_error: BaseException | None = None
    for attempt in range(1, attempts + 1):
        discard_orphan_incomplete(dest)
        try:
            missing = missing_shards(dest)
        except ModelIndexError:
            LOG.exception("模型索引无法读取，本轮仍会下载: %s", dest)
            missing = []
        if missing:
            LOG.info("第 %s/%s 轮，还缺 %s 个文件", attempt, attempts, len(missing))
        try:
            snapshot(
                repo_id=repo_id,
                revision=revision,
                local_dir=str(dest),
                max_workers=max_workers,
                force_download=False,
                etag_timeout=60,
            )
        except Exception as exc:
            last_error = exc
            if not retryable(exc) or attempt == attempts:
                LOG.exception(
                    "下载失败 repo=%s revision=%s dest=%s workers=%s attempt=%s",
                    repo_id,
                    revision,
                    dest,
                    max_workers,
                    attempt,
                )
                raise SystemExit(1) from None
            delay = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
            LOG.warning(
                "下载中断，保留已完成分片和缓存，%s 秒后继续。attempt=%s/%s error=%s",
                delay,
                attempt,
                attempts,
                exc,
            )
            sleep(delay)
            continue
        try:
            still = missing_shards(dest)
        except ModelIndexError:
            LOG.exception("下载结束但模型索引仍不可读: %s", dest)
            raise SystemExit(1) from None
        if not still:
            LOG.info("下载结束 repo=%s revision=%s dest=%s", repo_id, revision, dest)
            return
        last_error = RuntimeError("仍缺少 " + ", ".join(still))
        if attempt == attempts:
            LOG.error("下载结束仍缺少 %s", ", ".join(still))
            raise SystemExit(1)
        delay = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
        LOG.warning("本轮后仍缺 %s 个文件，%s 秒后继续。", len(still), delay)
        sleep(delay)
    LOG.error("下载未完成: %s", last_error)
    raise SystemExit(1)


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
    dest = Path(args.dest)
    prepare_hub_env(dest)
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        LOG.exception("没有 huggingface_hub，无法下载模型")
        raise SystemExit(1) from None
    run_download(args.repo, args.revision, dest, workers, snapshot_download)


if __name__ == "__main__":
    main()
