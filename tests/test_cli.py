"""Tests for the CLI module — Click commands wiring all modules together."""

from __future__ import annotations

import hashlib
from unittest.mock import patch

import pytest
from click.testing import CliRunner

from trove.cli import cli
from trove.db import StateDB
from trove.metadata import FileMetadata
from trove.timeout import path_exists, run_with_timeout
from trove.verify import VerifyResult


@pytest.fixture
def runner():
    return CliRunner()


@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "test.db"


class TestLibraryCreate:
    def test_create_with_files_decline(self, runner, db_path, tmp_path):
        """Create library with files, user declines add prompt."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        (lib_dir / "photo.jpg").write_bytes(b"photo content")
        result = runner.invoke(
            cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)],
            input="n\n",
        )
        assert result.exit_code == 0
        assert "Created library" in result.output
        assert "Add" in result.output or "add" in result.output

    def test_create_interactive(self, runner, db_path, tmp_path):
        """Create library interactively when no args given."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        result = runner.invoke(cli, ["--db", str(db_path), "create"], input=f"Photos\n{lib_dir}\nn\n")
        assert result.exit_code == 0
        assert "Created library" in result.output

    def test_create_duplicate(self, runner, db_path, tmp_path):
        """Duplicate library name shows error."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)], input="n\n")
        result = runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        assert result.exit_code != 0

    def test_create_new_directory(self, runner, db_path, tmp_path):
        """Creates directory if it doesn't exist, no prompts."""
        lib_dir = tmp_path / "new_photos"
        result = runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        assert result.exit_code == 0
        assert lib_dir.exists()
        assert "Created library" in result.output

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_create_with_files_accept(self, mock_meta, runner, db_path, tmp_path):
        """User says yes to add files, files get processed."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        (lib_dir / "photo.jpg").write_bytes(b"photo data")
        mock_meta.return_value = {
            str(lib_dir / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }
        result = runner.invoke(
            cli,
            ["--db", str(db_path), "create", "Photos", str(lib_dir)],
            input="y\ny\n",  # yes to add, yes to proceed
        )
        assert result.exit_code == 0
        assert "Indexed" in result.output or "Moved" in result.output

    def test_create_empty_directory(self, runner, db_path, tmp_path):
        """Library create with empty existing dir — no prompts about files."""
        lib_dir = tmp_path / "empty"
        lib_dir.mkdir()
        result = runner.invoke(
            cli,
            ["--db", str(db_path), "create", "Photos", str(lib_dir)],
        )
        assert result.exit_code == 0
        assert "Created library" in result.output


class TestLibraryDelete:
    def test_delete_removes_library_and_entries(self, runner, db_path, tmp_path):
        """Deleting a library removes the library record and all its entries."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        # Create library and add an entry directly
        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "2024/01/photo.jpg", 100, "abc", None, None)

        # Confirm by typing library name
        result = runner.invoke(
            cli, ["--db", str(db_path), "delete", "Photos"],
            input="Photos\n",
        )
        assert result.exit_code == 0
        assert "Deleted" in result.output

        with StateDB(db_path) as db:
            assert db.get_library("Photos") is None
            # entries gone too
            assert db.list_entries(lib.id) == []

    def test_delete_shows_warning_with_entry_count(self, runner, db_path, tmp_path):
        """Delete command warns about how many entries will be removed."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "a.jpg", 100, "h1", None, None)
            db.create_entry(lib.id, "b.jpg", 200, "h2", None, None)
            db.create_entry(lib.id, "c.jpg", 300, "h3", None, None)

        # Abort by typing wrong name
        result = runner.invoke(
            cli, ["--db", str(db_path), "delete", "Photos"],
            input="nope\n",
        )
        assert "3 entries" in result.output
        assert "files on disk will NOT" in result.output

        # Library should still exist
        with StateDB(db_path) as db:
            assert db.get_library("Photos") is not None

    def test_delete_wrong_confirmation_aborts(self, runner, db_path, tmp_path):
        """Typing wrong name aborts the delete."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        with StateDB(db_path) as db:
            db.create_library("Photos", str(lib_dir))

        result = runner.invoke(
            cli, ["--db", str(db_path), "delete", "Photos"],
            input="wrong\n",
        )
        assert result.exit_code == 0
        assert "Aborted" in result.output

        with StateDB(db_path) as db:
            assert db.get_library("Photos") is not None

    def test_delete_unknown_library(self, runner, db_path):
        """Deleting nonexistent library shows error."""
        result = runner.invoke(cli, ["--db", str(db_path), "delete", "Nope"])
        assert result.exit_code != 0


