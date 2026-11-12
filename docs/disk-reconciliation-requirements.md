# Disk Reconciliation Requirements

This document captures the recovery and reconciliation requirements for the new
`trove` replacement tool in light of observed divergence between the Python
database and the actual library tree on disk.

The immediate trigger for this document is that Python-side duplicate cleanup
was successful, but verification against a real library showed substantial
drift:

- durable `entries` missing from disk
- large numbers of real photo files on disk with no matching `entries`
- evidence consistent with prior interrupted or unreliable runs against NAS
  storage

That changes the migration posture.

For some libraries, the old Python database can no longer be treated as the
sole source of truth. The replacement tool must be able to reconcile from disk
reality, not just import database state.

## Goal

The new tool must be able to recover a correct durable library model from a
combination of:

- the old Python database
- the actual on-disk library tree
- deterministic reconciliation rules

It must do this safely on large libraries stored on unreliable NAS or mounted
volumes.

## Core Conclusion

Database-only migration is not sufficient.

The replacement tool must support a disk reconciliation workflow that can:

- import whatever useful durable facts exist in the old DB
- scan the actual library tree on disk
- identify files present on disk but absent from imported durable records
- identify DB records whose managed files are absent from disk
- reconcile those mismatches into a new durable model without relying on Python
  run-state semantics

## Problem Statement

The Python tool mixes durable facts and run-local state imperfectly, and its
behavior on NAS-backed libraries has proven unreliable enough that some
libraries now contain significant DB/disk drift.

Observed failure modes include:

- files on disk with no matching durable `entries`
- `entries` pointing at files no longer present on disk
- stale transient `files` rows reflecting interrupted historical runs
- likely partial or inconsistent outcomes after mount instability

This means the old DB is still useful, but it is not always authoritative.

## Source Authority Rules

The new system should treat old Python data sources with explicit precedence.

### Durable Facts From The Old DB

Useful imported facts from the Python DB may include:

- library identity and location
- known managed relative paths
- prior `md5_hash` values when trustworthy
- capture date and camera metadata
- original-path provenance where present

These are inputs to reconciliation, not unquestioned truth.

### Disk Reality

For file existence, file content, and actual managed tree contents, the live
library on disk is authoritative over the old DB.

If the DB says a managed file exists but the file is not present on disk, the
new tool must treat that as a reconciliation problem, not as a durable fact to
carry forward unchanged.

If a real media file exists on disk under the library tree and no imported DB
record claims it, the new tool must be able to surface and recover it.

### Python Transient State

The Python `files` table and similar run-local artifacts should not be treated
as authoritative migration input.

They may be useful for diagnostics, but they must not drive the durable model
of the replacement tool.

## Required Capabilities

### 1. Import Legacy Durable State

The new tool must be able to ingest the durable subset of the Python DB,
especially:

- `libraries`
- `entries`

It must not require the old transient `files` table to be clean or meaningful.

### 2. Scan Existing Library Trees Safely

The new tool must be able to scan a live library tree in place without copying
it.

Requirements:

- handle libraries large enough that full copies are impractical
- operate safely on NAS and mounted volumes
- provide visible progress during long scans
- survive transient read failures and report them explicitly
- avoid assuming the scan can be completed quickly or in one uninterrupted
  burst

### 3. Detect Disk/DB Drift

After importing old DB state and scanning disk, the new tool must detect at
least these mismatch classes:

- imported record whose managed file is missing from disk
- managed media file on disk with no imported durable record
- imported record whose file exists but whose size or hash disagrees with disk
- same-library exact duplicate content after reconciliation inputs are merged

### 4. Recover Orphaned Managed Files

This is the most important missing capability.

The new tool must be able to take a file that already exists inside the managed
library tree and create or reconstruct the durable record for it without
re-copying or re-moving the file.

Requirements:

- create a durable record from the existing on-disk managed path
- hash the file if needed
- recover metadata if needed
- infer or confirm library ownership from location
- preserve deterministic relative-path identity
- avoid creating duplicate records when the file is already represented

This is effectively an index-or-reconcile path for already-materialized library
content.

### 5. Separate Discovery From Destructive Action

Reconciliation must support explicit phases:

- analyze
- review
- apply

Analysis should produce structured reports of:

- missing managed records
- orphaned on-disk files
- duplicate-content conflicts
- proposed recoveries
- unresolved ambiguities

