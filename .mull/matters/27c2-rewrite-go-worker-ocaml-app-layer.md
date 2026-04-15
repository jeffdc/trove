---
status: refined
created: 2026-04-13
updated: 2026-04-15
docs: [docs/go-port-plan.md, docs/generic-go-worker.md, docs/ocaml-layer-on-worker.md, docs/intake-algorithm.md, docs/worker-protocol-contract.md, docs/worker-repo-extraction-plan.md]
relates: [6cc8, 7053]
---

# Rewrite: Go worker + OCaml app layer

## Design

Rewrite trove from Python to a two-layer architecture:

- **Go worker** — generic, reusable filesystem engine with process isolation and timeout protection. Shared between trove (photos) and reprise (music).
- **OCaml app layer** — domain modeling, planning, SQLite state, CLI, reporting. Application-specific per tool.

The Go worker is a long-lived child process communicating over stdin/stdout with newline-delimited JSON. The OCaml layer spawns it, sends typed requests, interprets results, and owns all business logic and database state.

### Key architectural decisions

- Worker knows filesystems, bytes, paths, timeouts. Nothing about photos, music, or libraries.
- OCaml layer owns SQLite completely. Worker never touches the database.
- Planning is pure/testable. Execution is effectful and calls the worker.
- Worker protocol is versioned from day one for multi-tool reuse.
- Go stdlib covers nearly all worker needs — no significant third-party deps.

### Docs

Existing design docs in `docs/` remain the authoritative reference:
- `go-port-plan.md` — overall migration rationale and strategy
- `generic-go-worker.md` — worker scope, API, error model, batching
- `ocaml-layer-on-worker.md` — OCaml module layout, type design, testing
- `intake-algorithm.md` — behavioral spec for add/init workflows
- `worker-repo-extraction-plan.md` — staged plan for extracting the Go worker
  into its own repository

## Current Follow-On Direction

The worker is now far enough along that extraction into its own repo should be
planned explicitly rather than left implicit in the original rewrite matter.

The current working position is:

- keep the worker media-agnostic
- extract it before `reprise` adopts it directly
- treat protocol, timeout behavior, and binary-path consumption as the main
  pre-extraction contracts
- avoid coupling extraction with broader application redesign

## Current Status

This matter now spans both the architectural rewrite and the worker extraction
work that fell out of it.

What is true now:

- the worker protocol has been expanded and written down
- the Go worker has been imported into the separate `grove` repo
- `trove` now consumes the worker as an external binary or sibling checkout
- the in-tree `worker/` source tree has been removed from `trove`
- the remaining major rewrite work is in the OCaml application layer, not the
  worker packaging boundary

That means the worker-extraction part of this matter is no longer speculative.
It is effectively in transition-to-stable mode, with the remaining work focused
on CI/release consumption and finishing the OCaml-side reshape.

## Implementation Plan

**Goal:** Replace the Python trove CLI with a Go filesystem worker + OCaml application layer, then delete the Python code.

**Architecture:** Go worker process communicates over stdin/stdout JSON with the OCaml application. OCaml owns all domain logic, SQLite state, and CLI. Worker is a generic reusable binary shared with reprise.

**Tech Stack:**
- Go (worker): stdlib `os`, `path/filepath`, `crypto/md5`, `io`, `encoding/json`, `os/exec`. Possibly `charlievieth/fastwalk` for NAS directory traversal perf.
- OCaml (app): `dune` build, `cmdliner` CLI, `sqlite3` or `caqti` for DB, `yojson` for JSON, `alcotest` for tests.
- External: `exiftool` (retained for metadata extraction, called from OCaml layer).

---

### Phase 1: Go Worker

Status: substantially complete, with ongoing protocol hardening and worker repo
maintenance now happening in `grove`.

The worker is independently buildable, testable, and deployable. It has no
knowledge of trove or any application. It began life under `trove/worker/` and
has now been extracted into the separate `grove` repo.

#### Task 1: Project scaffold and IPC protocol

**Files:**
- Create: `worker/go.mod`
- Create: `worker/cmd/worker/main.go`
- Create: `worker/protocol/protocol.go`
- Create: `worker/protocol/protocol_test.go`