class TestLibraryList:
    def test_list_empty(self, runner, db_path):
        """List with no libraries."""
        result = runner.invoke(cli, ["--db", str(db_path), "list"])
        assert result.exit_code == 0
        assert "No libraries" in result.output

    def test_list_libraries(self, runner, db_path, tmp_path):
        """List shows created libraries."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "list"])
        assert result.exit_code == 0
        assert "Photos" in result.output


class TestFixCreatedDates:
    def _seed(self, db_path, tmp_path):
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        photo = lib_dir / "2024" / "01" / "photo.jpg"
        photo.parent.mkdir(parents=True)
        photo.write_bytes(b"photo content")
        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            entry = db.create_entry(
                lib.id,
                "2024/01/photo.jpg",
                photo.stat().st_size,
                "abc",
                "2024-01-15T10:30:00",
                "Canon",
            )
        return lib_dir, photo, entry

    def test_fix_created_dates_dry_run(self, runner, db_path, tmp_path):
        """Dry run reports eligible entries but does not update them."""
        self._seed(db_path, tmp_path)

        with (
            patch("trove.cli.sys.platform", "darwin"),
            patch("trove.cli.stamp_creation_date", return_value=True) as mock_stamp,
        ):
            result = runner.invoke(cli, ["--db", str(db_path), "fix-created-dates", "Photos"])

        assert result.exit_code == 0
        assert "Entries needing creation-date stamp: 1" in result.output
        assert "Dry run only" in result.output
        mock_stamp.assert_not_called()

    def test_fix_created_dates_apply(self, runner, db_path, tmp_path):
        """Apply mode rewrites Finder Date Created from stored capture dates."""
        _, photo, entry = self._seed(db_path, tmp_path)

        with (
            patch("trove.cli.sys.platform", "darwin"),
            patch("trove.cli.stamp_creation_date", return_value=True) as mock_stamp,
        ):
            result = runner.invoke(
                cli, ["--db", str(db_path), "fix-created-dates", "Photos", "--apply", "--yes"],
            )

        assert result.exit_code == 0
        assert "Updated Finder Date Created for 1 files." in result.output
        mock_stamp.assert_called_once_with(photo, "2024-01-15T10:30:00")

        # Entry is now marked stamped, so a second run finds nothing.
        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            assert db.list_entries_needing_creation_date_stamp(lib.id) == []

    def test_fix_created_dates_skips_already_stamped(self, runner, db_path, tmp_path):
        """Entries already in entries_creation_date_stamped are not re-stamped."""
        _, _, entry = self._seed(db_path, tmp_path)
        with StateDB(db_path) as db:
            db.mark_entry_creation_date_stamped(entry.id)

        with (
            patch("trove.cli.sys.platform", "darwin"),
            patch("trove.cli.stamp_creation_date", return_value=True) as mock_stamp,
        ):
            result = runner.invoke(
                cli, ["--db", str(db_path), "fix-created-dates", "Photos", "--apply", "--yes"],
            )

        assert result.exit_code == 0
        assert "Entries needing creation-date stamp: 0" in result.output
        assert "Nothing to update" in result.output
        mock_stamp.assert_not_called()

    def test_fix_created_dates_force_restamp(self, runner, db_path, tmp_path):
        """--force re-stamps entries that have already been stamped."""
        _, photo, entry = self._seed(db_path, tmp_path)
        with StateDB(db_path) as db:
            db.mark_entry_creation_date_stamped(entry.id)

        with (
            patch("trove.cli.sys.platform", "darwin"),
            patch("trove.cli.stamp_creation_date", return_value=True) as mock_stamp,
        ):
            result = runner.invoke(
                cli,
                ["--db", str(db_path), "fix-created-dates", "Photos", "--apply", "--yes", "--force"],
            )

        assert result.exit_code == 0
        assert "Updated Finder Date Created for 1 files." in result.output
        mock_stamp.assert_called_once_with(photo, "2024-01-15T10:30:00")


class TestAddCommand:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_with_yes(self, mock_meta, runner, db_path, tmp_path):
        """Add with --yes imports without prompts."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"photo content")

        mock_meta.return_value = {
            str(source / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source), "--yes"])
        assert result.exit_code == 0
        assert "Imported" in result.output

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_interactive_import(self, mock_meta, runner, db_path, tmp_path):
        """Add interactively — user picks import."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"photo content")

        mock_meta.return_value = {
            str(source / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        # User types "i" for import
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source)], input="i\n")
        assert result.exit_code == 0
        assert "Imported" in result.output

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_abort(self, mock_meta, runner, db_path, tmp_path):
        """Add interactively — user aborts."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"photo content")

        mock_meta.return_value = {
            str(source / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source)], input="a\n")
        assert result.exit_code == 0
        assert "Aborted" in result.output

    def test_add_unknown_library(self, runner, db_path, tmp_path):
        """Add with unknown library shows error."""
        source = tmp_path / "source"
        source.mkdir()
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Nope", str(source)])
        assert result.exit_code != 0
        assert "not found" in result.output.lower()

    def test_add_library_location_not_accessible_abort(self, runner, db_path, tmp_path):
        """Add when library location doesn't exist (NAS unmounted) — user aborts."""
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"photo content")

        # Create library pointing to a path, then remove it to simulate unmounted NAS
        lib_dir = tmp_path / "nas" / "photos"
        lib_dir.mkdir(parents=True)
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        lib_dir.rmdir()
        (tmp_path / "nas").rmdir()

        result = runner.invoke(
            cli, ["--db", str(db_path), "add", "Photos", str(source)], input="a\n"
        )
        assert result.exit_code != 0
        assert "not found" in result.output.lower()
        assert "mounted" in result.output.lower()

    def test_add_library_location_not_accessible_retry_succeeds(self, runner, db_path, tmp_path):
        """Add when library location doesn't exist — user retries after mounting, proceeds."""
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"photo content")

        lib_dir = tmp_path / "nas" / "photos"
        lib_dir.mkdir(parents=True)
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        lib_dir.rmdir()
        (tmp_path / "nas").rmdir()

        # Patch run_with_timeout so path_exists returns False first, True on retry.
        # All other calls go through the real implementation.
        call_count = {"n": 0}
        real_rwt = run_with_timeout

        def fake_rwt(fn, *args, **kwargs):
            if fn is path_exists:
                call_count["n"] += 1
                if call_count["n"] <= 1:
                    return False
                lib_dir.mkdir(parents=True, exist_ok=True)
                return True
            return real_rwt(fn, *args, **kwargs)

        with patch("trove.cli.run_with_timeout", side_effect=fake_rwt):
            result = runner.invoke(
                cli,
                ["--db", str(db_path), "add", "Photos", str(source), "--yes"],
                input="r\n",
            )
        assert "not found" in result.output.lower()
        assert "Scanning" in result.output  # proceeded after retry

    def test_add_source_not_readable(self, runner, db_path, tmp_path):
        """Add with source path that exists but isn't readable shows clean error."""
        source = tmp_path / "source"
        source.mkdir()

        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])

        # Make source unreadable
        source.chmod(0o000)
        try:
            result = runner.invoke(
                cli, ["--db", str(db_path), "add", "Photos", str(source)]
            )
            assert result.exit_code != 0
            assert "not readable" in result.output.lower() or "permission" in result.output.lower()
        finally:
            source.chmod(0o755)

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_library_path_uses_move_mode(self, mock_meta, runner, db_path, tmp_path):
        """Add with library's own path uses move/index mode."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        (lib_dir / "photo.jpg").write_bytes(b"photo content")

        mock_meta.return_value = {
            str(lib_dir / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)], input="n\nn\n")
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(lib_dir), "--yes"])
        assert result.exit_code == 0
        # Should show init-style output (Indexed/Moved), not import-style
        assert "Indexed" in result.output or "Moved" in result.output

    def test_add_no_path_nothing_queued(self, runner, db_path, tmp_path):
        """Add without path when nothing is queued reports nothing to do."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos"])
        assert result.exit_code == 0
        assert "Nothing to process" in result.output or "No files" in result.output

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_no_path_resumes(self, mock_meta, runner, db_path, tmp_path):
        """Add without path processes files already queued in DB, skips discovery."""
        from datetime import datetime, timezone

        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        (lib_dir / "photo.jpg").write_bytes(b"photo content")
        # Second file on disk but NOT in DB — proves discovery is skipped
        (lib_dir / "other.jpg").write_bytes(b"other content")

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])

        # Insert only photo.jpg at 'hashed' status (simulating interrupted add)
        photo = lib_dir / "photo.jpg"
        mtime = datetime.fromtimestamp(photo.stat().st_mtime, tz=timezone.utc).isoformat()
        md5 = hashlib.md5(b"photo content").hexdigest()
        with StateDB(db_path) as db:
            f = db.insert_file(str(photo), "local", photo.stat().st_size, mtime)
            db.update_file(f.id, md5_hash=md5, status="hashed")

        mock_meta.return_value = {
            str(photo): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", "--yes"])
        assert result.exit_code == 0
        # Should have processed the queued file
        assert "Indexed" in result.output or "Moved" in result.output

        # other.jpg should NOT have been picked up (discovery was skipped)
        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            entries = db.list_entries(lib.id)
            paths = {e.relative_path for e in entries}
            assert any("photo" in p for p in paths)
            assert not any("other" in p for p in paths)

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_symlinked_library_path_detected(self, mock_meta, runner, db_path, tmp_path):
        """Symlinked source path that resolves to library location uses move mode."""
        lib_dir = tmp_path / "photos"
        lib_dir.mkdir()
        (lib_dir / "photo.jpg").write_bytes(b"photo content")

        # Create symlink pointing to lib_dir
        link = tmp_path / "link_to_photos"
        link.symlink_to(lib_dir)

        mock_meta.return_value = {
            str(lib_dir / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)], input="n\nn\n")
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(link), "--yes"])
        assert result.exit_code == 0
        # Should use move mode (init-style output)
        assert "Indexed" in result.output or "Moved" in result.output


