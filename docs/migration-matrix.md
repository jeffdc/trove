# Migration Matrix Draft

This document maps the current Python/main database schema onto the target v1
schema defined in `docs/target-schema.md`.

It is the first-pass migration plan. It is not yet executable migration code.

See also:

- `docs/library-centric-domain-model.md`
- `docs/target-schema.md`
- `docs/ocaml-reshape-plan.md`

## Purpose

The migration must preserve expensive completed work already represented in the
current database.

This means:

- do not treat existing `files` rows as disposable just because they mix
  concerns poorly
- do not force a full rescan or re-extract when trustworthy data can be carried
  forward
- preserve provenance, content identity, metadata, library membership, and
  path-planning information wherever possible

## Source Schema Inventory

Current Python/main schema:

- `libraries`
- `entries`
- `files`
- `schema_version`

Current schema version:

- `2`

## High-Level Mapping

### `libraries`

Current role:

- top-level library definition and policy owner

Target mapping:

- `libraries`

Notes:

- this is the cleanest mapping in the migration
- `location` becomes `root_path`
- `config` becomes `config_json`

### `entries`

Current role:

- durable library membership and intended relative placement

Target mapping:

- `library_items`
- `library_placements`
- partially `file_objects`

Notes:

- an entry is close to the new `library_item`, but the new model separates
  membership from placement and from file-object facts
- `original_path` is provenance and should be preserved if present

### `files`

Current role:

- mixed working-state table containing:
  - source provenance
  - content identity (`md5_hash`)
  - extracted metadata
  - run progress
  - planned placement
  - failure state

Target mapping:

- `source_observations`
- `file_objects`
- `run_items`
- `file_ops` in limited cases
- preserve as legacy where ownership is ambiguous

Notes:

- this is the hard part of the migration
- no single current `files` row maps 1:1 to one new table

## Column Mapping

### Current `libraries`

| Current column | Target table | Target column | Notes |
|---|---|---|---|
| `id` | `libraries` | `id` | preserve if practical, otherwise remap deterministically |
| `name` | `libraries` | `name` | direct |
| `location` | `libraries` | `root_path` | rename |
| `config` | `libraries` | `config_json` | direct rename |
| `created_at` | `libraries` | `created_at` | direct |

### Current `entries`

| Current column | Target table | Target column | Notes |
|---|---|---|---|
| `id` | `library_items` | legacy reference or remapped id | preserve as migration reference if useful |
| `library_id` | `library_items` | `library_id` | direct |
| `relative_path` | `library_placements` | `intended_relative_path` | direct semantic mapping |
| `relative_path` | `library_placements` | `actual_relative_path` | initialize equal to intended on migration |
| `file_size` | `file_objects` | `size_bytes` | populate when trustworthy |
| `md5_hash` | `file_objects` | `content_hash` | canonical identity hash in v1 |
| `capture_date` | `file_objects` | `capture_date` | direct |
| `camera_model` | `file_objects` | `camera_model` | direct |
| `imported_at` | `library_items` | `created_at` or provenance field | preserve as admission timestamp |
| `original_path` | `library_items` or legacy provenance | provenance field | preserve, do not discard |

### Current `files`

| Current column | Target table | Target column | Notes |
|---|---|---|---|
| `id` | `source_observations` / `run_items` | legacy reference | useful for audit and migration tracing |
| `source_path` | `source_observations` | `observed_path` | direct provenance |
| `source_type` | `source_roots` | `source_kind` | coarse mapping, may need normalization |
| `file_size` | `source_observations` and/or `file_objects` | `size_bytes` | preserve in both contexts where trusted |
| `file_modify_date` | `source_observations` | `mtime` | direct provenance |
| `md5_hash` | `file_objects` | `content_hash` | canonical identity hash in v1 |
| `capture_date` | `file_objects` | `capture_date` | direct |
| `camera_model` | `file_objects` | `camera_model` | direct |
| `target_path` | `run_items` | `planned_relative_path` | current path-planning output |
| `target_path` | `library_placements` | `intended_relative_path` | only when row has become durable membership |
| `status` | `run_items` | `workflow_state` / `disposition` | status mapping below |
| `error_message` | `run_items` / `file_ops` | `failure_reason` / `error_text` | preserve |
| `discovered_at` | `source_observations` | `observed_at` | direct |
| `hashed_at` | `file_objects` or migration provenance | hash timing | preserve if present |

