"""Audit logging module — append-only JSON lines log for file operations."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path


class AuditLogger:
    """Append-only JSON lines audit logger.

    Each line is a JSON object recording one file operation.
    """

    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)

    def log(self, operation: str, **fields: object) -> None:
        """Append an audit record."""
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "operation": operation,
            **fields,
        }
        with open(self._path, "a") as f:
            f.write(json.dumps(record) + "\n")

    def log_import(self, source: str, destination: str, md5_hash: str, size: int, library: str) -> None:
        """Record a file import."""
        self.log("import", source=source, destination=destination, md5_hash=md5_hash, size=size, library=library)

    def log_skip_duplicate(self, source: str, md5_hash: str, library: str) -> None:
        """Record a skipped duplicate."""
        self.log("skip_duplicate", source=source, md5_hash=md5_hash, library=library)
