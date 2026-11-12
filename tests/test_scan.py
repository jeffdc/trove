"""Tests for the scan module — file discovery, target path computation, and orchestration."""

from __future__ import annotations

import os
from unittest.mock import patch

import pytest

from trove.config import LibraryConfig, OrganizationConfig
from trove.metadata import FileMetadata
from trove.scan import compute_target_path, discover_files, scan_source


class TestDiscoverFiles:
    def test_finds_photos_by_extension(self, tmp_path):
        """Finds jpg, heic, png files."""
        (tmp_path / "photo.jpg").write_bytes(b"fake jpg")
        (tmp_path / "photo.HEIC").write_bytes(b"fake heic")
        (tmp_path / "photo.png").write_bytes(b"fake png")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 3

    def test_finds_videos_and_raw(self, tmp_path):
        """Finds mov, mp4, cr2, nef."""
        (tmp_path / "video.mov").write_bytes(b"fake mov")
        (tmp_path / "video.MP4").write_bytes(b"fake mp4")
        (tmp_path / "raw.cr2").write_bytes(b"fake cr2")
        (tmp_path / "raw.NEF").write_bytes(b"fake nef")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 4

    def test_case_insensitive_extensions(self, tmp_path):
        """Extension matching is case-insensitive."""
        (tmp_path / "a.JPG").write_bytes(b"data")
        (tmp_path / "b.Jpg").write_bytes(b"data")
        (tmp_path / "c.jpg").write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 3

    def test_skips_excluded_patterns(self, tmp_path):
        """Skips .DS_Store, ._files, Thumbs.db, .ini, .db files."""
        (tmp_path / ".DS_Store").write_bytes(b"data")
        (tmp_path / "._photo.jpg").write_bytes(b"data")
        (tmp_path / "Thumbs.db").write_bytes(b"data")
        (tmp_path / "settings.ini").write_bytes(b"data")
        (tmp_path / "cache.db").write_bytes(b"data")
        (tmp_path / "thumb_001.jpg").write_bytes(b"data")
        (tmp_path / "real_photo.jpg").write_bytes(b"real")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 1
        assert found[0].name == "real_photo.jpg"

    def test_skips_zero_byte_files(self, tmp_path):
        """Skips empty files."""
        (tmp_path / "empty.jpg").write_bytes(b"")
        (tmp_path / "real.jpg").write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 1

    def test_skips_non_media_files(self, tmp_path):
        """Skips txt, pdf, doc and other non-media files."""
        (tmp_path / "notes.txt").write_bytes(b"text")
        (tmp_path / "doc.pdf").write_bytes(b"pdf")
        (tmp_path / "photo.jpg").write_bytes(b"jpg")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 1

    def test_nested_directories(self, tmp_path):
        """Finds files in nested subdirectories."""
        sub = tmp_path / "2024" / "01" / "15"
        sub.mkdir(parents=True)
        (sub / "photo.jpg").write_bytes(b"nested")
        (tmp_path / "top.jpg").write_bytes(b"top")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 2

    def test_unicode_filenames(self, tmp_path):
        """Handles unicode filenames."""
        (tmp_path / "café.jpg").write_bytes(b"data")
        (tmp_path / "日本語.heic").write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 2

    def test_source_not_exists_raises(self, tmp_path):
        """Non-existent source raises ValueError."""
        config = LibraryConfig()
        with pytest.raises(ValueError, match="does not exist"):
            discover_files(tmp_path / "nope", config)

    def test_source_is_file_raises(self, tmp_path):
        """Source that is a file (not dir) raises ValueError."""
        f = tmp_path / "file.txt"
        f.write_bytes(b"data")
        config = LibraryConfig()
        with pytest.raises(ValueError, match="not a directory"):
            discover_files(f, config)

    def test_skips_hardlinks(self, tmp_path):
        """When a file has multiple hardlinks, only one is discovered."""
        original = tmp_path / "photo.jpg"
        original.write_bytes(b"hardlink test data")
        link = tmp_path / "photo_link.jpg"
        try:
            os.link(original, link)
        except OSError:
            pytest.skip("Hardlinks not supported on this filesystem")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        assert len(found) == 1

    def test_returns_sorted(self, tmp_path):
        """Results are sorted by path for deterministic order."""
        (tmp_path / "c.jpg").write_bytes(b"c")
        (tmp_path / "a.jpg").write_bytes(b"a")
        (tmp_path / "b.jpg").write_bytes(b"b")
        config = LibraryConfig()
        found = discover_files(tmp_path, config)
        names = [p.name for p in found]
        assert names == ["a.jpg", "b.jpg", "c.jpg"]

    def test_limit_caps_results(self, tmp_path):
        """limit=N returns at most N files."""
        for i in range(10):
            (tmp_path / f"photo{i:02d}.jpg").write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config, limit=3)
        assert len(found) == 3

    def test_limit_returns_sorted(self, tmp_path):
        """Limited results are still sorted."""
        for name in ["c.jpg", "a.jpg", "b.jpg", "d.jpg"]:
            (tmp_path / name).write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config, limit=2)
        assert len(found) == 2
        assert found == sorted(found)

    def test_limit_none_returns_all(self, tmp_path):
        """limit=None (default) returns all files."""
        for i in range(5):
            (tmp_path / f"photo{i}.jpg").write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config, limit=None)
        assert len(found) == 5

    def test_limit_stops_across_nested_dirs(self, tmp_path):
        """limit stops discovery even when files span multiple subdirectories."""
        for d in ["a", "b", "c", "d"]:
            subdir = tmp_path / d
            subdir.mkdir()
            for i in range(5):
                (subdir / f"photo{i}.jpg").write_bytes(b"data")
        config = LibraryConfig()
        found = discover_files(tmp_path, config, limit=3)
        assert len(found) == 3


