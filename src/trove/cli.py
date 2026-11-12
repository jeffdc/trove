"""Trove CLI — Click commands wiring all modules together."""

from __future__ import annotations

import os
import re
import sqlite3
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import click

from trove.audit import AuditLogger
from trove.cli_helpers import prompt_for_path, resolve_library
from trove.complete import execute_complete, plan_complete
from trove.config import LibraryConfig, OrganizationConfig
from trove.db import EntryRecord, StateDB
from trove.fs_dates import stamp_creation_date
from trove.hashing import hash_files_parallel
from trove.importer import execute_import
from trove.initialize import execute_initialize, plan_initialize
from trove.pipeline import (
    classify_for_import,
    compute_paths,
    discover_and_persist,
    extract_metadata,
    hash_files,
)
from trove.progress import create_progress
from trove.timeout import path_exists, run_with_timeout
from trove.verify import verify_library

_DUPLICATE_SUFFIX_RE = re.compile(r"_(\d+)$")


@dataclass(frozen=True)
class DuplicateCleanupGroup:
    md5_hash: str
    keeper: EntryRecord
    non_keepers: list[EntryRecord]


def _entry_absolute_path(library_location: str, entry: EntryRecord) -> Path:
    return Path(library_location) / entry.relative_path


def _entry_has_duplicate_suffix(entry: EntryRecord) -> bool:
    return _DUPLICATE_SUFFIX_RE.search(Path(entry.relative_path).stem) is not None


def _entry_matches_original_basename(entry: EntryRecord) -> bool:
    if not entry.original_path:
        return False
    return Path(entry.relative_path).name == Path(entry.original_path).name


def _select_duplicate_keeper(entries: list[EntryRecord]) -> EntryRecord:
    return min(
        entries,
        key=lambda entry: (
            0 if _entry_matches_original_basename(entry) else 1,
            0 if not _entry_has_duplicate_suffix(entry) else 1,
            entry.id,
        ),
    )


def _analyze_duplicate_cleanup(groups: list[list[EntryRecord]]) -> list[DuplicateCleanupGroup]:
    analyses: list[DuplicateCleanupGroup] = []
    for group in groups:
        if not group or group[0].md5_hash is None:
            continue
        ordered = sorted(group, key=lambda entry: entry.id)
        keeper = _select_duplicate_keeper(ordered)
        non_keepers = [entry for entry in ordered if entry.id != keeper.id]
        analyses.append(
            DuplicateCleanupGroup(
                md5_hash=group[0].md5_hash,
                keeper=keeper,
                non_keepers=non_keepers,
            )
        )
    return analyses


def _write_delete_list(delete_list_path: Path, library_location: str, groups: list[DuplicateCleanupGroup]) -> None:
    delete_paths = sorted(
        str(_entry_absolute_path(library_location, entry))
        for group in groups
        for entry in group.non_keepers
    )
    contents = "\n".join(delete_paths)
    if contents:
        contents += "\n"
    delete_list_path.parent.mkdir(parents=True, exist_ok=True)
    delete_list_path.write_text(contents)


@click.group()
@click.option(
    "--db",
    "db_path",
    type=click.Path(),
    default=None,
    help="Path to state database",
)
@click.option("-v", "--verbose", is_flag=True, help="Verbose output")
@click.option("-q", "--quiet", is_flag=True, help="Quiet output (errors only)")
@click.pass_context
def cli(
    ctx: click.Context,
    db_path: str | None,
    verbose: bool,
    quiet: bool,
) -> None:
    """Trove: Photo deduplication and organization tool."""
    ctx.ensure_object(dict)
    ctx.obj["db_path"] = Path(db_path) if db_path else None
    ctx.obj["verbose"] = verbose
    ctx.obj["quiet"] = quiet


@cli.command("create")
@click.argument("name", required=False, default=None)
@click.argument("location", required=False, default=None, type=click.Path())
@click.option("--structure", default=None, help='Directory structure (strftime format, e.g. "%%Y/%%m/%%d")')
@click.option("--no-camera-model", is_flag=True, help="Don't include camera model in directory structure")
@click.pass_context
def library_create(
    ctx: click.Context,
    name: str | None,
    location: str | None,
    structure: str | None,
    no_camera_model: bool,
) -> None:
    """Create a new library."""
    defaults = OrganizationConfig()
    org = OrganizationConfig(
        structure=structure if structure is not None else defaults.structure,
        include_camera_model=False if no_camera_model else defaults.include_camera_model,
    )
    config = LibraryConfig(organization=org)

    # Interactive mode if no args
    if name is None:
        name = click.prompt("Library name")
    if location is None:
        location = prompt_for_path("Location (directory path)")

    # At this point, name and location are guaranteed to be strings
    if name is None or location is None:
        click.echo("Error: Both name and location are required.", err=True)
        ctx.exit(1)
        return

    resolved = Path(location).resolve()

    with StateDB(ctx.obj["db_path"]) as db:
        try:
            lib = db.create_library(name, str(resolved), config=config)
        except sqlite3.IntegrityError:
            click.echo(f"Error: Library '{name}' already exists.", err=True)
            ctx.exit(1)
            return

        # Create directory if it doesn't exist
        if not resolved.exists():
            resolved.mkdir(parents=True)
            click.echo(f"Created library '{lib.name}' at {lib.location}")
            return

        click.echo(f"Created library '{lib.name}' at {lib.location}")

        # If directory has files, offer to add them
        has_files = any(resolved.iterdir())
        if not has_files:
            return

        if click.confirm("Found files here. Add them now?"):
            _add_init_mode(ctx, db, lib, config, source_path=str(resolved), yes=False)