Apply mode should not be the first time a user sees these decisions.

### 6. Preserve Non-Destructive Recovery

The replacement tool must not require immediate file deletion to reconcile the
library model.

It should be able to:

- register orphaned managed files into durable state
- mark missing imported records as unresolved, stale, or removed
- output deletion candidates separately when needed

Direct file deletion should remain an explicit later step.

### 7. Reconcile Incrementally

Reconciliation must be resumable and incremental.

Large libraries and unreliable mounts mean the tool cannot assume:

- one uninterrupted full scan
- one uninterrupted full repair pass
- stable availability of all paths at all times

The tool should support checkpointed progress and deterministic resume.

### 8. Distinguish Managed Media From Noise

When scanning for orphaned content, the new tool must distinguish between:

- managed media files that should become durable records
- sidecars or support files
- generated reports
- unrelated clutter under the library root

Orphan detection must not collapse everything under the root into one undifferentiated bucket.

The tool should either:

- filter by configured supported media types first
- or classify findings by file category before presenting reconciliation
  decisions

### 9. Support Reviewable Exports

The tool must support exporting reconciliation findings in reviewable forms,
such as:

- newline-delimited path lists
- structured JSON reports
- summary counts by mismatch class
- samples or full lists of orphaned and missing managed paths

Large mismatch sets cannot be handled from summary counts alone.

### 10. Produce Durable Provenance

When the new tool reconstructs a record from disk rather than importing it
directly from the old DB, it should record that provenance explicitly.

Examples:

- imported from legacy DB
- recovered from existing managed path during reconciliation
- reconstructed from disk metadata and hash

This is important for later auditability and trust.

## Required Workflow

The replacement tool should support a concrete workflow like this:

1. Import durable legacy records from the Python DB.
2. Scan the live library tree.
3. Build a drift report:
   - records missing from disk
   - orphaned managed media files on disk
   - duplicate-content conflicts
   - metadata or hash mismatches
4. Let the user review the report.
5. Apply selected recoveries:
   - register orphaned managed files
   - mark or remove stale imported records
   - resolve duplicate conflicts deterministically
6. Re-run verification against the new durable model.

This workflow must be usable without ever mutating the original file tree until
the user explicitly chooses a destructive action.

## Recovery Rules

### Missing Imported Record On Disk

If a durable imported record refers to a managed path that no longer exists on
disk, the new tool must not silently preserve it as healthy.

The system should support explicit states such as:

- missing
- stale
- removed by reconciliation
- unresolved pending review

### Orphaned Managed File On Disk

If a real managed media file exists on disk under the library tree and no
durable record claims it, the default bias should be toward recovery rather
than deletion.

The tool should propose turning that file into a durable record unless another
conflict prevents it.

### Duplicate Content During Recovery

If recovering an orphaned managed file would create same-library duplicate
content, the tool must surface that explicitly and apply deterministic conflict
rules.

It must not silently register duplicate durable rows.

## Operational Constraints

The design must assume:

- library trees may be far too large to duplicate for rehearsal
- the user may need to work directly against the live library tree
- DB backups are practical even when full library copies are not
- NAS and mounted storage may become slow, flaky, or temporarily unavailable

This means the tool must support safe analysis and reconciliation against live
storage without assuming that a full shadow copy exists.

## Non-Goals

This document does not require:

- immediate cleanup of all Python-era drift inside the old tool
- full trust in historical Python run-state
- destructive cleanup as part of first-pass reconciliation
- fuzzy duplicate detection as a prerequisite for migration

## Acceptance Criteria

The replacement tool is not ready for migration on drifted libraries unless it
can do all of the following:

- import durable legacy DB state without depending on transient Python
  run-state
- scan the live library tree with visible progress
- report missing imported records and orphaned on-disk media separately
- recover orphaned managed files into durable records without re-copying them
- handle duplicate-content conflicts deterministically during recovery
- run incrementally and resume after interruption
- produce reviewable reports before applying changes
- verify that the reconciled durable model matches disk reality closely enough
  to trust migration outcomes

## Immediate Implication For Project Priorities

For libraries that already show significant Python-era DB/disk drift, further
cleanup in Python should not be the primary path forward.

The highest-value next step is to ensure the new Go or OCaml-based tool treats
disk reconciliation as a first-class recovery workflow rather than an optional
follow-up feature after migration.
