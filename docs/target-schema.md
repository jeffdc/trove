# Target Schema v1 Draft

This document translates the library-centric domain model into a concrete first
schema target for the `trove` OCaml rewrite.

It is not yet the migration plan. It defines the destination shape that the
migration plan should target.

See also:

- `docs/library-centric-domain-model.md`
- `docs/ocaml-reshape-plan.md`

## Purpose

The schema must satisfy these goals:

- `library` is the primary top-level managed object
- file identity is content-based, not path-based
- source paths remain durable provenance but not long-term identity
- library membership is explicit
- intended paths are derived and repairable
- file metadata is queryable from the DB without rescanning files
- future cross-library duplicate reporting remains possible

## v1 Decisions Locked

The following decisions are locked for the first schema target.

### File Identity

`file_objects.id` is the durable internal identity key.

`file_objects.content_hash` is the canonical uniqueness constraint for file
bytes in v1.

`file_objects.hash_algorithm` is not a free per-row identity choice in v1. It
is fixed to `md5` for migration compatibility.

That means:

- rows are referenced by internal integer ID
- file identity is content-based through a unique hash
- paths are never the durable identity anchor
- quick signatures are never the identity key
- `blake2b-256` may be stored, but it does not define v1 identity

This is better than hash-only references because it gives the schema stable
surrogate keys while still making byte identity explicit and enforceable.

### Full-Hash Transition Plan

v1 should capture two full hashes for newly ingested files:

- canonical identity hash: `md5`
- secondary migration hash: `blake2b-256`

Operational policy:

- new ingest computes both in one streaming pass
- existing rows may backfill `blake2b-256` lazily over time
- identity and dedupe semantics remain `md5`-based until a later deliberate
  migration flips the canonical identity hash

This keeps migration compatibility now while avoiding a future world where the
dataset is much larger and still lacks stronger hashes.

### Library Placement Uniqueness

`library_placements` carries `library_id` explicitly in v1.

That means:

- intended-path uniqueness can be enforced directly with
  `unique(library_id, intended_relative_path)`
- placement lookups by library do not require joining through
  `library_items` for every query

This is intentional denormalization in support of a core invariant.

### Metadata Storage

`file_objects` stores both:

- promoted first-class metadata columns
- full `metadata_json`

The promoted columns in v1 are limited to fields that are likely to be queried
frequently or needed in core workflows.

`quick_signature` is treated as secondary comparison evidence only. It may be
used to narrow candidate matches cheaply, but it does not determine file-object
identity.

`blake2b-256` is treated as secondary full-hash evidence in v1. Unlike
`quick_signature`, it is a real full-content hash, but it is still not the
canonical identity key until a future migration says otherwise.

### Fact Storage Shape

`file_objects` remains a single primary table in v1 rather than being split
into several 1:1 fact tables.

The important ownership boundary is:

- file-object row owns byte identity and extracted metadata snapshot

If the table later becomes unwieldy, it can be split after the model is proven.

If additional full-hash algorithms beyond `md5` and `blake2b-256` are ever
needed later, they should be modeled in a separate child table such as
`file_object_hashes(file_object_id, algorithm, digest)` rather than by allowing
multiple identity interpretations inside `file_objects`.

### Library Config Storage

`libraries.config_json` remains JSON in v1.

This avoids premature schema churn for policy fields that are not queried at
large scale.

### Placement Model

The minimum placement state in v1 is:

- intended relative path
- actual relative path
- placement status
- last verification state

This is enough to express healthy state, drift, and repair needs without
borrowing the heavier target-state model from `reprise`.

## Enum Domains

The schema should use narrow controlled string domains rather than free-form
text where operational meaning matters.

### `source_roots.source_kind`

Initial allowed values:

- `import`
- `init_root`
- `staging`

### `runs.mode`

Initial allowed values:

- `import`
- `init`
- `verify`
- `rehash`
- `reconcile`

### `runs.status`

Initial allowed values:

- `planned`
- `running`
- `completed`
- `failed`
- `interrupted`
- `abandoned`

### `run_items.workflow_state`

Initial allowed values:

- `observed`
- `identified`
- `planned`
- `executing`
- `completed`
- `failed`

### `run_items.planned_action`

Initial allowed values:

- `admit_copy`
- `admit_move`
- `index_existing`
- `quarantine`
- `skip`

### `run_items.disposition`

Initial allowed values:

- `pending`
- `admitted`
- `duplicate_in_library`
- `quarantined`
- `skipped`
- `failed`

### `library_items.status`

Initial allowed values:

- `active`
- `missing`
- `broken`
- `retired`

