# Test Support

Deterministic adapters used only by tests.

| Module | Responsibility | Production counterpart |
|---|---|---|
| `Controlled_clock` | Explicit time advancement | System UTC clock |
| `Deterministic_ids` | Repeatable identifiers | UUID generator |
| `Scripted_executor` | Configured execution outcomes | Worker executor |
| `Simulated_worker` | Drives start and result reports | Worker agent |

These modules contain no scheduling, retry, or domain-transition decisions and are excluded from application runtime dependencies.
