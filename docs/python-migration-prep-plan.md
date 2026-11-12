# Python Migration Preparation Plan

This document defines the cleanup work to complete in the current Python
`trove` implementation before migrating real library state into the new target
application and schema.

The point of this work is not to preserve every artifact of the current
database. The point is to remove avoidable ambiguity in the Python source data
so the migration can stay strict where it should be strict.

## Goal

Prepare a real `trove` database so that migration into the target system is not
dominated by two known classes of source-state problems:

- same-library exact duplicate `entries`
- `entries` missing `md5_hash`

The target side should continue to treat exact duplicate content within a
single library as invalid. The Python app should clean that up first rather
than forcing the target model to accept it.

## Current Baseline In Python

The current Python code already provides part of the needed foundation:

- `entries` contains `library_id`, `relative_path`, `md5_hash`,
  `original_path`, and related metadata
- `trove hash <library>` backfills missing `md5_hash` values for existing
  entries
- `trove duplicates <library>` reports duplicate groups within a library
- duplicate hashes are currently allowed by the schema

What is still missing:

- reporting for missing or unreadable files during hash backfill
- deterministic keeper selection for exact duplicate cleanup
- removal of duplicate rows from the `entries` table
- generation of a newline-delimited delete list
- dry-run and apply modes for duplicate cleanup
- tests that lock down cleanup behavior against the current DB schema

This plan is about filling those gaps without weakening the migration target.

## Source-State Rules

### Exact Duplicate Definition

Two entries are exact duplicates if all of the following are true:

- they belong to the same library
- both rows have a non-null `md5_hash`
- the `md5_hash` values are identical

This is intentionally narrow.

It is not:

- fuzzy duplicate detection
- cross-library duplicate handling
- path-based duplicate detection without hash confirmation

### Library-Local Only

Cleanup is scoped to a single library.

The Python cleanup path must not compare or collapse duplicates across
libraries.

### Missing Hashes Are A Prerequisite Problem

Duplicate cleanup should not run until hash backfill has been completed for the
target library, or until the remaining unhashed rows are explicitly understood
and reported.

Entries without `md5_hash` cannot safely participate in exact duplicate
grouping.

## Keeper Rule

Within an exact-duplicate group, keep the row whose managed filename best
matches the original filename rather than a suffix-appended managed duplicate
such as `_1`, `_2`, and so on.

### Evidence Order

Keeper selection should use this order:

1. Prefer the entry whose managed basename matches the basename implied by
   `original_path`, when `original_path` exists.
2. Otherwise prefer a basename that does not end in an appended numeric
   duplicate suffix.
3. If multiple candidates still remain, choose the lowest `entries.id`.

This keeps the result deterministic and reviewable.

### Duplicate Suffix Rule

For this cleanup pass, treat a managed filename as suffix-appended if its stem
ends in `_<number>` immediately before the file extension.

Examples:

- `IMG_1234.jpg` is not suffix-appended
- `IMG_1234_1.jpg` is suffix-appended
- `IMG_1234_2.CR3` is suffix-appended

The helper that evaluates this should operate on the basename only, not on the
full relative path.

### Entries Without `original_path`

If `original_path` is absent, keeper selection falls back to:

- basename without duplicate suffix
- then lowest `entries.id`

No other heuristics should be introduced in this cleanup pass.

## Cleanup Scope

The Python app performs database cleanup only.

It must not delete files from disk directly.

Instead, it must emit a newline-delimited file containing the absolute paths of
the managed files corresponding to non-keeper rows. That file is the input to a
separate reviewed deletion step outside Python.

## Required Outputs

The cleanup workflow must produce all of the following:

- a summary of entries missing `md5_hash` before and after backfill
- a report of entries whose on-disk files were missing or unreadable during
  backfill
- a dry-run summary of duplicate groups found
- a deterministic keeper decision for each duplicate group
- a newline-delimited delete-list file of absolute paths to remove externally
- a summary of database rows updated or removed

### Delete-List Format

The delete list is required output.

Format:

- plain text
- one absolute path per line
- no quoting
- no shell escaping
- stable ordering for repeatability

For each non-keeper duplicate entry, the emitted path must be:

- `Path(library.location) / entry.relative_path`

## Execution Model

The cleanup work should remain split into two explicit phases.

### Phase 1: Hash Backfill

Use the existing `trove hash <library>` command as the starting point rather
than inventing a second hash-backfill path.

Required behavior for this phase:

- select only `entries` where `md5_hash IS NULL`
- compute the hash from the managed on-disk file at
  `Path(library.location) / entry.relative_path`
- write the hash back to `entries.md5_hash`
- report rows whose files are missing or unreadable
- leave rows unchanged when hashing fails
- print a summary showing:
  - count examined
  - count backfilled
  - count still unhashed
  - count missing or unreadable

Constraints:

- do not attempt duplicate cleanup in this phase
- do not synthesize hashes for missing files
- do not mutate rows that already have `md5_hash`

