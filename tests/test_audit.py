import hashlib
import json

from trove.audit import AuditLogger
from trove.complete import complete_import
from trove.config import LibraryConfig
from trove.importer import import_to_library


class TestAuditLogger:
    def test_log_creates_file_and_writes_json(self, tmp_path):
        """AuditLogger creates file and writes valid JSON lines."""
        log_path = tmp_path / "audit.log"
        audit = AuditLogger(log_path)
        audit.log("test_op", key="value")

        assert log_path.exists()
        lines = log_path.read_text().strip().split("\n")
        assert len(lines) == 1
        record = json.loads(lines[0])
        assert record["operation"] == "test_op"
        assert record["key"] == "value"
        assert "timestamp" in record

    def test_append_only(self, tmp_path):
        """Multiple writes append, don't overwrite."""
        log_path = tmp_path / "audit.log"
        audit = AuditLogger(log_path)
        audit.log("first")
        audit.log("second")

        lines = log_path.read_text().strip().split("\n")
        assert len(lines) == 2
        assert json.loads(lines[0])["operation"] == "first"
        assert json.loads(lines[1])["operation"] == "second"

    def test_append_across_instances(self, tmp_path):
        """New AuditLogger instance appends to existing file."""
        log_path = tmp_path / "audit.log"
        AuditLogger(log_path).log("first")
        AuditLogger(log_path).log("second")

        lines = log_path.read_text().strip().split("\n")
        assert len(lines) == 2


class TestAuditImportIntegration:
    def test_import_logs_audit(self, db, library, tmp_path):
        """import_to_library writes audit records for imports and duplicates."""
        source = tmp_path / "source"
        source.mkdir()

        # Two files: one unique, one duplicate of it
        content = b"photo content"
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

        log_path = tmp_path / "audit.log"
        audit = AuditLogger(log_path)
        config = LibraryConfig()
        import_to_library(db, library, config, audit=audit)

        lines = log_path.read_text().strip().split("\n")
        records = [json.loads(line) for line in lines]
        ops = [r["operation"] for r in records]
        assert "import" in ops
        assert "skip_duplicate" in ops

    def test_import_without_audit_works(self, db, library, tmp_path):
        """import_to_library works fine without audit logger."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"photo"
        content_hash = hashlib.md5(content).hexdigest()
        (source / "a.jpg").write_bytes(content)

        f = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(
            f.id,
            md5_hash=content_hash,
            status="hashed",
            capture_date="2024-01-15T10:30:00",
            camera_model="Canon",
            target_path="2024/01/Canon/a.jpg",
        )

        config = LibraryConfig()
        summary = import_to_library(db, library, config)  # no audit param
        assert summary["imported"] == 1


class TestAuditCompleteIntegration:
    def test_complete_without_audit_works(self, db, library, tmp_path):
        """complete_import works without audit logger."""
        source = tmp_path / "source"
        source.mkdir()
        content = b"content"
        content_hash = hashlib.md5(content).hexdigest()

        f = db.insert_file(str(source / "a.jpg"), "local", len(content), "2024-01-01T00:00:00")
        db.update_file(f.id, md5_hash=content_hash, status="imported")
        db.create_entry(library.id, "2024/01/Canon/a.jpg", len(content), content_hash, "2024-01-01T00:00:00", "Canon")

        result = complete_import(db, library)
        assert result.can_complete is True
        assert result.records_cleaned == 1
