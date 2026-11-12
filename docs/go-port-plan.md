# Go Port Plan

## Goal

Evaluate and execute a staged port of Trove from Python to Go, with emphasis on:

- reliability on flaky NAS and network-mounted volumes
- bounded memory usage for 100k+ file libraries
- resumable long-running operations
- simpler distribution as a single CLI binary

This is not a "rewrite everything at once" plan. The safest path is to stabilize behavior, define invariants, then replace subsystems incrementally.

## Why Consider Go

Go is a good fit for Trove because the tool is no longer a small script-style CLI. It behaves more like a systems utility:

- large recursive filesystem walks
- long-running batch processing
- persistent SQLite state
- careful crash recovery and resume behavior
- interaction with unreliable external storage

Expected benefits:

- lower steady-state memory usage
- better concurrency primitives for bounded worker pools
- easier shipping and invocation via a single binary
- cleaner subprocess supervision for isolating risky file operations

Limits:

- Go will not automatically solve dead SMB/NAS kernel I/O hangs
- a rewrite without architectural cleanup will just recreate the same failure modes faster
- EXIF/metadata extraction still needs a robust strategy, whether via `exiftool`, Go-native parsers, or both

## Non-Goals

- no full rewrite before behavior is specified and tested
- no schema churn unless clearly justified
- no loss of resume/recovery behavior during migration
- no first version that is feature-richer but less trustworthy

## Guiding Principles

- preserve the current user model: named libraries, resumable runs, deterministic organization
- move from all-at-once planning toward streaming or chunked execution
- isolate risky filesystem operations behind a narrow interface
- treat the SQLite database as the source of truth for workflow state
- prefer compatibility layers over disruptive migrations early on

## Recommended Strategy

Use a staged migration with a compatibility period.

### Phase 0: Freeze Semantics

Before porting, document the current intended behavior in enough detail that a Go implementation can be validated against it.

Capture:

- library model and config model
- file-state lifecycle in `files`
- entry semantics in `entries`
- duplicate handling
- orphan recovery behavior
- path conflict resolution
- quarantine rules
- interruption and resume semantics
- expected behavior on mount loss, timeouts, missing files, and partial moves

Deliverables:

- behavior spec for add/init/import/verify/status
- representative fixture datasets
- golden-output test cases where practical

### Phase 1: Stabilize the Python Design

Do not port unstable architecture.

First harden the current design around the biggest operational risks:

- remove full-library in-memory planning where possible
- switch large operations to chunked or streaming execution
- reduce repeated DB scans over 100k+ rows
- define a single protected file-ops layer for dangerous mount interactions
- make timeout behavior consistent across discovery, hashing, move/copy, and cleanup

The value here is twofold:

- the Python tool becomes safer immediately
- the Go design becomes clearer because the boundaries are explicit

### Phase 2: Define the Go Architecture

Design the Go implementation around a few explicit subsystems.

Suggested package layout:

- `cmd/trove`
  CLI entrypoint
- `internal/config`
  library config model and serialization
- `internal/db`
  SQLite access, migrations, queries, transactional operations
- `internal/discovery`
  directory walking, filtering, incremental detection
- `internal/hash`
  file hashing and verification
- `internal/meta`
  metadata extraction abstraction
- `internal/plan`
  import/init decision logic
- `internal/fileops`
  isolated filesystem operations with timeout/process supervision
- `internal/runstate`
  resumable pipeline orchestration
- `internal/report`
  user-facing summaries and diagnostics

Important architectural choice:

- Do not let business logic call raw filesystem operations directly.

Instead, define a narrow interface for:

- stat
- exists
- scandir / directory enumeration
- rename
- copy
- unlink
- rmdir
- hash

That interface should be the only place where timeout isolation and mount protection live.

### Phase 3: Decide Metadata Strategy

Metadata extraction is a key fork in the road.

Options:

1. Keep `exiftool` as an external dependency.
2. Use Go-native libraries for common formats.
3. Use a hybrid:
   Go-native fast path for common photo formats, `exiftool` fallback for difficult formats.

Recommended starting point:

- retain `exiftool` initially for compatibility and correctness
- wrap it behind a Go interface
- revisit native extraction later only if startup, portability, or throughput justify it

## Data Model Plan

Keep SQLite and the current schema concepts unless a specific bottleneck forces change.

Core tables:

- `libraries`
- `entries`
- `files`
- `schema_version`

Porting rule:

- the Go implementation should open and operate on the same DB schema wherever possible

This reduces migration risk and allows:

- side-by-side validation
- rollback to Python if needed
- focused benchmarking on implementation differences rather than schema changes

Potential later improvements:

