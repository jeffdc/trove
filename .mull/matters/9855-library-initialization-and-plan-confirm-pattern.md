---
status: done
tags: [design]
created: 2026-03-28
updated: 2026-03-29
epic: trove
relates: [1e41]
---

# Library initialization and plan-confirm pattern

## Design: Library Initialization & Plan-Confirm Pattern

### Problem

The current pipeline assumes files always come from an external source (USB, SD card) and get copied into a library. But the most common first use is: "I already have 30,000 photos on my NAS, make that my library." There's no way to index existing files in-place.

Additionally, all file-modifying operations (import, complete, initialize) execute immediately without showing the user what will happen first.

### Design

#### 1. Library Initialize

When `trove library create` points at a directory that already contains files, offer to initialize:

```
trove library create "Family Photos" /Volumes/photos/family
  → Found 30,247 media files in /Volumes/photos/family
  → Scan and organize into library? [y/n]
```

If confirmed, the initialize operation:

1. **Scan** (read-only): discover all media files, hash them, extract metadata, compute target paths based on EXIF + config layout. EXIF is the source of truth — files are relocated to match, regardless of current directory structure.

2. **Classify** each file:
   - **Already correct**: file is at its computed target path → just create entry, no move
   - **Needs move**: file is at a different path than its target → plan a move
   - **Duplicate**: another file in the batch has the same hash → keep both (suffix the second), flag for later review

3. **Show plan**:
   ```
   === Initialization Plan ===
   Files to index (no move needed):  29,750
   Files to relocate:                   247
   Duplicates (both kept, suffixed):     50
   Quarantined (no date):                 3
   
   Proceed? [y/n]
   ```

4. **Execute**: move files, create entries. Each move is atomic: move file → verify at new location → create entry in DB transaction. Resume-safe: files with entries are done, files without are pending.

5. **Report**:
   ```
   === Library Initialized ===
   Indexed:    29,750
   Moved:         247
   Duplicates:     50 (run 'trove duplicates' to review)
   Quarantined:     3
   ```

#### 2. Plan-Then-Confirm Pattern

All file-modifying operations follow the same pattern:

1. **Scan/analyze** (read-only, always safe)
2. **Show plan** with counts and summary
3. **Ask for confirmation** (or `--yes` to skip for scripting)
4. **Execute** with progress indicators
5. **Report** results

This applies to:
- `library create` (when dir has existing files) → initialize plan
- `trove import` → import plan (N files to copy, N duplicates to skip)
- `trove complete --delete-sources` → deletion plan (N source files to delete)
- `trove run` → full pipeline with confirmation before each destructive step

Non-destructive operations (scan, verify, status) don't need confirmation.

#### 3. Progress Indicators

Use Rich for all long-running operations:
- **Hashing**: progress bar with file count and bytes processed
- **Metadata extraction**: progress bar with file count
- **File moves/copies**: progress bar with file count and current filename
- **Verification**: progress bar with file count

Progress is shown on stderr so stdout remains clean for piping/scripting.

#### 4. Duplicate Tracking

During initialize, duplicates are handled automatically:
- Both copies kept (second gets `-1` suffix via existing path conflict resolution)
- Duplicates flagged in DB for later review

New command:
```
trove duplicates --library "Family Photos"
  → 50 duplicate groups found
  → Group 1: 2 files, hash abc123
      /2024/01/Canon/IMG_001.JPG (4.2 MB, 2024-01-15)
      /2024/01/Canon/IMG_001-1.JPG (4.2 MB, 2024-01-15)
```

Interactive review and the HTML report are deferred to a later iteration. For v1, this command just lists them so the user knows what to look at.

### Schema Change

```sql
-- Remove: UNIQUE(library_id, md5_hash) on entries
-- Keep:   UNIQUE(library_id, relative_path) on entries
```

The `get_entry_by_hash` method returns a list instead of a single result. Import dedup still works — it checks if a hash exists in the library and skips if so. But initialize indexes everything, including duplicates.

### What This Does NOT Change

- The scan → import → complete pipeline for external sources stays the same
- Verify stays the same
- Audit logging stays the same
- The core modules (hashing, metadata, normalize) are untouched

---

## Implementation Plan

**Goal:** Add in-place library initialization, plan-then-confirm pattern for all destructive operations, Rich progress indicators, and a duplicates command.

**Architecture:** New `initialize.py` module handles scanning a library directory and organizing files in-place (move + index). The plan-confirm pattern is implemented as a two-phase approach in each operation: phase 1 builds and returns a plan dataclass, phase 2 executes it. CLI commands call phase 1, show the plan, prompt, then call phase 2. Rich progress bars wrap all long-running loops.

**Tech Stack:** Existing stack plus Rich (already a dependency) for progress bars and formatted output.

### Task 1: Schema Change — Drop Hash Uniqueness on Entries

