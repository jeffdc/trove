# Worker Repo Extraction Plan

## Purpose

Define a concrete plan for moving the Go filesystem worker out of the `trove`
rewrite worktree into its own repository without losing the boundary discipline
already established here.

This plan is about extracting the worker as a reusable subsystem. It is not a
plan to merge `trove` and `reprise`, and it is not a plan to create a broad
shared application framework.

## Current State

The extraction work is now far enough along that `trove` no longer carries the
worker source tree. The current shape is:

- the worker lives in the separate `grove` repo
- the OCaml layer talks to it through `Worker_client`
- `trove` treats the worker as an external binary or sibling checkout
- the worker owns no SQLite logic and no photo-specific rules

That confirms the split is a packaging and ownership boundary, not a broader
application redesign.

Additional progress already made:

- the worker protocol has been written down in
  `docs/worker-protocol-contract.md`
- the worker has been imported into its own repo as `grove`
- `trove` now defaults to consuming a sibling `grove` checkout for worker
  build, test, and runtime lookup
- local-path assumptions have been reduced to sibling-checkout defaults and an
  explicit `GROVE_WORKER_PATH` override

## Extraction Goal

End state:

1. The worker lives in its own repo.
2. `trove` consumes a released worker binary and/or builds it from that repo.
3. The worker repo remains media-agnostic.
4. The OCaml app layer in `trove` owns all domain, DB, and workflow logic.
5. The same worker boundary is available to `reprise` later without dragging in
   `trove` implementation details.

## Non-Goals

- no shared DB schema between `trove` and `reprise`
- no shared domain model for photos and music
- no migration of metadata, planning, or business rules into the worker
- no forced language decision for `reprise` as part of this extraction

## What Actually Needs To Move

The worker repo should contain:

- `cmd/worker`
- `protocol`
- `ops`
- `supervisor`
- integration tests for wire protocol and filesystem behavior
- worker build/test/release automation

The worker repo should not contain:

- OCaml client code
- `trove` CLI code
- `trove` DB schema or migrations
- metadata extraction rules
- path planning logic
- duplicate semantics
- library or archive semantics

## Current Coupling To Resolve

The extraction is straightforward, but a few places are still tightly coupled to
the current in-repo layout.

### 1. Go module identity

Current module path:

- `github.com/jeffdc/grove`

This is now tied to the extracted worker repo. The remaining question is
whether to keep `grove` as the long-term public module/repo name.

### 2. Build and test assumptions

This is now resolved for local development.

The top-level `Makefile` used to assume:

- worker source lives at `worker/`
- worker binary is produced as `grove/worker` in the extracted repo
- OCaml tests depend on building that in-tree binary first

Current state:

- `build` and `test` in `trove` are OCaml-focused again
- `build-worker` and `test-worker` proxy to the sibling `grove` repo
- `WORKER_BIN` defaults to the sibling `grove` binary

### 3. Runtime worker path discovery

This is also resolved for local development.

The OCaml entrypoint no longer uses a hard-coded absolute path. It searches
ancestor directories for a sibling `grove/worker` binary and otherwise requires
an explicit `GROVE_WORKER_PATH`.

### 4. Validation scripts

This has been updated to prefer the sibling `grove` worker binary.

### 5. Protocol ownership

The protocol exists and is versioned, but it should be treated as the primary
cross-repo contract before extraction begins. That means:

- capability list becomes intentional API, not incidental implementation detail
- response shapes should be frozen for the initial extraction
- protocol compatibility rules should be written down explicitly

## Recommended Repository Shape

Proposed worker repo layout:

```text
grove/
  cmd/worker/
  protocol/
  ops/
  supervisor/
  integration_test.go
  go.mod
  Makefile
  README.md
  docs/
    protocol.md
    error-model.md
    release-process.md
```

This repo should produce one main artifact:

- the worker binary

Optionally it may also publish:

- checksummed release archives per platform

It should not publish application SDKs initially. `trove` can vendor or
maintain its own OCaml client until there is a demonstrated need for more.

## Extraction Strategy

The safest path is a staged extraction rather than a one-shot move.

### Phase 1: Freeze The Contract

Before moving code, write down what `trove` relies on today.

Deliverables:

- protocol shape and version note
- list of supported operations
- structured error kinds and meanings
- worker startup behavior, including the hello message
- timeout behavior and kill/restart expectations

The goal is to make the extraction a packaging change first, not an interface
change disguised as a packaging change.

### Phase 2: Remove Local-Path Assumptions In `trove`

Make `trove` consume the worker through one explicit configuration boundary.

Recommended rule:

- `GROVE_WORKER_PATH` is the canonical override
- local dev fallback is acceptable
- hard-coded absolute paths must be removed

Changes needed in `trove`:

- `ocaml/bin/main.ml`
- `ocaml/test/test_worker_client.ml`
- `ocaml/test/test_init.ml`
- `scripts/validate_side_by_side.sh`
- top-level `Makefile`

After this phase, `trove` should not care whether the worker source is
in-repo, in a sibling checkout, or downloaded as a release artifact.

Status:

- complete

### Phase 3: Create The Worker Repo

Create the new repo and copy the worker package structure over with history
preserved if practical.

Minimum contents:

- all Go worker source
- tests
- README explaining scope and non-goals
- protocol docs
- release/build instructions

Open decision:

- whether to preserve file history via `git filter-repo` / subtree split, or
  start a fresh repo with an initial import commit

Preserving history is preferable if it is not operationally painful.

Status:

- complete as a fresh import into `grove`
- history preservation was deferred in favor of a clean first split

### Phase 4: Repoint `trove` To The Extracted Worker

At this stage, `trove` should stop treating `worker/` as a source directory it
owns.

Recommended options, in order of simplicity:

1. Consume a built binary through `GROVE_WORKER_PATH` in development and CI.
2. Add a `make fetch-worker` or equivalent to place a known worker binary in a
   local tool cache.
3. Keep a sibling-checkout development mode for local iteration.

Avoid trying to solve every distribution problem at once. For the rewrite,
explicit binary path configuration is enough.

Status:

- complete for sibling-checkout development
- still pending for CI/release-driven consumption

### Phase 5: Decide Long-Term Consumption Model

Once the split is stable, choose how `trove` should depend on the worker long
term.

Viable models:

- release artifact download during setup
- sibling checkout in development
- submodule or subtree
- package-manager based installation if you later want broader distribution

For now, the simplest acceptable approach is:

- dev: point `GROVE_WORKER_PATH` at a local built binary
- CI: build worker from its repo and pass the path in explicitly

Given the current state, a slightly better short-term default is:

- dev: use the sibling `grove` checkout automatically
- override: use `GROVE_WORKER_PATH` explicitly when needed
- CI: build worker from the `grove` repo and pass the path in explicitly

## `trove` Changes Expected After Extraction

`trove` should still own:

- worker process lifecycle from the app side
- worker-path discovery policy
- mapping worker errors into app/domain errors
- all DB mutations and workflow transitions

`trove` should stop owning:

- worker source tree
- worker Go module metadata
- worker internal tests

That ownership cleanup is now complete in the worktree: `trove` no longer
carries the worker source tree, Go module metadata, or worker internal tests.

## `reprise` Preparation Benefit

Pulling the worker into its own repo now helps `reprise` later in two ways:

1. It prevents the worker from accreting photo-specific assumptions.
2. It lets `reprise` adopt the same filesystem boundary independently of its
   eventual application language choice.

That means this extraction should happen before any attempt to make `reprise`
depend on the worker directly.

## Risks

### Risk: Interface churn during extraction

If protocol changes happen at the same time as repo extraction, failures will be
harder to reason about.

Mitigation:

- freeze the protocol first
- separate "move" commits from "behavior change" commits

### Risk: Test fragility from binary-path assumptions

Current tests assume the worker binary is in this repo layout.

Mitigation:

- centralize worker-path resolution
- require an explicit env var in CI where appropriate

### Risk: Losing easy local iteration

Moving the worker out can make iteration slower if every change requires manual
cross-repo bookkeeping.

Mitigation:

- support sibling-checkout development
- keep the runtime boundary path-based and explicit

### Risk: Expanding the worker scope after extraction

A separate repo can attract unrelated generic ideas and become a dumping ground.

Mitigation:

- keep a strong README and protocol docs
- explicitly reject domain logic in the worker repo

## Open Decisions

- final worker repo name
- final Go module path
- whether `trove` will keep a convenience wrapper for building/fetching the
  worker
- whether the worker repo should ship platform release artifacts immediately or
  later
- whether protocol compatibility will be strict by version only or by version
  plus capability negotiation

## Concrete Next Steps

1. Write a short protocol contract doc from the current implementation.
2. Remove hard-coded absolute worker paths from OCaml tests and entrypoints.
3. Refactor the `trove` Makefile so the worker path is an input, not just an
   in-repo output.
4. Choose the worker repo name and Go module path.
5. Create the new repo and import the current worker tree.
6. Repoint `trove` dev/test scripts to the external worker binary.
7. Only then start changing behavior across the boundary again.