## Status Mapping For Current `files`

The current `files.status` column is the most overloaded part of the schema.

The migration should treat every status as durable evidence of what work was
completed or what problem was encountered.

### `discovered`

Meaning today:

- path observed and persisted
- no successful content hash yet

Target mapping:

- create `source_observations`
- create `run_items` with:
  - `workflow_state = observed`
  - `disposition = pending`
- do not create `file_objects` unless hash already exists elsewhere

Preserve:

- `source_path`
- `file_size`
- `file_modify_date`
- `discovered_at`

### `hashed`

Meaning today:

- content hash exists
- metadata may or may not be complete
- target path may or may not be computed

Target mapping:

- create `source_observations`
- create or attach `file_objects`
- create `run_items` with:
  - `workflow_state = identified`
  - `disposition = pending`

Additional rules:

- if `target_path` exists, carry it into `run_items.planned_relative_path`
- if `capture_date` or `camera_model` exist, populate `file_objects`

Preserve:

- `md5_hash`
- `hashed_at`
- `target_path`
- extracted metadata fields

### `duplicate`

Meaning today:

- file was determined to be a duplicate in current workflow
- current schema does not preserve enough context to know whether it was batch
  duplicate or already-in-library duplicate in every case

Target mapping:

- create `source_observations`
- create or attach `file_objects` if hash exists
- create `run_items` with:
  - `workflow_state = completed`
  - `disposition = duplicate_in_library` or legacy duplicate bucket

Important caveat:

- if the old row does not preserve enough context to distinguish duplicate kind,
  migration should preserve the raw row as legacy evidence instead of pretending
  certainty it does not have

### `quarantined`

Meaning today:

- file was observed but blocked from normal admission
- common reason is `no_date`
- may also reflect hash or metadata failure paths

Target mapping:

- create `source_observations`
- create `run_items` with:
  - `workflow_state = completed`
  - `disposition = quarantined`
  - `failure_reason` from `error_message`
- attach `file_objects` when hash exists

Preserve:

- `error_message`
- any partial metadata or planned path if already computed

### `imported`

Meaning today:

- file record was successfully promoted into the library
- corresponding `entries` row should exist

Target mapping:

- migrate durable membership primarily from `entries`
- if imported `files` rows still exist at migration time, use them as provenance
  to link `source_observations` and `run_items` to the resulting
  `library_items`
- create `run_items` with:
  - `workflow_state = completed`
  - `disposition = admitted`

Important rule:

- if an imported file row exists but no matching entry exists, preserve it as
  anomalous legacy state and do not silently upgrade it into a healthy
  `library_item`

### `missing`

Meaning today:

- initialization or repair logic observed missing source state or mismatch

Target mapping:

- create `source_observations`
- create or attach `file_objects` when hash exists
- create `run_items` with:
  - `workflow_state = failed`
  - `disposition = failed`
  - `failure_reason` from `error_message`

Potential library-side consequence:

- if this status corresponds to a known library member, initialize
  `library_items.status = missing` or `broken`
- otherwise preserve only as failed run evidence

### `completed`

Meaning today:

- not present in current main schema operations as a durable steady-state value,
  but appears in cleanup tests and legacy expectations

Target mapping:

- preserve as legacy if encountered
- map to `run_items.workflow_state = completed` only when surrounding evidence
  makes ownership unambiguous

## Trust Levels For Migration

Not every old row should be treated equally.

### Strongly trustworthy

These should migrate directly when present:

- `libraries.name`
- `libraries.location`
- `libraries.config`
- `entries.library_id`
- `entries.relative_path`
- `entries.file_size`
- `entries.md5_hash`
- `entries.capture_date`
- `entries.camera_model`
- `entries.imported_at`
- `files.source_path`
- `files.file_size`
- `files.file_modify_date`
- `files.md5_hash`
- `files.capture_date`
- `files.camera_model`
- `files.discovered_at`
- `files.hashed_at`

### Context-dependent

These are valuable, but meaning depends on surrounding rows:

- `files.target_path`
- `files.status`
- `files.error_message`
- `entries.original_path`
- `files.source_type`

### Preserve as legacy if ambiguous

If the migration cannot assign exact ownership confidently, preserve the source
row in a legacy table or migration log rather than fabricating certainty.

Examples:

- duplicate rows without enough context to distinguish duplicate kind
- imported rows with no matching entry
- missing rows with unclear library linkage

## Recommended Migration Order

The migration should write a new database, not mutate the source database in
place for the first implementation.

Recommended order:

1. migrate `libraries`
2. migrate `entries` into `file_objects`, `library_items`, and
   `library_placements`
3. migrate `files` into `source_observations` and `run_items`
4. attach `files.md5_hash` rows to existing `file_objects` where possible
5. preserve unresolved or ambiguous rows into legacy migration tables
6. write migration summary and anomaly counts

## Important Reconciliation Rules

### Entry-first library membership

If there is a conflict between old `entries` and old `files` about whether a
file is in the library, `entries` should win for durable library membership.

Reason:

- `entries` is the durable collection table today
- `files` is the mixed workflow table

### File-object reuse

When multiple old rows share the same `md5_hash`, they should attach to the
same `file_object` unless there is strong evidence of corruption or bad data.

### Planned path versus admitted path

`files.target_path` is not enough on its own to create a durable library
placement.

Only use it to initialize `library_placements` when the surrounding evidence
shows that the row truly became a library member, typically through `entries`.

## Open Migration Questions

- how should `source_type` values from the old schema map onto the tighter
  `source_roots.source_kind` enum
- should imported `files` rows be linked to `library_items` only by hash, or by
  hash plus path heuristics when multiple entries share the same hash
- do we want a dedicated `legacy_files` preservation table in the new DB, or a
  sidecar migration report only
- should old `entries` without `md5_hash` create partial `file_objects`, or
  should they remain membership rows awaiting later backfill

## First Migration Slice

The first implementation should intentionally target the subset of old state
that is both valuable and sufficiently trustworthy to migrate without
reconstructing too much missing context.

### In scope for the first slice

- all `libraries`
- all `entries`
- all `files` rows at statuses:
  - `discovered`
  - `hashed`
  - `quarantined`
  - `imported`
  - `missing`
- all old `md5_hash` values
- all old `capture_date` and `camera_model` values
- all old `target_path` values as run-scoped planned paths

### Intentionally conservative in the first slice

- `duplicate` rows migrate, but duplicate kind is treated cautiously
- `completed` rows are preserved as legacy unless ownership is obvious
- file-operation history is reconstructed only minimally from current evidence,
  not invented wholesale

### Practical simplifications for the first slice

- `source_type` should map to `source_kind = import` by default unless there is
  strong evidence the row came from library initialization
- `entries` should be treated as authoritative for durable library membership
- `files` should be treated as authoritative for source provenance and partial
  workflow progress

### Explicit non-goals for the first slice

- perfect reconstruction of historical run boundaries from the old schema
- exact recovery of batch-duplicate versus library-duplicate semantics in every
  ambiguous old row
- full reconstruction of past file operations that were never modeled durably

## Anomaly Report Shape

The first migrator should emit a machine-readable anomaly report alongside the
new database.

Suggested top-level fields:

- `source_db_path`
- `source_schema_version`
- `migrated_at`
- `counts`
- `warnings`
- `anomalies`

### Suggested count buckets

- libraries migrated
- entries migrated
- file_objects created
- source_observations created
- run_items created
- library_items created
- library_placements created
- legacy rows preserved

### Suggested anomaly buckets

- imported file rows with no matching entry
- duplicate rows with ambiguous duplicate kind
- missing rows with no clear library linkage
- entries with no `md5_hash`
- file rows whose `target_path` conflicts with durable entry state
- hash collisions or inconsistent file sizes for same `md5_hash`

The point of this report is not just debugging. It is the safety valve that
lets the migration be explicit about uncertain cases instead of silently making
up answers.

## Immediate Next Step

Use this matrix to define:

1. the mandatory fields for the first migration slice
2. the anomaly report format for ambiguous old rows
3. the OCaml migration layer API that reads old rows and writes the new schema
