"""Complete module — final pipeline step that asserts all files are accounted for
and cleans up file records from the working table."""

from __future__ import annotations

import logging
from dataclasses import dataclass

from trove.db import LibraryRecord, StateDB
from trove.plan import CompletePlan

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class CompleteResult:
    imported: int
    duplicate: int
    quarantined: int
    unaccounted: int  # files still at discovered/hashed — blocks completion
    records_cleaned: int  # file records removed from DB
    can_complete: bool  # True if unaccounted == 0


def plan_complete(
    db: StateDB,
    library: LibraryRecord,
) -> CompletePlan:
    """Build a read-only plan for completing an import.

    Queries files by status, verifies imported files have matching library
    entries, and classifies everything into the plan buckets.

    Args:
        db: Open StateDB instance.
        library: Target library record.

    Returns:
        CompletePlan with files classified by status.
    """
    imported = db.query_files_by_status("imported")
    duplicate = db.query_files_by_status("duplicate")
    quarantined = db.query_files_by_status("quarantined")
    discovered = db.query_files_by_status("discovered")
    hashed = db.query_files_by_status("hashed")

    unaccounted = list(discovered) + list(hashed)

    # Verify imported files have corresponding entries in the library.
    # If an imported file has no matching entry, it's unaccounted for.
    verified_imported = []
    for f in imported:
        if f.md5_hash is None:
            # Files without hashes can't be verified
            unaccounted.append(f)
            continue
        entries = db.get_entries_by_hash(library.id, f.md5_hash)
        if entries:
            verified_imported.append(f)
        else:
            unaccounted.append(f)

    return CompletePlan(
        imported=verified_imported,
        duplicate=list(duplicate),
        quarantined=list(quarantined),
        unaccounted=unaccounted,
    )


def execute_complete(
    db: StateDB,
    library: LibraryRecord,
    plan: CompletePlan,
) -> CompleteResult:
    """Execute a completion plan: clean up file records from the DB.

    This only removes transient file records from the working table.
    It never deletes files from disk.

    Args:
        db: Open StateDB instance.
        library: Target library record.
        plan: A CompletePlan from plan_complete().

    Returns:
        CompleteResult with counts.
    """
    db.delete_files_by_status(["imported", "duplicate", "quarantined"])

    records_cleaned = len(plan.imported) + len(plan.duplicate) + len(plan.quarantined)

    return CompleteResult(
        imported=len(plan.imported),
        duplicate=len(plan.duplicate),
        quarantined=len(plan.quarantined),
        unaccounted=0,
        records_cleaned=records_cleaned,
        can_complete=True,
    )


def complete_import(
    db: StateDB,
    library: LibraryRecord,
) -> CompleteResult:
    """Assert all scanned files are accounted for, then clean up.

    Backward-compatible wrapper around plan_complete + execute_complete.
    """
    plan = plan_complete(db, library)

    if not plan.can_complete:
        return CompleteResult(
            imported=len(plan.imported),
            duplicate=len(plan.duplicate),
            quarantined=len(plan.quarantined),
            unaccounted=len(plan.unaccounted),
            records_cleaned=0,
            can_complete=False,
        )

    return execute_complete(db, library, plan)
