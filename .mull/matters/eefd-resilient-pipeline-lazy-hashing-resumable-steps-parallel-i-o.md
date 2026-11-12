---
status: done
tags: [design]
created: 2026-03-31
updated: 2026-03-31
epic: trove
relates: [130e, ad92, 9544]
---

# Resilient pipeline: lazy hashing, resumable steps, parallel I/O

Supersedes 130e, ad92, 9544.

## Design: Resilient Pipeline

### Problems

1. Initialize hashes every file upfront — 60K files over NAS = 4+ hours
2. Plan phase holds everything in memory — crash loses all work
3. Exiftool called with all paths at once — OS arg limit crash at ~60K files
4. No parallelism — serial I/O leaves the network pipe mostly idle
5. No progress on metadata extraction

### Principles

- Every step writes to DB as it goes — crash at any point loses at most one file's work
- Hash only when there's a reason to hash
- Parallelize I/O where it helps without thrashing
- Batch exiftool in chunks to avoid arg limits and enable progress

### Design

#### Lazy Hashing

`md5_hash` on entries becomes **nullable**. Hashes are computed only when needed:

| Operation | Hashes? | Why |
|-----------|---------|-----|
| Initialize: discover + metadata | No | Just reading EXIF headers |
| Initialize: move a file | Yes (that file only) | Post-move verification |
| Initialize: index in-place file | No | No verification needed |
| Add: dedup check | Size first, hash on demand | Only hash size-matched files |
| Add: copy to library | Yes | Post-copy verification |
| Verify --thorough | Yes (or skip if no hash) | Integrity check |
| `trove hash` (new command) | Yes (backfill) | User-initiated, run overnight |

#### Resumable Steps

Initialize pipeline, each step persists to DB:

```
1. DISCOVER: walk directory → write file record per file (status: discovered)
   Resume: skip files already in DB by source_path

2. METADATA: chunked exiftool (500 per batch) → update file records
   Resume: skip files that already have capture_date set

3. CLASSIFY: compute target paths, detect dupes by size
   This is fast (DB reads + computation), no persistence needed

4. EXECUTE: move/index files → create entries, delete file records
   Resume: skip files that already have entries (by relative_path)
```

Each step queries the DB for what needs doing. Interruption at any point means re-running picks up from the last completed record.

#### Parallel I/O

| Step | Parallelism |
|------|------------|
| Discovery | Serial (single directory walk, fast enough) |
| Metadata | Multiple exiftool processes (2-3 concurrent, 500 files each) |
| Hashing (when needed) | Thread pool (4-8 threads, GIL released during file reads) |
| Moves | Serial (SMB locking concerns) |
| Copies (add) | Serial (same reason) |

#### Chunked Exiftool

Replace single `extract_metadata(all_paths)` call with chunked version:

```python
def extract_metadata_chunked(paths, chunk_size=500, progress=None):
    results = {}
    for i in range(0, len(paths), chunk_size):
        chunk = paths[i:i+chunk_size]
        results.update(extract_metadata(chunk))
        if progress:
            progress.update(task_id, advance=len(chunk))
    return results
```

This fixes the arg-too-long crash AND gives progress feedback.

#### Add Flow with Size-First Dedup

```python
# For each source file:
1. Check: any entry in library with same file_size?
   No  → definitely new, import it
   Yes → hash the source file
         hash the matching entry(s) if not already hashed
         compare hashes
         match → duplicate, skip
         no match → new file, import it
```

Requires index on `entries.file_size`.

#### New Command: `trove hash`

```
trove hash [--library <name>]
```

Backfills hashes for entries that don't have them. Parallel threads, progress bar, resumable. Run it overnight on the NAS.

#### Schema Changes

- `entries.md5_hash`: NOT NULL → nullable
- Add index on `entries.file_size`
- `entries.file_size` index used for size-first dedup lookup
- New DB method: `get_entries_by_size(library_id, file_size) -> list[EntryRecord]`

#### What Changes in Existing Code

| Module | Change |
|--------|--------|
| db.py | md5_hash nullable on entries, add get_entries_by_size, add file_size index |
| metadata.py | Add extract_metadata_chunked with progress + chunk_size |
| initialize.py | Complete rewrite: discover→DB, metadata→DB, classify from DB, execute |
| importer.py | Size-first dedup check, hash on demand |
| cli.py | Add `trove hash` command, update progress wiring |
| hashing.py | Add parallel hash function with thread pool |

#### What Does NOT Change

- normalize.py, config.py, scan.py, verify.py, report.py, audit.py, plan.py
- The add/import pipeline structure (scan → plan → execute)
- CLI UX (menus, prompts, library resolution)


## Implementation Plan

**Goal:** Make the pipeline resilient to interruption, lazy about hashing, and parallel where it helps — so initializing a 60K-file NAS library takes minutes, not hours.

