from __future__ import annotations

from trove.report import DuplicateGroup, generate_duplicate_report


class TestGenerateReport:
    def test_generates_html_file(self, tmp_path):
        """Report generates a valid HTML file."""
        output = tmp_path / "report.html"
        batch = [
            DuplicateGroup(
                md5_hash="abc123",
                files=[
                    {
                        "path": "/tmp/a.jpg",
                        "size": 1024,
                        "capture_date": "2024-01-15",
                        "camera_model": "Canon",
                        "is_library": False,
                    },
                    {
                        "path": "/tmp/b.jpg",
                        "size": 1024,
                        "capture_date": "2024-01-15",
                        "camera_model": "Canon",
                        "is_library": False,
                    },
                ],
            )
        ]
        generate_duplicate_report(batch, [], output, "Test Library")
        assert output.exists()
        content = output.read_text()
        assert "<html" in content
        assert "abc123" in content

    def test_report_has_both_sections(self, tmp_path):
        """Report includes batch and library sections."""
        output = tmp_path / "report.html"
        batch = [
            DuplicateGroup(
                md5_hash="hash1",
                files=[
                    {
                        "path": "/tmp/a.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                    {
                        "path": "/tmp/b.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                ],
            )
        ]
        library = [
            DuplicateGroup(
                md5_hash="hash2",
                files=[
                    {
                        "path": "/tmp/c.jpg",
                        "size": 2048,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                    {
                        "path": "/lib/d.jpg",
                        "size": 2048,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": True,
                    },
                ],
            )
        ]
        generate_duplicate_report(batch, library, output, "Test Library")
        content = output.read_text()
        assert "within" in content.lower() or "source" in content.lower()
        assert "library" in content.lower()

    def test_report_contains_file_links(self, tmp_path):
        """Report contains file:// links."""
        output = tmp_path / "report.html"
        batch = [
            DuplicateGroup(
                md5_hash="hash1",
                files=[
                    {
                        "path": "/Users/test/photo.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                    {
                        "path": "/Users/test/photo-1.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                ],
            )
        ]
        generate_duplicate_report(batch, [], output, "Test Library")
        content = output.read_text()
        assert "file:///Users/test/photo.jpg" in content

    def test_report_has_image_thumbnails(self, tmp_path):
        """Report includes img tags for image files."""
        output = tmp_path / "report.html"
        batch = [
            DuplicateGroup(
                md5_hash="hash1",
                files=[
                    {
                        "path": "/tmp/photo.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                    {
                        "path": "/tmp/photo-1.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                ],
            )
        ]
        generate_duplicate_report(batch, [], output, "Test Library")
        content = output.read_text()
        assert "<img" in content
        assert "file:///tmp/photo.jpg" in content

    def test_report_labels_library_files(self, tmp_path):
        """Library files are labeled in the report."""
        output = tmp_path / "report.html"
        library = [
            DuplicateGroup(
                md5_hash="hash1",
                files=[
                    {
                        "path": "/tmp/source.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                    {
                        "path": "/lib/existing.jpg",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": True,
                    },
                ],
            )
        ]
        generate_duplicate_report([], library, output, "Test Library")
        content = output.read_text()
        assert "in library" in content.lower() or "library" in content.lower()

    def test_report_empty_groups(self, tmp_path):
        """Report handles empty group lists."""
        output = tmp_path / "report.html"
        generate_duplicate_report([], [], output, "Test Library")
        assert output.exists()
        content = output.read_text()
        assert "no duplicates" in content.lower() or "0" in content

    def test_report_non_image_no_thumbnail(self, tmp_path):
        """Non-image files don't get thumbnails."""
        output = tmp_path / "report.html"
        batch = [
            DuplicateGroup(
                md5_hash="hash1",
                files=[
                    {
                        "path": "/tmp/video.mov",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                    {
                        "path": "/tmp/video-1.mov",
                        "size": 1024,
                        "capture_date": None,
                        "camera_model": None,
                        "is_library": False,
                    },
                ],
            )
        ]
        generate_duplicate_report(batch, [], output, "Test Library")
        content = output.read_text()
        # Should have file links but img tags should NOT reference .mov files
        assert "file:///tmp/video.mov" in content
        # Check that img src doesn't point to .mov
        assert 'src="file:///tmp/video.mov"' not in content
