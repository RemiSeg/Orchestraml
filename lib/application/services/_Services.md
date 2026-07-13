# Services

Coordinator-side use cases. Depends only on domain APIs and application ports.

| Module | Responsibility |
|---|---|
| `Job_service` | Submission, queries, history, non-active cancellation |
| `Worker_service` | Registration and queries |
| `Scheduling_service` | One atomic assignment cycle |
| `Execution_service` | Worker start and terminal-result reports |
| `Retry_service` | Release retry-ready jobs to pending |
| `Log_service` | Idempotent ordered attempt-log ingestion and retrieval |
| `Container_service` | Validate and persist monotonic Docker lifecycle observations |
| `Metrics_service` | Read a consistent operational metrics snapshot without mutation |

Services do not execute jobs, read system time, generate randomness, or access concrete storage.
