# Services

Coordinator-side use cases. Depends only on domain APIs and application ports.

| Module | Responsibility |
|---|---|
| `Job_service` | Submission, queries, history, non-active cancellation |
| `Worker_service` | Registration and queries |
| `Scheduling_service` | One atomic assignment cycle |
| `Execution_service` | Worker start and terminal-result reports |
| `Retry_service` | Release retry-ready jobs to pending |

Services do not execute jobs, read system time, generate randomness, or access concrete storage.
