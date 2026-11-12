"""Composable pipeline stages for file processing.

Each stage takes a list of file record IDs (except discover which produces them)
and returns IDs for the next stage. Side effects are DB updates.
"""

from __future__ import annotations

import errno
import logging
import os
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

from trove.hashing import hash_file
from trove.metadata import extract_metadata_chunked
from trove.normalize import normalize_filename
from trove.plan import FileAction, ImportPlan, InitializePlan
from trove.scan import compute_target_path, discover_files  # noqa: F401
from trove.timeout import (
    copy_file_and_hash,
    ensure_dir,
    hash_path,
    path_exists,
    rename_path,
    run_with_timeout,
    scan_directory,
    unlink_path,
)

if TYPE_CHECKING:
    from rich.progress import Progress

    from trove.config import LibraryConfig
    from trove.db import LibraryRecord, StateDB

logger = logging.getLogger(__name__)


def discover_and_persist(
    source_path: Path,
    db: StateDB,
    config: LibraryConfig,
    skip_paths: set[str] | None = None,
    known_paths: list[Path] | None = None,
    progress: Progress | None = None,
    limit: int | None = None,
) -> tuple[list[int], int]:
    """Walk source directory, insert file records, return IDs of new/reset files.

    Args:
        source_path: Root directory to scan.
        db: StateDB instance.
        config: LibraryConfig with file_types and exclude_patterns.
        skip_paths: Relative paths to exclude (e.g. files already with entries).
        known_paths: If provided, skip directory walk and use these paths.
        progress: Optional Rich progress bar.
        limit: If set, cap discovery at this many files.

    Returns:
        Tuple of (list of new/reset file record IDs, count of skipped unchanged files).
    """
    if known_paths is not None:
        paths = known_paths
    else:
        discover_task_id = None
        if progress is not None:
            discover_task_id = progress.add_task("Discovering files...", total=None)

        # Run discovery inside the worker so scandir/stat on a hung NAS
        # cannot wedge the parent. The on_found callback is omitted since
        # cross-process callbacks are not supported; the spinner covers UX.
        path_strs = run_with_timeout(
            scan_directory,
            str(source_path),
            config.to_json(),
            limit,
            timeout=3600,
        )
        paths = [Path(p) for p in path_strs]

        if progress is not None and discover_task_id is not None:
            progress.update(discover_task_id, description=f"Discovered {len(paths)} files", total=1, completed=1)

    task_id = None
    if progress is not None:
        task_id = progress.add_task("Persisting file records", total=len(paths))

    new_ids: list[int] = []
    skip_count = 0

    for path in paths:
        abs_str = str(path)
        rel_str = str(path.relative_to(source_path))

        if skip_paths and rel_str in skip_paths:
            if progress is not None and task_id is not None:
                progress.update(task_id, advance=1)
            continue

        stat = path.stat()
        file_size = stat.st_size
        mtime_iso = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()

        existing = db.get_file_by_path(abs_str)
        if existing is not None:
            if existing.file_size == file_size and existing.file_modify_date == mtime_iso:
                skip_count += 1
            else:
                # File changed — reset to discovered
                db.update_file(
                    existing.id,
                    file_size=file_size,
                    file_modify_date=mtime_iso,
                    status="discovered",
                    md5_hash=None,
                    capture_date=None,
                    camera_model=None,
                    target_path=None,
                    error_message=None,
                    hashed_at=None,
                )
                new_ids.append(existing.id)
        else:
            rec = db.insert_file(
                source_path=abs_str,
                source_type="local",
                file_size=file_size,
                file_modify_date=mtime_iso,
            )
            new_ids.append(rec.id)

        if progress is not None and task_id is not None:
            progress.update(task_id, advance=1)

    return new_ids, skip_count


