# OCaml Rewrite Reshape Plan

See also: `docs/worker-repo-extraction-plan.md` for the staged plan to move the
Go worker into its own repository while keeping the application-layer reshape
separate from that packaging change.

## Purpose

This document captures the plan for getting the OCaml rewrite into a shape that
actually uses OCaml well for modeling Trove's workflow.

The immediate conclusion is:

- keep the useful infrastructure already built
- preserve the existing database and avoid losing expensive completed work
- migrate away from the current `files`-table-centered workflow model safely
- redesign the core domain, DB API, and pipeline structure around run-centric
  state

This is a reshape, not a full restart.

## Primary Constraint

The number one goal is data preservation.

More specifically:

- do not lose data already present in the existing database
- do not discard expensive completed work such as discovery, hashing, metadata
  extraction, or path planning if it can be preserved safely
- do not require users to rerun long and expensive scans unless there is no
  trustworthy way to preserve or reconcile the prior results

This constraint takes precedence over elegance of migration. If a more explicit
or slower migration path is what preserves data, that is the right trade.

## Current Assessment

The rewrite already has a few solid pieces:

- the Go worker boundary is a good fit
- the OCaml worker client is pragmatic and mostly well-contained
- config handling and migration scaffolding are worth preserving
- `.mli` files already impose some module discipline
- several pure helpers are useful and testable

But the core workflow model is still mostly a typed transliteration of the
Python design:

- `Domain.file_record` is still the center of the workflow
- the `files` table still mixes durable facts and transient per-run state
- `Db.update_file` is still a generic patch API instead of a typed transition
- `Pipeline` is too broad and mixes unrelated concerns
- `Init`, `Import`, `Resume`, and `Complete` still reason from status buckets or
  file-like rows rather than from an explicit run model

That means the rewrite is not yet getting the main benefit OCaml should provide:
making illegal states difficult to represent and making workflow transitions
explicit and understandable.

## Guiding Decisions

### Keep

Keep and build from these parts:

- Go worker process boundary and protocol
- `Worker_client`
- DB open/create/migration shell
- config modules
- test harness and module layout discipline
- pure helper logic that can be extracted into smaller modules

### Migrate and retire safely

Do not keep these as the long-term model, but also do not casually abandon
their data:

- the current `file_record`-centered domain model
- the `files` table as the primary workflow representation
- `Db.update_file` style generic row patching
- global status query patterns for resume/complete
- the current broad `Pipeline` module as the center of workflow modeling

The plan is to:

- stop designing new behavior around them
- extract and preserve trustworthy information from them
- migrate current rows into the new run-centric structures where ownership and
  meaning can be established
- preserve or rename legacy state rather than dropping it blindly

### Replace

Replace the core workflow model with a run-centric one:

- `runs`
- `run_items`
- `file_facts`
- `file_ops`

The objective is to model durable facts separately from run-local workflow
state and to make recovery deterministic.

## Design Goals

- preserve the existing database without silent data loss
- preserve expensive work such as discovery, hashing, metadata extraction, and
  path planning across migration and future runs
- make resume exact and run-scoped
- make timeout and kill recovery explicit
- encode workflow transitions in the type system and DB API
- keep the worker generic and stateless
- make the module layout readable enough that the responsibility of a file is
  obvious from its name

## Phase 1: Inventory and Migration Strategy

Before redesigning behavior, inventory the current schema and decide how to
preserve every class of existing state.

### Deliverables

- a catalog of current durable versus transient information in `files`
- a migration matrix that says, for each current column and status:
  - migrate into `runs`
  - migrate into `run_items`
  - migrate into `file_facts`
  - migrate into `file_ops`
  - preserve as legacy only
- explicit criteria for when an old row is trustworthy enough to import versus
  when it must remain legacy state

### Decisions to lock down

- what old `files` data is expensive and trustworthy enough to preserve directly
- what old `files` data is ambiguous and must be surfaced as legacy or salvage
- whether current rows should be migrated in place, copied forward, or renamed
  and preserved as a legacy table
- what minimum reconciliation logic is needed so migration does not force
  expensive re-scans

### Expected result

The team should know exactly how current database contents will be preserved,
not just what the future model should look like.

## Phase 2: Architectural Reset

Write down the target model before changing implementation.

### Deliverables

- a short design note that translates the run-centric plan into OCaml terms
- a target schema for `runs`, `run_items`, `file_facts`, and `file_ops`
- a first-pass list of exact domain types and transitions

### Decisions to lock down

- what belongs in durable facts versus run-local state
- what statuses are lifecycle statuses versus terminal dispositions
- what recovery outcomes exist after interruption
- what the minimum typed API surface should be for the DB layer

### Expected result

The team should be able to explain the workflow in terms of domain types and
transitions, not in terms of ad hoc DB rows.

## Phase 3: Replace the Domain Layer

Rewrite the domain model so that workflow types describe the process directly.

### New primary concepts

- `run`
- `run_item`
- `file_fact`
- `file_op`
- `run_mode`
- `run_status`
- `item_action`
- `item_disposition`
- `recovery_outcome`

