# Executor

Scope: staged local-command and restricted Docker-container execution with shared lifecycle semantics.

Depends only on domain execution/failure values and Eio process primitives.

| API | Purpose |
|---|---|
| `Local_process` | Spawn, stream output, await, terminate, and reap a local child |
| `Docker_process` | Probe Docker, create restricted containers, stream logs, stop, remove, and clean orphans |
| `Dispatcher` | Select an executor while preserving `start`, `await`, `stop`, and `is_finished` |

Non-responsibilities: HTTP reports, scheduling, privileged mode, host mounts, registry credentials, or persistence.
