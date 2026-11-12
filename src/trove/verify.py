"""Library verification — check that DB records match what's on disk."""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from trove.db import LibraryRecord, StateDB
from trove.hashing import hash_file

if TYPE_CHECKING:
    from rich.progress import Progress

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class VerifyResult:
    entries_checked: int
    files_on_disk: int
    verified_ok: int
    missing_from_disk: list[str] = field(default_factory=list)
    orphan_files: list[str] = field(default_factory=list)
    size_mismatches: list[str] = field(default_factory=list)
    hash_mismatches: list[str] = field(default_factory=list)
    is_healthy: bool = True


def _walk_files(directory: Path, progress: Progress | None = None) -> list[Path]:
    """Recursively find all files under *directory* using os.scandir."""
    result: list[Path] = []
    scan_task_id = None
    if progress is not None:
        scan_task_id = progress.add_task("Scanning library", total=None)

    def _scan(d: Path) -> None:
        try:
            entries = os.scandir(d)
        except PermissionError:
            return

        with entries:
            for entry in entries:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        _scan(Path(entry.path))
                        continue
                    if entry.is_file(follow_symlinks=True):
                        result.append(Path(entry.path))
                        if progress is not None and scan_task_id is not None:
                            progress.update(scan_task_id, advance=1)
                except OSError:
                    continue

    _scan(directory)
    result.sort()
    if progress is not None and scan_task_id is not None:
        progress.remove_task(scan_task_id)
    return result


def verify_library(
    db: StateDB,
    library: LibraryRecord,
    thorough: bool = False,
    progress: Progress | None = None,
) -> VerifyResult:
    """Check that a library's DB records match what's on disk.

    Args:
        db: Open StateDB instance.
        library: Library to verify.
        thorough: If True, hash every file and compare to DB.

    Returns:
        VerifyResult with details of any issues found.

    Raises:
        ValueError: If library location is not accessible.
    """
    lib_dir = Path(library.location)
    if not lib_dir.is_dir():
        raise ValueError(f"Library location '{library.location}' is not accessible")

    # --- Check entries against disk ---
    entries = db.list_entries(library.id)
    verified_ok = 0
    missing_from_disk: list[str] = []
    size_mismatches: list[str] = []
    hash_mismatches: list[str] = []

    verify_task_id = None
    if progress is not None:
        verify_task_id = progress.add_task("Verifying entries", total=len(entries))

    for entry in entries:
        full_path = lib_dir / entry.relative_path

        if not full_path.exists():
            missing_from_disk.append(entry.relative_path)
            logger.warning("Missing from disk: %s", entry.relative_path)
            if progress is not None and verify_task_id is not None:
                progress.update(verify_task_id, advance=1)
            continue

        stat = full_path.stat()
        if stat.st_size != entry.file_size:
            size_mismatches.append(entry.relative_path)
            logger.warning(
                "Size mismatch: %s (db=%d, disk=%d)",
                entry.relative_path,
                entry.file_size,
                stat.st_size,
            )
            if progress is not None and verify_task_id is not None:
                progress.update(verify_task_id, advance=1)
            continue

        if thorough:
            disk_hash = hash_file(full_path)
            if disk_hash != entry.md5_hash:
                hash_mismatches.append(entry.relative_path)
                logger.warning(
                    "Hash mismatch: %s (db=%s, disk=%s)",
                    entry.relative_path,
                    entry.md5_hash,
                    disk_hash,
                )
                if progress is not None and verify_task_id is not None:
                    progress.update(verify_task_id, advance=1)
                continue

        verified_ok += 1
        if progress is not None and verify_task_id is not None:
            progress.update(verify_task_id, advance=1)

    # --- Check disk against entries (find orphans) ---
    disk_files = _walk_files(lib_dir, progress=progress)
    orphan_files: list[str] = []

    for file_path in disk_files:
        relative = file_path.relative_to(lib_dir)
        relative_str = str(relative)
        if db.get_entry_by_path(library.id, relative_str) is None:
            orphan_files.append(relative_str)
            logger.warning("Orphan file: %s", relative_str)

    is_healthy = (
        len(missing_from_disk) == 0
        and len(orphan_files) == 0
        and len(size_mismatches) == 0
        and len(hash_mismatches) == 0
    )

    return VerifyResult(
        entries_checked=len(entries),
        files_on_disk=len(disk_files),
        verified_ok=verified_ok,
        missing_from_disk=missing_from_disk,
        orphan_files=orphan_files,
        size_mismatches=size_mismatches,
        hash_mismatches=hash_mismatches,
        is_healthy=is_healthy,
    )
