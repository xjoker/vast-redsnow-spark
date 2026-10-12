#!/usr/bin/env python3
"""Complete the local model directory. Leave it alone if already complete. Missing shards are downloaded in parallel and resume after interruption."""

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
    """The model index is unreadable, or a file name in it is unusable."""


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [redsnow] %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        stream=sys.stderr,
    )
    logging.Formatter.converter = time.gmtime
    # huggingface_hub uses httpx and logs an INFO line per HEAD/GET; with dozens of files that floods the startup log.
    logging.getLogger("httpx").setLevel(logging.WARNING)


def parse_workers(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise SystemExit(f"MODEL_DOWNLOAD_WORKERS is not an integer: {raw}") from exc
    if value < 1:
        raise SystemExit(f"MODEL_DOWNLOAD_WORKERS must be positive: {value}")
    return value


def prepare_hub_env(dest: Path) -> Path:
    """The shard cache lives on the same disk as the model so downloads resume after the container is recreated."""
    cache = dest / ".hf-cache"
    cache.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(cache))
    os.environ.setdefault("HF_XET_HIGH_PERFORMANCE", "1")
    os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", "60")
    os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")
    if os.environ.get("HF_HUB_ENABLE_HF_TRANSFER"):
        LOG.warning("HF_HUB_ENABLE_HF_TRANSFER is deprecated and Xet ignores it. Do not rely on it for speed.")
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
    """Temporary file names change on every download, so keeping them cannot resume anything. The shard cache .hf-cache is left alone."""
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
            "removed %s temporary files that cannot be resumed, %s bytes total. Completed shards and .hf-cache are kept.",
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
        raise ModelIndexError(f"model index unreadable: {index_path}: {exc}") from exc
    missing: list[str] = []
    seen: list[str] = []
    for name in names:
        if (
            not isinstance(name, str)
            or name == ""
            or Path(name).is_absolute()
            or ".." in Path(name).parts
        ):
            raise ModelIndexError(f"invalid file name in model index: {name!r}")
        if name in seen:
            continue
        seen.append(name)
        if not (dest / name).is_file():
            missing.append(name)
    if not seen:
        raise ModelIndexError(f"model index has no weight files: {index_path}")
    return missing


def is_complete(dest: Path) -> bool:
    try:
        return missing_shards(dest) == []
    except ModelIndexError:
        LOG.exception("model index unreadable: %s", dest)
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
        "download repo=%s revision=%s dest=%s workers=%s cache=%s fast=%s",
        repo_id,
        revision,
        dest,
        max_workers,
        cache,
        os.environ.get("HF_XET_HIGH_PERFORMANCE"),
    )
    LOG.info("Completed shards are skipped. Unfinished chunks stay in the cache and resume after an interruption instead of restarting.")
    last_error: BaseException | None = None
    for attempt in range(1, attempts + 1):
        discard_orphan_incomplete(dest)
        try:
            missing = missing_shards(dest)
        except ModelIndexError:
            LOG.exception("model index unreadable, downloading anyway this round: %s", dest)
            missing = []
        if missing:
            LOG.info("round %s/%s, %s files still missing", attempt, attempts, len(missing))
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
                    "download failed repo=%s revision=%s dest=%s workers=%s attempt=%s",
                    repo_id,
                    revision,
                    dest,
                    max_workers,
                    attempt,
                )
                raise SystemExit(1) from None
            delay = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
            LOG.warning(
                "download interrupted, keeping completed shards and cache, retrying in %s s. attempt=%s/%s error=%s",
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
            LOG.exception("download finished but model index is still unreadable: %s", dest)
            raise SystemExit(1) from None
        if not still:
            LOG.info("download finished repo=%s revision=%s dest=%s", repo_id, revision, dest)
            return
        last_error = RuntimeError("still missing " + ", ".join(still))
        if attempt == attempts:
            LOG.error("download finished but still missing %s", ", ".join(still))
            raise SystemExit(1)
        delay = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
        LOG.warning("%s files still missing after this round, retrying in %s s.", len(still), delay)
        sleep(delay)
    LOG.error("download incomplete: %s", last_error)
    raise SystemExit(1)


def main() -> None:
    configure_logging()
    parser = argparse.ArgumentParser(description="Check or download RED-SNOW weights")
    parser.add_argument("--check", metavar="DIR")
    parser.add_argument("--repo")
    parser.add_argument("--revision")
    parser.add_argument("--dest")
    parser.add_argument("--workers", default="8")
    args = parser.parse_args()
    if args.check:
        raise SystemExit(0 if is_complete(Path(args.check)) else 1)
    if not args.repo or not args.revision or not args.dest:
        raise SystemExit("download needs --repo --revision --dest")
    workers = parse_workers(args.workers)
    dest = Path(args.dest)
    prepare_hub_env(dest)
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        LOG.exception("huggingface_hub is missing, cannot download the model")
        raise SystemExit(1) from None
    run_download(args.repo, args.revision, dest, workers, snapshot_download)


if __name__ == "__main__":
    main()