**Behavior:**
Define the JSON wire protocol. Request: `{id, op, args}`. Response: `{id, ok, result}` or `{id, ok: false, error: {kind, message}}`. Protocol version negotiation on startup — worker sends a `hello` message with its version and capabilities list. Main loop: read request from stdin, dispatch, write response to stdout.

Error kinds: `timeout`, `not_found`, `permission_denied`, `cross_device`, `already_exists`, `io_error`, `worker_crash`, `unknown`.

**Testing:**
- Encode/decode round-trip for all message types
- Unknown op returns structured error
- Malformed JSON returns structured error
- Version hello on startup

#### Task 2: Path and stat operations

**Files:**
- Create: `worker/ops/stat.go`
- Create: `worker/ops/stat_test.go`

**Behavior:**
Implement `path_exists`, `stat_path`, `stat_paths` (batch). Return structured results with size, mtime, mode. `stat_paths` accepts a list and returns results per-path (some may error individually without failing the batch).

**Testing:**
- Existing file returns correct stats
- Missing file returns `not_found` error
- Batch with mix of existing/missing returns per-path results
- Symlink handling (skip or follow, configurable)

#### Task 3: Mount health check

**Files:**
- Create: `worker/ops/mount.go`
- Create: `worker/ops/mount_test.go`

**Behavior:**
`check_mount` does a timed `os.Stat` on the given path. If it completes within the timeout, mount is healthy. Uses goroutine + channel pattern with `time.After`. This is the one operation that runs in-process (not subprocess-isolated) because it IS the health check — if this hangs, the worker itself is stuck, which the OCaml layer detects via response timeout.

**Testing:**
- Healthy path returns success
- Non-existent path returns error
- Timeout behavior (mock or use a temp path)

#### Task 4: Directory walking

**Files:**
- Create: `worker/ops/walk.go`
- Create: `worker/ops/walk_test.go`

**Behavior:**
`walk_tree` takes root path, extension filter list, exclude patterns (glob), and returns results in chunks. Uses `filepath.WalkDir`. Skips symlinks, zero-byte files, and matched exclude patterns. Returns: relative path, size, mtime for each file. Chunked response — sends partial results as they accumulate to a configurable batch size rather than buffering the entire tree.

**Testing:**
- Walk returns files matching extensions
- Exclude patterns are respected
- Symlinks skipped
- Zero-byte files skipped
- Empty directory returns empty result
- Chunked output with large directory

**Notes:** If NAS traversal perf becomes an issue, swap `filepath.WalkDir` for `charlievieth/fastwalk`. Same interface shape.

#### Task 5: File hashing

**Files:**
- Create: `worker/ops/hash.go`
- Create: `worker/ops/hash_test.go`

**Behavior:**
`hash_path` computes MD5 of a single file in 8KB chunks. `hash_paths` accepts a bounded list and returns per-path results. Streaming — never loads full file into memory.

**Testing:**
- Known file produces expected MD5
- Missing file returns `not_found`
- Empty file produces correct hash
- Batch with mix of valid/invalid paths
- Large file (verify streaming, not memory spike)

#### Task 6: Copy, move, and delete

**Files:**
- Create: `worker/ops/fileops.go`
- Create: `worker/ops/fileops_test.go`

**Behavior:**
`copy_and_hash`: create parent dirs, stream copy via `io.MultiWriter(dst, md5Hasher)`, return hash. Write to `.tmp` adjacent to dest, rename on success. On failure, clean up partial `.tmp` file.

`move_file`: try `os.Rename`. On `EXDEV`, fall back to copy_and_hash + verify + delete source. Accepts optional `expected_hash` for verification.

`unlink_path`: delete a single file.

`remove_empty_dirs`: walk upward from a path, removing empty directories, stopping at a configured boundary path.

`mkdir_all`: create directory tree.

**Testing:**
- Copy produces correct file with matching hash
- Copy cleans up on failure
- Move on same device (rename)
- Move cross-device (copy+verify+delete)
- Move with hash verification failure (source not deleted)
- Unlink existing file
- Unlink missing file returns error
- Remove empty dirs stops at boundary
- Remove empty dirs leaves non-empty dirs alone

#### Task 7: Timeout isolation

**Files:**
- Create: `worker/supervisor/supervisor.go`
- Create: `worker/supervisor/supervisor_test.go`
- Modify: `worker/cmd/worker/main.go` (integrate supervisor into dispatch)

