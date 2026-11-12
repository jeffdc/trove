---
status: done
tags: [design]
created: 2026-04-01
updated: 2026-04-01
epic: trove
---

# Unify add and initialize into single pipeline

## Motivation

Reduce code duplication between `add` and `initialize` pipelines. Both share discovery, hashing, metadata extraction, and path computation — duplicated with slight variations that drift over time. Unify internals while keeping both CLI commands unchanged.

## Design: Composable Stage Pipeline

Each stage is a function that receives a list of file record IDs (plus shared context: `db`, `config`, `library`) and returns IDs for the next stage. Side effects are DB updates.

```
discover(source_path, db, config) → [id, ...]
hash_files(ids, db) → [id, ...]
extract_metadata(ids, db, config) → { hashed: [id, ...], quarantined: [id, ...] }
compute_paths(ids, db, config) → [id, ...]
classify(ids, db, library, mode) → Plan
execute(plan, db, library, mode) → Summary
```

### Stage details

**discover** — Walk source, insert file records with status="discovered". Skip files already tracked (by path + size + mtime for resume). Returns IDs of newly discovered files.

**hash_files** — Hash each file by ID. Update records with md5_hash, status="hashed". Returns same IDs.

**extract_metadata** — Chunked exiftool over IDs. Update capture_date, camera_model. Quarantine files with no usable date. Returns two lists: hashed IDs and quarantined IDs.

**compute_paths** — Compute target_path from metadata. Update records. Returns same IDs.

**classify** — Mode-dependent:
- **add mode**: batch dedup (by hash within ID list), library dedup (by size then hash against entries), path conflict detection. Returns an ImportPlan.
- **init mode**: compare current path to target path → move vs index. Returns an InitPlan.

**execute** — Mode-dependent:
- **add mode**: copy + streaming hash verify to library. Source untouched.
- **init mode**: try `os.rename` first. If cross-device error → copy + streaming hash verify + delete original. If rename succeeds → reuse source hash. Create entry either way.

Copy+verify logic is shared between both modes. Init mode wraps it with "try rename first, clean up source after."

### Command assembly

```
# trove add
ids = discover(source_path, db, config)
ids = hash_files(ids, db)
hashed, quarantined = extract_metadata(ids, db, config)
hashed = compute_paths(hashed, db, config)
plan = classify(hashed, db, library, mode="add")
# present plan, user confirms
summary = execute(plan, db, library, mode="add")

# trove library init
ids = discover(library_path, db, config)
ids = hash_files(ids, db)
hashed, quarantined = extract_metadata(ids, db, config)
hashed = compute_paths(hashed, db, config)
plan = classify(hashed, db, library, mode="init")
# present plan, user confirms
summary = execute(plan, db, library, mode="init")
```

First four stages are identical. Only classify and execute differ.

### Data flow: explicit ID passing (no global queries)

No more `query_files_by_status("hashed")` for inter-stage communication. Each stage receives explicit IDs from the prior stage. DB status field still updates (useful for debugging/inspection) but is never the data flow mechanism. This fixes the scoping bug where files from previous runs leaked into current run queries.

Reprocessing is idempotent — once a file is processed and stored, reprocessing produces the same result (target paths are deterministic from capture date + camera model + filename).

### Post-move hash fix

Init-mode execute uses `os.rename` success/failure as same-filesystem detection:
- Rename succeeds → same filesystem, reuse source hash (no wasted I/O)
- Rename fails (OSError cross-device) → fall back to shared copy+verify, then delete original

### Where current code lands

- `scan.py` — broken apart. `discover_files()` stays as file-walking utility. `scan_source()` orchestration replaced by stage sequence.
- `initialize.py` — each internal function (`_discover_and_persist`, `_extract_and_persist`, `_classify_from_db`, `execute_initialize`) becomes or feeds into a stage.
- `importer.py` — `plan_import` becomes add-mode classify. `execute_import` becomes add-mode execute.
- `cli.py` — each command assembles its stages. No change to user-facing behavior.

### What doesn't change

- DB schema
- CLI commands and flags
- File naming / target path logic
- Dedup logic (restructured into classify stage)
- Entry creation

### Key design principles

- Stages are composable — each command assembles the stages it needs
- Data flows explicitly via ID lists, not implicit DB status queries
- One copy+verify implementation shared by both modes
- `os.rename` failure is the cross-filesystem detector
- Resume works by re-running — early stages skip already-completed work