class TestVerifyCommand:
    def test_verify_empty_library(self, runner, db_path, tmp_path):
        """Verify empty library is healthy."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "verify", "Photos"])
        assert result.exit_code == 0
        assert "HEALTHY" in result.output

    def test_verify_unknown_library(self, runner, db_path):
        """Verify unknown library shows error."""
        result = runner.invoke(cli, ["--db", str(db_path), "verify", "Nope"])
        assert result.exit_code != 0

    @patch("trove.cli.verify_library")
    def test_verify_passes_progress(self, mock_verify, runner, db_path, tmp_path):
        """Verify command should pass a progress object into verify_library."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        mock_verify.return_value = VerifyResult(entries_checked=0, files_on_disk=0, verified_ok=0)

        result = runner.invoke(cli, ["--db", str(db_path), "verify", "Photos"])

        assert result.exit_code == 0
        assert mock_verify.call_count == 1
        assert mock_verify.call_args.kwargs["progress"] is not None


class TestDuplicatesCommand:
    def test_duplicates_no_duplicates(self, runner, db_path, tmp_path):
        """No duplicates shows message."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Photos"])
        assert result.exit_code == 0
        assert "No duplicates" in result.output

    def test_duplicates_unknown_library(self, runner, db_path):
        """Unknown library shows error."""
        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Nope"])
        assert result.exit_code != 0


class TestHashCommand:
    def test_hash_reports_missing_files_and_backfills_existing(self, runner, db_path, tmp_path):
        """Hash command backfills what it can and reports missing files."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        existing_path = lib_dir / "keep.jpg"
        existing_path.write_bytes(b"photo content")

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "keep.jpg", existing_path.stat().st_size, None, None, None)
            db.create_entry(lib.id, "gone.jpg", 123, None, None, None)

        result = runner.invoke(cli, ["--db", str(db_path), "hash", "Photos"])
        assert result.exit_code == 0
        assert "2 entries without hashes." in result.output
        assert "Done. 1 entries updated with hashes." in result.output
        assert "Remaining without hashes: 1" in result.output
        assert "Missing files: 1" in result.output
        assert "Unreadable files: 0" in result.output
        assert "gone.jpg" in result.output

        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            kept = db.get_entry_by_path(lib.id, "keep.jpg")
            missing = db.get_entry_by_path(lib.id, "gone.jpg")
            assert kept is not None
            assert kept.md5_hash == hashlib.md5(b"photo content").hexdigest()
            assert missing is not None
            assert missing.md5_hash is None

    @patch("trove.cli.hash_files_parallel", return_value={})
    def test_hash_reports_unreadable_files(self, _mock_hash, runner, db_path, tmp_path):
        """Files omitted from hash results but present on disk are reported unreadable."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        unreadable_path = lib_dir / "stuck.jpg"
        unreadable_path.write_bytes(b"photo content")

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "stuck.jpg", unreadable_path.stat().st_size, None, None, None)

        result = runner.invoke(cli, ["--db", str(db_path), "hash", "Photos"])
        assert result.exit_code == 0
        assert "Remaining without hashes: 1" in result.output
        assert "Missing files: 0" in result.output
        assert "Unreadable files: 1" in result.output
        assert "stuck.jpg" in result.output


class TestDedupeCommand:
    def test_dedupe_dry_run_prefers_original_basename(self, runner, db_path, tmp_path):
        """Dry-run keeps the entry whose managed basename matches original_path."""
        lib_dir = tmp_path / "library"
        (lib_dir / "2024" / "01").mkdir(parents=True)
        (lib_dir / "2024" / "01" / "photo.jpg").write_bytes(b"one")
        (lib_dir / "2024" / "01" / "photo_1.jpg").write_bytes(b"one")
        delete_list = tmp_path / "delete.txt"

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "2024/01/photo.jpg", 3, "samehash", None, None, original_path="source/photo.jpg")
            db.create_entry(lib.id, "2024/01/photo_1.jpg", 3, "samehash", None, None, original_path="source/photo.jpg")

        result = runner.invoke(
            cli,
            ["--db", str(db_path), "dedupe", "Photos", "--dry-run", "--delete-list", str(delete_list)],
        )
        assert result.exit_code == 0
        assert "keep 2024/01/photo.jpg" in result.output
        assert "delete 2024/01/photo_1.jpg" in result.output
        assert delete_list.read_text() == f"{lib_dir / '2024/01/photo_1.jpg'}\n"

        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            assert len(db.list_entries(lib.id)) == 2

    def test_dedupe_dry_run_and_apply_emit_same_delete_list_and_apply_cleanup(self, runner, db_path, tmp_path):
        """Dry-run and apply produce the same delete list, and apply removes only non-keepers."""
        lib_dir = tmp_path / "library"
        (lib_dir / "2024" / "01").mkdir(parents=True)
        (lib_dir / "2024" / "01" / "photo.jpg").write_bytes(b"one")
        (lib_dir / "2024" / "01" / "photo_1.jpg").write_bytes(b"one")
        dry_delete_list = tmp_path / "dry-delete.txt"
        apply_delete_list = tmp_path / "apply-delete.txt"

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "2024/01/photo.jpg", 3, "samehash", None, None)
            db.create_entry(lib.id, "2024/01/photo_1.jpg", 3, "samehash", None, None)

        dry_result = runner.invoke(
            cli,
            ["--db", str(db_path), "dedupe", "Photos", "--dry-run", "--delete-list", str(dry_delete_list)],
        )
        assert dry_result.exit_code == 0

        apply_result = runner.invoke(
            cli,
            ["--db", str(db_path), "dedupe", "Photos", "--apply", "--delete-list", str(apply_delete_list)],
        )
        assert apply_result.exit_code == 0
        assert dry_delete_list.read_text() == apply_delete_list.read_text()
        assert "Removed 1 duplicate entries" in apply_result.output

        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            remaining = db.list_entries(lib.id)
            assert len(remaining) == 1
            assert remaining[0].relative_path == "2024/01/photo.jpg"

    def test_dedupe_apply_falls_back_to_lowest_id_and_does_not_touch_other_libraries(
        self, runner, db_path, tmp_path
    ):
        """If no stronger signal exists, the lowest entry id wins within the targeted library only."""
        lib_dir = tmp_path / "library"
        other_dir = tmp_path / "other-library"
        (lib_dir / "2024" / "01").mkdir(parents=True)
        (other_dir / "2024" / "01").mkdir(parents=True)
        delete_list = tmp_path / "delete.txt"

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            other = db.create_library("Other", str(other_dir))
            first = db.create_entry(lib.id, "2024/01/photo_1.jpg", 3, "samehash", None, None)
            db.create_entry(lib.id, "2024/01/photo_2.jpg", 3, "samehash", None, None)
            db.create_entry(other.id, "2024/01/photo_1.jpg", 3, "samehash", None, None)
            db.create_entry(other.id, "2024/01/photo_2.jpg", 3, "samehash", None, None)

        result = runner.invoke(
            cli,
            ["--db", str(db_path), "dedupe", "Photos", "--apply", "--delete-list", str(delete_list)],
        )
        assert result.exit_code == 0
        assert str(lib_dir / "2024/01/photo_2.jpg") in delete_list.read_text()

        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            other = db.get_library("Other")
            remaining = db.list_entries(lib.id)
            other_entries = db.list_entries(other.id)
            assert len(remaining) == 1
            assert remaining[0].id == first.id
            assert len(other_entries) == 2

    def test_dedupe_requires_hash_backfill_first(self, runner, db_path, tmp_path):
        """Cleanup refuses to run while the library still has entries without hashes."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        delete_list = tmp_path / "delete.txt"

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "photo.jpg", 3, None, None, None)

        result = runner.invoke(
            cli,
            ["--db", str(db_path), "dedupe", "Photos", "--dry-run", "--delete-list", str(delete_list)],
        )
        assert result.exit_code != 0
        assert "requires hash backfill first" in result.output
        assert not delete_list.exists()


