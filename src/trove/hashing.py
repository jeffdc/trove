from __future__ import annotations

import hashlib
import logging
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from rich.progress import Progress

logger = logging.getLogger(__name__)


def hash_file(
    path: Path,
    chunk_size: int = 8192,
    progress_callback: Callable[[int], None] | None = None,
) -> str:
    """Compute MD5 hash of a file using chunked reads.

    Args:
        path: Path to file to hash.
        chunk_size: Bytes to read per chunk.
        progress_callback: Called with cumulative bytes read after each chunk.

    Returns:
        MD5 hex digest string.

    Raises:
        OSError: If file cannot be read.
    """
    hasher = hashlib.md5()
    bytes_read = 0

    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            hasher.update(chunk)
            bytes_read += len(chunk)
            if progress_callback is not None:
                progress_callback(bytes_read)

    return hasher.hexdigest()


def hash_files_parallel(
    paths: list[Path],
    max_workers: int = 4,
    chunk_size: int = 8192,
    progress: Progress | None = None,
) -> dict[str, str]:
    """Hash multiple files concurrently using a thread pool.

    Returns dict mapping str(path) -> md5 hex string.
    Files that fail to hash are omitted with a warning logged.
    """
    if not paths:
        return {}

    results: dict[str, str] = {}

    task_id = None
    if progress is not None:
        task_id = progress.add_task("Hashing files", total=len(paths))

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_path = {executor.submit(hash_file, p, chunk_size): p for p in paths}
        for future in as_completed(future_to_path):
            path = future_to_path[future]
            try:
                results[str(path)] = future.result()
            except OSError:
                logger.warning("Failed to hash file: %s", path)
            if progress is not None and task_id is not None:
                progress.update(task_id, advance=1)

    return results