## Implementation Plan

**Goal:** Replace the duplicated scan/initialize/import orchestrations with composable pipeline stages that pass file IDs explicitly between steps.

**Architecture:** New `pipeline.py` module owns the shared stages. Existing modules (`scan.py`, `initialize.py`, `importer.py`) become thin wrappers that delegate to stages, preserving their public APIs so existing tests pass at every step. Once stages are proven, CLI switches to direct stage assembly and wrappers are removed.

**Tech Stack:** Python, SQLite (via existing `StateDB`), exiftool (via existing `extract_metadata_chunked`).

### Task 1: DB helper — query files by ID list

**Files:**
- Modify: `src/trove/db.py` (add `query_files_by_ids` method)
- Test: `tests/test_db.py` (create if needed, or add to existing)

**Behavior:**
Add `query_files_by_ids(self, ids: list[int]) -> list[FileRecord]` to `StateDB`. Takes a list of file record IDs, returns the matching `FileRecord` objects in the same order as the input IDs (skipping any IDs not found). This is the foundation for ID-based data flow between stages.

Use `WHERE id IN (...)` with parameter binding. For lists > 999 (SQLite variable limit), chunk into batches.

**Testing:**
- `test_returns_matching_records` — insert 3 files, query 2 by ID, get exactly those 2
- `test_preserves_order` — query [id3, id1, id2], get records in that order
- `test_skips_missing_ids` — query with a nonexistent ID, it's silently skipped
- `test_empty_list_returns_empty` — query with [] returns []

### Task 2: Shared pipeline stages — discover, hash, extract, compute_paths

**Files:**
- Create: `src/trove/pipeline.py`
- Test: `tests/test_pipeline.py`

**Behavior:**
Four functions, each taking explicit IDs (except discover which produces them):

`discover_and_persist(source_path, db, config, skip_paths=None, progress=None) -> list[int]`
- Calls existing `discover_files()` for the walk
- For each path: check if already in DB (by source_path + size + mtime) or in skip_paths → skip. Otherwise insert file record.
- Returns list of newly created file record IDs
- Unifies the insert loops from `scan_source` (lines 178-211) and `_discover_and_persist` (lines 89-107)

`hash_files(ids, db, progress=None) -> list[int]`
- For each ID: load record, call `hash_file()`, update DB with hash + status="hashed" + hashed_at
- Returns same ID list
- Extracted from `scan_source` lines 214-227

`extract_metadata(ids, db, config, progress=None) -> tuple[list[int], list[int]]`
- Load records by ID, extract metadata via `extract_metadata_chunked`
- Apply filesystem mtime fallback for missing dates
- Quarantine files with no usable date (update status, return in second list)
- Update capture_date + camera_model for good files
- Returns (hashed_ids, quarantined_ids)
- Unifies `scan_source` lines 230-274 and `_extract_and_persist` lines 125-171

`compute_paths(ids, db, config) -> list[int]`
- Load records by ID, call existing `compute_target_path()` for each
- Update target_path in DB
- Returns same ID list
- Extracted from `scan_source` lines 278-286 and `_extract_and_persist` lines 163-171

**Testing:**
- `test_discover_inserts_and_returns_ids` — discover files, verify IDs returned, records in DB
- `test_discover_skips_existing_unchanged` — re-discover same files, nothing new
- `test_discover_resets_changed_files` — change file size, re-discover, file re-inserted
- `test_discover_skips_skip_paths` — pass skip_paths set, those paths excluded
- `test_hash_files_updates_records` — hash a set of IDs, verify md5_hash + status in DB
- `test_extract_metadata_splits_hashed_and_quarantined` — mock exiftool, verify two lists
- `test_extract_metadata_mtime_fallback` — no EXIF date, valid mtime → hashed not quarantined
- `test_extract_metadata_quarantines_invalid_mtime` — no EXIF, mtime year < 2000 → quarantined
- `test_compute_paths_updates_target_path` — verify target_path set in DB for each ID

**Notes:**
- `extract_metadata` should use `query_files_by_ids` from Task 1 to load records
- Reuse `discover_files` and `compute_target_path` from `scan.py` — don't duplicate
- The quarantine logic (year validation range) must match what `scan_source` and `_extract_and_persist` currently do

### Task 3: Classify stages — import mode and init mode

**Files:**
- Modify: `src/trove/pipeline.py` (add classify functions)
- Test: `tests/test_pipeline.py` (add classify tests)

