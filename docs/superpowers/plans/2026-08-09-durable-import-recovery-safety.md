# Durable Import Recovery and Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make interrupted imports durably resumable, explicitly failed, run-scoped, non-destructive, and non-zero on failure while enforcing explicit authorization around every destructive Trove command.

**Architecture:** Add durable `import_runs` records and attach transient file records to one run. Pipeline, execution, completion, and CLI orchestration operate by run ID instead of global status or raw path prefixes. Copy primitives become strictly additive through exclusive destination creation and preservation of failed copies; existing destructive initialize/maintenance operations retain explicit command, flag, or plan authorization.

**Tech Stack:** Python 3.14 development environment with Python 3.10+ typing, SQLite migrations/transactions, Click/CliRunner, pytest/unittest.mock, Ruff, and MyPy.

## Global Constraints

- Do not run the installed `trove` executable or access the default database, mounted photo library, or user source directories.
- Every test must use `tmp_path`, temporary SQLite databases, and Click’s isolated runner fixtures.
- External copy import never deletes source files and never overwrites or deletes an existing destination object.
- A permanent entry is created only after the destination bytes match the expected MD5.
- A specific destructive command/flag or approval of a displayed plan is required before moving/deleting user filesystem objects or permanent library records.
- Transient rows may be cleaned automatically only after their own run is verified complete.
- Selecting Abort never deletes, resets, or transitions existing run/file state; pending cache created by discovery remains resumable.
- Expected timeout output is concise and contains no traceback.
- Preserve existing immutable frozen-dataclass conventions, plan/execute separation, Ruff line length 120, and MyPy Python 3.10 compatibility.
- Stage and commit only the files named in each task; never use `git add .` or `git add -A`.

---

## File Structure

- `src/trove/db.py` — schema migration, immutable run record, run/file queries, and atomic failure/completion transactions.
- `src/trove/plan.py` — typed import execution result and run-aware completion plan data.
- `src/trove/pipeline.py` — run-aware discovery plus non-destructive copy helper behavior.
- `src/trove/timeout.py` — exclusive destination file creation.
- `src/trove/importer.py` — persist file/run failure and return typed execution outcome.
- `src/trove/complete.py` — run-scoped completion and cleanup only.
- `src/trove/initialize.py` — initialize-run association, failure persistence, and completion.
- `src/trove/cli.py` — canonical source identity, Resume/Abort flow, non-zero failure exit, run lifecycle, and collision-free generated reports.
- `tests/test_db.py` — schema, migration, active-run uniqueness, and atomic transaction contracts.
- `tests/test_pipeline.py` — run association, exclusive create, and failed-copy preservation.
- `tests/test_importer.py` — timeout/ordinary failure persistence, orphan adoption, and typed results.
- `tests/test_complete.py` — run-scoped blocking and cleanup isolation.
- `tests/test_cli.py` — end-to-end failed/resume/abort behavior and destructive authorization gates.
- `tests/test_initialize.py` — durable initialize failure/resume behavior.
- `tests/test_report.py` — collision-free fixed generated output.

---

### Task 1: Durable Run Schema and Atomic State API

**Files:**
- Modify: `src/trove/db.py:20-140,172-197,537-754`
- Test: `tests/test_db.py:1-184,600-658`

**Interfaces:**
- Produces: frozen `ImportRunRecord` with `id`, `library_id`, `source_root`, `mode`, `status`, `last_error`, `failed_at`, `created_at`, `updated_at`, and `completed_at`.
- Produces: `StateDB.create_import_run(library_id: int, source_root: str, mode: str) -> ImportRunRecord`.
- Produces: `StateDB.get_import_run(run_id: int) -> ImportRunRecord | None`.
- Produces: `StateDB.get_active_import_run(library_id: int, source_root: str, mode: str) -> ImportRunRecord | None`.
- Produces: `StateDB.update_import_run(run_id: int, *, status: str) -> None`.
- Produces: `StateDB.resume_import_run(run_id: int) -> None`, atomically changing `failed` files back to `hashed`, clearing their file errors, and setting the run `running` without clearing run failure history.
- Produces: `StateDB.mark_import_failed(run_id: int, file_id: int, error_message: str) -> None`, atomically marking both rows failed.
- Produces: `StateDB.query_files_by_run(run_id: int, statuses: tuple[str, ...] | None = None) -> list[FileRecord]`.
- Produces: `StateDB.attach_files_to_run(file_ids: list[int], run_id: int) -> None`.
- Produces: `StateDB.complete_import_run(run_id: int, file_ids: list[int]) -> None`, atomically deleting only listed transient rows and marking the run completed.
- Changes: `FileRecord.import_run_id: int | None = None` and `StateDB.insert_file(source_path: str, source_type: str, file_size: int, file_modify_date: str, import_run_id: int | None = None) -> FileRecord`.

- [ ] **Step 1: Add failing schema and lifecycle tests**

Add tests that require the new table/column, one-active-run invariant, run-scoped file queries, failure atomicity, resume behavior, and completion isolation:

