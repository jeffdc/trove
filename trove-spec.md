# Trove: Photo Deduplication, Organization & Sync Tool

## Specification v2.0

---

## 1. Overview

Trove is a CLI tool that consolidates photos and videos from multiple source directories (local directories, USB drives, NAS volumes) into organized, deduplicated libraries. A library is a named collection of files at a known location — typically a NAS volume but can be any directory. Sources are treated as disposable once their contents are verified in a library.

### 1.1 Design Principles

- **Data safety above all else**: Never delete or overwrite a file without verified confirmation that a byte-identical copy exists in the library. Every destructive operation must be preceded by verification.
- **Provably correct**: All operations must be verifiable. The tool must produce audit logs that prove no data was lost.
- **Idempotent**: The tool can be stopped and re-run at any point without duplicating work or corrupting state.
- **Network-resilient**: All operations over network mounts (SMB/NFS) must handle disconnections, timeouts, and stale caches gracefully.
- **Incremental**: A persistent state database avoids re-scanning and re-hashing files that haven't changed.
- **Atomic state transitions**: Database state updates are wrapped in SQLite transactions. A file's state only advances after its corresponding disk operation is verified.

### 1.2 Non-Goals

- This tool does not manage Apple Photos libraries, Lightroom catalogs, or any photo application databases.
- Apple library package extraction (Photos, iPhoto, Aperture) is out of scope for v1 — provide the extracted directory instead.
- This tool does not perform visual/perceptual duplicate detection (e.g., finding photos that look similar but are different files). It uses content hashing only.
- This tool does not edit, transcode, or modify photo/video content in any way. Files are always copied byte-for-byte.

---

## 2. Architecture

### 2.1 Core Concepts

**Library**: A named, organized collection of photos and videos at a known directory location. Multiple libraries can coexist (e.g., "Family Photos", "Nature Photography", "Sarah's Photos"). Each library is independent. A library's absolute file path is always `library.location / entry.relative_path`.

**Entry**: A file that belongs to a library. Represented by a row in the `entries` table and a file on disk. Entries are permanent records — they represent the organized, deduplicated collection.

**File**: A discovered file from a source being processed. Represented by a row in the `files` table. Files are transient working state — they exist while being scanned and imported, and are cleaned up after.

### 2.2 Pipeline

The tool operates as a three-step pipeline. Each step can be run independently or as part of a full run (`trove run`).

```
1. SCAN     → Discover files from a source, hash them, extract metadata
2. IMPORT   → Deduplicate and promote files into a library
3. COMPLETE → Assert import is done, clean up file records and optionally delete source files
```

A separate `VERIFY` command checks library health independent of the pipeline.

State is tracked in the SQLite database. The pipeline can be interrupted and resumed at any point — file and entry records hold all the state needed to determine what work remains.

### 2.3 State Database

SQLite database stored at a configurable location (default: `~/.trove/state.db`). WAL mode enabled for concurrent read safety. All state transitions use SQLite transactions for atomicity.

#### Schema

```
libraries:
  - id                (integer primary key)
  - name              (text, unique — human-readable label)
  - location          (text — absolute path to library root directory)
  - created_at        (timestamp)

entries:
  - id                (integer primary key)
  - library_id        (integer, FK to libraries)
  - relative_path     (text — path within library root, e.g. "2018/05/15/iPhone_7_Plus/IMG_0042.JPG")
  - file_size         (integer, bytes)
  - md5_hash          (text)
  - capture_date      (text, nullable — best available date, see section 3.1)
  - camera_model      (text, nullable)
  - imported_at       (timestamp)
  - UNIQUE(library_id, relative_path)
  - UNIQUE(library_id, md5_hash)

files:
  - id                (integer primary key)
  - source_path       (text — original absolute path on source)
  - source_type       (text — local | usb)
  - file_size         (integer, bytes)
  - file_modify_date  (text — filesystem modification date)
  - md5_hash          (text, nullable — computed during scan)
  - capture_date      (text, nullable — best available date, see section 3.1)
  - camera_model      (text, nullable)
  - target_path       (text, nullable — computed relative path for import)
  - status            (text — discovered | hashed | imported | duplicate | quarantined)
  - error_message     (text, nullable)
  - discovered_at     (timestamp)
  - hashed_at         (timestamp, nullable)
```

