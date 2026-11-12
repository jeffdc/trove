Replace the Python trove with two layers: the media-agnostic Go worker (`grove`, its own repo) for protected filesystem operations, and an OCaml application that owns the domain, SQLite schema, migration and CLI.

The OCaml app targets a new library-centric schema: content-identified file objects, explicit library membership and placements, run-scoped items and a file-ops journal, instead of the old `files` table. That schema grows out of the run-centric durable-state design carried in full below. A one-way `migrate-db` moves the Python database into it, preserving expensive completed work and reporting ambiguity instead of guessing.

The rewrite must also reproduce what Python gained since: source mtime preserved on copy, Finder Date Created stamped from capture date, and a backfill command. The full requirement is carried below.

Done when normal ingest and inspection run in OCaml on a migrated production database, with no fallback to Python.

Order (from operationalization-plan.md): trust the migration first; then a read-only target runtime (list, status, verify); then target-schema import; then cutover; then maintenance and reconciliation.

Docs on branch go-ocaml-rewrite: docs/ocaml-reshape-plan.md, docs/implementation-plan.md, docs/library-centric-domain-model.md, docs/target-schema.md, docs/migration-matrix.md, docs/migration-layer-api.md, docs/worker-protocol-contract.md, and (uncommitted) docs/operationalization-plan.md and docs/disk-reconciliation-requirements.md. Background on main: docs/go-port-plan.md, docs/generic-go-worker.md, docs/ocaml-layer-on-worker.md, docs/intake-algorithm.md, docs/cross-project-architecture.md.

The three sections below carry, in full, the original rewrite design and task plan, the run-centric durable-state design, and the Python behaviours the rewrite must reproduce. The branch docs above came later and refine them: the OCaml app targets the library-centric schema rather than the original plan's same-as-Python schema (Tasks 10, 12 and 14 below), the worker was extracted to the grove repo rather than living under `worker/` here, and worker timeouts are recovered by killing the worker process. The decisions on this plan record where the later design departs.

## Original rewrite design and task plan

From matter 27c2 (Rewrite: Go worker + OCaml app layer), carried in full.

### Design

Rewrite trove from Python to a two-layer architecture:

- **Go worker** — generic, reusable filesystem engine with process isolation and timeout protection. Shared between trove (photos) and reprise (music).
- **OCaml app layer** — domain modeling, planning, SQLite state, CLI, reporting. Application-specific per tool.

The Go worker is a long-lived child process communicating over stdin/stdout with newline-delimited JSON. The OCaml layer spawns it, sends typed requests, interprets results, and owns all business logic and database state.

#### Key architectural decisions

- Worker knows filesystems, bytes, paths, timeouts. Nothing about photos, music, or libraries.
- OCaml layer owns SQLite completely. Worker never touches the database.
- Planning is pure/testable. Execution is effectful and calls the worker.
- Worker protocol is versioned from day one for multi-tool reuse.
- Go stdlib covers nearly all worker needs — no significant third-party deps.

#### Docs

Existing design docs in `docs/` remain the authoritative reference:
- `go-port-plan.md` — overall migration rationale and strategy
- `generic-go-worker.md` — worker scope, API, error model, batching
- `ocaml-layer-on-worker.md` — OCaml module layout, type design, testing
- `intake-algorithm.md` — behavioral spec for add/init workflows

### Implementation Plan

**Goal:** Replace the Python trove CLI with a Go filesystem worker + OCaml application layer, then delete the Python code.

**Architecture:** Go worker process communicates over stdin/stdout JSON with the OCaml application. OCaml owns all domain logic, SQLite state, and CLI. Worker is a generic reusable binary shared with reprise.

**Tech Stack:**
- Go (worker): stdlib `os`, `path/filepath`, `crypto/md5`, `io`, `encoding/json`, `os/exec`. Possibly `charlievieth/fastwalk` for NAS directory traversal perf.
- OCaml (app): `dune` build, `cmdliner` CLI, `sqlite3` or `caqti` for DB, `yojson` for JSON, `alcotest` for tests.
- External: `exiftool` (retained for metadata extraction, called from OCaml layer).

---

#### Phase 1: Go Worker

