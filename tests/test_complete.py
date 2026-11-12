from __future__ import annotations

import hashlib

from trove.complete import complete_import, execute_complete, plan_complete


class TestCompleteAllAccountedFor:
    def test_all_accounted_cleans_records(self, db, library, tmp_path):
        """Imported + duplicate + quarantined files: can_complete=True, records cleaned."""
        source = tmp_path / "source"
        source.mkdir()

        # An imported file (needs matching entry in library)
        content = b"imported content"
        content_hash = hashlib.md5(content).hexdigest()
        (source / "a.jpg").write_bytes(content)
        f1 = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f1.id, md5_hash=content_hash, status="imported")
        db.create_entry(library.id, "2024/01/Canon/a.jpg", len(content), content_hash, "2024-01-01T00:00:00", "Canon")

        # A duplicate file
        f2 = db.insert_file(str(source / "b.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f2.id, md5_hash=content_hash, status="duplicate")

        # A quarantined file
        f3 = db.insert_file(str(source / "c.jpg"), "local", 100, "2024-01-01T00:00:00")
        db.update_file(f3.id, status="quarantined", error_message="no_date")

        result = complete_import(db, library)

        assert result.can_complete is True
        assert result.imported == 1
        assert result.duplicate == 1
        assert result.quarantined == 1
        assert result.unaccounted == 0
        assert result.records_cleaned == 3
        # Records should be gone from DB
        assert db.query_files_by_status("imported") == []
        assert db.query_files_by_status("duplicate") == []
        assert db.query_files_by_status("quarantined") == []


class TestUnaccountedBlocksCompletion:
    def test_hashed_file_blocks(self, db, library, tmp_path):
        """File still at hashed status blocks completion."""
        source = tmp_path / "source"
        source.mkdir()
        (source / "a.jpg").write_bytes(b"data")
        f = db.insert_file(str(source / "a.jpg"), "local", 4, "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash="abc123", status="hashed")

        result = complete_import(db, library)

        assert result.can_complete is False
        assert result.unaccounted == 1
        assert result.records_cleaned == 0
        # Record still exists
        assert len(db.query_files_by_status("hashed")) == 1

    def test_discovered_file_blocks(self, db, library, tmp_path):
        """File still at discovered status blocks completion."""
        source = tmp_path / "source"
        source.mkdir()
        (source / "a.jpg").write_bytes(b"data")
        db.insert_file(str(source / "a.jpg"), "local", 4, "2024-01-01T00:00:00")

        result = complete_import(db, library)

        assert result.can_complete is False
        assert result.unaccounted == 1


class TestSourceFilesNeverDeleted:
    def test_source_files_always_kept(self, db, library, tmp_path):
        """Complete never deletes source files."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"keep me"
        content_hash = hashlib.md5(content).hexdigest()
        photo = source / "photo.jpg"
        photo.write_bytes(content)

        f = db.insert_file(str(photo), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash=content_hash, status="imported")
        db.create_entry(
            library.id, "2024/01/Canon/photo.jpg", len(content), content_hash, "2024-01-01T00:00:00", "Canon"
        )

        result = complete_import(db, library)

        assert result.can_complete is True
        assert photo.exists()  # source file untouched
        assert result.records_cleaned == 1


class TestEmptyFilesTable:
    def test_empty_table_completes(self, db, library):
        """Nothing to do: can_complete=True."""
        result = complete_import(db, library)
        assert result.can_complete is True
        assert result.imported == 0
        assert result.records_cleaned == 0


class TestVerifyImportedHaveEntries:
    def test_imported_without_entry_blocks(self, db, library, tmp_path):
        """Imported file with no matching entry in library: can_complete=False."""
        source = tmp_path / "source"
        source.mkdir()

        f = db.insert_file(str(source / "orphan.jpg"), "local", 100, "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash="nonexistent_hash", status="imported")

        result = complete_import(db, library)

        assert result.can_complete is False
        assert result.unaccounted >= 1
        assert result.records_cleaned == 0


class TestPlanComplete:
    def test_plan_returns_correct_counts(self, db, library, tmp_path):
        """plan_complete classifies files correctly."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"imported content"
        content_hash = hashlib.md5(content).hexdigest()

        f1 = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f1.id, md5_hash=content_hash, status="imported")
        db.create_entry(library.id, "2024/01/Canon/a.jpg", len(content), content_hash, None, None)

        f2 = db.insert_file(str(source / "b.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f2.id, md5_hash=content_hash, status="duplicate")

        f3 = db.insert_file(str(source / "c.jpg"), "local", 100, "2024-01-01T00:00:00")
        db.update_file(f3.id, status="quarantined", error_message="no_date")

        plan = plan_complete(db, library)
        assert plan.can_complete is True
        assert len(plan.imported) == 1
        assert len(plan.duplicate) == 1
        assert len(plan.quarantined) == 1
        assert len(plan.unaccounted) == 0
        assert plan.total_to_clean == 3

    def test_plan_is_read_only(self, db, library, tmp_path):
        """plan_complete does not modify DB."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"content"
        content_hash = hashlib.md5(content).hexdigest()

        f = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash=content_hash, status="imported")
        db.create_entry(library.id, "a.jpg", len(content), content_hash, None, None)

        _plan = plan_complete(db, library)

        # DB unchanged
        assert len(db.query_files_by_status("imported")) == 1

    def test_plan_unaccounted_blocks(self, db, library, tmp_path):
        """Hashed files make can_complete False."""
        source = tmp_path / "source"
        source.mkdir()
        f = db.insert_file(str(source / "a.jpg"), "local", 100, "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash="abc", status="hashed")

        plan = plan_complete(db, library)
        assert plan.can_complete is False
        assert len(plan.unaccounted) == 1

    def test_plan_imported_without_entry_is_unaccounted(self, db, library, tmp_path):
        """Imported file with no matching entry is unaccounted."""
        source = tmp_path / "source"
        source.mkdir()
        f = db.insert_file(str(source / "a.jpg"), "local", 100, "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash="nonexistent", status="imported")

        plan = plan_complete(db, library)
        assert plan.can_complete is False
        assert len(plan.unaccounted) == 1


class TestExecuteComplete:
    def test_execute_cleans_records(self, db, library, tmp_path):
        """execute_complete removes records from DB."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"imported content"
        content_hash = hashlib.md5(content).hexdigest()

        f1 = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f1.id, md5_hash=content_hash, status="imported")
        db.create_entry(library.id, "2024/01/Canon/a.jpg", len(content), content_hash, None, None)

        plan = plan_complete(db, library)
        result = execute_complete(db, library, plan)

        assert result.can_complete is True
        assert result.records_cleaned == 1
        assert db.query_files_by_status("imported") == []