#### Indexes

```
entries: index on (library_id, md5_hash) — fast duplicate lookup during import
entries: index on (library_id, relative_path) — fast path conflict lookup during import
files:   index on (source_path) — fast incremental scan lookup
files:   index on (md5_hash) — fast batch dedup lookup
files:   index on (status) — fast pipeline stage queries
```

### 2.4 Configuration

YAML configuration file with CLI overrides:

```yaml
# trove.yaml
organization:
  structure: "%Y/%m/%d"       # strftime format for directory structure
  include_camera_model: true
  unknown_model_label: "Unknown_Model"

file_types:
  photos:
    - jpg
    - jpeg
    - heic
    - png
    - tiff
    - tif
    - psd
    - gif
    - dng
    - bmp
    - webp
  videos:
    - mov
    - mp4
    - mpg
    - mpeg
    - avi
    - m4v
    - mts
  raw:
    - cr2
    - cr3
    - nef
    - arw
    - orf
    - raf
    - rw2
    - dng
    - srw
    - pef

exclude_patterns:
  - "*.DS_Store"
  - "._*"
  - "Thumbs.db"
  - "*.ini"
  - "*.db"
  - "thumb_*"

network:
  retry_attempts: 3
  retry_delay_seconds: 5
  connection_check_interval: 30
  stale_cache_workaround: true

hashing:
  algorithm: md5
  chunk_size: 8192

logging:
  level: INFO
  file: trove.log
  audit_file: trove_audit.log
```

Libraries are managed via CLI commands, not the config file. Sources are specified as CLI arguments, not in config.

---

## 3. Step Specifications

### 3.1 SCAN

**Purpose**: Discover all files from a source, hash them, and extract metadata into the files table.

**Behavior**:

1. Accept a source path.

2. Walk the source directory recursively:
   a. For each file found:
      - Check extension against configured file_types (case-insensitive)
      - Skip files matching exclude_patterns
      - Skip zero-byte files
      - Normalize the filename (see section 6)
      - Check if file already exists in the files table (by source_path). If so and file_size + file_modify_date are unchanged, skip (incremental mode). If changed, update the existing record.
      - Record source_path, source_type, file_size, file_modify_date
      - Set status = `discovered`

4. Hash each discovered file:
   a. Read file in chunks, compute MD5 hash
   b. Store hash in files table
   c. Set status = `hashed`
   d. Display progress: files hashed / total, estimated time remaining

5. Extract metadata via exiftool (batch mode for efficiency):
   a. Capture date — resolved through fallback chain:
      - `DateTimeOriginal` (preferred)
      - `CreateDate` (fallback 1)
      - `ModifyDate` (fallback 2)
      - File creation date from filesystem (fallback 3, least reliable)
      - If no date available at all: set status = `quarantined`, reason = `no_date`
   b. Camera model — sanitized via the filename normalization function (section 6)
   c. Flag obviously wrong dates (year < 2000, year > current year + 1) — use filesystem date as fallback

6. Compute target relative path for each hashed file:
   - `{date_structure}/{camera_model}/{normalized_filename}`
   - Example: `2018/05/15/iPhone_7_Plus/IMG_0042.JPG`
   - If camera model is unknown: use configured `unknown_model_label`
   - Store as `target_path` on the file record

7. Report summary: total files found, breakdown by type, files skipped (incremental), files quarantined.

**Error handling**:
- Permission denied on a file: log warning, skip file, continue
- Source path does not exist: error, exit
- exiftool not installed: clear error message, exit

### 3.2 IMPORT

**Purpose**: Deduplicate scanned files and promote them into a target library.

