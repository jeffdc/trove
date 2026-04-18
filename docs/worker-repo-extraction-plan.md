# Worker Repo Extraction Plan

This document now serves as a short status record for the worker extraction.

The detailed protocol contract lives in `docs/worker-protocol-contract.md`.

## Status

The extraction is effectively complete for local development:

- the worker lives in the separate `grove` repo
- `trove` no longer carries the worker source tree
- `trove` consumes the worker as an external binary or sibling checkout
- the worker protocol has been documented and expanded to cover current known
  needs

## What Was Decided

- the worker remains media-agnostic
- the worker owns protected filesystem operations, not application rules
- `trove` owns domain logic, DB schema, workflow state, and migration logic
- `reprise` may reuse the worker boundary later without sharing application
  schema or domain model

## What Is Still Open

The remaining extraction-adjacent work is operational rather than architectural:

- decide the long-term public `grove` repo/module naming if desired
- decide CI and release consumption strategy for `trove`
- optionally add a fetch or release-artifact path instead of relying only on a
  sibling checkout in development

## Current Recommendation

For now:

- local development uses a sibling `grove` checkout
- explicit worker path override remains `GROVE_WORKER_PATH`
- CI should build `grove` explicitly and pass the binary path into `trove`

## Related Docs

- `docs/worker-protocol-contract.md`
- `docs/implementation-plan.md`