def hash_files(
    ids: list[int],
    db: StateDB,
    progress: Progress | None = None,
) -> list[int]:
    """Hash files by ID, update DB with hash and status.

    Files that are missing or unreadable are logged, marked as errored in
    the DB, and excluded from the returned ID list.
    """
    if not ids:
        return ids

    records = db.query_files_by_ids(ids)

    task_id = None
    if progress is not None:
        task_id = progress.add_task("Hashing files", total=len(records))

    hashed_ids: list[int] = []
    for rec in records:
        try:
            file_hash = run_with_timeout(hash_path, rec.source_path, timeout=600)
        except (OSError, TimeoutError):
            logger.warning("Cannot hash %s (missing, unreadable, or timed out), skipping", rec.source_path)
            db.update_file(rec.id, status="quarantined", error_message="hash_failed")
            if progress is not None and task_id is not None:
                progress.update(task_id, advance=1)
            continue
        hash_time = datetime.now(timezone.utc).isoformat()
        db.update_file(rec.id, md5_hash=file_hash, status="hashed", hashed_at=hash_time)
        hashed_ids.append(rec.id)
        if progress is not None and task_id is not None:
            progress.update(task_id, advance=1)

    return hashed_ids


def extract_metadata(
    ids: list[int],
    db: StateDB,
    config: LibraryConfig,
    progress: Progress | None = None,
) -> tuple[list[int], list[int]]:
    """Extract metadata for files, quarantine those with no usable date.

    Returns (hashed_ids, quarantined_ids).
    """
    if not ids:
        return [], []

    records = db.query_files_by_ids(ids)
    current_year = datetime.now().year

    # Extract metadata in chunks
    meta_paths = [Path(r.source_path) for r in records]
    metadata_map = extract_metadata_chunked(meta_paths, progress=progress)

    hashed_ids: list[int] = []
    quarantined_ids: list[int] = []

    for rec in records:
        meta = metadata_map.get(rec.source_path)
        if meta is None and rec.source_path not in metadata_map:
            logger.warning(
                "No metadata returned for %s (exiftool may have failed)",
                rec.source_path,
            )
        capture_date = meta.capture_date if meta else None
        camera_model = meta.camera_model if meta else None

        if capture_date is None:
            # Try filesystem date as fallback
            try:
                fs_dt = datetime.fromisoformat(rec.file_modify_date)
                if 1990 <= fs_dt.year <= current_year + 1:
                    capture_date = fs_dt.strftime("%Y-%m-%dT%H:%M:%S")
                else:
                    db.update_file(
                        rec.id,
                        status="quarantined",
                        error_message="no_date",
                        camera_model=camera_model,
                    )
                    quarantined_ids.append(rec.id)
                    continue
            except (ValueError, TypeError):
                db.update_file(
                    rec.id,
                    status="quarantined",
                    error_message="no_date",
                    camera_model=camera_model,
                )
                quarantined_ids.append(rec.id)
                continue

        db.update_file(
            rec.id,
            capture_date=capture_date,
            camera_model=camera_model,
        )
        hashed_ids.append(rec.id)

    return hashed_ids, quarantined_ids


def compute_paths(
    ids: list[int],
    db: StateDB,
    config: LibraryConfig,
) -> list[int]:
    """Compute target paths for files and update DB.

    Returns the same ID list.
    """
    if not ids:
        return ids

    records = db.query_files_by_ids(ids)

    for rec in records:
        if rec.capture_date is not None:
            original_filename = Path(rec.source_path).name
            target = compute_target_path(rec.capture_date, rec.camera_model, original_filename, config)
            if target is not None:
                db.update_file(rec.id, target_path=target)

    return ids


