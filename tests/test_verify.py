import hashlib
from pathlib import Path

import pytest

from trove.verify import verify_library


class TestHealthyLibrary:
    def test_all_entries_match_disk(self, db, library):
        """All entries have matching files on disk, no orphans."""
        lib_dir = Path(library.location)

        # Create files and entries
        content = b"photo content"
        content_hash = hashlib.md5(content).hexdigest()

        dest = lib_dir / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(content)

        db.create_entry(
            library.id, "2024/01/Canon/photo.jpg", len(content), content_hash, "2024-01-01T00:00:00", "Canon"
        )

        result = verify_library(db, library)

        assert result.is_healthy is True
        assert result.entries_checked == 1
        assert result.verified_ok == 1
        assert result.missing_from_disk == []
        assert result.orphan_files == []
        assert result.size_mismatches == []
        assert result.hash_mismatches == []


class TestMissingFromDisk:
    def test_detects_missing_file(self, db, library):
        """Entry exists but file is missing from disk."""
        content = b"gone"
        content_hash = hashlib.md5(content).hexdigest()
        db.create_entry(
            library.id, "2024/01/Canon/gone.jpg", len(content), content_hash, "2024-01-01T00:00:00", "Canon"
        )
        # Don't create the file on disk

        result = verify_library(db, library)

        assert result.is_healthy is False
        assert result.missing_from_disk == ["2024/01/Canon/gone.jpg"]
        assert result.verified_ok == 0


class TestOrphanFiles:
    def test_detects_orphan_file(self, db, library):
        """File on disk with no entry in DB."""
        lib_dir = Path(library.location)
        orphan = lib_dir / "2024/01/Canon/orphan.jpg"
        orphan.parent.mkdir(parents=True)
        orphan.write_bytes(b"orphan data")

        result = verify_library(db, library)

        assert result.is_healthy is False
        assert "2024/01/Canon/orphan.jpg" in result.orphan_files


class TestSizeMismatch:
    def test_detects_size_mismatch(self, db, library):
        """File on disk has different size than entry."""
        lib_dir = Path(library.location)
        content_original = b"original content"
        content_hash = hashlib.md5(content_original).hexdigest()

        dest = lib_dir / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(b"shorter")  # different size

        db.create_entry(
            library.id, "2024/01/Canon/photo.jpg", len(content_original), content_hash, "2024-01-01T00:00:00", "Canon"
        )

        result = verify_library(db, library)

        assert result.is_healthy is False
        assert "2024/01/Canon/photo.jpg" in result.size_mismatches


class TestHashMismatch:
    def test_thorough_detects_hash_mismatch(self, db, library):
        """With thorough=True, detects content change (same size, different hash)."""
        lib_dir = Path(library.location)
        content_original = b"AAAAAAAAAA"  # 10 bytes
        content_tampered = b"BBBBBBBBBB"  # 10 bytes, same size
        original_hash = hashlib.md5(content_original).hexdigest()

        dest = lib_dir / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(content_tampered)

        db.create_entry(
            library.id, "2024/01/Canon/photo.jpg", len(content_original), original_hash, "2024-01-01T00:00:00", "Canon"
        )

        result = verify_library(db, library, thorough=True)

        assert result.is_healthy is False
        assert "2024/01/Canon/photo.jpg" in result.hash_mismatches

    def test_not_thorough_skips_hash_check(self, db, library):
        """Without thorough, hash mismatches not checked."""
        lib_dir = Path(library.location)
        content_original = b"AAAAAAAAAA"
        content_tampered = b"BBBBBBBBBB"
        original_hash = hashlib.md5(content_original).hexdigest()

        dest = lib_dir / "2024/01/Canon/photo.jpg"
        dest.parent.mkdir(parents=True)
        dest.write_bytes(content_tampered)

        db.create_entry(
            library.id, "2024/01/Canon/photo.jpg", len(content_original), original_hash, "2024-01-01T00:00:00", "Canon"
        )

        result = verify_library(db, library, thorough=False)

        # Size matches so it passes without thorough
        assert result.is_healthy is True
        assert result.hash_mismatches == []
        assert result.verified_ok == 1


class TestEmptyLibrary:
    def test_empty_library_is_healthy(self, db, library):
        """No entries, no files: healthy."""
        result = verify_library(db, library)
        assert result.is_healthy is True
        assert result.entries_checked == 0
        assert result.files_on_disk == 0


class TestLibraryNotAccessible:
    def test_missing_location_raises(self, db):
        """Library location doesn't exist: raises ValueError."""
        lib = db.create_library("Bad Library", "/nonexistent/path")
        with pytest.raises(ValueError, match="not accessible"):
            verify_library(db, lib)
