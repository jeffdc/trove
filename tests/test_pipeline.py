"""Tests for trove.pipeline shared pipeline stages."""

from __future__ import annotations

import errno
import hashlib
import logging
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from trove.config import LibraryConfig
from trove.metadata import FileMetadata

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _create_file(directory: Path, name: str, content: bytes = b"test data") -> Path:
    """Create a file in directory and return its path."""
    p = directory / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(content)
    return p


def _mtime_iso(path: Path) -> str:
    """Return file mtime as ISO 8601 UTC string (matches DB convention)."""
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# TestDiscoverAndPersist
# ---------------------------------------------------------------------------


class TestDiscoverAndPersist:
    def test_inserts_and_returns_ids(self, db, tmp_path):
        """Discover files, verify IDs returned and records in DB."""
        from trove.pipeline import discover_and_persist

        _create_file(tmp_path, "photo1.jpg")
        _create_file(tmp_path, "photo2.jpg")

        config = LibraryConfig()
        ids, skip_count = discover_and_persist(tmp_path, db, config)

        assert len(ids) == 2
        assert skip_count == 0

        # Verify records exist in DB
        records = db.query_files_by_ids(ids)
        assert len(records) == 2
        for rec in records:
            assert rec.status == "discovered"
            assert rec.source_path.startswith(str(tmp_path))

    def test_skips_existing_unchanged(self, db, tmp_path):
        """Re-discover same files (unchanged size+mtime), returns empty, skip_count incremented."""
        from trove.pipeline import discover_and_persist

        _create_file(tmp_path, "photo1.jpg")
        config = LibraryConfig()

        # First run — inserts the file
        ids1, skip1 = discover_and_persist(tmp_path, db, config)
        assert len(ids1) == 1
        assert skip1 == 0

        # Second run — same file unchanged
        ids2, skip2 = discover_and_persist(tmp_path, db, config)
        assert len(ids2) == 0
        assert skip2 == 1

    def test_resets_changed_files(self, db, tmp_path):
        """Change file content (different size), re-discover -> file reset with its ID returned."""
        from trove.pipeline import discover_and_persist

        p = _create_file(tmp_path, "photo1.jpg", content=b"short")
        config = LibraryConfig()

        ids1, _ = discover_and_persist(tmp_path, db, config)
        original_id = ids1[0]

        # Mark as hashed to confirm reset clears it
        db.update_file(original_id, status="hashed", md5_hash="abc123")

        # Change file content (different size)
        p.write_bytes(b"much longer content now")

        ids2, skip2 = discover_and_persist(tmp_path, db, config)
        assert len(ids2) == 1
        assert skip2 == 0

        # The returned ID should be the same record, now reset
        rec = db.query_files_by_ids([ids2[0]])[0]
        assert rec.status == "discovered"
        assert rec.md5_hash is None
        assert rec.capture_date is None
        assert rec.camera_model is None
        assert rec.target_path is None

    def test_skips_skip_paths(self, db, tmp_path):
        """Pass skip_paths set, those paths excluded from insertion."""
        from trove.pipeline import discover_and_persist

        _create_file(tmp_path, "photo1.jpg")
        _create_file(tmp_path, "photo2.jpg")

        config = LibraryConfig()
        skip_paths = {"photo1.jpg"}

        ids, skip_count = discover_and_persist(tmp_path, db, config, skip_paths=skip_paths)
        assert len(ids) == 1
        assert skip_count == 0

        rec = db.query_files_by_ids(ids)[0]
        assert rec.source_path.endswith("photo2.jpg")

    def test_known_paths_skips_walk(self, db, tmp_path):
        """Provide known_paths, verify discover_files is not called and those paths are used."""
        from trove.pipeline import discover_and_persist

        p = _create_file(tmp_path, "photo1.jpg")
        config = LibraryConfig()

        with patch("trove.pipeline.discover_files") as mock_discover:
            ids, skip_count = discover_and_persist(
                tmp_path,
                db,
                config,
                known_paths=[p],
            )

            mock_discover.assert_not_called()
            assert len(ids) == 1
            assert skip_count == 0


# ---------------------------------------------------------------------------
# TestHashFiles
# ---------------------------------------------------------------------------


