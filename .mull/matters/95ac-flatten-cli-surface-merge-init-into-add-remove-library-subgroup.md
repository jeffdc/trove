---
status: done
created: 2026-04-12
updated: 2026-04-12
relates: [7053]
---

# Flatten CLI surface — merge init into add, remove library subgroup

## Design

**Current:** `trove library create|list|delete|init|relocate` subgroup + `trove add SOURCE --library NAME` + `trove verify|duplicates|status|hash --library NAME`

**New:** All top-level. Library name is first positional arg. `init` removed — `add` handles both copy (external source) and move (files already in library).

```
trove create NAME PATH
trove delete NAME
trove list
trove relocate NAME PATH
trove add NAME [PATH]         # PATH optional — omit to resume/maintain
trove status NAME
trove verify NAME
trove duplicates NAME
trove hash NAME
trove completions
```

**`add` behavior:**
- With PATH: discover files, then full pipeline
- Without PATH: skip discovery, process queued files in DB
- Copy vs move: resolve both PATH and library.location to real paths. If PATH is inside library → move (init logic). If outside → copy (import logic).

**`create` behavior:**
- Register library in DB, create dir if needed
- If dir has files, prompt "Found files here. Add them now?"
- If yes, delegate to `add` logic (which will use move mode since source is library path)

**Removed:**
- `library` subgroup
- `library init` command
- `resolve_library()` interactive picker — name is always required
- `--library` option pattern

## Implementation Plan

**Goal:** Restructure the CLI surface so all commands are top-level, library name is always a positional arg, and `add` replaces both the old `add` and `library init`.

**Architecture:** Pure CLI rewiring. The pipeline, importer, and initialize modules stay as-is. We change how cli.py calls them. cli_helpers.py shrinks to a simple lookup.

**Tech stack:** Click, existing pipeline/importer/initialize modules.

### Task 1: Replace resolve_library with simple lookup

**Files:**
- Modify: `src/trove/cli_helpers.py` (gut the interactive logic)
- Test: `tests/test_cli.py` (existing tests will be updated in later tasks)

**Behavior:**
`resolve_library(db, name)` becomes a plain lookup: call `db.get_library(name)`, return it or None. Remove the interactive picker, auto-select-single-library, and create-on-the-fly flows. The function still echoes an error if not found — callers check for None.

No test changes yet — tests are updated alongside command signature changes in Task 2.

### Task 2: Flatten CLI structure and change signatures

**Files:**
- Modify: `src/trove/cli.py` (remove `library` group, promote all commands, change signatures)
- Modify: `tests/test_cli.py` (update all invocations)

**Behavior:**
- Remove `@cli.group() library()` and all `@library.command()` decorators
- Each command becomes `@cli.command()` directly
- `create`, `delete`, `relocate`, `init` (temporarily kept): NAME is first positional arg (was already)
- `verify`, `duplicates`, `status`, `hash`: NAME becomes required first positional arg, remove `--library` option
- `add`: signature changes to `add(name, path=None, yes=False)` — NAME first, PATH optional positional
- `list`: no NAME arg (lists all libraries)
- All commands call `resolve_library(db, name)` directly instead of passing `library_name`

**Testing:**
Update every test invocation:
- `["library", "create", ...]` → `["create", ...]`
- `["library", "list"]` → `["list"]`
- `["library", "delete", ...]` → `["delete", ...]`
- `["library", "init", ...]` → `["init", ...]` (temporary, removed in Task 3)
- `["add", source, "--library", name]` → `["add", name, source]`
- `["verify", "--library", name]` → `["verify", name]`
- `["duplicates", "--library", name]` → `["duplicates", name]`
- `["status", "--library", name]` → `["status", name]`

All existing tests should pass with updated invocations. No new behavior in this task.

### Task 3: Merge init into add

**Files:**
- Modify: `src/trove/cli.py` (add command gains init behavior, init command removed)
- Modify: `tests/test_cli.py` (remove TestLibraryInit, add new tests)

**Behavior:**
The `add` command detects copy vs move mode:
1. If PATH provided: resolve both PATH and `lib.location` to real paths (`Path.resolve()`)
2. If resolved PATH is inside resolved library location → **move mode**: use `plan_initialize` + `execute_initialize`
3. If resolved PATH is outside → **copy mode**: use `classify_for_import` + `execute_import` (existing behavior)
4. If no PATH → **resume mode**: query files table for any files matching this library's location prefix. If found, run them through remaining pipeline steps. If nothing queued, report "Nothing to process."

Resume mode (no PATH) checks DB state and picks up where things left off:
- `status=discovered` → hash, extract, compute paths, classify, execute
- `status=hashed`, no capture_date → extract, compute paths, classify, execute
- `status=hashed`, has capture_date, no target_path → compute paths, classify, execute
- `status=hashed`, has target_path → classify, execute

Remove the `library_init` command entirely.

**Testing:**
- Remove `TestLibraryInit` class
- Add to `TestAddCommand`:
  - `test_add_library_path_uses_move_mode` — add with library's own path triggers init logic (file gets moved/indexed, not copied)
  - `test_add_external_path_uses_copy_mode` — add with external path copies (existing behavior, rename existing test)
  - `test_add_no_path_resumes` — add without path processes queued files
  - `test_add_no_path_nothing_queued` — add without path when DB is clean reports nothing to do
  - `test_add_symlinked_library_path_detected` — symlinked paths correctly detected as inside library

**Notes:**
The resume logic currently lives inline in the `add` command (the "stale_discovered / stale_hashed" block). For the no-PATH case, this same logic runs but without the initial discovery step. Factor the resume logic into a helper if it gets unwieldy, but don't over-abstract.

### Task 4: Simplify create

**Files:**
- Modify: `src/trove/cli.py` (simplify create command)
- Modify: `tests/test_cli.py` (update TestLibraryCreate)

**Behavior:**
`create` becomes:
1. Register library in DB
2. Create directory if it doesn't exist → done, no prompts
3. If directory exists and has files: prompt "Found files here. Add them now? [y/n]"
4. If yes: run the same add logic (with library's own path, so move mode)
5. If no: done

Remove the separate "scan to count files?" prompt — it was two prompts for one decision. One prompt is enough.

**Testing:**
- `test_create_with_args` — create with name+path, no files → no prompt
- `test_create_new_directory` — creates dir, no prompts
- `test_create_empty_directory` — existing empty dir, no prompts
- `test_create_with_files_decline` — files exist, user declines add
- `test_create_with_files_accept` — files exist, user accepts, files get processed (mock metadata)
- `test_create_duplicate` — duplicate name error
- Remove: `test_create_scan_yes_shows_count`, `test_create_scan_no_skips_to_init_prompt` (two-prompt flow gone)