def classify_for_import(
    ids: list[int],
    db: StateDB,
    library: LibraryRecord,
    config: LibraryConfig,
    progress: Progress | None = None,
) -> ImportPlan:
    """Classify hashed files for import into a library.

    Takes explicit IDs — only those files are considered. Performs batch dedup
    (by hash within the ID set), library dedup (by size then hash against
    existing entries), and path conflict counting.
    """
    records = db.query_files_by_ids(ids)

    # Separate files with/without target_path
    importable = []
    skipped = 0
    for f in records:
        if f.target_path is None:
            skipped += 1
        else:
            importable.append(f)

    if not importable:
        return ImportPlan(skipped=skipped)

    # Batch dedup: group by hash, identify keepers vs duplicates
    by_hash: dict[str, list] = defaultdict(list)
    no_hash: list = []
    for f in importable:
        if f.md5_hash is None:
            no_hash.append(f)
        else:
            by_hash[f.md5_hash].append(f)

    keepers = list(no_hash)
    batch_duplicates = []
    for _hash_val, group in by_hash.items():
        group.sort(key=lambda f: f.id)
        keepers.append(group[0])
        batch_duplicates.extend(group[1:])

    # Library dedup: size-first check, hash on demand
    to_import = []
    library_duplicates = []

    dedup_task_id = None
    if progress is not None:
        dedup_task_id = progress.add_task("Checking for duplicates", total=len(keepers))

    for f in keepers:
        size_matches = db.get_entries_by_size(library.id, f.file_size)
        if not size_matches:
            to_import.append(f)
        else:
            source_hash = f.md5_hash
            if source_hash is None:
                source_hash = hash_file(Path(f.source_path))
                db.update_file(f.id, md5_hash=source_hash)

            is_dup = False
            for entry in size_matches:
                if entry.md5_hash is None:
                    entry_path = Path(library.location) / entry.relative_path
                    try:
                        entry_hash = hash_file(entry_path)
                        db.update_entry_hash(entry.id, entry_hash)
                    except OSError:
                        continue
                    if entry_hash == source_hash:
                        is_dup = True
                        break
                elif entry.md5_hash == source_hash:
                    is_dup = True
                    break

            if is_dup:
                library_duplicates.append(f)
            else:
                to_import.append(f)

        if progress is not None and dedup_task_id is not None:
            progress.update(dedup_task_id, advance=1)

    # Count path conflicts
    path_conflicts = 0
    for f in to_import:
        existing_at_path = db.get_entry_by_path(library.id, f.target_path)
        if existing_at_path is not None:
            path_conflicts += 1

    return ImportPlan(
        to_import=to_import,
        duplicates_in_batch=batch_duplicates,
        duplicates_in_library=library_duplicates,
        path_conflicts=path_conflicts,
        skipped=skipped,
    )


def classify_for_init(
    ids: list[int],
    quarantined_ids: list[int],
    db: StateDB,
    library: LibraryRecord,
    config: LibraryConfig,
) -> InitializePlan:
    """Classify files for in-place library initialization.

    Takes explicit hashed IDs and quarantined IDs. Compares each file's
    current relative path to its computed target path.
    """
    lib_path = Path(library.location)

    # Build claimed paths from existing entries
    claimed_paths: set[str] = set()
    for entry in db.list_entries(library.id):
        claimed_paths.add(entry.relative_path)

    hashed_records = db.query_files_by_ids(ids)
    quarantined_records = db.query_files_by_ids(quarantined_ids)

    already_correct: list[FileAction] = []
    needs_move: list[FileAction] = []
    duplicates: list[FileAction] = []
    quarantined: list[FileAction] = []

    # Handle quarantined files
    for f in quarantined_records:
        # Quarantined files may not have md5_hash - use empty string if None
        md5 = f.md5_hash if f.md5_hash is not None else ""
        original_filename = Path(f.source_path).name
        quarantine_target = f"{config.quarantine.path}{normalize_filename(original_filename)}"
        quarantine_target = _resolve_path(quarantine_target, claimed_paths)
        quarantined.append(
            FileAction(
                source_path=f.source_path,
                relative_path=str(Path(f.source_path).relative_to(lib_path)),
                target_path=quarantine_target,
                md5_hash=md5,
                file_size=f.file_size,
                capture_date=f.capture_date,
                camera_model=f.camera_model,
                action="quarantine",
            )
        )

    # Classify each hashed file
    for f in sorted(hashed_records, key=lambda x: x.id):
        rel_path = str(Path(f.source_path).relative_to(lib_path))
        target = f.target_path

        if target is None:
            continue

        # All hashed records should have md5_hash
        if f.md5_hash is None:
            continue

        resolved_target = _resolve_path(target, claimed_paths)

        if rel_path == resolved_target:
            already_correct.append(
                FileAction(
                    source_path=f.source_path,
                    relative_path=rel_path,
                    target_path=resolved_target,
                    md5_hash=f.md5_hash,
                    file_size=f.file_size,
                    capture_date=f.capture_date,
                    camera_model=f.camera_model,
                    action="index",
                )
            )
        else:
            needs_move.append(
                FileAction(
                    source_path=f.source_path,
                    relative_path=rel_path,
                    target_path=resolved_target,
                    md5_hash=f.md5_hash,
                    file_size=f.file_size,
                    capture_date=f.capture_date,
                    camera_model=f.camera_model,
                    action="move",
                )
            )

    total = len(already_correct) + len(needs_move) + len(duplicates) + len(quarantined)
    return InitializePlan(
        already_correct=already_correct,
        needs_move=needs_move,
        duplicates=duplicates,
        quarantined=quarantined,
        total_files=total,
    )


