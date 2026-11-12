---
status: planned
tags: [rewrite, schema, recovery]
created: 2026-04-14
updated: 2026-05-06
relates: [27c2, f1e4, 905e]
---

# Replace files table with run-centric durable pipeline state

## Why

The current `files` table is carrying two incompatible responsibilities:

- expensive derived state that should survive interruption: discovered size/mtime, hash work, metadata work, target-path planning
- per-run workflow state that is inherently transient: queued, hashing, imported, quarantined, duplicate, failed, interrupted

That mismatch is what made the `library_id` migration messy.

The key problems to solve are:

- partial work may represent hours or days of processing and cannot be dropped casually
- migration of old `files` rows cannot rely on heuristics that silently guess ownership
- kill and timeout behavior must be recoverable and explicit
- resume should be scoped to a concrete run, not inferred from global transient rows
- library ownership should be modeled structurally, not bolted onto scratch rows after the fact

## Decision

Do not continue evolving the current `files` table as the primary runtime model.

Introduce a run-centric model with a clean separation between:

- durable file facts
- durable run metadata
- per-run item state
- file mutation journal / reconciliation state

Keep `libraries` and `entries` as the durable canonical tables.
Treat the current `files` table as a legacy source for salvage, not as the long-term state model.

## Goals

- preserve expensive completed work across interruption, retries, and version changes
- make cancellation and timeout recovery explicit and deterministic
- make resume semantics exact at the run level
- eliminate heuristic library reassignment during migration for newly written state
- support future multi-phase execution without overloading one table

## Non-Goals

- perfect automatic recovery of every ambiguous legacy `files` row
- preserving the old schema as the long-term runtime representation
- teaching the Go worker any domain semantics about photos, libraries, duplicates, or quarantine policy

## Target Schema

### `libraries`

Keep as-is. This remains the durable record of library identity, root path, and config.

### `entries`

Keep as-is. This remains the durable record of files that belong to a library.

### `runs`

One row per add/init execution.

Suggested fields:

- `id`
- `library_id`
- `mode` (`add`, `init`, later maybe `verify`, `repair`)
- `source_root`
- `status` (`planned`, `active`, `interrupted`, `completed`, `failed`, `cancelled`)
- `created_at`
- `started_at`
- `updated_at`
- `finished_at`
- `tool_version`
- `worker_protocol_version`
- `cancel_requested`
- `error_summary`

Properties:

- resume is always attached to a concrete run
- multiple historical runs can exist without colliding
- library scoping is structural and no longer inferred from per-file scratch rows

### `run_items`

One row per file in a run.

Suggested fields:

- `id`
- `run_id`
- `source_path`
- `rel_source_path`
- `source_size`
- `source_mtime`
- `fact_key`
- `status`
- `action`
- `target_path`
- `disposition`
- `error_kind`
- `error_message`
- `discovered_at`
- `hashed_at`
- `planned_at`
- `executed_at`

Suggested status progression:

- `discovered`
- `facts_attached`
- `planned`
- `copying`
- `moving`
- `imported`
- `duplicate`
- `quarantined`
- `missing`
- `failed`
- `unknown`

Properties:

- this is the exact resumable workflow state
- deleting or archiving a run only affects that run
- completion is determined by one run’s items, not by scanning all transient rows globally

### `file_facts`

Durable cache for expensive derived work.

Suggested fields:

- `id`
- `library_id` nullable or optional depending on whether facts are library-scoped
- `source_path`
- `source_size`
- `source_mtime`
- `identity_key`
- `md5_hash`
- `capture_date`
- `camera_model`
- `normalized_filename`
- `target_path_hint`
- `computed_at`
- `fact_schema_version`

Identity key should be based on a stable source observation tuple, minimally:

- `source_path`
- `source_size`
- `source_mtime`

This is not perfect identity, but it is sufficient as a cache key for resumable work. If stronger identity is needed later, add inode/device where available or a staged content fingerprint.

Properties:

- expensive hashing and metadata work survives interruption and restart
- a new run can reuse facts without redoing the work
- migrations care about durable facts, not fragile in-progress status flags

### `file_ops`

Journal for mutating filesystem actions.

Suggested fields:

- `id`
- `run_item_id`
- `op_type` (`copy`, `move`, `unlink`, `mkdir`, `rmdir`)
- `src_path`
- `dst_path`
- `expected_hash`
- `status` (`planned`, `started`, `completed`, `failed`, `unknown`)
- `started_at`
- `finished_at`
- `error_kind`
- `error_message`

Properties:

- interrupted mutations become explicit recovery objects
- reconciliation after crash or timeout has concrete state to inspect
- filesystem recovery no longer depends on guessing from half-updated `run_items`

## Runtime Model

### Worker role

Keep the Go worker stateless and generic.

