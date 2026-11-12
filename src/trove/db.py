"""State database for Trove — persistence layer with libraries, entries, and files."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING

from trove.config import LibraryConfig

if TYPE_CHECKING:
    from typing_extensions import Self

# --- Row dataclasses (all frozen) ---


@dataclass(frozen=True)
class LibraryRecord:
    id: int
    name: str
    location: str
    created_at: str
    config: LibraryConfig = dataclass_field(default_factory=LibraryConfig)


@dataclass(frozen=True)
class EntryRecord:
    id: int
    library_id: int
    relative_path: str
    file_size: int
    md5_hash: str | None = None
    capture_date: str | None = None
    camera_model: str | None = None
    imported_at: str = ""
    original_path: str | None = None


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


# Valid column names for files table (used by update_file validation)
_FILE_COLUMNS = frozenset(
    {
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
)


_SCHEMA_VERSION = 3

_MIGRATIONS: dict[int, str] = {
    1: "ALTER TABLE libraries ADD COLUMN config TEXT NOT NULL DEFAULT '{}';",
    2: "ALTER TABLE entries ADD COLUMN original_path TEXT;",
    3: (
        "CREATE TABLE IF NOT EXISTS entries_creation_date_stamped ("
        "    entry_id INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,"
        "    stamped_at TEXT NOT NULL"
        ");"
    ),
}

_CREATE_TABLES = """\
CREATE TABLE IF NOT EXISTS libraries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    location TEXT NOT NULL,
    config TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL REFERENCES libraries(id),
    relative_path TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    md5_hash TEXT,
    capture_date TEXT,
    camera_model TEXT,
    imported_at TEXT NOT NULL,
    original_path TEXT,
    UNIQUE(library_id, relative_path)
);