**Behavior:**
Risky operations (copy, move, hash — anything that reads/writes files) run inside a timeout wrapper. Use `context.WithTimeout` + goroutine. If the operation exceeds the per-request timeout (from `args.timeout_seconds`, default 60), the goroutine is abandoned and a `timeout` error is returned. The main worker process stays alive — it's the goroutine that's abandoned, not the process. If the worker itself becomes unresponsive (mount freeze), the OCaml layer detects this via its own response timeout and kills/restarts the worker process.

This is simpler than subprocess-per-operation. The worker IS the isolation boundary (it's already a child process). If it hangs, the parent kills it.

**Testing:**
- Operation completing within timeout returns result
- Operation exceeding timeout returns timeout error
- Worker remains responsive after a timeout

**Notes:** The go-port-plan doc discusses subprocess-per-operation. That's overkill for v1. The worker process itself IS the subprocess boundary. If a goroutine hangs on kernel I/O, the OCaml layer kills the worker process and spawns a new one. This matches the "kill and replace the worker on timeout" design without nested subprocesses.

#### Task 8: End-to-end integration tests

**Files:**
- Create: `worker/integration_test.go`

**Behavior:**
Spawn the worker binary as a subprocess. Send JSON requests over stdin, read responses from stdout. Exercise the full request/response cycle for each operation. Verify protocol framing, error handling, and timeout behavior against real temp filesystems.

**Testing:**
- Full lifecycle: hello → walk → hash → copy → verify → cleanup
- Error propagation through the protocol
- Worker recovery after timeout
- Concurrent requests (if supported in v1, otherwise sequential is fine)

---

### Phase 2: OCaml App Layer

Status: in progress. The rewrite still lives or dies on the quality of this
layer, especially around expression of rules, validation, and recovery logic.

#### Task 9: Project scaffold and build

**Files:**
- Create: `ocaml/dune-project`
- Create: `ocaml/bin/dune`
- Create: `ocaml/bin/main.ml`
- Create: `ocaml/lib/dune`
- Create: `ocaml/.ocamlformat`

**Behavior:**
Set up dune project with `cmdliner` for CLI, `sqlite3` for DB, `yojson` for JSON, `alcotest` for tests. Verify the build produces a `trove` binary. Minimal CLI that prints version and exits.

**Testing:**
- Project builds
- Binary runs and prints version

**Notes:** `opam` for package management. Pin versions in an `opam` file.

#### Task 10: Domain types

**Files:**
- Create: `ocaml/lib/domain.ml`
- Create: `ocaml/lib/domain.mli`
- Create: `ocaml/test/test_domain.ml`

**Behavior:**
Define the core variant types that model the workflow:

```ocaml
type file_status =
  | Discovered
  | Hashed
  | Quarantined of quarantine_reason
  | Duplicate of duplicate_kind
  | Imported

type quarantine_reason = Hash_failed | No_date | Unreadable
type duplicate_kind = In_batch | In_library

type file_action = Index | Move of { src: string; dst: string } | Quarantine of string
type worker_error = Timeout | Not_found | Permission_denied | Cross_device | Io_error of string
type app_error = Mount_unavailable | File_disappeared | Db_error of string | Worker_protocol_error of string
```

Plus record types for `file_record`, `entry`, `library`, `library_config`, `import_plan`, `init_plan`.

**Testing:**
- Round-trip serialization of config types
- Status transition validity (discovered → hashed is valid, imported → discovered is not)

#### Task 11: Worker client

**Files:**
- Create: `ocaml/lib/worker_client.ml`
- Create: `ocaml/lib/worker_client.mli`
- Create: `ocaml/lib/worker_protocol.ml`
- Create: `ocaml/test/test_worker_client.ml`

**Behavior:**
Spawn the Go worker binary as a child process. Send typed requests as JSON over stdin, read typed responses from stdout. Map worker error kinds to `worker_error` variants. Handle worker process death — detect, restart, and return `Worker_protocol_error`.

Module signature roughly:

```ocaml
module type WORKER = sig
  type t
  val start : worker_path:string -> t
  val stop : t -> unit
  val check_mount : t -> string -> (unit, worker_error) result
  val walk_tree : t -> root:string -> filters:walk_filters -> (walk_item list, worker_error) result
  val hash_path : t -> string -> (string, worker_error) result
  val copy_and_hash : t -> src:string -> dst:string -> (string, worker_error) result
  val move_file : t -> src:string -> dst:string -> expected_hash:string option -> (string, worker_error) result
  val unlink_path : t -> string -> (unit, worker_error) result
  val remove_empty_dirs : t -> stop_at:string -> string -> (unit, worker_error) result
end
```

**Testing:**
- Start/stop lifecycle
- Request/response round-trip (against real worker binary)
- Worker crash detection and restart
- Timeout detection (OCaml-side timeout on worker response)

**Notes:** This is a critical integration point. Test against the real Go worker binary, not mocks.

#### Task 12: SQLite layer

**Files:**
- Create: `ocaml/lib/db.ml`
- Create: `ocaml/lib/db.mli`
- Create: `ocaml/test/test_db.ml`

**Behavior:**
Same schema as current Python implementation (libraries, entries, files, schema_version). Must be able to open existing trove databases for cutover. CRUD for all tables. Transaction helpers. Batch query support (fetch N file records by status). Schema migration on open.

**Testing:**
- Create database, verify schema
- CRUD for libraries, entries, files
- Batch query by status
- Transaction rollback on failure
- Open existing Python-created database (use a fixture)
- Schema migration from current version

**Notes:** Compatibility with the existing Python DB schema is a hard requirement for cutover.

#### Task 13: Config module

**Files:**
- Create: `ocaml/lib/config.ml`
- Create: `ocaml/lib/config.mli`
- Create: `ocaml/test/test_config.ml`

**Behavior:**
Parse and serialize `LibraryConfig` JSON. Same structure as Python: organization (structure, include_camera_model, unknown_model_label), file_types (photos, videos, raw extensions), exclude_patterns, quarantine config. Round-trip compatibility with existing configs stored in the database.

**Testing:**
- Parse existing Python-generated config JSON
- Round-trip serialize/deserialize
- Defaults match Python defaults
- Invalid config produces clear errors

#### Task 14: Discovery and hashing pipeline

**Files:**
- Create: `ocaml/lib/pipeline.ml`
- Create: `ocaml/lib/pipeline.mli`
- Create: `ocaml/test/test_pipeline.ml`

**Behavior:**
Orchestrate: walk source via worker → persist discovered files to DB → hash via worker → persist hashes → extract metadata via exiftool → persist metadata → compute target paths. Chunked/batched — fetch a bounded batch from DB, process it, commit, continue. Per-file DB commits for crash safety.

Resume recovery: on startup, query files with incomplete status and re-enter the pipeline at the appropriate stage.

**Testing:**
- Discovery persists file records with status=discovered
- Hashing updates status to hashed
- Metadata extraction updates capture_date and camera_model
- No-date files get quarantined
- Hash failure quarantines file
- Resume picks up incomplete work
- Chunked processing doesn't load entire library into memory

**Notes:** Metadata extraction calls `exiftool` directly from OCaml (not through the worker — exiftool is app-specific). Use `Unix.open_process` or similar.

#### Task 15: Import planning and execution

**Files:**
- Create: `ocaml/lib/plan_import.ml`
- Create: `ocaml/lib/execute_import.ml`
- Create: `ocaml/test/test_import.ml`

**Behavior:**
Planning (pure): batch dedup by hash, library dedup by size+hash, path conflict counting. Produces `import_plan` with to_import, duplicates_in_batch, duplicates_in_library, path_conflicts.

Execution (effectful): mark duplicates in DB, then for each to_import file: resolve path conflicts (suffix), orphan recovery (check dest exists, hash it, skip copy if matches), copy via worker, atomic DB write (insert entry + update file status in one transaction). Per-file commits.

**Testing:**
- Batch dedup groups correctly
- Library dedup detects size+hash matches
- Path conflict suffixing (photo-1.jpg through photo-N.jpg)
- Orphan recovery skips copy when dest matches
- Copy failure doesn't create entry
- DB transaction rolls back on failure
- Full import flow end-to-end

#### Task 16: Init planning and execution

**Files:**
- Create: `ocaml/lib/plan_init.ml`
- Create: `ocaml/lib/execute_init.ml`
- Create: `ocaml/test/test_init.ml`

**Behavior:**
Planning: compare current relative path to computed target path. Classify as index (paths match), move (paths differ), or quarantine (no date).

Execution: for index — insert entry directly. For move — move via worker, insert entry with original_path, clean up empty dirs. For quarantine — move to quarantine dir. Signal handling for graceful stop. Mount health checks between files.

**Testing:**
- Already-correct files get indexed without move
- Needs-move files get relocated
- Failed move rolls back (file returned to original location)
- Empty parent dirs cleaned up after move
- Quarantine moves to correct directory
- Graceful stop on interrupt

#### Task 17: CLI

**Files:**
- Create: `ocaml/bin/main.ml` (expand from scaffold)
- Create: `ocaml/lib/cli.ml`
- Create: `ocaml/test/test_cli.ml`

**Behavior:**
Port the Click CLI to cmdliner. Commands in priority order:

1. `trove create <name> <location>` — create library
2. `trove list` — list libraries
3. `trove add <name> <source>` — import from external source
4. `trove add <name> --init` — organize in-place
5. `trove status <name>` — show processing status
6. `trove verify <name>` — check library integrity
7. `trove hash <name>` — hash all files
8. `trove duplicates <name>` — find duplicates
9. `trove relocate <name> <path>` — change library path
10. `trove delete <name>` — delete library

Global flags: `--db PATH`, `--verbose`, `--quiet`.

**Testing:**
- Each command parses arguments correctly
- Missing required args produce clear errors
- --db flag overrides default path
- Help text is accurate

**Notes:** Don't port reporting (`report.py` HTML generation) in v1 unless explicitly needed. Text output first.

#### Task 18: Completion and cleanup

**Files:**
- Create: `ocaml/lib/complete.ml`
- Create: `ocaml/test/test_complete.ml`

**Behavior:**
After import/init, verify all files are accounted for (imported, duplicate, or quarantined). Delete processed file records from the files table. Report summary.

**Testing:**
- All files accounted for → clean up succeeds
- Unaccounted files → error with details

---

### Phase 3: Migration and Cutover

Status: partially complete. The worker cutover has already happened in the
rewrite worktree; the remaining cutover is about finishing the OCaml app layer
and retiring the Python implementation cleanly.

#### Task 19: Build integration

**Files:**
- Create: `Makefile` (new, replacing Python Makefile)
- Modify: `pyproject.toml` (remove or archive)

**Behavior:**
`trove` should build and test the OCaml layer while consuming the worker from
`grove`. Local development may use a sibling checkout by default. CI should
build the worker from `grove` explicitly and pass the path in through
`GROVE_WORKER_PATH` or an equivalent build variable.

#### Task 20: Side-by-side validation

**Behavior:**
Run Python trove and OCaml trove against the same test datasets. Compare:
- DB state after discovery, hashing, metadata extraction
- Import plans (same duplicates detected, same path assignments)
- Final library tree structure
- Entry counts and file statuses

This is manual validation, not automated tests. Use existing libraries as test fixtures.

#### Task 21: Cutover

**Behavior:**
Delete `src/trove/`, `tests/`, `pyproject.toml`, and Python-related config once
the OCaml rewrite is ready. The worker no longer needs any move inside `trove`
because it already lives in `grove`. Update the remaining documentation and
cut over to the OCaml CLI as the only supported implementation.

---

### Dependency Order

```
Task 1-6  (Go worker ops — parallel, no deps between them)
  → Task 7  (timeout isolation — wraps all ops)
  → Task 8  (integration tests — needs complete worker)

Task 9   (OCaml scaffold — no deps)
Task 10  (domain types — no deps)
  → Task 11 (worker client — needs domain types + built worker)
  → Task 12 (SQLite layer — needs domain types)
  → Task 13 (config — needs domain types)
  → Task 14 (pipeline — needs worker client + DB + config)
  → Task 15 (import — needs pipeline)
  → Task 16 (init — needs pipeline)
  → Task 17 (CLI — needs all above)
  → Task 18 (completion — needs pipeline)

Task 19-21 (migration — needs everything above)
```

Go worker (tasks 1-8) and OCaml scaffold + types (tasks 9-10) can proceed in parallel.