The worker should only know how to:

- stat
- walk
- hash
- copy
- move
- delete
- check mount health

It should not own library semantics, DB state, dedup policy, or import/init decisions.

### Timeout / kill strategy

The safe boundary is the worker process, not a goroutine wrapper alone.

Rules:

- risky filesystem requests may still have an internal timeout for response purposes
- if the worker reports `timeout`, assume the process may contain leaked goroutines and kill it immediately
- if the OCaml side gets no response in time, kill the worker immediately
- restart a fresh worker for subsequent operations
- persist run state before and after each mutating step so recovery is deterministic

This means timeout recovery is implemented by process replacement plus DB-backed reconciliation, not by trusting the old in-memory worker state.

## Recovery Semantics

On startup or on explicit resume of a run:

1. Load the most recent `active` or `interrupted` run for the library and mode.
2. Find `run_items` and `file_ops` with `started`, `failed`, or `unknown` status.
3. Reconcile each using filesystem facts:
   - does source still exist?
   - does destination exist?
   - if destination exists, does hash match expected?
   - does an `entries` row already exist?
4. Convert ambiguous in-flight state into one of:
   - `imported`
   - `planned`
   - `failed`
   - `missing`
   - `unknown` requiring manual intervention

The important point is that recovery is driven by journaled intent plus observable disk state, not by vague status strings on one mixed-use table.

## Migration Strategy

### Principle

Do not try to perfectly and silently reinterpret old `files` rows into the new model.

### Durable migration

Migrate only durable schema directly:

- preserve `libraries`
- preserve `entries`
- add new `runs`, `run_items`, `file_facts`, `file_ops`

### Legacy preservation

Rename or retain the old `files` table as `legacy_files_v1`.
Do not continue using it as the primary runtime table.

### Fact salvage

Create a one-time salvage pass that imports reusable data from `legacy_files_v1` into `file_facts` when safe:

- `source_path`
- `file_size`
- `file_modify_date`
- `md5_hash`
- `capture_date`
- `camera_model`
- maybe `target_path` as a hint only

This preserves the expensive work product even if the old workflow state is not trustworthy.

### Run salvage

Only auto-create a new `run` from legacy rows when ownership is high-confidence.
Examples:

- `source_path` is under exactly one library root for old init rows
- there is exactly one library in the DB for old import rows
- a future run header table exists and can be trusted

For ambiguous cases, do not guess. Surface them in a salvage workflow.

## Legacy Commands

Add explicit operator-facing recovery commands:

- `trove legacy-status`
  shows legacy rows grouped by likely library, source root, confidence, and reusable facts
- `trove salvage <library> --source <path>`
  creates a new run and imports matching reusable facts / items
- `trove salvage --all-safe`
  only imports rows whose ownership is unambiguous
- `trove legacy-drop <selection>`
  discards old legacy rows after user confirmation

This makes ambiguity visible instead of silently encoding guesses into the DB.

## CLI Behavior

### `add`

- create or resume a run for `(library_id, mode=add, source_root)`
- discover source tree into `run_items`
- attach reusable `file_facts`
- compute missing facts only where needed
- plan actions
- execute actions while journaling `file_ops`
- complete the run when all items have terminal status

### `init`

Same as `add`, but `mode=init` and the source root is the library root.

### `status`

Show run-oriented status:

- active runs
- interrupted runs
- counts by run item status
- unresolved recovery items

### `resume`

Resume a specific interrupted run or the latest interrupted run for a library/mode.

## Rollout Plan

### Phase 1

Introduce the new schema alongside existing tables.
Switch no behavior yet.

### Phase 2

Write all new executions into `runs`, `run_items`, `file_facts`, and `file_ops`.
Keep legacy read-only.

### Phase 3

Add salvage and reconciliation commands for `legacy_files_v1`.
Preserve expensive facts from old rows where safe.

### Phase 4

Switch CLI status and resume commands to the new run-centric model only.
Keep legacy tooling as an explicit recovery path.

### Phase 5

After confidence is high, retire operational dependence on the legacy table entirely.

## Consequences

Positive:

- expensive partial work is preserved explicitly
- migration logic becomes honest about ambiguity
- library scoping becomes structural instead of heuristic
- resume and recovery become deterministic
- worker timeout handling aligns with durable journaling

Negative:

- schema is larger and more explicit
- implementation takes longer than patching the current `files` model
- a salvage path is required for old state

## Acceptance Criteria

- a run can be interrupted during hashing or file mutation and resumed deterministically
- timeout or worker kill does not require guessing from a mixed transient table
- a newly added library-scoping concept never requires heuristic reassignment for newly written rows
- old expensive work can be salvaged into `file_facts` without pretending every old workflow row is trustworthy
- `status` and `complete` operate on a specific run, not on all transient rows in the database
