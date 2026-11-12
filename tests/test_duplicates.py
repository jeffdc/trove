"""Tests for the duplicates command and get_duplicate_groups method."""

from __future__ import annotations

from unittest.mock import patch

import pytest
from click.testing import CliRunner

from trove.cli import cli
from trove.db import StateDB


@pytest.fixture
def runner():
    return CliRunner()


@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "test.db"


class TestDuplicateGroups:
    def test_get_duplicate_groups_returns_groups(self, db, library):
        """Returns groups of entries with same hash."""
        db.create_entry(library.id, "a.jpg", 100, "hash1", None, None)
        db.create_entry(library.id, "b.jpg", 100, "hash1", None, None)
        db.create_entry(library.id, "c.jpg", 200, "hash2", None, None)

        groups = db.get_duplicate_groups(library.id)
        assert len(groups) == 1  # only hash1 has duplicates
        assert len(groups[0]) == 2

    def test_no_duplicates_returns_empty(self, db, library):
        """No duplicates returns empty list."""
        db.create_entry(library.id, "a.jpg", 100, "hash1", None, None)
        db.create_entry(library.id, "b.jpg", 200, "hash2", None, None)

        groups = db.get_duplicate_groups(library.id)
        assert groups == []

    def test_null_hash_groups_are_ignored(self, db, library):
        """Rows with null md5_hash are not treated as duplicate groups."""
        db.create_entry(library.id, "a.jpg", 100, None, None, None)
        db.create_entry(library.id, "b.jpg", 100, None, None, None)

        groups = db.get_duplicate_groups(library.id)
        assert groups == []

    def test_multiple_groups(self, db, library):
        """Multiple duplicate groups returned."""
        db.create_entry(library.id, "a1.jpg", 100, "hash1", None, None)
        db.create_entry(library.id, "a2.jpg", 100, "hash1", None, None)
        db.create_entry(library.id, "b1.jpg", 200, "hash2", None, None)
        db.create_entry(library.id, "b2.jpg", 200, "hash2", None, None)
        db.create_entry(library.id, "b3.jpg", 200, "hash2", None, None)
        db.create_entry(library.id, "unique.jpg", 300, "hash3", None, None)

        groups = db.get_duplicate_groups(library.id)
        assert len(groups) == 2
        sizes = sorted(len(g) for g in groups)
        assert sizes == [2, 3]


class TestDuplicatesCommand:
    def test_duplicates_lists_groups(self, runner, db_path, tmp_path):
        """Duplicates command lists duplicate groups."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "a.jpg", 1024, "aabbccdd", "2024-01-15T10:30:00", "Canon")
            db.create_entry(lib.id, "b.jpg", 1024, "aabbccdd", "2024-01-15T10:30:00", "Canon")

        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Photos"])
        assert result.exit_code == 0
        assert "1 duplicate group" in result.output
        assert "a.jpg" in result.output
        assert "b.jpg" in result.output

    def test_duplicates_no_duplicates(self, runner, db_path, tmp_path):
        """No duplicates shows message."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()

        with StateDB(db_path) as db:
            db.create_library("Photos", str(lib_dir))

        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Photos"])
        assert result.exit_code == 0
        assert "No duplicates found" in result.output

    def test_duplicates_unknown_library(self, runner, db_path):
        """Unknown library shows error."""
        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Nope"])
        assert result.exit_code != 0
        assert "not found" in result.output.lower()

    @patch("trove.cli.click.launch")
    def test_duplicates_report_flag(self, mock_launch, runner, db_path, tmp_path):
        """--report flag generates HTML report."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()

        with StateDB(db_path) as db:
            lib = db.create_library("Photos", str(lib_dir))
            db.create_entry(lib.id, "a.jpg", 1024, "aabbccdd", "2024-01-15T10:30:00", "Canon")
            db.create_entry(lib.id, "b.jpg", 1024, "aabbccdd", "2024-01-15T10:30:00", "Canon")

        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Photos", "--report"])
        assert result.exit_code == 0
        assert "Report generated" in result.output
        assert "trove_duplicates_report.html" in result.output

        # Verify the report was created
        report_path = lib_dir / "trove_duplicates_report.html"
        assert report_path.exists()
        content = report_path.read_text()
        assert "Duplicate Report" in content or "Duplicates" in content
        assert "aabbccdd" in content or "aabb" in content  # Hash should be in report
        # Verify click.launch was called to open the report
        mock_launch.assert_called_once()

    def test_duplicates_report_no_duplicates(self, runner, db_path, tmp_path):
        """--report flag with no duplicates shows message instead of report."""
        lib_dir = tmp_path / "library"
        lib_dir.mkdir()

        with StateDB(db_path) as db:
            db.create_library("Photos", str(lib_dir))

        result = runner.invoke(cli, ["--db", str(db_path), "duplicates", "Photos", "--report"])
        assert result.exit_code == 0
        assert "No duplicates found" in result.output