@cli.command("list")
@click.pass_context
def list_cmd(ctx: click.Context) -> None:
    """List all libraries."""
    with StateDB(ctx.obj["db_path"]) as db:
        libs = db.list_libraries()
        if not libs:
            click.echo("No libraries.")
            return
        for lib in libs:
            click.echo(f"  {lib.name}  {lib.location}")


@cli.command("relocate")
@click.argument("name")
@click.argument("new_location", type=click.Path())
@click.pass_context
def library_relocate(ctx: click.Context, name: str, new_location: str) -> None:
    """Update a library's location after moving files externally."""
    resolved = Path(new_location).resolve()
    with StateDB(ctx.obj["db_path"]) as db:
        lib = db.get_library(name)
        if lib is None:
            click.echo(f"Error: Library '{name}' not found.", err=True)
            ctx.exit(1)
            return
        if not resolved.exists():
            click.echo(f"Warning: {resolved} does not exist yet.", err=True)
        db.update_library_location(lib.id, str(resolved))
        click.echo(f"Updated '{lib.name}' location: {lib.location} → {resolved}")


@cli.command("delete")
@click.argument("name")
@click.pass_context
def library_delete(ctx: click.Context, name: str) -> None:
    """Delete a library and all its entries from the database.

    Files on disk are not moved or deleted.
    """
    with StateDB(ctx.obj["db_path"]) as db:
        lib = db.get_library(name)
        if lib is None:
            click.echo(f"Error: Library '{name}' not found.", err=True)
            ctx.exit(1)
            return

        entry_count = len(db.list_entries(lib.id))

        click.echo(f"Library: {lib.name}")
        click.echo(f"Location: {lib.location}")
        click.echo(f"Entries: {entry_count}")
        click.echo()
        click.echo(f"This will delete the library record and all {entry_count} entries from the database.")
        click.echo("WARNING: files on disk will NOT be moved back or deleted.")
        click.echo()

        confirm = click.prompt(f'Type "{name}" to confirm deletion')
        if confirm != name:
            click.echo("Aborted.")
            return

        db.delete_library(lib.id)
        click.echo(f"Deleted library '{name}' and {entry_count} entries.")


# --- Add (replaces run/scan/import/complete/init) ---


def _generate_and_open_report(
    db: StateDB,
    lib,
    plan,
    source_path: str,
    quarantined_ids: list[int] | None = None,
) -> None:
    """Build and open a full analysis report in the browser."""
    from collections import defaultdict as _defaultdict

    from trove.report import DuplicateGroup, FileInfo, generate_analysis_report

    # Files to import
    import_files = [
        FileInfo(
            path=f.source_path,
            size=f.file_size,
            capture_date=f.capture_date,
            camera_model=f.camera_model,
            target_path=f.target_path,
        )
        for f in plan.to_import
    ]

    # Path conflicts
    conflict_files = []
    for f in plan.to_import:
        existing = db.get_entry_by_path(lib.id, f.target_path)
        if existing is not None:
            conflict_files.append(
                FileInfo(
                    path=f.source_path,
                    size=f.file_size,
                    capture_date=f.capture_date,
                    camera_model=f.camera_model,
                    target_path=f.target_path,
                    label="conflict: will be renamed",
                )
            )

    # Batch duplicate groups — built from plan data (scoped to this run)
    all_plan_files = list(plan.to_import) + list(plan.duplicates_in_batch)
    by_hash = _defaultdict(list)
    for f in all_plan_files:
        if f.md5_hash:
            by_hash[f.md5_hash].append(f)

    batch_groups = []
    seen_hashes: set[str] = set()
    for dup in plan.duplicates_in_batch:
        if not dup.md5_hash:
            continue
        if dup.md5_hash in seen_hashes:
            continue
        seen_hashes.add(dup.md5_hash)
        group_files = by_hash.get(dup.md5_hash, [])
        batch_groups.append(
            DuplicateGroup(
                md5_hash=dup.md5_hash,
                files=[
                    {
                        "path": f.source_path,
                        "size": f.file_size,
                        "capture_date": f.capture_date,
                        "camera_model": f.camera_model,
                        "is_library": False,
                        "label": "kept" if f.id != dup.id else "skipped",
                    }
                    for f in group_files
                ],
            )
        )

    # Library duplicate groups
    library_groups = []
    for dup in plan.duplicates_in_library:
        if not dup.md5_hash:
            continue
        entries = db.get_entries_by_hash(lib.id, dup.md5_hash)
        files_list = [
            {
                "path": dup.source_path,
                "size": dup.file_size,
                "capture_date": dup.capture_date,
                "camera_model": dup.camera_model,
                "is_library": False,
                "label": "skipped",
            }
        ]
        for entry in entries:
            files_list.append(
                {
                    "path": str(Path(lib.location) / entry.relative_path),
                    "size": entry.file_size,
                    "capture_date": entry.capture_date,
                    "camera_model": entry.camera_model,
                    "is_library": True,
                }
            )
        library_groups.append(
            DuplicateGroup(
                md5_hash=dup.md5_hash,
                files=files_list,
            )
        )

    # Quarantined — use scoped IDs if available
    if quarantined_ids:
        q_records = db.query_files_by_ids(quarantined_ids)
    else:
        q_records = db.query_files_by_status("quarantined")
    quarantined_files = [
        FileInfo(
            path=f.source_path,
            size=f.file_size,
            capture_date=f.capture_date,
            camera_model=f.camera_model,
        )
        for f in q_records
    ]

    report_path = Path(source_path) / "trove_analysis_report.html"
    try:
        generate_analysis_report(
            to_import=import_files,
            path_conflicts=conflict_files,
            library_duplicates=library_groups,
            batch_duplicates=batch_groups,
            quarantined=quarantined_files,
            output_path=report_path,
            library_name=lib.name,
            source_path=source_path,
        )
    except OSError:
        import tempfile

        report_path = Path(tempfile.gettempdir()) / "trove_analysis_report.html"
        generate_analysis_report(
            to_import=import_files,
            path_conflicts=conflict_files,
            library_duplicates=library_groups,
            batch_duplicates=batch_groups,
            quarantined=quarantined_files,
            output_path=report_path,
            library_name=lib.name,
            source_path=source_path,
        )

    click.echo(f"Report generated: {report_path}")
    click.launch(str(report_path))