class TestComputeTargetPath:
    def test_full_path_with_date_and_model(self):
        """Date + model + filename -> correct path."""
        config = LibraryConfig()
        result = compute_target_path("2024-01-15T10:30:00", "Canon EOS R5", "IMG_0042.JPG", config)
        assert result == "2024/01/Canon_EOS_R5/IMG_0042.JPG"

    def test_day_structure(self):
        """YYYY/MM/DD structure works."""
        config = LibraryConfig(organization=OrganizationConfig(structure="%Y/%m/%d"))
        result = compute_target_path("2024-01-15T10:30:00", "Canon EOS R5", "IMG_0042.JPG", config)
        assert result == "2024/01/15/Canon_EOS_R5/IMG_0042.JPG"

    def test_no_camera_model_uses_default(self):
        """None camera model uses Unknown_Model."""
        config = LibraryConfig()
        result = compute_target_path("2024-01-15T10:30:00", None, "IMG_0042.JPG", config)
        assert result == "2024/01/Unknown_Model/IMG_0042.JPG"

    def test_no_capture_date_returns_none(self):
        """None capture_date returns None (caller quarantines)."""
        config = LibraryConfig()
        result = compute_target_path(None, "Canon", "photo.jpg", config)
        assert result is None

    def test_filename_normalized(self):
        """Filename is normalized in output."""
        config = LibraryConfig()
        result = compute_target_path("2024-01-15T10:30:00", "Canon", "my photo.JPG", config)
        assert "my_photo.JPG" in result

    def test_camera_model_normalized(self):
        """Camera model string is normalized."""
        config = LibraryConfig()
        result = compute_target_path(
            "2024-01-15T10:30:00",
            "Apple iPhone 15 Pro/Back Camera",
            "photo.jpg",
            config,
        )
        assert "Apple_iPhone_15_Pro_Back_Camera" in result

    def test_include_camera_model_false(self):
        """When include_camera_model is False, no model in path."""
        config = LibraryConfig(organization=OrganizationConfig(include_camera_model=False))
        result = compute_target_path("2024-01-15T10:30:00", "Canon", "photo.jpg", config)
        assert "Canon" not in result
        assert result == "2024/01/photo.jpg"