**Behavior:**

`classify_for_import(ids, db, library, config, progress=None) -> ImportPlan`
- Takes explicit list of hashed file IDs (not a global query)
- Same logic as current `plan_import()`: batch dedup by hash, library dedup by size-then-hash, path conflict count
- Returns `ImportPlan` (reuse existing dataclass)

`classify_for_init(ids, quarantined_ids, db, library, config) -> InitializePlan`
- Takes explicit hashed IDs + quarantined IDs
- Same logic as current `_classify_from_db()`: compare relative_path to target_path, classify as index/move/quarantine
- Returns `InitializePlan` (reuse existing dataclass)
- Moves `_resolve_path` helper into `pipeline.py` (or a shared location)

**Testing:**
- `test_classify_import_batch_dedup` — 3 files same hash → 1 to_import, 2 batch dups
- `test_classify_import_library_dedup` — file hash matches entry → library dup
- `test_classify_import_unique` — unique file → to_import
- `test_classify_import_only_uses_given_ids` — insert extra hashed files in DB, verify they're ignored
- `test_classify_init_correct_path` — file at target path → already_correct
- `test_classify_init_needs_move` — file at wrong path → needs_move
- `test_classify_init_quarantine` — quarantined file → quarantine action with quarantine target path
- `test_classify_init_path_conflict_suffix` — two files same target → second gets -1 suffix

**Notes:**
- The critical test is `test_classify_import_only_uses_given_ids` — this validates the scoping fix. Insert "hashed" files outside the given ID list and confirm they're not included.
- `classify_for_import` should accept IDs, load records via `query_files_by_ids`, and operate only on those records.

### Task 4: Execute helper — move_file with cross-filesystem fallback

**Files:**
- Modify: `src/trove/pipeline.py` (add `move_file`)
- Test: `tests/test_pipeline.py` (add move tests)

**Behavior:**

`move_file(source, dest, expected_hash) -> tuple[bool, str]`
- Try `os.rename(source, dest)` first
- If succeeds → return `(True, expected_hash)` — same filesystem, hash unchanged
- If `OSError` with errno `EXDEV` (cross-device link) → fall back to `_copy_and_verify(source, dest, expected_hash)` + delete original on success
- Returns `(success, verified_hash)`

Reuse existing `_copy_and_verify` from `importer.py` — move it to `pipeline.py` since both modes need it.

**Testing:**
- `test_move_same_filesystem` — rename within tmp_path, verify file moved, original gone, hash correct
- `test_move_cross_filesystem` — mock `os.rename` to raise `OSError(errno.EXDEV)`, verify copy+verify+delete fallback
- `test_move_copy_verify_failure` — cross-filesystem move where copy hash doesn't match → returns False, source preserved
- `test_move_creates_parent_dirs` — destination directory doesn't exist → created

**Notes:**
- This replaces the redundant pre+post hash in `execute_initialize`'s move loop
- For same-filesystem: one hash (before) + atomic rename. For cross-filesystem: streaming hash during copy (zero extra reads).

### Task 5: Rewire scan_source to use pipeline stages

**Files:**
- Modify: `src/trove/scan.py` (rewrite `scan_source` internals)
- Test: `tests/test_scan.py` (existing tests must pass unchanged)

**Behavior:**
Replace the body of `scan_source()` with stage calls:
```python
def scan_source(source_path, db, config, progress=None):
    ids = discover_and_persist(source_path, db, config, progress=progress)
    ids = hash_files(ids, db, progress=progress)
    hashed, quarantined = extract_metadata(ids, db, config, progress=progress)
    compute_paths(hashed, db, config)
    return {"discovered": len(ids), "hashed": len(hashed), ...}
```

Keep the function signature and return dict format identical.

**Testing:**
All 6 existing `TestScanSource` tests must pass without modification. Run the full test suite.

**Notes:**
- `discover_files()` and `compute_target_path()` stay in `scan.py` — they're pure utilities, not orchestration.
- The `skipped` count in the return dict comes from discover_and_persist (files that were already in DB). Need to return both new IDs and skip count from discover.

### Task 6: Rewire initialize to use pipeline stages

**Files:**
- Modify: `src/trove/initialize.py` (rewrite `plan_initialize` + `execute_initialize`)
- Test: `tests/test_initialize.py` (existing tests must pass unchanged)

**Behavior:**