### `library_placements.placement_status`

Initial allowed values:

- `healthy`
- `misplaced`
- `missing`
- `repair_needed`

### `file_ops.op_kind`

Initial allowed values:

- `copy`
- `move`
- `unlink`
- `mkdir`
- `quarantine_move`

### `file_ops.status`

Initial allowed values:

- `running`
- `completed`
- `failed`

## Table Overview

The first target schema should be built around these tables:

- `libraries`
- `source_roots`
- `runs`
- `source_observations`
- `file_objects`
- `run_items`
- `library_items`
- `library_placements`
- `file_ops`

The current `entries` table may either be replaced by `library_items` or
preserved temporarily as a migration compatibility layer. The final ownership
model should live in `library_items`.

## 1. `libraries`

Owns managed collection boundaries and policy.

### Columns

- `id` integer primary key
- `name` text not null unique
- `root_path` text not null unique
- `config_json` text not null
- `created_at` text not null
- `updated_at` text not null

### Notes

- Keeping config as JSON is acceptable initially because it is not queried at
  large scale.
- `root_path` is unique in v1. If relocation history is later modeled, that can
  be relaxed by introducing a history table rather than weakening the current
  top-level invariant.

## 2. `source_roots`

Durable record of ingest or init origins.

### Columns

- `id` integer primary key
- `library_id` integer not null references `libraries(id)`
- `root_path` text not null
- `source_kind` text not null
- `created_at` text not null

### Likely Constraints

- index on `library_id`

### Notes

- `source_kind` is a narrow enum-like domain defined above.

## 3. `runs`

Durable execution and recovery boundary.

### Columns

- `id` integer primary key
- `library_id` integer not null references `libraries(id)`
- `source_root_id` integer references `source_roots(id)`
- `mode` text not null
- `status` text not null
- `options_json` text
- `summary_json` text
- `error_text` text
- `started_at` text not null
- `completed_at` text

### Likely Constraints

- index on `(library_id, started_at desc)`
- index on `(library_id, status)`

### Notes

- `mode` and `status` are narrow enum-like domains defined above.
- `status` must support interruption and exact resume behavior.

## 4. `source_observations`

Path-based observations made during a run.

### Columns

- `id` integer primary key
- `run_id` integer not null references `runs(id)`
- `source_root_id` integer not null references `source_roots(id)`
- `observed_path` text not null
- `relative_path` text
- `size_bytes` integer
- `mtime` text
- `observed_at` text not null
- `file_object_id` integer references `file_objects(id)`

### Likely Constraints

- unique on `(run_id, observed_path)`
- index on `source_root_id`
- index on `file_object_id`

### Notes

- Observations are provenance. They should survive even if the original source
  path disappears later.
- `file_object_id` may be null until hashing identifies content.
- `file_object_id` becomes the bridge from path provenance to content identity.

## 5. `file_objects`

Durable identity anchor for concrete file bytes.

### Columns

- `id` integer primary key
- `content_hash` text not null unique
- `hash_algorithm` text not null
- `blake2b_256_hash` text
- `size_bytes` integer not null
- `quick_signature` text
- `capture_date` text
- `camera_model` text
- `original_filename` text
- `extension` text
- `mime_type` text
- `metadata_json` text
- `metadata_extracted_at` text
- `metadata_tool` text
- `created_at` text not null
- `updated_at` text not null

### Likely Constraints

- unique on `content_hash`
- unique on `blake2b_256_hash`
- index on `capture_date`
- index on `camera_model`
- index on `size_bytes`
- index on `original_filename`
- index on `extension`

### Notes

- `metadata_json` is a durable metadata snapshot for the file bytes, not a
  cache of whatever happens to be at some path today.
- `hash_algorithm` should be constrained to `md5` in v1 rather than treated as
  an open operational choice.
- `blake2b_256_hash` should be nullable initially so existing rows can migrate
  without immediate rehashing, but newly ingested files should populate it.
- The promoted metadata fields in v1 should be:
  `capture_date`, `camera_model`, `original_filename`, `extension`,
  `mime_type`, `size_bytes`, `content_hash`, `blake2b_256_hash`,
  `quick_signature`.
- `quick_signature` is explicitly non-identity and exists only as a fast
  comparison aid.
- `md5` and `blake2b-256` should be computed in a single streaming pass when
  the worker reads file bytes, so remote files are not read twice just to store
  both digests.
- The initial design keeps all metadata-related fields in one table. If width
  or update patterns later become painful, this can be split without changing
  ownership semantics.

## 6. `run_items`

