# Library-Centric Domain Model Draft

This document defines the target domain model for `trove` after the Go worker
extraction. It is the design anchor for the OCaml reshape.

See also:

- `docs/ocaml-reshape-plan.md`
- `docs/target-schema.md`
- `docs/worker-repo-extraction-plan.md`

## Purpose

The goal is to define the durable domain concepts that `trove` actually cares
about so the rewrite can stop centering the workflow on a single overloaded
`files` row.

The design has to satisfy all of the following:

- `library` is a primary domain object
- expensive completed work must be preserved across migration and future runs
- ingest and init workflows must be modeled explicitly
- the schema must support exact resume and recovery
- future reporting across libraries must remain possible

## Design Premise

`trove` is not centered on scans in the abstract. It is centered on managed
libraries.

That means the top-level questions are:

- which library are we operating on
- what policy does that library apply
- what source material was observed for that library
- what durable facts do we know about the observed files
- what did a specific run decide to do
- what is now a member of the managed library
- where is that member intended to live and where does it actually live

This differs from `reprise` in an important way. `reprise` is centered on
intake and canonical collection state first, with archive and library targets
downstream. `trove` starts from the concept of a managed library and should
model it as primary.

## Core Rule

Run-scoped does not mean discardable.

Some state is scoped to a run because that is the correct ownership boundary,
but that state may still represent many hours of expensive work and must be
preserved durably.

The important distinction is not durable versus disposable. The important
distinction is:

- durable content identity
- durable metadata snapshots
- durable run records
- durable library membership
- durable file-operation history
- policy decisions made in a particular run and library context

## Core Separation

The model should separate three things that the old schema blurred together:

- bytes
- path observations
- library membership

The right ownership model is:

- bytes are represented by a content-identified `file_object`
- where those bytes were seen is represented by `source_observation`
- a library managing those bytes is represented by `library_item`

This is the most important structural decision in the redesign.

## Primary Domain Objects

### Library

A `library` is the primary managed collection boundary.

It owns:

- identity: name, root path, timestamps
- policy: organization structure, naming, quarantine policy, file-type policy,
  exclusion patterns, copy or move semantics, metadata preservation options
- namespace: path claims and duplicate handling boundaries
- workflow context: every run happens against exactly one library

A library is not just a folder and not just a convenience grouping. It is the
unit of ownership for organization rules and managed membership.

### Source Root

A `source_root` is an input location used by a run.

Examples:

- an external import directory
- a camera dump
- a loose staging directory
- the library root itself for `init`

A source root exists to explain where observations came from. It is not the
same thing as library membership.

### Run

A `run` is one execution against a specific library.

Likely run modes:

- `import`
- `init`
- `verify`
- `rehash`
- `reconcile`

A run records:

- target library
- optional source root
- mode
- timestamps
- status and recovery state
- options that materially affect interpretation
- accounting and summaries

Runs are durable provenance. They explain what was attempted and what happened.

### Source Observation

A `source_observation` is a path-based observation of a file during a run.

It represents:

- where a file was seen
- when it was seen
- what basic filesystem properties were observed at that path

This is evidence. It is not long-term identity.

A source path is not useful as the durable identity anchor because the source
may be deleted after ingest. A source observation exists to preserve provenance,
not to define what a file is.

### File Object

A `file_object` is the durable identity anchor for concrete file bytes.

This should be content-based, not path-based.

In the current shape of `trove`, the natural identity anchor is the full hash of
the file bytes. If the bytes differ, it is a different file object. If the
bytes are the same, it is the same file object even if it has appeared at many
different paths.

For v1, this must mean one canonical full-hash algorithm for identity.

Allowing multiple full-hash algorithms at the identity layer would create an
ambiguity problem: the same bytes could produce two different identity digests
with no direct way to know they represent the same file object. So v1 should
not treat the identity hash algorithm as a free per-row choice.

For migration compatibility, the canonical identity hash in v1 should be `md5`.
That is not because `md5` is the ideal long-term answer. It is because the
existing database already embodies expensive work keyed around `md5`.

At the same time, v1 should start storing `blake2b-256` as a secondary full
hash on new ingest so the system can move away from `md5` later without waiting
until the dataset is even larger.

A file object owns:

- content identity
- one canonical identity hash (`md5` in v1)
- one secondary full hash (`blake2b-256`) for future migration
- one optional quick signature for acceleration only
- promoted queryable file properties
- durable extracted metadata
- a structured metadata snapshot from `exiftool`

This is where `metadata_json` belongs conceptually.

Metadata should be treated as extracted evidence about the file object. If the
bytes change, that is a new file object with a new metadata snapshot, not drift
on the old row.

The quick signature is not identity. It is only a fast comparison aid for
prefiltering or narrowing candidate matches before relying on the canonical
identity hash.

The secondary `blake2b-256` hash is different. It is a real full-content hash,
but it is not the canonical identity key in v1. It exists to accumulate future
upgrade data while preserving the current migration boundary.

### Run Item

A `run_item` is the participation of a source observation or file object in a
specific run.

It carries the run-context decisions and workflow state, such as:

- was this observation discovered in the run
- was it linked to a known file object
- was it planned for admission
- was it identified as a duplicate in the target library
- was it quarantined
- was it admitted
- did it fail

This is the right place for run-scoped decisions. It is not the right place for
global file identity or durable metadata ownership.

### Library Item

A `library_item` is durable managed membership of exactly one file object in a
particular library.

