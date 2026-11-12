Interrupted imports become durable, resumable runs, and every destructive action needs explicit authorization.

Why: an external import timed out before its first copy. The rerun planned zero files and reported everything accounted for. Resume matched prior work by raw path prefix, and empty-plan and abort paths deleted transient rows globally by status.

The picture: each add or init run is an `import_runs` row, and transient `files` rows belong to one run. Planning, execution, completion and cleanup work by run ID. Copies are strictly additive (exclusive create, failed copies preserved). A timeout marks the file and run failed and exits non-zero. A rerun offers Resume or Abort.

Done when the spec's required behavioural coverage passes in isolated tests, along with the full suite and static checks.

Why the order: the schema and the non-destructive copy primitives depend on nothing. The pipeline, completion and executor consume them. CLI orchestration and initialize runs consume all of that. The contract check comes last.

Design: `docs/superpowers/specs/2026-08-09-durable-import-recovery-safety-design.md`. Tasks and interfaces: `docs/superpowers/plans/2026-08-09-durable-import-recovery-safety.md`.

Constraint for every item: never run the installed `trove` or touch the live database, library or sources. Tests use `tmp_path` and temporary SQLite only.
