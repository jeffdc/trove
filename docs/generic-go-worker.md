# Generic Go Worker Plan

## Goal

Build a reusable Go worker process that provides protected filesystem operations
for Trove and other media-library tools, including a future music-oriented tool.

The worker should be:

- media-agnostic
- safe around flaky NAS / SMB / network mounts
- reusable across multiple applications
- narrow in scope

It should not contain photo-specific or music-specific business logic.

See also: `docs/cross-project-architecture.md` for the current repository and
language strategy around `trove`, `reprise`, and the extracted worker.

## Why This Exists

Trove has two very different problem domains:

1. media-specific planning logic
2. risky filesystem execution on unreliable storage

These domains have different ideal implementation characteristics.

The planning side benefits from a more expressive language and richer domain modeling.
The filesystem side benefits from a pragmatic systems language with strong process,
I/O, and concurrency support.

That makes a split architecture attractive:

- application layer in a higher-level language
- protected filesystem worker in Go

## Reuse Across Photo and Music Tools

The low-level file-ops layer is highly reusable between a photo tool and a music tool.

Shared concerns:

- recursive directory walking
- extension and filename filtering
- path existence checks
- file size and stat checks
- hashing
- move/copy/verify operations
- empty directory cleanup
- mount responsiveness checks
- timeout isolation for dead NAS operations
- batching and progress-oriented execution

Photo-specific concerns:

- EXIF extraction
- capture-date fallback rules
- camera model normalization
- photo quarantine semantics

Music-specific concerns:

- ID3 / FLAC / Vorbis metadata
- album/artist/track parsing
- disc/track ordering
- music-specific quarantine semantics

The worker should contain only the shared concerns.

## Core Design Principle

The worker should know:

- filesystems
- bytes
- paths
- processes
- timeouts

The worker should not know:

- photos
- music
- albums
- cameras
- duplicate business rules
- library configuration semantics beyond generic path/operation arguments

## Recommended Architecture

Use a long-lived Go worker process with a narrow IPC protocol.

The application process:

- owns SQLite
- owns planning and classification
- owns user-facing CLI behavior
- decides what file operation should happen

The Go worker:

- performs risky filesystem operations
- isolates operations that can hang in kernel I/O
- times out and restarts when necessary
- returns structured results and structured errors

This is preferable to deep FFI because:

- it keeps failure isolation
- it is easier to debug
- it is easier to reuse across languages
- it matches the natural fault boundary of the system

## Recommended Interop Model

Use a persistent worker process communicating over one of:

- stdin/stdout with framed JSON
- Unix domain sockets
- local TCP only if needed, but usually unnecessary

Recommended default:

- stdin/stdout framed JSON

Reasons:

- simple
- portable
- easy to supervise from any host language
- no extra transport infrastructure

## Worker Scope

The worker should expose only a small set of filesystem primitives and batched operations.

### Candidate operations

- `check_mount`
- `path_exists`
- `stat_path`
- `stat_paths`
- `walk_tree`
- `hash_path`
- `hash_paths`
- `copy_and_hash`
- `move_file`
- `unlink_path`
- `mkdir_all`
- `remove_empty_dirs`

### Optional operations

- `resolve_disk_conflict`
- `batch_copy`
- `batch_move`
- `run_external_tool`

These should only be added if multiple applications genuinely need them.

## Operations That Should Stay Out of the Worker

The worker should not decide:

- whether a file is a duplicate in application terms
- what metadata fields matter
- where a file belongs logically in a media library
- whether a file should be quarantined for business reasons
- how a DB row should transition between workflow states

Those decisions belong to the application layer.

## API Design Guidance

Keep the protocol:

- explicit
- typed
- batch-friendly
- versioned
- narrow

### Request shape

```json
{
  "id": 42,
  "op": "copy_and_hash",
  "args": {
    "source": "/Volumes/source/file.jpg",
    "dest": "/Volumes/library/2024/01/file.jpg",
    "chunk_size": 8192,
    "timeout_seconds": 600
  }
}
```