```python
from pathlib import Path


def test_import_run_schema_and_file_link(db):
    tables = {row[0] for row in db._conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert "import_runs" in tables
    file_cols = {row[1] for row in db._conn.execute("PRAGMA table_info(files)")}
    assert "import_run_id" in file_cols


def test_active_run_is_unique_and_completed_run_allows_successor(db, library, tmp_path):
    source = str((tmp_path / "source").resolve())
    first = db.create_import_run(library.id, source, "copy")
    with pytest.raises(sqlite3.IntegrityError):
        db.create_import_run(library.id, source, "copy")
    db.complete_import_run(first.id, [])
    second = db.create_import_run(library.id, source, "copy")
    assert second.id != first.id


def test_failure_resume_and_completion_are_run_scoped(db, library, tmp_path):
    source_a = str((tmp_path / "a").resolve())
    source_b = str((tmp_path / "b").resolve())
    run_a = db.create_import_run(library.id, source_a, "copy")
    run_b = db.create_import_run(library.id, source_b, "copy")
    file_a = db.insert_file(f"{source_a}/a.jpg", "local", 1, "mtime", import_run_id=run_a.id)
    file_b = db.insert_file(f"{source_b}/b.jpg", "local", 1, "mtime", import_run_id=run_b.id)
    db.update_file(file_a.id, status="hashed", md5_hash="a")
    db.update_file(file_b.id, status="hashed", md5_hash="b")

    db.mark_import_failed(run_a.id, file_a.id, "import_timeout:destination_check:/library/a.jpg")
    assert db.get_import_run(run_a.id).status == "failed"
    assert db.get_file_by_path(file_a.source_path).status == "failed"
    assert db.get_file_by_path(file_b.source_path).status == "hashed"

    db.resume_import_run(run_a.id)
    assert db.get_import_run(run_a.id).status == "running"
    assert db.get_file_by_path(file_a.source_path).status == "hashed"
    db.complete_import_run(run_a.id, [file_a.id])
    assert db.get_file_by_path(file_a.source_path) is None
    assert db.get_file_by_path(file_b.source_path) is not None
```

Also create a legacy version-3 database directly with SQLite, open it through `StateDB`, and assert migration 4 preserves its existing library, entry, and file rows while adding nullable `import_run_id`.

Use an explicit version-3 fixture rather than editing the default database:

```python
def test_migrates_version_three_database_without_losing_rows(tmp_path):
    path = tmp_path / "legacy.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE schema_version (version INTEGER NOT NULL);
        INSERT INTO schema_version VALUES (3);
        CREATE TABLE libraries (
            id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, location TEXT NOT NULL,
            config TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL
        );
        CREATE TABLE files (
            id INTEGER PRIMARY KEY, source_path TEXT NOT NULL, source_type TEXT NOT NULL,
            file_size INTEGER NOT NULL, file_modify_date TEXT NOT NULL, md5_hash TEXT,
            capture_date TEXT, camera_model TEXT, target_path TEXT, status TEXT NOT NULL,
            error_message TEXT, discovered_at TEXT NOT NULL, hashed_at TEXT
        );
        INSERT INTO libraries VALUES (1, 'Legacy', '/legacy', '{}', 'created');
        INSERT INTO files VALUES (
            1, '/source/a.jpg', 'local', 1, 'mtime', 'hash', NULL, NULL, NULL,
            'hashed', NULL, 'discovered', 'hashed-at'
        );
        """
    )
    conn.close()

    with StateDB(path) as migrated:
        assert migrated.get_library("Legacy") is not None
        record = migrated.get_file_by_path("/source/a.jpg")
        assert record is not None
        assert record.import_run_id is None
```

- [ ] **Step 2: Run the database tests and verify the new contracts fail**

Run: `.venv/bin/python -m pytest tests/test_db.py -v`

Expected: FAIL because `import_runs`, `FileRecord.import_run_id`, and run lifecycle methods do not exist.

- [ ] **Step 3: Implement migration 4 and immutable row mapping**

Add the record and schema definitions:

```python
@dataclass(frozen=True)
class ImportRunRecord:
    id: int
    library_id: int
    source_root: str
    mode: str
    status: str
    last_error: str | None
    failed_at: str | None
    created_at: str
    updated_at: str
    completed_at: str | None


@dataclass(frozen=True)
class FileRecord:
    id: int
    source_path: str
    source_type: str
    file_size: int
    file_modify_date: str
    status: str
    discovered_at: str
    md5_hash: str | None = None
    capture_date: str | None = None
    camera_model: str | None = None
    target_path: str | None = None
    error_message: str | None = None
    hashed_at: str | None = None
    import_run_id: int | None = None
```

Set `_SCHEMA_VERSION = 4`. Migration 4 must create `import_runs`, add `files.import_run_id REFERENCES import_runs(id) ON DELETE CASCADE`, add run/status indexes, and add a partial unique index:

```sql
CREATE UNIQUE INDEX idx_import_runs_active
ON import_runs(library_id, source_root, mode)
WHERE status != 'completed';
```

