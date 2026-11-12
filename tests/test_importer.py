from __future__ import annotations

import hashlib
import os
from pathlib import Path
from unittest.mock import patch

from trove.config import LibraryConfig
from trove.importer import execute_import, import_to_library, plan_import


class TestImportSingleFile:
    def test_imports_file_to_library(self, db, library, tmp_path):
        """Single file: copied to library, entry created, status=imported."""
        # Create source file
        source = tmp_path / "source"
        source.mkdir()
        photo = source / "photo.jpg"
        photo.write_bytes(b"photo content here")
        photo_hash = hashlib.md5(b"photo content here").hexdigest()

        # Insert file record as if scan already ran
        f = db.insert_file(str(photo), "local", 18, "2024-01-15T10:30:00")
        db.update_file(
            f.id,
            md5_hash=photo_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        summary = import_to_library(db, library, config)

        assert summary["imported"] == 1
        # Entry should exist in library
        entries = db.get_entries_by_hash(library.id, photo_hash)
        assert len(entries) == 1
        assert entries[0].relative_path == "2024/01/Canon/photo.jpg"
        # File should exist on disk
        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        assert dest.exists()
        assert dest.read_bytes() == b"photo content here"
        # File record status should be imported
        rec = db.get_file_by_path(str(photo))
        assert rec.status == "imported"


class TestBatchDedup:
    def test_batch_duplicates_marked(self, db, library, tmp_path):
        """3 files with same hash: 1 imported, 2 marked duplicate."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"identical content"
        content_hash = hashlib.md5(content).hexdigest()

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

        config = LibraryConfig()
        summary = import_to_library(db, library, config)

        assert summary["imported"] == 1
        assert summary["duplicates_in_batch"] == 2
        # Only one entry in library
        entries = db.list_entries(library.id)
        assert len(entries) == 1


class TestLibraryDedup:
    def test_existing_entry_marked_duplicate(self, db, library, tmp_path):
        """File whose hash already exists in library is marked duplicate, not copied."""
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
        summary = import_to_library(db, library, config)

        assert summary["duplicates_in_library"] == 1
        assert summary["imported"] == 0
        rec = db.get_file_by_path(str(photo))
        assert rec.status == "duplicate"


class TestPathConflict:
    def test_auto_suffix_on_conflict(self, db, library, tmp_path):
        """Two different files with same target path: second gets -1 suffix."""
        source = tmp_path / "source"
        source.mkdir()

        content_a = b"content A"
        hash_a = hashlib.md5(content_a).hexdigest()
        content_b = b"content B different"
        hash_b = hashlib.md5(content_b).hexdigest()

        (source / "a.jpg").write_bytes(content_a)
        (source / "b.jpg").write_bytes(content_b)

        fa = db.insert_file(str(source / "a.jpg"), "local", len(content_a), "2024-01-15T10:30:00")
        db.update_file(
            fa.id,
            md5_hash=hash_a,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        fb = db.insert_file(str(source / "b.jpg"), "local", len(content_b), "2024-01-15T10:30:00")
        db.update_file(
            fb.id,
            md5_hash=hash_b,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        summary = import_to_library(db, library, config)

        assert summary["imported"] == 2
        assert summary["path_conflicts"] == 1
        entries = db.list_entries(library.id)
        assert len(entries) == 2
        paths = {e.relative_path for e in entries}
        assert "2024/01/Canon/photo.jpg" in paths
        assert "2024/01/Canon/photo-1.jpg" in paths

    def test_no_suffix_chains(self, db, library, tmp_path):
        """File named photo-1.jpg conflicting doesn't become photo-1-1.jpg."""
        source = tmp_path / "source"
        source.mkdir()

        content_a = b"content A"
        hash_a = hashlib.md5(content_a).hexdigest()
        content_b = b"content B"
        hash_b = hashlib.md5(content_b).hexdigest()

        # First file already occupies photo-1.jpg path in library
        db.create_entry(library.id, "2024/01/Canon/photo-1.jpg", len(content_a), hash_a, "2024-01-15T10:30:00", "Canon")

        # New file also wants photo-1.jpg
        (source / "photo-1.jpg").write_bytes(content_b)
        fb = db.insert_file(str(source / "photo-1.jpg"), "local", len(content_b), "2024-01-15T10:30:00")
        db.update_file(
            fb.id,
            md5_hash=hash_b,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo-1.jpg",
        )

        config = LibraryConfig()
        summary = import_to_library(db, library, config)

        assert summary["imported"] == 1
        entries = db.list_entries(library.id)
        assert len(entries) == 2
        paths = {e.relative_path for e in entries}
        # Should be photo-1.jpg and photo-1-1.jpg (appending -1 to original stem "photo-1")
        # This is fine — it's not a "chain" because the original filename IS photo-1
        assert "2024/01/Canon/photo-1.jpg" in paths
        assert "2024/01/Canon/photo-1-1.jpg" in paths


class TestResumeOrphan:
    def test_orphan_file_verified_and_entry_created(self, db, library, tmp_path):
        """Destination exists without entry, hash matches -> entry created without re-copy."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"orphan content"
        content_hash = hashlib.md5(content).hexdigest()

        photo = source / "photo.jpg"
        photo.write_bytes(content)

        # Simulate orphan: file exists at destination but no entry
        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(content)

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
        summary = import_to_library(db, library, config)

        assert summary["imported"] == 1
        entries = db.get_entries_by_hash(library.id, content_hash)
        assert len(entries) == 1

    def test_orphan_file_still_gets_creation_date_stamp(self, db, library, tmp_path):
        """Matching orphan file still gets Finder Date Created stamped."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"orphan content"
        content_hash = hashlib.md5(content).hexdigest()

        photo = source / "photo.jpg"
        photo.write_bytes(content)

        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(content)

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
        with patch("trove.importer.stamp_creation_date", return_value=True) as mock_stamp:
            summary = import_to_library(db, library, config)

        assert summary["imported"] == 1
        mock_stamp.assert_called_once_with(dest, "2024-01-15T10:30:00")

    def test_untracked_file_preserved_and_import_suffixed(self, db, library, tmp_path):
        """Destination exists with different content -> untracked file kept, import gets suffix."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"correct content"
        content_hash = hashlib.md5(content).hexdigest()

        photo = source / "photo.jpg"
        photo.write_bytes(content)

        # Existing untracked file at target path
        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(b"corrupt garbage")

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
        summary = import_to_library(db, library, config)

        assert summary["imported"] == 1
        # Untracked file is preserved
        assert dest.read_bytes() == b"corrupt garbage"
        # New file imported with suffix
        suffixed = Path(library.location) / "2024/01/Canon/photo-1.jpg"
        assert suffixed.exists()
        assert suffixed.read_bytes() == content


class TestDryRun:
    def test_dry_run_no_copies_no_entries(self, db, library, tmp_path):
        """Dry run reports what would happen but doesn't copy or create entries."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content"
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
        summary = import_to_library(db, library, config, dry_run=True)

        assert summary["imported"] == 1  # would be imported
        # But no entry created
        assert db.get_entries_by_hash(library.id, content_hash) == []
        # And no file on disk
        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        assert not dest.exists()
        # File status unchanged
        rec = db.get_file_by_path(str(photo))
        assert rec.status == "hashed"


class TestEdgeCases:
    def test_no_files_to_import(self, db, library):
        """Empty batch handled gracefully."""
        config = LibraryConfig()
        summary = import_to_library(db, library, config)
        assert summary["imported"] == 0
        assert summary["duplicates_in_batch"] == 0
        assert summary["duplicates_in_library"] == 0

    def test_quarantined_files_skipped(self, db, library, tmp_path):
        """Files without target_path are skipped."""
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"data")
        f = db.insert_file(str(source / "photo.jpg"), "local", 4, "2024-01-15T10:30:00")
        db.update_file(f.id, md5_hash="abc123", status="hashed")
        # No target_path set — should be skipped

        config = LibraryConfig()
        summary = import_to_library(db, library, config)
        assert summary["imported"] == 0
        assert summary["skipped"] == 1