### Success response

```json
{
  "id": 42,
  "ok": true,
  "result": {
    "md5": "abcd1234"
  }
}
```

### Failure response

```json
{
  "id": 42,
  "ok": false,
  "error": {
    "kind": "timeout",
    "message": "operation timed out after 60s"
  }
}
```

## Error Model

The worker should return structured error kinds such as:

- `timeout`
- `not_found`
- `permission_denied`
- `cross_device`
- `already_exists`
- `io_error`
- `worker_crash`

The application can then map those into tool-specific semantics.

Example:

- Trove may map `timeout` to "mount may be unavailable"
- a music tool may map the same error into its own pause/retry behavior

## Timeout and Isolation Strategy

The worker must assume some filesystem operations can block indefinitely in kernel I/O.

Design implications:

- do not rely on goroutine cancellation alone
- isolate risky operations in a subprocess or a killable worker boundary
- kill and replace workers after timeout
- treat timeout as a stop condition unless the host application has an explicit retry policy

Important note:

- no implementation can guarantee the OS immediately frees a child stuck in kernel U-state
- the goal is to protect the host application from getting trapped too

## Batching Strategy

To keep the worker generic and efficient:

- prefer batch-oriented requests for discovery, stat, and hashing
- avoid one tiny RPC per file when a single batch can handle thousands

Good examples:

- `walk_tree` returns file candidates in chunks
- `hash_paths` accepts a bounded list of paths
- `stat_paths` checks many files at once

This matters for both photo and music tools.

## Suggested Responsibility Split

### Host application

- library definitions
- config
- SQLite state
- planning
- duplicate logic
- metadata rules
- quarantining rules
- reporting
- resume semantics

### Go worker

- risky I/O execution
- path and mount checks
- batch traversal
- hashing and verified copy
- worker lifecycle and restart on timeout

## Versioning

The worker protocol should have an explicit version from the beginning.

Suggested fields:

- protocol version
- worker version
- capability list

This allows:

- rolling upgrades
- multiple host applications
- feature detection without fragile assumptions

## Packaging and Deployment

Even if packaging is not the primary concern, keep the worker easy to use:

- single binary
- no application-specific compile-time assumptions
- host passes only runtime config

Ideal result:

- Trove can start the worker as a child process
- the music tool can do the same
- both speak the same stable protocol

## Risks

The biggest risks are not technical feasibility but boundary discipline.

### Risk: boundary creep

The worker starts generic but slowly absorbs business logic.

Examples:

- adding EXIF-aware operations
- adding music metadata parsing
- adding DB-aware duplicate checks

Mitigation:

- require every worker operation to be justified as media-agnostic

### Risk: over-chatty protocol

If the host makes tiny RPCs for every single file operation, latency and complexity rise.

Mitigation:

- design batch operations from the beginning

### Risk: duplicated logic

If some planning logic exists in both the host and worker, they will drift.

Mitigation:

- keep all business decisions in the host

## Recommended Build Sequence

### Phase 1

Build a minimal generic worker supporting:

- `check_mount`
- `path_exists`
- `stat_path`
- `walk_tree`
- `hash_path`
- `copy_and_hash`
- `move_file`
- `unlink_path`

Use it only from Trove first.

### Phase 2

Stabilize:

- error semantics
- timeout behavior
- protocol framing
- worker restart behavior

### Phase 3

Generalize the interface as needed for the music tool, but only after the overlap is proven.

### Phase 4

Optionally split the worker into its own repository if both tools depend on it cleanly.

## Recommendation

A reusable Go worker is a good idea if it is treated as:

- a protected filesystem engine
- a process-isolated I/O layer
- a generic service for file operations

It is a bad idea if it turns into:

- Trove-in-Go plus some accidental extra commands
- a second application layer with duplicated business rules

For Trove and a future music-library tool, the overlap is strong enough that a generic worker is very plausible and worth designing deliberately from the start.