class TestHashFiles:
    def test_updates_records(self, db, tmp_path):
        """Hash a set of IDs, verify md5_hash + status='hashed' in DB."""
        from trove.pipeline import hash_files

        p = _create_file(tmp_path, "photo1.jpg", content=b"unique content for hashing")
        rec = db.insert_file(
            source_path=str(p),
            source_type="local",
            file_size=p.stat().st_size,
            file_modify_date=_mtime_iso(p),
        )

        _result_ids = hash_files([rec.id], db)

        updated = db.query_files_by_ids([rec.id])[0]
        assert updated.md5_hash is not None
        assert len(updated.md5_hash) == 32  # MD5 hex length
        assert updated.status == "hashed"
        assert updated.hashed_at is not None

    def test_returns_same_ids(self, db, tmp_path):
        """Returns the same ID list that was passed in."""
        from trove.pipeline import hash_files

        p1 = _create_file(tmp_path, "a.jpg", content=b"aaa")
        p2 = _create_file(tmp_path, "b.jpg", content=b"bbb")
        r1 = db.insert_file(str(p1), "local", p1.stat().st_size, _mtime_iso(p1))
        r2 = db.insert_file(str(p2), "local", p2.stat().st_size, _mtime_iso(p2))

        input_ids = [r1.id, r2.id]
        output_ids = hash_files(input_ids, db)
        assert output_ids == input_ids

    def test_skips_missing_file(self, db, tmp_path):
        """Missing file is logged, quarantined, and excluded from returned IDs."""
        from trove.pipeline import hash_files

        p1 = _create_file(tmp_path, "exists.jpg", content=b"real")
        r1 = db.insert_file(str(p1), "local", p1.stat().st_size, _mtime_iso(p1))

        # Insert record for a file that doesn't exist
        r2 = db.insert_file(str(tmp_path / "gone.jpg"), "local", 100, "2024-01-01T00:00:00+00:00")

        output_ids = hash_files([r1.id, r2.id], db)

        # Only the existing file should be returned
        assert output_ids == [r1.id]

        # The missing file should be quarantined
        missing = db.query_files_by_ids([r2.id])[0]
        assert missing.status == "quarantined"
        assert missing.error_message == "hash_failed"

        # The existing file should be hashed normally
        hashed = db.query_files_by_ids([r1.id])[0]
        assert hashed.status == "hashed"
        assert hashed.md5_hash is not None


# ---------------------------------------------------------------------------
# TestExtractMetadata
# ---------------------------------------------------------------------------