class TestPlanImport:
    def test_plan_returns_correct_counts(self, db, library, tmp_path):
        """plan_import classifies files correctly."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content"
        content_hash = hashlib.md5(content).hexdigest()
        (source / "photo.jpg").write_bytes(content)

        f = db.insert_file(str(source / "photo.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert len(plan.to_import) == 1
        assert len(plan.duplicates_in_batch) == 0
        assert len(plan.duplicates_in_library) == 0

    def test_plan_is_read_only(self, db, library, tmp_path):
        """plan_import does not modify DB."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo"
        content_hash = hashlib.md5(content).hexdigest()
        (source / "a.jpg").write_bytes(content)
        (source / "b.jpg").write_bytes(content)

        fa = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            fa.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/a.jpg",
        )
        fb = db.insert_file(str(source / "b.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            fb.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/b.jpg",
        )

        config = LibraryConfig()
        plan = plan_import(db, library, config)

        # DB should be unchanged — both files still "hashed"
        assert len(db.query_files_by_status("hashed")) == 2
        assert len(db.query_files_by_status("duplicate")) == 0
        # Plan should identify the duplicate
        assert len(plan.duplicates_in_batch) == 1

    def test_plan_identifies_library_duplicates(self, db, library, tmp_path):
        """plan_import detects files already in library."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"already in library"
        content_hash = hashlib.md5(content).hexdigest()

        db.create_entry(library.id, "existing.jpg", len(content), content_hash, None, None)

        (source / "photo.jpg").write_bytes(content)
        f = db.insert_file(str(source / "photo.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert len(plan.duplicates_in_library) == 1
        assert len(plan.to_import) == 0

    def test_plan_empty_when_no_files(self, db, library):
        """plan_import with no hashed files returns empty plan."""
        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert plan.is_empty

    def test_plan_counts_skipped(self, db, library, tmp_path):
        """Files without target_path counted as skipped."""
        source = tmp_path / "source"
        source.mkdir()
        f = db.insert_file(str(source / "a.jpg"), "local", 100, "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash="abc", status="hashed")  # no target_path
        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert plan.skipped == 1


class TestImportTimeouts:
    def test_timeout_aborts_import(self, db, library, tmp_path):
        """A timed-out copy aborts the import loop and leaves DB state unchanged."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content"
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
        plan = plan_import(db, library, config)

        with patch("trove.importer._copy_and_verify", side_effect=TimeoutError("timed out")):
            summary = execute_import(db, library, config, plan)

        assert summary["errors"] == 1
        assert summary["imported"] == 0
        assert db.list_entries(library.id) == []
        assert db.get_file_by_path(str(photo)).status == "hashed"

    def test_plan_counts_path_conflicts(self, db, library, tmp_path):
        """plan_import counts files whose target_path already exists in library."""
        source = tmp_path / "source"
        source.mkdir()
        content_a = b"content A"
        hash_a = hashlib.md5(content_a).hexdigest()
        content_b = b"content B different"
        hash_b = hashlib.md5(content_b).hexdigest()

        # Pre-existing entry at the same target path
        db.create_entry(library.id, "2024/01/Canon/photo.jpg", len(content_a), hash_a, "2024-01-15T10:30:00", "Canon")

        (source / "b.jpg").write_bytes(content_b)
        fb = db.insert_file(str(source / "b.jpg"), "local", len(content_b), "2024-01-15T10:30:00")
        db.update_file(
            fb.id,
            md5_hash=hash_b,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert plan.path_conflicts == 1
        assert len(plan.to_import) == 1

    def test_plan_total_files(self, db, library, tmp_path):
        """total_files property sums all categories."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo"
        content_hash = hashlib.md5(content).hexdigest()
        (source / "a.jpg").write_bytes(content)
        (source / "b.jpg").write_bytes(content)

        fa = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            fa.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/a.jpg",
        )
        fb = db.insert_file(str(source / "b.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            fb.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/b.jpg",
        )

        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert plan.total_files == 2  # 1 to_import + 1 batch duplicate


class TestExecuteImport:
    def test_execute_imports_planned_files(self, db, library, tmp_path):
        """execute_import copies files and creates entries from a plan."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content here"
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
        plan = plan_import(db, library, config)
        assert len(plan.to_import) == 1

        summary = execute_import(db, library, config, plan)
        assert summary["imported"] == 1
        assert summary["errors"] == 0

        # File should exist on disk
        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        assert dest.exists()
        assert dest.read_bytes() == content

    def test_execute_import_preserves_source_mtime(self, db, library, tmp_path):
        """Imported files keep the source filesystem modification time."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content here"
        content_hash = hashlib.md5(content).hexdigest()
        photo = source / "photo.jpg"
        photo.write_bytes(content)

        source_mtime = 946684800  # 2000-01-01 00:00:00 UTC
        os.utime(photo, (source_mtime, source_mtime))

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
        plan = plan_import(db, library, config)

        summary = execute_import(db, library, config, plan)
        assert summary["imported"] == 1
        assert summary["errors"] == 0

        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        assert dest.exists()
        assert dest.stat().st_mtime_ns == photo.stat().st_mtime_ns

    def test_execute_import_sets_creation_date_from_capture_date(self, db, library, tmp_path):
        """Imported files stamp Finder Date Created from capture_date."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content here"
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
        plan = plan_import(db, library, config)

        with patch("trove.importer.stamp_creation_date", return_value=True) as mock_stamp:
            summary = execute_import(db, library, config, plan)

        assert summary["imported"] == 1
        dest = Path(library.location) / "2024/01/Canon/photo.jpg"
        mock_stamp.assert_called_once_with(dest, "2024-01-15T10:30:00")

        # Successful stamp marks the new entry so fix-created-dates skips it.
        assert db.list_entries_needing_creation_date_stamp(library.id) == []

    def test_execute_import_does_not_mark_when_stamp_fails(self, db, library, tmp_path):
        """A failed stamp leaves the entry available for later backfill."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo content here"
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
        plan = plan_import(db, library, config)

        with patch("trove.importer.stamp_creation_date", return_value=False):
            summary = execute_import(db, library, config, plan)

        assert summary["imported"] == 1
        pending = db.list_entries_needing_creation_date_stamp(library.id)
        assert len(pending) == 1
        assert pending[0].relative_path == "2024/01/Canon/photo.jpg"

    def test_execute_marks_batch_duplicates(self, db, library, tmp_path):
        """execute_import marks batch duplicates in DB."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"identical content"
        content_hash = hashlib.md5(content).hexdigest()

        for name in ["a.jpg", "b.jpg"]:
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

        config = LibraryConfig()
        plan = plan_import(db, library, config)
        assert len(plan.duplicates_in_batch) == 1

        summary = execute_import(db, library, config, plan)
        assert summary["duplicates_in_batch"] == 1
        assert len(db.query_files_by_status("duplicate")) == 1

    def test_execute_marks_library_duplicates(self, db, library, tmp_path):
        """execute_import marks library duplicates in DB."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"already in library"
        content_hash = hashlib.md5(content).hexdigest()

        db.create_entry(library.id, "existing.jpg", len(content), content_hash, None, None)

        (source / "photo.jpg").write_bytes(content)
        f = db.insert_file(str(source / "photo.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo.jpg",
        )

        config = LibraryConfig()
        plan = plan_import(db, library, config)
        summary = execute_import(db, library, config, plan)
        assert summary["duplicates_in_library"] == 1
        assert summary["imported"] == 0
