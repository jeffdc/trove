"""Shared plan dataclasses used across operations."""

from __future__ import annotations

from dataclasses import dataclass, field

from trove.db import FileRecord


@dataclass(frozen=True)
class FileAction:
    """A planned action for a single file during initialization."""

    source_path: str  # absolute path where file is now
    relative_path: str  # current relative path within library
    target_path: str  # computed target relative path
    md5_hash: str
    file_size: int
    capture_date: str | None
    camera_model: str | None
    action: str  # "index" | "move" | "duplicate" | "quarantine"


@dataclass(frozen=True)
class InitializePlan:
    """Plan for initializing a library from existing files."""

    already_correct: list[FileAction] = field(default_factory=list)
    needs_move: list[FileAction] = field(default_factory=list)
    duplicates: list[FileAction] = field(default_factory=list)
    quarantined: list[FileAction] = field(default_factory=list)
    total_files: int = 0

    @property
    def is_empty(self) -> bool:
        return self.total_files == 0


@dataclass(frozen=True)
class InitializeResult:
    """Result of executing an initialization plan."""

    indexed: int = 0  # entries created without moving
    moved: int = 0  # files moved + entry created
    duplicates: int = 0  # duplicate files indexed (suffixed)
    quarantined: int = 0
    errors: int = 0


@dataclass(frozen=True)
class ImportPlan:
    """Plan for importing files into a library."""

    to_import: list[FileRecord] = field(default_factory=list)
    duplicates_in_batch: list[FileRecord] = field(default_factory=list)
    duplicates_in_library: list[FileRecord] = field(default_factory=list)
    path_conflicts: int = 0
    skipped: int = 0

    @property
    def total_files(self) -> int:
        return len(self.to_import) + len(self.duplicates_in_batch) + len(self.duplicates_in_library) + self.skipped

    @property
    def is_empty(self) -> bool:
        return len(self.to_import) == 0


@dataclass(frozen=True)
class CompletePlan:
    """Plan for completing an import."""

    imported: list[FileRecord] = field(default_factory=list)
    duplicate: list[FileRecord] = field(default_factory=list)
    quarantined: list[FileRecord] = field(default_factory=list)
    unaccounted: list[FileRecord] = field(default_factory=list)  # discovered + hashed

    @property
    def can_complete(self) -> bool:
        return len(self.unaccounted) == 0

    @property
    def total_to_clean(self) -> int:
        return len(self.imported) + len(self.duplicate) + len(self.quarantined)