Rewrite `plan_initialize`:
```python
def plan_initialize(library, db, config, progress=None, known_paths=None):
    skip_paths = {e.relative_path for e in db.list_entries(library.id)}
    # discover_and_persist needs to handle known_paths (skip walk, use provided list)
    ids = discover_and_persist(lib_path, db, config, skip_paths=skip_paths, 
                               known_paths=known_paths, progress=progress)
    ids = hash_files(ids, db, progress=progress)
    hashed, quarantined = extract_metadata(ids, db, config, progress=progress)
    compute_paths(hashed, db, config)  # already done inside extract for init? No — separate stage
    return classify_for_init(hashed, quarantined, db, library, config)
```

Rewrite `execute_initialize` to use `move_file` from Task 4:
- For needs_move: call `move_file(source, dest, source_hash)` instead of manual rename+re-hash
- For already_correct: index with null hash (unchanged)
- For quarantined: same as needs_move
- Remove the duplicated move+hash logic in the duplicates/quarantine loops

**Testing:**
All 11 existing initialize tests must pass without modification.

**Notes:**
- `discover_and_persist` needs a `known_paths` parameter to support the `library_create` CLI flow (where files are already discovered). When provided, skip the directory walk and use those paths.
- The current `_extract_and_persist` combines metadata extraction AND target path computation in one step. In the new pipeline, these are separate stages. The tests should still pass because the stages produce the same end state in DB.
- `_resolve_path` and `_cleanup_empty_dirs` stay as helpers in `initialize.py` or move to `pipeline.py`.

### Task 7: Rewire importer to use pipeline stages

**Files:**
- Modify: `src/trove/importer.py` (rewrite `plan_import`)
- Test: `tests/test_importer.py` (existing tests must pass unchanged)

**Behavior:**

Rewrite `plan_import` to delegate to `classify_for_import`:
```python
def plan_import(db, library, config, progress=None):
    all_hashed = db.query_files_by_status("hashed")  # still needed for backward compat
    ids = [f.id for f in all_hashed]
    return classify_for_import(ids, db, library, config, progress=progress)
```

Note: `plan_import` still queries by status here for backward compatibility (the CLI calls scan_source → plan_import and doesn't pass IDs yet). This gets cleaned up in Task 8.

`execute_import` stays largely as-is — it already uses `_copy_and_verify` correctly for cross-filesystem copies. Move `_copy_and_verify` to `pipeline.py` and import it.

**Testing:**
All 14 existing importer tests must pass without modification.

**Notes:**
- `import_to_library` backward-compat wrapper can stay — it's used by tests.
- `_resolve_target_path` and `_resolve_target_path_on_disk` stay in importer — they're import-specific (DB-based and disk-based conflict resolution respectively).

### Task 8: Update CLI to assemble stages directly

**Files:**
- Modify: `src/trove/cli.py` (rewrite `add` and `library_create` command internals)
- Modify: `src/trove/scan.py` (remove `scan_source` if no longer needed)
- Modify: `src/trove/initialize.py` (remove old internal functions)

**Behavior:**

Rewrite the `add` command body:
```python
ids = discover_and_persist(source_path, db, config, progress=...)
ids = hash_files(ids, db, progress=...)
hashed, quarantined = extract_metadata(ids, db, config, progress=...)
compute_paths(hashed, db, config)
plan = classify_for_import(hashed, db, library, config, progress=...)
# show plan, get confirmation
summary = execute_import(db, library, config, plan, ...)
```

Rewrite `library_create`'s initialization flow similarly.

Remove:
- `scan_source` from `scan.py` (orchestration replaced by stage assembly)
- `_discover_and_persist`, `_extract_and_persist`, `_classify_from_db` from `initialize.py`
- `import_to_library` backward-compat wrapper from `importer.py`

**Testing:**
Existing tests pass. The report helpers in CLI (`_generate_and_open_report`) need their `query_files_by_status("hashed")` calls replaced with ID-scoped queries — pass the hashed IDs through to the report function.

**Notes:**
- The `add` command's interactive menu (review quarantined, duplicates, report) currently re-queries `query_files_by_status`. These should use the ID lists from the pipeline instead.
- `complete.py` (`plan_complete`/`execute_complete`) still uses status queries — this is fine for now since it runs after import is done and operates on terminal statuses (imported, duplicate). Consider a follow-up to clean this up.
- Keep `discover_files` and `compute_target_path` in `scan.py` as public utilities.