class TestStatusCommand:
    def test_status_unknown_library(self, runner, db_path):
        """Status with unknown library shows error."""
        result = runner.invoke(cli, ["--db", str(db_path), "status", "Nope"])
        assert result.exit_code != 0

    def test_status_with_library(self, runner, db_path, tmp_path):
        """Status for a specific library."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "status", "Photos"])
        assert result.exit_code == 0
        assert "Photos" in result.output


    def test_status_shows_missing_count(self, runner, db_path, tmp_path):
        """Status shows missing file count when files have status=missing."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        # Insert missing file records directly
        with StateDB(db_path) as db:
            f = db.insert_file(str(lib_dir / "gone.jpg"), "local", 100, "2024-01-01T00:00:00")
            db.update_file(f.id, status="missing", error_message="source_missing")
        result = runner.invoke(cli, ["--db", str(db_path), "status", "Photos"])
        assert result.exit_code == 0
        assert "Missing" in result.output or "missing" in result.output

    def test_status_missing_flag_lists_files(self, runner, db_path, tmp_path):
        """--missing flag lists missing file paths."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        with StateDB(db_path) as db:
            f = db.insert_file(str(lib_dir / "gone.jpg"), "local", 100, "2024-01-01T00:00:00")
            db.update_file(f.id, status="missing", error_message="source_missing")
        result = runner.invoke(cli, ["--db", str(db_path), "status", "Photos", "--missing"])
        assert result.exit_code == 0
        assert "gone.jpg" in result.output

    def test_status_clear_missing(self, runner, db_path, tmp_path):
        """--clear-missing removes missing file records."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        with StateDB(db_path) as db:
            f = db.insert_file(str(lib_dir / "gone.jpg"), "local", 100, "2024-01-01T00:00:00")
            db.update_file(f.id, status="missing", error_message="source_missing")
        result = runner.invoke(cli, ["--db", str(db_path), "status", "Photos", "--clear-missing"], input="y\n")
        assert result.exit_code == 0
        # Record should be gone
        with StateDB(db_path) as db:
            missing = db.query_files_by_status("missing")
            assert len(missing) == 0


