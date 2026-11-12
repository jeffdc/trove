---
status: refined
created: 2026-04-05
updated: 2026-04-13
relates: [9638, 7053, 27c2]
docket: true
---

# Photo tagging system

## Core idea

Existing libraries are organized by directory names that represent categories/tags (e.g. species, locations, trips). When reorganizing these libraries by date, preserve the old directory names as tags on the photos rather than losing that curation.

## Phase 1: Original path capture (current scope)

### Schema change

Add `original_path TEXT` column to `entries` table (nullable). Migration via `ALTER TABLE entries ADD COLUMN original_path TEXT`.

- Files that are already in the correct location: NULL
- Files that get moved: pre-move path relative to library root
- Example: `/Volumes/photos/Nature/mammals/deer.jpg` → `original_path = "mammals/deer.jpg"`

### Initialize change

In `initialize.py`, before moving a file, store its current relative path (relative to library root) in `original_path`. No change for files already in the correct location.

### What phase 1 does NOT include

- No tagging logic, tag schema, or tag CLI commands
- No EXIF writing
- No folder name parsing or interpretation

### First use: Nature photo library

Create library at `/Volumes/photos/Nature` and run `trove initialize`. Thousands of files, organized as a hodge-podge of date folders, location names, and species categories. The `original_path` column preserves the folder structure metadata through the reorganization.

## Phase 2: Tag extraction (future)

Use `original_path` data to derive tags from directory names. Open questions:

- Tag schema: flat list? hierarchical? (nested dirs like "birds/raptors/hawks")
- Tag source: just directory names, or also support manual tagging later?
- Queryability: search by tag, list tags, combine tags?
- Export: can tags map to EXIF/XMP keywords for interop with Lightroom etc?
- Bulk operations: tag/untag groups of files?
