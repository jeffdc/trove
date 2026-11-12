# Durable Import Recovery and Destructive-Action Safety

Date: 2026-08-09
Status: Approved design

## Problem

An external import timed out before copying its first file. The next invocation reported that all 102 source files were already scanned, but planned zero files for import. It then claimed that all files were accounted for.

The source files were not marked imported. `Found 0 new media files (102 already scanned)` meant only that unchanged source records already existed in the transient `files` table. A permanent library entry is created, and a file record becomes `imported`, only after a destination copy has been verified.

Two implementation defects turned the recoverable interruption into misleading state:

1. Resume discovers prior work through a raw source-path string prefix. Equivalent spellings such as relative and absolute paths can fail to match, so valid `hashed` records may not enter the new plan.
2. An empty plan or interactive abort globally deletes transient records by status. This can discard failed or unrelated work and makes the false “accounted for” result permanent.

The database also lacks an operation-level failure record. A timeout is reduced to an error count while the CLI exits successfully.

## Goals

- Represent each import or initialization run durably, including pending, running, failed, and completed state.
- Resume a failed external import without rescanning, rehashing, or re-extracting unchanged files.
- Offer interactive users only **Resume** or **Abort** when matching pending/failed work exists. Abort must not mutate filesystem or database state. `--yes` explicitly selects resume.
- Stop immediately on a destination mount timeout, preserve resumable state, show the failed stage/path, and exit non-zero.
- Never report “nothing new” or “all accounted for” while the selected run has failed or pending files.
- Eliminate global transient-state cleanup.
- Enforce a repository-wide authorization rule for destructive actions.
- Verify behavior only with isolated temporary fixtures; do not run live `trove` commands or access the live Trove database/library.

## Non-goals

- Automatically delete or repair partial destination files.
- Delete source media after an external copy import.
- Add automatic retries beyond the existing verified-copy retry behavior.
- Change media classification, hash, metadata, or target-path rules.
- Add a general workflow engine beyond the run state needed by the existing pipelines.

## Safety Contract

A command may delete, overwrite, rename, or move a source/library filesystem object, or delete a permanent library/entry record, only after explicit authorization. A specific destructive command or flag counts as authorization, including `delete`, `dedupe --apply`, `--clear-missing`, or `--yes` after a displayed plan. Interactive flows retain their existing confirmations.

External copy import is additive:

- It never deletes source files.
- It never overwrites or deletes an existing destination object.
- It does not delete a failed or partial destination copy.
- It creates a permanent entry only after byte verification succeeds.

Transient scan/cache rows are internal state and may be removed automatically only when their own run reaches a verified terminal state. Trove-owned temporary artifacts, such as an exiftool argument file, may be removed automatically and are outside the user-data contract.

### Existing authorized destructive flows

- In-library initialization displays the relocation plan and requires `Proceed?`; `--yes` explicitly authorizes the plan. Same-filesystem rename and cross-device copy/verify/source-delete remain within that authorization.
- Library deletion requires typing the library name.
- Permanent duplicate-entry deletion requires `dedupe --apply`.
- Missing transient-record cleanup requires `--clear-missing` and confirmation.

### Required safety corrections

- Destination creation must be exclusive, not check-then-open with `"wb"`, so a concurrent creator cannot be overwritten.
- Failed copy verification must preserve any destination object rather than unlinking it.
- Empty-plan, abort, and completion paths must never delete records globally by status.
- Generated outputs must not silently overwrite an unrelated existing file. A user-supplied output flag is explicit authorization; fixed generated report names must use a collision-free path.

## Durable Run Model

Add schema migration 4.

### `import_runs`

- `id INTEGER PRIMARY KEY`
- `library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE`
- `source_root TEXT NOT NULL` — canonical absolute path
- `mode TEXT NOT NULL` — `copy` or `initialize`
- `status TEXT NOT NULL` — `pending`, `running`, `failed`, or `completed`
- `last_error TEXT`
- `failed_at TEXT`
- `created_at TEXT NOT NULL`
- `updated_at TEXT NOT NULL`
- `completed_at TEXT`

A partial unique index permits only one non-completed run for a `(library_id, source_root, mode)` tuple. Completed runs remain as compact operation history. A successfully resumed run becomes `completed`; `last_error` and `failed_at` remain available as the last failure history.

### `files.import_run_id`

Add a nullable foreign key from `files` to `import_runs` with `ON DELETE CASCADE`. New discovery always supplies a run ID and stores canonical absolute `source_path` values. File status remains the detailed pipeline state:

- `discovered` — needs hashing
- `hashed` — ready for remaining metadata/path/classification/import work
- `failed` — the file operation failed; `error_message` contains a stable reason and relevant path/stage
- `imported`, `duplicate`, `quarantined` — accounted terminal states
- existing initialization-specific states remain supported

Existing unscoped rows remain nullable after migration. The first matching command may offer to attach legacy rows only after canonical containment checks and explicit Resume selection. Legacy rows are never globally deleted or silently attached to another library.

## External Import Flow

1. Canonicalize the source root once at `add` command entry.
2. Look up the active copy run for the selected library and canonical source.
3. If the run is pending or failed, display run/file counts and the last error, then prompt `[r]esume or [a]bort`.
   - Abort returns without changing the run, files, source, or destination.
   - Resume changes the run to `running` and continues.
   - `--yes` explicitly selects Resume.
