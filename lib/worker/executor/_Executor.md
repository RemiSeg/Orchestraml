# Executor

Scope: staged direct local process startup and completion with bounded diagnostic tails.

Depends only on domain execution/failure values and Eio process primitives.

| API | Purpose |
|---|---|
| `start` | Validate and spawn without an implicit shell |
| `await` | Drain output, reap, and classify the outcome |

Non-responsibilities: HTTP reports, scheduling, timeout, cancellation, Docker execution, or durable logs.