Run-scoped work and decisions.

### Columns

- `id` integer primary key
- `run_id` integer not null references `runs(id)`
- `source_observation_id` integer references `source_observations(id)`
- `file_object_id` integer references `file_objects(id)`
- `workflow_state` text not null
- `planned_action` text
- `disposition` text
- `planned_relative_path` text
- `failure_reason` text
- `created_at` text not null
- `updated_at` text not null

### Likely Constraints

- index on `run_id`
- index on `(run_id, workflow_state)`
- index on `(run_id, disposition)`
- index on `file_object_id`

### Notes

- This is where library-scoped ingest decisions live.
- A file object can appear in multiple run items across multiple libraries
  without collapsing those decisions into one global truth.
- `workflow_state`, `planned_action`, and `disposition` are narrow enum-like
  domains defined above.

## 7. `library_items`

Durable library membership of file objects.

### Columns

- `id` integer primary key
- `library_id` integer not null references `libraries(id)`
- `file_object_id` integer not null references `file_objects(id)`
- `admitted_from_run_item_id` integer references `run_items(id)`
- `status` text not null
- `created_at` text not null
- `updated_at` text not null

### Likely Constraints

- unique on `(library_id, file_object_id)`
- index on `library_id`
- index on `file_object_id`

### Notes

- This table represents managed membership, not raw filesystem presence.
- A row here without a corresponding healthy placement is a broken state.
- `status` is a narrow enum-like domain defined above.

## 8. `library_placements`

Derived intended and actual path state for library items.

### Columns

- `id` integer primary key
- `library_item_id` integer not null references `library_items(id)`
- `library_id` integer not null references `libraries(id)`
- `intended_relative_path` text not null
- `actual_relative_path` text
- `placement_status` text not null
- `last_verified_at` text
- `error_text` text
- `created_at` text not null
- `updated_at` text not null

### Likely Constraints

- unique on `library_item_id`
- unique on `(library_id, intended_relative_path)`
- index on `placement_status`
- index on `(library_id, placement_status)`

### Notes

- `library_id` is intentionally denormalized into this table to enforce the
  library-scoped path-claim invariant directly.
- The minimum status set should cover `healthy`, `misplaced`, `missing`,
  `repair_needed`.
- `placement_status` is a narrow enum-like domain defined above.

## 9. `file_ops`

Durable record of filesystem effects and recovery points.

### Columns

- `id` integer primary key
- `run_id` integer not null references `runs(id)`
- `run_item_id` integer references `run_items(id)`
- `library_item_id` integer references `library_items(id)`
- `op_kind` text not null
- `src_path` text
- `dst_path` text
- `status` text not null
- `error_text` text
- `started_at` text not null
- `completed_at` text

### Likely Constraints

- index on `run_id`
- index on `run_item_id`
- index on `library_item_id`
- index on `(run_id, status)`

### Notes

- This is the durable audit and recovery surface for copy, move, unlink, and
  similar protected operations.
- `op_kind` and `status` are narrow enum-like domains defined above.

## Core Schema Invariants

- every run belongs to exactly one library
- every library item belongs to exactly one library
- every library item references exactly one file object
- every library placement belongs to exactly one library and one library item
- file identity is content-based through `file_objects`
- source identity is observational and path-based through `source_observations`
- intended paths are unique within a library
- duplicate disposition in ingest is library-scoped
- cross-library duplicate reporting is possible through shared file-object facts
- metadata snapshots belong to file objects, not to source paths or placements
- `md5` is the canonical identity hash in v1
- `blake2b-256` is stored as secondary full-hash evidence when available
- quick signatures are secondary evidence and never the primary identity key

## Important Query Shapes

The schema should support these efficiently:

- all items in one library by intended path
- all items in one library by capture date
- all file objects by hash
- all library memberships for one file object
- all observations for one file object
- all run items for one run
- all broken placements for one library
- future duplicate report across libraries by shared file object or other facts

## Deferred Questions

The following are intentionally deferred rather than left ambiguous:

- whether `file_objects` should later split into sibling fact tables
- whether library config should later normalize selected policy fields
- whether a higher-level photo-asset concept is needed after the file-centric
  model is proven
- whether additional promoted metadata fields are justified by real query
  patterns
- whether a future `file_object_hashes` child table is justified for storing
  additional full-hash algorithms beyond `md5` and `blake2b-256`

## Immediate Next Step

The next design step after accepting this schema draft is:

1. define the OCaml domain types directly from these tables and invariants
2. decide which fields are mandatory for the first migration slice
3. write the migration matrix from the current Python/main database into this
   schema
