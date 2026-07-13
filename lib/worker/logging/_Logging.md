# Logging

Scope: convert local or container stdout/stderr reads into one ordered, bounded, retryable upload stream.

Dependency direction: `Executor → Logging.Pipeline → Client.Coordinator`; persistence remains coordinator-side.

| Module | Purpose | Key API |
|---|---|---|
| `Pipeline` | Sequence, chunk, batch, backpressure, retry, and final flush | `create`, `emit`, `close_and_flush` |

Key invariants: 16 KiB entries, 64 KiB batches, one cross-stream sequence, bounded pending bytes, and terminal reporting only after final acknowledgement.

Non-responsibilities: PostgreSQL storage, SSE delivery, diagnostic-tail policy, or durable worker-side spooling.
