Replace the Python trove with two layers: the media-agnostic Go worker (`grove`, its own repo) for protected filesystem operations, and an OCaml application that owns the domain, SQLite schema, migration and CLI.

The OCaml app targets a new library-centric schema: content-identified file objects, explicit library membership and placements, run-scoped items and a file-ops journal, instead of the old `files` table. It carries forward matter 1f53's run-centric model. A one-way `migrate-db` moves the Python database into it, preserving expensive completed work and reporting ambiguity instead of guessing.

The rewrite must also reproduce what Python gained since: source mtime preserved on copy, Finder Date Created stamped from capture date, and a backfill command (matter 905e).

Done when normal ingest and inspection run in OCaml on a migrated production database, with no fallback to Python.

Order (from operationalization-plan.md): trust the migration first; then a read-only target runtime (list, status, verify); then target-schema import; then cutover; then maintenance and reconciliation.

Docs on branch go-ocaml-rewrite: docs/ocaml-reshape-plan.md, docs/implementation-plan.md, docs/library-centric-domain-model.md, docs/target-schema.md, docs/migration-matrix.md, docs/migration-layer-api.md, docs/worker-protocol-contract.md, and (uncommitted) docs/operationalization-plan.md and docs/disk-reconciliation-requirements.md. Background on main: docs/go-port-plan.md, docs/generic-go-worker.md, docs/ocaml-layer-on-worker.md, docs/intake-algorithm.md, docs/cross-project-architecture.md.
