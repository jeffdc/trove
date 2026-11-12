"""Import module — deduplicates scanned files and promotes them into a library."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import TYPE_CHECKING

from trove.config import LibraryConfig
from trove.db import LibraryRecord, StateDB
from trove.fs_dates import stamp_creation_date
from trove.pipeline import _copy_and_verify, classify_for_import
from trove.plan import ImportPlan
from trove.timeout import hash_path, path_exists, run_with_timeout

if TYPE_CHECKING:
    from rich.progress import Progress

    from trove.audit import AuditLogger

logger = logging.getLogger(__name__)


def plan_import(
    db: StateDB,
    library: LibraryRecord,
    config: LibraryConfig,
    progress: Progress | None = None,
) -> ImportPlan:
    """Build an import plan by classifying hashed files.

    Delegates to classify_for_import with all currently hashed file IDs.
    """
    all_hashed = db.query_files_by_status("hashed")
    ids = [f.id for f in all_hashed]
    return classify_for_import(ids, db, library, config, progress=progress)


def execute_import(
    db: StateDB,
    library: LibraryRecord,
    config: LibraryConfig,
    plan: ImportPlan,
    audit: AuditLogger | None = None,
    progress: Progress | None = None,
) -> dict:
    """Execute an import plan: mark duplicates, copy files, create entries.

    Args:
        db: Open StateDB instance.
        library: Target library record.
        config: LibraryConfig with settings.
        plan: ImportPlan from plan_import.
        audit: Optional audit logger.
        progress: Optional Rich progress bar.

    Returns:
        Summary dict with keys: imported, duplicates_in_batch, duplicates_in_library,
        path_conflicts, skipped, errors.
    """
    summary = {
        "imported": 0,
        "duplicates_in_batch": len(plan.duplicates_in_batch),
        "duplicates_in_library": len(plan.duplicates_in_library),
        "path_conflicts": 0,
        "skipped": plan.skipped,
        "errors": 0,
    }

    # Step 1: Mark batch duplicates
    for dup in plan.duplicates_in_batch:
        db.update_file(dup.id, status="duplicate")
        if audit is not None:
            if dup.md5_hash is None:
                raise RuntimeError("Duplicate must have md5_hash")
            audit.log_skip_duplicate(source=dup.source_path, md5_hash=dup.md5_hash, library=library.name)

    # Step 2: Mark library duplicates
    for dup in plan.duplicates_in_library:
        db.update_file(dup.id, status="duplicate")
        if audit is not None:
            if dup.md5_hash is None:
                raise RuntimeError("Duplicate must have md5_hash")
            audit.log_skip_duplicate(source=dup.source_path, md5_hash=dup.md5_hash, library=library.name)

    # Step 3: Re-query to_import files from DB (statuses may have changed above)
    to_import_ids = [f.id for f in plan.to_import]
    to_import = db.query_files_by_ids(to_import_ids)

    import_task_id = None
    if progress is not None:
        import_task_id = progress.add_task("Importing files", total=len(to_import))

    for file_rec in to_import:
        try:
            # All files in to_import should have been hashed and have target paths
            if file_rec.target_path is None:
                raise RuntimeError("File must have target_path")
            if file_rec.md5_hash is None:
                raise RuntimeError("File must have md5_hash")

            # Resolve path conflicts
            resolved_path = _resolve_target_path(db, library.id, file_rec.target_path)
            if resolved_path != file_rec.target_path:
                summary["path_conflicts"] += 1

            dest_path = Path(library.location) / resolved_path

            # Check for resume/orphan/untracked file at destination
            needs_copy = True
            if run_with_timeout(path_exists, str(dest_path), timeout=10):
                existing_hash = run_with_timeout(hash_path, str(dest_path), timeout=600)
                if existing_hash == file_rec.md5_hash:
                    # Matching file already at destination — skip the copy
                    logger.info(
                        "Orphan recovery: %s already at %s with matching hash, skipping copy",
                        file_rec.source_path,
                        dest_path,
                    )
                    needs_copy = False
                else:
                    # Different file exists at target path (untracked or corrupt orphan)
                    # Do NOT delete it — suffix our file instead and warn
                    logger.warning(
                        "Untracked file at %s (hash %s) differs from source (hash %s). "
                        "Importing source with a suffixed name.",
                        dest_path,
                        existing_hash[:12] if existing_hash else "none",
                        file_rec.md5_hash[:12] if file_rec.md5_hash else "none",
                    )
                    resolved_path = _resolve_target_path_on_disk(Path(library.location), resolved_path)
                    dest_path = Path(library.location) / resolved_path
                    summary["path_conflicts"] += 1

            # Copy file
            if needs_copy:
                success = _copy_and_verify(Path(file_rec.source_path), dest_path, file_rec.md5_hash)
                if not success:
                    # Retry once
                    success = _copy_and_verify(Path(file_rec.source_path), dest_path, file_rec.md5_hash)
                if not success:
                    logger.error(
                        "Copy verification failed for %s -> %s",
                        file_rec.source_path,
                        dest_path,
                    )
                    summary["errors"] += 1
                    if progress is not None and import_task_id is not None:
                        progress.update(import_task_id, advance=1)
                    continue

            # Atomic DB update
            entry = db.import_file(
                file_rec.id,
                library.id,
                resolved_path,
                file_rec.file_size,
                file_rec.md5_hash,
                file_rec.capture_date,
                file_rec.camera_model,
            )
            summary["imported"] += 1
            if stamp_creation_date(dest_path, file_rec.capture_date):
                db.mark_entry_creation_date_stamped(entry.id)
            if audit is not None:
                audit.log_import(
                    source=file_rec.source_path,
                    destination=str(dest_path),
                    md5_hash=file_rec.md5_hash,
                    size=file_rec.file_size,
                    library=library.name,
                )

        except TimeoutError:
            logger.exception("Timed out importing file %s", file_rec.source_path)
            summary["errors"] += 1
            break
        except Exception:
            logger.exception("Error importing file %s", file_rec.source_path)
            summary["errors"] += 1

        if progress is not None and import_task_id is not None:
            progress.update(import_task_id, advance=1)

    return summary


def import_to_library(
    db: StateDB,
    library: LibraryRecord,
    config: LibraryConfig,
    dry_run: bool = False,
    audit: AuditLogger | None = None,
    progress: Progress | None = None,
) -> dict:
    """Deduplicate and import scanned files into a library.

    Backward-compatible wrapper around plan_import + execute_import.

    Args:
        db: Open StateDB instance.
        library: Target library record.
        config: LibraryConfig with settings.
        dry_run: If True, report what would happen without copying or creating entries.
        audit: Optional audit logger.
        progress: Optional Rich progress bar.

    Returns:
        Summary dict with keys: imported, duplicates_in_batch, duplicates_in_library,
        path_conflicts, skipped, errors.
    """
    plan = plan_import(db, library, config)

    if dry_run:
        return {
            "imported": len(plan.to_import),
            "duplicates_in_batch": len(plan.duplicates_in_batch),
            "duplicates_in_library": len(plan.duplicates_in_library),
            "path_conflicts": plan.path_conflicts,
            "skipped": plan.skipped,
            "errors": 0,
        }

    return execute_import(db, library, config, plan, audit=audit, progress=progress)


def _resolve_target_path(db: StateDB, library_id: int, target_path: str) -> str:
    """Resolve path conflicts by auto-suffixing if needed."""
    existing = db.get_entry_by_path(library_id, target_path)
    if existing is None:
        return target_path

    # Need to suffix. Split the path to get directory and filename parts.
    parts = target_path.rsplit("/", 1)
    if len(parts) == 2:
        dir_part, filename = parts
    else:
        dir_part, filename = "", parts[0]

    stem, ext = os.path.splitext(filename)

    for i in range(1, 10000):
        candidate = f"{stem}-{i}{ext}"
        if dir_part:
            candidate_path = f"{dir_part}/{candidate}"
        else:
            candidate_path = candidate
        if db.get_entry_by_path(library_id, candidate_path) is None:
            return candidate_path

    raise RuntimeError(f"Could not resolve path conflict for {target_path} after 10000 attempts")


def _resolve_target_path_on_disk(
    library_path: Path,
    target_path: str,
) -> str:
    """Resolve a target path against files on disk, suffixing if needed.

    Unlike _resolve_target_path which checks the DB, this checks the actual
    filesystem for conflicts with untracked files.
    """
    if not run_with_timeout(path_exists, str(library_path / target_path), timeout=10):
        return target_path

    parts = target_path.rsplit("/", 1)
    if len(parts) == 2:
        dir_part, filename = parts
    else:
        dir_part, filename = "", parts[0]

    stem, ext = os.path.splitext(filename)

    for i in range(1, 10000):
        candidate = f"{stem}-{i}{ext}"
        candidate_path = f"{dir_part}/{candidate}" if dir_part else candidate
        if not run_with_timeout(path_exists, str(library_path / candidate_path), timeout=10):
            return candidate_path

    raise RuntimeError(f"Could not resolve disk path conflict for {target_path} after 10000 attempts")
