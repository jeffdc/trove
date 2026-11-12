# Photo Intake Algorithm

---

## `trove add <source>` — Import from External Source

Copies files from an external directory into the library.

### 1. Discover files in source

Walk source directory recursively. For each file:
- Filter by extension (config `file_types`: photos, videos, raw)
- Skip: symlinks, zero-byte files, exclude_patterns (`*.DS_Store`, `._*`, `Thumbs.db`, etc.), duplicate inodes
- Stat each file → absolute path, size, mtime (ISO 8601 UTC)

**DB:** For each file, INSERT into `files` with `status=discovered`. If file already exists in DB unchanged, skip. If changed, reset to `status=discovered` (clear hash/metadata/target). Per-file commit.

### 2. Hash files

For each discovered file, read in 8KB chunks, compute MD5.
- Success → UPDATE `status=hashed`, set `md5_hash`, `hashed_at`
- Failure (missing/unreadable) → UPDATE `status=quarantined`, `error_message=hash_failed`

Per-file commit.

### 3. Extract metadata

Call exiftool (chunked batch) on all hashed files. Parse `capture_date` and `camera_model`.
- Valid date found → UPDATE `capture_date`, `camera_model`
- No EXIF date → fall back to file mtime if year in [1990, now+1]
- No valid date at all → UPDATE `status=quarantined`, `error_message=no_date`

Per-file commit.

### 4. Compute target paths

For each file with valid capture_date:
1. Format date with `config.organization.structure` (default `%Y/%m`)
2. Normalize filename (lowercase, safe chars)
3. If `include_camera_model`: add camera model directory segment
4. Example: `2024/01/photo.jpg` or `2024/01/canon_eos_r5/photo.jpg`

UPDATE `target_path`. Per-file commit.

### 5. Resume recovery

Pick up incomplete work from a prior crashed run of `add` against the same source:
1. Build source_prefix from current source path
2. Query `status=discovered` files matching prefix → re-run steps 2-4
3. Query `status=hashed` files matching prefix missing capture_date → re-run steps 3-4
4. Merge recovered IDs into current batch

Source prefix prevents cross-run contamination.

### 6. Classify (deduplication planning)

**Batch dedup:** Group files by md5_hash. Keep first by ID, rest become `duplicates_in_batch`.

**Library dedup:** For each keeper:
1. Query entries by file_size
2. No size match → unique → `to_import`
3. Size match → compare hashes (lazy-hash existing library entries on demand, UPDATE `entry.md5_hash`)
4. Hash match → `duplicates_in_library`; no match → `to_import`

**Path conflict count:** For each `to_import` file, check if entry exists at (library_id, target_path). Count only, no DB writes.

Output: `ImportPlan(to_import, duplicates_in_batch, duplicates_in_library, path_conflicts, skipped)`

### 7. Execute import

**Mark duplicates:** UPDATE `status=duplicate` for all batch and library dups. Per-file commit.

**For each file in `to_import`:**

1. **Validate** — target_path and md5_hash must be set
2. **Resolve path conflicts** — if entry already exists at target_path in DB, suffix filename (`photo-1.jpg`, ..., up to 10000)
3. **Orphan recovery** — if file already exists at destination on disk:
   - Hash it. If matches source → skip copy (orphan from prior crash)
   - If different → suffix to avoid collision
4. **Copy** via `_copy_and_verify()`:
   - Create parent dirs
   - Stream copy in 8KB chunks while computing MD5
   - Verify hash matches expected
   - On mismatch or error: delete partial file, retry once, then skip with error count
5. **Atomic DB write** via `db.import_file()` in single transaction:
   - INSERT into `entries` (library_id, relative_path, file_size, md5_hash, capture_date, camera_model, imported_at, original_path)
   - UPDATE `files` set `status=imported`
   - COMMIT (ROLLBACK on any failure)

### 8. Auto-complete

Delete processed `files` records (imported, duplicate, quarantined) from files table.

---

## `trove library init` — Organize In-Place

Organizes files already in the library location. Moves them to computed paths and indexes them.

### 1. Discover files in library

Same walk as `add`, but scans the library location. Skips files that already have entries in the DB (by path).

**DB:** Same as `add` step 1 — INSERT into `files` with `status=discovered`. Per-file commit.

### 2. Hash files

Same as `add` step 2. MD5 in 8KB chunks. Per-file commit.