Include the same final schema in `_CREATE_TABLES` so fresh databases start at version 4. Update every `files` SELECT and `FileRecord` constructor to include `import_run_id`; keep `insert_file` backward compatible only through its optional keyword default, not through a second API.

- [ ] **Step 4: Implement run APIs with explicit transactions**

Validate mode/status values in Python. Implement failure and completion as single transactions:

```python
def mark_import_failed(self, run_id: int, file_id: int, error_message: str) -> None:
    now = _now()
    try:
        self._conn.execute("BEGIN")
        self._conn.execute(
            "UPDATE files SET status = 'failed', error_message = ? "
            "WHERE id = ? AND import_run_id = ?",
            (error_message, file_id, run_id),
        )
        self._conn.execute(
            "UPDATE import_runs SET status = 'failed', last_error = ?, "
            "failed_at = ?, updated_at = ? WHERE id = ?",
            (error_message, now, now, run_id),
        )
        self._conn.execute("COMMIT")
    except Exception:
        self._conn.execute("ROLLBACK")
        raise
```

`complete_import_run` must verify every requested file belongs to the run before deletion, delete only those IDs, update the run, and commit once. `resume_import_run` must preserve `last_error`/`failed_at` on the run for history.

- [ ] **Step 5: Run database tests**

Run: `.venv/bin/python -m pytest tests/test_db.py -v`

Expected: PASS, including migration preservation and cross-run isolation.

- [ ] **Step 6: Commit durable state**

```bash
git add src/trove/db.py tests/test_db.py
git commit -m "Add durable import run state"
```

---

### Task 2: Run-Aware Discovery and Completion

**Files:**
- Modify: `src/trove/pipeline.py:42-138`
- Modify: `src/trove/complete.py:15-124`
- Modify: `src/trove/plan.py:69-84`
- Test: `tests/test_pipeline.py:1-145`
- Test: `tests/test_complete.py:1-210`

**Interfaces:**
- Consumes: Task 1 run/file APIs.
- Changes: `discover_and_persist(source_path: Path, db: StateDB, config: LibraryConfig, skip_paths: set[str] | None = None, known_paths: list[Path] | None = None, progress: Progress | None = None, limit: int | None = None, import_run_id: int | None = None) -> tuple[list[int], int]` stores canonical absolute source paths and associates new/reset records with the run.
- Changes: `plan_complete(db: StateDB, library: LibraryRecord, run_id: int) -> CompletePlan`.
- Changes: `execute_complete(db: StateDB, library: LibraryRecord, run_id: int, plan: CompletePlan) -> CompleteResult`.
- Changes: `complete_import(db: StateDB, library: LibraryRecord, run_id: int) -> CompleteResult`.
- Produces: `CompletePlan.terminal_file_ids` containing only verified/accounted IDs for this run.

Add the field to the existing frozen plan:

```python
@dataclass(frozen=True)
class CompletePlan:
    imported: list[FileRecord] = field(default_factory=list)
    duplicate: list[FileRecord] = field(default_factory=list)
    quarantined: list[FileRecord] = field(default_factory=list)
    unaccounted: list[FileRecord] = field(default_factory=list)
    terminal_file_ids: list[int] = field(default_factory=list)
```

- [ ] **Step 1: Add failing discovery and completion tests**

Add a discovery test proving relative and absolute spellings persist the same canonical path and run ID:

```python
def test_discovery_canonicalizes_paths_and_associates_run(db, library, tmp_path, monkeypatch):
    source = tmp_path / "source"
    source.mkdir()
    photo = source / "photo.jpg"
    photo.write_bytes(b"content")
    run = db.create_import_run(library.id, str(source.resolve()), "copy")
    monkeypatch.chdir(source)

    ids, _ = discover_and_persist(Path("."), db, LibraryConfig(), import_run_id=run.id)

    record = db.query_files_by_ids(ids)[0]
    assert record.source_path == str(photo.resolve())
    assert record.import_run_id == run.id
```

Add completion tests with two runs and a `failed` record. Assert `plan_complete` sees only its run, failed state blocks completion, and `execute_complete` deletes only `plan.terminal_file_ids` while preserving the other run.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `.venv/bin/python -m pytest tests/test_pipeline.py tests/test_complete.py -v`

Expected: FAIL because discovery does not accept a run ID/canonicalize paths and completion is global.

- [ ] **Step 3: Make discovery canonical and run-aware**

Resolve the root once and normalize both scanned and `known_paths` inputs:

```python
source_root = source_path.resolve()
# Discovery receives source_root, and each persisted path is path.resolve().
```

Pass `import_run_id` to `insert_file`. When an existing record is changed, reset its derived fields and attach it only when its current `import_run_id` is `None` or equals the requested run. If a non-null different run owns the path, raise a clear `RuntimeError` rather than silently stealing state.

- [ ] **Step 4: Make completion run-scoped**

