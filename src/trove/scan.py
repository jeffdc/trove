"""File discovery, metadata extraction, and scan orchestration for Trove."""

from __future__ import annotations

import fnmatch
import os
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

from trove.config import LibraryConfig
from trove.db import StateDB
from trove.normalize import normalize_filename

if TYPE_CHECKING:
    from rich.progress import Progress


from collections.abc import Callable


def discover_files(
    source_path: Path,
    config: LibraryConfig,
    on_found: Callable[[int], None] | None = None,
    limit: int | None = None,
) -> list[Path]:
    """Walk source directory recursively and return sorted list of media files.

    Uses os.scandir for performance. Filters by configured file type extensions,
    exclude patterns, and skips zero-byte files and directory symlinks.

    Args:
        source_path: Root directory to scan.
        config: LibraryConfig with file_types and exclude_patterns.
        on_found: Optional callback called with current count after each file found.
        limit: If set, stop discovery after finding this many files.

    Returns:
        Sorted list of Path objects for discovered media files.

    Raises:
        ValueError: If source_path does not exist or is not a directory.
    """
    if not source_path.exists():
        raise ValueError(f"Source path '{source_path}' does not exist")
    if not source_path.is_dir():
        raise ValueError(f"Source path '{source_path}' is not a directory")

    # Build set of allowed extensions (lowercase, without leading dot)
    allowed_extensions: set[str] = set()
    allowed_extensions.update(ext.lower() for ext in config.file_types.photos)
    allowed_extensions.update(ext.lower() for ext in config.file_types.videos)
    allowed_extensions.update(ext.lower() for ext in config.file_types.raw)

    exclude_patterns = config.exclude_patterns
    result: list[Path] = []
    seen_inodes: set[int] = set()

    def _scan(directory: Path) -> None:
        try:
            entries = os.scandir(directory)
        except PermissionError:
            return

        with entries:
            for entry in entries:
                try:
                    if entry.is_symlink():
                        # Skip all symlinks — they're references, not real files.
                        # Moving a symlink during initialize would either move the
                        # target (data loss at original location) or move just the
                        # link (hash mismatch on verification).
                        continue

                    if entry.is_dir(follow_symlinks=False):
                        _scan(Path(entry.path))
                        if limit is not None and len(result) >= limit:
                            return
                        continue

                    if not entry.is_file(follow_symlinks=False):
                        continue

                    name = entry.name

                    # Check exclude patterns against filename
                    if any(fnmatch.fnmatch(name, pattern) for pattern in exclude_patterns):
                        continue

                    # Check extension (case-insensitive)
                    _, ext = os.path.splitext(name)
                    if not ext:
                        continue
                    if ext[1:].lower() not in allowed_extensions:
                        continue

                    # Skip zero-byte files
                    try:
                        stat = entry.stat(follow_symlinks=True)
                    except OSError:
                        continue
                    if stat.st_size == 0:
                        continue

                    inode = stat.st_ino
                    if inode in seen_inodes:
                        continue
                    seen_inodes.add(inode)

                    result.append(Path(entry.path))
                    if on_found is not None:
                        on_found(len(result))
                    if limit is not None and len(result) >= limit:
                        return
                except OSError:
                    continue

    _scan(source_path)
    result.sort()
    return result


def compute_target_path(
    capture_date: str | None,
    camera_model: str | None,
    filename: str,
    config: LibraryConfig,
) -> str | None:
    """Compute relative target path for a file within a library.

    Pure function. Returns None if capture_date is None (caller should quarantine).

    Args:
        capture_date: ISO format date string (e.g. "2024-01-15T10:30:00"), or None.
        camera_model: Camera model string, or None.
        filename: Original filename.
        config: LibraryConfig with organization settings.

    Returns:
        Relative path string, or None if no capture_date.
    """
    if capture_date is None:
        return None

    dt = datetime.fromisoformat(capture_date)
    date_part = dt.strftime(config.organization.structure)

    normalized_filename = normalize_filename(filename)

    if not config.organization.include_camera_model:
        return f"{date_part}/{normalized_filename}"

    if camera_model is None:
        model_part = config.organization.unknown_model_label
    else:
        model_part = normalize_filename(camera_model)

    return f"{date_part}/{model_part}/{normalized_filename}"


def scan_source(
    source_path: Path,
    db: StateDB,
    config: LibraryConfig,
    progress: Progress | None = None,
) -> dict:
    """Orchestrate file discovery, hashing, metadata extraction, and target path computation.

    Delegates to pipeline stages for each step.

    Args:
        source_path: Root directory to scan.
        db: StateDB instance (already opened as context manager).
        config: LibraryConfig with all settings.
        progress: Optional Rich progress bar.

    Returns:
        Summary dict with keys: discovered, hashed, quarantined, skipped.
    """
    from trove.pipeline import (
        compute_paths,
        discover_and_persist,
        extract_metadata,
        hash_files,
    )

    ids, skip_count = discover_and_persist(source_path, db, config, progress=progress)
    ids = hash_files(ids, db, progress=progress)
    hashed_ids, quarantined_ids = extract_metadata(ids, db, config, progress=progress)
    compute_paths(hashed_ids, db, config)

    return {
        "discovered": len(ids),
        "hashed": len(hashed_ids),
        "quarantined": len(quarantined_ids),
        "skipped": skip_count,
    }