**Architecture:** Every step persists to DB as it goes. Hashing is deferred until actually needed (moves, dedup, verify). Exiftool calls are chunked for arg-limit safety and progress. Hashing uses a thread pool for concurrent I/O. The initialize module is rewritten to follow discover→metadata→classify→execute with DB persistence at each step.

**Tech Stack:** Existing stack plus `concurrent.futures.ThreadPoolExecutor` for parallel hashing.

### Task 1: Schema — Make entry hash nullable, add size index

**Files:**
- Modify: `src/trove/db.py` (schema, create_entry, import_file, get_entries_by_size)
- Modify: `tests/test_db.py`

**Behavior:**
Change `md5_hash TEXT NOT NULL` to `md5_hash TEXT` (nullable) on entries table. Add index on `entries(library_id, file_size)`. Add new method `get_entries_by_size(library_id, file_size) -> list[EntryRecord]`. Update `create_entry` to accept `md5_hash=None`. Update `import_file` — it still requires a hash (imports always verify).

**Testing:**
- Create entry with md5_hash=None succeeds
- Create entry with md5_hash set still works
- get_entries_by_size returns matching entries
- get_entries_by_size returns empty list for no match
- Existing tests still pass (entries with hashes still work)
- import_file still requires hash (unchanged)

**Notes:**
This is the foundation. Everything else depends on it.

---

### Task 2: Chunked exiftool with progress

**Files:**
- Modify: `src/trove/metadata.py` (add extract_metadata_chunked)
- Modify: `tests/test_metadata.py`

**Behavior:**
Add `extract_metadata_chunked(paths, chunk_size=500, progress=None)` that splits paths into chunks of `chunk_size`, calls `extract_metadata` per chunk, merges results, and updates progress after each chunk. The existing `extract_metadata` is unchanged (still processes one batch). The chunked version is the new entry point for callers with large path lists.

**Testing:**
- Chunked with 10 files and chunk_size=3 calls extract_metadata 4 times (3+3+3+1)
- Results merged correctly across chunks
- Progress callback advances after each chunk
- Empty paths list returns empty dict
- Single chunk (fewer paths than chunk_size) works

**Notes:**
All tests mock subprocess as before. This fixes the arg-too-long crash.

---

### Task 3: Parallel hashing with thread pool

**Files:**
- Modify: `src/trove/hashing.py` (add hash_files_parallel)
- Modify: `tests/test_hashing.py`

**Behavior:**
Add `hash_files_parallel(paths, max_workers=4, chunk_size=8192, progress=None) -> dict[str, str]` that uses ThreadPoolExecutor to hash multiple files concurrently. Returns dict mapping str(path) -> md5 hex string. Catches per-file errors without killing the batch (logs warning, skips file). Progress updated per file completed.

**Testing:**
- Hashes 10 files correctly with 4 workers
- Results match serial hash_file for each file
- Unreadable file skipped, others still hashed
- Progress advances per file
- Single file works
- Empty list returns empty dict

**Notes:**
GIL is released during file I/O, so threads genuinely help for NAS reads. Default 4 workers is conservative — user could tune later.

---

### Task 4: Rewrite initialize — discover step with DB persistence

**Files:**
- Modify: `src/trove/initialize.py` (rewrite plan_initialize)
- Modify: `tests/test_initialize.py`

**Behavior:**
Rewrite `plan_initialize` to persist to DB as it goes. Split into internal steps:

Step 1 — Discover: `_discover_and_persist(library, db, config, progress)`
- Call discover_files to get all media paths
- For each path: check if file record already exists in DB (by source_path) — if so, skip (resume)
- Check if entry already exists for this relative path — if so, skip (already initialized)
- Insert file record to DB with status="discovered", file_size, file_modify_date
- Progress: live counter

This step alone makes the discovery resumable.

**Testing:**
- Files written to DB as discovered
- Re-run skips files already in DB
- Re-run skips files that already have entries
- Progress callback fires

---

### Task 5: Rewrite initialize — metadata step with DB persistence

**Files:**
- Modify: `src/trove/initialize.py`
- Modify: `tests/test_initialize.py`

**Behavior:**
Step 2 — Metadata: `_extract_and_persist(library, db, config, progress)`
- Query all file records with status="discovered" (no capture_date yet)
- Call extract_metadata_chunked on their paths (500 per chunk)
- For each result: update file record with capture_date, camera_model
- Update status to "hashed" (name is legacy but means "metadata extracted")
- Filesystem date fallback for files with no EXIF date
- Files with no date at all: status="quarantined"
- Progress: per chunk

**Testing:**
- Metadata written to file records in DB
- Files with no EXIF date fall back to filesystem date
- Files with no date at all quarantined
- Re-run skips files that already have metadata
- Chunked exiftool called (mock verifies chunk_size respected)

---

### Task 6: Rewrite initialize — classify and plan from DB

**Files:**
- Modify: `src/trove/initialize.py`
- Modify: `tests/test_initialize.py`

