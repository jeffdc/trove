"""Thin wrapper providing a consistent Rich progress bar for CLI commands."""

from __future__ import annotations

from rich.progress import BarColumn, Progress, TextColumn, TimeRemainingColumn


def create_progress() -> Progress:
    """Create a Rich progress bar for use in CLI commands."""
    return Progress(
        TextColumn("[bold]{task.description}"),
        BarColumn(),
        TextColumn("{task.completed}/{task.total}"),
        TimeRemainingColumn(),
    )