class TestExtractMetadata:
    def test_splits_hashed_and_quarantined(self, db, tmp_path):
        """Mock exiftool: one file with date, one without + invalid mtime -> returns both lists."""
        from trove.pipeline import extract_metadata

        p1 = _create_file(tmp_path, "dated.jpg")
        p2 = _create_file(tmp_path, "undated.jpg")

        # Insert with an mtime that's out of range (year < 1990) for the undated file
        r1 = db.insert_file(str(p1), "local", p1.stat().st_size, _mtime_iso(p1))
        r2 = db.insert_file(str(p2), "local", p2.stat().st_size, "1980-01-01T00:00:00+00:00")

        # Update both to hashed status
        db.update_file(r1.id, status="hashed", md5_hash="aaa")
        db.update_file(r2.id, status="hashed", md5_hash="bbb")

        # Mock extract_metadata_chunked: dated.jpg has EXIF, undated.jpg has none
        mock_metadata = {
            str(p1): FileMetadata(
                capture_date="2024-06-15T10:30:00",
                camera_model="Canon EOS R5",
                date_source="DateTimeOriginal",
            ),
            str(p2): FileMetadata(
                capture_date=None,
                camera_model=None,
                date_source=None,
            ),
        }

        config = LibraryConfig()

        with patch("trove.pipeline.extract_metadata_chunked", return_value=mock_metadata):
            hashed_ids, quarantined_ids = extract_metadata([r1.id, r2.id], db, config)

        assert r1.id in hashed_ids
        assert r2.id in quarantined_ids

        # Verify DB state
        dated_rec = db.query_files_by_ids([r1.id])[0]
        assert dated_rec.capture_date == "2024-06-15T10:30:00"
        assert dated_rec.camera_model == "Canon EOS R5"

        undated_rec = db.query_files_by_ids([r2.id])[0]
        assert undated_rec.status == "quarantined"
        assert undated_rec.error_message == "no_date"

    def test_mtime_fallback(self, db, tmp_path):
        """No EXIF date, valid mtime -> file stays hashed, not quarantined."""
        from trove.pipeline import extract_metadata

        p = _create_file(tmp_path, "no_exif.jpg")
        # Use the real mtime which should be current year (valid)
        r = db.insert_file(str(p), "local", p.stat().st_size, _mtime_iso(p))
        db.update_file(r.id, status="hashed", md5_hash="ccc")

        mock_metadata = {
            str(p): FileMetadata(capture_date=None, camera_model=None, date_source=None),
        }

        config = LibraryConfig()

        with patch("trove.pipeline.extract_metadata_chunked", return_value=mock_metadata):
            hashed_ids, quarantined_ids = extract_metadata([r.id], db, config)

        assert r.id in hashed_ids
        assert r.id not in quarantined_ids

        rec = db.query_files_by_ids([r.id])[0]
        assert rec.capture_date is not None
        assert rec.status != "quarantined"

    def test_quarantines_invalid_mtime(self, db, tmp_path):
        """No EXIF date, mtime year < 2000 -> quarantined."""
        from trove.pipeline import extract_metadata

        p = _create_file(tmp_path, "old.jpg")
        # Insert with an ancient mtime
        r = db.insert_file(str(p), "local", p.stat().st_size, "1985-03-10T12:00:00+00:00")
        db.update_file(r.id, status="hashed", md5_hash="ddd")

        mock_metadata = {
            str(p): FileMetadata(capture_date=None, camera_model=None, date_source=None),
        }

        config = LibraryConfig()

        with patch("trove.pipeline.extract_metadata_chunked", return_value=mock_metadata):
            hashed_ids, quarantined_ids = extract_metadata([r.id], db, config)

        assert r.id in quarantined_ids
        assert r.id not in hashed_ids

        rec = db.query_files_by_ids([r.id])[0]
        assert rec.status == "quarantined"
        assert rec.error_message == "no_date"

    def test_logs_warning_for_missing_files(self, db, tmp_path, caplog):
        """When extract_metadata_chunked omits a file from the map, log a warning."""
        from trove.pipeline import extract_metadata

        p1 = _create_file(tmp_path, "good.jpg")
        p2 = _create_file(tmp_path, "missing_from_map.jpg")

        r1 = db.insert_file(str(p1), "local", p1.stat().st_size, _mtime_iso(p1))
        r2 = db.insert_file(str(p2), "local", p2.stat().st_size, _mtime_iso(p2))
        db.update_file(r1.id, status="hashed", md5_hash="aaa")
        db.update_file(r2.id, status="hashed", md5_hash="bbb")

        # Return metadata only for p1; p2 is absent (simulates exiftool crash)
        mock_metadata = {
            str(p1): FileMetadata(
                capture_date="2024-06-15T10:30:00",
                camera_model="Canon EOS R5",
                date_source="DateTimeOriginal",
            ),
            # str(p2) deliberately missing
        }

        config = LibraryConfig()

        with (
            caplog.at_level(logging.WARNING, logger="trove.pipeline"),
            patch("trove.pipeline.extract_metadata_chunked", return_value=mock_metadata),
        ):
            hashed_ids, quarantined_ids = extract_metadata(
                [r1.id, r2.id],
                db,
                config,
            )

        # p2 should trigger a warning about missing metadata
        assert any(
            "missing_from_map.jpg" in msg and "no metadata returned" in msg.lower() for msg in caplog.messages
        ), f"Expected warning about missing file, got: {caplog.messages}"

        # p1 should still be processed normally
        assert r1.id in hashed_ids


# ---------------------------------------------------------------------------
# TestComputePaths
# ---------------------------------------------------------------------------