### 3. Extract metadata

Same as `add` step 3. Exiftool batch, fallback to mtime. Per-file commit.

### 4. Compute target paths

Same as `add` step 4. Per-file commit.

### 5. Resume recovery

Same pattern as `add` — query stale `discovered` and `hashed` files within this library prefix, re-run pipeline steps.

### 6. Classify for init

Compare each file's current relative_path to its computed target_path:

| Condition | Action assigned |
|-----------|----------------|
| Paths match | `index` — file already in correct location |
| Paths differ | `move` — file needs to be relocated |
| Quarantined (no date) | `quarantine` — move to quarantine dir |

Output: `InitializePlan(already_correct, needs_move, duplicates, quarantined)`

### 7. Execute init

**Signal handling:** SIGINT/SIGTERM handlers installed. Graceful stop between files. Checks mount health.

**For `already_correct` files:**
- INSERT into `entries` (null md5_hash — file didn't move, no verification). COMMIT.

**For `needs_move` files:**
1. `move_file()`: try `os.rename()` (atomic same-filesystem); if cross-device: copy+verify then delete source
2. INSERT into `entries` with `original_path` set to source location. COMMIT.
3. On entry creation failure: move file back to original location
4. Clean up empty parent directories

**For duplicates and quarantined:** similar move + entry creation.

**Cleanup:** DELETE processed file records from `files` table. Per-file commit.

---

## Database Schema

### files (transient — working state during intake)

```
id              INTEGER PRIMARY KEY
source_path     TEXT NOT NULL          -- absolute path to source file
source_type     TEXT NOT NULL          -- "local"
file_size       INTEGER NOT NULL
file_modify_date TEXT NOT NULL         -- ISO 8601 UTC
md5_hash        TEXT                   -- NULL until hashed
capture_date    TEXT                   -- NULL until metadata extracted
camera_model    TEXT                   -- NULL until metadata extracted
target_path     TEXT                   -- NULL until path computed
status          TEXT NOT NULL          -- state machine value
error_message   TEXT                   -- quarantine reason
discovered_at   TEXT NOT NULL          -- ISO 8601 UTC
hashed_at       TEXT                   -- ISO 8601 UTC
```

### entries (permanent library catalog)

```
id              INTEGER PRIMARY KEY
library_id      INTEGER NOT NULL       -- FK to libraries
relative_path   TEXT NOT NULL          -- path within library
file_size       INTEGER NOT NULL
md5_hash        TEXT                   -- NULL if file never moved during init
capture_date    TEXT
camera_model    TEXT
imported_at     TEXT NOT NULL          -- ISO 8601 UTC
original_path   TEXT                   -- source path if different
UNIQUE(library_id, relative_path)
```

### libraries

```
id              INTEGER PRIMARY KEY
name            TEXT UNIQUE NOT NULL
location        TEXT NOT NULL          -- absolute path
config          TEXT NOT NULL          -- JSON LibraryConfig
created_at      TEXT NOT NULL          -- ISO 8601 UTC
```

---

## File Status State Machine

```
discovered ──→ hashed ──→ [metadata + path ready]
    │              │              │
    │              │              ├──→ imported (add) ──→ [deleted from files]
    │              │              ├──→ duplicate       ──→ [deleted from files]
    │              │              └──→ quarantined     ──→ [deleted from files]
    │              │
    │              └──→ quarantined (no_date)
    │
    └──→ quarantined (hash_failed)
```

---

## Transaction Boundaries

| Operation | Scope | On failure |
|-----------|-------|------------|
| Discovery | Per-file commit | Next file continues |
| Hashing | Per-file commit | Mark quarantined, continue |
| Metadata | Per-file commit | Mark quarantined, continue |
| Path compute | Per-file commit | — |
| Mark duplicates | Per-file commit | — |
| Import file (add) | Transaction: INSERT entry + UPDATE file | ROLLBACK, copied file may remain on disk |
| Create entry (init) | Per-file commit | Move file back if it was moved |
| Cleanup | Per-file commit | — |

---

## Configuration Affecting Flow

```
organization.structure            -- strftime format, default "%Y/%m"
organization.include_camera_model -- bool, adds camera dir segment
organization.unknown_model_label  -- label when camera model unknown
file_types                        -- extension lists (photos, videos, raw)
exclude_patterns                  -- fnmatch skip patterns
quarantine.path                   -- destination for undated files
```