Query `db.query_files_by_run(run_id)` once. Classify `imported`, `duplicate`, and `quarantined` as terminal; classify `failed`, `discovered`, `hashed`, `missing`, and unknown non-terminal statuses as unaccounted. Verify imported hashes against entries in the supplied library. Populate `terminal_file_ids` from only verified terminal rows.

Replace `delete_files_by_status` with:

```python
db.complete_import_run(run_id, plan.terminal_file_ids)
```

Reject `execute_complete` when `plan.can_complete` is false.

- [ ] **Step 5: Run focused tests**

Run: `.venv/bin/python -m pytest tests/test_pipeline.py tests/test_complete.py -v`

Expected: PASS; no completion test observes deletion outside its run.

- [ ] **Step 6: Commit run-scoped pipeline state**

```bash
git add src/trove/pipeline.py src/trove/complete.py src/trove/plan.py tests/test_pipeline.py tests/test_complete.py
git commit -m "Scope discovery and completion to import runs"
```

---

### Task 3: Strictly Non-Destructive Copy Primitives

**Files:**
- Modify: `src/trove/timeout.py:231-247`
- Modify: `src/trove/pipeline.py:498-537`
- Test: `tests/test_timeout.py`
- Test: `tests/test_pipeline.py:760-920`

**Interfaces:**
- Changes: `copy_file_and_hash` creates destinations with exclusive mode and raises `FileExistsError` if another object already exists.
- Changes: `_copy_and_verify` never unlinks a destination after mismatch, timeout, or `OSError`.
- Preserves: `_copy_and_verify(source, dest, expected_hash, chunk_size=8192) -> bool`.

- [ ] **Step 1: Add failing exclusive-create and preservation tests**

```python
def test_copy_file_and_hash_never_overwrites_existing_destination(tmp_path):
    source = tmp_path / "source.jpg"
    dest = tmp_path / "dest.jpg"
    source.write_bytes(b"new")
    dest.write_bytes(b"existing")

    with pytest.raises(FileExistsError):
        copy_file_and_hash(str(source), str(dest))

    assert dest.read_bytes() == b"existing"


def test_copy_verify_mismatch_preserves_created_destination(tmp_path):
    source = tmp_path / "source.jpg"
    dest = tmp_path / "dest.jpg"
    source.write_bytes(b"source")

    assert _copy_and_verify(source, dest, "not-the-real-hash") is False
    assert source.read_bytes() == b"source"
    assert dest.read_bytes() == b"source"
```

Add an `OSError` test whose fake copy creates partial bytes and then raises; assert both source and partial destination remain.

- [ ] **Step 2: Run focused copy tests and verify failure**

Run: `.venv/bin/python -m pytest tests/test_timeout.py tests/test_pipeline.py -k "copy or overwrite or mismatch" -v`

Expected: FAIL because destination uses `"wb"` and mismatch/error cleanup unlinks it.

- [ ] **Step 3: Use exclusive creation and remove destination deletion**

Change the worker primitive to:

```python
hasher = hashlib.md5()
src_stat = os.stat(source_str)
with open(source_str, "rb") as src_f, open(dest_str, "xb") as dst_f:
    while True:
        chunk = src_f.read(chunk_size)
        if not chunk:
            break
        dst_f.write(chunk)
        hasher.update(chunk)
os.utime(dest_str, ns=(src_stat.st_atime_ns, src_stat.st_mtime_ns))
return hasher.hexdigest()
```

Remove both `unlink_path(dest, ...)` cleanup blocks from `_copy_and_verify`. Keep source preservation and return `False` for hash mismatch/ordinary `OSError`; continue to re-raise `TimeoutError`.

- [ ] **Step 4: Run focused copy tests**

Run: `.venv/bin/python -m pytest tests/test_timeout.py tests/test_pipeline.py -k "copy or overwrite or mismatch" -v`

Expected: PASS; every asserted pre-existing/partial destination remains byte-for-byte unchanged.

- [ ] **Step 5: Commit non-destructive copy behavior**

```bash
git add src/trove/timeout.py src/trove/pipeline.py tests/test_timeout.py tests/test_pipeline.py
git commit -m "Prevent import copy deletion and overwrite"
```

---

### Task 4: Import Executor Failure Semantics

**Files:**
- Modify: `src/trove/plan.py:51-67`
- Modify: `src/trove/importer.py:25-225`
- Test: `tests/test_importer.py`

**Interfaces:**
- Consumes: Task 1 `mark_import_failed`; Task 3 non-destructive copy.
- Produces: frozen `ImportResult` with integer counters plus `timed_out: bool`, `failed_file: str | None`, `failure_message: str | None`, and `succeeded` property.
- Changes: `execute_import(db: StateDB, library: LibraryRecord, config: LibraryConfig, plan: ImportPlan, run_id: int, audit: AuditLogger | None = None, progress: Progress | None = None) -> ImportResult`.
- Changes: `plan_import(db: StateDB, library: LibraryRecord, config: LibraryConfig, run_id: int, progress: Progress | None = None) -> ImportPlan`, classifying only `query_files_by_run(run_id, ("hashed",))`.
- Changes: `import_to_library(db: StateDB, library: LibraryRecord, config: LibraryConfig, run_id: int, dry_run: bool = False, audit: AuditLogger | None = None, progress: Progress | None = None) -> ImportResult`.