The worker is independently buildable, testable, and deployable. It has no knowledge of trove or any application. It lives in its own directory (initially `worker/` in the trove repo, extractable to its own repo later when reprise needs it).

##### Task 1: Project scaffold and IPC protocol

**Files:**
- Create: `worker/go.mod`
- Create: `worker/cmd/worker/main.go`
- Create: `worker/protocol/protocol.go`
- Create: `worker/protocol/protocol_test.go`

**Behavior:** Define the JSON wire protocol. Request: `{id, op, args}`. Response: `{id, ok, result}` or `{id, ok: false, error: {kind, message}}`. Protocol version negotiation on startup — worker sends a `hello` message with its version and capabilities list. Main loop: read request from stdin, dispatch, write response to stdout.

Error kinds: `timeout`, `not_found`, `permission_denied`, `cross_device`, `already_exists`, `io_error`, `worker_crash`, `unknown`.

**Testing:**
- Encode/decode round-trip for all message types
- Unknown op returns structured error
- Malformed JSON returns structured error
- Version hello on startup

##### Task 2: Path and stat operations

**Files:**
- Create: `worker/ops/stat.go`
- Create: `worker/ops/stat_test.go`

**Behavior:** Implement `path_exists`, `stat_path`, `stat_paths` (batch). Return structured results with size, mtime, mode. `stat_paths` accepts a list and returns results per-path (some may error individually without failing the batch).

**Testing:**
- Existing file returns correct stats
- Missing file returns `not_found` error
- Batch with mix of existing/missing returns per-path results
- Symlink handling (skip or follow, configurable)

##### Task 3: Mount health check

**Files:**
- Create: `worker/ops/mount.go`
- Create: `worker/ops/mount_test.go`

**Behavior:** `check_mount` does a timed `os.Stat` on the given path. If it completes within the timeout, mount is healthy. Uses goroutine + channel pattern with `time.After`. This is the one operation that runs in-process (not subprocess-isolated) because it IS the health check — if this hangs, the worker itself is stuck, which the OCaml layer detects via response timeout.

**Testing:**
- Healthy path returns success
- Non-existent path returns error
- Timeout behavior (mock or use a temp path)

##### Task 4: Directory walking

**Files:**
- Create: `worker/ops/walk.go`
- Create: `worker/ops/walk_test.go`

**Behavior:** `walk_tree` takes root path, extension filter list, exclude patterns (glob), and returns results in chunks. Uses `filepath.WalkDir`. Skips symlinks, zero-byte files, and matched exclude patterns. Returns: relative path, size, mtime for each file. Chunked response — sends partial results as they accumulate to a configurable batch size rather than buffering the entire tree.

**Testing:**
- Walk returns files matching extensions
- Exclude patterns are respected
- Symlinks skipped
- Zero-byte files skipped
- Empty directory returns empty result
- Chunked output with large directory

**Notes:** If NAS traversal perf becomes an issue, swap `filepath.WalkDir` for `charlievieth/fastwalk`. Same interface shape.

##### Task 5: File hashing

**Files:**
- Create: `worker/ops/hash.go`
- Create: `worker/ops/hash_test.go`

**Behavior:** `hash_path` computes MD5 of a single file in 8KB chunks. `hash_paths` accepts a bounded list and returns per-path results. Streaming — never loads full file into memory.

**Testing:**
- Known file produces expected MD5
- Missing file returns `not_found`
- Empty file produces correct hash
- Batch with mix of valid/invalid paths
- Large file (verify streaming, not memory spike)

##### Task 6: Copy, move, and delete

**Files:**
- Create: `worker/ops/fileops.go`
- Create: `worker/ops/fileops_test.go`

**Behavior:** `copy_and_hash`: create parent dirs, stream copy via `io.MultiWriter(dst, md5Hasher)`, return hash. Write to `.tmp` adjacent to dest, rename on success. On failure, clean up partial `.tmp` file.

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

##### Task 7: Timeout isolation

**Files:**
- Create: `worker/supervisor/supervisor.go`
- Create: `worker/supervisor/supervisor_test.go`
- Modify: `worker/cmd/worker/main.go` (integrate supervisor into dispatch)

