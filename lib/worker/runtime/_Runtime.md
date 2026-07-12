# Runtime

Scope: validated environment configuration and race-safe stable identity publication.

Independent of client, executor, and agent behavior.

| Module | Purpose | Key API |
|---|---|---|
| `Config` | Validate worker settings | `load` |
| `Identity` | Reuse or atomically create `Worker_id` | `load_or_create` |

Non-responsibilities: secrets, remote enrollment, protocol calls, process execution, or lifecycle decisions.
