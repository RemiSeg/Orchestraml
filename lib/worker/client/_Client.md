# Client

Scope: bounded worker-facing HTTP transport and explicit JSON contracts.

Depends on domain values, Cohttp-eio, and Eio time. It is independent of the agent and executor.

| API | Purpose |
|---|---|
| `register`, `heartbeat`, `poll` | Worker coordination requests |
| `acknowledge`, `started`, `report` | Attempt lifecycle reports |
| `upload_logs` | Idempotent ordered output delivery |
| `record_container`, `find_container` | Durable container lifecycle observations and orphan lookup |
| `retryable` | Transport/server failure classification |

Non-responsibilities: retry loops, scheduling, process execution, TLS, authentication, or persistence.