**Behavior:** Risky operations (copy, move, hash — anything that reads/writes files) run inside a timeout wrapper. Use `context.WithTimeout` + goroutine. If the operation exceeds the per-request timeout (from `args.timeout_seconds`, default 60), the goroutine is abandoned and a `timeout` error is returned. The main worker process stays alive — it's the goroutine that's abandoned, not the process. If the worker itself becomes unresponsive (mount freeze), the OCaml layer detects this via its own response timeout and kills/restarts the worker process.

This is simpler than subprocess-per-operation. The worker IS the isolation boundary (it's already a child process). If it hangs, the parent kills it.

**Testing:**
- Operation completing within timeout returns result
- Operation exceeding timeout returns timeout error
- Worker remains responsive after a timeout

**Notes:** The go-port-plan doc discusses subprocess-per-operation. That's overkill for v1. The worker process itself IS the subprocess boundary. If a goroutine hangs on kernel I/O, the OCaml layer kills the worker process and spawns a new one. This matches the "kill and replace the worker on timeout" design without nested subprocesses.

##### Task 8: End-to-end integration tests

**Files:**
- Create: `worker/integration_test.go`

**Behavior:** Spawn the worker binary as a subprocess. Send JSON requests over stdin, read responses from stdout. Exercise the full request/response cycle for each operation. Verify protocol framing, error handling, and timeout behavior against real temp filesystems.

**Testing:**
- Full lifecycle: hello → walk → hash → copy → verify → cleanup
- Error propagation through the protocol
- Worker recovery after timeout
- Concurrent requests (if supported in v1, otherwise sequential is fine)

---

#### Phase 2: OCaml App Layer

##### Task 9: Project scaffold and build

**Files:**
- Create: `ocaml/dune-project`
- Create: `ocaml/bin/dune`
- Create: `ocaml/bin/main.ml`
- Create: `ocaml/lib/dune`
- Create: `ocaml/.ocamlformat`

**Behavior:** Set up dune project with `cmdliner` for CLI, `sqlite3` for DB, `yojson` for JSON, `alcotest` for tests. Verify the build produces a `trove` binary. Minimal CLI that prints version and exits.

**Testing:**
- Project builds
- Binary runs and prints version

**Notes:** `opam` for package management. Pin versions in an `opam` file.

##### Task 10: Domain types

**Files:**
- Create: `ocaml/lib/domain.ml`
- Create: `ocaml/lib/domain.mli`
- Create: `ocaml/test/test_domain.ml`

**Behavior:** Define the core variant types that model the workflow:

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

##### Task 11: Worker client

**Files:**
- Create: `ocaml/lib/worker_client.ml`
- Create: `ocaml/lib/worker_client.mli`
- Create: `ocaml/lib/worker_protocol.ml`
- Create: `ocaml/test/test_worker_client.ml`

**Behavior:** Spawn the Go worker binary as a child process. Send typed requests as JSON over stdin, read typed responses from stdout. Map worker error kinds to `worker_error` variants. Handle worker process death — detect, restart, and return `Worker_protocol_error`.

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

##### Task 12: SQLite layer

**Files:**
- Create: `ocaml/lib/db.ml`
- Create: `ocaml/lib/db.mli`
- Create: `ocaml/test/test_db.ml`

**Behavior:** Same schema as current Python implementation (libraries, entries, files, schema_version). Must be able to open existing trove databases for cutover. CRUD for all tables. Transaction helpers. Batch query support (fetch N file records by status). Schema migration on open.

**Testing:**
- Create database, verify schema
- CRUD for libraries, entries, files
- Batch query by status
- Transaction rollback on failure
- Open existing Python-created database (use a fixture)
- Schema migration from current version

**Notes:** Compatibility with the existing Python DB schema is a hard requirement for cutover.

##### Task 13: Config module

**Files:**
- Create: `ocaml/lib/config.ml`
- Create: `ocaml/lib/config.mli`
- Create: `ocaml/test/test_config.ml`

**Behavior:** Parse and serialize `LibraryConfig` JSON. Same structure as Python: organization (structure, include_camera_model, unknown_model_label), file_types (photos, videos, raw extensions), exclude_patterns, quarantine config. Round-trip compatibility with existing configs stored in the database.

**Testing:**
- Parse existing Python-generated config JSON
- Round-trip serialize/deserialize
- Defaults match Python defaults
- Invalid config produces clear errors

##### Task 14: Discovery and hashing pipeline

**Files:**
- Create: `ocaml/lib/pipeline.ml`
- Create: `ocaml/lib/pipeline.mli`
- Create: `ocaml/test/test_pipeline.ml`

**Behavior:** Orchestrate: walk source via worker → persist discovered files to DB → hash via worker → persist hashes → extract metadata via exiftool → persist metadata → compute target paths. Chunked/batched — fetch a bounded batch from DB, process it, commit, continue. Per-file DB commits for crash safety.

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

##### Task 15: Import planning and execution

**Files:**
- Create: `ocaml/lib/plan_import.ml`
- Create: `ocaml/lib/execute_import.ml`
- Create: `ocaml/test/test_import.ml`

**Behavior:** Planning (pure): batch dedup by hash, library dedup by size+hash, path conflict counting. Produces `import_plan` with to_import, duplicates_in_batch, duplicates_in_library, path_conflicts.

Execution (effectful): mark duplicates in DB, then for each to_import file: resolve path conflicts (suffix), orphan recovery (check dest exists, hash it, skip copy if matches), copy via worker, atomic DB write (insert entry + update file status in one transaction). Per-file commits.

**Testing:**
- Batch dedup groups correctly
- Library dedup detects size+hash matches
- Path conflict suffixing (photo-1.jpg through photo-N.jpg)
- Orphan recovery skips copy when dest matches
- Copy failure doesn't create entry
- DB transaction rolls back on failure
- Full import flow end-to-end

##### Task 16: Init planning and execution

**Files:**
- Create: `ocaml/lib/plan_init.ml`
- Create: `ocaml/lib/execute_init.ml`
- Create: `ocaml/test/test_init.ml`

**Behavior:** Planning: compare current relative path to computed target path. Classify as index (paths match), move (paths differ), or quarantine (no date).

Execution: for index — insert entry directly. For move — move via worker, insert entry with original_path, clean up empty dirs. For quarantine — move to quarantine dir. Signal handling for graceful stop. Mount health checks between files.

**Testing:**
- Already-correct files get indexed without move
- Needs-move files get relocated
- Failed move rolls back (file returned to original location)
- Empty parent dirs cleaned up after move
- Quarantine moves to correct directory
- Graceful stop on interrupt

##### Task 17: CLI

**Files:**
- Create: `ocaml/bin/main.ml` (expand from scaffold)
- Create: `ocaml/lib/cli.ml`
- Create: `ocaml/test/test_cli.ml`

**Behavior:** Port the Click CLI to cmdliner. Commands in priority order:

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

##### Task 18: Completion and cleanup

**Files:**
- Create: `ocaml/lib/complete.ml`
- Create: `ocaml/test/test_complete.ml`

**Behavior:** After import/init, verify all files are accounted for (imported, duplicate, or quarantined). Delete processed file records from the files table. Report summary.

**Testing:**
- All files accounted for → clean up succeeds
- Unaccounted files → error with details

---

#### Phase 3: Migration and Cutover

##### Task 19: Build integration

**Files:**
- Create: `Makefile` (new, replacing Python Makefile)
- Modify: `pyproject.toml` (remove or archive)

**Behavior:** Single `make build` that builds both the Go worker and the OCaml binary. `make test` runs both test suites. The OCaml binary knows where to find the worker binary (compiled-in path or adjacent-binary discovery). Consider bundling both into a single distribution directory.

##### Task 20: Side-by-side validation

**Behavior:** Run Python trove and OCaml trove against the same test datasets. Compare:
- DB state after discovery, hashing, metadata extraction
- Import plans (same duplicates detected, same path assignments)
- Final library tree structure
- Entry counts and file statuses

This is manual validation, not automated tests. Use existing libraries as test fixtures.

##### Task 21: Cutover

**Behavior:** Delete `src/trove/`, `tests/`, `pyproject.toml`, and Python-related config. Move `worker/` and `ocaml/` to top level (or keep the directory structure if it's clean). Update any documentation. Merge branch to main.

---

#### Dependency Order

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

## Run-centric durable pipeline state

From matter 1f53 (Replace files table with run-centric durable pipeline state), carried in full.

### Why

The current `files` table is carrying two incompatible responsibilities:

- expensive derived state that should survive interruption: discovered size/mtime, hash work, metadata work, target-path planning
- per-run workflow state that is inherently transient: queued, hashing, imported, quarantined, duplicate, failed, interrupted

That mismatch is what made the `library_id` migration messy.

The key problems to solve are:

- partial work may represent hours or days of processing and cannot be dropped casually
- migration of old `files` rows cannot rely on heuristics that silently guess ownership
- kill and timeout behavior must be recoverable and explicit
- resume should be scoped to a concrete run, not inferred from global transient rows
- library ownership should be modeled structurally, not bolted onto scratch rows after the fact

### Decision

Do not continue evolving the current `files` table as the primary runtime model.

Introduce a run-centric model with a clean separation between:

- durable file facts
- durable run metadata
- per-run item state
- file mutation journal / reconciliation state

Keep `libraries` and `entries` as the durable canonical tables. Treat the current `files` table as a legacy source for salvage, not as the long-term state model.

### Goals

- preserve expensive completed work across interruption, retries, and version changes
- make cancellation and timeout recovery explicit and deterministic
- make resume semantics exact at the run level
- eliminate heuristic library reassignment during migration for newly written state
- support future multi-phase execution without overloading one table

### Non-Goals

- perfect automatic recovery of every ambiguous legacy `files` row
- preserving the old schema as the long-term runtime representation
- teaching the Go worker any domain semantics about photos, libraries, duplicates, or quarantine policy

### Target Schema

#### `libraries`

Keep as-is. This remains the durable record of library identity, root path, and config.

#### `entries`

Keep as-is. This remains the durable record of files that belong to a library.

#### `runs`

One row per add/init execution.

Suggested fields:

- `id`
- `library_id`
- `mode` (`add`, `init`, later maybe `verify`, `repair`)
- `source_root`
- `status` (`planned`, `active`, `interrupted`, `completed`, `failed`, `cancelled`)
- `created_at`
- `started_at`
- `updated_at`
- `finished_at`
- `tool_version`
- `worker_protocol_version`
- `cancel_requested`
- `error_summary`

Properties:

- resume is always attached to a concrete run
- multiple historical runs can exist without colliding
- library scoping is structural and no longer inferred from per-file scratch rows

#### `run_items`

One row per file in a run.

Suggested fields:

- `id`
- `run_id`
- `source_path`
- `rel_source_path`
- `source_size`
- `source_mtime`
- `fact_key`
- `status`
- `action`
- `target_path`
- `disposition`
- `error_kind`
- `error_message`
- `discovered_at`
- `hashed_at`
- `planned_at`
- `executed_at`

Suggested status progression:

- `discovered`
- `facts_attached`
- `planned`
- `copying`
- `moving`
- `imported`
- `duplicate`
- `quarantined`
- `missing`
- `failed`
- `unknown`

Properties:

- this is the exact resumable workflow state
- deleting or archiving a run only affects that run
- completion is determined by one run’s items, not by scanning all transient rows globally

#### `file_facts`

Durable cache for expensive derived work.

Suggested fields:

- `id`
- `library_id` nullable or optional depending on whether facts are library-scoped
- `source_path`
- `source_size`
- `source_mtime`
- `identity_key`
- `md5_hash`
- `capture_date`
- `camera_model`
- `normalized_filename`
- `target_path_hint`
- `computed_at`
- `fact_schema_version`

Identity key should be based on a stable source observation tuple, minimally:

- `source_path`
- `source_size`
- `source_mtime`

This is not perfect identity, but it is sufficient as a cache key for resumable work. If stronger identity is needed later, add inode/device where available or a staged content fingerprint.

Properties:

- expensive hashing and metadata work survives interruption and restart
- a new run can reuse facts without redoing the work
- migrations care about durable facts, not fragile in-progress status flags

#### `file_ops`

Journal for mutating filesystem actions.

Suggested fields:

- `id`
- `run_item_id`
- `op_type` (`copy`, `move`, `unlink`, `mkdir`, `rmdir`)
- `src_path`
- `dst_path`
- `expected_hash`
- `status` (`planned`, `started`, `completed`, `failed`, `unknown`)
- `started_at`
- `finished_at`
- `error_kind`
- `error_message`

Properties:

- interrupted mutations become explicit recovery objects
- reconciliation after crash or timeout has concrete state to inspect
- filesystem recovery no longer depends on guessing from half-updated `run_items`

### Runtime Model

#### Worker role

Keep the Go worker stateless and generic.

The worker should only know how to:

- stat
- walk
- hash
- copy
- move
- delete
- check mount health

It should not own library semantics, DB state, dedup policy, or import/init decisions.

#### Timeout / kill strategy

The safe boundary is the worker process, not a goroutine wrapper alone.

Rules:

- risky filesystem requests may still have an internal timeout for response purposes
- if the worker reports `timeout`, assume the process may contain leaked goroutines and kill it immediately
- if the OCaml side gets no response in time, kill the worker immediately
- restart a fresh worker for subsequent operations
- persist run state before and after each mutating step so recovery is deterministic

This means timeout recovery is implemented by process replacement plus DB-backed reconciliation, not by trusting the old in-memory worker state.

### Recovery Semantics

On startup or on explicit resume of a run:

1. Load the most recent `active` or `interrupted` run for the library and mode.
2. Find `run_items` and `file_ops` with `started`, `failed`, or `unknown` status.
3. Reconcile each using filesystem facts:
   - does source still exist?
   - does destination exist?
   - if destination exists, does hash match expected?
   - does an `entries` row already exist?
4. Convert ambiguous in-flight state into one of:
   - `imported`
   - `planned`
   - `failed`
   - `missing`
   - `unknown` requiring manual intervention

The important point is that recovery is driven by journaled intent plus observable disk state, not by vague status strings on one mixed-use table.

### Migration Strategy

#### Principle

Do not try to perfectly and silently reinterpret old `files` rows into the new model.

#### Durable migration

Migrate only durable schema directly:

- preserve `libraries`
- preserve `entries`
- add new `runs`, `run_items`, `file_facts`, `file_ops`

#### Legacy preservation

Rename or retain the old `files` table as `legacy_files_v1`. Do not continue using it as the primary runtime table.

#### Fact salvage

Create a one-time salvage pass that imports reusable data from `legacy_files_v1` into `file_facts` when safe:

- `source_path`
- `file_size`
- `file_modify_date`
- `md5_hash`
- `capture_date`
- `camera_model`
- maybe `target_path` as a hint only

This preserves the expensive work product even if the old workflow state is not trustworthy.

#### Run salvage

Only auto-create a new `run` from legacy rows when ownership is high-confidence. Examples:

- `source_path` is under exactly one library root for old init rows
- there is exactly one library in the DB for old import rows
- a future run header table exists and can be trusted

For ambiguous cases, do not guess. Surface them in a salvage workflow.

### Legacy Commands

Add explicit operator-facing recovery commands:

- `trove legacy-status` shows legacy rows grouped by likely library, source root, confidence, and reusable facts
- `trove salvage <library> --source <path>` creates a new run and imports matching reusable facts / items
- `trove salvage --all-safe` only imports rows whose ownership is unambiguous
- `trove legacy-drop <selection>` discards old legacy rows after user confirmation

This makes ambiguity visible instead of silently encoding guesses into the DB.

### CLI Behavior

#### `add`

- create or resume a run for `(library_id, mode=add, source_root)`
- discover source tree into `run_items`
- attach reusable `file_facts`
- compute missing facts only where needed
- plan actions
- execute actions while journaling `file_ops`
- complete the run when all items have terminal status

#### `init`

Same as `add`, but `mode=init` and the source root is the library root.

#### `status`

Show run-oriented status:

- active runs
- interrupted runs
- counts by run item status
- unresolved recovery items

#### `resume`

Resume a specific interrupted run or the latest interrupted run for a library/mode.

### Rollout Plan

#### Phase 1

Introduce the new schema alongside existing tables. Switch no behavior yet.

#### Phase 2

Write all new executions into `runs`, `run_items`, `file_facts`, and `file_ops`. Keep legacy read-only.

#### Phase 3

Add salvage and reconciliation commands for `legacy_files_v1`. Preserve expensive facts from old rows where safe.

#### Phase 4

Switch CLI status and resume commands to the new run-centric model only. Keep legacy tooling as an explicit recovery path.

#### Phase 5

After confidence is high, retire operational dependence on the legacy table entirely.

### Consequences

Positive:

- expensive partial work is preserved explicitly
- migration logic becomes honest about ambiguity
- library scoping becomes structural instead of heuristic
- resume and recovery become deterministic
- worker timeout handling aligns with durable journaling

Negative:

- schema is larger and more explicit
- implementation takes longer than patching the current `files` model
- a salvage path is required for old state

### Acceptance Criteria

- a run can be interrupted during hashing or file mutation and resumed deterministically
- timeout or worker kill does not require guessing from a mixed transient table
- a newly added library-scoping concept never requires heuristic reassignment for newly written rows
- old expensive work can be salvaged into `file_facts` without pretending every old workflow row is trustworthy
- `status` and `complete` operate on a specific run, not on all transient rows in the database

## Python behaviours the rewrite must reproduce

From matter 905e (Preserve Finder Date Created during import + backfill command), carried in full. Idea f888 carries the same text for triage.

Context for the Go-worker / OCaml-app rewrite (27c2). The Python codebase gained two changes that the rewrite must reproduce so library state stays intact across the cutover.

### Behaviors to preserve

#### 1. `os.utime` on import copies
`copy_file_and_hash` (src/trove/timeout.py) calls `os.utime(dest, ns=(atime, mtime))` after the chunked copy completes, so the destination file inherits the source's atime/mtime. Without this, every import would reset filesystem timestamps to the copy moment. The Go worker that owns file copies must do the equivalent (`os.Chtimes` after a successful copy+verify).

#### 2. Stamp Finder Date Created from `capture_date`
After a successful import, the importer calls `stamp_creation_date(dest_path, capture_date)` (src/trove/fs_dates.py). On macOS this shells out to `/usr/bin/SetFile -d <MM/DD/YYYY HH:MM:SS> <path>`, which the kernel turns into `setattrlist(ATTR_CMN_CRTIME)`. Over SMB this is a single SET_FILE_BASIC_INFO RPC — pure metadata, no data transfer. NFSv3 has no creation-date attribute, so the call silently no-ops there.

The "set creation date" capability is platform-specific. The OCaml app layer should expose this as a worker RPC so non-macOS hosts can omit it without ifdefs scattered through the import path.

### New CLI command: `fix-created-dates`

Backfill for libraries that were imported before this feature existed.

- `trove fix-created-dates <name>` — dry-run preview (default).
- `--apply --yes` — actually stamp.
- `--workers N` — concurrent SetFile invocations (default 8). Network-bound metadata RPCs scale linearly with concurrency.
- `--force` — re-stamp entries that have already been stamped.

The rewrite needs an equivalent backfill command, since the schema marker (below) is set per-entry and a fresh OCaml binary running against an existing DB will see all old entries as unstamped.

### Schema change (relates 1f53)

New table:

```sql
CREATE TABLE entries_creation_date_stamped (
    entry_id INTEGER PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
    stamped_at TEXT NOT NULL
);
```

Migration #3 in src/trove/db.py. Used to skip already-processed entries on repeat backfill runs and to mark entries automatically when the importer stamps them on first import.

If 1f53 replaces the entries table with a run-centric schema, this marker should fold into whatever per-file durable state replaces it (e.g., a `finder_creation_date_stamped_at` column on the new file/run record). Don't carry the side-table forward — it only exists because adding a column to the legacy entries table felt heavier than a join.

### Files touched

- src/trove/fs_dates.py (new) — `set_creation_date`, `stamp_creation_date`
- src/trove/db.py — table, migration, methods
- src/trove/importer.py — call stamp + mark on success
- src/trove/cli.py — `fix-created-dates` command, ThreadPoolExecutor parallelism
- src/trove/timeout.py — `copy_file_and_hash` preserves source mtime via os.utime

### Notes on the SetFile dependency

`/usr/bin/SetFile` is provided by Xcode Command Line Tools and is technically deprecated. The kernel-level replacement is `setattrlist` via ctypes or `NSURL setResourceValue:forKey:NSURLCreationDateKey` via PyObjC. NAS behavior (SMB works, NFSv3 doesn't) is identical regardless of which caller you use — it's determined by the protocol, not the binary. The Go rewrite can use `syscall.Setattrlist` directly and avoid the CLT dependency.