- more targeted indexes for high-volume resume/classify paths
- batched updates
- query patterns that avoid full-row materialization where not needed

## Execution Model

The Go version should avoid building giant in-memory plans unless strictly necessary.

Preferred pattern:

1. discover files in chunks
2. persist chunk state
3. hash chunk
4. extract metadata for chunk
5. classify chunk
6. execute chunk
7. checkpoint progress

Benefits:

- bounded memory use
- less work lost on interruption
- easier visibility into progress
- more natural retry behavior

For initialization of very large libraries, consider:

- iterating file records in ordered batches
- maintaining claimed target paths incrementally
- reducing whole-library materialization where possible

## NAS / Mount Failure Design

This needs to be explicit in the Go design.

Important rule:

- assume some filesystem calls can block indefinitely inside the kernel

Because of that, the final design should not rely on goroutine cancellation alone. Instead:

- run risky file operations in an isolated worker process
- time out at the process boundary
- kill and replace the worker on timeout
- stop the run after the first timeout unless there is a very clear recovery strategy

Worker model options:

1. Single persistent worker process.
2. Small worker pool with strict replacement on timeout.

Recommended starting point:

- one persistent worker process for risky calls
- keep normal orchestration in the main process
- expand only if profiling shows a clear need

## CLI Migration Plan

Port the CLI in slices, not all at once.

Suggested order:

1. `list`
2. `status`
3. `verify`
4. `hash`
5. `create`
6. `add` copy-mode
7. `add` init/resume-mode
8. reporting and completions

Why this order:

- lower-risk read commands validate DB compatibility first
- write paths come later after the runtime and DB layers are trusted
- `add` is the most complex and highest-risk command

## Validation Plan

The port should be validated at three levels.

### 1. Unit Validation

For pure logic:

- target path computation
- duplicate classification
- quarantine rules
- config round-tripping
- migration logic

### 2. Integration Validation

Against temporary real filesystems:

- copy import
- in-place initialize
- resume after interruption
- orphan recovery
- path conflict suffixing
- DB rollback behavior on failure

### 3. Side-by-Side Validation

Run Python and Go against cloned datasets and compare:

- resulting DB rows
- resulting library tree
- counts for imported, quarantined, duplicates, and missing

This is the highest-value validation before making Go the default implementation.

## Performance Work Plan

Benchmark before and after each major phase.

Measure:

- discovery throughput
- hashing throughput
- metadata throughput
- classify/init memory usage
- import throughput
- startup latency on large existing DBs
- resume latency with 100k+ queued rows

Representative datasets:

- small: 1k files
- medium: 25k files
- large: 100k+ files

Important:

- include NAS-backed runs where possible
- include fault-injection cases, not just happy-path benchmarks

## Rollout Options

### Option A: Full Replacement Cutover

Switch from Python CLI to Go CLI in one step.

Pros:

- simpler end state

Cons:

- highest risk
- hardest to debug under real data

### Option B: Parallel CLIs

Ship a second binary, for example `trove-go`, during validation.

Pros:

- easy side-by-side testing
- easy rollback
- lower user risk

Cons:

- temporary duplication

Recommended:

- use parallel CLIs first

### Option C: Hybrid System

Keep Python for some functions and call a Go helper for high-risk/high-scale parts.

Examples:

- Go for discovery and file operations
- Python for metadata/reporting

Pros:

- faster time to value

Cons:

- operational complexity
- two runtimes to debug

Recommended only if a full port is deferred but the current Python bottlenecks are urgent.

## Concrete Milestones

### Milestone 1: Specification

- finalize behavior spec
- identify critical invariants
- freeze DB compatibility target

### Milestone 2: Python Hardening

- chunk/stream high-volume paths
- consolidate file-op protection
- confirm behavior on real large datasets

### Milestone 3: Go Foundation

- SQLite layer
- config layer
- CLI skeleton
- read-only commands

### Milestone 4: Go Write Path

- create/relocate/delete
- import copy-mode
- verify resume semantics

### Milestone 5: Go Initialize Path

- in-place reorganization
- orphan recovery
- mount timeout behavior

### Milestone 6: Parallel Validation

- compare Python vs Go on real datasets
- benchmark and fix mismatches

### Milestone 7: Default Cutover

- make Go CLI primary
- keep Python fallback for a defined deprecation period

## Recommendation

The best path is:

1. harden the current Python architecture first
2. define behavior precisely
3. build a Go implementation in parallel
4. validate side-by-side before cutover

If the only goal is short-term bug fixing, stay in Python.

If the goal is a long-lived, large-scale, reliable photo-ingest utility, Go is a strong medium-term target, but only if the port is staged and behavior-driven rather than treated as a clean-slate rewrite.