**Requires**: A library must exist (created via `trove library create`). Files must be scanned (status = `hashed`).

**Behavior**:

1. Deduplicate within batch:
   a. Group all `hashed` files by md5_hash
   b. For groups with multiple files (same content from multiple sources):
      - Keep one (the first discovered)
      - Mark others as `status = duplicate`
   c. Report: duplicates found within batch, space saved

2. Deduplicate against library:
   a. For each remaining `hashed` file, check if its md5_hash exists in the entries table for the target library
   b. If match found: mark `status = duplicate` (file is already in the library)
   c. Report: duplicates found against library

3. Import each non-duplicate, non-quarantined file:
   a. Resolve path conflicts:
      - Check if an entry already exists at the file's `target_path` in the target library
      - If yes (different content at same path): auto-suffix the filename (`IMG_0042-1.JPG`, `IMG_0042-2.JPG`, ...)
      - Ensure suffix doesn't collide with other existing entries
      - Do not create suffix chains (e.g., `IMG_0042-1-1.JPG`)
   b. Copy file from source to `library.location / target_path`
   c. Verify copy: hash the destination file, compare to source hash
      - If mismatch: delete destination file, log error, retry up to configured retry_attempts
      - If repeated failure: log error, skip file, continue with others
   d. Atomically (SQLite transaction):
      - Create entry record (library_id, relative_path, file_size, md5_hash, capture_date, camera_model)
      - Update file record: status = `imported`

4. Resume handling:
   a. If destination file exists but no entry exists (crash between copy and DB update):
      - Hash the destination file
      - If hash matches source: run the DB transaction (create entry, update status)
      - If hash doesn't match: delete destination, re-copy

5. Network resilience during copy:
   a. Before each file copy, verify destination volume is mounted and writable
   b. If copy fails with I/O error: delete partial file, log error, retry
   c. If volume becomes unavailable: pause, retry at configured intervals, exit gracefully after max retries
   d. After copy, verify by reading and hashing the destination file (not trusting OS cache)

6. Report summary: files imported, duplicates skipped, path conflicts resolved, errors.

### 3.3 COMPLETE

**Purpose**: Assert that all scanned files have been accounted for, then clean up.

**Behavior**:

1. Check all file records from the source:
   a. Every file should be in one of: `imported`, `duplicate`, `quarantined`
   b. If any files are still `discovered` or `hashed`: report them and refuse to complete ("N files have not been imported yet")
   c. For `imported` files: verify the corresponding entry exists in the library
   d. For `duplicate` files: verify a matching hash exists in the library entries

2. Report:
   ```
   === IMPORT COMPLETION REPORT ===
   Source: /Volumes/SD_CARD/DCIM
   Library: Family Photos (/Volumes/photos/family)

   Total files scanned:     1,234
     Imported:                987
     Duplicate (skipped):     240
     Quarantined:               7

   All files accounted for: YES
   ```

3. Offer cleanup options:
   a. Delete file records from the files table (always safe — the entries are the permanent record)
   b. Delete source files from disk (only if all files are accounted for)
   c. Both require explicit user confirmation

**Safety**:
- Never delete source files if any file is unaccounted for
- Never delete source files without explicit user confirmation
- The tool does not delete source directories — only individual files it has tracked

### 3.4 VERIFY

**Purpose**: Check that a library's database records accurately reflect what is on disk. This is independent of the scan/import/complete pipeline.

**Behavior**:

1. Pre-flight:
   a. Verify library location is accessible
   b. Force SMB cache invalidation if on a network volume (read a test file, not just stat)

2. Check entries against disk:
   a. For each entry in the library:
      - Verify file exists at `library.location / entry.relative_path`
      - Verify file size matches entry record
      - Optionally (`--thorough`): hash file and verify against entry's md5_hash
   b. Report missing files, size mismatches, hash mismatches

3. Check disk against entries:
   a. Walk the library directory on disk
   b. For each file found, check if a matching entry exists (by relative path)
   c. Report orphan files (on disk but not in DB)

