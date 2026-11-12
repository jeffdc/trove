---
status: done
created: 2026-04-02
updated: 2026-04-05
relates: [6cc8]
docket: true
---

# Per-library config in DB

## Per-library config in DB

### What changes

The `libraries` table gets a `config` JSON column storing per-library settings. The YAML file goes away. Operational settings (hashing, network, logging) become hardcoded defaults with CLI flag overrides if ever needed.

### Libraries table becomes

```sql
CREATE TABLE libraries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    location TEXT NOT NULL,
    config TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
);
```

### Config JSON shape

All fields optional, defaults applied in code:

```json
{
  "organization": {
    "structure": "%Y/%m",
    "include_camera_model": true,
    "unknown_model_label": "Unknown_Model"
  },
  "file_types": {
    "photos": ["jpg", "jpeg", "heic", ...],
    "videos": ["mov", "mp4", ...],
    "raw": ["cr2", "cr3", ...]
  },
  "exclude_patterns": ["*.DS_Store", "._*", ...],
  "quarantine": {
    "path": "quarantine/",
    "reasons": ["no_exif_date", "corrupt_file", "unreadable_file"]
  }
}
```

### What gets removed from config.py

- `DestinationConfig` — redundant with `library.location`
- `SourceConfig` — only relevant at import time, passed as CLI arg
- `NetworkConfig`, `HashingConfig`, `LoggingConfig` — hardcoded defaults
- `load_config()` and YAML dependency — replaced by reading from DB
- The `--config` CLI flag

### What stays in config.py

- `OrganizationConfig`, `FileTypesConfig`, `QuarantineConfig` dataclasses — used to deserialize the JSON and provide defaults
- A `LibraryConfig` dataclass replacing `TroveConfig` that holds just the per-library fields
- A function to build `LibraryConfig` from JSON (merging with defaults for missing keys)

### DB default location

`~/.trove/state.db` — the `--db` flag still works as an override.

### CLI flow changes

- `trove library create "name" /path` → stores library with default config
- `trove library create "name" /path --structure "%Y/%B"` → stores custom org structure
- `trove library config "name"` → shows current config
- `trove library config "name" --structure "%Y/%m/%d"` → updates config
- All other commands (`add`, `init`, `verify`, etc.) pull config from the library's DB record instead of YAML

### Migration

Add the `config` column with `ALTER TABLE`, defaulting to `'{}'`. Existing libraries get defaults automatically.