class TestComputePaths:
    def test_updates_target_path(self, db, tmp_path):
        """Verify target_path set in DB for each ID."""
        from trove.pipeline import compute_paths

        p = _create_file(tmp_path, "sunset.jpg")
        r = db.insert_file(str(p), "local", p.stat().st_size, _mtime_iso(p))
        db.update_file(
            r.id,
            status="hashed",
            md5_hash="eee",
            capture_date="2024-06-15T10:30:00",
            camera_model="Canon EOS R5",
        )

        config = LibraryConfig()
        result_ids = compute_paths([r.id], db, config)
        assert result_ids == [r.id]

        rec = db.query_files_by_ids([r.id])[0]
        assert rec.target_path is not None
        # Default config: %Y/%m with camera model
        assert "2024" in rec.target_path
        assert "06" in rec.target_path
        assert "Canon_EOS_R5" in rec.target_path
        assert "sunset.jpg" in rec.target_path


# ---------------------------------------------------------------------------
# TestClassifyForImport
# ---------------------------------------------------------------------------


class TestClassifyForImport:
    def test_batch_dedup(self, db, library, tmp_path):
        """3 files same hash -> 1 to_import, 2 batch dups."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content = b"identical content"
        content_hash = hashlib.md5(content).hexdigest()

        ids = []
        for name in ["a.jpg", "b.jpg", "c.jpg"]:
            (source / name).write_bytes(content)
            f = db.insert_file(str(source / name), "local", len(content), "2024-01-15T10:30:00")
            db.update_file(
                f.id,
                md5_hash=content_hash,
                status="hashed",
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon",
                target_path=f"2024/01/Canon/{name}",
            )
            ids.append(f.id)

        config = LibraryConfig()
        plan = classify_for_import(ids, db, library, config)

        assert len(plan.to_import) == 1
        assert len(plan.duplicates_in_batch) == 2

    def test_library_dedup(self, db, library, tmp_path):
        """File hash matches existing entry -> library dup."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content = b"already in library"
        content_hash = hashlib.md5(content).hexdigest()

        # Pre-existing entry in library
        db.create_entry(
            library.id, "2023/06/Canon/existing.jpg", len(content), content_hash, "2023-06-01T00:00:00", "Canon"
        )

        # Scanned file with same hash
        photo = source / "photo.jpg"
        photo.write_bytes(content)
        f = db.insert_file(str(photo), "local", len(content), "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_import([f.id], db, library, config)

        assert len(plan.duplicates_in_library) == 1
        assert len(plan.to_import) == 0

    def test_unique_file(self, db, library, tmp_path):
        """Unique file -> to_import."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content = b"unique photo data"
        content_hash = hashlib.md5(content).hexdigest()

        photo = source / "photo.jpg"
        photo.write_bytes(content)
        f = db.insert_file(str(photo), "local", len(content), "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_import([f.id], db, library, config)

        assert len(plan.to_import) == 1
        assert len(plan.duplicates_in_batch) == 0
        assert len(plan.duplicates_in_library) == 0

    def test_only_uses_given_ids(self, db, library, tmp_path):
        """Insert extra hashed files in DB outside ID list -> they're ignored."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content_a = b"file A content"
        hash_a = hashlib.md5(content_a).hexdigest()
        content_b = b"file B content"
        hash_b = hashlib.md5(content_b).hexdigest()

        (source / "a.jpg").write_bytes(content_a)
        fa = db.insert_file(str(source / "a.jpg"), "local", len(content_a), "2024-01-15T10:30:00")
        db.update_file(
            fa.id,
            md5_hash=hash_a,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/a.jpg",
        )

        (source / "b.jpg").write_bytes(content_b)
        fb = db.insert_file(str(source / "b.jpg"), "local", len(content_b), "2024-01-15T10:30:00")
        db.update_file(
            fb.id,
            md5_hash=hash_b,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/b.jpg",
        )

        config = LibraryConfig()
        # Only pass fa.id — fb should be ignored
        plan = classify_for_import([fa.id], db, library, config)

        assert len(plan.to_import) == 1
        assert plan.to_import[0].id == fa.id
        # fb must not appear anywhere in the plan
        all_ids_in_plan = (
            [f.id for f in plan.to_import]
            + [f.id for f in plan.duplicates_in_batch]
            + [f.id for f in plan.duplicates_in_library]
        )
        assert fb.id not in all_ids_in_plan

    def test_skipped_files_without_target_path(self, db, library, tmp_path):
        """Files without target_path are counted as skipped."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        (source / "a.jpg").write_bytes(b"data")
        f = db.insert_file(str(source / "a.jpg"), "local", 4, "2024-01-15T10:30:00")
        db.update_file(f.id, md5_hash="abc123", status="hashed")
        # No target_path set

        config = LibraryConfig()
        plan = classify_for_import([f.id], db, library, config)

        assert plan.skipped == 1
        assert len(plan.to_import) == 0

    def test_path_conflict_count(self, db, library, tmp_path):
        """Files whose target_path already has an entry -> path_conflicts counted."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content_existing = b"existing content"
        hash_existing = hashlib.md5(content_existing).hexdigest()
        content_new = b"new content different"
        hash_new = hashlib.md5(content_new).hexdigest()

        # Pre-existing entry at a specific path
        db.create_entry(
            library.id, "2024/01/Canon/photo.jpg", len(content_existing), hash_existing, "2024-01-15T10:30:00", "Canon"
        )

        (source / "new.jpg").write_bytes(content_new)
        f = db.insert_file(str(source / "new.jpg"), "local", len(content_new), "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash=hash_new,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_import([f.id], db, library, config)

        assert plan.path_conflicts == 1
        assert len(plan.to_import) == 1

    def test_library_dedup_backfill(self, db, library, tmp_path):
        """Entry without hash, same size -> hash backfilled, detected as dup."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content = b"backfill test content"
        content_hash = hashlib.md5(content).hexdigest()

        # Create a file in the library location with no hash in the entry
        lib_file = Path(library.location) / "2023/06/Canon/existing.jpg"
        lib_file.parent.mkdir(parents=True, exist_ok=True)
        lib_file.write_bytes(content)
        db.create_entry(
            library.id, "2023/06/Canon/existing.jpg", len(content), None, "2023-06-01T00:00:00", "Canon"
        )  # no hash

        # Incoming file same content
        photo = source / "photo.jpg"
        photo.write_bytes(content)
        f = db.insert_file(str(photo), "local", len(content), "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_import([f.id], db, library, config)

        assert len(plan.duplicates_in_library) == 1
        assert len(plan.to_import) == 0

        # Verify the entry hash was backfilled
        entries = db.get_entries_by_size(library.id, len(content))
        assert entries[0].md5_hash == content_hash


# ---------------------------------------------------------------------------
# TestClassifyForInit
# ---------------------------------------------------------------------------


class TestClassifyForInit:
    def test_correct_path(self, db, library):
        """File at target path -> already_correct."""
        from trove.pipeline import classify_for_init

        lib_path = Path(library.location)
        # Create a file that's already at its correct target path
        file_path = lib_path / "2024/01/Canon/photo.jpg"
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(b"photo data")

        f = db.insert_file(str(file_path), "local", 10, "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash="abc123",
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_init([f.id], [], db, library, config)

        assert len(plan.already_correct) == 1
        assert plan.already_correct[0].action == "index"
        assert plan.already_correct[0].relative_path == "2024/01/Canon/photo.jpg"

    def test_needs_move(self, db, library):
        """File at wrong path -> needs_move."""
        from trove.pipeline import classify_for_init

        lib_path = Path(library.location)
        # File is at wrong path
        file_path = lib_path / "unsorted/photo.jpg"
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(b"photo data")

        f = db.insert_file(str(file_path), "local", 10, "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash="abc123",
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_init([f.id], [], db, library, config)

        assert len(plan.needs_move) == 1
        assert plan.needs_move[0].action == "move"
        assert plan.needs_move[0].relative_path == "unsorted/photo.jpg"
        assert plan.needs_move[0].target_path == "2024/01/Canon/photo.jpg"

    def test_quarantine(self, db, library):
        """Quarantined file -> quarantine action with quarantine target path."""
        from trove.pipeline import classify_for_init

        lib_path = Path(library.location)
        file_path = lib_path / "random/IMG_1234.jpg"
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(b"no date photo")

        f = db.insert_file(str(file_path), "local", 13, "2024-01-15T10:30:00")
        db.update_file(f.id, status="quarantined", error_message="no_date")

        config = LibraryConfig()
        plan = classify_for_init([], [f.id], db, library, config)

        assert len(plan.quarantined) == 1
        assert plan.quarantined[0].action == "quarantine"
        assert plan.quarantined[0].target_path.startswith("quarantine/")
        assert "IMG_1234.jpg" in plan.quarantined[0].target_path

    def test_path_conflict_suffix(self, db, library):
        """Two files same target -> second gets -1 suffix."""
        from trove.pipeline import classify_for_init

        lib_path = Path(library.location)

        # Two files that both want the same target path (but are at different current paths)
        file_a = lib_path / "unsorted/a.jpg"
        file_a.parent.mkdir(parents=True, exist_ok=True)
        file_a.write_bytes(b"content a")

        file_b = lib_path / "unsorted/b.jpg"
        file_b.write_bytes(b"content b")

        fa = db.insert_file(str(file_a), "local", 9, "2024-01-15T10:30:00")
        db.update_file(
            fa.id,
            md5_hash="hash_a",
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        fb = db.insert_file(str(file_b), "local", 9, "2024-01-15T10:30:00")
        db.update_file(
            fb.id,
            md5_hash="hash_b",
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_init([fa.id, fb.id], [], db, library, config)

        all_targets = [a.target_path for a in plan.needs_move]
        assert "2024/01/Canon/photo.jpg" in all_targets
        assert "2024/01/Canon/photo-1.jpg" in all_targets

    def test_existing_entries_claimed(self, db, library):
        """Existing library entries should be treated as claimed paths."""
        from trove.pipeline import classify_for_init

        lib_path = Path(library.location)

        # Pre-existing entry at the target path
        db.create_entry(library.id, "2024/01/Canon/photo.jpg", 100, "existing_hash", "2024-01-15T10:30:00", "Canon")

        # File that wants the same target path
        file_path = lib_path / "unsorted/photo.jpg"
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_bytes(b"new photo")

        f = db.insert_file(str(file_path), "local", 9, "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash="new_hash",
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = classify_for_init([f.id], [], db, library, config)

        assert len(plan.needs_move) == 1
        # Should get a suffixed path since the original is claimed
        assert plan.needs_move[0].target_path == "2024/01/Canon/photo-1.jpg"


# ---------------------------------------------------------------------------
# TestMoveFile
# ---------------------------------------------------------------------------


class TestMoveFile:
    def test_move_same_filesystem(self, tmp_path):
        """Rename within tmp_path: file moved, original gone, correct hash returned."""
        from trove.pipeline import move_file

        content = b"same filesystem content"
        expected_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "source" / "photo.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(content)

        dest = tmp_path / "dest" / "photo.jpg"

        success, result_hash = move_file(src, dest, expected_hash)

        assert success is True
        assert result_hash == expected_hash
        assert dest.exists()
        assert dest.read_bytes() == content
        assert not src.exists()

    def test_move_cross_filesystem(self, tmp_path):
        """Mock os.rename to raise OSError(errno.EXDEV): copy+verify+delete fallback."""
        from trove.pipeline import move_file, rename_path

        content = b"cross filesystem content"
        expected_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "source" / "photo.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(content)

        dest = tmp_path / "dest" / "photo.jpg"

        def fake_run_with_timeout(fn, *args, **kwargs):
            kwargs.pop("timeout", None)
            if fn is rename_path:
                raise OSError(errno.EXDEV, "cross-device link")
            return fn(*args)

        with patch("trove.pipeline.run_with_timeout", side_effect=fake_run_with_timeout):
            success, result_hash = move_file(src, dest, expected_hash)

        assert success is True
        assert result_hash == expected_hash
        assert dest.exists()
        assert dest.read_bytes() == content
        assert not src.exists()

    def test_move_copy_verify_failure(self, tmp_path):
        """Cross-filesystem move where copy hash doesn't match -> returns False, source preserved."""
        from trove.pipeline import move_file, rename_path

        content = b"verify failure content"
        expected_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "source" / "photo.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(content)

        dest = tmp_path / "dest" / "photo.jpg"

        def fake_run_with_timeout(fn, *args, **kwargs):
            kwargs.pop("timeout", None)
            if fn is rename_path:
                raise OSError(errno.EXDEV, "cross-device link")
            return fn(*args)

        with (
            patch("trove.pipeline.run_with_timeout", side_effect=fake_run_with_timeout),
            patch("trove.pipeline._copy_and_verify", return_value=False),
        ):
            success, result_hash = move_file(src, dest, expected_hash)

        assert success is False
        assert src.exists()  # Source preserved on failure

    def test_move_cross_filesystem_unlink_fails(self, tmp_path):
        """Cross-filesystem copy succeeds but source.unlink() fails -> still returns success."""
        from trove.pipeline import move_file, rename_path, unlink_path

        content = b"unlink failure content"
        expected_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "source" / "photo.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(content)

        dest = tmp_path / "dest" / "photo.jpg"

        def fake_run_with_timeout(fn, *args, **kwargs):
            kwargs.pop("timeout", None)
            if fn is rename_path:
                raise OSError(errno.EXDEV, "cross-device link")
            if fn is unlink_path:
                raise PermissionError("not allowed")
            return fn(*args)

        with (
            patch("trove.pipeline.run_with_timeout", side_effect=fake_run_with_timeout),
            patch("trove.pipeline._copy_and_verify", return_value=True),
        ):
            success, result_hash = move_file(src, dest, expected_hash)

        assert success is True
        assert result_hash == expected_hash

    def test_move_cross_filesystem_unlink_fails_logs_warning(self, tmp_path, caplog):
        """Cross-filesystem copy succeeds but source.unlink() fails -> logs warning."""
        from trove.pipeline import move_file, rename_path, unlink_path

        content = b"unlink failure content"
        expected_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "source" / "photo.jpg"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(content)

        dest = tmp_path / "dest" / "photo.jpg"

        def fake_run_with_timeout(fn, *args, **kwargs):
            kwargs.pop("timeout", None)
            if fn is rename_path:
                raise OSError(errno.EXDEV, "cross-device link")
            if fn is unlink_path:
                raise PermissionError("not allowed")
            return fn(*args)

        with (
            patch("trove.pipeline.run_with_timeout", side_effect=fake_run_with_timeout),
            patch("trove.pipeline._copy_and_verify", return_value=True),
            caplog.at_level(logging.WARNING, logger="trove.pipeline"),
        ):
            success, result_hash = move_file(src, dest, expected_hash)

        assert success is True
        assert result_hash == expected_hash
        assert any(
            "could not remove source" in msg.lower()
            or "unable to remove source" in msg.lower()
            or "failed to remove source" in msg.lower()
            for msg in caplog.messages
        ), f"Expected warning about source removal, got: {caplog.messages}"

    def test_move_creates_parent_dirs(self, tmp_path):
        """Destination directory doesn't exist -> created automatically."""
        from trove.pipeline import move_file

        content = b"parent dir test"
        expected_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "photo.jpg"
        src.write_bytes(content)

        dest = tmp_path / "a" / "b" / "c" / "photo.jpg"

        success, result_hash = move_file(src, dest, expected_hash)

        assert success is True
        assert dest.exists()
        assert dest.read_bytes() == content
        assert not src.exists()


# ---------------------------------------------------------------------------
# TestCopyAndVerify
# ---------------------------------------------------------------------------


class TestCopyAndVerify:
    def test_preserves_preexisting_file(self, tmp_path):
        """Pre-existing dest file must NOT be deleted on hash mismatch."""
        from trove.pipeline import _copy_and_verify

        src = tmp_path / "source.jpg"
        src.write_bytes(b"source content")

        dest = tmp_path / "dest.jpg"
        original_content = b"precious pre-existing data"
        dest.write_bytes(original_content)

        wrong_hash = "0" * 32  # will not match

        result = _copy_and_verify(src, dest, wrong_hash)

        assert result is False
        assert dest.exists(), "Pre-existing dest file was deleted"
        assert dest.read_bytes() == original_content, "Pre-existing dest file was modified"

    def test_cleans_up_own_file_on_failure(self, tmp_path):
        """When dest did not exist before, a failed copy should be cleaned up."""
        from trove.pipeline import _copy_and_verify

        src = tmp_path / "source.jpg"
        src.write_bytes(b"source content")

        dest = tmp_path / "dest.jpg"
        assert not dest.exists()

        wrong_hash = "0" * 32  # will not match

        result = _copy_and_verify(src, dest, wrong_hash)

        assert result is False
        assert not dest.exists(), "Failed copy was not cleaned up"

    def test_successful_copy(self, tmp_path):
        """Successful copy returns True and dest has correct content."""
        from trove.pipeline import _copy_and_verify

        content = b"good content"
        correct_hash = hashlib.md5(content).hexdigest()

        src = tmp_path / "source.jpg"
        src.write_bytes(content)

        dest = tmp_path / "dest.jpg"

        result = _copy_and_verify(src, dest, correct_hash)

        assert result is True
        assert dest.exists()
        assert dest.read_bytes() == content


# ---------------------------------------------------------------------------
# TestResumeAfterCrash
# ---------------------------------------------------------------------------


class TestResumeAfterCrash:
    """Verify that stale intermediate files from a crashed run are handled correctly."""

    def test_stale_hashed_files_picked_up_by_classify(self, db, library, tmp_path):
        """Files left at status='hashed' with target_path from a previous run
        should be usable by classify_for_import when passed explicitly."""
        from trove.pipeline import classify_for_import

        source = tmp_path / "source"
        source.mkdir()
        content = b"stale hashed content"
        content_hash = hashlib.md5(content).hexdigest()

        photo = source / "photo.jpg"
        photo.write_bytes(content)

        # Simulate a previous run that hashed + extracted + computed paths, then crashed
        f = db.insert_file(str(photo), "local", len(content), "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        # On resume: discover_and_persist would return [] (file unchanged)
        # but stale file should be found by status query and passed to classify
        config = LibraryConfig()
        plan = classify_for_import([f.id], db, library, config)

        assert len(plan.to_import) == 1
        assert plan.to_import[0].source_path == str(photo)

    def test_discover_skips_but_stale_files_still_in_db(self, db, tmp_path):
        """discover_and_persist skips files already in DB, but they remain queryable."""
        from trove.pipeline import discover_and_persist

        photo = _create_file(tmp_path, "photo.jpg", b"already tracked")

        # Simulate previous run: file already in DB
        existing = db.insert_file(str(photo), "local", photo.stat().st_size, _mtime_iso(photo))
        db.update_file(existing.id, status="hashed", md5_hash="abc123")

        config = LibraryConfig()
        ids, skip_count = discover_and_persist(tmp_path, db, config)

        # New IDs should be empty — file was skipped
        assert ids == []
        assert skip_count == 1

        # But the stale file should still be queryable by status
        stale = db.query_files_by_status("hashed")
        assert len(stale) == 1
        assert stale[0].id == existing.id

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_stale_hashed_without_metadata_gets_extracted(self, mock_meta, db, tmp_path):
        """A file stuck at 'hashed' without capture_date gets metadata extracted on resume."""
        from trove.pipeline import compute_paths, extract_metadata

        photo = _create_file(tmp_path, "photo.jpg", b"needs metadata")

        # Simulate crash after hashing but before metadata
        f = db.insert_file(str(photo), "local", photo.stat().st_size, _mtime_iso(photo))
        db.update_file(f.id, status="hashed", md5_hash="abc123")
        assert db.query_files_by_ids([f.id])[0].capture_date is None

        mock_meta.return_value = {str(photo): FileMetadata("2024-06-15T10:30:00", "Canon", "DateTimeOriginal")}

        config = LibraryConfig()
        hashed_ids, quarantined_ids = extract_metadata([f.id], db, config)
        compute_paths(hashed_ids, db, config)

        assert f.id in hashed_ids
        rec = db.query_files_by_ids([f.id])[0]
        assert rec.capture_date == "2024-06-15T10:30:00"
        assert rec.target_path is not None