This is intentionally close to a managed file instance, not an abstract photo
asset detached from files.

The important invariant is:

- a library item always has a file object

If a library item no longer has a live on-disk file at its managed placement,
that is a broken state, not a normal representation.

This is the conceptual successor to the current notion of an entry, but it
should be modeled more explicitly as managed membership rather than as a side
effect of file-copy execution.

### Library Placement

A `library_placement` records the intended and actual path state for a library
item.

This separation matters because:

- path planning is not the same thing as library membership
- actual filesystem state may temporarily diverge from intended state
- repair and verification need to reason about drift explicitly

The minimum useful model is:

- intended relative path
- actual relative path
- placement status
- last verification state

### File Operation

A `file_op` records protected filesystem work.

Examples:

- copy
- move
- unlink
- mkdir
- quarantine move

These operations should be durable because they matter for recovery, audit, and
idempotence reasoning.

## Metadata Strategy

The system should store more than a few promoted EXIF fields.

For a large photo collection, repeatedly rescanning hundreds of thousands of
files to answer metadata queries is the wrong baseline. The database should own
a durable metadata snapshot for each file object.

Recommended approach:

- store the full extracted metadata payload in structured JSON
- promote a small set of heavily-used fields into dedicated columns
- index the promoted fields that matter for core workflows and reporting
- keep quick comparison signals separate from canonical identity semantics

Recommended hash approach:

- canonical identity hash in v1: `md5`
- secondary full hash in v1: `blake2b-256`
- quick comparison signal: non-identity `quick_signature`
- compute both full hashes in a single streaming pass when reading file bytes
  so remote files are not read twice

Good candidate promoted fields:

- full hash
- file size
- capture date
- camera model
- MIME or format info
- extraction timestamp
- extraction tool version if available

The JSON payload is there to preserve future query power and migration
flexibility. The promoted columns are there for fast indexed access to common
operations.

## Facts Versus Decisions

This is the most important separation in the model.

### Facts

Facts are evidence about file bytes or extracted metadata.

Examples:

- hash
- size
- capture date
- camera model
- metadata snapshot

Facts belong to the file object and may support future comparison across
libraries.

The important distinction is:

- canonical identity hash decides file-object identity
- secondary full hash supports future identity migration and integrity checks
- quick signature only helps find candidate comparisons cheaply

### Decisions

Decisions are made in a library and run context.

Examples:

- duplicate in target library
- quarantine due to policy
- admit to library
- reject for this run
- planned destination path for this library

Decisions may be durable, but they are still contextual. A file object can be a
duplicate for library A and still be admissible for library B.

## Cross-Library Duplicate Reporting

The main ingest path should remain library-scoped.

That means:

- duplicate handling during ingest is library-scoped
- path claims are library-scoped
- admission is library-scoped

But the schema must not block future reporting across libraries.

So the design constraint is:

- preserve enough global or cross-library comparable fact structure to support
  duplicate reports later without schema surgery

This implies:

- duplicate evidence may be global
- duplicate disposition during ingest is library-local
- future reports may compare shared file-object facts across libraries without
  changing ingest semantics

## Recommended Relationships

The high-level relationship model should look like this:

- one `library` has many `runs`
- one `library` has many `library_items`
- one `run` may reference one `source_root`
- one `run` has many `source_observations`
- one `run` has many `run_items`
- one `source_observation` may link to one `file_object`
- one `file_object` may have many source observations across runs
- one `file_object` may appear in many libraries through many library items
- one `run_item` may link to one admitted `library_item`
- one `library_item` has one current `library_placement`
- one `run_item` and one `library_item` may both have related `file_ops`

## Proposed Invariants

- every run belongs to exactly one library
- every library item belongs to exactly one library
- every library item references exactly one file object
- every admitted library item has provenance linking it back to at least one
  run item or source observation
- intended placement paths are unique within a library
- run-item disposition is interpreted in the context of one library and one run
- file-object facts are not owned solely by one library decision row
- the model must allow cross-library comparison from preserved file-object facts
- source paths are observations, not durable identity
- `md5` is the canonical identity hash in v1
- `blake2b-256` is stored as secondary full-hash evidence for future migration
- quick signatures are secondary evidence and never the primary identity key

## Immediate Consequences For The Rewrite

This model implies the rewrite should move away from:

- path-based file identity
- one giant file row that mixes facts and decisions
- entry creation as a side effect with little explicit provenance

And toward:

- content-based file identity
- explicit observation rows
- explicit run-item decision records
- explicit library membership rows
- placement derived from DB state rather than treated as identity

## Open Questions

- should file-object identity start with just full hash, or should it carry an
  internal stable ID plus hash-based uniqueness constraints
- if more full-hash algorithms beyond `md5` and `blake2b-256` are ever needed,
  they should live in a separate child table rather than redefining primary
  file-object identity
- how much metadata should be promoted into first-class columns in v1
- should extraction provenance such as `exiftool` version and extraction time be
  stored directly on file objects or in a small sibling table
- do we need a separate conceptual photo-asset layer later for RAW/JPEG/sidecar
  groupings, or can that wait until after the file-centric rewrite stabilizes

## Immediate Next Step

Use this document to derive:

- a concrete target schema
- exact OCaml domain types
- the migration matrix from the existing Python/main database into this model

The migration plan should be written only after the shape above is accepted or
revised enough that table ownership and meaning are stable.
