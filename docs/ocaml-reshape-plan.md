# OCaml Rewrite Reshape Plan

This is the umbrella roadmap for the `trove` rewrite.

It is intentionally short. The detailed design and migration decisions now live
in the more specific docs linked below.

## Start Here

If you are implementing from a fresh context, start with:

1. `docs/implementation-plan.md`
2. `docs/library-centric-domain-model.md`
3. `docs/target-schema.md`
4. `docs/migration-matrix.md`
5. `docs/migration-layer-api.md`

## Purpose

The rewrite should stop centering the workflow on the old overloaded `files`
table shape and move to a library-first model with:

- explicit source observations
- explicit content-identified file objects
- explicit library membership
- explicit run-scoped decisions
- explicit migration from the Python/main schema without data loss

## Current Position

The important conclusions are already established:

- the Go worker boundary is good and has been extracted to `grove`
- the active design center is now the OCaml application model and schema
- preserving expensive completed work from the Python/main DB is mandatory
- the rewrite should be implemented against the new target model, not by
  stabilizing the old OCaml transliteration first

## Active Design Docs

### Domain and schema

- `docs/library-centric-domain-model.md`
- `docs/target-schema.md`

### Migration

- `docs/migration-matrix.md`
- `docs/migration-layer-api.md`

### Worker boundary

- `docs/worker-protocol-contract.md`
- `docs/worker-repo-extraction-plan.md`

## What To Preserve

Preserve and build from these parts of the current rewrite:

- Go worker process boundary and protocol
- `Worker_client`
- DB open/create/migration shell
- config modules
- test harness and module layout discipline
- pure helper logic that can be extracted into smaller modules

## What Not To Preserve As The Final Model

Do not keep these as the long-term shape:

- the `file_record`-centered domain model
- the `files` table as the primary workflow representation
- generic `Db.update_file` patch-style APIs
- broad global status-query reasoning
- `Pipeline` as one oversized workflow center

## Implementation Order

Do not improvise the order. The intended order is:

1. accept the target domain and schema docs
2. build the read-only migration layer against the Python/main schema
3. build the new target DB layer and migration report path
4. migrate real copied DB fixtures and inspect anomalies
5. only then start rewriting runtime OCaml workflows on top of the new model

The detailed execution order lives in `docs/implementation-plan.md`.
