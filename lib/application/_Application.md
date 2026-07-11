# Application

Coordinates domain objects into use cases. Depends on `orchestraml.domain`; contains no transport, database, Eio, Docker, or process execution.

| Namespace | Scope |
|---|---|
| `Ports` | Required persistence, time, and identifier capabilities |
| `Services` | Coordinator-side use-case orchestration |
| `Memory` | Transactional in-memory persistence adapter |

```text
Domain <- Ports <- Services
           ^
           |
         Memory
```

Expected operational failures use `result`. Domain rules remain in `orchestraml_domain`.
