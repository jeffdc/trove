from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from trove.metadata import extract_metadata, extract_metadata_chunked


def _make_exiftool_result(stdout_data, returncode=0, stderr=""):
    """Helper to create a mock subprocess.CompletedProcess."""
    result = MagicMock(spec=subprocess.CompletedProcess)
    result.stdout = stdout_data if isinstance(stdout_data, str) else json.dumps(stdout_data)
    result.stderr = stderr
    result.returncode = returncode
    return result


class TestExtractMetadata:
    @patch("trove.metadata.subprocess.run")
    def test_extracts_date_and_model(self, mock_run):
        """Extracts DateTimeOriginal and Model from exiftool output."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "2024:01:15 10:30:00",
                    "CreateDate": "2024:01:15 10:30:00",
                    "ModifyDate": "2024:01:15 10:30:05",
                    "Model": "Canon EOS R5",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date == "2024-01-15T10:30:00"
        assert meta.camera_model == "Canon EOS R5"
        assert meta.date_source == "DateTimeOriginal"

    @patch("trove.metadata.subprocess.run")
    def test_falls_back_to_create_date(self, mock_run):
        """Falls back to CreateDate when DateTimeOriginal missing."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "CreateDate": "2024:06:20 14:00:00",
                    "ModifyDate": "2024:06:20 14:00:05",
                    "Model": "iPhone 15",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date == "2024-06-20T14:00:00"
        assert meta.date_source == "CreateDate"

    @patch("trove.metadata.subprocess.run")
    def test_falls_back_to_modify_date(self, mock_run):
        """Falls back to ModifyDate when DateTimeOriginal and CreateDate missing."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "ModifyDate": "2023:12:25 08:00:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date == "2023-12-25T08:00:00"
        assert meta.date_source == "ModifyDate"

    @patch("trove.metadata.subprocess.run")
    def test_no_dates_returns_none(self, mock_run):
        """No date fields at all returns capture_date=None."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "Model": "Canon EOS R5",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date is None
        assert meta.date_source is None
        assert meta.camera_model == "Canon EOS R5"

    @patch("trove.metadata.subprocess.run")
    def test_missing_model_returns_none(self, mock_run):
        """Missing Model field returns camera_model=None."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "2024:01:15 10:30:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.camera_model is None

    @patch("trove.metadata.subprocess.run")
    def test_empty_date_string_treated_as_missing(self, mock_run):
        """Empty string dates treated as missing."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "",
                    "CreateDate": "",
                    "ModifyDate": "2024:01:15 10:30:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date == "2024-01-15T10:30:00"
        assert meta.date_source == "ModifyDate"

    @patch("trove.metadata.subprocess.run")
    def test_obviously_wrong_date_before_2000(self, mock_run):
        """Date with year < 2000 returns None (caller uses filesystem date)."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "1970:01:01 00:00:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date is None

    @patch("trove.metadata.subprocess.run")
    def test_obviously_wrong_date_future(self, mock_run):
        """Date with year > current year + 1 returns None."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "2099:01:01 00:00:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date is None

    @patch("trove.metadata.subprocess.run")
    def test_corrupt_date_format_treated_as_missing(self, mock_run):
        """Unparseable date format treated as missing."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "not-a-date",
                    "CreateDate": "2024:01:15 10:30:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date == "2024-01-15T10:30:00"
        assert meta.date_source == "CreateDate"

    @patch("trove.metadata.subprocess.run")
    def test_batch_multiple_files(self, mock_run):
        """Batch invocation processes multiple files."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/a.jpg",
                    "DateTimeOriginal": "2024:01:15 10:30:00",
                    "Model": "Canon EOS R5",
                },
                {
                    "SourceFile": "/tmp/b.jpg",
                    "DateTimeOriginal": "2023:06:20 14:00:00",
                    "Model": "iPhone 15",
                },
            ]
        )
        result = extract_metadata([Path("/tmp/a.jpg"), Path("/tmp/b.jpg")])
        assert len(result) == 2
        assert result["/tmp/a.jpg"].camera_model == "Canon EOS R5"
        assert result["/tmp/b.jpg"].camera_model == "iPhone 15"
        # Verify exiftool was called once (batch mode)
        assert mock_run.call_count == 1

    @patch("trove.metadata.subprocess.run")
    def test_exiftool_not_installed_raises(self, mock_run):
        """FileNotFoundError from subprocess raises RuntimeError."""
        mock_run.side_effect = FileNotFoundError("exiftool not found")
        with pytest.raises(RuntimeError, match="exiftool"):
            extract_metadata([Path("/tmp/photo.jpg")])

    @patch("trove.metadata.subprocess.run")
    def test_exiftool_invalid_json_returns_empty(self, mock_run):
        """Invalid JSON output returns empty dict."""
        mock_run.return_value = _make_exiftool_result("not valid json {{{")
        result = extract_metadata([Path("/tmp/photo.jpg")])
        assert result == {}

    @patch("trove.metadata.subprocess.run")
    def test_exiftool_empty_output_returns_empty(self, mock_run):
        """Empty output returns empty dict."""
        mock_run.return_value = _make_exiftool_result("")
        result = extract_metadata([Path("/tmp/photo.jpg")])
        assert result == {}

    @patch("trove.metadata.subprocess.run")
    def test_empty_paths_list(self, mock_run):
        """Empty paths list returns empty dict without calling exiftool."""
        result = extract_metadata([])
        assert result == {}
        mock_run.assert_not_called()

    @patch("trove.metadata.subprocess.run")
    def test_exiftool_stderr_warnings_still_parses(self, mock_run):
        """exiftool warnings on stderr don't prevent parsing stdout."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "2024:01:15 10:30:00",
                    "Model": "Canon EOS R5",
                }
            ],
            returncode=1,
            stderr="Warning: bad something",
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        assert "/tmp/photo.jpg" in result
        assert result["/tmp/photo.jpg"].capture_date == "2024-01-15T10:30:00"

    @patch("trove.metadata.subprocess.run")
    def test_wrong_date_falls_through_to_next(self, mock_run):
        """If DateTimeOriginal has wrong year, falls back to CreateDate."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "1970:01:01 00:00:00",
                    "CreateDate": "2024:01:15 10:30:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date == "2024-01-15T10:30:00"
        assert meta.date_source == "CreateDate"

    @patch("trove.metadata.subprocess.run")
    def test_all_dates_wrong_returns_none(self, mock_run):
        """If all dates have wrong years, returns None."""
        mock_run.return_value = _make_exiftool_result(
            [
                {
                    "SourceFile": "/tmp/photo.jpg",
                    "DateTimeOriginal": "1970:01:01 00:00:00",
                    "CreateDate": "1970:01:01 00:00:00",
                    "ModifyDate": "1970:01:01 00:00:00",
                }
            ]
        )
        result = extract_metadata([Path("/tmp/photo.jpg")])
        meta = result["/tmp/photo.jpg"]
        assert meta.capture_date is None