4. If no active run exists, create a `pending` run, perform discovery into that run, display analysis, and change it to `running` only after Import is selected.
5. Normal discovery still detects new or changed source files. Unchanged records reuse existing hashes, metadata, and target paths.
6. Classification operates only on file IDs belonging to the selected run.
7. Batch/library duplicates are terminal only after their duplicate status is persisted for this run.
8. Each destination is created with exclusive-create semantics. Existing paths are hashed:
   - Matching hash: adopt the verified destination and create the permanent entry.
   - Different hash: preserve it and select a collision-free suffix.
9. Create the permanent entry and mark the file imported in one transaction only after destination verification.
10. Complete and clean transient rows only when every run file is in a verified/accounted terminal state and no file is failed, discovered, or hashed.

A plan with zero copy candidates is not automatically a completed run. Duplicate-only or quarantined runs must first persist their terminal decisions and pass run-scoped completion checks. A run with zero associated records may report no work but may not delete other state.

## In-Library Initialization Flow

Initialization uses the same durable run model with `mode="initialize"`. Discovery and classification associate working records with that run before the relocation plan is displayed. The displayed plan plus `Proceed?`, or the explicit `--yes` flag, authorizes its rename and verified cross-device copy/delete operations.

Successful per-file actions may clean their own transient rows. Any timeout, move, rollback, or indexing failure marks the affected record and run failed with a stable error. Pending and failed records remain attached for the existing source/destination reconciliation logic on Resume. The run becomes completed only when no pending or failed record remains. Choosing Abort before or after planning leaves the run resumable and performs no filesystem or permanent-record mutation.

## Failure Handling

### Destination timeout

- Stop processing immediately.
- Atomically mark the current file `failed` with `error_message="import_timeout:<stage>:<destination>"` and mark the run `failed` with the same last error and timestamp.
- Leave unattempted files in their existing pending state, normally `hashed`.
- Preserve imported/duplicate/quarantined decisions already completed in the run.
- Close progress output, print a concise resumable-failure summary, and exit non-zero.
- Do not emit an expected timeout traceback in normal CLI output.

### Ordinary copy or verification failure

- Preserve source and destination objects.
- Mark the affected file `failed` with a stable reason.
- Follow the existing continue/stop error policy for non-timeout failures, but leave the run `failed` and exit non-zero if any failure remains.

### Partial destination

A timeout can leave a partial destination. Trove never deletes it automatically. On resume:

- If its hash matches the source hash, it is accepted as the completed copy.
- If its hash differs, it is reported and preserved. The source is copied to a collision-free suffix.

## Run-Scoped Completion and Cleanup

`plan_complete` and `execute_complete` accept a run ID and query only that run’s files. Completion is blocked by `failed`, `discovered`, or `hashed` records and by any imported record without a matching permanent entry in the selected library.

Cleanup deletes only the terminal transient file IDs listed by the verified completion plan. It never calls a global status deletion. Transient cleanup and the durable run’s transition to `completed` occur in one database transaction after entry checks succeed.

Interactive Abort never cleans transient rows. Failed runs retain every record needed for resume.

## Repository-wide Destructive-Action Audit

The implementation will inventory every filesystem and permanent-record mutation and classify it as:

1. non-destructive/additive;
2. transient internal cleanup after verified completion; or
3. destructive and protected by a specific command/flag or displayed-plan confirmation.

Regression tests will cover the authorization gates around library deletion, dedupe apply, missing-record cleanup, and in-library moves. External imports will additionally prove no source deletion, no destination overwrite, no failed-copy deletion, and safe behavior under a destination creation race.

Generated fixed-name reports will choose a suffix when the target exists. Explicit user-provided output paths may be replaced only because supplying that output flag is the authorization for that path.

## Tests and Verification

All verification uses isolated `tmp_path` directories and temporary SQLite databases. No live Trove command, default database, mounted photo library, or user source directory is accessed.

Required behavioral coverage:

- Schema migration creates run state and preserves existing databases.
- A relative `.` source and its canonical path identify the same run.
- Matching pending/failed runs prompt Resume or Abort.
- Abort produces no database or filesystem changes.
- `--yes` resumes without an interactive prompt.
- Timeout marks file/run failed, preserves remaining records and files, and returns a non-zero CLI result.
- A rerun reuses hash/metadata/path state and imports all remaining files.
- Failed or pending records prevent “all accounted for” and prevent cleanup.
- Completion removes only terminal transient rows for its run.
- Runs for other sources and libraries remain untouched.
- Exclusive destination creation cannot overwrite a concurrently created path.
- Hash mismatch and ordinary copy errors preserve failed destination objects.
- Matching orphan/partial destinations are safely adopted.
- Different orphan/partial destinations are preserved and cause suffixing.
- Initialization failures remain attached to a failed run and resume through source/destination reconciliation.
- Existing destructive commands require their current explicit authorization.
- Generated reports do not silently overwrite an existing fixed-name file.

Run focused pytest modules for database, pipeline/importer, completion, initialization, and CLI behavior, followed by the full existing test suite and static checks. Do not invoke the installed `trove` executable.