- [ ] **Step 1: Add failing typed-result and failure-state tests**

Create a run-backed helper in `tests/test_importer.py`, then add:

```python
def test_timeout_marks_file_and_run_failed_without_entry(db, library, tmp_path):
    run, file_record = _ready_run_file(db, library, tmp_path)
    plan = plan_import(db, library, LibraryConfig(), run.id)

    with patch("trove.importer.run_with_timeout", side_effect=TimeoutError("dead mount")):
        result = execute_import(db, library, LibraryConfig(), plan, run.id)

    assert result.succeeded is False
    assert result.timed_out is True
    assert result.failed_file == file_record.source_path
    assert db.get_import_run(run.id).status == "failed"
    assert db.get_file_by_path(file_record.source_path).status == "failed"
    assert db.list_entries(library.id) == []
    assert Path(file_record.source_path).exists()


def test_verification_failure_preserves_partial_and_marks_failed(db, library, tmp_path):
    run, file_record = _ready_run_file(db, library, tmp_path)
    plan = plan_import(db, library, LibraryConfig(), run.id)
    with patch("trove.importer._copy_and_verify", return_value=False):
        result = execute_import(db, library, LibraryConfig(), plan, run.id)
    assert result.errors == 1
    assert db.get_import_run(run.id).status == "failed"
    assert db.get_file_by_path(file_record.source_path).error_message.startswith("copy_verification_failed:")
```

Update existing summary assertions from mapping syntax to `ImportResult` attributes.

- [ ] **Step 2: Run importer tests and verify failure**

Run: `.venv/bin/python -m pytest tests/test_importer.py -v`

Expected: FAIL because execution has no run ID, typed result, or persisted failure state.

- [ ] **Step 3: Add `ImportResult` and run-scoped planning**

Define in `plan.py`:

```python
@dataclass(frozen=True)
class ImportResult:
    imported: int = 0
    duplicates_in_batch: int = 0
    duplicates_in_library: int = 0
    path_conflicts: int = 0
    skipped: int = 0
    errors: int = 0
    timed_out: bool = False
    failed_file: str | None = None
    failure_message: str | None = None

    @property
    def succeeded(self) -> bool:
        return self.errors == 0
```

Build the final immutable result from local counters. Dry-run returns an `ImportResult` without mutation.

- [ ] **Step 4: Persist precise executor failures**

Track the current stage before each risky destination operation (`destination_check`, `destination_hash`, `copy`, `creation_date`). On timeout, create:

```python
failure_message = f"import_timeout:{stage}:{dest_path}"
db.mark_import_failed(run_id, file_rec.id, failure_message)
```

Stop immediately after a timeout. For exhausted copy verification or ordinary exceptions, mark that file/run failed with a stable reason, preserve all filesystem objects, and continue only under the current non-timeout behavior. Do not log expected timeout with `logger.exception`; use a concise warning/error without traceback.

Only call `db.import_file` after copy/orphan hash verification succeeds.

- [ ] **Step 5: Run importer tests**

Run: `.venv/bin/python -m pytest tests/test_importer.py -v`

Expected: PASS, including existing dedup/orphan/path-conflict behavior and new persisted failures.

- [ ] **Step 6: Commit executor failure handling**

```bash
git add src/trove/plan.py src/trove/importer.py tests/test_importer.py
git commit -m "Persist resumable import failures"
```

---

### Task 5: Copy-Mode Run Orchestration and Resume UI

**Files:**
- Modify: `src/trove/cli.py:407-476,582-788`
- Test: `tests/test_cli.py:190-410,792-999`

**Interfaces:**
- Consumes: Tasks 1–4 run, discovery, completion, and import APIs.
- Produces: `_get_or_create_copy_run(db: StateDB, lib: LibraryRecord, source_root: Path, yes: bool) -> ImportRunRecord | None`; `None` means explicit Abort.
- Changes: `_add_copy_mode(ctx: click.Context, db: StateDB, lib: LibraryRecord, config: LibraryConfig, source_path: str, yes: bool) -> None` receives/stores a canonical absolute source.
- Behavior: matching pending/failed runs offer `[r]esume or [a]bort`; `--yes` resumes; failures call `ctx.exit(1)` after progress closes.

- [ ] **Step 1: Add failing CLI recovery tests**

Use only temporary DB/source/library fixtures and `runner.invoke`. Add separate tests for:

```python
from datetime import datetime, timezone

@patch("trove.pipeline.extract_metadata_chunked")
def test_relative_dot_timeout_is_failed_and_resumable(mock_meta, runner, db_path, tmp_path, monkeypatch):
    lib_dir = tmp_path / "library"
    lib_dir.mkdir()
    source = tmp_path / "source"
    source.mkdir()
    photo = source / "photo.jpg"
    photo.write_bytes(b"photo content")
    mock_meta.return_value = {
        str(photo.resolve()): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
    }
    runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
    monkeypatch.chdir(source)

    with patch("trove.importer._copy_and_verify", side_effect=TimeoutError("dead mount")):
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", ".", "--yes"])

    assert result.exit_code != 0
    assert "Import stopped" in result.output
    assert "can be resumed" in result.output
    assert "Traceback" not in result.output
    assert photo.read_bytes() == b"photo content"
    with StateDB(db_path) as db:
        lib = db.get_library("Photos")
        run = db.get_active_import_run(lib.id, str(source.resolve()), "copy")
        assert run is not None
        assert run.status == "failed"
        records = db.query_files_by_run(run.id)
        assert [record.status for record in records] == ["failed"]
        assert db.list_entries(lib.id) == []


def test_resume_abort_preserves_database_and_files(runner, db_path, tmp_path):
    lib_dir = tmp_path / "library"
    lib_dir.mkdir()
    source = tmp_path / "source"
    source.mkdir()
    photo = source / "photo.jpg"
    photo.write_bytes(b"photo content")
    with StateDB(db_path) as db:
        lib = db.create_library("Photos", str(lib_dir))
        run = db.create_import_run(lib.id, str(source.resolve()), "copy")
        mtime = datetime.fromtimestamp(photo.stat().st_mtime, tz=timezone.utc).isoformat()
        record = db.insert_file(
            str(photo.resolve()), "local", len(b"photo content"), mtime, import_run_id=run.id
        )
        db.update_file(
            record.id,
            status="hashed",
            md5_hash=hashlib.md5(b"photo content").hexdigest(),
            capture_date="2024-01-15T10:30:00",
            target_path="2024/01/Canon/photo.jpg",
        )
        db.mark_import_failed(run.id, record.id, "import_timeout:copy:destination")
        before_run = db.get_import_run(run.id)
        before_files = db.query_files_by_run(run.id)

    result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source)], input="a\n")

    assert result.exit_code == 0
    assert photo.read_bytes() == b"photo content"
    with StateDB(db_path) as db:
        assert db.get_import_run(run.id) == before_run
        assert db.query_files_by_run(run.id) == before_files


def test_resume_reuses_ready_state_and_completes(runner, db_path, tmp_path):
    lib_dir = tmp_path / "library"
    lib_dir.mkdir()
    source = tmp_path / "source"
    source.mkdir()
    contents = {"a.jpg": b"a", "b.jpg": b"b"}
    with StateDB(db_path) as db:
        lib = db.create_library("Photos", str(lib_dir))
        run = db.create_import_run(lib.id, str(source.resolve()), "copy")
        records = []
        for name, content in contents.items():
            path = source / name
            path.write_bytes(content)
            mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat()
            record = db.insert_file(str(path.resolve()), "local", len(content), mtime, import_run_id=run.id)
            db.update_file(
                record.id,
                status="hashed",
                md5_hash=hashlib.md5(content).hexdigest(),
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon",
                target_path=f"2024/01/Canon/{name}",
            )
            records.append(record)
        db.mark_import_failed(run.id, records[0].id, "import_timeout:copy:destination")

    with patch("trove.cli.extract_metadata") as extract_metadata_mock:
        result = runner.invoke(
            cli,
            ["--db", str(db_path), "add", "Photos", str(source)],
            input="r\ni\n",
        )

    assert result.exit_code == 0
    extract_metadata_mock.assert_not_called()
    with StateDB(db_path) as db:
        completed = db.get_import_run(run.id)
        assert completed is not None
        assert completed.status == "completed"
        assert len(db.list_entries(lib.id)) == 2
        assert db.query_files_by_run(run.id) == []
```

Add cross-source and cross-library tests proving one resumed/completed run leaves the other active run untouched. Add a duplicate-only run test proving duplicate statuses are persisted and completed rather than globally deleted.

- [ ] **Step 2: Run CLI recovery tests and verify failure**

Run: `.venv/bin/python -m pytest tests/test_cli.py -k "resume or timeout or accounted or duplicate" -v`

Expected: FAIL because current CLI uses raw prefixes, global cleanup, successful failure exits, and no Resume/Abort run prompt.

- [ ] **Step 3: Canonicalize source and implement active-run selection**

In `add`, resolve the external source once and pass `str(resolved_source)` to copy mode. Implement active-run handling:

```python
run = db.get_active_import_run(lib.id, str(source_root), "copy")
if run is not None:
    if not yes:
        click.echo(_format_resume_summary(db, run))
        choice = click.prompt(
            "[r]esume or [a]bort",
            type=click.Choice(["r", "a"], case_sensitive=False),
        )
        if choice.lower() == "a":
            click.echo("Aborted. Pending import state was preserved.")
            return None
    db.resume_import_run(run.id)
    return db.get_import_run(run.id)
return db.create_import_run(lib.id, str(source_root), "copy")
```