**Files:**
- Modify: `src/trove/db.py` (remove UNIQUE constraint on md5_hash, change get_entry_by_hash to return list)
- Modify: `tests/test_db.py` (update tests for new behavior)

**Behavior:**
Remove `UNIQUE(library_id, md5_hash)` from the entries table. Keep `UNIQUE(library_id, relative_path)`. Change `get_entry_by_hash(library_id, md5_hash)` to `get_entries_by_hash(library_id, md5_hash) -> list[EntryRecord]`. Update all callers (importer.py uses it for dedup — change to check `len(results) > 0`).

**Testing:**
- Two entries with same hash in same library: no error (was IntegrityError before)
- `get_entries_by_hash` returns list of all matches
- `get_entries_by_hash` returns empty list when no match
- Existing duplicate path constraint still enforced
- Import dedup still works (checks len > 0 instead of is not None)

**Notes:**
This unblocks initialize, which needs to index real duplicates. Must also update importer.py to use the new method signature. Run full test suite after — some tests may assert IntegrityError on duplicate hash which should be removed.

---

### Task 2: Rich Progress Bars

**Files:**
- Create: `src/trove/progress.py` (thin wrapper around Rich progress)
- Modify: `src/trove/scan.py` (add progress to hashing and metadata extraction)
- Modify: `src/trove/importer.py` (add progress to file copies)
- Modify: `src/trove/verify.py` (add progress to verification)
- Modify: `tests/test_scan.py` (pass progress=None in tests, verify no breakage)

**Behavior:**
Create a minimal progress wrapper that operations accept as an optional parameter. When provided, it updates a Rich progress bar. When None (tests, quiet mode), operations work silently as before. The wrapper handles: task creation, advance, and completion.

```python
# progress.py sketch
from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn

def create_progress() -> Progress:
    return Progress(
        TextColumn("[bold]{task.description}"),
        BarColumn(),
        TextColumn("{task.completed}/{task.total}"),
        TimeRemainingColumn(),
    )
```

Operations accept an optional progress object and call `progress.update(task_id, advance=1)` after each item. No progress object → no output, no error.

**Testing:**
- All existing tests pass with progress=None (default)
- No new tests for Rich output itself (visual, not worth testing)
- Integration: verify progress parameter is threaded through without breaking

**Notes:**
Progress goes to stderr. Keep it optional everywhere so tests stay fast and silent.

---

### Task 3: Plan-Confirm Pattern for Import

**Files:**
- Create: `src/trove/plan.py` (plan dataclasses shared across operations)
- Modify: `src/trove/importer.py` (split into plan phase + execute phase)
- Modify: `src/trove/cli.py` (import command shows plan, prompts, then executes)
- Modify: `tests/test_importer.py` (test plan generation separately from execution)
- Modify: `tests/test_cli.py` (test prompting behavior)

**Behavior:**
Split `import_to_library` into two functions:
- `plan_import(db, library, config) -> ImportPlan` — read-only, returns what would happen
- `execute_import(db, library, config, plan, audit, progress) -> ImportResult` — does it

`ImportPlan` dataclass:
```python
@dataclass(frozen=True)
class ImportPlan:
    to_import: list[FileRecord]       # files that will be copied
    duplicates_in_batch: list[FileRecord]
    duplicates_in_library: list[FileRecord]
    path_conflicts: int
    skipped: int                      # no target_path
```

CLI import command: call plan_import, show summary, prompt `Proceed? [y/n]` (skip with `--yes`), then call execute_import.

**Testing:**
- `plan_import` returns correct counts without modifying DB or disk
- `execute_import` with a plan produces same results as current `import_to_library`
- CLI prompts and respects --yes flag
- CLI shows plan summary before prompting

**Notes:**
Depends on Task 1 (schema change). The existing `import_to_library` can become a convenience wrapper that calls plan then execute.

---

### Task 4: Plan-Confirm Pattern for Complete

**Files:**
- Modify: `src/trove/complete.py` (split into plan + execute)
- Modify: `src/trove/cli.py` (complete command shows plan, prompts)
- Modify: `tests/test_complete.py` (test plan generation)
- Modify: `tests/test_cli.py` (test prompting)

**Behavior:**
Split `complete_import` into:
- `plan_complete(db, library) -> CompletePlan` — read-only assessment
- `execute_complete(db, library, plan, delete_sources, audit) -> CompleteResult` — does it

`CompletePlan` dataclass:
```python
@dataclass(frozen=True)
class CompletePlan:
    imported: list[FileRecord]
    duplicate: list[FileRecord]
    quarantined: list[FileRecord]
    unaccounted: list[FileRecord]     # discovered + hashed — blocks completion
    can_complete: bool
```

CLI complete command: call plan, show summary, if `--delete-sources` prompt with file count, then execute.

**Testing:**
- `plan_complete` returns correct assessment without modifying anything
- `execute_complete` produces same results as current `complete_import`
- CLI prompts before deletion, respects --yes