@cli.command()
@click.argument("name")
@click.argument("source_path", required=False, default=None, type=click.Path(exists=True))
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompts")
@click.pass_context
def add(ctx: click.Context, name: str, source_path: str | None, yes: bool) -> None:
    """Add files to a library from a source directory, or resume processing."""
    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return

        click.echo(f"Library: {lib.name}  ({lib.location})")

        # Check library location is accessible (e.g. NAS mounted).
        # Run in the worker so a hung mount doesn't wedge the parent — if it
        # times out, the mount is not responding to filesystem calls even if
        # it appears mounted. Ctrl-C works throughout.
        def _location_accessible() -> bool | None:
            """Return True=ok, False=not found, None=timed out/hung."""
            click.echo("  Checking mount...", nl=False)
            try:
                result: bool = run_with_timeout(path_exists, lib.location, timeout=30)
                click.echo(" ok" if result else " not found")
                return result
            except TimeoutError:
                click.echo(" timed out — mount is not responding")
                return None

        while True:
            status = _location_accessible()
            if status is True:
                break
            if status is False:
                click.echo(
                    f"\nLibrary location not found: {lib.location}\nIs the drive or network share mounted?",
                    err=True,
                )
            else:
                click.echo(
                    f"\nLibrary location not responding: {lib.location}\n"
                    "The mount is visible but not answering filesystem calls.\n"
                    "Try remounting the share.",
                    err=True,
                )
            choice = click.prompt("[r]etry or [a]bort", type=click.Choice(["r", "a"], case_sensitive=False))
            if choice == "a":
                ctx.exit(1)
                return

        config = lib.config

        # Determine mode: move (source inside library) vs copy (external source)
        if source_path is not None:
            resolved_source = Path(source_path).resolve()
            resolved_library = Path(lib.location).resolve()
            is_move_mode = resolved_source == resolved_library or str(resolved_source).startswith(
                str(resolved_library) + "/"
            )
        else:
            is_move_mode = None  # resume mode — no discovery

        if is_move_mode is True or is_move_mode is None:
            # Move mode or resume mode — use init pipeline
            _add_init_mode(ctx, db, lib, config, source_path, yes)
        else:
            # Copy mode — use import pipeline (existing logic)
            assert source_path is not None  # guaranteed by is_move_mode=False branch
            _add_copy_mode(ctx, db, lib, config, source_path, yes)


