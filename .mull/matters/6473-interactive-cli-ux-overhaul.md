---
status: done
tags: [design]
created: 2026-03-30
updated: 2026-03-30
epic: trove
---

# Interactive CLI UX overhaul

## Design: Interactive CLI UX Overhaul

### Problem

The current CLI has poor ergonomics:
- Every command requires `--library "Name"` even when there's only one library
- The `run` command flow is confusing — "complete" is a separate prompted step that's really just DB housekeeping
- Prompts are terse y/n gates instead of informative menus with options
- No way to create a library inline when one doesn't exist
- Too many commands — scan, import, complete are internal pipeline steps exposed as commands

### Design

#### 1. Simplified Command Set

```
trove library create [<name> <location>]    # interactive if no args
trove library list
trove add <source-path>                     # the main command: scan + import + cleanup
trove verify                                # library health check
trove duplicates                            # review duplicate groups
trove status                                # overview, --library for details
```

Dropped commands:
- `scan` — internal step of `add`
- `import` — internal step of `add`
- `complete` — auto-runs after successful import
- `library show` — absorbed into `status --library`
- `run` — renamed to `add`

#### 2. Smart Library Resolution

Every command that needs a library uses `resolve_library` helper:

```
No libraries exist:
  → "No libraries found. Create one now?"
  → Prompts for name and location
  → Creates library, continues with original command

One library:
  → "Using library: Family Photos (/Volumes/photos/family)"
  → Continues (no prompt)

Multiple libraries:
  → "Which library?"
  → [1] Family Photos  (/Volumes/photos/family)
  → [2] Nature         (/Volumes/photos/nature)
  → User picks by number

--library flag still works for scripting
```

Status: DONE (implemented in step 1)

#### 3. Progressive `add` Flow

```
$ trove add /Volumes/SD_CARD/DCIM

Using library: Family Photos (/Volumes/photos/family)

Scanning /Volumes/SD_CARD/DCIM...
  Found 160 media files (142 photos, 15 videos, 3 raw)
  Hashing... ████████████████████ 160/160
  Extracting metadata...

Analysis:
  Ready to import:      147 files (2.3 GB)
  Duplicates (batch):    10 files (same content in this source)
  Already in library:     0 files
  No date (quarantine):   3 files

What would you like to do?
  [i] Import 147 files
  [q] Review 3 quarantined files
  [d] Review 10 duplicates
  [a] Abort

> i

Importing... ████████████████████ 147/147
Imported 147 files to Family Photos.

  3 quarantined files were skipped (no date).
  10 duplicate files were skipped.

Source files on /Volumes/SD_CARD/DCIM: [k]eep or [d]elete?
> k
Done. Source files kept.
```

After import: DB cleanup (complete) runs automatically and silently.

#### 4. Review Sub-flows

When user picks [q] or [d]:

**Quarantined:**
```
Quarantined files (no date found):
  1. /Volumes/SD_CARD/DCIM/IMG_0042.JPG (4.2 MB)
  2. /Volumes/SD_CARD/DCIM/scan_001.jpg (1.1 MB)

[b]ack to menu
```

**Duplicates:**
```
Duplicate files (10 files):
  Group 1: 2 files share content
    .../DCIM/IMG_0042.JPG (4.2 MB, 2024-01-15)
    .../DCIM/backup/IMG_0042.JPG (4.2 MB, 2024-01-15)

  ... (4 more groups)

[b]ack to menu
```

Read-only for v1. User sees what's going on, goes back to menu.

#### 5. Library Create Flow

Interactive when called without args:

```
$ trove library create

Library name: Family Photos
Location: /Volumes/photos/family

Found 30,247 media files. Scan and organize? [y/n]
> y

Scanning...
  Hashing... ████████████████████ 30247/30247

Initialization plan:
  Already organized:   29,750 (no move needed)
  Need to relocate:       247
  Duplicates found:        50 (both copies kept)
  No date:                  3

Proceed? [y/n]
> y

Organizing... ████████████████████ 30247/30247

Library initialized:
  Indexed:    29,750
  Moved:         247
  Duplicates:     50
  Quarantined:     3
```

Still supports args for scripting: `trove library create "Name" /path --yes`

#### 6. --yes Flag

All prompts skippable with `--yes` / `-y`:
- Library resolution requires `--library` with `--yes` if multiple exist
- All confirmations auto-proceed
- Source files kept (not deleted) unless `--delete-sources` also passed
- No menus — straight to import

#### 7. What Does NOT Change

- All underlying modules (scan, import, complete, initialize, verify)
- The plan/execute architecture
- The DB schema
- Audit logging
- The resolve_library helper (already built)
