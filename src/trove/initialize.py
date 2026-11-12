"""Library initialization module — scan, classify, and organize existing files in-place.

Each step persists to DB as it goes, so the process is resumable after interruption.
Hashing is deferred — only files that need to move get hashed (for verification).
"""

from __future__ import annotations

import logging
import signal
import time
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING

from trove.config import LibraryConfig
from trove.db import LibraryRecord, StateDB
from trove.pipeline import (
    classify_for_init,
    compute_paths,
    discover_and_persist,
    extract_metadata,
    hash_files,
    move_file,
)
from trove.plan import FileAction, InitializePlan, InitializeResult
from trove.timeout import hash_path, path_exists, path_size, run_with_timeout, stat_path

if TYPE_CHECKING:
    from rich.progress import Progress

    from trove.audit import AuditLogger

logger = logging.getLogger(__name__)

# Module-level stop flag, set by signal handlers.
_stop_requested = False
_last_mount_check = 0.0
_MOUNT_CHECK_INTERVAL_SECONDS = 5.0


def _request_stop(signum: int, frame: object) -> None:
    """Signal handler that sets the stop flag."""
    global _stop_requested  # noqa: PLW0603
    _stop_requested = True
    logger.info("Stop requested (signal %s), finishing current file...", signum)


def _check_should_continue(lib_path: Path) -> None:
    """Check if we should continue processing. Raises on stop conditions.

    Checks:
    1. Whether a signal (SIGINT/SIGTERM) requested a stop.
    2. Whether the library path is still accessible (mount health check).

    Raises:
        InterruptedError: If a stop was requested via signal.
        OSError/TimeoutError: If the library path is not accessible or hung.
    """
    global _last_mount_check  # noqa: PLW0603

    if _stop_requested:
        raise InterruptedError("Stop requested by signal")

    now = time.monotonic()
    if now - _last_mount_check < _MOUNT_CHECK_INTERVAL_SECONDS:
        return

    run_with_timeout(stat_path, str(lib_path), timeout=10)
    _last_mount_check = now


def plan_initialize(
    library: LibraryRecord,
    db: StateDB,
    config: LibraryConfig,
    progress: Progress | None = None,
    known_paths: list[Path] | None = None,
    limit: int | None = None,
) -> InitializePlan:
    """Build an initialization plan, persisting progress to DB at each step.

    Steps:
    1. Discover files → write file records to DB
    2. Hash files → compute MD5 for each file
    3. Extract metadata (chunked exiftool) → update file records
    4. Compute target paths → set target_path on each file record
    5. Classify from DB → build plan

    Each step is resumable: re-running skips work already done.

    Args:
        known_paths: If provided, skip discovery and use these paths instead.
                     Avoids redundant directory walks when CLI already discovered.
        limit: If set, cap file discovery at this many files.
    """
    lib_path = Path(library.location)

    # Build skip_paths from existing entries
    skip_paths = {e.relative_path for e in db.list_entries(library.id)}

    ids, _ = discover_and_persist(
        lib_path, db, config, skip_paths=skip_paths, known_paths=known_paths, progress=progress, limit=limit
    )
    ids = hash_files(ids, db, progress=progress)
    hashed, quarantined = extract_metadata(ids, db, config, progress=progress)
    compute_paths(hashed, db, config)

    # For resume: include any previously processed file records not in this run,
    # but scoped to this library's location to avoid cross-library leaks.
    lib_prefix = str(lib_path) + "/"
    all_hashed_ids = set(hashed)
    all_hashed_ids.update(f.id for f in db.query_files_by_status("hashed") if f.source_path.startswith(lib_prefix))
    all_quarantined_ids = set(quarantined)
    all_quarantined_ids.update(
        f.id for f in db.query_files_by_status("quarantined") if f.source_path.startswith(lib_prefix)
    )

    return classify_for_init(list(all_hashed_ids), list(all_quarantined_ids), db, library, config)


class _MissingFile(Exception):
    """Raised when a source file is missing and cannot be recovered."""

    def __init__(self, error_message: str) -> None:
        self.error_message = error_message
        super().__init__(error_message)


