# Worker library

Scope: worker-side coordinator transport, local and Docker execution, durable-log upload, lifecycle orchestration, configuration, and stable identity.

Dependency direction: `Runtime`, `Client`, and `Executor` are independent adapters consumed by `Agent`. The worker depends on domain contracts but never on coordinator or persistence implementations.

| Namespace | Purpose | Key API |
|---|---|---|
| `Runtime` | Configuration and identity | `Config.load`, `Identity.load_or_create` |
| `Client` | Worker HTTP protocol | `register`, `heartbeat`, `poll`, lifecycle reports |
| `Executor` | Local/Docker execution dispatch | `Dispatcher.start`, `await`, `stop` |
| `Logging` | Ordered bounded output delivery | `Pipeline.create`, `emit`, `close_and_flush` |
| `Agent` | Structured worker lifecycle | `create_control`, `run`, `stop` |

Non-responsibilities: scheduling policy, database state, retry policy, stale-worker recovery, registry authentication, privileged containers, and durable worker-side spooling.
