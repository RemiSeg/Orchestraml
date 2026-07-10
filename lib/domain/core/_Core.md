# Core

Private domain entities and pure orchestration decisions. May depend on all lower domain namespaces.

| Module | Responsibility | Key API |
|---|---|---|
| `Job` | Job data and lifecycle transitions | `create`, `assign`, `start`, `complete`, `request_cancel` |
| `Attempt` | Attempt data and lifecycle transitions | `create`, `start`, `succeed`, `fail`, `time_out` |
| `Worker` | Worker capacity and reservations | `create`, `available_resources`, `free_slots` |
| `Eligibility` | Explainable worker compatibility | `evaluate`, `is_eligible` |
| `Scheduler_policy` | Deterministic candidate selection | `select_job`, `select_worker` |

```ocaml
let selected = Scheduler_policy.select_worker ~health_policy ~now ~job workers
```

Does not coordinate multiple entity updates, reserve database capacity, perform I/O, or execute jobs.
