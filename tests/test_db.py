"""Tests for the state database module."""

from __future__ import annotations

import sqlite3

import pytest

from trove.config import LibraryConfig, OrganizationConfig
from trove.db import EntryRecord, FileRecord, LibraryRecord, StateDB


class TestDatabaseCreation:
    def test_creates_tables(self, db):
        """New DB has all three tables with correct columns."""
        cur = db._conn.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        tables = sorted(row[0] for row in cur.fetchall())
        assert "entries" in tables
        assert "files" in tables
        assert "libraries" in tables

        # Check columns exist on each table
        lib_cols = {row[1] for row in db._conn.execute("PRAGMA table_info(libraries)").fetchall()}
        assert lib_cols == {"id", "name", "location", "config", "created_at"}

        entry_cols = {row[1] for row in db._conn.execute("PRAGMA table_info(entries)").fetchall()}
        assert entry_cols == {
            "id",
            "library_id",
            "relative_path",
            "file_size",
            "md5_hash",
            "capture_date",
            "camera_model",
            "imported_at",
            "original_path",
        }

        file_cols = {row[1] for row in db._conn.execute("PRAGMA table_info(files)").fetchall()}
        assert file_cols == {
            "id",
            "source_path",
            "source_type",
            "file_size",
            "file_modify_date",
            "md5_hash",
            "capture_date",
            "camera_model",
            "target_path",
            "status",
            "error_message",
            "discovered_at",
            "hashed_at",
        }

    def test_wal_mode_enabled(self, db):
        """PRAGMA journal_mode returns 'wal'."""
        mode = db._conn.execute("PRAGMA journal_mode").fetchone()[0]
        assert mode == "wal"


class TestLibraries:
    def test_create_and_read_library(self, db):
        """Create library, get it back, all fields match."""
        lib = db.create_library("Photos", "/Volumes/nas/photos")
        assert isinstance(lib, LibraryRecord)
        assert lib.id is not None
        assert lib.name == "Photos"
        assert lib.location == "/Volumes/nas/photos"
        assert lib.created_at is not None

    def test_duplicate_library_name_raises(self, db):
        """Creating two libraries with same name raises IntegrityError."""
        db.create_library("Photos", "/Volumes/nas/photos")
        with pytest.raises(sqlite3.IntegrityError):
            db.create_library("Photos", "/other/path")

    def test_get_library_by_name(self, db):
        """get_library with string looks up by name."""
        created = db.create_library("Photos", "/Volumes/nas/photos")
        fetched = db.get_library("Photos")
        assert fetched is not None
        assert fetched.id == created.id
        assert fetched.name == "Photos"
        assert fetched.location == "/Volumes/nas/photos"

    def test_get_library_by_id(self, db):
        """get_library with int looks up by id."""
        created = db.create_library("Photos", "/Volumes/nas/photos")
        fetched = db.get_library(created.id)
        assert fetched is not None
        assert fetched.name == "Photos"

    def test_get_library_not_found(self, db):
        """get_library returns None for nonexistent."""
        assert db.get_library("nonexistent") is None
        assert db.get_library(9999) is None

    def test_list_libraries(self, db):
        """list_libraries returns all created libraries."""
        db.create_library("Photos", "/vol/photos")
        db.create_library("Videos", "/vol/videos")
        libs = db.list_libraries()
        assert len(libs) == 2
        names = {lib.name for lib in libs}
        assert names == {"Photos", "Videos"}