def _move_and_create_entry(
    action: FileAction,
    lib_path: Path,
    library: LibraryRecord,
    db: StateDB,
    audit: AuditLogger | None,
    audit_event: str,
) -> bool:
    """Move a file and create its library entry. Returns True on success.

    On entry creation failure, moves the file back to its original location.

    If relative_path == target_path the file is already in place: creates the
    entry with a null hash (no verification needed) and returns True.

    If the source file is missing, attempts orphan recovery: checks if the
    file already exists at the destination with matching size+hash. If so,
    creates the entry and returns True. Otherwise raises _MissingFile.
    """
    source = lib_path / action.relative_path
    dest = lib_path / action.target_path

    # File already at correct location — just create the entry.
    if action.relative_path == action.target_path:
        db.create_entry(
            library.id,
            action.target_path,
            action.file_size,
            None,
            action.capture_date,
            action.camera_model,
        )
        if audit is not None:
            audit.log(audit_event, path=action.target_path, library=library.name)
        return True

    # Source missing — attempt orphan recovery
    if not run_with_timeout(path_exists, str(source), timeout=10):
        return _recover_orphan(action, dest, lib_path, library, db, audit, audit_event)

    # Normal move using hash from plan (already computed during planning phase).
    # Pass lib_path to enable batched operation (includes cleanup).
    success, result_hash = move_file(source, dest, action.md5_hash, lib_path=lib_path)

    if not success:
        logger.error("Failed to move %s -> %s", source, dest)
        return False

    try:
        db.create_entry(
            library.id,
            action.target_path,
            action.file_size,
            result_hash,
            action.capture_date,
            action.camera_model,
            original_path=action.relative_path,
        )
    except Exception:
        logger.error("Entry creation failed for %s, moving back", action.target_path)
        try:
            move_file(dest, source, result_hash, lib_path=lib_path)
        except Exception:
            logger.critical(
                "CRITICAL: File at %s has no entry and could not be moved back to %s. Manual recovery needed.",
                dest,
                source,
            )
        return False

    if audit is not None:
        audit.log(
            audit_event,
            source=action.relative_path,
            destination=action.target_path,
            md5_hash=result_hash,
            library=library.name,
        )

    # Cleanup is now done inside move_file via move_and_cleanup
    return True


def _recover_orphan(
    action: FileAction,
    dest: Path,
    lib_path: Path,
    library: LibraryRecord,
    db: StateDB,
    audit: AuditLogger | None,
    audit_event: str,
) -> bool:
    """Try to recover a file whose source is missing.

    Checks multiple candidate locations for the file:
    1. The plan's target path (may be suffixed due to conflict resolution)
    2. The file record's original target path (unsuffixed)

    If found with matching size+hash, create the entry (if needed) and return True.
    Otherwise, mark the file as missing and raise _MissingFile.
    """
    file_rec = db.get_file_by_path(action.source_path)

    def _mark_missing(error_message: str) -> None:
        if file_rec is not None:
            db.update_file(file_rec.id, status="missing", error_message=error_message)

    # Build candidate paths to check — the plan target and the file record's target
    candidates: list[Path] = [dest]
    if file_rec is not None and file_rec.target_path and file_rec.target_path != action.target_path:
        candidates.append(lib_path / file_rec.target_path)

    found_but_mismatched = False
    for candidate in candidates:
        if not run_with_timeout(path_exists, str(candidate), timeout=10):
            continue
        if run_with_timeout(path_size, str(candidate), timeout=10) != action.file_size:
            found_but_mismatched = True
            continue
        candidate_hash = run_with_timeout(hash_path, str(candidate), timeout=600)
        if candidate_hash != action.md5_hash:
            found_but_mismatched = True
            continue

        # Found the file — recover it
        candidate_rel = str(candidate.relative_to(lib_path))
        existing_entry = db.get_entry_by_path(library.id, candidate_rel)
        if existing_entry is None:
            db.create_entry(
                library.id,
                candidate_rel,
                action.file_size,
                candidate_hash,
                action.capture_date,
                action.camera_model,
                original_path=action.relative_path,
            )

        if audit is not None:
            audit.log(
                audit_event + "_recovered",
                source=action.relative_path,
                destination=candidate_rel,
                md5_hash=candidate_hash,
                library=library.name,
            )
        return True

    # Not found at any candidate location
    if found_but_mismatched:
        _mark_missing("source_missing_dest_mismatch")
        raise _MissingFile("source_missing_dest_mismatch")
    _mark_missing("source_missing")
    raise _MissingFile("source_missing")


