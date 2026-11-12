"""Filesystem date helpers."""

from __future__ import annotations

import logging
import subprocess
import sys
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

_SETFILE_TIMEOUT = 30.0


def set_creation_date(path_str: str, iso_date: str, timeout: float = _SETFILE_TIMEOUT) -> None:
    """Set a file's Finder Date Created using macOS SetFile.

    Raises:
        TimeoutError: SetFile did not complete within the timeout.
        RuntimeError: SetFile reported a non-zero exit.
        ValueError: iso_date could not be parsed.
    """
    dt = datetime.fromisoformat(iso_date)
    setfile_date = (
        f"{dt.month:02d}/{dt.day:02d}/{dt.year} "
        f"{dt.hour:02d}:{dt.minute:02d}:{dt.second:02d}"
    )
    try:
        proc = subprocess.run(
            ["/usr/bin/SetFile", "-d", setfile_date, path_str],
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise TimeoutError(f"SetFile timed out after {timeout}s for {path_str}") from exc
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
        raise RuntimeError(f"SetFile failed for {path_str}: {stderr}")


def stamp_creation_date(path: Path, capture_date: str | None) -> bool:
    """Set a file's creation date from an ISO capture date on macOS.

    Returns True on success, False if the platform is unsupported, capture_date
    is None, or SetFile fails. Failures are logged but never raised.
    """
    if capture_date is None or sys.platform != "darwin":
        return False

    try:
        set_creation_date(str(path), capture_date)
    except Exception as exc:
        logger.warning("Could not set creation date for %s from %s: %s", path, capture_date, exc)
        return False

    return True