class TestFiles:
    def test_insert_and_read_file(self, db):
        """Insert file, get by path, all fields match."""
        f = db.insert_file(
            source_path="/tmp/photo.jpg",
            source_type="local",
            file_size=1024,
            file_modify_date="2024-01-15T10:30:00",
        )
        assert isinstance(f, FileRecord)
        assert f.id is not None
        assert f.source_path == "/tmp/photo.jpg"
        assert f.source_type == "local"
        assert f.file_size == 1024
        assert f.file_modify_date == "2024-01-15T10:30:00"
        assert f.status == "discovered"
        assert f.discovered_at is not None
        assert f.md5_hash is None
        assert f.hashed_at is None

        fetched = db.get_file_by_path("/tmp/photo.jpg")
        assert fetched is not None
        assert fetched.id == f.id
        assert fetched.source_path == f.source_path

    def test_update_file_status(self, db):
        """Update status, read back, change persisted."""
        f = db.insert_file("/tmp/a.jpg", "local", 512, "2024-01-01T00:00:00")
        db.update_file(f.id, status="hashed")
        updated = db.get_file_by_path("/tmp/a.jpg")
        assert updated.status == "hashed"

    def test_update_file_hash(self, db):
        """Update md5_hash and hashed_at, read back."""
        f = db.insert_file("/tmp/b.jpg", "local", 512, "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash="abc123", hashed_at="2024-01-15T12:00:00")
        updated = db.get_file_by_path("/tmp/b.jpg")
        assert updated.md5_hash == "abc123"
        assert updated.hashed_at == "2024-01-15T12:00:00"

    def test_update_file_invalid_field_raises(self, db):
        """Updating a nonexistent column raises ValueError."""
        f = db.insert_file("/tmp/c.jpg", "local", 512, "2024-01-01T00:00:00")
        with pytest.raises(ValueError, match="Invalid field"):
            db.update_file(f.id, bogus_field="nope")

    def test_query_files_by_status(self, db):
        """Returns only files matching status."""
        db.insert_file("/tmp/a.jpg", "local", 100, "2024-01-01T00:00:00")
        db.insert_file("/tmp/b.jpg", "local", 200, "2024-01-01T00:00:00")
        f3 = db.insert_file("/tmp/c.jpg", "local", 300, "2024-01-01T00:00:00")
        db.update_file(f3.id, status="hashed")

        discovered = db.query_files_by_status("discovered")
        assert len(discovered) == 2

        hashed = db.query_files_by_status("hashed")
        assert len(hashed) == 1
        assert hashed[0].source_path == "/tmp/c.jpg"

    def test_delete_files_by_status(self, db):
        """Deletes matching, leaves others."""
        db.insert_file("/tmp/a.jpg", "local", 100, "2024-01-01T00:00:00")
        f2 = db.insert_file("/tmp/b.jpg", "local", 200, "2024-01-01T00:00:00")
        f3 = db.insert_file("/tmp/c.jpg", "local", 300, "2024-01-01T00:00:00")
        db.update_file(f2.id, status="imported")
        db.update_file(f3.id, status="completed")

        db.delete_files_by_status(["imported", "completed"])

        remaining = db.query_files_by_status("discovered")
        assert len(remaining) == 1
        assert remaining[0].source_path == "/tmp/a.jpg"

        assert db.query_files_by_status("imported") == []
        assert db.query_files_by_status("completed") == []


class TestEntries:
    def test_create_and_read_entry_by_path(self, db, library):
        """Create entry, get by path, all fields match."""
        entry = db.create_entry(
            library_id=library.id,
            relative_path="2024/01/photo.jpg",
            file_size=2048,
            md5_hash="deadbeef",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon EOS R5",
        )
        assert isinstance(entry, EntryRecord)
        assert entry.id is not None
        assert entry.library_id == library.id
        assert entry.relative_path == "2024/01/photo.jpg"
        assert entry.file_size == 2048
        assert entry.md5_hash == "deadbeef"
        assert entry.capture_date == "2024-01-15T10:30:00"
        assert entry.camera_model == "Canon EOS R5"
        assert entry.imported_at is not None

        fetched = db.get_entry_by_path(library.id, "2024/01/photo.jpg")
        assert fetched is not None
        assert fetched.id == entry.id

    def test_create_and_read_entries_by_hash(self, db, library):
        """Create entry, get by hash, returns list with one entry."""
        entry = db.create_entry(
            library_id=library.id,
            relative_path="2024/01/photo.jpg",
            file_size=2048,
            md5_hash="deadbeef",
            capture_date=None,
            camera_model=None,
        )
        fetched = db.get_entries_by_hash(library.id, "deadbeef")
        assert isinstance(fetched, list)
        assert len(fetched) == 1
        assert fetched[0].id == entry.id

    def test_duplicate_path_raises(self, db, library):
        """Same library + relative_path raises IntegrityError."""
        db.create_entry(library.id, "2024/01/photo.jpg", 2048, "hash1", None, None)
        with pytest.raises(sqlite3.IntegrityError):
            db.create_entry(library.id, "2024/01/photo.jpg", 1024, "hash2", None, None)

    def test_duplicate_hash_allowed(self, db, library):
        """Same library + md5_hash with different paths is allowed."""
        entry1 = db.create_entry(library.id, "2024/01/a.jpg", 2048, "samehash", None, None)
        entry2 = db.create_entry(library.id, "2024/01/b.jpg", 1024, "samehash", None, None)
        fetched = db.get_entries_by_hash(library.id, "samehash")
        assert isinstance(fetched, list)
        assert len(fetched) == 2
        ids = {e.id for e in fetched}
        assert ids == {entry1.id, entry2.id}

    def test_list_entries(self, db, library):
        """list_entries returns all entries for library."""
        db.create_entry(library.id, "a.jpg", 100, "h1", None, None)
        db.create_entry(library.id, "b.jpg", 200, "h2", None, None)
        entries = db.list_entries(library.id)
        assert len(entries) == 2
        paths = {e.relative_path for e in entries}
        assert paths == {"a.jpg", "b.jpg"}


class TestAtomicImport:
    def test_import_file_creates_entry_and_updates_status(self, db, library):
        """import_file creates entry AND sets file status to imported."""
        f = db.insert_file("/tmp/photo.jpg", "local", 2048, "2024-01-15T10:30:00")
        db.update_file(f.id, md5_hash="deadbeef", status="hashed")

        entry = db.import_file(
            file_id=f.id,
            library_id=library.id,
            relative_path="2024/01/photo.jpg",
            file_size=2048,
            md5_hash="deadbeef",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon EOS R5",
        )
        assert isinstance(entry, EntryRecord)
        assert entry.relative_path == "2024/01/photo.jpg"

        updated_file = db.get_file_by_path("/tmp/photo.jpg")
        assert updated_file.status == "imported"

    def test_import_file_rollback_on_error(self, db, library):
        """If entry creation fails (e.g. duplicate path), file status unchanged."""
        # Create an existing entry at path "existing.jpg"
        db.create_entry(library.id, "existing.jpg", 1024, "hash_a", None, None)

        f = db.insert_file("/tmp/photo.jpg", "local", 2048, "2024-01-15T10:30:00")
        db.update_file(f.id, md5_hash="hash_b", status="hashed")

        with pytest.raises(sqlite3.IntegrityError):
            db.import_file(
                file_id=f.id,
                library_id=library.id,
                relative_path="existing.jpg",  # duplicate path
                file_size=2048,
                md5_hash="hash_b",
                capture_date=None,
                camera_model=None,
            )

        # File status should be unchanged (still "hashed", not "imported")
        unchanged = db.get_file_by_path("/tmp/photo.jpg")
        assert unchanged.status == "hashed"


class TestEntriesNullableHash:
    def test_create_entry_with_null_hash(self, db, library):
        """Entry can be created with md5_hash=None."""
        entry = db.create_entry(library.id, "2024/01/photo.jpg", 2048, None, None, None)
        assert entry.md5_hash is None
        fetched = db.get_entry_by_path(library.id, "2024/01/photo.jpg")
        assert fetched is not None
        assert fetched.md5_hash is None

    def test_create_entry_with_hash_still_works(self, db, library):
        """Entry with hash still works as before."""
        entry = db.create_entry(library.id, "2024/01/photo.jpg", 2048, "abc123", None, None)
        assert entry.md5_hash == "abc123"

    def test_update_entry_hash(self, db, library):
        """Backfill hash on an entry."""
        entry = db.create_entry(library.id, "2024/01/photo.jpg", 2048, None, None, None)
        assert entry.md5_hash is None
        db.update_entry_hash(entry.id, "abc123")
        fetched = db.get_entry_by_path(library.id, "2024/01/photo.jpg")
        assert fetched.md5_hash == "abc123"

    def test_list_entries_missing_hash(self, db, library):
        """Only entries with null hashes are returned."""
        db.create_entry(library.id, "missing.jpg", 2048, None, None, None)
        db.create_entry(library.id, "hashed.jpg", 2048, "abc123", None, None)

        missing = db.list_entries_missing_hash(library.id)

        assert len(missing) == 1
        assert missing[0].relative_path == "missing.jpg"

    def test_delete_entries(self, db, library):
        """Delete specific entries by id."""
        db.create_entry(library.id, "keep.jpg", 2048, "keep", None, None)
        drop = db.create_entry(library.id, "drop.jpg", 2048, "drop", None, None)

        db.delete_entries([drop.id])

        assert db.get_entry_by_path(library.id, "drop.jpg") is None
        assert db.get_entry_by_path(library.id, "keep.jpg") is not None


class TestEntriesBySize:
    def test_get_entries_by_size_found(self, db, library):
        """Returns entries matching file size."""
        db.create_entry(library.id, "a.jpg", 1024, None, None, None)
        db.create_entry(library.id, "b.jpg", 1024, None, None, None)
        db.create_entry(library.id, "c.jpg", 2048, None, None, None)

        results = db.get_entries_by_size(library.id, 1024)
        assert len(results) == 2

    def test_get_entries_by_size_not_found(self, db, library):
        """Returns empty list for no size match."""
        db.create_entry(library.id, "a.jpg", 1024, None, None, None)
        results = db.get_entries_by_size(library.id, 9999)
        assert results == []

    def test_get_entries_by_size_correct_library(self, db, tmp_path):
        """Only returns entries from the specified library."""
        lib_dir1 = tmp_path / "lib1"
        lib_dir1.mkdir()
        lib_dir2 = tmp_path / "lib2"
        lib_dir2.mkdir()
        lib1 = db.create_library("Lib1", str(lib_dir1))
        lib2 = db.create_library("Lib2", str(lib_dir2))

        db.create_entry(lib1.id, "a.jpg", 1024, None, None, None)
        db.create_entry(lib2.id, "b.jpg", 1024, None, None, None)

        results = db.get_entries_by_size(lib1.id, 1024)
        assert len(results) == 1
        assert results[0].relative_path == "a.jpg"


class TestQueryFilesByIds:
    def test_returns_matching_records(self, db):
        """Insert 3 files, query 2 by ID, get exactly those 2."""
        f1 = db.insert_file("/tmp/a.jpg", "local", 100, "2024-01-01T00:00:00")
        _f2 = db.insert_file("/tmp/b.jpg", "local", 200, "2024-01-01T00:00:00")
        f3 = db.insert_file("/tmp/c.jpg", "local", 300, "2024-01-01T00:00:00")

        results = db.query_files_by_ids([f1.id, f3.id])
        assert len(results) == 2
        paths = {r.source_path for r in results}
        assert paths == {"/tmp/a.jpg", "/tmp/c.jpg"}

    def test_preserves_order(self, db):
        """Query [id3, id1, id2], get records in that order."""
        f1 = db.insert_file("/tmp/a.jpg", "local", 100, "2024-01-01T00:00:00")
        f2 = db.insert_file("/tmp/b.jpg", "local", 200, "2024-01-01T00:00:00")
        f3 = db.insert_file("/tmp/c.jpg", "local", 300, "2024-01-01T00:00:00")

        results = db.query_files_by_ids([f3.id, f1.id, f2.id])
        assert len(results) == 3
        assert results[0].source_path == "/tmp/c.jpg"
        assert results[1].source_path == "/tmp/a.jpg"
        assert results[2].source_path == "/tmp/b.jpg"

    def test_skips_missing_ids(self, db):
        """Query with a nonexistent ID, it's silently skipped."""
        f1 = db.insert_file("/tmp/a.jpg", "local", 100, "2024-01-01T00:00:00")

        results = db.query_files_by_ids([f1.id, 99999])
        assert len(results) == 1
        assert results[0].source_path == "/tmp/a.jpg"

    def test_empty_list_returns_empty(self, db):
        """Query with [] returns []."""
        assert db.query_files_by_ids([]) == []


class TestLibraryConfig:
    def test_create_library_default_config(self, db):
        """Library created without config gets LibraryConfig defaults."""
        lib = db.create_library("Photos", "/vol/photos")
        assert lib.config == LibraryConfig()

    def test_create_library_custom_config(self, db):
        """Library created with custom config stores it."""
        custom = LibraryConfig(
            organization=OrganizationConfig(structure="%Y/%m/%d", include_camera_model=False)
        )
        lib = db.create_library("Photos", "/vol/photos", config=custom)
        assert lib.config.organization.structure == "%Y/%m/%d"
        assert lib.config.organization.include_camera_model is False

    def test_get_library_returns_config(self, db):
        """get_library round-trips the config."""
        custom = LibraryConfig(
            organization=OrganizationConfig(structure="%Y/%B")
        )
        db.create_library("Photos", "/vol/photos", config=custom)
        fetched = db.get_library("Photos")
        assert fetched is not None
        assert fetched.config.organization.structure == "%Y/%B"

    def test_list_libraries_returns_config(self, db):
        """list_libraries includes config on each record."""
        custom = LibraryConfig(
            organization=OrganizationConfig(structure="%Y/%m/%d")
        )
        db.create_library("A", "/vol/a", config=custom)
        db.create_library("B", "/vol/b")
        libs = {lib.name: lib for lib in db.list_libraries()}
        assert libs["A"].config.organization.structure == "%Y/%m/%d"
        assert libs["B"].config == LibraryConfig()

    def test_update_library_config(self, db):
        """update_library_config changes the stored config."""
        lib = db.create_library("Photos", "/vol/photos")
        new_config = LibraryConfig(
            organization=OrganizationConfig(structure="%Y/%m/%d")
        )
        db.update_library_config(lib.id, new_config)
        fetched = db.get_library(lib.id)
        assert fetched is not None
        assert fetched.config.organization.structure == "%Y/%m/%d"

    def test_update_library_location(self, db):
        """update_library_location changes the stored location."""
        lib = db.create_library("Photos", "/vol/old")
        db.update_library_location(lib.id, "/vol/new")
        fetched = db.get_library(lib.id)
        assert fetched is not None
        assert fetched.location == "/vol/new"


class TestSchemaMigration:
    def test_new_db_has_schema_version(self, db):
        """Fresh DB has schema_version table with current version."""
        row = db._conn.execute("SELECT version FROM schema_version").fetchone()
        assert row is not None
        assert row[0] >= 1

    def test_new_db_has_config_column(self, db):
        """Fresh DB has config column on libraries table."""
        cols = {row[1] for row in db._conn.execute("PRAGMA table_info(libraries)").fetchall()}
        assert "config" in cols

    def test_migration_from_v0(self, tmp_path):
        """Opening a v0 DB (no schema_version, no config column) migrates it."""
        db_path = tmp_path / "legacy.db"
        # Create a v0 database manually
        conn = sqlite3.connect(str(db_path))
        conn.executescript("""
            CREATE TABLE libraries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                location TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            INSERT INTO libraries (name, location, created_at)
                VALUES ('OldLib', '/vol/old', '2025-01-01T00:00:00');
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                library_id INTEGER NOT NULL REFERENCES libraries(id),
                relative_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                md5_hash TEXT,
                capture_date TEXT,
                camera_model TEXT,
                imported_at TEXT NOT NULL,
                UNIQUE(library_id, relative_path)
            );
            CREATE TABLE files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_path TEXT NOT NULL,
                source_type TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                file_modify_date TEXT NOT NULL,
                md5_hash TEXT,
                capture_date TEXT,
                camera_model TEXT,
                target_path TEXT,
                status TEXT NOT NULL,
                error_message TEXT,
                discovered_at TEXT NOT NULL,
                hashed_at TEXT
            );
        """)
        conn.close()

        with StateDB(db_path) as db:
            # Migration should have added config column
            cols = {row[1] for row in db._conn.execute("PRAGMA table_info(libraries)").fetchall()}
            assert "config" in cols

            # Existing library should have default config
            row = db._conn.execute(
                "SELECT config FROM libraries WHERE name = 'OldLib'"
            ).fetchone()
            assert row is not None
            assert row[0] == "{}"

            # schema_version should be current
            version = db._conn.execute("SELECT version FROM schema_version").fetchone()[0]
            assert version >= 1


class TestOriginalPath:
    def test_entries_table_has_original_path_column(self, db):
        """entries table includes original_path column."""
        cols = {row[1] for row in db._conn.execute("PRAGMA table_info(entries)").fetchall()}
        assert "original_path" in cols

    def test_create_entry_with_original_path(self, db, library):
        """create_entry accepts and stores original_path."""
        entry = db.create_entry(
            library_id=library.id,
            relative_path="2024/01/Canon/photo.jpg",
            file_size=2048,
            md5_hash="deadbeef",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon EOS R5",
            original_path="mammals/photo.jpg",
        )
        assert entry.original_path == "mammals/photo.jpg"

    def test_create_entry_without_original_path(self, db, library):
        """create_entry defaults original_path to None."""
        entry = db.create_entry(
            library_id=library.id,
            relative_path="2024/01/Canon/photo.jpg",
            file_size=2048,
            md5_hash="deadbeef",
            capture_date=None,
            camera_model=None,
        )
        assert entry.original_path is None

    def test_get_entry_by_path_includes_original_path(self, db, library):
        """get_entry_by_path round-trips original_path."""
        db.create_entry(
            library_id=library.id,
            relative_path="2024/01/Canon/photo.jpg",
            file_size=2048,
            md5_hash="deadbeef",
            capture_date=None,
            camera_model=None,
            original_path="trips/NC-Sandhills/photo.jpg",
        )
        fetched = db.get_entry_by_path(library.id, "2024/01/Canon/photo.jpg")
        assert fetched.original_path == "trips/NC-Sandhills/photo.jpg"

    def test_list_entries_includes_original_path(self, db, library):
        """list_entries includes original_path on each record."""
        db.create_entry(library.id, "a.jpg", 100, "h1", None, None, original_path="birds/a.jpg")
        db.create_entry(library.id, "b.jpg", 200, "h2", None, None)
        entries = {e.relative_path: e for e in db.list_entries(library.id)}
        assert entries["a.jpg"].original_path == "birds/a.jpg"
        assert entries["b.jpg"].original_path is None

    def test_migration_adds_original_path_to_existing_db(self, tmp_path):
        """Opening a DB without original_path column adds it via migration."""
        db_path = tmp_path / "legacy.db"
        # Create a v1 database (has config column but no original_path)
        conn = sqlite3.connect(str(db_path))
        conn.executescript("""
            CREATE TABLE libraries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                location TEXT NOT NULL,
                config TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL
            );
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                library_id INTEGER NOT NULL REFERENCES libraries(id),
                relative_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                md5_hash TEXT,
                capture_date TEXT,
                camera_model TEXT,
                imported_at TEXT NOT NULL,
                UNIQUE(library_id, relative_path)
            );
            CREATE TABLE files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_path TEXT NOT NULL,
                source_type TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                file_modify_date TEXT NOT NULL,
                md5_hash TEXT,
                capture_date TEXT,
                camera_model TEXT,
                target_path TEXT,
                status TEXT NOT NULL,
                error_message TEXT,
                discovered_at TEXT NOT NULL,
                hashed_at TEXT
            );
            CREATE TABLE schema_version (version INTEGER NOT NULL);
            INSERT INTO schema_version (version) VALUES (1);
        """)
        conn.close()

        with StateDB(db_path) as db:
            cols = {row[1] for row in db._conn.execute("PRAGMA table_info(entries)").fetchall()}
            assert "original_path" in cols


class TestPersistence:
    def test_reopen_preserves_data(self, tmp_path):
        """Close and reopen DB, all data still there."""
        db_path = tmp_path / "test.db"

        with StateDB(db_path) as db:
            db.create_library("Photos", "/vol/photos")
            db.insert_file("/tmp/a.jpg", "local", 100, "2024-01-01T00:00:00")

        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            assert lib is not None
            assert lib.name == "Photos"

            f = db.get_file_by_path("/tmp/a.jpg")
            assert f is not None
            assert f.source_path == "/tmp/a.jpg"
