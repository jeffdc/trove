# Cross-Project Architecture Notes

## Purpose

Capture the current architectural conclusions across `trove`, `reprise`, and
the reusable filesystem worker effort.

These notes are meant to prevent two common mistakes:

- forcing the photo and music applications together above the wrong boundary
- leaving the reusable worker trapped inside one application repo

## Current Conclusion

`trove` and `reprise` are structurally similar, but they are not the same
application with different metadata.

The useful shared layer is the lower-level infrastructure for:

- scanning and observing files
- surviving unreliable NAS / SMB / network mounts
- hashing and verified file transfer
- resumable execution around risky filesystem effects
- materializing concrete outputs from application decisions

The application layer above that boundary diverges quickly.

`trove` is primarily a deterministic ingest and organization pipeline. `reprise`
is primarily an intake, identity, curation, and materialization system. They
share machinery, but they do not share one generic media-domain model.

## Three-Repo Model

The current best repository shape is:

1. `trove`
   Photo and video application logic, SQLite schema, planning rules, CLI, and
   reporting.
2. `reprise`
   Music application logic, SQLite schema, identity model, process/review
   orchestration, and target materialization rules.
3. `worker`
   Media-agnostic protected filesystem worker implemented in Go.

The reason for a separate worker repo is not just reuse. It is also boundary
enforcement. If the worker remains inside `trove`, it will tend to drift back
toward photo-specific assumptions over time.

## What Belongs In The Worker Repo

The worker repo should stay intentionally narrow.

It should contain:

- protocol and versioning
- process supervision and timeout isolation
- mount health checks
- generic filesystem operations
- integration tests for mount-loss and timeout behavior
- client compatibility tests where practical

It should expose generic operations such as:

- `check_mount`
- `path_exists`
- `stat_path`
- `walk_tree`
- `hash_path`
- `copy_and_hash`
- `move_file`
- `unlink_path`
- `mkdir_all`
- `remove_empty_dirs`

It should not contain:

- SQLite access
- photo or music metadata logic
- duplicate business rules
- library placement policy
- quarantine policy
- workflow-state transitions
- archive semantics

## Shared Vs Application-Specific Concerns

Shared concerns:

- process-isolated filesystem effects
- structured worker errors
- timeout and restart behavior
- verification-oriented copy and move primitives
- batch-friendly path and hashing operations

Application-specific concerns in `trove`:

- EXIF extraction strategy
- capture-date fallback rules
- camera-model normalization
- photo-specific quarantine and import rules
- path planning for organized photo libraries

Application-specific concerns in `reprise`:

- tag and codec interpretation
- work-unit formation
- identity assessment and MusicBrainz enrichment
- proposal and review flows
- canonical-item and target materialization semantics

## Isomorphism Boundary

The two tools are only close to isomorphic below the domain boundary.

Below the boundary:

- both deal with files, mounts, hashes, copies, moves, retries, and resumable
  execution

Above the boundary:

- `trove` decides where files belong in a deterministic organized library
- `reprise` decides what music an item is, whether it should be admitted, and
  how canonical assets should materialize into targets

That means the right move is shared infrastructure, not a shared application
core.

## Language Strategy

The worker should stay in Go.

For the application layer, OCaml is still an open question rather than a settled
cross-project direction.

The current working position is:

- do not move `reprise` to OCaml just for symmetry
- first prove that OCaml materially improves the upper-layer design in `trove`
- if it does, consider applying the same approach to `reprise`

The relevant test is not whether OCaml is elegant in isolation. The test is
whether it produces a clearer and safer workflow model than the current Python
design, especially around:

- explicit state transitions
- separation of durable facts from run-local state
- typed error handling across the worker boundary
- deterministic recovery after interruption or mount failure

If OCaml proves itself there, `reprise` may actually be the stronger long-term
candidate because its identity, review, and target state models are more subtle
than `trove`'s current pipeline.

## Practical Sequence

Recommended order of work:

1. Extract the Go worker into its own repo.
2. Keep `trove` and `reprise` as separate application repos.
3. Stabilize the worker protocol and ownership boundary.
4. Continue validating whether the `trove` OCaml layer is meaningfully better
   than the Python port it replaces.
5. Revisit `reprise` language choices only after that result is clear.

## Anti-Goals

Avoid these moves:

- creating a broad shared "media core" package too early
- sharing one DB schema across the apps
- forcing one generic workflow model across photos and music
- rewriting `reprise` into OCaml before the `trove` rewrite has earned that
  confidence
