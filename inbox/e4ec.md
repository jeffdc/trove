---
kind: decision
text: Recover worker timeouts by killing and restarting the worker process
plan: rewrite
source: matter 1f53 §Timeout / kill strategy; git 9b30961
by: /Users/jeff/dev/trove
created: "2026-11-12T01:03:24Z"
---

Overrides matter 27c2 Task 7 (abandon the goroutine, keep the worker). Built as the worker watchdog in 9b30961.
