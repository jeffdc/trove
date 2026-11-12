---
status: done
created: 2026-03-27
updated: 2026-03-29
epic: trove
relates: [9855]
---

# Trove v1

Build Trove per trove-spec.md v2.0

## Implementation Plan

**Goal:** Build a CLI tool that organizes photos/videos from sources into deduplicated libraries, with full audit trail and library verification.

**Architecture:** Three-step pipeline (scan → import → complete) backed by a SQLite state database with three core tables (libraries, entries, files). CLI exposes each step as a subcommand plus `run` for the full pipeline. Libraries are first-class entities. State transitions are atomic via SQLite transactions.

**Tech Stack:** Python 3.10+, Click (CLI), SQLite3 (state DB), PyYAML (config), exiftool (EXIF via subprocess), rich (progress/output).

### Task 1: Project Scaffolding & Config

**Files:**
- Create: `pyproject.toml`
- Create: `src/trove/__init__.py`
- Create: `src/trove/config.py`
- Create: `src/trove/cli.py` (placeholder Click group)
- Create: `tests/conftest.py`
- Create: `tests/test_config.py`

**Behavior:**
Python package with src layout, Click entry point. Config module loads and validates `trove.yaml` — organization, file types, exclude patterns, network, hashing, logging settings. Frozen dataclasses with baked-in defaults. Tool works with no config file.

**Testing:**
- Load valid config with all fields
- Load config with only optional overrides, defaults fill the rest
- Unknown fields ignored
- Invalid values raise clear errors
- No config file returns pure defaults
- Relative paths resolved correctly

**Status:** DONE

---

### Task 2: State Database

**Files:**
- Create: `src/trove/db.py`
- Create: `tests/test_db.py`

**Behavior:**
SQLite database with three tables: `libraries`, `entries`, `files`. `StateDB` class wraps connection management (context manager), table creation on first open, WAL mode, and typed methods for each operation. Dataclasses for row types (`LibraryRecord`, `EntryRecord`, `FileRecord`). DB path defaults to `~/.trove/state.db`.

API surface:
- Libraries: `create_library(name, location)`, `get_library(name_or_id)`, `list_libraries()`
- Entries: `create_entry(library_id, relative_path, ...)`, `get_entry_by_path(library_id, relative_path)`, `get_entry_by_hash(library_id, md5_hash)`, `list_entries(library_id)`
- Files: `insert_file(...)`, `get_file_by_path(source_path)`, `update_file(id, **fields)`, `query_files_by_status(status)`, `delete_files_by_status(statuses)`
- Transactions: context manager for atomic entry creation + file status update

**Testing:**
- Create database, verify all tables exist with correct columns and indexes
- Create a library, read it back
- Library name uniqueness enforced
- Insert file record, read back, verify all fields
- Update file status and hash
- Query files by status returns only matching
- Create entry, read back by path and by hash
- Entry uniqueness enforced (library_id + relative_path, library_id + md5_hash)
- Atomic transaction: entry + file status update committed together
- Atomic transaction: rollback on error leaves no partial state
- Reopen existing DB preserves all data
- WAL mode enabled

---

### Task 3: Filename Normalization

**Files:**
- Create: `src/trove/normalize.py`
- Create: `tests/test_normalize.py`

**Behavior:**
Single function that all filenames and camera model strings pass through. Rules per spec section 6: NFC unicode normalization, replace unsafe characters, collapse underscores, strip leading/trailing dots and underscores, preserve extension, handle empty basenames, truncate long names with hash suffix.

**Testing:**
- Path-unsafe characters replaced with underscore
- Whitespace replaced with underscore
- Multiple consecutive underscores collapsed
- Leading/trailing dots and underscores stripped
- Extension preserved including case
- Empty basename becomes "unnamed"
- Long filename (>200 chars) truncated with hash suffix, still unique
- Camera model "Canon EOS R5" becomes "Canon_EOS_R5"
- Unicode normalized to NFC
- Already-clean filename passes through unchanged

---

### Task 4: Hashing

**Files:**
- Create: `src/trove/hashing.py`
- Create: `tests/test_hashing.py`

**Behavior:**
Compute MD5 of files in configurable chunk sizes. Progress reporting callback for large files. Pure function: takes a path, returns a hash string. Handles unreadable files by raising a clear exception.

**Testing:**
- Correct MD5 for known test files
- Chunked reading handles large files without memory issues
- Progress callback fires with byte counts
- Unreadable file raises clear error
- Empty file handled (not skipped by hasher — caller decides)

**Notes:**
Simpler than original plan — no partial hash optimization, no SHA256, no parallelization for v1. Can add these later if performance requires it.

---

### Task 5: Metadata Extraction

**Files:**
- Create: `src/trove/metadata.py`
- Create: `tests/test_metadata.py`

**Behavior:**
Shell out to exiftool via subprocess. Batch mode: pass multiple files in one invocation, parse JSON output. Extract capture_date (through fallback chain) and camera_model. Return structured results keyed by file path.

**Testing:**
- Extracts DateTimeOriginal from JPEG
- Falls back through date chain correctly (CreateDate, ModifyDate, file date)
- No date at all returns None (caller decides to quarantine)
- Camera model extracted and returned
- Missing camera model returns None
- Corrupt EXIF handled without crashing
- Empty EXIF date strings treated as missing
- Obviously wrong dates (< 2000, > current year + 1) flagged
- Batch invocation processes multiple files in one call
- Video files metadata extracted
- exiftool not installed raises clear error

**Notes:**
Depends on exiftool being installed. Tests should either use real small test files with known EXIF or mock subprocess — discuss testing approach before building.

