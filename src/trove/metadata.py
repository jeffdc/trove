from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from rich.progress import Progress

logger = logging.getLogger(__name__)

_DATE_FIELDS = ("DateTimeOriginal", "CreateDate", "ModifyDate")


@dataclass(frozen=True)
class FileMetadata:
    capture_date: str | None  # best available date as ISO string, or None
    camera_model: str | None  # camera model string, or None
    date_source: str | None  # which EXIF field the date came from, for debugging


def _parse_exif_date(raw: str) -> str | None:
    """Parse an exiftool date string into ISO 8601 format.

    Returns the ISO string if valid, or None if parsing fails or
    the date is outside the plausible range (year < 2000 or > current year + 1).
    """
    if not raw or not raw.strip():
        return None
    try:
        dt = datetime.strptime(raw.strip(), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None
    current_year = datetime.now().year
    if dt.year < 2000 or dt.year > current_year + 1:
        return None
    return dt.strftime("%Y-%m-%dT%H:%M:%S")


def _resolve_date(entry: dict) -> tuple[str | None, str | None]:
    """Walk the date fallback chain and return (iso_date, source_field) or (None, None)."""
    for field in _DATE_FIELDS:
        raw = entry.get(field)
        if raw is None:
            continue
        iso = _parse_exif_date(str(raw))
        if iso is not None:
            return iso, field
    return None, None


def extract_metadata(paths: list[Path]) -> dict[str, FileMetadata]:
    """Extract metadata from files using exiftool.

    Calls exiftool in batch mode (one invocation for all paths), parses
    JSON output, and resolves capture_date through fallback chain.

    Args:
        paths: List of file paths to extract metadata from.

    Returns:
        Dict mapping str(path) -> FileMetadata for each path.

    Raises:
        RuntimeError: If exiftool is not installed or cannot be executed.
    """
    if not paths:
        return {}

    import tempfile

    try:
        # Write paths to a temp file and use -@ to avoid OS arg length limits
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as argfile:
            for p in paths:
                argfile.write(f"{p}\n")
            argfile_path = argfile.name

        try:
            proc = subprocess.run(
                [
                    "exiftool",
                    "-json",
                    "-DateTimeOriginal",
                    "-CreateDate",
                    "-ModifyDate",
                    "-Model",
                    "-@",
                    argfile_path,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        finally:
            Path(argfile_path).unlink(missing_ok=True)

    except FileNotFoundError as exc:
        raise RuntimeError("exiftool is not installed or not on PATH. Install it from https://exiftool.org/") from exc

    stdout = proc.stdout.strip()
    if not stdout:
        return {}

    try:
        entries = json.loads(stdout)
    except json.JSONDecodeError:
        logger.warning("exiftool returned invalid JSON output")
        return {}

    results: dict[str, FileMetadata] = {}
    for entry in entries:
        source_file = entry.get("SourceFile")
        if source_file is None:
            continue

        capture_date, date_source = _resolve_date(entry)
        camera_model = entry.get("Model") or None

        results[str(source_file)] = FileMetadata(
            capture_date=capture_date,
            camera_model=camera_model,
            date_source=date_source,
        )

    return results


def extract_metadata_chunked(
    paths: list[Path],
    chunk_size: int = 100,
    progress: Progress | None = None,
) -> dict[str, FileMetadata]:
    """Extract metadata from files using exiftool in chunked batches.

    Splits paths into chunks to avoid OS argument length limits.
    Updates progress after each chunk.

    Args:
        paths: List of file paths to extract metadata from.
        chunk_size: Number of files per exiftool invocation (default 100
                    for responsive progress updates).
        progress: Optional Rich progress bar.

    Returns:
        Dict mapping str(path) -> FileMetadata for each path.

    Raises:
        RuntimeError: If exiftool is not installed.
    """
    if not paths:
        return {}

    results: dict[str, FileMetadata] = {}

    task_id = None
    if progress is not None:
        task_id = progress.add_task("Extracting metadata", total=len(paths))

    for i in range(0, len(paths), chunk_size):
        chunk = paths[i : i + chunk_size]
        chunk_results = extract_metadata(chunk)
        results.update(chunk_results)
        if progress is not None and task_id is not None:
            progress.update(task_id, advance=len(chunk))

    return results