def _resolve_path(target_path: str, claimed: set[str]) -> str:
    """Resolve a target path against claimed paths, suffixing if needed.

    Mutates ``claimed`` — the resolved path is added to the set so subsequent
    calls see it as taken.  Callers must pass the same set across all files
    in a single classification run to avoid collisions.
    """
    if target_path not in claimed:
        claimed.add(target_path)
        return target_path

    if "/" in target_path:
        dir_part, filename = target_path.rsplit("/", 1)
    else:
        dir_part, filename = "", target_path

    stem, ext = os.path.splitext(filename)

    for i in range(1, 10000):
        candidate = f"{stem}-{i}{ext}"
        candidate_path = f"{dir_part}/{candidate}" if dir_part else candidate
        if candidate_path not in claimed:
            claimed.add(candidate_path)
            return candidate_path

    raise RuntimeError(f"Cannot resolve path for {target_path}")


def _copy_and_verify(source: Path, dest: Path, expected_hash: str, chunk_size: int = 8192) -> bool:
    """Copy a file and verify the copy via hash comparison.

    Returns True if copy succeeded and hash matches, False otherwise.
    Only cleans up the destination on failure if it did not exist before
    the copy started — pre-existing files are never deleted.
    """
    run_with_timeout(ensure_dir, str(dest.parent))

    # Never overwrite a pre-existing file — caller should have resolved
    # path conflicts before we get here.
    if run_with_timeout(path_exists, str(dest), timeout=10):
        logger.warning("Destination already exists, refusing to overwrite: %s", dest)
        return False

    try:
        result_hash = run_with_timeout(
            copy_file_and_hash,
            str(source),
            str(dest),
            chunk_size=chunk_size,
            timeout=600,
        )
        if result_hash == expected_hash:
            return True
        # Hash mismatch — clean up the file we just created
        try:
            run_with_timeout(unlink_path, str(dest), missing_ok=True, timeout=10)
        except (OSError, TimeoutError):
            pass
        return False
    except TimeoutError:
        # Mount is dead — skip cleanup to avoid burning another timeout window
        raise
    except OSError:
        try:
            run_with_timeout(unlink_path, str(dest), missing_ok=True, timeout=10)
        except (OSError, TimeoutError):
            pass
        return False


def move_file(
    source: Path,
    dest: Path,
    expected_hash: str,
    lib_path: Path | None = None,
) -> tuple[bool, str]:
    """Move a file from source to dest, verifying integrity.

    Tries os.rename first (atomic, same filesystem). If cross-device,
    falls back to copy+verify+delete.

    Args:
        source: Source file path
        dest: Destination file path
        expected_hash: MD5 hash to verify against
        lib_path: Library root for cleanup of empty directories (optional)

    Returns (success, hash) where hash is the expected_hash on success.
    """
    from trove.timeout import move_and_cleanup

    if lib_path is not None:
        # Use batched operation (single worker call, includes cleanup)
        success, result_hash, _was_copy = run_with_timeout(
            move_and_cleanup,
            str(source),
            str(dest),
            str(lib_path),
            expected_hash,
            timeout=600,
        )
        return (success, result_hash)

    # Legacy path: individual operations (for backwards compatibility)
    run_with_timeout(ensure_dir, str(dest.parent))
    try:
        run_with_timeout(rename_path, str(source), str(dest))
        return (True, expected_hash)
    except OSError as e:
        if e.errno == errno.EXDEV:
            if _copy_and_verify(source, dest, expected_hash):
                try:
                    run_with_timeout(unlink_path, str(source), timeout=10)
                except (OSError, TimeoutError) as unlink_err:
                    logger.warning(
                        "Failed to remove source after verified copy: %s -> %s (%s)",
                        source,
                        dest,
                        unlink_err,
                    )
                return (True, expected_hash)
            return (False, expected_hash)
        raise
