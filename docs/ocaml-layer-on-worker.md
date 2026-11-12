# OCaml Layer On Top Of The Generic Go Worker

## Goal

Define how an OCaml application layer would sit on top of the generic Go worker.

The OCaml layer should handle:

- domain modeling
- planning and classification
- SQLite state and migrations
- resumable workflow orchestration
- CLI behavior
- reporting

The Go worker should remain a generic protected filesystem engine.

## Design Principle

The split should be:

- Go knows filesystems and risky I/O
- OCaml knows workflow semantics and media-domain rules

This separation should be strict.

The OCaml layer should be the source of truth for:

- what operations should happen
- why they should happen
- how state transitions are recorded
- how errors are interpreted

The Go worker should only answer:

- can this filesystem operation be performed
- what happened when it was attempted

## High-Level Architecture

### OCaml responsibilities

- parse CLI arguments
- load and validate library definitions
- own SQLite access and schema migrations
- read file records and entry records
- construct plans for import / initialize / verify
- send concrete filesystem requests to the worker
- translate worker results into DB mutations
- present progress and reporting to the user

### Go worker responsibilities

- perform mount checks
- walk trees
- stat paths
- hash files
- copy and verify
- move with fallback
- unlink
- clean up empty directories
- timeout and restart safely on hung mounts

## OCaml Module Layout

A plausible OCaml package layout could be:

- `Cli`
  CLI entrypoint and command dispatch
- `Config`
  domain config types and serialization
- `Db`
  SQLite access layer
- `Domain`
  core types such as file records, entries, plans, and actions
- `Plan_import`
  import planning logic
- `Plan_init`
  initialize planning logic
- `Execute_import`
  effectful interpreter for import plans
- `Execute_init`
  effectful interpreter for initialize plans
- `Worker_client`
  protocol client for the Go worker
- `Worker_types`
  typed request/response definitions
- `Reporter`
  summaries and user-facing output

## Strongly Typed Domain Layer

One of the main reasons to put the top layer in OCaml is to model workflow states well.

Important types:

- `library`
- `library_config`
- `file_record`
- `entry`
- `file_action`
- `initialize_plan`
- `import_plan`
- `worker_error`
- `app_error`

The OCaml layer should use variants and records to make the workflow explicit.

Examples:

- `Discovered | Hashed | Quarantined | Duplicate | Imported | Missing`
- `Index | Move | Quarantine`
- `Timeout | Not_found | Permission_denied | Cross_device | Io_error`

This is the part OCaml is particularly good at.

## Worker Client Boundary

The worker client should be small and boring.

It should:

- start the worker process if needed
- manage stdin/stdout or socket framing
- send typed requests
- decode typed responses
- map protocol-level failures into OCaml error variants

It should not:

- contain business rules
- interpret media metadata
- decide how the DB should change

## Suggested Worker Client Interface

The OCaml side should expose a module roughly like:

```ocaml
module type WORKER = sig
  type error

  val check_mount : string -> (unit, error) result
  val path_exists : string -> (bool, error) result
  val stat_path : string -> (Unix.stats, error) result
  val walk_tree : root:string -> filters:walk_filters -> (walk_item list, error) result
  val hash_path : string -> (string, error) result
  val copy_and_hash : src:string -> dst:string -> (string, error) result
  val move_file : src:string -> dst:string -> expected_hash:string -> (string, error) result
  val unlink_path : string -> (unit, error) result
  val remove_empty_dirs : stop_at:string -> path:string -> (unit, error) result
end
```

This keeps the worker generic and the OCaml layer expressive.

## Protocol Mapping

The worker will likely communicate using JSON or another simple framing protocol.

The OCaml side should define protocol-specific types separate from domain types.

Recommended separation:

- `Worker_protocol`
  low-level wire representation
- `Worker_types`
  typed OCaml representation of worker operations
- `Worker_client`
  conversion plus transport

This avoids polluting domain logic with transport concerns.

## Error Handling Strategy

The OCaml layer should distinguish:

### Worker-level errors

- timeout
- not found
- permission denied
- cross-device
- generic I/O error
- malformed worker response
- worker crash

### Application-level errors

- missing file during planned move
- orphan recovery failure
- duplicate path conflict
- DB invariant violation
- metadata missing
- unsupported media rules

Worker errors should be converted into application semantics only in the execution layer.

Example:

- worker returns `Timeout`
- execution layer maps that into "mount may be unavailable"
- orchestration layer records stop state and avoids launching more work

## SQLite Ownership

The OCaml layer should own SQLite completely.

Reasons:

- avoids duplicating source of truth
- keeps workflow logic in one place
- simplifies reuse of the worker across multiple applications

The Go worker should not:

- read SQLite
- write SQLite
- decide row-level workflow transitions

The OCaml layer should:

- persist file records
- query batches
- checkpoint progress
- record missing/duplicate/imported states

## Planning and Execution Split

The OCaml layer should keep Trove’s most important architectural split:

- pure or mostly pure planning
- effectful execution

### Planning modules

These should:

- read current DB state
- classify files
- build action lists
- remain easy to unit test

### Execution modules

These should:

- call the worker
- write DB transitions
- stop on timeout or fatal errors
- preserve resumability

This split is one of the strongest reasons to use OCaml on top of the worker.

## Streaming / Chunked Execution

The OCaml layer should avoid reconstructing giant in-memory plans where possible.

Recommended strategy:

- fetch a bounded batch from SQLite
- classify that batch
- execute that batch
- commit progress
- continue

This will matter for both Trove and a future music tool.

The worker can be batch-capable, but the orchestration remains in OCaml.

## Applicability To Multiple Tools

The OCaml layer can be application-specific even when the Go worker is shared.

Example:

### Trove OCaml layer

- photo organization config
- EXIF-driven planning
- quarantine/no-date behavior
- duplicate semantics for photo libraries

### Music OCaml layer

- album/artist-based organization rules
- ID3/FLAC metadata interpretation
- track conflict handling
- music-specific quarantine rules

Both can use the same worker protocol and the same worker binary.

## Testing Strategy

The OCaml layer should be tested separately from the Go worker.

### Unit tests

For:

- path planning
- duplicate classification
- state transition logic
- error mapping

### Integration tests

For:

- real worker process interaction
- DB updates after worker success/failure
- stop-on-timeout behavior
- resume after partial execution

### Contract tests

For:

- worker protocol compatibility
- decoding/encoding correctness
- version negotiation

## Build Sequence

### Phase 1: Thin Client

Implement:

- worker process startup
- request/response framing
- typed error decoding

Use it for one or two simple operations first, such as `check_mount` and `hash_path`.

### Phase 2: Effect Boundary

Replace direct risky file operations with OCaml calls through `Worker_client`.

Keep planning logic unchanged.

### Phase 3: Domain Refactor

Move core planning and execution logic into well-separated OCaml modules.

### Phase 4: Streaming Improvements

Reduce in-memory planning for very large libraries by making OCaml orchestration more batch-oriented.

## Risks

### Risk: leaking protocol details upward

If JSON fields and worker response shapes appear everywhere in the app, the design will get messy.

Mitigation:

- keep a dedicated `Worker_client` abstraction

### Risk: duplicated error logic

If worker errors are interpreted in several places, behavior will drift.

Mitigation:

- centralize worker-error to app-error mapping

### Risk: too much orchestration in the CLI module

If the CLI module directly manages DB reads, worker calls, retries, and reporting, the architecture will collapse into a script.

Mitigation:

- keep CLI thin
- put orchestration in dedicated modules

## Recommendation

The OCaml layer should be:

- the semantic brain of the application
- the owner of SQLite state
- the planner and orchestrator

The Go worker should be:

- a reusable protected filesystem engine
- narrowly focused
- replaceable and versioned

That division gives:

- reusable infrastructure
- expressive domain code
- strong fault isolation
- a clean path to supporting both Trove and a future music-library tool
