# Migration Layer API Draft

This document defines the first-pass OCaml API shape for migrating a Python/main
Trove database into the target v1 schema.

It is deliberately narrow. The goal is to make migration explicit, testable,
and read-only with respect to the source database.

See also:

- `docs/migration-matrix.md`
- `docs/target-schema.md`
- `docs/ocaml-reshape-plan.md`

## Design Goals

- source database is never mutated
- target database is created and written independently
- ambiguous source rows are reported, not silently guessed through
- migration logic is decomposed by domain responsibility rather than one giant
  script

## Conceptual Flow

1. open source DB in read-only mode
2. open or create target DB
3. migrate `libraries`
4. migrate `entries`
5. migrate `files`
6. reconcile links across migrated rows
7. emit anomaly report and migration summary

## Module Shape

Suggested OCaml modules:

- `Legacy_db`
  Read-only access to the Python/main schema.

- `Legacy_types`
  OCaml record types mirroring the current `libraries`, `entries`, and `files`
  rows.

- `Migration_types`
  Shared migration-only types such as anomaly categories, counters, and mapping
  references.

- `Migration_report`
  In-memory summary and machine-readable report writer.

- `Migrate_libraries`
  Moves legacy library rows into target `libraries`.

- `Migrate_entries`
  Builds `file_objects`, `library_items`, and `library_placements` from legacy
  `entries`.

- `Migrate_files`
  Builds `source_observations` and `run_items` from legacy `files`.

- `Migrate_reconcile`
  Resolves linkages between migrated rows where exact ownership depends on both
  `entries` and `files`.

- `Migrator`
  Thin orchestration layer.

## Read-Only Source API

`Legacy_db` should expose typed read functions only.

Suggested signatures:

```ocaml
type t

val open_readonly : path:string -> (t, string) result
val close : t -> unit

val schema_version : t -> (int, string) result

val list_libraries : t -> (Legacy_types.library list, string) result
val list_entries : t -> (Legacy_types.entry list, string) result
val list_files : t -> (Legacy_types.file_row list, string) result
```

If needed for memory control, the interface can later gain batched or cursor
style reads, but the first version should stay simple.

## Mapping State

Migration needs explicit lookup state so later phases can link rows without
guessing repeatedly.

Suggested structure:

```ocaml
type mapping_state = {
  library_ids_by_legacy_id : (int, int) Hashtbl.t;
  file_object_ids_by_md5 : (string, int) Hashtbl.t;
  library_item_ids_by_entry_id : (int, int) Hashtbl.t;
  source_observation_ids_by_file_id : (int, int) Hashtbl.t;
}
```

This is migration scaffolding, not permanent domain state.

## Anomaly Model

The migration layer should have first-class anomaly values, not ad hoc strings
scattered through the code.

Suggested type:

```ocaml
type anomaly_kind =
  | Imported_file_without_entry
  | Ambiguous_duplicate_kind
  | Missing_without_library_link
  | Entry_without_md5
  | Target_path_conflict
  | Inconsistent_md5_group
  | Unsupported_source_type
  | Legacy_completed_status

type anomaly = {
  kind : anomaly_kind;
  legacy_table : string;
  legacy_id : int option;
  detail : string;
}
```

## Report API

Suggested `Migration_report` surface:

```ocaml
type t

val create : source_db_path:string -> source_schema_version:int -> t
val add_anomaly : t -> Migration_types.anomaly -> unit
val incr : t -> counter:string -> unit
val add_count : t -> counter:string -> int -> unit
val write_json : t -> path:string -> (unit, string) result
```

The first version does not need a complicated reporting engine. It just needs a
stable machine-readable output.

## Library Migration API

Suggested `Migrate_libraries` surface:

```ocaml
val run :
  legacy:Legacy_db.t ->
  target:Db.t ->
  state:Migration_types.mapping_state ->
  report:Migration_report.t ->
  (unit, string) result
```

Responsibilities:

- read all legacy libraries
- write target libraries
- populate legacy-to-target library ID map

## Entry Migration API

Suggested `Migrate_entries` surface:

```ocaml
val run :
  legacy:Legacy_db.t ->
  target:Db.t ->
  state:Migration_types.mapping_state ->
  report:Migration_report.t ->
  (unit, string) result
```

Responsibilities:

- create or reuse `file_objects` from `entries.md5_hash`
- create `library_items`
- create `library_placements`
- preserve `original_path` where possible
- report entries with missing hashes as explicit anomalies or partial rows

## File Migration API

Suggested `Migrate_files` surface:

```ocaml
val run :
  legacy:Legacy_db.t ->
  target:Db.t ->
  state:Migration_types.mapping_state ->
  report:Migration_report.t ->
  (unit, string) result
```

Responsibilities:

- create `source_observations`
- attach to `file_objects` by `md5_hash` when possible
- create `run_items` from legacy status and planning fields
- preserve `error_message`, `target_path`, `discovered_at`, and `hashed_at`

## Reconciliation API

Suggested `Migrate_reconcile` surface:

```ocaml
val run :
  target:Db.t ->
  state:Migration_types.mapping_state ->
  report:Migration_report.t ->
  (unit, string) result
```

Responsibilities:

- resolve imported file rows against migrated library membership
- mark missing or broken library state when evidence supports it
- preserve unresolved ambiguity in the report instead of inventing certainty

## Top-Level Orchestrator

Suggested `Migrator` surface:

```ocaml
type options = {
  source_db_path : string;
  target_db_path : string;
  report_path : string;
}

val run : options -> (unit, string) result
```

The orchestrator should:

- open source DB read-only
- initialize target DB
- run each migration stage in order
- write report at the end

## Testing Strategy

The first migration implementation should be tested at three levels:

### Unit tests

- status mapping from legacy `files.status` to target `run_items`
- anomaly classification for known ambiguous cases
- `md5`-based file-object reuse

### Fixture tests

- small hand-built legacy DBs covering:
  - clean import case
  - missing-file case
  - duplicate ambiguity case
  - entry-without-md5 case

### End-to-end migration tests

- migrate a copied real-world DB fixture
- assert row counts, anomaly buckets, and key invariants in the target DB

## Immediate Next Step

Use this API draft to decide:

1. whether the first implementation should be batched or whole-database
2. what exact target `Db` functions must exist before migration coding starts
3. what sample legacy DB fixture should be copied from `main` for validation
