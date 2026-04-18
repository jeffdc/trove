# Implementation Plan

This is the execution plan for the next implementation context.

If you are starting fresh, start here. Do not re-derive the architecture from
scratch and do not start by stabilizing the old OCaml workflow model.

## Goal

Implement the new library-centric OCaml model and a safe migration path from
the Python/main database into the target v1 schema.

## Read First

Read these in order before writing code:

1. `docs/library-centric-domain-model.md`
2. `docs/target-schema.md`
3. `docs/migration-matrix.md`
4. `docs/migration-layer-api.md`
5. `docs/worker-protocol-contract.md`

Use `docs/ocaml-reshape-plan.md` only as the short umbrella roadmap.

## Ground Rules

- do not mutate the source Python/main DB
- work only against copied DB fixtures
- do not spend time stabilizing the old OCaml `files`-table workflow
- do not weaken the new model to fit accidental old implementation details
- preserve expensive completed work whenever ownership is trustworthy
- report ambiguity explicitly instead of guessing through it

## Phase 1: Lock The Design Into Code Interfaces

### Objective

Create the type and module boundaries needed for migration and the new target
schema, without yet rewriting the full runtime workflows.

### Deliverables

- target OCaml domain types for:
  - `Library`
  - `Source_observation`
  - `File_object`
  - `Run`
  - `Run_item`
  - `Library_item`
  - `Library_placement`
  - `File_op`
- target DB API signatures for the new schema
- migration-only OCaml types for legacy rows and anomaly reporting

### Stop Condition

The codebase has explicit type definitions and module stubs that reflect the
new docs rather than the old `file_record` shape.

## Phase 2: Build The Read-Only Migration Layer

### Objective

Implement the source-side migration modules against the Python/main schema.

### Deliverables

- `Legacy_types`
- `Legacy_db`
- `Migration_types`
- `Migration_report`
- `Migrate_libraries`

### Order

1. implement legacy row types
2. implement read-only DB access to `libraries`, `entries`, `files`
3. implement anomaly and count reporting
4. implement library migration first

### Stop Condition

A copied source DB can be opened read-only and its libraries can be migrated
into a new target DB.

## Phase 3: Build The Target DB Layer

### Objective

Implement the new target schema and the minimum DB API needed by migration.

### Deliverables

- target schema creation and migration shell
- typed insert and lookup functions for:
  - `libraries`
  - `file_objects`
  - `library_items`
  - `library_placements`
  - `source_observations`
  - `run_items`
  - `file_ops`

### Important Constraint

Do not fall back to generic patch APIs as the primary interface.

### Stop Condition

The target DB can be created from scratch and written through typed operations.

## Phase 4: Implement The Entry And File Migration

### Objective

Move real source data into the new schema according to the migration matrix.

### Deliverables

- `Migrate_entries`
- `Migrate_files`
- `Migrate_reconcile`
- anomaly report output

### Required Behavior

- `entries` wins for durable library membership
- `files` supplies provenance and partial workflow evidence
- ambiguous cases are preserved and reported
- imported rows without matching entries are anomalies, not silently accepted

### Stop Condition

A copied real DB can be migrated into the new schema and produce a useful
anomaly report.

## Phase 5: Validate Against Real Fixtures

### Objective

Pressure-test the migration with copied real data before rewriting the runtime
workflows on top of the new schema.

### Deliverables

- one or more copied DB fixtures from `main`
- migration test runs
- counts and anomaly summaries reviewed by hand
- explicit notes on any schema or mapping adjustments required

### Stop Condition

The migration behavior is trustworthy enough that the new schema is no longer
only theoretical.

## Phase 6: Rewrite Runtime OCaml Workflows

### Objective

Port the active OCaml runtime onto the new schema and types.

### Rewrite Order

1. DB-facing domain adapters
2. run creation and source observation flow
3. file-object creation and metadata persistence
4. library admission and placement logic
5. resume and reconciliation logic
6. reporting and maintenance commands

### Important Constraint

Do not try to preserve the old `Pipeline` structure if it fights the new model.
Extract smaller modules that follow the new ownership boundaries.

## Immediate Task List

The next implementation context should start with these concrete tasks:

1. create OCaml modules and `.mli` files for the new target domain types
2. implement `Legacy_types`
3. implement `Legacy_db.open_readonly`, `schema_version`, `list_libraries`,
   `list_entries`, `list_files`
4. implement `Migration_types` and `Migration_report`
5. implement `Migrate_libraries`
6. add fixture tests for the read-only legacy DB layer

Do not jump ahead to runtime import/init rewrite before these are done.

## Success Checks

Before moving from one phase to the next, verify:

- the source DB is still untouched
- target schema invariants remain aligned with `docs/target-schema.md`
- anomaly reporting is explicit
- no implementation step has reintroduced path-as-identity semantics
- no implementation step has made `quick_signature` or secondary hashes part of
  primary identity

## When In Doubt

If a fresh context encounters ambiguity:

- trust `entries` over `files` for durable library membership
- trust `files` for provenance and partial workflow evidence
- preserve the row as legacy evidence if ownership is ambiguous
- update the anomaly report instead of inventing a hidden rule
