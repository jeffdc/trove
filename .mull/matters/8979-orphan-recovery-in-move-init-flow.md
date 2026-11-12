---
status: done
created: 2026-04-12
updated: 2026-04-12
relates: [7053]
---

# Orphan recovery in move/init flow

## Design

Before attempting a move, check if source exists. If missing, look for the file at the destination.

**Flow per file in _move_and_create_entry:**
1. Source exists → move as normal
2. Source missing → check destination
   a. At destination, size+hash match → already moved. Create entry if needed, delete file record. Count as success.
   b. At destination, hash mismatch → mark status=missing, error_message="source_missing_dest_mismatch"
   c. Not at destination → mark status=missing, error_message="source_missing"

**New status:** `missing` in the file status state machine. Skipped by resume. Visible via `trove status NAME` ("X missing files"). Listable with `--missing`. Clearable with `--clear-missing`.

**Hash validation:** Compare file_size first (cheap), then md5_hash if size matches.

## Implementation Plan

**Goal:** Build orphan recovery into the init flow so interrupted runs self-heal, and truly missing files are tracked cleanly.

**Architecture:** Change _move_and_create_entry to handle missing sources. Add missing file visibility to status command. No new commands.

### Task 1: Orphan recovery in _move_and_create_entry

**Files:**
- Modify: `src/trove/initialize.py`
- Test: `tests/test_initialize.py`

**Behavior:**
At the top of `_move_and_create_entry`, before attempting the move, check if source exists. If not:
- Build dest path from lib_path / action.target_path
- If dest exists and dest.stat().st_size == action.file_size:
  - Hash dest file, compare to action.md5_hash
  - If match: create entry (if not already in entries table), delete file record, return True
  - If mismatch: update file status to "missing" with error_message="source_missing_dest_mismatch", return False
- If dest doesn't exist: update file status to "missing" with error_message="source_missing", return False

The on_error callback is NOT called for recovered files (they're successes). For files marked missing, call on_error with a clean message like "file missing from source and destination".

**Testing:**
- `test_orphan_recovery_file_already_moved` — source gone, dest exists with matching hash → entry created, file record deleted, counted as moved
- `test_orphan_recovery_dest_mismatch` — source gone, dest exists with different hash → status=missing
- `test_orphan_recovery_truly_missing` — source gone, dest gone → status=missing
- `test_orphan_recovery_entry_already_exists` — source gone, dest exists, entry already in DB → file record deleted, no duplicate entry

### Task 2: Missing file visibility in status command

**Files:**
- Modify: `src/trove/cli.py` (status command)
- Modify: `src/trove/db.py` (query helper if needed)
- Test: `tests/test_cli.py`

**Behavior:**
- `trove status Nature` shows "Missing files: X" if any files have status=missing
- `trove status Nature --missing` lists each missing file: path, error_message
- `trove status Nature --clear-missing` deletes all files with status=missing for that library, with confirmation

**Testing:**
- `test_status_shows_missing_count` — missing files show in status output
- `test_status_missing_flag_lists_files` — --missing lists paths
- `test_status_clear_missing` — --clear-missing removes records