def _add_init_mode(
    ctx: click.Context,
    db: StateDB,
    lib,
    config,
    source_path: str | None,
    yes: bool,
) -> None:
    """Move mode or resume mode — organize files already inside the library."""
    if source_path:
        # Move mode: discover + full pipeline
        click.echo(f"\nScanning {source_path}...")
        progress = create_progress()
        with progress:
            plan = plan_initialize(lib, db, config, progress=progress)
    else:
        # Resume mode: skip discovery, process what's queued in DB
        click.echo(f"\nProcessing queued files for {lib.name}...")
        plan = _resume_init_from_db(db, lib, config)

    if plan.is_empty:
        click.echo("Nothing to process." if source_path is None else "No files to organize.")
        return

    click.echo(f"\n  Files to index (no move needed):  {len(plan.already_correct)}")
    click.echo(f"  Files to relocate:                {len(plan.needs_move)}")
    click.echo(f"  Duplicates (both kept):           {len(plan.duplicates)}")
    click.echo(f"  Quarantined (no date):            {len(plan.quarantined)}")

    if not yes:
        if not click.confirm("\nProceed?"):
            click.echo("Aborted.")
            return

    audit = AuditLogger(Path("trove_audit.log"))
    exec_progress = create_progress()

    def _on_error(path: str, reason: str, error_count: int) -> bool:
        filename = Path(path).name
        exec_progress.console.print(f"  Skipped: {filename} ({reason})")
        if error_count >= 10 and error_count % 10 == 0:
            exec_progress.stop()
            should_continue = click.confirm(f"  {error_count} errors so far. Continue?", default=False)
            exec_progress.start()
            return should_continue
        return True

    with exec_progress:
        result = execute_initialize(lib, db, plan, audit=audit, progress=exec_progress, on_error=_on_error)

    click.echo(f"\n  Indexed:      {result.indexed}")
    click.echo(f"  Moved:        {result.moved}")
    click.echo(f"  Duplicates:   {result.duplicates}")
    click.echo(f"  Quarantined:  {result.quarantined}")
    click.echo("Done.")


def _resume_init_from_db(db: StateDB, lib, config):
    """Resume processing queued files from DB state — no discovery."""
    from trove.pipeline import classify_for_init  # noqa: E402

    lib_prefix = str(Path(lib.location).resolve()) + "/"

    # Collect files in intermediate states scoped to this library
    stale_discovered = [f for f in db.query_files_by_status("discovered") if f.source_path.startswith(lib_prefix)]
    stale_hashed = [f for f in db.query_files_by_status("hashed") if f.source_path.startswith(lib_prefix)]
    stale_quarantined = [f for f in db.query_files_by_status("quarantined") if f.source_path.startswith(lib_prefix)]

    if not stale_discovered and not stale_hashed and not stale_quarantined:
        return classify_for_init([], [], db, lib, config)

    hashed_ids: list[int] = []
    quarantined_ids: list[int] = [f.id for f in stale_quarantined]

    progress = create_progress()
    with progress:
        # discovered → hash → extract → compute paths
        if stale_discovered:
            disc_ids = hash_files([f.id for f in stale_discovered], db, progress=progress)
        else:
            disc_ids = []

        # Newly hashed + stale hashed needing metadata
        need_extract = disc_ids + [f.id for f in stale_hashed if f.capture_date is None]
        if need_extract:
            r_hashed, r_quarantined = extract_metadata(need_extract, db, config, progress=progress)
            compute_paths(r_hashed, db, config)
            hashed_ids.extend(r_hashed)
            quarantined_ids.extend(r_quarantined)

        # Stale hashed with metadata but no target path
        need_paths = [f.id for f in stale_hashed if f.capture_date is not None and f.target_path is None]
        if need_paths:
            compute_paths(need_paths, db, config)
            hashed_ids.extend(need_paths)

        # Stale hashed already fully ready
        ready = [f.id for f in stale_hashed if f.capture_date is not None and f.target_path is not None]
        hashed_ids.extend(ready)

    return classify_for_init(hashed_ids, quarantined_ids, db, lib, config)


