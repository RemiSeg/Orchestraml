# Worker library

Scope: worker-side coordinator transport, local execution, lifecycle orchestration, configuration, and stable identity.

Dependency direction: `Runtime`, `Client`, and `Executor` are independent adapters consumed by `Agent`. The worker depends on domain contracts but never on coordinator or persistence implementations.

| Namespace | Purpose | Key API |
|---|---|---|
| `Runtime` | Configuration and identity | `Config.load`, `Identity.load_or_create` |
| `Client` | Worker HTTP protocol | `register`, `heartbeat`, `poll`, lifecycle reports |
| `Executor` | Direct process execution | `start`, `await` |
| `Agent` | Structured worker lifecycle | `create_control`, `run`, `stop` |

Non-responsibilities: scheduling policy, durable state, retry policy, stale-worker recovery, Docker execution, and durable logs.
