# Error-Handling Unification

## Why this is needed

Error-handling is currently split across three different styles:

- Python runtime code raises generic exceptions for both operator-facing failures and programmer bugs.
- Python pipeline stages also persist ad hoc string status and `error_message` values into the database.
- The OCaml rewrite has started using `result` and a typed `worker_error`, but most higher-level failures are still flattened into plain strings.

That makes it hard to answer basic questions consistently:

- Is this failure expected or a bug?
- Should the current file be skipped, retried, or should the whole command stop?
- What should be persisted to the DB?
- What should be logged?
- What should the CLI print, and with which exit code?

## Current pain points

### 1. Expected operational failures and programmer invariants are both raised as generic exceptions

- [`src/trove/importer.py`](../src/trove/importer.py#L94) raises generic `RuntimeError` for missing `target_path` / `md5_hash`, then catches broad `Exception` and increments an error counter.
- [`src/trove/metadata.py`](../src/trove/metadata.py#L102) raises `RuntimeError` for missing `exiftool`, which is an operator/environment issue, not a bug.
- [`src/trove/pipeline.py`](../src/trove/pipeline.py#L495) raises `RuntimeError` when path resolution exhausts attempts, again without a stable code.

These failures all look the same to callers even though they should be handled differently.

### 2. File-level issues are encoded as free-form strings in mutable DB state

- [`src/trove/pipeline.py`](../src/trove/pipeline.py#L164) maps hash failures to `status="quarantined"` and `error_message="hash_failed"`.
- [`src/trove/pipeline.py`](../src/trove/pipeline.py#L219) maps missing dates to `error_message="no_date"`.
- [`src/trove/initialize.py`](../src/trove/initialize.py#L235) stores `source_missing` / `source_missing_dest_mismatch`.

Those strings are acting as error codes, but the schema and API still call them `error_message`, which invites drift between machine-readable state and user-facing text.

### 3. The DB layer accepts arbitrary status strings

- [`src/trove/db.py`](../src/trove/db.py#L493) validates column names in `update_file`, but not allowed values for `status`.
- [`src/trove/db.py`](../src/trove/db.py#L512) and tests treat status as an unconstrained string.

This means the workflow state machine exists only by convention.

### 4. UI concerns are mixed into execution code

- [`src/trove/initialize.py`](../src/trove/initialize.py#L328) contains `_handle_error`, which translates exceptions into user-facing reasons and stop/continue policy.
- [`src/trove/cli.py`](../src/trove/cli.py#L356) contains custom mount retry messaging and local return-value conventions.
- [`src/trove/cli.py`](../src/trove/cli.py#L735) separately translates `ValueError` into an exit code for `verify`.

The same failure class can therefore render differently depending on which command hit it.

### 5. Logging policy is inconsistent

- Import logs and swallows broad exceptions in [`src/trove/importer.py`](../src/trove/importer.py#L172).
- Initialize sometimes logs, sometimes converts to callback messages, and sometimes stops immediately in [`src/trove/initialize.py`](../src/trove/initialize.py#L328).

Lower layers are deciding both business behavior and observability policy.

### 6. The OCaml rewrite has a better start, but only for worker failures

- [`ocaml/domain/domain.ml`](../ocaml/domain/domain.ml#L363) defines a typed `worker_error`.
- [`ocaml/utils/worker_client.ml`](../ocaml/utils/worker_client.ml#L124) returns `('a, worker_error) result` from worker calls.
- But higher-level helpers such as [`ocaml/library/common.ml`](../ocaml/library/common.ml#L8) and most DB APIs in [`ocaml/db/db.mli`](../ocaml/db/db.mli#L9) flatten failures to `(…, string) result`.

So the rewrite already proves typed errors are workable, but the typing stops too early.

## Recommended model

Use one error model with three layers:

1. **Issue**
   Expected, file- or record-scoped problem that should be persisted and counted.
   Examples: `missing_capture_date`, `hash_failed`, `source_missing`, `duplicate_in_library`.

2. **Operation error**
   Command-scoped failure that may abort the current operation.
   Examples: library root unavailable, exiftool missing, worker timeout, DB write failure.

3. **Defect**
   Programmer bug or broken invariant.
   Examples: “file marked importable without hash”, protocol desync, impossible state transitions.

The rule is:

- **Issues** are data, not exceptions.
- **Operation errors** are structured values propagated to the boundary.
- **Defects** raise immediately and should fail fast.

## Canonical error shape

Both Python and OCaml should use the same conceptual fields:

- `code`: stable machine-readable identifier
- `kind`: `issue | operation | defect`
- `message`: default human-readable summary
- `retryable`: whether retry is a meaningful option
- `context`: structured key/value detail for logs and reports
- `cause`: optional wrapped lower-level error

Suggested canonical codes:

- Input/config: `library_not_found`, `source_not_found`, `source_not_directory`
- Environment: `mount_unavailable`, `mount_timeout`, `tool_missing.exiftool`
- Filesystem: `permission_denied`, `cross_device`, `file_missing`, `hash_mismatch`
- Metadata/pipeline: `metadata_missing_date`, `metadata_parse_failed`, `path_conflict_exhausted`
- Persistence: `db_unique_violation`, `db_write_failed`, `db_protocol_failed`
- Internal: `invalid_state`, `protocol_desync`, `unexpected_worker_exit`

## Python guidance

### 1. Add a typed app error module

Create something like `src/trove/errors.py`:

```python
from dataclasses import dataclass, field
from typing import Any

@dataclass(frozen=True)
class TroveError(Exception):
    code: str
    message: str
    retryable: bool = False
    context: dict[str, Any] = field(default_factory=dict)
    exit_code: int = 1

class TroveDefect(RuntimeError):
    pass

@dataclass(frozen=True)
class FileIssue:
    code: str
    message: str
    context: dict[str, Any] = field(default_factory=dict)
```

The important distinction is:

- `TroveError`: operational failure, okay to show to a user
- `FileIssue`: expected per-item outcome, persistable
- `TroveDefect`: invariant break, not expected to recover

### 2. Stop using `RuntimeError` / `ValueError` for operator-facing failures

Examples:

- missing `exiftool` should become `TroveError(code="tool_missing.exiftool", ...)`
- inaccessible library root should become `TroveError(code="mount_unavailable", ...)`
- path conflict exhaustion should become `TroveDefect` or a dedicated `invalid_state` if it should be impossible

### 3. Return issues from pipeline stages instead of burying them in exception handling

Current pipeline functions mix processing with DB mutation. A cleaner contract is:

- pure/service layer returns `StageResult`
- caller decides persistence/logging

For example:

```python
@dataclass(frozen=True)
class StageResult[T]:
    ok: list[T]
    issues: list[FileIssue]
```

Then `hash_files` returns:

- hashed ids in `ok`
- `FileIssue(code="hash_failed", ...)` for files that could not be processed

The orchestration layer can then persist those issues via one shared adapter.

### 4. Separate persisted codes from rendered messages

Rename the current notion of `error_message` to:

- `error_code TEXT`
- `error_detail_json TEXT NULL`

If schema churn is undesirable right now, keep the existing column but treat it as `error_code` in code and documentation. Do not store prose there.

### 5. Centralize CLI translation

Add one function that maps a `TroveError` to:

- stderr message
- optional recovery prompt
- exit code

For example:

```python
def render_cli_error(err: TroveError) -> tuple[str, int]:
    ...
```

That removes ad hoc `except ValueError`, `except TimeoutError`, and custom local message generation from individual commands.

### 6. Log once, at boundaries

Guideline:

- lower layers should create structured errors/issues
- command/orchestration boundaries decide whether to log
- avoid both logging and re-raising the same failure unless an extra layer adds real context

That prevents duplicate “error happened” messages with inconsistent wording.

## OCaml guidance

The OCaml rewrite should extend its current direction, not replace it.

### 1. Introduce an application-level error type

`Domain.worker_error` is useful but too narrow. Add something like:

```ocaml
type app_error = {
  code : string;
  message : string;
  retryable : bool;
  context : (string * string) list;
}
```

Then move high-level APIs from `(a, string) result` to `(a, app_error) result`.

### 2. Keep variant types for leaf subsystems

Keep `worker_error` as a subsystem-specific error, but wrap it into `app_error` at the worker boundary.

That preserves precision without letting stringly-typed errors leak upward.

### 3. Reserve exceptions for defects

Cases such as protocol desync in [`ocaml/utils/worker_client.ml`](../ocaml/utils/worker_client.ml#L136) should remain hard failures, because they indicate broken assumptions, not user-recoverable conditions.

### 4. Persist codes, not prose

The rewrite schema already distinguishes workflow state and `error_text`. Keep the free text only for operator notes or debugging detail. Stable machine behavior should key off canonical codes stored separately or encoded in a dedicated field.

## Boundary rules

These rules should apply across both implementations.

### Domain/service layers

- Must not print to stderr/stdout
- Must not choose CLI exit codes
- Should not log except for rare low-level diagnostics
- Must return typed issues or typed operation errors

### Persistence layer

- Must validate workflow state transitions
- Must reject unknown status/error codes
- Must not invent user-facing prose

### CLI / command handlers

- May render human-readable messages
- May ask the user whether to retry/abort
- Must map operation errors to exit codes in one place
- Must summarize persisted issues consistently

## Suggested migration sequence

### Phase 1: Normalize without major behavior change

- Add `src/trove/errors.py`
- Replace operator-facing `RuntimeError` / `ValueError` with `TroveError`
- Add a shared CLI renderer
- Declare a canonical list of issue codes and operation codes

### Phase 2: Make file issues explicit

- Introduce `FileIssue`
- Convert `pipeline.py`, `initialize.py`, and `importer.py` to return issues instead of inferring policy from broad `except Exception`
- Treat DB `error_message` as a code field everywhere

### Phase 3: Enforce state machine correctness

- Add Python enums or `Literal` types for file status and issue codes
- Validate allowed `status` values in `StateDB.update_file`
- Add explicit transition helpers instead of open-ended `update_file(status="...")`

### Phase 4: Align the OCaml rewrite

- Add `app_error`
- Migrate `(…, string) result` APIs in `Db`, `library/common`, `library/import`, `library/init`, and `runtime`
- Keep `worker_error` as a wrapped leaf error, not the top-level app contract

## Concrete design choices

### What should still use exceptions?

- Broken invariants
- Corrupt internal protocol state
- Programmer mistakes
- Truly unrecoverable library bugs

### What should not use exceptions?

- A file missing metadata
- A source file disappearing mid-run
- A mount timing out during one file operation
- A duplicate being skipped

Those are workflow outcomes and should be modeled explicitly.

## What “good” looks like

When a file cannot be hashed:

1. filesystem helper returns a typed operation error or leaf worker error
2. pipeline converts that into `FileIssue(code="hash_failed", context=...)`
3. orchestration persists `error_code="hash_failed"` and increments counters
4. CLI prints one consistent summary
5. logs include the same stable code and context

When the library root is unavailable:

1. mount check returns `TroveError(code="mount_unavailable", retryable=True, ...)`
2. CLI renders the message and retry prompt through one shared path
3. exit code is chosen centrally if the user aborts

When an invariant is broken:

1. code raises `TroveDefect("importable file missing md5")`
2. command fails fast
3. stack trace and logs clearly identify a defect, not an operator mistake

## Recommendation

The cleanest unified approach for this codebase is:

- **typed issues for expected file-level problems**
- **typed operation errors for command-level failures**
- **exceptions only for defects**

That matches the rewrite’s direction, reduces ad hoc branching in the Python CLI, and gives the database a stable machine-readable failure vocabulary instead of informal string messages.