def _add_copy_mode(
    ctx: click.Context,
    db: StateDB,
    lib,
    config,
    source_path: str,
    yes: bool,
) -> None:
    """Copy mode — import files from an external source into the library."""
    # Step 1: Discover, hash, extract metadata, compute paths
    click.echo(f"\nScanning {source_path}...")
    scan_progress = create_progress()
    with scan_progress:
        ids, skip_count = discover_and_persist(Path(source_path), db, config, progress=scan_progress)
        ids = hash_files(ids, db, progress=scan_progress)
        hashed_ids, quarantined_ids = extract_metadata(ids, db, config, progress=scan_progress)
        compute_paths(hashed_ids, db, config)

    # Show informative summary
    click.echo(f"  Found {len(ids)} new media files" + (f" ({skip_count} already scanned)" if skip_count else ""))
    if quarantined_ids:
        click.echo(f"  {len(quarantined_ids)} files quarantined (no date)")

    # Resume: pick up stale intermediate files from a previous crashed run,
    # scoped to this source directory to avoid cross-source leaks.
    # Use the same path form as discover_and_persist (no resolve — raw
    # os.scandir paths must match the prefix).
    source_prefix = str(Path(source_path)) + "/"
    current_ids = set(hashed_ids) | set(quarantined_ids)

    stale_discovered = [f for f in db.query_files_by_status("discovered") if f.source_path.startswith(source_prefix)]
    stale_hashed = [
        f
        for f in db.query_files_by_status("hashed")
        if f.source_path.startswith(source_prefix) and f.id not in current_ids
    ]

    if stale_discovered or stale_hashed:
        resume_count = len(stale_discovered) + len(stale_hashed)
        click.echo(f"  Resuming {resume_count} files from previous run...")

        resume_progress = create_progress()
        with resume_progress:
            # Hash any files stuck at "discovered"
            if stale_discovered:
                disc_ids = hash_files([f.id for f in stale_discovered], db, progress=resume_progress)
            else:
                disc_ids = []

            # Extract metadata for newly hashed + stale hashed without metadata
            need_extract = disc_ids + [f.id for f in stale_hashed if f.capture_date is None]
            if need_extract:
                r_hashed, r_quarantined = extract_metadata(need_extract, db, config, progress=resume_progress)
                compute_paths(r_hashed, db, config)
                hashed_ids.extend(r_hashed)
                quarantined_ids.extend(r_quarantined)

            # Files that have metadata but still need target paths
            need_paths = [f.id for f in stale_hashed if f.capture_date is not None and f.target_path is None]
            if need_paths:
                compute_paths(need_paths, db, config)
                hashed_ids.extend(need_paths)

            # Files fully ready (have target_path already)
            ready = [f.id for f in stale_hashed if f.capture_date is not None and f.target_path is not None]
            hashed_ids.extend(ready)

    # Step 2: Classify (may hash library files for dedup — show progress)
    plan_progress = create_progress()
    with plan_progress:
        plan = classify_for_import(hashed_ids, db, lib, config, progress=plan_progress)

    # Always show full analysis
    click.echo("\nAnalysis:")
    click.echo(f"  Ready to import:         {len(plan.to_import)} files")
    if plan.duplicates_in_library:
        click.echo(f"  Already in library:      {len(plan.duplicates_in_library)} files (exact match by content)")
    if plan.duplicates_in_batch:
        click.echo(
            f"  Duplicates in source:    {len(plan.duplicates_in_batch)} files (same content as other files in this batch)"
        )
    if plan.skipped:
        click.echo(f"  No date (quarantine):    {plan.skipped} files")
    if plan.path_conflicts:
        click.echo(f"  Path conflicts:          {plan.path_conflicts} (auto-resolved)")

    if plan.is_empty:
        click.echo(f"\nAll {plan.total_files} files accounted for. Nothing new to import.")
        if not yes and plan.total_files > 0:
            if click.confirm("Generate analysis report?", default=False):
                _generate_and_open_report(db, lib, plan, source_path, quarantined_ids=quarantined_ids)
        # Clean up file records so they don't accumulate
        db.delete_files_by_status(["hashed", "discovered", "duplicate", "quarantined"])
        return

    if yes:
        # Non-interactive: just import
        pass
    else:
        # Interactive menu
        while True:
            click.echo("\nWhat would you like to do?")
            click.echo(f"  [i] Import {len(plan.to_import)} files")
            if plan.skipped:
                click.echo(f"  [q] Review {plan.skipped} quarantined files")
            if plan.duplicates_in_batch:
                click.echo(
                    f"  [d] Review {len(plan.duplicates_in_batch)} duplicates within source (same content, different filenames)"
                )
            if plan.duplicates_in_library:
                click.echo(
                    f"  [l] Review {len(plan.duplicates_in_library)} files already in library (exact match exists)"
                )
            click.echo("  [r] Full analysis report (opens in browser)")
            click.echo("  [a] Abort")

            choice = click.prompt("Choice", type=str).strip().lower()

            if choice == "i":
                break
            elif choice == "q" and plan.skipped:
                # Show quarantined files (scoped to this run)
                quarantined = db.query_files_by_ids(quarantined_ids)
                click.echo("\nQuarantined files (no date found):")
                for f in quarantined:
                    size_kb = f.file_size / 1024
                    click.echo(f"  {f.source_path}  ({size_kb:.1f} KB)")
                click.echo()
                continue
            elif choice == "d" and plan.duplicates_in_batch:
                click.echo(f"\nDuplicates within source ({len(plan.duplicates_in_batch)} files):")
                click.echo("These files have identical content to another file in the source.\n")
                # Group by hash from plan data (scoped to this run)
                from collections import defaultdict as _defaultdict

                all_plan_files = list(plan.to_import) + list(plan.duplicates_in_batch)
                by_hash = _defaultdict(list)
                for f in all_plan_files:
                    if f.md5_hash:
                        by_hash[f.md5_hash].append(f)

                shown = 0
                for dup in plan.duplicates_in_batch[:20]:  # limit console output
                    if not dup.md5_hash:
                        continue
                    group = by_hash.get(dup.md5_hash, [])
                    if len(group) >= 2:
                        click.echo(f"  Hash: {dup.md5_hash[:12]}...")
                        for f in group:
                            size_kb = f.file_size / 1024
                            label = " (kept)" if f.id != dup.id else " (skipped)"
                            click.echo(f"    {f.source_path}  ({size_kb:.1f} KB){label}")
                        click.echo()
                        shown += 1
                if len(plan.duplicates_in_batch) > 20:
                    click.echo(f"  ... and {len(plan.duplicates_in_batch) - 20} more. Use [r] for full report.")
                click.echo()
                continue
            elif choice == "l" and plan.duplicates_in_library:
                click.echo(f"\nFiles already in library ({len(plan.duplicates_in_library)} files):")
                click.echo("These source files have identical content to files in your library.\n")
                for dup in plan.duplicates_in_library[:20]:
                    if not dup.md5_hash:
                        continue
                    entries = db.get_entries_by_hash(lib.id, dup.md5_hash)
                    size_kb = dup.file_size / 1024
                    click.echo(f"  Source: {dup.source_path}  ({size_kb:.1f} KB)")
                    for entry in entries:
                        click.echo(f"    \u21b3 matches: {entry.relative_path} in library")
                    click.echo()
                if len(plan.duplicates_in_library) > 20:
                    click.echo(f"  ... and {len(plan.duplicates_in_library) - 20} more. Use [r] for full report.")
                click.echo()
                continue
            elif choice == "r":
                _generate_and_open_report(db, lib, plan, source_path, quarantined_ids=quarantined_ids)
                click.echo()
                continue
            elif choice == "a":
                click.echo("Aborted.")
                # Clean up file records so they don't accumulate
                db.delete_files_by_status(["hashed", "discovered", "duplicate", "quarantined"])
                return
            else:
                click.echo("Invalid choice.")
                continue

    # Step 3: Import
    click.echo("\nImporting...")
    audit = AuditLogger(Path("trove_audit.log"))
    import_progress = create_progress()
    with import_progress:
        summary = execute_import(db, lib, config, plan, audit=audit, progress=import_progress)

    click.echo(f"Imported {summary['imported']} files to {lib.name}.")
    if summary["errors"]:
        click.echo(f"  {summary['errors']} errors occurred.")
    if plan.duplicates_in_batch:
        click.echo(f"  {len(plan.duplicates_in_batch)} batch duplicates skipped.")
    if plan.duplicates_in_library:
        click.echo(f"  {len(plan.duplicates_in_library)} already in library.")

    # Step 4: Auto-complete (silent DB cleanup)
    cplan = plan_complete(db, lib)
    if cplan.can_complete:
        execute_complete(db, lib, cplan)
    click.echo("Done.")


