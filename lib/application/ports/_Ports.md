# Ports

Runtime capabilities required by application services.

| Module | Responsibility | Key API |
|---|---|---|
| `Persistence` | Repository records and atomic unit of work | `with_transaction` |
| `Clock` | Current UTC time | `now` |
| `Id_generator` | Job, attempt, and worker identities | `next_*_id` |

Ports contain contracts only. They do not select implementations or contain orchestration rules.