def execute_initialize(
    library: LibraryRecord,
    db: StateDB,
    plan: InitializePlan,
    audit: AuditLogger | None = None,
    progress: Progress | None = None,
    on_error: Callable[[str, str, int], bool] | None = None,
) -> InitializeResult:
    """Execute an initialization plan: index, move, and create DB entries.

    - Files at correct path: create entry with no hash (no verification needed)
    - Files needing move: use plan hash, verify only on cross-device copy
    - Each file's working record is deleted from the files table after success
    - Checks for stop signals and mount health between each file

    Args:
        on_error: Optional callback(path, reason, error_count) -> should_continue.
                  Called on each file error. Return False to abort.
    """
    global _last_mount_check, _stop_requested  # noqa: PLW0603
    _stop_requested = False
    _last_mount_check = 0.0

    # Install SIGTERM handler for graceful stop (scripts/daemons).
    # Do NOT trap SIGINT — let Ctrl-C kill the process immediately.
    prev_sigterm = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, _request_stop)

    lib_path = Path(library.location)
    indexed = 0
    moved = 0
    dup_count = 0
    quarantined_count = 0
    errors = 0
    stopped_early = False

    def _cleanup_file_record(source_path: str) -> None:
        """Delete the file record from the files table immediately after success."""
        file_rec = db.get_file_by_path(source_path)
        if file_rec is not None:
            db.delete_file(file_rec.id)

    def _handle_error(path: str, exc: Exception) -> bool:
        """Record an error. Returns True if execution should stop."""
        nonlocal errors, stopped_early
        errors += 1
        if isinstance(exc, _MissingFile):
            if "mismatch" in exc.error_message:
                reason = "missing from source, different file at destination"
            else:
                reason = "missing from source and destination"
        elif isinstance(exc, TimeoutError):
            reason = "operation timed out — mount may be unavailable"
        elif isinstance(exc, FileNotFoundError):
            reason = "file not found"
        elif isinstance(exc, PermissionError):
            reason = "permission denied"
        elif isinstance(exc, OSError):
            reason = exc.strerror or str(exc)
        else:
            reason = str(exc) or type(exc).__name__
        logger.debug("Error processing %s: %s", path, exc)
        if on_error is not None:
            if not on_error(path, reason, errors):
                stopped_early = True
                return True
        else:
            logger.warning("%s — %s", path, reason)
        if isinstance(exc, TimeoutError):
            stopped_early = True
            return True
        return False

    total_actions = len(plan.already_correct) + len(plan.needs_move) + len(plan.duplicates) + len(plan.quarantined)
    task_id = None
    if progress is not None:
        task_id = progress.add_task("Initializing library", total=total_actions)

    try:
        # 1. Index files already at correct path (no hash needed, no move)
        for action in plan.already_correct:
            try:
                _check_should_continue(lib_path)
            except (InterruptedError, OSError, TimeoutError) as e:
                logger.info("Stopping: %s", e)
                stopped_early = True
                break
            try:
                db.create_entry(
                    library.id,
                    action.target_path,
                    action.file_size,
                    None,  # no hash — file didn't move, no verification needed
                    action.capture_date,
                    action.camera_model,
                )
                indexed += 1
                _cleanup_file_record(action.source_path)
                if audit is not None:
                    audit.log("initialize_index", path=action.target_path, library=library.name)
            except Exception as exc:
                if _handle_error(action.source_path, exc):
                    break
            if progress is not None and task_id is not None:
                progress.update(task_id, advance=1)

        # 2. Move files to correct path
        if not stopped_early:
            for action in plan.needs_move:
                try:
                    _check_should_continue(lib_path)
                except (InterruptedError, OSError, TimeoutError) as e:
                    logger.info("Stopping: %s", e)
                    stopped_early = True
                    break
                try:
                    if _move_and_create_entry(action, lib_path, library, db, audit, "initialize_move"):
                        moved += 1
                        _cleanup_file_record(action.source_path)
                    else:
                        errors += 1
                except Exception as exc:
                    if _handle_error(action.source_path, exc):
                        break
                if progress is not None and task_id is not None:
                    progress.update(task_id, advance=1)

        # 3. Handle duplicates (may need to move, create entry)
        if not stopped_early:
            for action in plan.duplicates:
                try:
                    _check_should_continue(lib_path)
                except (InterruptedError, OSError, TimeoutError) as e:
                    logger.info("Stopping: %s", e)
                    stopped_early = True
                    break
                try:
                    if _move_and_create_entry(action, lib_path, library, db, audit, "initialize_duplicate"):
                        dup_count += 1
                        _cleanup_file_record(action.source_path)
                    else:
                        errors += 1
                except Exception as exc:
                    if _handle_error(action.source_path, exc):
                        break
                if progress is not None and task_id is not None:
                    progress.update(task_id, advance=1)

        # 4. Handle quarantined files
        if not stopped_early:
            for action in plan.quarantined:
                try:
                    _check_should_continue(lib_path)
                except (InterruptedError, OSError, TimeoutError) as e:
                    logger.info("Stopping: %s", e)
                    stopped_early = True
                    break
                try:
                    if _move_and_create_entry(action, lib_path, library, db, audit, "initialize_quarantine"):
                        quarantined_count += 1
                        _cleanup_file_record(action.source_path)
                    else:
                        errors += 1
                except Exception as exc:
                    if _handle_error(action.source_path, exc):
                        break
                if progress is not None and task_id is not None:
                    progress.update(task_id, advance=1)

    finally:
        signal.signal(signal.SIGTERM, prev_sigterm)

    return InitializeResult(
        indexed=indexed,
        moved=moved,
        duplicates=dup_count,
        quarantined=quarantined_count,
        errors=errors,
    )