# --- Verify ---


@cli.command()
@click.argument("name")
@click.option("--thorough", is_flag=True, help="Hash every file for full verification")
@click.pass_context
def verify(ctx: click.Context, name: str, thorough: bool) -> None:
    """Verify library integrity."""
    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return
        try:
            progress = create_progress()
            with progress:
                result = verify_library(db, lib, thorough=thorough, progress=progress)
        except ValueError as e:
            click.echo(f"Error: {e}", err=True)
            ctx.exit(2)
            return

        click.echo(
            f"Entries: {result.entries_checked}, Files on disk: {result.files_on_disk}, "
            f"Verified OK: {result.verified_ok}"
        )
        if result.missing_from_disk:
            click.echo(f"Missing from disk: {len(result.missing_from_disk)}")
        if result.orphan_files:
            click.echo(f"Orphan files: {len(result.orphan_files)}")
        if result.size_mismatches:
            click.echo(f"Size mismatches: {len(result.size_mismatches)}")
        if result.hash_mismatches:
            click.echo(f"Hash mismatches: {len(result.hash_mismatches)}")

        if result.is_healthy:
            click.echo("Status: HEALTHY")
        else:
            click.echo("Status: ISSUES FOUND", err=True)
            ctx.exit(1)


# --- Duplicates ---


@cli.command()
@click.argument("name")
@click.option(
    "--report",
    "generate_report",
    is_flag=True,
    help="Generate HTML report and open in browser",
)
@click.pass_context
def duplicates(ctx: click.Context, name: str, generate_report: bool) -> None:
    """List duplicate files in a library."""
    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return

        groups = db.get_duplicate_groups(lib.id)

        if not groups:
            click.echo("No duplicates found.")
            return

        if generate_report:
            # Generate HTML report
            from trove.report import DuplicateGroup, generate_duplicate_report

            # Convert EntryRecord groups to DuplicateGroup objects
            library_groups = []
            for group in groups:
                if not group or not group[0].md5_hash:
                    continue
                files_list = []
                for entry in group:
                    # Get full path from library location + relative path
                    full_path = str(Path(lib.location) / entry.relative_path)
                    files_list.append(
                        {
                            "path": full_path,
                            "size": entry.file_size,
                            "capture_date": entry.capture_date,
                            "camera_model": entry.camera_model,
                            "is_library": True,  # All files are already in the library
                        }
                    )
                library_groups.append(DuplicateGroup(md5_hash=group[0].md5_hash, files=files_list))

            report_path = Path(lib.location) / "trove_duplicates_report.html"
            try:
                generate_duplicate_report([], library_groups, report_path, lib.name)
            except OSError:
                import tempfile

                report_path = Path(tempfile.gettempdir()) / "trove_duplicates_report.html"
                generate_duplicate_report([], library_groups, report_path, lib.name)

            click.echo(f"Report generated: {report_path}")
            click.launch(str(report_path))
            return

        click.echo(f"{len(groups)} duplicate group(s) found:\n")
        for i, group in enumerate(groups, 1):
            if not group or not group[0].md5_hash:
                continue
            click.echo(f"Group {i}: {len(group)} files, hash {group[0].md5_hash[:12]}...")
            for entry in group:
                size_kb = entry.file_size / 1024
                date_str = entry.capture_date or "unknown date"
                model_str = entry.camera_model or "unknown model"
                click.echo(f"  {entry.relative_path}  ({size_kb:.1f} KB, {date_str}, {model_str})")
            click.echo()