4. Report:
   ```
   === LIBRARY VERIFICATION REPORT ===
   Library: Family Photos (/Volumes/photos/family)

   Entries in database:     23,456
   Files on disk:           23,458

   Verified OK:             23,450
   Missing from disk:            6  (entry exists, file missing)
   Orphan files:                 8  (file exists, no entry)
   Size mismatch:                0
   Hash mismatch:                0  (--thorough only)

   Status: ISSUES FOUND
   ```

5. Exit codes:
   - 0: Library is healthy — all entries verified, no orphans
   - 1: Issues found — missing files, orphans, or mismatches
   - 2: Library not accessible or other error

---

## 4. CLI Interface

```bash
# Library management
trove library create <name> <location>
trove library list
trove library show <name-or-id>

# Core pipeline
trove scan <source-path> --library <name>    # step 1
trove import --library <name>                 # step 2
trove complete --library <name> [--delete-sources]  # step 3

# All-in-one (runs scan + import + complete)
trove run <source-path> --library <name> [--delete-sources]

# Library health
trove verify --library <name> [--thorough]

# Status and info
trove status                                  # show files table: counts by status
trove status --library <name>                 # show library entry counts, last import, etc.

# Common flags
--dry-run                    # show what would happen without doing it
--verbose / -v               # detailed output
--quiet / -q                 # minimal output (errors only)
--config <path>              # path to trove.yaml (optional)
--progress                   # show progress bars (default when stdout is a terminal)
```

---

## 5. Filename Normalization

All filenames pass through a single normalization function before being used in target paths or written to disk. This function is the sole authority on filename safety.

**Rules**:

1. Unicode normalization: NFC form (composed characters)
2. Replace path-unsafe characters (`/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`) with `_`
3. Replace whitespace (spaces, tabs) with `_`
4. Collapse multiple consecutive underscores to one
5. Strip leading/trailing dots and underscores
6. Preserve the original file extension (including case)
7. If the resulting basename (without extension) is empty, use `unnamed`
8. If the total filename exceeds 200 characters, truncate the basename and append a short hash suffix to ensure uniqueness (e.g., `very_long_name_a1b2c3.JPG`)

Camera model strings are also sanitized through this function before being used as directory names.

---

## 6. Network Resilience

### 7.1 Health Checks

Before any write operation to a network volume:
1. Verify the volume is mounted (`os.path.ismount` or check `/Volumes/`)
2. Verify the volume is writable (create and delete a temp file)
3. Verify the volume is responsive (operation completes within timeout)

### 7.2 SMB-Specific Issues

**Stale cache**: macOS SMB cache can return stale directory listings and file existence results.

Mitigations:
- After writing a file, verify by reading and hashing it (forces actual read from NAS)
- Never trust `os.path.isfile()` alone for verification on network volumes
- For `trove verify --thorough`, hash every file to force real reads

**Silent corruption**: SMB transfers can silently produce corrupt files.

Mitigations:
- Always hash the destination file after copy and compare to source hash
- If mismatch, delete destination and re-copy
- Never assume a transfer succeeded based on file size alone

### 7.3 Connection Loss Recovery

On network disconnect during import:
1. Catch I/O error from write operation
2. Delete partial destination file (if it exists)
3. Enter retry loop: wait `retry_delay_seconds`, check if volume is back
4. After `retry_attempts` failures: save state and exit gracefully
5. On re-run: resume from last completed file (files still at `hashed` status are retried)

### 7.4 USB Drive Handling

USB drives may be ejected during scan or import.

Mitigations:
- Before reading a file from USB, verify the volume is still mounted
- If USB disconnects during scan: save state, exit with clear message
- On re-run after reconnect: incremental scan picks up where it left off

---

## 7. Logging and Audit Trail

### 8.1 Operational Log (`trove.log`)

Standard application log with timestamps and levels (DEBUG, INFO, WARNING, ERROR).

### 8.2 Audit Log (`trove_audit.log`)

