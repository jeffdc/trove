"""Shared CLI helpers — library resolution and interactive prompt helpers."""

from __future__ import annotations

import os
import sys
from contextlib import contextmanager
from pathlib import Path

import click

from trove.db import LibraryRecord, StateDB

try:
    import readline
except ImportError:  # pragma: no cover - platform dependent
    readline = None  # type: ignore[assignment]


def _readline_tab_binding() -> str:
    """Return the correct tab-completion binding for the active readline backend."""
    doc = (readline.__doc__ or "").lower() if readline is not None else ""
    if "libedit" in doc:
        return "bind ^I rl_complete"
    return "tab: complete"


def resolve_library(db: StateDB, name: str) -> LibraryRecord | None:
    """Look up a library by name.

    Returns the LibraryRecord, or None if not found (with error printed).
    """
    lib = db.get_library(name)
    if lib is None:
        click.echo(f"Error: Library '{name}' not found.", err=True)
        return None
    return lib


def get_path_completion_matches(text: str) -> list[str]:
    """Return filesystem completion candidates for a prompt input prefix."""
    if text.endswith(os.sep):
        display_dir = text
        search_dir = os.path.expanduser(text)
        prefix = ""
    else:
        display_dir, prefix = os.path.split(text)
        search_dir = os.path.expanduser(display_dir or ".")
        if display_dir:
            display_dir = display_dir + os.sep

    try:
        entries = sorted(Path(search_dir).iterdir(), key=lambda entry: (not entry.is_dir(), entry.name.lower()))
    except OSError:
        return []

    matches: list[str] = []
    for entry in entries:
        if not entry.name.startswith(prefix):
            continue
        match = f"{display_dir}{entry.name}"
        if entry.is_dir():
            match = match + os.sep
        matches.append(match)

    return matches


@contextmanager
def _path_prompt_completion():
    """Temporarily enable readline path completion for interactive prompts."""
    if readline is None or not sys.stdin.isatty():
        yield
        return

    matches: list[str] = []
    old_completer = readline.get_completer()
    old_delims = readline.get_completer_delims()

    def _complete(text: str, state: int) -> str | None:
        nonlocal matches
        if state == 0:
            matches = get_path_completion_matches(text)
        return matches[state] if state < len(matches) else None

    try:
        readline.set_completer(_complete)
        readline.set_completer_delims("")
        readline.parse_and_bind(_readline_tab_binding())
        yield
    finally:
        readline.set_completer(old_completer)
        readline.set_completer_delims(old_delims)


def prompt_for_path(text: str) -> str:
    """Prompt for a filesystem path with readline tab completion when available."""
    with _path_prompt_completion():
        path: str = click.prompt(text, type=click.Path(path_type=str))
        return path