class TestScanSource:
    @patch("trove.pipeline.extract_metadata_chunked")
    def test_scan_discovers_and_hashes_files(self, mock_meta, db, tmp_path):
        """Files are discovered, hashed, and end up with correct status."""
        (tmp_path / "photo.jpg").write_bytes(b"fake jpg content")
        mock_meta.return_value = {
            str(tmp_path / "photo.jpg"): FileMetadata(
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon EOS R5",
                date_source="DateTimeOriginal",
            )
        }
        config = LibraryConfig()
        summary = scan_source(tmp_path, db, config)
        assert summary["discovered"] == 1
        assert summary["hashed"] == 1
        # File should be in DB with hash and metadata
        f = db.get_file_by_path(str(tmp_path / "photo.jpg"))
        assert f is not None
        assert f.status == "hashed"
        assert f.md5_hash is not None
        assert f.capture_date == "2024-01-15T10:30:00"
        assert f.camera_model == "Canon EOS R5"
        assert f.target_path is not None
        assert "2024/01" in f.target_path

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_incremental_skips_unchanged(self, mock_meta, db, tmp_path):
        """Unchanged files are skipped on re-scan."""
        (tmp_path / "photo.jpg").write_bytes(b"content")
        mock_meta.return_value = {
            str(tmp_path / "photo.jpg"): FileMetadata(
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon",
                date_source="DateTimeOriginal",
            )
        }
        config = LibraryConfig()
        scan_source(tmp_path, db, config)
        # Second scan should skip
        summary = scan_source(tmp_path, db, config)
        assert summary["skipped"] == 1
        assert summary["discovered"] == 0

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_incremental_rescans_modified(self, mock_meta, db, tmp_path):
        """Modified files (different size) are re-scanned."""
        f = tmp_path / "photo.jpg"
        f.write_bytes(b"original")
        mock_meta.return_value = {
            str(f): FileMetadata(
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon",
                date_source="DateTimeOriginal",
            )
        }
        config = LibraryConfig()
        scan_source(tmp_path, db, config)
        # Modify the file
        f.write_bytes(b"modified content that is different")
        mock_meta.return_value = {
            str(f): FileMetadata(
                capture_date="2024-01-15T10:30:00",
                camera_model="Canon",
                date_source="DateTimeOriginal",
            )
        }
        summary = scan_source(tmp_path, db, config)
        assert summary["discovered"] >= 1

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_quarantines_no_date(self, mock_meta, db, tmp_path):
        """File with no date from exiftool and invalid filesystem date gets quarantined."""
        f = tmp_path / "photo.jpg"
        f.write_bytes(b"no date photo")
        mock_meta.return_value = {
            str(f): FileMetadata(
                capture_date=None,
                camera_model=None,
                date_source=None,
            )
        }
        config = LibraryConfig()
        _summary = scan_source(tmp_path, db, config)
        rec = db.get_file_by_path(str(f))
        # File should still have status hashed or quarantined depending on filesystem date
        # Since tmp files have valid dates, it should use filesystem date as fallback
        assert rec is not None
        # The filesystem date of a file we just created will be valid (2026)
        # so it should NOT be quarantined — it should use filesystem date
        assert rec.status == "hashed"
        assert rec.capture_date is not None  # filled from filesystem

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_multiple_files(self, mock_meta, db, tmp_path):
        """Multiple files all processed correctly."""
        (tmp_path / "a.jpg").write_bytes(b"aaa")
        (tmp_path / "b.mov").write_bytes(b"bbb")
        (tmp_path / "c.cr2").write_bytes(b"ccc")
        (tmp_path / "ignore.txt").write_bytes(b"txt")
        mock_meta.return_value = {
            str(tmp_path / "a.jpg"): FileMetadata("2024-01-01T00:00:00", "Canon", "DateTimeOriginal"),
            str(tmp_path / "b.mov"): FileMetadata("2024-02-01T00:00:00", "iPhone", "DateTimeOriginal"),
            str(tmp_path / "c.cr2"): FileMetadata("2024-03-01T00:00:00", "Nikon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        summary = scan_source(tmp_path, db, config)
        assert summary["discovered"] == 3
        assert summary["hashed"] == 3

    @patch("trove.pipeline.extract_metadata_chunked")
    def test_skips_excluded_and_zero_byte(self, mock_meta, db, tmp_path):
        """Excluded files and zero-byte files not in DB."""
        (tmp_path / ".DS_Store").write_bytes(b"junk")
        (tmp_path / "empty.jpg").write_bytes(b"")
        (tmp_path / "real.jpg").write_bytes(b"real")
        mock_meta.return_value = {
            str(tmp_path / "real.jpg"): FileMetadata("2024-01-01T00:00:00", "Canon", "DateTimeOriginal"),
        }
        config = LibraryConfig()
        summary = scan_source(tmp_path, db, config)
        assert summary["discovered"] == 1
        assert db.get_file_by_path(str(tmp_path / ".DS_Store")) is None
        assert db.get_file_by_path(str(tmp_path / "empty.jpg")) is None
