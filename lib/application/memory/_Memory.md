# Memory

Transactional in-memory implementation of `Ports.Persistence`.

| Module | Responsibility |
|---|---|
| `Persistence` | Repository records, private state, and snapshot rollback |

This adapter is retained for deterministic tests. It is not production persistence and provides no cross-process durability or concurrency.
