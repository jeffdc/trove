from __future__ import annotations

import hashlib

import pytest

from trove.hashing import hash_file, hash_files_parallel


class TestHashFile:
    def test_correct_md5_for_known_content(self, tmp_path):
        """Produces correct MD5 for a file with known content."""
        f = tmp_path / "test.txt"
        content = b"hello world"
        f.write_bytes(content)
        expected = hashlib.md5(content).hexdigest()
        assert hash_file(f) == expected

    def test_correct_md5_for_binary_content(self, tmp_path):
        """Produces correct MD5 for binary content."""
        f = tmp_path / "test.bin"
        content = bytes(range(256)) * 100
        f.write_bytes(content)
        expected = hashlib.md5(content).hexdigest()
        assert hash_file(f) == expected

    def test_empty_file(self, tmp_path):
        """Empty file returns MD5 of empty bytes."""
        f = tmp_path / "empty.txt"
        f.write_bytes(b"")
        expected = hashlib.md5(b"").hexdigest()
        assert hash_file(f) == expected

    def test_chunked_reading_produces_same_hash(self, tmp_path):
        """Different chunk sizes produce the same hash."""
        f = tmp_path / "test.txt"
        content = b"x" * 50000
        f.write_bytes(content)
        assert hash_file(f, chunk_size=1024) == hash_file(f, chunk_size=8192)
        assert hash_file(f, chunk_size=7) == hash_file(f, chunk_size=8192)

    def test_progress_callback_called(self, tmp_path):
        """Progress callback is called with cumulative byte counts."""
        f = tmp_path / "test.txt"
        content = b"x" * 20000
        f.write_bytes(content)
        calls = []
        hash_file(f, chunk_size=8192, progress_callback=calls.append)
        # Should have been called multiple times
        assert len(calls) >= 2
        # Last call should equal total file size
        assert calls[-1] == 20000
        # Calls should be monotonically increasing
        for i in range(1, len(calls)):
            assert calls[i] > calls[i - 1]

    def test_progress_callback_not_called_when_none(self, tmp_path):
        """No error when progress_callback is None."""
        f = tmp_path / "test.txt"
        f.write_bytes(b"hello")
        # Should not raise
        hash_file(f, progress_callback=None)

    def test_unreadable_file_raises(self, tmp_path):
        """OSError raised for unreadable file."""
        f = tmp_path / "nope.txt"
        with pytest.raises(OSError):
            hash_file(f)

    def test_large_file_chunked(self, tmp_path):
        """File larger than chunk size is read in chunks without memory issues."""
        f = tmp_path / "large.bin"
        # 1MB file with small chunk size
        content = b"A" * (1024 * 1024)
        f.write_bytes(content)
        expected = hashlib.md5(content).hexdigest()
        assert hash_file(f, chunk_size=4096) == expected


class TestHashFilesParallel:
    def test_hashes_multiple_files(self, tmp_path):
        """Hashes multiple files correctly with thread pool."""
        files = []
        expected = {}
        for i in range(10):
            f = tmp_path / f"file_{i}.bin"
            content = f"content_{i}".encode()
            f.write_bytes(content)
            files.append(f)
            expected[str(f)] = hashlib.md5(content).hexdigest()

        results = hash_files_parallel(files, max_workers=4)
        assert len(results) == 10
        for path_str, hash_val in results.items():
            assert hash_val == expected[path_str]

    def test_results_match_serial(self, tmp_path):
        """Parallel results match serial hash_file."""
        files = []
        for i in range(5):
            f = tmp_path / f"file_{i}.bin"
            f.write_bytes(f"data_{i}".encode())
            files.append(f)

        parallel_results = hash_files_parallel(files, max_workers=2)
        for f in files:
            assert parallel_results[str(f)] == hash_file(f)

    def test_unreadable_file_skipped(self, tmp_path):
        """Unreadable file skipped, others still hashed."""
        good = tmp_path / "good.bin"
        good.write_bytes(b"good data")
        bad = tmp_path / "nonexistent.bin"

        results = hash_files_parallel([good, bad], max_workers=2)
        assert len(results) == 1
        assert str(good) in results

    def test_progress_advances(self, tmp_path):
        """Progress advances per file."""
        files = []
        for i in range(5):
            f = tmp_path / f"file_{i}.bin"
            f.write_bytes(b"data")
            files.append(f)

        advances = []

        class FakeProgress:
            def add_task(self, desc, total=0):
                return 0

            def update(self, task_id, advance=0):
                advances.append(advance)

        hash_files_parallel(files, max_workers=2, progress=FakeProgress())
        assert sum(advances) == 5

    def test_empty_list(self):
        """Empty list returns empty dict."""
        assert hash_files_parallel([]) == {}

    def test_single_file(self, tmp_path):
        """Single file works."""
        f = tmp_path / "single.bin"
        content = b"single"
        f.write_bytes(content)
        results = hash_files_parallel([f])
        assert results[str(f)] == hashlib.md5(content).hexdigest()