---

### Task 5: Library Initialize Module

**Files:**
- Create: `src/trove/initialize.py`
- Create: `tests/test_initialize.py`

**Behavior:**
Two-phase operation for organizing files already in a library directory:

`plan_initialize(db, library, config, progress) -> InitializePlan`:
1. Discover all media files in library.location (reuse discover_files from scan.py)
2. Hash each file
3. Extract metadata (exiftool batch)
4. Compute target path for each file
5. Classify:
   - `already_correct`: file's current relative path == target path
   - `needs_move`: current path != target path
   - `duplicate_groups`: multiple files with same hash (keep all, suffix conflicts)
   - `quarantined`: no date available
6. For files needing moves, resolve path conflicts (same logic as import)
7. Return plan without modifying anything

`execute_initialize(db, library, plan, audit, progress) -> InitializeResult`:
1. For `already_correct` files: create entry directly (no file operation)
2. For `needs_move` files:
   - Move file to target path (os.rename if same filesystem, copy+delete if cross-filesystem)
   - Verify file at new location (hash check)
   - Create entry atomically
   - Clean up empty parent directories left behind
3. For duplicates: both get entries (with suffixed paths), both flagged
4. Track progress throughout

`InitializePlan`:
```python
@dataclass(frozen=True)
class InitializePlan:
    already_correct: list  # (source_path, relative_path, hash, metadata)
    needs_move: list       # (source_path, current_relative, target_relative, hash, metadata)
    duplicate_groups: list  # list of (hash, [file_infos])
    quarantined: list       # files with no date
    total_files: int
```

**Testing:**
- File already at correct path → indexed without move
- File at wrong path → moved to correct path, entry created
- Move verified (hash check at destination)
- Duplicate files → both indexed with suffix on second
- Quarantined files (no date) → flagged, not moved
- Empty directories cleaned up after moves
- Resume: files with entries skipped, files without retried
- Plan phase is read-only (no DB writes, no file moves)

**Notes:**
Depends on Tasks 1-3. Reuses discover_files, hash_file, extract_metadata, normalize_filename, compute_target_path. The relative path of a file within the library is computed from `file_path.relative_to(library.location)`.

---

### Task 6: Enhanced Library Create CLI

**Files:**
- Modify: `src/trove/cli.py` (library create detects files, offers initialize)
- Modify: `tests/test_cli.py` (test interactive create flow)

**Behavior:**
Enhanced `library create` flow:
1. Create the library record in DB
2. If location doesn't exist: create directory, show import command suggestion
3. If location exists and is empty: show import command suggestion
4. If location exists and has media files:
   - Count them: "Found N media files"
   - Prompt: "Scan and organize into library? [y/n]" (skip with --yes)
   - If yes: run plan_initialize, show plan, prompt to proceed, execute
   - If no: library created but empty (user can import later)

Add `--yes` flag to library create command.

**Testing:**
- Create with new directory: directory created, suggestion shown
- Create with empty directory: suggestion shown
- Create with files, user confirms: initialize runs
- Create with files, user declines: library created, no initialization
- Create with --yes: no prompts, auto-confirms

**Notes:**
Depends on Task 5. Uses click.confirm() for prompts.

---

### Task 7: Duplicates Command

**Files:**
- Modify: `src/trove/db.py` (add query for duplicate hash groups)
- Modify: `src/trove/cli.py` (add duplicates command)
- Create: `tests/test_duplicates.py`

**Behavior:**
New DB method: `get_duplicate_groups(library_id) -> list[list[EntryRecord]]` — returns groups of entries sharing the same md5_hash within a library, where the group has 2+ members.

New CLI command:
```
trove duplicates --library "Family Photos"
```

Shows each duplicate group with file details (path, size, capture date, camera model). For v1, read-only — just lists them. No interactive resolution yet.

**Testing:**
- Library with no duplicates: "No duplicates found"
- Library with 3 groups of duplicates: all shown with correct counts
- Each group shows all file details
- Library not found: error message

**Notes:**
Depends on Task 1 (hash uniqueness removed) and Task 5 (initialize creates duplicate entries).

---

### Task 8: Update Run Command

**Files:**
- Modify: `src/trove/cli.py` (run command uses plan-confirm for each step)
- Modify: `tests/test_cli.py` (test updated run flow)

**Behavior:**
The `run` command (scan + import + complete) now:
1. Scan (always runs, no confirmation needed — read-only)
2. Show import plan, prompt to proceed
3. Import with progress
4. Show complete plan (including deletion count if --delete-sources)
5. Prompt to proceed
6. Complete with progress

With `--yes`: all prompts auto-confirmed.

**Testing:**
- Run with --yes skips all prompts
- Run without --yes prompts at each destructive step
- Run can be interrupted between steps without data loss

**Notes:**
Depends on Tasks 3-4.
