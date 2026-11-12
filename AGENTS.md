# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Trove is a CLI tool for photo/video deduplication and organization. It consolidates media from multiple sources (local folders, USB drives, NAS volumes) into organized, deduplicated libraries using MD5 hashing for dedup and EXIF metadata for organization.

## Python Environment

Uses a `.venv` at the project root (Python 3.14.3 via Homebrew, not tracked in git).

```bash
source .venv/bin/activate
make install   # editable install with dev deps
```

To recreate if missing:
```bash
/opt/homebrew/opt/python@3.14/bin/python3.14 -m venv .venv
source .venv/bin/activate
make install
```

## Commands

```bash
make install     # pip install -e ".[dev]" — install with dev deps
make test        # pytest tests/ -v
make check       # ruff check + mypy
make format      # ruff format
make fix         # ruff check --fix (auto-fix lint)
make all         # format + check + test
make ci          # check + test (no format)
```

Run a single test:
```bash
python -m pytest tests/test_pipeline.py -v
python -m pytest tests/test_db.py::test_specific_function -v
```

## Development Workflow

Install editably first (`make install`), then run `trove` directly:
```bash
trove --help
trove create my-library ~/Photos
trove add my-library /path/to/source
trove verify my-library
```

Use `--db /tmp/test.db` to point at a throwaway database during manual testing:
```bash
trove --db /tmp/dev.db create test ~/Photos/test-lib
trove --db /tmp/dev.db add test /some/source
```

## Architecture

### Three-stage pipeline

```
scan.py          discover_files()         → find media files on disk
pipeline.py      discover_and_persist()   → insert FileRecords (status=discovered)
                 hash_files()             → compute MD5, update DB (status=hashed)
                 extract_metadata()       → exiftool → capture_date, camera_model
                 compute_paths()          → build target relative paths
importer.py      plan_import() / execute_import()    → copy to library
initialize.py    plan_initialize() / execute_initialize()  → in-place reorg
complete.py      plan_complete() / execute_complete()      → verify + cleanup
```

`trove add` detects whether the source is inside the library (→ initialize) or external (→ import), or absent (→ resume interrupted run).

### Database (db.py)

SQLite at `~/.trove/state.db`. Three tables:

- **libraries** — named collections at fixed paths, with JSON config
- **entries** — permanent record of files belonging to a library (md5, path, date, camera)
- **files** — transient working state during a pipeline run; lifecycle: `discovered → hashed → imported` (or `duplicate`, `quarantined`, `missing`)

### Key design patterns

- **Plan-execute separation**: all `plan_*` functions build a decision tree; `execute_*` applies it. Read plans before touching files.
- **Immutable state objects**: frozen dataclasses throughout (`LibraryRecord`, `FileRecord`, `EntryRecord`, `FileMetadata`).
- **Hash-based dedup**: MD5 for byte-identical detection. Dedup runs in two passes — batch dedup within the incoming scan, then library dedup against existing entries.
- **EXIF fallback chain**: `DateTimeOriginal → CreateDate → ModifyDate`, with year sanity check; falls back to filesystem mtime; quarantines files with no usable date.
- **Incremental processing**: files tracked by `(source_path, file_size, mtime)` — unchanged files are skipped on resume.

### Config (config.py)

`LibraryConfig` is a frozen dataclass controlling organization structure (`%Y/%m` by default), supported extensions (photos/videos/raw), exclude patterns, and quarantine behavior. Stored as JSON in the `libraries` table.

### Linting

Ruff with line length 120. Rules: E, F, I (isort), UP, B, C4. MyPy on Python 3.10+ with `warn_return_any`.

## This project in mull

- **Plans.** `import-recovery` (Durable import recovery and safety): the Python work on `main`, in four phases, Run state and safe copy → Run-scoped pipeline → Run orchestration → Contract verification. Its design and task plan are under `docs/superpowers/`. `rewrite` (Go worker + OCaml rewrite): still shaping, so it takes captures and questions only; its code and most of its docs live on branch `go-ocaml-rewrite`. Small, unrelated work is unplanned (`--plan none`).
- **Hard checks.** `mull done` runs `make done-checks` (ruff, mypy and pytest via `make check test`). Activate `.venv` first: the Makefile calls `ruff`, `mypy` and `python` from `PATH`.
- **Layers.** `cli`: `src/trove/cli.py`, `src/trove/cli_helpers.py`, `src/trove/progress.py`, `src/trove/report.py`. `core`: `src/trove/**`. `tests`: `tests/**`. `docs`: `docs/**`, `trove-spec.md`, `AGENTS.md`. `ocaml`: `ocaml/**`, `scripts/**` (rewrite branch).
- **Old matters.** `.mull/` holds the pre-mull matters as read-only history. Don't edit it; the old binary is `mull1`.

