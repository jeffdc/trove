# Operationalization Plan

This document defines the concrete next plan for moving the OCaml rewrite from
"migration prototype" to "safe enough to replace Python for normal use."

It intentionally narrows scope.

The goal is not to finish every maintenance workflow before launch. The goal is
to get off the Python application as quickly as possible while preserving the
new target-schema direction.

## Current Position

The project is past the design-only stage.

What is already true:

- the target library-centric model is documented
- the target schema is implemented in OCaml
- the legacy read-only migration layer exists
- `migrate-db` runs successfully against a copied real pre-migration DB
- the latest migration run completed with:
  - zero anomalies
  - zero warnings
  - duplicate cleanup reflected cleanly in the target model
  - remaining broken imported state represented explicitly as `missing`

What is not yet true:

- the main OCaml runtime still operates on the old legacy-style schema
- normal commands such as `add`, `init`, `status`, `verify`, and `hash` are not
  yet implemented against `Target_db`
- the migrated target DB is not yet the DB that the everyday CLI uses

That means the migration path is in good shape, but the runtime replacement is
not yet complete.

## Test Entry Point

For rewrite-worktree validation, use:

```bash
make test-ocaml
```

Do not treat bare `dune test` as the canonical project test command.

The full OCaml suite depends on a built `grove` worker binary and the correct
`GROVE_WORKER_PATH` environment. The `Makefile` handles that wiring.

## Strategic Decision

Do not spend more time cleaning up Python-side drift unless migration reveals a
new hard blocker.

The Python-side work that mattered most for migration has already been done:

- missing hashes backfilled
- same-library exact duplicates removed

The next step is to finish the minimum OCaml runtime slice needed to stop using
Python for normal ingest.

Maintenance workflows such as bulk orphan adoption, missing-file cleanup, and
full library reconciliation can follow after operational cutover.

## Primary Goal

Make the OCaml application safe to use as the primary tool for normal
operations on migrated data.

In practical terms, that means:

- the app opens and uses the target schema, not the legacy schema
- the app can inspect migrated library state
- the app can admit new material into a library safely
- the app handles path conflicts safely and deterministically
- the app can report broken imported state without blocking normal use

## Non-Goals For This Slice

Do not block operationalization on these:

- automatic adoption of all orphaned files already present on disk
- full reconcile/apply workflow for every drift category
- bulk cleanup of all missing files
- migration of every possible maintenance command before first real ingest
- perfect parity with all Python reporting commands

These are important, but they are not the shortest path off Python.

## Hard Requirements Before Cutover

The OCaml app is ready to replace Python only when all of the following are
true:

- it can open the migrated target DB directly
- it can list libraries and inspect target-schema library state
- it can perform safe import into a target-schema library
- it can avoid unsafe path collisions with files already on disk
- it can expose broken imported state clearly enough that it does not surprise
  the operator
- the worker-backed file operations needed for import actually run in the OCaml
  path

## Minimal Operational Surface

The first operational target should be a deliberately narrow command set.

### Required First Commands

- `list`
  against the target schema
- `status`
  against the target schema, including counts for:
  - healthy placements
  - missing placements
  - repair-needed placements
- `verify`
  against the target schema
- `add`
  against the target schema for normal import workflow

### Optional For The First Cut

- `init`
  useful, but not required before the first operational cut if normal import is
  the immediate need
- `hash`
  as a standalone maintenance command in the new schema
- `duplicates`
  as a dedicated reporting command
- `relocate`
  if library-location changes are not immediately needed

## Core Implementation Direction

The immediate priority is not "add more migration logic."

The immediate priority is:

1. keep `migrate-db` as the one-way entry into the target schema
2. build a target-runtime CLI that talks to `Target_db` and `Target_domain`
3. stop routing normal operations through the old `Db` / `Domain` stack

This means the current legacy-style runtime in `ocaml/lib/db.ml`,
`ocaml/lib/domain.ml`, and the corresponding command paths in `ocaml/bin/main.ml`
should be treated as temporary scaffolding, not the base for future work.

## Execution Phases

### Phase 0: Lock Migration Confidence

Objective:

- treat the successful migration of the cleaned pre-migration DB as the current
  baseline

Tasks:

- keep the successful migration output and JSON report as reference fixtures
- rerun migration when source cleanup changes materially
- add one or two explicit target-schema invariant tests derived from the real
  migrated DB shape

Stop condition:

- the team trusts that the cleaned legacy DB migrates into the target schema
  without anomaly explosions

### Phase 1: Build Read-Only Target Runtime

Objective:

- make the OCaml CLI able to inspect the migrated target DB directly

Tasks:

- add a top-level target DB open path for the runtime
- implement target-schema `list`
- implement target-schema `status`
- implement target-schema `verify`

Required behavior:

- `list` shows libraries from `Target_db`
- `status` summarizes:
  - library items
  - healthy placements
  - missing placements
  - repair-needed placements
- `verify` checks:
  - intended vs actual path state
  - existence of managed placements on disk
  - optionally hash mismatch later

Stop condition:

- the OCaml app can be pointed at a migrated DB and used to inspect real
  library health without touching the legacy schema

### Phase 2: Build Target-Schema Import

Objective:

- support safe new ingest into the migrated target schema

Tasks:

- design the minimal target-runtime import path around:
  - source root
  - run
  - source observations
  - file objects
  - run items
  - library admission
  - library placements
- implement worker-backed file copy/move flow against target tables
- implement deterministic path-conflict resolution
- ensure path planning does not assume the DB is the only path-claim source

Required behavior:

- importing a new source creates target-schema run records
- admitted content produces:
  - `file_objects`
  - `library_items`
  - `library_placements`
  - `file_ops`
- duplicate-in-library decisions are enforced through target-schema identity and
  membership constraints
- if a computed destination path is already occupied on disk unexpectedly, the
  tool handles it safely and explicitly rather than failing silently or
  overwriting blindly

Stop condition:

- one new source can be ingested safely into a migrated library without using
  Python

### Phase 3: Operational Cutover

Objective:

- stop doing normal ingest with Python

Tasks:

- migrate the real production DB into target schema
- validate the migrated target DB using the new read-only commands
- run a controlled first real ingest with the target-schema `add`
- keep Python available only as fallback during the first cutover window

Stop condition:

- the operator can perform normal ingest and inspection in OCaml without
  needing Python

### Phase 4: Maintenance Workflows

Objective:

- address drift and repair after cutover, not before it

Tasks:

- orphaned managed-file adoption
- missing-file maintenance commands
- broader reconcile/report/apply workflows
- bulk repair and cleanup tools

This phase is intentionally after operational cutover.

## Immediate Task List

The next implementation context should do these in order:

1. add a distinct target-runtime DB open path and CLI routing for migrated DBs
2. implement target-schema `list`
3. implement target-schema `status`
4. implement target-schema `verify`
5. add tests for read-only target-runtime inspection on a migrated fixture DB
6. implement the minimal target-schema import/admission path
7. add an end-to-end test that migrates a fixture DB and performs one new
   successful import into the target schema

## Design Constraints

### Keep Unexpected-State Handling In Core Runtime

Unexpected filesystem state is not just a migration concern.

The target runtime must handle safely:

- computed destination path already occupied
- managed file missing from expected path
- imported target DB containing broken placements
- worker-reported mount or I/O failures mid-run

This should be modeled as core application behavior, not as migration-only
special casing.

### Do Not Overfit To Rare Multi-User Scenarios

The actual operator model here is narrow:

- one user
- one machine
- one database
- one set of library trees

The implementation should absolutely be safe and explicit, but it should not
block operational progress on hypothetical collaboration scenarios that are not
part of real use.

### Preserve Broken State Explicitly

If migrated state is broken, represent that explicitly in target tables.

Do not require the runtime to "clean everything first" before it can operate.

Broken imported placements should be visible and tolerable during normal use as
long as new ingest remains safe.

## Readiness Check

Before declaring the OCaml app ready to replace Python, verify:

- a real copied production DB migrates successfully into target schema
- the target-runtime CLI inspects that DB correctly
- the target-runtime `add` command succeeds on a real source
- the resulting target DB remains internally consistent
- no normal ingest task requires falling back to the legacy Python app

If those checks pass, cut over. Maintenance and reconciliation can continue
afterward inside the new system.