---

### Task 6: File Discovery & Scan

**Files:**
- Create: `src/trove/scan.py`
- Create: `tests/test_scan.py`
- Create: `tests/fixtures/` (test file trees)

**Behavior:**
Walk source directories, filter by configured file types (case-insensitive) and exclude patterns. Skip zero-byte files. Apple library detection and extraction per spec section 5. For each file: normalize filename, record in files table, hash, extract metadata, compute target_path. Incremental: skip files already in DB with same size + mtime.

This is the orchestrator for the scan step — it uses hashing (Task 4), metadata (Task 5), normalization (Task 3), and DB (Task 2).

**Testing:**
- Discovers files by extension (case-insensitive)
- Skips excluded patterns (.DS_Store, ._*, etc.)
- Skips zero-byte files
- Handles filenames with spaces, unicode, special characters
- Incremental: skips unchanged files, re-discovers changed files
- Source path does not exist: error
- Permission denied on file: logs warning, skips, continues
- Apple Photos library: finds files in originals/ then Masters/
- iPhoto library: finds files in Masters/, also Modified/
- Aperture library: finds files in Masters/ then Originals/
- Skips Previews/, Thumbnails/, database files
- Computes correct target_path from metadata + config
- All files end at status = hashed (or quarantined) after scan

**Notes:**
Depends on Tasks 2-5. This is the first "stage orchestrator" — it ties the lower-level modules together.

---

### Task 7: Import

**Files:**
- Create: `src/trove/importer.py`
- Create: `tests/test_importer.py`

**Behavior:**
Dedup within batch (group hashed files by md5, mark extras as duplicate). Dedup against library (check hashes against entries). For each remaining file: resolve path conflicts with auto-suffix, copy to library, verify copy hash, atomic DB update (create entry + set status = imported). Resume handling for orphan files. Network resilience.

**Testing:**
- Batch dedup: identifies duplicates within scanned files
- Library dedup: identifies files already in library
- Copies file correctly to library location
- Creates directory structure
- Verifies copy via hash comparison
- Hash mismatch triggers delete + retry
- Atomic transaction: entry + status update together
- Atomic transaction: rollback leaves no partial state
- Path conflict auto-resolved with suffix
- Suffix doesn't collide with existing entries
- No suffix chains
- Resume: orphan file verified and entry created
- Resume: corrupt orphan file deleted and re-copied
- Progress reporting
- Dry-run mode shows plan without copying

**Notes:**
Depends on Tasks 2-4, 6. Network resilience tests may need to mock filesystem operations.

---

### Task 8: Complete

**Files:**
- Create: `src/trove/complete.py`
- Create: `tests/test_complete.py`

**Behavior:**
Assert all files are accounted for (imported, duplicate, or quarantined). Refuse to complete if any files still at discovered/hashed. Verify imported files have entries, duplicate files have matching library entries. Report summary. Offer to delete file records and optionally source files.

**Testing:**
- Reports all files accounted for when complete
- Refuses when files still at hashed status
- Refuses when files still at discovered status
- Deletes file records on confirmation
- Deletes source files only with explicit confirmation
- Does not delete source files if any unaccounted
- Handles already-deleted source files gracefully (file removed externally)
- Report shows correct counts

**Notes:**
Depends on Task 7 (import must have run).

---

### Task 9: Verify

**Files:**
- Create: `src/trove/verify.py`
- Create: `tests/test_verify.py`

**Behavior:**
Check entries against disk: verify files exist, sizes match, optionally hashes match. Check disk against entries: find orphan files. Report health status. Exit codes: 0 = healthy, 1 = issues, 2 = error.

**Testing:**
- Healthy library: all entries verified, no orphans, exit 0
- Missing file detected (entry exists, file gone)
- Orphan file detected (file on disk, no entry)
- Size mismatch detected
- `--thorough` detects hash mismatch
- Library not accessible: clear error, exit 2
- NAS disconnect during verify: handled gracefully
- Empty library: healthy (nothing to verify)

**Notes:**
Independent of the pipeline. Can be run anytime.

---

### Task 10: CLI Wiring

**Files:**
- Modify: `src/trove/cli.py` (add all subcommands)
- Create: `tests/test_cli.py`

**Behavior:**
Click CLI with subcommands: `library create/list/show`, `scan`, `import`, `complete`, `run`, `verify`, `status`. Common flags: `--config`, `--dry-run`, `--verbose`, `--quiet`, `--library`. `run` executes scan + import + complete. `status` queries DB for counts.

**Testing:**
- Each subcommand invocable
- `--config` loads correct file
- `--dry-run` produces output without side effects
- `--library` selects correct library
- `run` executes all three steps
- `status` shows correct counts
- Missing library name: clear error
- Library doesn't exist: clear error

**Notes:**
Wiring task — individual steps are already tested. CLI tests are integration tests.

---

### Task 11: Logging & Audit Trail

**Files:**
- Create: `src/trove/audit.py`
- Modify: `src/trove/importer.py` (add audit logging)
- Modify: `src/trove/complete.py` (add audit logging)
- Create: `tests/test_audit.py`

**Behavior:**
Operational log (standard Python logging, configurable level). Audit log (append-only JSON lines) recording every file operation: import, skip_duplicate, quarantine, delete_source. Integrated into import and complete steps.

**Testing:**
- Audit log records import operations with all fields
- Audit log records skip_duplicate, quarantine, delete_source
- Audit log is append-only (re-run appends, doesn't overwrite)
- Operational log respects configured level
- `--verbose` sets DEBUG, `--quiet` sets ERROR
