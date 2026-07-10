# Shared

Reusable structures and pure policies shared by domain entities. May depend on `Foundation` and `Identifiers`; never on `Core`.

| Module | Responsibility | Key API |
|---|---|---|
| `Resources` | CPU and memory requirements | `create`, `fits`, `subtract` |
| `Execution_spec` | Validated command/container descriptions | `command`, `container`, `fold` |
| `Failure` | Structured failure classification | `create`, `retryable_by_default` |
| `Retry_policy` | Retry limits and capped backoff | `create`, `decide`, `delay_seconds` |
| `Worker_health` | Heartbeat health classification | `create`, `classify` |
| `Transition_error` | Rejected transition details | `make`, `pp` |
| `Domain_event` | Successful transition facts | `make` |

```ocaml
let decision = Retry_policy.decide policy ~failure ~attempts_started ~now
```

Does not persist events, execute work, mutate entities, or select jobs/workers.