class TestExtractMetadataChunked:
    @patch("trove.metadata.subprocess.run")
    def test_chunked_splits_into_batches(self, mock_run):
        """Chunked with 10 files and chunk_size=3 calls exiftool 4 times."""
        # Create 10 fake paths
        paths = [Path(f"/tmp/photo_{i}.jpg") for i in range(10)]

        # Mock reads file paths from the -@ argfile
        def make_result(args, **kwargs):
            file_args = []
            if "-@" in args:
                argfile_path = args[args.index("-@") + 1]
                with open(argfile_path) as af:
                    file_args = [line.strip() for line in af if line.strip()]
            result = MagicMock(spec=subprocess.CompletedProcess)
            result.stdout = json.dumps(
                [{"SourceFile": f, "DateTimeOriginal": "2024:01:15 10:30:00", "Model": "Canon"} for f in file_args]
            )
            result.stderr = ""
            result.returncode = 0
            return result

        mock_run.side_effect = make_result

        results = extract_metadata_chunked(paths, chunk_size=3)

        # Should have called exiftool 4 times (3+3+3+1)
        assert mock_run.call_count == 4
        # Should have results for all 10 files
        assert len(results) == 10

    @patch("trove.metadata.subprocess.run")
    def test_chunked_merges_results(self, mock_run):
        """Results from all chunks are merged into one dict."""
        paths = [Path("/tmp/a.jpg"), Path("/tmp/b.jpg"), Path("/tmp/c.jpg")]

        def make_result(args, **kwargs):
            file_args = []
            if "-@" in args:
                argfile_path = args[args.index("-@") + 1]
                with open(argfile_path) as af:
                    file_args = [line.strip() for line in af if line.strip()]
            result = MagicMock(spec=subprocess.CompletedProcess)
            result.stdout = json.dumps(
                [{"SourceFile": f, "DateTimeOriginal": "2024:01:15 10:30:00", "Model": "Canon"} for f in file_args]
            )
            result.stderr = ""
            result.returncode = 0
            return result

        mock_run.side_effect = make_result

        results = extract_metadata_chunked(paths, chunk_size=1)

        assert mock_run.call_count == 3
        assert "/tmp/a.jpg" in results
        assert "/tmp/b.jpg" in results
        assert "/tmp/c.jpg" in results

    def test_chunked_empty_paths(self):
        """Empty paths list returns empty dict without calling exiftool."""
        results = extract_metadata_chunked([])
        assert results == {}

    @patch("trove.metadata.subprocess.run")
    def test_chunked_single_chunk(self, mock_run):
        """Fewer paths than chunk_size uses single batch."""
        paths = [Path("/tmp/a.jpg")]

        result = MagicMock(spec=subprocess.CompletedProcess)
        result.stdout = json.dumps([{"SourceFile": "/tmp/a.jpg", "DateTimeOriginal": "2024:01:15 10:30:00"}])
        result.stderr = ""
        result.returncode = 0
        mock_run.return_value = result

        results = extract_metadata_chunked(paths, chunk_size=500)

        assert mock_run.call_count == 1
        assert len(results) == 1

    @patch("trove.metadata.subprocess.run")
    def test_chunked_progress_advances(self, mock_run):
        """Progress is advanced after each chunk."""
        paths = [Path(f"/tmp/photo_{i}.jpg") for i in range(5)]

        def make_result(args, **kwargs):
            file_args = []
            if "-@" in args:
                argfile_path = args[args.index("-@") + 1]
                with open(argfile_path) as af:
                    file_args = [line.strip() for line in af if line.strip()]
            result = MagicMock(spec=subprocess.CompletedProcess)
            result.stdout = json.dumps(
                [{"SourceFile": f, "DateTimeOriginal": "2024:01:15 10:30:00"} for f in file_args]
            )
            result.stderr = ""
            result.returncode = 0
            return result

        mock_run.side_effect = make_result

        # Track progress advances
        advances = []

        class FakeProgress:
            def add_task(self, desc, total=0):
                return 0

            def update(self, task_id, advance=0):
                advances.append(advance)

        results = extract_metadata_chunked(paths, chunk_size=2, progress=FakeProgress())

        # 5 files with chunk_size=2: chunks of 2, 2, 1
        assert advances == [2, 2, 1]
        assert len(results) == 5
