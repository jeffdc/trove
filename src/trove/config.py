"""Configuration for Trove — per-library settings stored in the database."""

from __future__ import annotations

import json
from dataclasses import dataclass, field

# --- Nested config dataclasses (all frozen) ---


@dataclass(frozen=True)
class OrganizationConfig:
    structure: str = "%Y/%m"
    include_camera_model: bool = True
    unknown_model_label: str = "Unknown_Model"


@dataclass(frozen=True)
class FileTypesConfig:
    photos: list[str] = field(
        default_factory=lambda: [
            "jpg",
            "jpeg",
            "heic",
            "png",
            "tiff",
            "tif",
            "psd",
            "gif",
            "dng",
            "bmp",
            "webp",
        ]
    )
    videos: list[str] = field(
        default_factory=lambda: [
            "mov",
            "mp4",
            "mpg",
            "mpeg",
            "avi",
            "m4v",
            "mts",
        ]
    )
    raw: list[str] = field(
        default_factory=lambda: [
            "cr2",
            "cr3",
            "nef",
            "arw",
            "orf",
            "raf",
            "rw2",
            "dng",
            "srw",
            "pef",
        ]
    )


@dataclass(frozen=True)
class QuarantineConfig:
    path: str = "quarantine/"
    reasons: list[str] = field(
        default_factory=lambda: [
            "no_exif_date",
            "corrupt_file",
            "unreadable_file",
        ]
    )


# --- Per-library config ---


@dataclass(frozen=True)
class LibraryConfig:
    organization: OrganizationConfig = field(default_factory=OrganizationConfig)
    file_types: FileTypesConfig = field(default_factory=FileTypesConfig)
    exclude_patterns: list[str] = field(
        default_factory=lambda: [
            "*.DS_Store",
            "._*",
            "Thumbs.db",
            "*.ini",
            "*.db",
            "thumb_*",
        ]
    )
    quarantine: QuarantineConfig = field(default_factory=QuarantineConfig)

    def to_json(self) -> str:
        """Serialize to JSON string."""
        return json.dumps({
            "organization": {
                "structure": self.organization.structure,
                "include_camera_model": self.organization.include_camera_model,
                "unknown_model_label": self.organization.unknown_model_label,
            },
            "file_types": {
                "photos": self.file_types.photos,
                "videos": self.file_types.videos,
                "raw": self.file_types.raw,
            },
            "exclude_patterns": self.exclude_patterns,
            "quarantine": {
                "path": self.quarantine.path,
                "reasons": self.quarantine.reasons,
            },
        })

    @classmethod
    def from_json(cls, json_str: str) -> LibraryConfig:
        """Deserialize from JSON string, filling missing keys with defaults."""
        raw = json.loads(json_str)
        defaults = cls()

        raw_org = raw.get("organization", {})
        organization = OrganizationConfig(
            structure=raw_org.get("structure", defaults.organization.structure),
            include_camera_model=raw_org.get("include_camera_model", defaults.organization.include_camera_model),
            unknown_model_label=raw_org.get("unknown_model_label", defaults.organization.unknown_model_label),
        )

        raw_ft = raw.get("file_types", {})
        file_types = FileTypesConfig(
            photos=raw_ft.get("photos", defaults.file_types.photos),
            videos=raw_ft.get("videos", defaults.file_types.videos),
            raw=raw_ft.get("raw", defaults.file_types.raw),
        )

        exclude_patterns = raw.get("exclude_patterns", defaults.exclude_patterns)

        raw_q = raw.get("quarantine", {})
        quarantine = QuarantineConfig(
            path=raw_q.get("path", defaults.quarantine.path),
            reasons=raw_q.get("reasons", defaults.quarantine.reasons),
        )

        return cls(
            organization=organization,
            file_types=file_types,
            exclude_patterns=exclude_patterns,
            quarantine=quarantine,
        )