## Working with mull

This project's plans, work items, backlog and open questions live in **mull**: a CLI whose data sits on the `mull` git branch. Use only the CLI. Never read or edit mull's data or the `mull` branch directly.

- **Output.** Every command prints JSON, and errors are `{"code", "error"}` on stderr. `mull guide json` documents the shapes and error codes.
- **Batch.** To write more than a couple of records, use `mull batch` (JSON Lines on stdin, all or nothing) instead of a shell loop.
- **The record.** Plans hold phases, and phases hold items. An item goes captured → committed → active → in review → done, or is dropped. Captured items (bugs and ideas) are the backlog: they aren't work until the human commits them. Done means reviewed.

1. **Start of session:** run `mull context --item <id>`, or `mull context` if you have no item yet.
   - Read the decisions it lists, and don't re-decide anything the log already settles.
   - Read the item's `docs` and its `phase_doc` (the phase's design and when it's done). Docs hold intent only. Status comes from mull, never from a doc.
2. **One item per session.**
   - Claim it with `mull start <id>`. Your item is committed work (`mull ready`), or a captured item the human wants done now: starting commits it.
   - Work on a branch named `<id>-<short-name>`.
   - End every commit message with the trailer line `Mull: <id>`.
3. **Capture as you go,** one line each, without waiting for the end. Anyone captures; only the human commits.
   - `mull decided "<what you chose>" --item <id> --detail "<why, one line>"`: any choice the human didn't make for you.
   - `mull ask "<question>" --item <id>`: anything you need from the human. Keep working on whatever isn't blocked.
   - `mull bug "<what>" --source "item <id>"`: anything out of scope that's wrong (a bug, an inconsistency, half-finished work, an assumption you made).
   - `mull idea "<title>" --detail "<short note>" --source "<where>"`: a possibility worth keeping that isn't work yet, whether the human raised it or you noticed it. Keep to ideas worth the human's time.
   - Bugs and ideas go to the backlog, not to the human's inbox: that's only questions, decisions and reviews. The human goes through the backlog in triage (`mull guide triage`). Add `--plan` or `--phase` to a capture if it belongs to one, and `--category` if it helps.
   - **Feedback the human hands over for later** (something to fix, change or revisit, but not now):
     ```
     mull bug "<the feedback, in the human's words>" --source "human, <date or context>"
     ```
     - File it when it's given. Don't hold it for the end of the session.
     - Don't act on it in your current work unless the human says to, and never drop it.
     - It's feedback if it judges or asks to change existing work. It's an idea if it's a possibility that isn't work yet. If you can't tell which, ask the human.
4. **Don't change plans or phases (or their docs), and don't add items,** unless the human asks. Propose changes with `mull ask`.
   - Only the human creates and agrees a plan (`mull plan new ... --on-request`, `mull plan agree <slug> --on-request`). A plan that's still shaping takes captures and questions, but no phases or committed work.
   - Read a plan's or phase's doc with `mull plan doc <slug>` or `mull phase doc <id>`.
   - Order exists only between phases (`mull need <phase> <phase>`). Items inside a phase are unordered.
   - Never commit a captured item (`mull commit <id>`) on your own. When the human tells you to, add `--on-request`, with `--plan`, `--phase` or `--plan none` if they say where it goes. Retag a capture (`mull set <id> plan|phase <value>`) only on their word too.
5. **Finish only with `mull done`:**
   ```
   mull done <id> --summary "<what changed and how it fits>" --tour "<steps, or none>" --design -
   ```
   - Give the design notes on stdin: how you built it and why (the approach, the shape of the code, what you rejected). They're required, and "none" isn't accepted.
   - Give the tour inline, one step per line: what to click and what the human should see. Write "none" if no UI changed. Only one of `--summary`, `--tour` and `--design` can read stdin.
   - `done` runs the project's hard checks itself. If they fail, fix the problem and run `done` again, or run `mull release <id>` and say why.
   - After `done` the item is in review. It's done only once its review is accepted. Never say an item is done unless `mull done` succeeded.
6. **Hand over:**
   - Show the human (or the supervisor) the report from `mull report <id>`, and the tour. The review carries the decisions you recorded with `--item`, and accepting it ratifies them.
   - Run `mull accept <id> --on-request` only when the human tells you to. If they decide one of those decisions differently, run `mull decide <decision-id> "<their decision>" --on-request` first.
   - Settle any other inbox entry only on the human's explicit instruction, also with `--on-request`.
7. **Run `mull sync`** after `done` and at the end of the session.