A newly created run remains `pending` until the user selects Import. Interactive Abort from the analysis menu leaves it pending and removes both global `delete_files_by_status` calls.

- [ ] **Step 4: Replace prefix recovery with run-state routing**

Route records from `db.query_files_by_run(run.id)`:

- `discovered` → hash;
- `hashed` without metadata → extract;
- `hashed` with metadata and no target → compute path;
- ready `hashed` → classify directly;
- `failed` must have been reset to `hashed` only by explicit Resume;
- `duplicate`, `quarantined`, and `imported` remain accounted for completion.

Pass `run.id` into discovery, planning, execution, and completion. Do not use global status queries or raw source prefixes.

- [ ] **Step 5: Implement truthful completion and failure exit**

Execute duplicate-only plans so statuses are persisted. For no-record runs, report no work without touching any other rows. After execution:

```python
if not result.succeeded:
    click.echo(f"Import stopped after {result.imported} verified file(s).", err=True)
    click.echo("Pending state was preserved and can be resumed.", err=True)
    ctx.exit(1)
    return
```

Only run run-scoped completion when `plan_complete(..., run.id).can_complete`. Never print `Done.` after a failed result.

- [ ] **Step 6: Run CLI recovery tests**

Run: `.venv/bin/python -m pytest tests/test_cli.py -k "resume or timeout or accounted or duplicate" -v`

Expected: PASS; Abort snapshots are identical and all failures have non-zero exit codes.

- [ ] **Step 7: Commit copy-mode orchestration**

```bash
git add src/trove/cli.py tests/test_cli.py
git commit -m "Resume failed copy runs safely"
```

---

### Task 6: Durable Initialization Runs

**Files:**
- Modify: `src/trove/initialize.py:73-119,286-465`
- Modify: `src/trove/cli.py:479-579`
- Test: `tests/test_initialize.py`
- Test: `tests/test_cli.py`

**Interfaces:**
- Consumes: Task 1 run APIs and Task 2 run-aware discovery.
- Changes: `plan_initialize(library: LibraryRecord, db: StateDB, config: LibraryConfig, run_id: int, progress: Progress | None = None, known_paths: list[Path] | None = None, limit: int | None = None) -> InitializePlan`.
- Changes: `execute_initialize(library: LibraryRecord, db: StateDB, plan: InitializePlan, run_id: int, audit: AuditLogger | None = None, progress: Progress | None = None, on_error: Callable[[str, str, int], bool] | None = None) -> InitializeResult`.
- Behavior: initialize plans are associated with `mode="initialize"`; plan approval authorizes moves; errors persist failed run/file state; successful terminal cleanup is run-scoped.

- [ ] **Step 1: Add failing initialize lifecycle tests**

Add tests proving plan records belong to an initialize run, timeout marks the run failed, successful records may be removed without touching another run, and Resume uses source/destination reconciliation:

```python
def test_initialize_timeout_marks_run_failed_and_preserves_pending(db, library, tmp_path):
    run = db.create_import_run(library.id, str(Path(library.location).resolve()), "initialize")
    plan = plan_initialize(library, db, LibraryConfig(), run.id)
    with patch("trove.initialize.move_file", side_effect=TimeoutError("mount unavailable")):
        result = execute_initialize(library, db, plan, run.id)
    assert result.errors == 1
    assert db.get_import_run(run.id).status == "failed"
    assert db.query_files_by_run(run.id, ("failed", "hashed", "discovered"))
```

Add a CLI test where declining `Proceed?` leaves a pending run and all source bytes unchanged. Add a Resume/Abort test for an existing failed initialize run; Abort must leave snapshots unchanged.

- [ ] **Step 2: Run initialize tests and verify failure**

Run: `.venv/bin/python -m pytest tests/test_initialize.py tests/test_cli.py -k "initialize or move_mode or queued" -v`

Expected: FAIL because initialize planning/execution has no run ID or durable run state.

- [ ] **Step 3: Associate initialize discovery and planning with a run**

Pass `run_id` into `discover_and_persist`. Replace library-path prefix queries with `query_files_by_run`. Build `_resume_init_from_db` from the active initialize run only. Keep the existing classification and orphan reconciliation algorithms unchanged.

- [ ] **Step 4: Persist initialize failures and complete successful runs**

When `_handle_error` receives timeout/move/index/rollback errors, find the file record by the action’s canonical source path and call `mark_import_failed`. Stop immediately on timeout as today. Successful action cleanup deletes only that action’s record. After all actions, if `errors == 0` and no pending run files remain, atomically mark the run completed; otherwise leave it failed/pending.

The CLI creates or selects an initialize run before planning. Existing plan output plus `Proceed?`/`--yes` is the authorization boundary. Declining leaves the run pending and performs no filesystem/permanent-entry mutation.

- [ ] **Step 5: Run initialize tests**

Run: `.venv/bin/python -m pytest tests/test_initialize.py tests/test_cli.py -k "initialize or move_mode or queued" -v`

Expected: PASS, including existing move/orphan/rollback coverage and new run persistence.