# --- Status ---


@cli.command()
@click.argument("name")
@click.option("--missing", is_flag=True, help="List missing files")
@click.option("--clear-missing", is_flag=True, help="Remove missing file records")
@click.pass_context
def status(ctx: click.Context, name: str, missing: bool, clear_missing: bool) -> None:
    """Show library status."""
    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return

        lib_prefix = str(Path(lib.location).resolve()) + "/"
        missing_files = [f for f in db.query_files_by_status("missing") if f.source_path.startswith(lib_prefix)]

        if clear_missing:
            if not missing_files:
                click.echo("No missing files to clear.")
                return
            click.echo(f"{len(missing_files)} missing file record(s).")
            if click.confirm("Delete these records?"):
                for f in missing_files:
                    db.delete_file(f.id)
                click.echo(f"Cleared {len(missing_files)} missing file records.")
            return

        if missing:
            if not missing_files:
                click.echo("No missing files.")
                return
            click.echo(f"{len(missing_files)} missing file(s):\n")
            for f in missing_files:
                reason = f.error_message or "unknown"
                click.echo(f"  {f.source_path}  ({reason})")
            return

        entries = db.list_entries(lib.id)
        click.echo(f"Library: {lib.name}")
        click.echo(f"Location: {lib.location}")
        click.echo(f"Entries: {len(entries)}")
        click.echo(f"Created: {lib.created_at}")

        # Show duplicate count
        dups = db.get_duplicate_groups(lib.id)
        if dups:
            click.echo(f"Duplicate groups: {len(dups)}")

        if missing_files:
            click.echo(f"Missing files: {len(missing_files)}")


# --- Hash backfill ---


@cli.command("fix-created-dates")
@click.argument("name")
@click.option(
    "--dry-run/--apply",
    "dry_run",
    default=True,
    help="Preview changes or apply Finder Date Created updates.",
)
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompt when using --apply")
@click.option(
    "--force",
    is_flag=True,
    help="Re-stamp entries that have already been stamped previously.",
)
@click.option(
    "--workers",
    type=click.IntRange(min=1, max=64),
    default=8,
    show_default=True,
    help="Concurrent SetFile invocations. Useful when the library is on a NAS.",
)
@click.pass_context
def fix_created_dates(
    ctx: click.Context, name: str, dry_run: bool, yes: bool, force: bool, workers: int,
) -> None:
    """Reset Finder Date Created from stored capture dates on macOS."""
    if sys.platform != "darwin":
        click.echo("Error: fix-created-dates is only supported on macOS.", err=True)
        ctx.exit(1)
        return

    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return

        candidates = db.list_entries_needing_creation_date_stamp(lib.id, force=force)

        click.echo(f"Library: {lib.name}")
        click.echo(f"Entries needing creation-date stamp: {len(candidates)}")
        if force:
            click.echo("(--force: previously stamped entries are included)")

        if dry_run:
            click.echo("Dry run only. Re-run with --apply to update Finder Date Created.")
            return

        if not candidates:
            click.echo("Nothing to update.")
            return

        if not yes and not click.confirm(f"Apply Finder Date Created to {len(candidates)} files?"):
            click.echo("Aborted.")
            return

        updated = 0
        failed = 0
        progress = create_progress()
        with progress:
            task_id = progress.add_task("Stamping creation dates", total=len(candidates))
            with ThreadPoolExecutor(max_workers=workers) as executor:
                futures = {
                    executor.submit(
                        stamp_creation_date,
                        _entry_absolute_path(lib.location, entry),
                        entry.capture_date,
                    ): entry
                    for entry in candidates
                }
                for future in as_completed(futures):
                    entry = futures[future]
                    try:
                        success = future.result()
                    except Exception as exc:  # noqa: BLE001
                        click.echo(f"Error stamping {entry.relative_path}: {exc}", err=True)
                        success = False
                    if success:
                        db.mark_entry_creation_date_stamped(entry.id)
                        updated += 1
                    else:
                        failed += 1
                    progress.update(task_id, advance=1)

        click.echo(f"Updated Finder Date Created for {updated} files.")
        if failed:
            click.echo(f"Failed to update {failed} files.")