**Behavior:**
Step 3 — Classify: `_classify_from_db(library, db, config) -> InitializePlan`
- Query all processed file records (status="hashed" with capture_date set)
- Compute target_path for each from capture_date + camera_model + filename + config
- Compare current relative_path to target_path:
  - Same → already_correct (just needs entry, no move)
  - Different → needs_move
- Detect duplicates by file_size: group files with same size, check if >1 file would land at same target_path or has same size as another file. For init, we flag potential dupes but don't hash to confirm — we keep both with suffix.
- Actually simpler: just detect target path collisions. If two files want the same target path, suffix the second. That's the only "duplicate" detection needed during init. Real dedup (by content) happens during `add` or via `trove hash` + `trove duplicates`.
- Resolve all target paths against claimed paths set (existing entries + planned targets)
- Return InitializePlan built from DB records

**Testing:**
- File at correct path classified as already_correct
- File at wrong path classified as needs_move
- Target path collision suffixed
- Quarantined files excluded from plan
- Plan built from DB, not in-memory state

**Notes:**
This is now a fast, in-memory operation that reads from DB. No file I/O needed.

---

### Task 7: Rewrite initialize — execute with hash-on-move

**Files:**
- Modify: `src/trove/initialize.py`
- Modify: `tests/test_initialize.py`

**Behavior:**
Step 4 — Execute: `execute_initialize(library, db, plan, audit, progress) -> InitializeResult`

For already_correct files:
- Create entry with md5_hash=None (no hash needed, file didn't move)
- Delete file record from DB

For needs_move files:
- Hash source file (needed for post-move verification)
- Move file (os.rename)
- Hash destination, compare to source hash
- On mismatch: move back, log error
- On success: create entry with md5_hash set, delete file record
- Clean up empty dirs

For quarantined files:
- Move to quarantine dir if not already there
- Create entry with md5_hash=None
- Delete file record

Progress throughout. Each file record deleted from the working table after success.

**Testing:**
- Already correct file: entry created with null hash, file not moved
- Moved file: entry created with hash, old location gone
- Move verified by hash comparison
- Failed verification: file moved back
- Empty dirs cleaned up
- Quarantined files moved to quarantine dir
- File records cleaned up after each file

---

### Task 8: Update add/import — size-first dedup

**Files:**
- Modify: `src/trove/importer.py` (plan_import uses size-first check)
- Modify: `tests/test_importer.py`

**Behavior:**
Change library dedup in `plan_import` from hash-based to size-first:

```python
# Old: check hash
existing = db.get_entries_by_hash(library.id, f.md5_hash)

# New: check size first, then hash on demand
size_matches = db.get_entries_by_size(library.id, f.file_size)
if not size_matches:
    # Unique size — definitely new
    to_import.append(f)
else:
    # Same size exists — need to hash both to compare
    if f.md5_hash is None:
        f_hash = hash_file(Path(f.source_path))
        db.update_file(f.id, md5_hash=f_hash)
    # Hash matching entries if not already hashed
    is_dup = False
    for entry in size_matches:
        if entry.md5_hash is None:
            entry_hash = hash_file(Path(library.location) / entry.relative_path)
            # Update entry hash in DB (backfill)
            db.update_entry_hash(entry.id, entry_hash)
            if entry_hash == f.md5_hash:
                is_dup = True
                break
        elif entry.md5_hash == f.md5_hash:
            is_dup = True
            break
    if is_dup:
        library_duplicates.append(f)
    else:
        to_import.append(f)
```

Need new DB method: `update_entry_hash(entry_id, md5_hash)` for backfilling.

**Testing:**
- Unique size file: imported without hashing library
- Same size, same hash: detected as duplicate
- Same size, different hash: imported (not a duplicate)
- Entry hash backfilled during comparison
- Existing hash-based tests updated

---

### Task 9: trove hash command

**Files:**
- Modify: `src/trove/cli.py` (add hash command)
- Modify: `tests/test_cli.py`

**Behavior:**
New command: `trove hash [--library <name>]`
- Queries entries with md5_hash=NULL
- Uses hash_files_parallel to hash them
- Updates entries with computed hashes
- Progress bar, resumable (skips entries that already have hashes)

```
$ trove hash
Using library: Family Photos

23,456 entries without hashes.
Hashing... ████████████████████ 23456/23456
Done. All entries now have hashes.
```

**Testing:**
- Entries without hashes get backfilled
- Entries with hashes skipped
- Progress updates
- Empty library: "Nothing to hash"

---

### Task 10: Wire progress into all CLI operations

**Files:**
- Modify: `src/trove/cli.py`

**Behavior:**
Ensure every long-running step in the CLI has progress:
- Initialize discover: live counter
- Initialize metadata: progress bar (chunked)
- Initialize execute: progress bar
- Add scan: progress bar (already wired)
- Add import: progress bar (already wired)
- Hash backfill: progress bar
- Verify: progress bar (already wired)

**Testing:**
No new tests — visual/integration only. Existing tests pass with progress=None.

**Notes:**
Mostly wiring. The progress infrastructure exists, just needs to be threaded through the new chunked metadata and parallel hashing calls.