- [ ] **Step 6: Commit durable initialize state**

```bash
git add src/trove/initialize.py src/trove/cli.py tests/test_initialize.py tests/test_cli.py
git commit -m "Track initialization runs durably"
```

---

### Task 7: Generated-Output Collision Safety and Authorization Regression

**Files:**
- Modify: `src/trove/cli.py:255-404,837-895,1107-1170`
- Test: `tests/test_cli.py`
- Test: `tests/test_report.py`

**Interfaces:**
- Produces: `_collision_free_output_path(path: Path) -> Path`, returning the original nonexistent path or `stem-1.ext`, `stem-2.ext`, and so on without modifying disk.
- Preserves: explicit `--delete-list PATH` authorizes replacement of that exact output path.
- Preserves: existing explicit authorization gates for library delete, `dedupe --apply`, `status --clear-missing`, initialize `Proceed?`, and `--yes`.

- [ ] **Step 1: Add failing fixed-output collision and gate tests**

```python
def test_analysis_report_does_not_overwrite_existing_file(db, library, tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    existing = source / "trove_analysis_report.html"
    existing.write_text("user content")

    with patch("trove.cli.click.launch"):
        _generate_and_open_report(db, library, ImportPlan(), str(source))

    assert existing.read_text() == "user content"
    assert (source / "trove_analysis_report-1.html").exists()


def test_collision_free_output_path_counts_up(tmp_path):
    base = tmp_path / "report.html"
    base.write_text("one")
    (tmp_path / "report-1.html").write_text("two")
    assert _collision_free_output_path(base) == tmp_path / "report-2.html"
```

Retain/add assertions that wrong typed library-delete confirmation, dry-run dedupe, declined missing cleanup, and declined initialize plan do not change permanent rows/files. Assert the corresponding explicit command/flag path performs only the displayed action.

- [ ] **Step 2: Run report and authorization tests and verify failure**

Run: `.venv/bin/python -m pytest tests/test_report.py tests/test_cli.py -k "report or delete or dedupe or clear_missing or abort" -v`

Expected: FAIL on fixed-name report collision; existing authorization tests should already pass and protect against regression.

- [ ] **Step 3: Route fixed generated outputs through collision-free selection**

Implement:

```python
def _collision_free_output_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(1, 10000):
        candidate = path.with_name(f"{path.stem}-{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Could not choose a free output path for {path}")
```

Use it for analysis and duplicate reports before calling report generation. Keep `--delete-list` behavior because the user explicitly supplied that output path; do not broaden implicit overwrite permissions.

- [ ] **Step 4: Run report and authorization tests**

Run: `.venv/bin/python -m pytest tests/test_report.py tests/test_cli.py -k "report or delete or dedupe or clear_missing or abort" -v`

Expected: PASS; pre-existing report bytes and declined-action snapshots are unchanged.

- [ ] **Step 5: Commit output safety**

```bash
git add src/trove/cli.py tests/test_cli.py tests/test_report.py
git commit -m "Avoid generated report overwrites"
```

---

### Task 8: Full Contract Verification

**Files:**
- Modify only if a verification failure exposes a real regression in a file changed by Tasks 1–7.

**Interfaces:**
- Verifies all interfaces and invariants produced by Tasks 1–7.

- [ ] **Step 1: Run focused recovery and safety modules**

Run:

```bash
.venv/bin/python -m pytest \
  tests/test_db.py \
  tests/test_pipeline.py \
  tests/test_timeout.py \
  tests/test_importer.py \
  tests/test_complete.py \
  tests/test_initialize.py \
  tests/test_report.py \
  tests/test_cli.py -v
```

Expected: PASS with no access to the default DB or live paths.

- [ ] **Step 2: Run static checks**

Run: `make check`

Expected: Ruff and MyPy both PASS. Fix only diagnostics caused by the changed interfaces; rerun `make check` after each correction.

- [ ] **Step 3: Run the complete isolated test suite**

Run: `make test`

Expected: all tests PASS. This command invokes pytest only; do not run `trove`, `make all`, or any manual live-database scenario.

- [ ] **Step 4: Inspect verification evidence for the requested guarantees**

Confirm the passing test output includes contracts for: non-zero timeout exit; failed run/file persistence; Resume/Abort; abort immutability; no source deletion; no destination overwrite/deletion; run-scoped completion; cross-source/library isolation; initialize authorization/failure; and report collision safety.

- [ ] **Step 5: Commit any verification-only corrections**

If Tasks 1–7 required no correction, skip this commit. Otherwise stage only corrected files by exact name and commit:

```bash
git add src/trove/db.py src/trove/plan.py src/trove/pipeline.py src/trove/timeout.py src/trove/importer.py src/trove/complete.py src/trove/initialize.py src/trove/cli.py tests/test_db.py tests/test_pipeline.py tests/test_timeout.py tests/test_importer.py tests/test_complete.py tests/test_initialize.py tests/test_cli.py tests/test_report.py
git commit -m "Fix durable recovery verification regressions"
```