class TestAddDuplicateReview:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_add_interactive_review_duplicates(self, mock_meta, runner, db_path, tmp_path):
        """Add with batch duplicates — user can review them."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()
        content = b"identical"
        (source / "a.jpg").write_bytes(content)
        (source / "b.jpg").write_bytes(content)

        mock_meta.return_value = {
            str(source / "a.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(source / "b.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        # User reviews duplicates (d), then imports (i)
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source)], input="d\ni\n")
        assert result.exit_code == 0
        assert "within source" in result.output.lower() or "identical content" in result.output.lower()
        assert "Imported" in result.output


class TestAddEndToEnd:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_full_pipeline_with_yes(self, mock_meta, runner, db_path, tmp_path):
        """Full add pipeline end-to-end with --yes."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"photo content")

        mock_meta.return_value = {
            str(source / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal")
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source), "--yes"])

        assert result.exit_code == 0
        assert "Imported" in result.output
        # File should exist in library
        assert any(lib_dir.rglob("photo.jpg"))


class TestAddResumeAfterCrash:
    """Integration tests: simulate a crash by inserting stale DB state, then re-run add."""

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_after_crash_during_metadata(self, mock_meta, runner, db_path, tmp_path):
        """Crash after hashing, before metadata extraction.
        Stale files at status='hashed' with no capture_date should be picked up on re-run.
        """
        from datetime import datetime, timezone

        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()

        content_a = b"photo A content"
        content_b = b"photo B content"
        pa = source / "a.jpg"
        pb = source / "b.jpg"
        pa.write_bytes(content_a)
        pb.write_bytes(content_b)
        hash_a = hashlib.md5(content_a).hexdigest()
        hash_b = hashlib.md5(content_b).hexdigest()

        # Capture real file stats so DB records match disk (simulating a real prior scan)
        def _mtime_iso(p):
            return datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc).isoformat()

        # Create library
        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])

        # Simulate crash state: files discovered + hashed but no metadata.
        # DB records must match real file size+mtime so discover_and_persist skips them.
        with StateDB(db_path) as db:
            fa = db.insert_file(str(pa), "local", pa.stat().st_size, _mtime_iso(pa))
            db.update_file(fa.id, md5_hash=hash_a, status="hashed")

            fb = db.insert_file(str(pb), "local", pb.stat().st_size, _mtime_iso(pb))
            db.update_file(fb.id, md5_hash=hash_b, status="hashed")

        # Mock metadata for the resume run
        mock_meta.return_value = {
            str(pa): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
            str(pb): FileMetadata("2024-06-20T14:00:00", "Nikon", "DateTimeOriginal"),
        }

        # Re-run add — should resume and import both files
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source), "--yes"])

        assert result.exit_code == 0, f"CLI failed:\n{result.output}"
        assert "Resuming 2 files from previous run" in result.output
        assert "Imported 2" in result.output

        # Both files should be in the library
        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            entries = db.list_entries(lib.id)
            assert len(entries) == 2

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_partial_metadata(self, mock_meta, runner, db_path, tmp_path):
        """Crash after extracting metadata for some files but not all.
        Files with metadata + target_path go straight to classify.
        Files without metadata get extracted.
        """
        from datetime import datetime, timezone

        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()

        content_done = b"already has metadata"
        content_todo = b"still needs metadata"
        p_done = source / "done.jpg"
        p_todo = source / "todo.jpg"
        p_done.write_bytes(content_done)
        p_todo.write_bytes(content_todo)
        hash_done = hashlib.md5(content_done).hexdigest()
        hash_todo = hashlib.md5(content_todo).hexdigest()

        def _mtime_iso(p):
            return datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc).isoformat()

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])

        # Simulate: done.jpg has metadata + target_path; todo.jpg only has hash
        with StateDB(db_path) as db:
            fd = db.insert_file(str(p_done), "local", p_done.stat().st_size, _mtime_iso(p_done))
            db.update_file(
                fd.id,
                md5_hash=hash_done,
                status="hashed",
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon",
                target_path="2024/01/Canon/done.jpg",
            )

            ft = db.insert_file(str(p_todo), "local", p_todo.stat().st_size, _mtime_iso(p_todo))
            db.update_file(ft.id, md5_hash=hash_todo, status="hashed")
            # todo.jpg has NO capture_date or target_path

        # Only todo.jpg needs metadata extraction
        mock_meta.return_value = {
            str(p_todo): FileMetadata("2024-06-20T14:00:00", "Nikon", "DateTimeOriginal"),
        }

        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source), "--yes"])

        assert result.exit_code == 0, f"CLI failed:\n{result.output}"
        assert "Resuming 2 files" in result.output
        assert "Imported 2" in result.output

        with StateDB(db_path) as db:
            lib = db.get_library("Photos")
            entries = db.list_entries(lib.id)
            assert len(entries) == 2
            paths = {e.relative_path for e in entries}
            assert any("done.jpg" in p for p in paths)
            assert any("todo.jpg" in p for p in paths)

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_no_stale_files(self, mock_meta, runner, db_path, tmp_path):
        """Clean run (no previous crash) should not show resume message."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source = tmp_path / "source"
        source.mkdir()
        (source / "photo.jpg").write_bytes(b"fresh content")

        mock_meta.return_value = {
            str(source / "photo.jpg"): FileMetadata("2024-01-15T10:30:00", "Canon", "DateTimeOriginal"),
        }

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])
        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source), "--yes"])

        assert result.exit_code == 0
        assert "Resuming" not in result.output
        assert "Imported 1" in result.output

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_resume_ignores_other_source(self, mock_meta, runner, db_path, tmp_path):
        """Stale files from a different source directory should NOT be picked up."""
        from datetime import datetime, timezone

        lib_dir = tmp_path / "library"
        lib_dir.mkdir()
        source_a = tmp_path / "source_a"
        source_a.mkdir()
        source_b = tmp_path / "source_b"
        source_b.mkdir()

        pa = source_a / "a.jpg"
        pb = source_b / "b.jpg"
        pa.write_bytes(b"from source A")
        pb.write_bytes(b"from source B")

        def _mtime_iso(p):
            return datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc).isoformat()

        runner.invoke(cli, ["--db", str(db_path), "create", "Photos", str(lib_dir)])

        # Simulate crash: stale file from source_a (must match real file stats)
        with StateDB(db_path) as db:
            fa = db.insert_file(str(pa), "local", pa.stat().st_size, _mtime_iso(pa))
            db.update_file(fa.id, md5_hash=hashlib.md5(b"from source A").hexdigest(), status="hashed")

        # Now add from source_b — should NOT pick up source_a's stale file
        mock_meta.return_value = {
            str(pb): FileMetadata("2024-06-20T14:00:00", "Nikon", "DateTimeOriginal"),
        }

        result = runner.invoke(cli, ["--db", str(db_path), "add", "Photos", str(source_b), "--yes"])

        assert result.exit_code == 0, f"CLI failed:\n{result.output}"
        assert "Resuming" not in result.output
        assert "Imported 1" in result.output

        # source_a's stale file should still be in DB (untouched)
        with StateDB(db_path) as db:
            stale = db.query_files_by_status("hashed")
            assert len(stale) == 1
            assert "source_a" in stale[0].source_path