Append-only record of every file operation. Each line is a JSON object:

```json
{"timestamp": "...", "operation": "import", "source": "/path/a", "destination": "/path/b", "md5_hash": "abc", "size": 12345, "library": "Family Photos"}
{"timestamp": "...", "operation": "skip_duplicate", "source": "/path/c", "duplicate_of_entry": 42, "md5_hash": "abc", "library": "Family Photos"}
{"timestamp": "...", "operation": "quarantine", "source": "/path/d", "reason": "no_date"}
{"timestamp": "...", "operation": "delete_source", "path": "/path/a", "md5_hash": "abc", "verified_in_library": "Family Photos"}
```

This log is never truncated or rotated during a run. It is the authoritative record of what happened.

---

## 8. Test Cases

### 9.1 Unit Tests

#### File Discovery
- Finds JPG, HEIC, PNG, TIFF, MOV, MP4, RAW files (case-insensitive extensions)
- Skips .DS_Store, ._* files, Thumbs.db, *.ini, *.db
- Skips zero-byte files
- Handles filenames with spaces, unicode characters, special characters
- Handles deeply nested directory structures
- Handles symlinks: follows or skips based on configuration
- Handles read-only files (should be readable for hashing/copying)

#### Metadata Extraction
- Extracts DateTimeOriginal correctly from JPEG
- Extracts DateTimeOriginal correctly from HEIC
- Extracts DateTimeOriginal correctly from RAW (CR2, NEF, ARW)
- Falls back to CreateDate when DateTimeOriginal missing
- Falls back to ModifyDate when CreateDate missing
- Falls back to file creation date when all EXIF dates missing
- Quarantines file when no date is available at all
- Extracts camera Model correctly
- Handles missing camera Model (uses configured unknown label)
- Handles corrupt EXIF data without crashing
- Handles obviously wrong dates (< 2000, > current year + 1) — falls back to filesystem date
- Handles video files (MOV, MP4) metadata extraction
- Batch exiftool invocation processes multiple files

#### Filename Normalization
- Replaces path-unsafe characters with underscore
- Replaces whitespace with underscore
- Collapses multiple consecutive underscores
- Strips leading/trailing dots and underscores
- Preserves file extension and case
- Empty basename becomes "unnamed"
- Long filenames truncated with hash suffix
- Camera model strings sanitized consistently
- Unicode characters normalized to NFC

#### Path Computation
- Generates correct YYYY/MM/DD/Model/filename path
- Generates correct YYYY/MM/Model/filename path (alternative format)
- Preserves original filename (including extension case)
- Handles files with no extension

#### Hashing
- Produces correct MD5 for known test files
- Handles very large files (>4GB) without memory issues
- Handles unreadable files gracefully (permission denied)
- Progress reporting works for large files

#### Deduplication
- Identifies exact duplicates within a batch (same hash)
- Identifies duplicates against existing library entries
- Does not falsely identify different files as duplicates
- Handles the case where all copies are in the same source directory

#### Path Conflict Resolution
- Auto-suffixes when path conflicts with existing entry (different content)
- Suffix doesn't collide with other existing entries
- Does not create suffix chains (e.g., `file-1-1.jpg`)
- No conflict when path matches and content matches (duplicate, not conflict)

### 9.2 Integration Tests

