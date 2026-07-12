# Agent

Scope: structured registration, heartbeat, polling, local slot ownership, execution, result retry, and shutdown.

Depends on `Client`, `Executor`, and `Runtime`; no lower namespace depends on `Agent`.

| API | Purpose |
|---|---|
| `create_control` / `stop` | Explicit acceptance/shutdown state |
| `run` | Own all heartbeat, polling, and execution fibers |

Non-responsibilities: selecting jobs, deciding retries, changing domain state directly, or recovering work after worker death.
