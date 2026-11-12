"""Tests for library initialization module."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from unittest.mock import patch

import pytest

from trove.config import LibraryConfig
from trove.initialize import execute_initialize, plan_initialize
from trove.metadata import FileMetadata


class TestPlanInitialize:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_file_already_at_correct_path(self, mock_meta, db, library):
        """File at its computed target path is classified as already_correct."""
        lib_dir = Path(library.location)
        target = lib_dir / "2024/01/Canon/photo.jpg"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"correct location")

        mock_meta.return_value = {str(target): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        assert len(plan.already_correct) == 1
        assert len(plan.needs_move) == 0
        assert plan.already_correct[0].action == "index"

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_file_needs_move(self, mock_meta, db, library):
        """File at wrong path is classified as needs_move."""
        lib_dir = Path(library.location)
        wrong_path = lib_dir / "unsorted/photo.jpg"
        wrong_path.parent.mkdir(parents=True)
        wrong_path.write_bytes(b"wrong location")

        mock_meta.return_value = {str(wrong_path): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        assert len(plan.needs_move) == 1
        assert plan.needs_move[0].action == "move"
        assert "2024/01" in plan.needs_move[0].target_path

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_quarantined_no_date(self, mock_meta, db, library):
        """File with no date is quarantined."""
        lib_dir = Path(library.location)
        f = lib_dir / "nodate.jpg"
        f.write_bytes(b"no date")
        os.utime(f, (315532800, 315532800))  # 1980-01-01 UTC (invalid year)

        mock_meta.return_value = {str(f): FileMetadata(None, None, None)}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        assert len(plan.quarantined) == 1
        assert plan.quarantined[0].action == "quarantine"

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_plan_does_not_create_entries(self, mock_meta, db, library):
        """plan_initialize writes file records but does NOT create entries or move files."""
        lib_dir = Path(library.location)
        (lib_dir / "photo.jpg").write_bytes(b"data")

        mock_meta.return_value = {
            str(lib_dir / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }
        config = LibraryConfig()
        plan_initialize(library, db, config)

        # No entries created
        assert db.list_entries(library.id) == []
        # File not moved
        assert (lib_dir / "photo.jpg").exists()
        # But file records WERE created (for resumability)
        assert len(db.query_files_by_status("hashed")) >= 1

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_skips_existing_entries(self, mock_meta, db, library):
        """Files that already have entries are skipped."""
        lib_dir = Path(library.location)
        content = b"already indexed"
        content_hash = hashlib.md5(content).hexdigest()
        target = lib_dir / "2024/01/Canon/photo.jpg"
        target.parent.mkdir(parents=True)
        target.write_bytes(content)

        db.create_entry(library.id, "2024/01/Canon/photo.jpg", len(content), content_hash, None, None)

        mock_meta.return_value = {str(target): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        assert plan.is_empty

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_skips_existing_file_records(self, mock_meta, db, library):
        """Files that already have file records are not re-discovered."""
        lib_dir = Path(library.location)
        (lib_dir / "photo.jpg").write_bytes(b"data")

        mock_meta.return_value = {
            str(lib_dir / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }
        config = LibraryConfig()

        # First run creates file records
        plan1 = plan_initialize(library, db, config)
        assert not plan1.is_empty

        # Second run should reuse existing records (not create duplicates)
        plan2 = plan_initialize(library, db, config)
        assert len(plan2.already_correct) + len(plan2.needs_move) == len(plan1.already_correct) + len(plan1.needs_move)

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_path_conflict_gets_suffix(self, mock_meta, db, library):
        """Two different files targeting same path: second gets suffix."""
        lib_dir = Path(library.location)
        dir1 = lib_dir / "folder1"
        dir1.mkdir()
        (dir1 / "photo.jpg").write_bytes(b"file a content")
        dir2 = lib_dir / "folder2"
        dir2.mkdir()
        (dir2 / "photo.jpg").write_bytes(b"file b different")

        mock_meta.return_value = {
            str(dir1 / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(dir2 / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        all_actions = plan.already_correct + plan.needs_move + plan.duplicates
        assert len(all_actions) == 2
        target_paths = {a.target_path for a in all_actions}
        assert len(target_paths) == 2

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_mtime_fallback(self, mock_meta, db, library):
        """File with no EXIF date falls back to mtime."""
        lib_dir = Path(library.location)
        f = lib_dir / "photo.jpg"
        f.write_bytes(b"mtime fallback")
        os.utime(f, (1704067200, 1704067200))  # 2024-01-01 UTC

        mock_meta.return_value = {str(f): FileMetadata(None, None, None)}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        assert len(plan.quarantined) == 0
        all_actions = plan.already_correct + plan.needs_move
        assert len(all_actions) == 1

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_persists_file_records_to_db(self, mock_meta, db, library):
        """Discover step writes file records to DB for resumability."""
        lib_dir = Path(library.location)
        (lib_dir / "a.jpg").write_bytes(b"aaa")
        (lib_dir / "b.jpg").write_bytes(b"bbb")

        mock_meta.return_value = {
            str(lib_dir / "a.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(lib_dir / "b.jpg"): FileMetadata("2024-02-15T10:30:00", "Canon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        plan_initialize(library, db, config)

        # File records should exist in DB
        hashed = db.query_files_by_status("hashed")
        assert len(hashed) == 2


class TestExecuteInitialize:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_indexes_correct_file_without_hash(self, mock_meta, db, library):
        """File at correct path: entry created with null hash, file not moved."""
        lib_dir = Path(library.location)
        target = lib_dir / "2024/01/Canon/photo.jpg"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"correct")

        mock_meta.return_value = {str(target): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        result = execute_initialize(library, db, plan)

        assert result.indexed >= 1
        entry = db.get_entry_by_path(library.id, "2024/01/Canon/photo.jpg")
        assert entry is not None
        assert entry.md5_hash is None  # no hash — file didn't move
        assert target.exists()

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_moves_file_with_hash(self, mock_meta, db, library):
        """File at wrong path: moved, entry created with hash."""
        lib_dir = Path(library.location)
        wrong = lib_dir / "unsorted/photo.jpg"
        wrong.parent.mkdir(parents=True)
        content = b"move me"
        wrong.write_bytes(content)
        content_hash = hashlib.md5(content).hexdigest()

        mock_meta.return_value = {str(wrong): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        result = execute_initialize(library, db, plan)

        assert result.moved >= 1
        assert not wrong.exists()
        new_path = lib_dir / plan.needs_move[0].target_path
        assert new_path.exists()
        assert new_path.read_bytes() == content
        entry = db.get_entry_by_path(library.id, plan.needs_move[0].target_path)
        assert entry is not None
        assert entry.md5_hash == content_hash  # hash stored since file was moved

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_cleans_empty_directories(self, mock_meta, db, library):
        """Empty parent directories removed after move."""
        lib_dir = Path(library.location)
        deep = lib_dir / "a/b/c/photo.jpg"
        deep.parent.mkdir(parents=True)
        deep.write_bytes(b"deep")

        mock_meta.return_value = {str(deep): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        execute_initialize(library, db, plan)

        assert not (lib_dir / "a/b/c").exists()
        assert lib_dir.exists()

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_cleans_file_records_after_execute(self, mock_meta, db, library):
        """File records cleaned from DB after successful execution."""
        lib_dir = Path(library.location)
        (lib_dir / "photo.jpg").write_bytes(b"data")

        mock_meta.return_value = {
            str(lib_dir / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        # File records exist before execute
        assert len(db.query_files_by_status("hashed")) >= 1

        execute_initialize(library, db, plan)

        # File records cleaned up
        assert len(db.query_files_by_status("hashed")) == 0
        # But entries exist
        assert len(db.list_entries(library.id)) >= 1


class TestOriginalPathCapture:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_moved_file_stores_original_path(self, mock_meta, db, library):
        """File that gets moved: entry has original relative path."""
        lib_dir = Path(library.location)
        source = lib_dir / "mammals/deer.jpg"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"deer photo")

        mock_meta.return_value = {str(source): FileMetadata("2024-06-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 1

        execute_initialize(library, db, plan)

        entry = db.get_entry_by_path(library.id, plan.needs_move[0].target_path)
        assert entry is not None
        assert entry.original_path == "mammals/deer.jpg"

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_correct_file_stores_no_original_path(self, mock_meta, db, library):
        """File already at correct path: original_path is None."""
        lib_dir = Path(library.location)
        target = lib_dir / "2024/01/Canon/photo.jpg"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"correct")

        mock_meta.return_value = {str(target): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.already_correct) == 1

        execute_initialize(library, db, plan)

        entry = db.get_entry_by_path(library.id, "2024/01/Canon/photo.jpg")
        assert entry is not None
        assert entry.original_path is None

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_duplicate_file_stores_original_path(self, mock_meta, db, library):
        """Duplicate file that gets moved: entry has original relative path."""
        lib_dir = Path(library.location)

        # First file at correct location
        first = lib_dir / "2024/01/Canon/photo.jpg"
        first.parent.mkdir(parents=True)
        first.write_bytes(b"original file")

        # Duplicate in a different folder
        second = lib_dir / "NC-Sandhills/photo.jpg"
        second.parent.mkdir(parents=True)
        second.write_bytes(b"duplicate file")

        mock_meta.return_value = {
            str(first): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(second): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        execute_initialize(library, db, plan)

        entries = db.list_entries(library.id)
        # Find the entry that came from NC-Sandhills
        moved_entries = [e for e in entries if e.original_path is not None]
        assert len(moved_entries) >= 1
        assert any("NC-Sandhills" in e.original_path for e in moved_entries)


class TestNoRedundantHash:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_move_does_not_import_hash_file(self, mock_meta, db, library):
        """initialize module should not import hash_file at all."""
        import trove.initialize

        assert not hasattr(trove.initialize, "hash_file"), "hash_file should not be imported in initialize"

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_moved_file_entry_uses_plan_hash(self, mock_meta, db, library):
        """Entry created from move uses the hash computed during planning."""
        lib_dir = Path(library.location)
        source = lib_dir / "unsorted/photo.jpg"
        source.parent.mkdir(parents=True)
        content = b"use plan hash"
        source.write_bytes(content)
        content_hash = hashlib.md5(content).hexdigest()

        mock_meta.return_value = {str(source): FileMetadata("2024-06-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        execute_initialize(library, db, plan)

        entry = db.get_entry_by_path(library.id, plan.needs_move[0].target_path)
        assert entry is not None
        assert entry.md5_hash == content_hash


class TestGracefulStop:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_stops_on_interrupt_flag(self, mock_meta, db, library):
        """execute_initialize stops after current file when interrupted."""
        lib_dir = Path(library.location)
        for i in range(5):
            f = lib_dir / f"folder/photo{i}.jpg"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(f"content {i}".encode())

        meta = {}
        for i in range(5):
            meta[str(lib_dir / f"folder/photo{i}.jpg")] = FileMetadata(
                "2024-01-15T10:30:00", "Canon", "DateTimeOriginal"
            )
        mock_meta.return_value = meta
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 5

        # Simulate interrupt after 2 files by patching the stop check
        call_count = 0

        def fake_check(lib_path):
            nonlocal call_count
            call_count += 1
            if call_count > 2:
                raise InterruptedError("Stopped")

        with patch("trove.initialize._check_should_continue", side_effect=fake_check):
            result = execute_initialize(library, db, plan)

        # Should have processed some but not all
        assert result.moved < 5
        assert result.moved > 0

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_stops_when_mount_unreachable(self, mock_meta, db, library):
        """execute_initialize stops if library path becomes inaccessible."""
        lib_dir = Path(library.location)
        for i in range(3):
            f = lib_dir / f"folder/photo{i}.jpg"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(f"content {i}".encode())

        meta = {}
        for i in range(3):
            meta[str(lib_dir / f"folder/photo{i}.jpg")] = FileMetadata(
                "2024-01-15T10:30:00", "Canon", "DateTimeOriginal"
            )
        mock_meta.return_value = meta
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        call_count = 0

        def fake_check(lib_path):
            nonlocal call_count
            call_count += 1
            if call_count > 1:
                raise OSError("Mount not accessible")

        with patch("trove.initialize._check_should_continue", side_effect=fake_check):
            result = execute_initialize(library, db, plan)

        # Should have stopped early
        assert result.moved < 3

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_result_reflects_partial_progress(self, mock_meta, db, library):
        """Partial run still returns accurate counts."""
        lib_dir = Path(library.location)
        # 2 correct + 2 needs_move
        correct = lib_dir / "2024/01/Canon/correct.jpg"
        correct.parent.mkdir(parents=True)
        correct.write_bytes(b"correct")
        wrong = lib_dir / "folder/wrong.jpg"
        wrong.parent.mkdir(parents=True)
        wrong.write_bytes(b"wrong")

        mock_meta.return_value = {
            str(correct): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(wrong): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        # Let it run fully (no interruption)
        result = execute_initialize(library, db, plan)
        total = result.indexed + result.moved + result.duplicates + result.quarantined
        assert total == len(plan.already_correct) + len(plan.needs_move) + len(plan.duplicates) + len(plan.quarantined)

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_stops_on_timed_out_file_operation(self, mock_meta, db, library):
        """Timeouts stop execution instead of continuing to launch more work."""
        lib_dir = Path(library.location)
        for i in range(2):
            f = lib_dir / f"folder/photo{i}.jpg"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(f"content {i}".encode())

        mock_meta.return_value = {
            str(lib_dir / "folder/photo0.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(lib_dir / "folder/photo1.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }

        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 2

        with patch("trove.initialize.move_file", side_effect=TimeoutError("timed out")):
            result = execute_initialize(library, db, plan)

        assert result.moved == 0
        assert db.list_entries(library.id) == []

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_on_error_callback_can_abort(self, mock_meta, db, library):
        """on_error returning False stops execution."""
        lib_dir = Path(library.location)
        for i in range(10):
            f = lib_dir / f"folder/photo{i}.jpg"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(f"content {i}".encode())

        meta = {}
        for i in range(10):
            meta[str(lib_dir / f"folder/photo{i}.jpg")] = FileMetadata(
                "2024-01-15T10:30:00", "Canon", "DateTimeOriginal"
            )
        mock_meta.return_value = meta
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 10

        move_call_count = 0

        def failing_move(source, dest, expected_hash=None, lib_path=None):
            nonlocal move_call_count
            move_call_count += 1
            raise FileNotFoundError(f"No such file: {source}")

        # Abort after 3 errors
        def abort_after_3(path, reason, error_count):
            return error_count < 3

        with patch("trove.initialize.move_file", side_effect=failing_move):
            result = execute_initialize(library, db, plan, on_error=abort_after_3)

        assert move_call_count == 3
        assert result.errors == 3
        assert result.moved == 0

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_errors_without_on_error_continue(self, mock_meta, db, library):
        """Without on_error callback, errors log but execution continues."""
        lib_dir = Path(library.location)
        for i in range(5):
            f = lib_dir / f"folder/photo{i}.jpg"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(f"content {i}".encode())

        meta = {}
        for i in range(5):
            meta[str(lib_dir / f"folder/photo{i}.jpg")] = FileMetadata(
                "2024-01-15T10:30:00", "Canon", "DateTimeOriginal"
            )
        mock_meta.return_value = meta
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 5

        def failing_move(source, dest, expected_hash=None):
            raise FileNotFoundError(f"No such file: {source}")

        with patch("trove.initialize.move_file", side_effect=failing_move):
            result = execute_initialize(library, db, plan)

        # Without callback, all files are attempted
        assert result.errors == 5
        assert result.moved == 0


class TestEdgeCases:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_empty_library_directory(self, mock_meta, db, library):
        """Empty library dir produces empty plan."""
        mock_meta.return_value = {}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert plan.is_empty

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_quarantine_target_path(self, mock_meta, db, library):
        """Quarantined files get a target_path in the quarantine directory."""
        lib_dir = Path(library.location)
        f = lib_dir / "nodate.jpg"
        f.write_bytes(b"no date data")
        os.utime(f, (315532800, 315532800))  # 1980-01-01 UTC (invalid year)

        mock_meta.return_value = {str(f): FileMetadata(None, None, None)}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        assert len(plan.quarantined) == 1
        assert plan.quarantined[0].target_path.startswith("quarantine/")


class TestResumeScoping:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_ignores_files_from_other_libraries(self, mock_meta, db, tmp_path):
        """Resume path should only pick up files scoped to the current library."""
        # Create two separate libraries with distinct directories
        lib_a_dir = tmp_path / "library_a"
        lib_a_dir.mkdir()
        lib_b_dir = tmp_path / "library_b"
        lib_b_dir.mkdir()
        lib_a = db.create_library("LibraryA", str(lib_a_dir))
        _lib_b = db.create_library("LibraryB", str(lib_b_dir))

        # Create a file in library A
        (lib_a_dir / "photo_a.jpg").write_bytes(b"library a photo")

        # Manually insert a hashed file record for library B (simulates previous run)
        rec_b = db.insert_file(
            source_path=str(lib_b_dir / "photo_b.jpg"),
            source_type="local",
            file_size=100,
            file_modify_date="2024-01-15T10:30:00",
        )
        db.update_file(
            rec_b.id,
            status="hashed",
            md5_hash="abc123",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/photo_b.jpg",
        )

        mock_meta.return_value = {
            str(lib_a_dir / "photo_a.jpg"): FileMetadata("2024-02-15T10:30:00", "Nikon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        plan = plan_initialize(lib_a, db, config)

        # Plan should only contain the file from library A
        all_actions = plan.already_correct + plan.needs_move + plan.duplicates + plan.quarantined
        all_source_paths = [a.source_path for a in all_actions]
        assert any("photo_a" in p for p in all_source_paths), "Library A's file should be in the plan"
        assert not any("photo_b" in p for p in all_source_paths), (
            "Library B's file should NOT leak into library A's plan"
        )


class TestCreateEntryRollback:
    """Verify that a failed db.create_entry after a successful move rolls back the file."""

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_needs_move_rollback_on_create_entry_failure(self, mock_meta, db, library):
        """If create_entry fails after move, file is moved back to source."""
        lib_dir = Path(library.location)
        source = lib_dir / "unsorted/photo.jpg"
        source.parent.mkdir(parents=True)
        content = b"rollback me"
        source.write_bytes(content)

        mock_meta.return_value = {str(source): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 1
        target_path = plan.needs_move[0].target_path

        # Patch create_entry to fail only when called with target_path (the move entry)
        original_create = db.create_entry

        def failing_create(*args, **kwargs):
            if args and len(args) >= 2 and args[1] == target_path:
                raise RuntimeError("simulated DB failure")
            return original_create(*args, **kwargs)

        with patch.object(db, "create_entry", side_effect=failing_create):
            result = execute_initialize(library, db, plan)

        # File should be back at source, not at destination
        assert source.exists(), "File should have been moved back to source"
        assert source.read_bytes() == content
        dest = lib_dir / target_path
        assert not dest.exists(), "File should not remain at destination"
        assert result.errors == 1
        assert result.moved == 0

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_duplicates_rollback_on_create_entry_failure(self, mock_meta, db, library):
        """If create_entry fails for a duplicate that was moved, file is moved back."""
        lib_dir = Path(library.location)

        # Create first file so it gets indexed normally
        first = lib_dir / "2024/01/Canon/photo.jpg"
        first.parent.mkdir(parents=True)
        first.write_bytes(b"original file")

        # Create second file with same metadata — will be classified as duplicate
        second = lib_dir / "subfolder/photo.jpg"
        second.parent.mkdir(parents=True)
        content = b"duplicate file"
        second.write_bytes(content)

        mock_meta.return_value = {
            str(first): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(second): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)

        # Find the duplicate action that requires a move
        dup_actions = [a for a in plan.duplicates if a.relative_path != a.target_path]
        if not dup_actions:
            pytest.skip("No duplicate action requires a move in this plan")

        dup_target = dup_actions[0].target_path

        original_create = db.create_entry

        def failing_create(*args, **kwargs):
            if args and len(args) >= 2 and args[1] == dup_target:
                raise RuntimeError("simulated DB failure")
            return original_create(*args, **kwargs)

        with patch.object(db, "create_entry", side_effect=failing_create):
            result = execute_initialize(library, db, plan)

        # The duplicate source file should be back at its original location
        assert second.exists(), "Duplicate file should have been moved back to source"
        assert second.read_bytes() == content
        assert result.errors >= 1

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_quarantined_rollback_on_create_entry_failure(self, mock_meta, db, library):
        """If create_entry fails for a quarantined file that was moved, file is moved back."""
        lib_dir = Path(library.location)
        source = lib_dir / "nodate.jpg"
        content = b"quarantine rollback"
        source.write_bytes(content)
        os.utime(source, (315532800, 315532800))  # 1980-01-01 UTC (invalid year)

        mock_meta.return_value = {str(source): FileMetadata(None, None, None)}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.quarantined) == 1

        q_action = plan.quarantined[0]
        # Only test rollback if the file actually needs to move
        if q_action.relative_path == q_action.target_path:
            pytest.skip("Quarantined file does not need a move")

        original_create = db.create_entry

        def failing_create(*args, **kwargs):
            if args and len(args) >= 2 and args[1] == q_action.target_path:
                raise RuntimeError("simulated DB failure")
            return original_create(*args, **kwargs)

        with patch.object(db, "create_entry", side_effect=failing_create):
            result = execute_initialize(library, db, plan)

        assert source.exists(), "Quarantined file should have been moved back to source"
        assert source.read_bytes() == content
        assert result.errors >= 1


class TestOrphanRecovery:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_file_already_moved_to_destination(self, mock_meta, db, library):
        """Source gone but file at destination with matching hash → recovered."""
        lib_dir = Path(library.location)
        content = b"already moved"
        content_hash = hashlib.md5(content).hexdigest()

        # Create file at source, plan the init
        source = lib_dir / "unsorted/photo.jpg"
        source.parent.mkdir(parents=True)
        source.write_bytes(content)

        mock_meta.return_value = {str(source): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 1
        target_path = plan.needs_move[0].target_path

        # Now simulate: source is gone, file is at destination
        dest = lib_dir / target_path
        dest.parent.mkdir(parents=True, exist_ok=True)
        source.rename(dest)
        assert not source.exists()
        assert dest.exists()

        result = execute_initialize(library, db, plan)

        # Should recover: entry created, file record cleaned up
        assert result.moved == 1
        assert result.errors == 0
        entry = db.get_entry_by_path(library.id, target_path)
        assert entry is not None
        assert entry.md5_hash == content_hash
        # File record should be cleaned up
        file_rec = db.get_file_by_path(str(source))
        assert file_rec is None

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_file_already_moved_entry_already_exists(self, mock_meta, db, library):
        """Source gone, dest exists, entry already in DB → just clean up file record."""
        lib_dir = Path(library.location)
        content = b"already moved and indexed"
        content_hash = hashlib.md5(content).hexdigest()

        source = lib_dir / "unsorted/photo.jpg"
        source.parent.mkdir(parents=True)
        source.write_bytes(content)

        mock_meta.return_value = {str(source): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 1
        target_path = plan.needs_move[0].target_path

        # Move file to dest and create entry manually (simulating prior completed move)
        dest = lib_dir / target_path
        dest.parent.mkdir(parents=True, exist_ok=True)
        source.rename(dest)
        db.create_entry(library.id, target_path, len(content), content_hash, "2024-01-15T10:30:00", "Canon")

        result = execute_initialize(library, db, plan)

        assert result.moved == 1
        assert result.errors == 0
        # Still just one entry (no duplicate)
        entries = [e for e in db.list_entries(library.id) if e.relative_path == target_path]
        assert len(entries) == 1

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_dest_has_different_file(self, mock_meta, db, library):
        """Source gone, dest exists but wrong hash → marked missing."""
        lib_dir = Path(library.location)
        content = b"original content"

        source = lib_dir / "unsorted/photo.jpg"
        source.parent.mkdir(parents=True)
        source.write_bytes(content)

        mock_meta.return_value = {str(source): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 1
        target_path = plan.needs_move[0].target_path

        # Remove source, put different content at dest
        source.unlink()
        dest = lib_dir / target_path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"completely different file")

        result = execute_initialize(library, db, plan)

        assert result.errors == 1
        # File record should be marked missing
        file_rec = db.get_file_by_path(str(source))
        assert file_rec is not None
        assert file_rec.status == "missing"
        assert "mismatch" in file_rec.error_message

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_truly_missing_file(self, mock_meta, db, library):
        """Source gone, dest gone → marked missing."""
        lib_dir = Path(library.location)
        content = b"will vanish"

        source = lib_dir / "unsorted/photo.jpg"
        source.parent.mkdir(parents=True)
        source.write_bytes(content)

        mock_meta.return_value = {str(source): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")}
        config = LibraryConfig()
        plan = plan_initialize(library, db, config)
        assert len(plan.needs_move) == 1

        # Remove source entirely, no dest
        source.unlink()

        result = execute_initialize(library, db, plan)

        assert result.errors == 1
        file_rec = db.get_file_by_path(str(source))
        assert file_rec is not None
        assert file_rec.status == "missing"
        assert file_rec.error_message == "source_missing"