### Phase 2: Exact Duplicate Cleanup

Add a new cleanup command or workflow for exact same-library duplicate entries.

The concrete command name is less important than the behavior, but it must
support both dry-run and apply modes.

Required behavior:

- group entries by `(library_id, md5_hash)` using only non-null hashes
- identify groups with more than one row
- choose exactly one keeper per group using the keeper rule above
- treat all remaining rows in the group as non-keepers
- write non-keeper managed paths to the delete-list file
- in apply mode, remove the non-keeper rows from `entries`

Constraints:

- do not delete files from disk
- do not operate on groups with null `md5_hash`
- make group ordering deterministic
- make keeper choice deterministic
- make delete-list output deterministic

## Recommended CLI Shape

The existing CLI already has a natural split:

- `trove hash <library>` for phase 1
- a new duplicate-cleanup command for phase 2

One workable shape would be:

```text
trove hash <library>
trove dedupe <library> --dry-run --delete-list /path/to/delete.txt
trove dedupe <library> --apply --delete-list /path/to/delete.txt
```

This does not lock the implementation to the name `dedupe`. It only captures
the required interface:

- explicit target library
- explicit dry-run vs apply
- explicit delete-list output path

## Implementation Notes

### Database Touchpoints

The current DB layer already has:

- `list_entries`
- `get_entries_by_hash`
- `get_duplicate_groups`
- `update_entry_hash`

The cleanup work will likely need small DB-layer additions, such as:

- a query that returns only entries with missing hashes
- a duplicate-group query that excludes null hashes explicitly
- deletion of specific `entries.id` rows inside a transaction

### Deterministic Ordering

Repeated dry runs against unchanged input should produce the same duplicate
grouping, the same keeper choices, and the same delete-list output.

Sort duplicate groups and delete-list rows explicitly. A straightforward stable
ordering is:

- by `library_id`
- then by `md5_hash`
- then by `entries.id`

### Hash Backfill Failure Reporting

Backfill should distinguish between:

- file missing on disk
- file exists but hashing failed

Those rows should remain unhashed so they stay visible for manual review before
migration.

### Transaction Boundaries

Apply-mode duplicate cleanup should remove non-keeper rows transactionally after
the delete list has been materialized from the same in-memory analysis result.

The delete-list contents for dry-run and apply must be identical for the same
input state.

## Validation Workflow

Run the cleanup against a copied database and copied library tree first.

Recommended sequence:

1. Copy the real database and the relevant library tree.
2. Run `trove hash <library>` on the copied dataset.
3. Confirm the remaining unhashed count is understood.
4. Run duplicate cleanup in dry-run mode.
5. Review duplicate-group summaries and the delete-list output.
6. Run duplicate cleanup in apply mode against the copied database.
7. Verify the duplicate groups are gone and the remaining rows match the
   intended keepers.
8. Spot-check delete-list paths against removed DB rows.
9. Only then repeat the same process against the real database.
10. Create a fresh copy of the cleaned database for target-side migration.

## Validation Checks

After cleanup on the copied dataset, verify:

- no `(library_id, md5_hash)` group with non-null hash has more than one row
- delete-list paths correspond exactly to rows removed in apply mode
- keeper rows still point at the intended managed file
- no rows from other libraries changed
- rows still missing `md5_hash` are understood exceptions rather than silent
  failures
- migration against the cleaned DB produces a sharply smaller anomaly set

## Test Coverage Required In Python

Before using the cleanup flow on the primary dataset, add tests for at least:

- hash backfill updates only rows with null `md5_hash`
- hash backfill reports missing files without mutating the row
- duplicate grouping ignores null hashes
- keeper selection prefers original-name matches over suffixed names
- keeper selection falls back to non-suffixed basename
- keeper selection finally falls back to lowest `entries.id`
- dry-run emits delete-list output without mutating the database
- apply removes only non-keeper rows
- dry-run and apply produce identical delete-list output for the same input
- cleanup never affects other libraries

## Non-Goals

This prep work does not attempt to solve:

- fuzzy duplicate detection
- cross-library duplicate reporting
- file deletion from Python
- metadata normalization beyond the hash backfill needed for exact duplicate
  grouping
- redesign of the current library schema before migration

## Expected Migration Effect

If this plan is executed successfully before migration:

- same-library exact duplicate-content conflicts should largely disappear
- the target invariant disallowing exact duplicate content within a library can
  remain strict
- migration anomalies should shrink toward real edge cases instead of bulk
  cleanup debt

## Next Implementation Step

The next Python-side work item should be:

1. harden `trove hash` so it reports remaining missing-hash cases clearly
2. add deterministic exact-duplicate cleanup with dry-run and apply modes
3. emit a required newline-delimited delete list
4. add tests that lock down keeper selection and cleanup safety
5. validate the workflow on a copied real database before touching the primary
   dataset