CREATE TABLE IF NOT EXISTS entries_creation_date_stamped (
    entry_id INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    stamped_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
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

CREATE INDEX IF NOT EXISTS idx_entries_library_hash ON entries(library_id, md5_hash);
CREATE INDEX IF NOT EXISTS idx_entries_library_path ON entries(library_id, relative_path);
CREATE INDEX IF NOT EXISTS idx_entries_library_size ON entries(library_id, file_size);
CREATE INDEX IF NOT EXISTS idx_files_source_path ON files(source_path);
CREATE INDEX IF NOT EXISTS idx_files_md5_hash ON files(md5_hash);
CREATE INDEX IF NOT EXISTS idx_files_status ON files(status);
"""


def _now() -> str:
    """Return current UTC time as ISO 8601 string."""
    return datetime.now(timezone.utc).isoformat()


class StateDB:
    """SQLite-backed state database for Trove.

    Use as a context manager:

        with StateDB(path) as db:
            db.create_library(...)
    """

    def __init__(self, path: Path | None = None) -> None:
        if path is None:
            path = Path.home() / ".trove" / "state.db"
        self._path = Path(path)
        self.__conn: sqlite3.Connection | None = None

    def __enter__(self) -> Self:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self.__conn = sqlite3.connect(str(self._path))
        self.__conn.execute("PRAGMA journal_mode=WAL")
        self.__conn.execute("PRAGMA foreign_keys=ON")
        self.__conn.executescript(_CREATE_TABLES)
        self._migrate()
        return self

    def _migrate(self) -> None:
        """Run pending schema migrations."""
        conn = self._conn
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"
        )
        row = conn.execute("SELECT version FROM schema_version").fetchone()
        if row is None:
            # Determine if this is a fresh DB or a legacy (v0) DB.
            # Fresh DBs already have the config column from _CREATE_TABLES.
            cols = {r[1] for r in conn.execute("PRAGMA table_info(libraries)").fetchall()}
            if "config" in cols:
                # Fresh DB — no migrations needed, just record the version.
                current = _SCHEMA_VERSION
            else:
                current = 0
            conn.execute("INSERT INTO schema_version (version) VALUES (?)", (current,))
            conn.commit()
        else:
            current = row[0]

        for version in range(current + 1, _SCHEMA_VERSION + 1):
            sql = _MIGRATIONS[version]
            conn.executescript(sql)
            conn.execute("UPDATE schema_version SET version = ?", (version,))
            conn.commit()

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:  # noqa: ANN001
        if self.__conn is not None:
            self.__conn.close()
            self.__conn = None

    @property
    def _conn(self) -> sqlite3.Connection:
        """Get the database connection, asserting it's open."""
        if self.__conn is None:
            raise RuntimeError("Database not opened. Use 'with StateDB() as db:'")
        return self.__conn

    # --- Libraries ---

    def create_library(
        self, name: str, location: str, config: LibraryConfig | None = None,
    ) -> LibraryRecord:
        """Insert a new library and return its record."""
        if config is None:
            config = LibraryConfig()
        now = _now()
        cur = self._conn.execute(
            "INSERT INTO libraries (name, location, config, created_at) VALUES (?, ?, ?, ?)",
            (name, location, config.to_json(), now),
        )
        self._conn.commit()
        if cur.lastrowid is None:
            raise RuntimeError("Failed to get library ID")
        return LibraryRecord(
            id=cur.lastrowid,
            name=name,
            location=location,
            created_at=now,
            config=config,
        )

    def get_library(self, name_or_id: str | int) -> LibraryRecord | None:
        """Look up a library by name (str) or id (int)."""
        if isinstance(name_or_id, int):
            row = self._conn.execute(
                "SELECT id, name, location, config, created_at FROM libraries WHERE id = ?",
                (name_or_id,),
            ).fetchone()
        else:
            row = self._conn.execute(
                "SELECT id, name, location, config, created_at FROM libraries WHERE name = ?",
                (name_or_id,),
            ).fetchone()
        if row is None:
            return None
        return LibraryRecord(
            id=row[0], name=row[1], location=row[2],
            created_at=row[4], config=LibraryConfig.from_json(row[3]),
        )

    def list_libraries(self) -> list[LibraryRecord]:
        """Return all libraries."""
        rows = self._conn.execute("SELECT id, name, location, config, created_at FROM libraries").fetchall()
        return [
            LibraryRecord(
                id=r[0], name=r[1], location=r[2],
                created_at=r[4], config=LibraryConfig.from_json(r[3]),
            )
            for r in rows
        ]

    def update_library_config(self, library_id: int, config: LibraryConfig) -> None:
        """Update the config for a library."""
        self._conn.execute(
            "UPDATE libraries SET config = ? WHERE id = ?",
            (config.to_json(), library_id),
        )
        self._conn.commit()

    def update_library_location(self, library_id: int, location: str) -> None:
        """Update the location for a library."""
        self._conn.execute(
            "UPDATE libraries SET location = ? WHERE id = ?",
            (location, library_id),
        )
        self._conn.commit()

    def delete_library(self, library_id: int) -> None:
        """Delete a library and all its entries."""
        self._conn.execute("DELETE FROM entries WHERE library_id = ?", (library_id,))
        self._conn.execute("DELETE FROM libraries WHERE id = ?", (library_id,))
        self._conn.commit()

    # --- Entries ---

    def create_entry(
        self,
        library_id: int,
        relative_path: str,
        file_size: int,
        md5_hash: str | None,
        capture_date: str | None,
        camera_model: str | None,
        original_path: str | None = None,
    ) -> EntryRecord:
        """Insert a new entry and return its record."""
        now = _now()
        cur = self._conn.execute(
            "INSERT INTO entries "
            "(library_id, relative_path, file_size, md5_hash, capture_date, camera_model, imported_at, original_path) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                library_id,
                relative_path,
                file_size,
                md5_hash,
                capture_date,
                camera_model,
                now,
                original_path,
            ),
        )
        self._conn.commit()
        if cur.lastrowid is None:
            raise RuntimeError("Failed to get entry ID")
        return EntryRecord(
            id=cur.lastrowid,
            library_id=library_id,
            relative_path=relative_path,
            file_size=file_size,
            md5_hash=md5_hash,
            capture_date=capture_date,
            camera_model=camera_model,
            imported_at=now,
            original_path=original_path,
        )

    def get_entry_by_path(self, library_id: int, relative_path: str) -> EntryRecord | None:
        """Look up an entry by library and relative path."""
        row = self._conn.execute(
            "SELECT id, library_id, relative_path, file_size, md5_hash, "
            "capture_date, camera_model, imported_at, original_path "
            "FROM entries WHERE library_id = ? AND relative_path = ?",
            (library_id, relative_path),
        ).fetchone()
        if row is None:
            return None
        return EntryRecord(
            id=row[0],
            library_id=row[1],
            relative_path=row[2],
            file_size=row[3],
            md5_hash=row[4],
            capture_date=row[5],
            camera_model=row[6],
            imported_at=row[7],
            original_path=row[8],
        )

    def get_entries_by_hash(self, library_id: int, md5_hash: str) -> list[EntryRecord]:
        """Look up entries by library and md5 hash."""
        rows = self._conn.execute(
            "SELECT id, library_id, relative_path, file_size, md5_hash, "
            "capture_date, camera_model, imported_at, original_path "
            "FROM entries WHERE library_id = ? AND md5_hash = ? "
            "ORDER BY id",
            (library_id, md5_hash),
        ).fetchall()
        return [
            EntryRecord(
                id=row[0],
                library_id=row[1],
                relative_path=row[2],
                file_size=row[3],
                md5_hash=row[4],
                capture_date=row[5],
                camera_model=row[6],
                imported_at=row[7],
                original_path=row[8],
            )
            for row in rows
        ]

    def get_duplicate_groups(self, library_id: int) -> list[list[EntryRecord]]:
        """Return groups of entries sharing the same md5_hash within a library.

        Only returns groups with 2+ entries (actual duplicates).
        """
        rows = self._conn.execute(
            "SELECT md5_hash FROM entries "
            "WHERE library_id = ? AND md5_hash IS NOT NULL "
            "GROUP BY md5_hash HAVING COUNT(*) > 1 "
            "ORDER BY md5_hash",
            (library_id,),
        ).fetchall()

        groups = []
        for (hash_val,) in rows:
            entries = self.get_entries_by_hash(library_id, hash_val)
            if len(entries) > 1:  # Only include groups with 2+ entries
                groups.append(entries)
        return groups

    def list_entries(self, library_id: int) -> list[EntryRecord]:
        """Return all entries for a library."""
        rows = self._conn.execute(
            "SELECT id, library_id, relative_path, file_size, md5_hash, "
            "capture_date, camera_model, imported_at, original_path "
            "FROM entries WHERE library_id = ?",
            (library_id,),
        ).fetchall()
        return [
            EntryRecord(
                id=r[0],
                library_id=r[1],
                relative_path=r[2],
                file_size=r[3],
                md5_hash=r[4],
                capture_date=r[5],
                camera_model=r[6],
                imported_at=r[7],
                original_path=r[8],
            )
            for r in rows
        ]

    def list_entries_missing_hash(self, library_id: int) -> list[EntryRecord]:
        """Return entries in a library that do not yet have an md5 hash."""
        rows = self._conn.execute(
            "SELECT id, library_id, relative_path, file_size, md5_hash, "
            "capture_date, camera_model, imported_at, original_path "
            "FROM entries WHERE library_id = ? AND md5_hash IS NULL "
            "ORDER BY id",
            (library_id,),
        ).fetchall()
        return [
            EntryRecord(
                id=r[0],
                library_id=r[1],
                relative_path=r[2],
                file_size=r[3],
                md5_hash=r[4],
                capture_date=r[5],
                camera_model=r[6],
                imported_at=r[7],
                original_path=r[8],
            )
            for r in rows
        ]

    def get_entries_by_size(self, library_id: int, file_size: int) -> list[EntryRecord]:
        """Look up entries by library and file size."""
        rows = self._conn.execute(
            "SELECT id, library_id, relative_path, file_size, md5_hash, "
            "capture_date, camera_model, imported_at, original_path "
            "FROM entries WHERE library_id = ? AND file_size = ?",
            (library_id, file_size),
        ).fetchall()
        return [
            EntryRecord(
                id=row[0],
                library_id=row[1],
                relative_path=row[2],
                file_size=row[3],
                md5_hash=row[4],
                capture_date=row[5],
                camera_model=row[6],
                imported_at=row[7],
                original_path=row[8],
            )
            for row in rows
        ]

    def update_entry_hash(self, entry_id: int, md5_hash: str) -> None:
        """Backfill the hash for an entry."""
        self._conn.execute(
            "UPDATE entries SET md5_hash = ? WHERE id = ?",
            (md5_hash, entry_id),
        )
        self._conn.commit()

    def delete_entries(self, entry_ids: list[int]) -> None:
        """Delete specific entries by ID."""
        if not entry_ids:
            return

        placeholders = ", ".join("?" for _ in entry_ids)
        self._conn.execute(
            f"DELETE FROM entries WHERE id IN ({placeholders})",  # noqa: S608
            entry_ids,
        )
        self._conn.commit()

    def mark_entry_creation_date_stamped(self, entry_id: int) -> None:
        """Record that the on-disk creation date has been set for this entry."""
        self._conn.execute(
            "INSERT OR REPLACE INTO entries_creation_date_stamped (entry_id, stamped_at) VALUES (?, ?)",
            (entry_id, _now()),
        )
        self._conn.commit()

    def list_entries_needing_creation_date_stamp(
        self, library_id: int, *, force: bool = False,
    ) -> list[EntryRecord]:
        """Return entries with a capture_date that have not yet been stamped.

        With force=True, returns all entries with a capture_date regardless of
        whether they have been stamped before.
        """
        if force:
            sql = (
                "SELECT id, library_id, relative_path, file_size, md5_hash, "
                "capture_date, camera_model, imported_at, original_path "
                "FROM entries "
                "WHERE library_id = ? AND capture_date IS NOT NULL "
                "ORDER BY id"
            )
        else:
            sql = (
                "SELECT e.id, e.library_id, e.relative_path, e.file_size, e.md5_hash, "
                "e.capture_date, e.camera_model, e.imported_at, e.original_path "
                "FROM entries e "
                "LEFT JOIN entries_creation_date_stamped s ON s.entry_id = e.id "
                "WHERE e.library_id = ? AND e.capture_date IS NOT NULL "
                "AND s.entry_id IS NULL "
                "ORDER BY e.id"
            )
        rows = self._conn.execute(sql, (library_id,)).fetchall()
        return [
            EntryRecord(
                id=r[0],
                library_id=r[1],
                relative_path=r[2],
                file_size=r[3],
                md5_hash=r[4],
                capture_date=r[5],
                camera_model=r[6],
                imported_at=r[7],
                original_path=r[8],
            )
            for r in rows
        ]

    # --- Files ---

    def insert_file(
        self,
        source_path: str,
        source_type: str,
        file_size: int,
        file_modify_date: str,
    ) -> FileRecord:
        """Insert a new file record with status='discovered'."""
        now = _now()
        cur = self._conn.execute(
            "INSERT INTO files "
            "(source_path, source_type, file_size, file_modify_date, status, discovered_at) "
            "VALUES (?, ?, ?, ?, 'discovered', ?)",
            (source_path, source_type, file_size, file_modify_date, now),
        )
        self._conn.commit()
        if cur.lastrowid is None:
            raise RuntimeError("Failed to get file ID")
        return FileRecord(
            id=cur.lastrowid,
            source_path=source_path,
            source_type=source_type,
            file_size=file_size,
            file_modify_date=file_modify_date,
            status="discovered",
            discovered_at=now,
        )

    def get_file_by_path(self, source_path: str) -> FileRecord | None:
        """Look up a file by source path."""
        row = self._conn.execute(
            "SELECT id, source_path, source_type, file_size, file_modify_date, "
            "md5_hash, capture_date, camera_model, target_path, status, "
            "error_message, discovered_at, hashed_at "
            "FROM files WHERE source_path = ?",
            (source_path,),
        ).fetchone()
        if row is None:
            return None
        return FileRecord(
            id=row[0],
            source_path=row[1],
            source_type=row[2],
            file_size=row[3],
            file_modify_date=row[4],
            md5_hash=row[5],
            capture_date=row[6],
            camera_model=row[7],
            target_path=row[8],
            status=row[9],
            error_message=row[10],
            discovered_at=row[11],
            hashed_at=row[12],
        )

    def update_file(self, file_id: int, **fields: object) -> None:
        """Update arbitrary fields on a file record.

        Raises ValueError if any field name is not a valid column.
        """
        invalid = set(fields.keys()) - _FILE_COLUMNS
        if invalid:
            raise ValueError(f"Invalid field(s): {', '.join(sorted(invalid))}")
        if not fields:
            return
        set_clause = ", ".join(f"{col} = ?" for col in fields)
        values = list(fields.values())
        values.append(file_id)
        self._conn.execute(
            f"UPDATE files SET {set_clause} WHERE id = ?",  # noqa: S608
            values,
        )
        self._conn.commit()

    def query_files_by_status(self, status: str) -> list[FileRecord]:
        """Return all files matching the given status."""
        rows = self._conn.execute(
            "SELECT id, source_path, source_type, file_size, file_modify_date, "
            "md5_hash, capture_date, camera_model, target_path, status, "
            "error_message, discovered_at, hashed_at "
            "FROM files WHERE status = ?",
            (status,),
        ).fetchall()
        return [
            FileRecord(
                id=r[0],
                source_path=r[1],
                source_type=r[2],
                file_size=r[3],
                file_modify_date=r[4],
                md5_hash=r[5],
                capture_date=r[6],
                camera_model=r[7],
                target_path=r[8],
                status=r[9],
                error_message=r[10],
                discovered_at=r[11],
                hashed_at=r[12],
            )
            for r in rows
        ]

    def query_files_by_ids(self, ids: list[int]) -> list[FileRecord]:
        """Return FileRecords matching the given IDs, in the same order.

        Silently skips IDs not found.  Chunks into batches of 999 to
        stay within SQLite's variable limit.
        """
        if not ids:
            return []

        rows_by_id: dict[int, FileRecord] = {}
        batch_size = 999
        for start in range(0, len(ids), batch_size):
            batch = ids[start : start + batch_size]
            placeholders = ", ".join("?" for _ in batch)
            rows = self._conn.execute(
                "SELECT id, source_path, source_type, file_size, file_modify_date, "
                "md5_hash, capture_date, camera_model, target_path, status, "
                f"error_message, discovered_at, hashed_at FROM files WHERE id IN ({placeholders})",  # noqa: S608
                batch,
            ).fetchall()
            for r in rows:
                rows_by_id[r[0]] = FileRecord(
                    id=r[0],
                    source_path=r[1],
                    source_type=r[2],
                    file_size=r[3],
                    file_modify_date=r[4],
                    md5_hash=r[5],
                    capture_date=r[6],
                    camera_model=r[7],
                    target_path=r[8],
                    status=r[9],
                    error_message=r[10],
                    discovered_at=r[11],
                    hashed_at=r[12],
                )

        return [rows_by_id[i] for i in ids if i in rows_by_id]

    def delete_files_by_status(self, statuses: list[str]) -> None:
        """Delete all file records matching any of the given statuses."""
        if not statuses:
            return
        placeholders = ", ".join("?" for _ in statuses)
        self._conn.execute(
            f"DELETE FROM files WHERE status IN ({placeholders})",  # noqa: S608
            statuses,
        )
        self._conn.commit()

    def delete_file(self, file_id: int) -> None:
        """Delete a single file record by ID."""
        self._conn.execute("DELETE FROM files WHERE id = ?", (file_id,))
        self._conn.commit()

    # --- Atomic import ---

    def import_file(
        self,
        file_id: int,
        library_id: int,
        relative_path: str,
        file_size: int,
        md5_hash: str,
        capture_date: str | None,
        camera_model: str | None,
        original_path: str | None = None,
    ) -> EntryRecord:
        """Atomically create an entry and mark the file as imported.

        Both operations happen in a single transaction. If either fails,
        neither change persists.
        """
        now = _now()
        try:
            self._conn.execute("BEGIN")
            cur = self._conn.execute(
                "INSERT INTO entries "
                "(library_id, relative_path, file_size, md5_hash, capture_date, camera_model, imported_at, original_path) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    library_id,
                    relative_path,
                    file_size,
                    md5_hash,
                    capture_date,
                    camera_model,
                    now,
                    original_path,
                ),
            )
            entry_id = cur.lastrowid
            if entry_id is None:
                raise RuntimeError("Failed to get entry ID during import")
            self._conn.execute(
                "UPDATE files SET status = 'imported' WHERE id = ?",
                (file_id,),
            )
            self._conn.execute("COMMIT")
        except Exception:
            self._conn.execute("ROLLBACK")
            raise
        return EntryRecord(
            id=entry_id,
            library_id=library_id,
            relative_path=relative_path,
            file_size=file_size,
            md5_hash=md5_hash,
            capture_date=capture_date,
            camera_model=camera_model,
            imported_at=now,
            original_path=original_path,
        )