### Principles

- avoid one giant record with many optional fields
- use distinct types for distinct phases where possible
- do not represent precision in variants that the storage layer cannot preserve
- keep `library` and `entry` as durable canonical concepts

### Expected result

The central domain type should no longer be a direct mirror of the old `files`
row shape.

## Phase 4: Replace the DB API

The DB layer should expose typed operations, not generic field patching.

### Replace APIs like

- `update_file : (string * string option) list -> unit`
- global `query_files_by_status`

### With typed operations like

- `create_run`
- `mark_run_active`
- `mark_run_interrupted`
- `insert_run_items`
- `attach_file_fact`
- `mark_item_planned`
- `mark_item_duplicate`
- `mark_item_quarantined`
- `start_file_op`
- `complete_file_op`
- `mark_item_imported`
- `mark_item_failed`
- `list_run_items`
- `load_resumable_run`

### Principles

- query by `run_id` by default
- encode state transitions through function names
- preserve legacy data until migration and reconciliation are proven safe

### Expected result

The DB interface should make it hard to write code that accidentally performs
 cross-run inference.

## Phase 5: Break Up the Modules

The current `Pipeline` module is too broad. Split it by responsibility.

### Extract pure modules

- `Filename_normalize`
- `Target_path`
- `Path_claims`
- `Source_observation`

### Extract workflow modules

- `Run_discovery`
- `Run_facts`
- `Run_planning`
- `Run_execute`
- `Run_reconcile`

### Keep orchestration thin

After extraction, `Pipeline` should either disappear or become a small
orchestration layer that wires together smaller modules.

### Expected result

A reader should be able to guess what a module owns from the file name alone.

## Phase 6: Rebuild Add / Init / Resume / Complete Around Runs

Rebuild the user-facing workflows on top of explicit runs.

### `add`

- create or resume a run for `(library_id, mode=add, source_root)`
- discover source files into `run_items`
- attach reusable facts
- compute missing facts
- plan actions
- execute actions
- complete the run when all items are terminal

### `init`

- same shape as `add`, but with `mode=init`
- source root is the library root

### `resume`

- resume a concrete run, not a guessed set of rows

### `complete`

- inspect one run's items only
- stop inferring completion from global transient rows

### Expected result

Resume and completion become exact and deterministic instead of heuristic.

## Phase 7: Add Reconciliation and Recovery

Recovery should be driven by journaled intent plus observed filesystem state.

### Reconciliation inputs

- `run_items`
- `file_ops`
- filesystem observations
- `entries`

### Reconciliation questions

- does source still exist?
- does destination exist?
- if destination exists, does content match expectation?
- was the final `entry` already created?

### Recovery outcomes

- imported
- planned
- missing
- failed
- unknown and surfaced explicitly

### Expected result

Timeouts and worker kills no longer force guessing from half-updated rows.

## Phase 8: Legacy Handling and Retirement

Do not silently reinterpret the old `files` table as if it were trustworthy
workflow state.

### Strategy

- preserve `libraries` and `entries`
- migrate new schema in alongside old tables first
- migrate trustworthy current `files` data forward into new structures
- salvage expensive reusable facts wherever they can be trusted
- avoid guessing ownership in ambiguous cases
- rename or retain old tables as legacy only after migration is complete and
  verified
- do not drop old state until the new system can account for it safely

### Expected result

Legacy data remains available for recovery, but it does not control the new
architecture.

## What To Keep vs Rewrite

### Keep largely intact

- worker protocol design
- `Worker_client`
- DB connection/migration shell
- config modules
- tests for worker behavior
- pure helpers after extraction into focused modules

### Rewrite heavily

- `Domain`
- DB workflow API
- workflow orchestration around `files`
- current `Import`, `Init`, `Resume`, and `Complete` logic
- broad `Pipeline` structure

## Good First Three Tasks

1. Inventory existing `files` rows and classify what must be preserved, what can
   be migrated directly, and what requires explicit salvage or reconciliation.
2. Write the run-centric schema and domain sketch in detail, with a migration
   mapping from current state into the new model.
3. Redesign `Domain` and `Db.mli` together before touching CLI behavior.

## Definition of "In Shape"

The rewrite is in shape when all of the following are true:

- the workflow is explainable in terms of types rather than status strings
- resume is run-scoped, not heuristic
- DB writes happen through typed transition functions
- module boundaries are small and obvious
- timeout recovery is explicit and deterministic
- adding a new phase does not require overloading one catch-all record with more
  optional fields
- current users do not lose prior expensive pipeline work just because the
  runtime model changed

## Summary

This rewrite should not be abandoned, but it should stop growing around the
current `files`-centered model.

The correct move is:

- preserve the useful infrastructure
- preserve current database contents and expensive completed work
- redesign the core domain and state model now
- rebuild the workflow around runs and explicit recovery

That is the point where the OCaml rewrite will start compounding rather than
carrying the legacy Python structure forward.