@cli.command("hash")
@click.argument("name")
@click.pass_context
def hash_cmd(ctx: click.Context, name: str) -> None:
    """Backfill hashes for library entries that don't have them."""
    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return

        need_hash = db.list_entries_missing_hash(lib.id)

        if not need_hash:
            click.echo("All entries already have hashes.")
            return

        click.echo(f"{len(need_hash)} entries without hashes.")

        paths = [Path(lib.location) / e.relative_path for e in need_hash]
        progress = create_progress()
        with progress:
            results = hash_files_parallel(paths, max_workers=4, progress=progress)

        backfilled = 0
        missing_files: list[str] = []
        unreadable_files: list[str] = []
        for entry in need_hash:
            full_path_obj = _entry_absolute_path(lib.location, entry)
            full_path = str(full_path_obj)
            if full_path in results:
                db.update_entry_hash(entry.id, results[full_path])
                backfilled += 1
            elif full_path_obj.exists():
                unreadable_files.append(full_path)
            else:
                missing_files.append(full_path)

        remaining_unhashed = len(need_hash) - backfilled
        click.echo(f"Done. {backfilled} entries updated with hashes.")
        click.echo(f"Remaining without hashes: {remaining_unhashed}")
        click.echo(f"Missing files: {len(missing_files)}")
        click.echo(f"Unreadable files: {len(unreadable_files)}")

        for path in missing_files:
            click.echo(f"  missing: {path}")
        for path in unreadable_files:
            click.echo(f"  unreadable: {path}")


# --- Duplicate cleanup ---


@cli.command("dedupe")
@click.argument("name")
@click.option(
    "--dry-run/--apply",
    "dry_run",
    default=True,
    help="Preview duplicate cleanup or apply DB changes.",
)
@click.option(
    "--delete-list",
    "delete_list_path",
    type=click.Path(dir_okay=False, path_type=Path),
    required=True,
    help="Write absolute non-keeper paths to this newline-delimited file.",
)
@click.pass_context
def dedupe_cmd(ctx: click.Context, name: str, dry_run: bool, delete_list_path: Path) -> None:
    """Analyze and clean exact duplicate entries within one library."""
    with StateDB(ctx.obj["db_path"]) as db:
        lib = resolve_library(db, name)
        if lib is None:
            ctx.exit(1)
            return

        missing_hash = db.list_entries_missing_hash(lib.id)
        if missing_hash:
            click.echo(
                "Error: duplicate cleanup requires hash backfill first. "
                f"{len(missing_hash)} entries still lack md5_hash.",
                err=True,
            )
            ctx.exit(1)
            return

        analyses = _analyze_duplicate_cleanup(db.get_duplicate_groups(lib.id))
        _write_delete_list(delete_list_path, lib.location, analyses)

        if not analyses:
            click.echo("No exact duplicates found.")
            click.echo(f"Delete list written: {delete_list_path}")
            return

        click.echo(
            f"{len(analyses)} exact duplicate group(s) found in '{lib.name}' "
            f"({'dry run' if dry_run else 'apply'})."
        )
        for index, group in enumerate(analyses, start=1):
            click.echo(f"Group {index}: hash {group.md5_hash[:12]}..., keep {group.keeper.relative_path}")
            for entry in group.non_keepers:
                click.echo(f"  delete {entry.relative_path}")

        delete_count = sum(len(group.non_keepers) for group in analyses)
        if not dry_run:
            db.delete_entries([entry.id for group in analyses for entry in group.non_keepers])

        click.echo(f"Delete list written: {delete_list_path}")
        if dry_run:
            click.echo(f"Dry run complete. {delete_count} entries would be removed from the database.")
            return

        click.echo(f"Apply complete. Removed {delete_count} duplicate entries from the database.")


# --- Completions ---


@cli.command()
@click.option("--install", is_flag=True, help="Install completions to shell config")
def completions(install: bool) -> None:
    """Generate or install shell completions."""
    shell = os.environ.get("SHELL", "")
    if "zsh" in shell:
        shell_name = "zsh"
        env_var = "_TROVE_COMPLETE=zsh_source"
        rc_file = Path.home() / ".zshrc"
    elif "bash" in shell:
        shell_name = "bash"
        env_var = "_TROVE_COMPLETE=bash_source"
        rc_file = Path.home() / ".bashrc"
    elif "fish" in shell:
        shell_name = "fish"
        env_var = "_TROVE_COMPLETE=fish_source"
        rc_file = Path.home() / ".config" / "fish" / "completions" / "trove.fish"
    else:
        click.echo(f"Unsupported shell: {shell}", err=True)
        click.echo("Set SHELL env var or generate manually:")
        click.echo("  _TROVE_COMPLETE=zsh_source trove")
        return

    # Generate the completion script
    result = subprocess.run(
        ["trove"],
        env={**os.environ, env_var.split("=")[0]: env_var.split("=")[1]},
        capture_output=True,
        text=True,
    )
    script = result.stdout.strip()

    if not script:
        click.echo("Failed to generate completion script.", err=True)
        return

    if not install:
        click.echo(script)
        return

    # Install to rc file
    marker = "# trove shell completions"
    if rc_file.exists():
        existing = rc_file.read_text()
        if marker in existing:
            click.echo(f"Completions already installed in {rc_file}")
            return

    if shell_name == "fish":
        rc_file.parent.mkdir(parents=True, exist_ok=True)
        rc_file.write_text(script + "\n")
    else:
        with open(rc_file, "a") as f:
            f.write(f"\n{marker}\n")
            f.write(f'eval "$({env_var} trove)"\n')

    click.echo(f"Completions installed to {rc_file}")
    click.echo(f"Restart your shell or run: source {rc_file}")