#### Import
- Copies file correctly to local destination
- Copies file correctly to NAS destination (SMB)
- Creates directory structure in library
- Stream hash during copy matches source hash
- Interrupted import (Ctrl+C) leaves state database consistent
- Resumed import skips already-imported files
- Resumed import handles orphan destination files (copy succeeded, DB update didn't)
- Failed copy is retried up to configured retry count
- Partial file from failed copy is deleted before retry
- Progress display shows correct counts and ETA

#### Atomic State Transitions
- Entry creation + file status update happen in single transaction
- Crash between copy and DB update: on resume, orphan file is verified and entry created
- Crash during DB transaction: no partial state (no entry without status update or vice versa)

#### Network Resilience
- Tool detects NAS disconnection during import
- Tool pauses and retries on NAS disconnection
- Tool exits gracefully after max retries exhausted
- State database is consistent after ungraceful exit
- USB source disconnection during scan is handled gracefully
- SMB stale cache does not cause false verification success
- Verification reads actual file content (not cached metadata)

#### Complete
- Reports all files accounted for when import is complete
- Refuses to complete when files are still in `hashed` status
- Deletes file records from files table on confirmation
- Deletes source files on disk only with explicit confirmation
- Does not delete source files if any file is unaccounted for

#### Verify
- Detects missing file on disk (entry exists, file gone)
- Detects orphan file on disk (file exists, no entry)
- Detects size mismatch between entry and file on disk
- `--thorough` detects hash mismatch
- Reports healthy library correctly (no false alarms)
- Handles NAS disconnect during verify gracefully

#### End-to-End
- Full pipeline with two local directories (one subset of the other)
- Full pipeline with mixed sources into same library
- Full pipeline with sources into different libraries
- Incremental: add new source, only new files are processed
- Re-run after complete run: no files imported, fast completion
- Run with --dry-run produces correct plan without side effects

### 8.3 Edge Cases

- Source directory is empty
- Source directory contains only excluded files (.DS_Store, etc.)
- Library location is read-only: clear error message
- Library location has insufficient space: clear error message before starting
- Source and library location are the same path: error, refuse to run
- Two sources contain the exact same directory tree (100% duplicates)
- File is modified between scan and import: detected via hash check
- File is deleted between scan and import: logged as warning, skipped
- Thousands of files with the same name (IMG_0001.JPG from many cameras): correctly differentiated by content
- File with .jpg extension is actually a PNG: handled gracefully (still copied, EXIF extraction may fail gracefully)
- Extremely long filename: truncated with hash suffix
- Circular symlinks in source: detected and skipped
- macOS resource forks (._files) alongside real files: resource forks skipped

### 8.4 Performance Tests

- Scan 50,000 files in under 5 minutes (local SSD)
- Hash 50,000 files (average 5MB each) with reasonable throughput
- Incremental re-scan of 50,000 already-processed files completes in under 1 minute
- State database handles 100,000+ records without performance degradation
- Memory usage stays under 500MB regardless of file count

---

## 9. Future Considerations

These are explicitly out of scope for v1 but should be considered in the architecture:

- **Apple library extraction**: Directly scan .photoslibrary, .aplibrary, .apvault packages and extract originals.
- **Rich UI for conflict resolution**: Interactive comparison of files with similar content but different hashes.
- **Perceptual hashing**: Detect visually similar photos using pHash or similar algorithms.
- **Cloud storage support**: Extend sources to include iCloud Photo Library, Google Photos takeout, Dropbox.
- **Scheduled/continuous sync**: Watch source directories for changes and automatically import to library.
- **Web UI dashboard**: Real-time monitoring of import progress and library browsing.

---

## 10. Dependencies

Required:
- Python 3.10+
- exiftool (`brew install exiftool`) — EXIF metadata extraction
- SQLite3 (built into Python) — state database

Python packages:
- click — CLI framework
- pyyaml — configuration file parsing
- rich — progress bars and formatted output

Optional:
- ImageMagick or `sips` (macOS built-in) — thumbnail generation for future conflict resolution UI

---

## 11. Installation & First Run

```bash
# Install dependencies
brew install exiftool
pip install trove  # or clone repo and install in dev mode

# Create a library
trove library create "Family Photos" /Volumes/photos/family

# Import from a source
trove run /Volumes/SD_CARD/DCIM --library "Family Photos"

# Or step by step
trove scan /Volumes/SD_CARD/DCIM --library "Family Photos"
trove import --library "Family Photos"
trove complete --library "Family Photos" --delete-sources

# Check library health
trove verify --library "Family Photos"
trove verify --library "Family Photos" --thorough

# Check status
trove status
trove status --library "Family Photos"
```
