# OCaml Error-Handling Proposal

## Current state

The OCaml rewrite already has one good foundation:

- `Worker_client` returns typed leaf errors as `(…, Domain.worker_error) result`

But that structure is lost almost immediately:

- `Db` exposes `(…, string) result` everywhere
- `library/common`, `library/import`, `library/init`, and `library/runtime` also use `(…, string) result`
- `bin/main` prints those strings and exits

So the error model is currently:

1. typed worker errors at the bottom
2. flattened strings in the middle
3. ad hoc CLI rendering at the top

That is the main inconsistency to remove.

## Concrete hotspots

### 1. `Worker_client` is typed, but only for one subsystem

- [`ocaml/domain/domain.ml`](../ocaml/domain/domain.ml#L363) defines `worker_error`
- [`ocaml/utils/worker_client.ml`](../ocaml/utils/worker_client.ml#L124) returns `('a, worker_error) result`

This is the right direction.

### 2. Higher layers immediately flatten errors to strings

- [`ocaml/library/common.ml`](../ocaml/library/common.ml#L8) turns worker failures into formatted strings
- [`ocaml/library/runtime.ml`](../ocaml/library/runtime.ml#L145) does the same for verify/status checks
- [`ocaml/library/import.ml`](../ocaml/library/import.ml#L92) and [`ocaml/library/init.ml`](../ocaml/library/init.ml#L99) build `failure_reason` strings inline

Once that happens, the caller can no longer tell whether the failure was:

- a timeout
- a missing path
- a DB conflict
- a retryable filesystem problem
- an invariant failure

### 3. `Db` is stringly typed on failure

- [`ocaml/db/db.mli`](../ocaml/db/db.mli#L9) returns `(…, string) result` for the full DB API
- [`ocaml/db/db.ml`](../ocaml/db/db.ml#L7) constructs raw strings such as `"step error: ..."`, `"bind_text error ..."`, and `"SQLite exec error ..."`

That loses both error class and context structure.

### 4. Some true defects still use exceptions

- [`ocaml/utils/worker_client.ml`](../ocaml/utils/worker_client.ml#L137) uses `failwith` for protocol desync
- [`ocaml/bin/main.ml`](../ocaml/bin/main.ml#L16) uses `failwith` when worker discovery is misconfigured
- [`ocaml/domain/domain.ml`](../ocaml/domain/domain.ml#L6) uses `invalid_arg` for unknown enum values

Those are not necessarily wrong. The problem is that the codebase does not clearly distinguish:

- defects that should raise
- operational failures that should return `Error`

## Recommended model

Use a single typed application error at every layer above the worker boundary.

### 1. Keep `worker_error`

Do not remove `Domain.worker_error`. It is a good leaf error type for the worker protocol and filesystem operations.

### 2. Add `Domain.app_error`

Add something like:

```ocaml
type error_code =
  | Library_not_found
  | Worker_unavailable
  | Worker_timeout
  | Filesystem_not_found
  | Filesystem_permission_denied
  | Db_exec_failed
  | Db_constraint_violation
  | Invalid_state
  | Protocol_desync
  | Missing_capture_date
  | Unable_to_compute_path

type app_error = {
  code : error_code;
  message : string;
  retryable : bool;
  context : (string * string) list;
}
```

Then change all public APIs above the worker layer to:

- `(a, app_error) result`

That includes:

- `Db`
- `library/common`
- `library/import`
- `library/init`
- `library/runtime`

## Error layering

There should be three categories.

### A. Defects

Use exceptions for:

- impossible protocol states
- malformed worker JSON
- enum/schema mismatches that indicate broken code, not bad operator input

Examples:

- protocol desync in `Worker_client.call`
- corrupted internal assumptions

These should remain exceptions.

### B. Operation failures

Use `app_error` for failures that should abort the current command or sub-operation:

- worker unavailable
- worker timeout
- DB write failure
- library not found
- mount/path checks that fail before work can continue

These should not be flattened to strings until the CLI boundary.

### C. Workflow outcomes

Do not model expected per-file outcomes as top-level command errors.

Examples already present in the schema:

- `Disposition.Quarantined`
- `Disposition.Duplicate_in_library`
- `Disposition.Failed`
- `failure_reason`
- `error_text`

For import/init/verify, these are better treated as recorded outcomes, not returned `Error` values, unless the whole run must stop.

## What to change

### 1. Stop returning `string` from `Db`

Change:

- `val create_library : ... -> (library, string) result`

to:

- `val create_library : ... -> (library, Domain.app_error) result`

The DB layer should classify at least:

- execution/bind/step failures
- uniqueness/constraint failures
- lookup-not-found cases when appropriate

Do not return preformatted prose like `"step error: ..."`.

Return:

- `code = Db_exec_failed`
- `message = "sqlite step failed"`
- `context = [("rc", ...); ("sql", ...)]`

### 2. Stop formatting worker failures in `Common`

Current pattern in [`ocaml/library/common.ml`](../ocaml/library/common.ml#L8):

- call `Worker_client`
- convert `worker_error` to string
- return `Error "worker ... failed for ..."`

Instead:

- map `worker_error` to `app_error`
- keep path/context as structured fields

`Common` should be the normalization boundary from subsystem errors to app errors.

### 3. Stop building `failure_reason` as control flow

`import.ml` and `init.ml` currently use strings like:

- `"hash failed: ..."`
- `"mkdir failed: ..."`
- `"copy failed: ..."`
- `"no_usable_date"`

Those strings are doing two different jobs:

- operator/debug prose
- machine state recorded into the DB

Split those roles:

- store a stable code in the model
- derive prose at the CLI/reporting edge

If schema changes are too large right now, keep the existing DB columns but standardize the stored values as canonical codes, not sentence fragments.

### 4. Make run control explicit

Right now, `Error` can mean both:

- “this file failed, but the run continues”
- “the entire command failed”

That is too ambiguous.

For import/init, use a result shape like:

```ocaml
type run_stop =
  | Continue
  | Abort of Domain.app_error
```

Per-file failures should usually:

- be recorded in `run_items` / `file_ops`
- increment counters
- return `Continue`

Only operation-level failures should bubble up as `Abort`.

### 5. Centralize CLI rendering

[`ocaml/bin/main.ml`](../ocaml/bin/main.ml#L109) currently prints command-specific error strings directly.

Replace that with one renderer:

```ocaml
val Cli_error.render : Domain.app_error -> string
val Cli_error.exit_code : Domain.app_error -> int
```

Then every command can do the same thing:

- compute
- render on `Error`
- exit with mapped code

## Suggested `Domain` additions

Minimum useful addition:

```ocaml
type error_code =
  | Worker_timeout
  | Worker_crash
  | Path_not_found
  | Permission_denied
  | Db_exec_failed
  | Db_constraint_violation
  | Library_not_found
  | Invalid_state

type app_error = {
  code : error_code;
  message : string;
  retryable : bool;
  context : (string * string) list;
}
```

Also add helpers:

```ocaml
val app_error_of_worker_error :
  op:string -> path:string option -> worker_error -> app_error

val string_of_error_code : error_code -> string
```

## Migration order

### Phase 1

- Add `Domain.app_error`
- Add conversion from `worker_error -> app_error`
- Change `library/common` to return `app_error`

This gives the biggest payoff first because `Common` is where typed worker errors are currently being destroyed.

### Phase 2

- Change `Db` signatures from `(…, string) result` to `(…, app_error) result`
- Stop constructing raw SQLite failure strings as the public contract

### Phase 3

- Change `library/import`, `library/init`, and `library/runtime` to use `app_error`
- Separate “recorded item failure” from “abort the command”

### Phase 4

- Add a small CLI rendering module
- Remove command-specific string formatting in `bin/main.ml`

## Bottom line

The clean unified approach for the OCaml code is:

- keep `worker_error` as a leaf subsystem error
- introduce `app_error` as the common error type above that boundary
- use exceptions only for defects and invariant violations
- treat per-file failures as recorded workflow outcomes, not top-level command errors

The single highest-value change is to stop flattening typed worker failures into strings in `library/common` and stop exposing plain-string failures from `Db`.
