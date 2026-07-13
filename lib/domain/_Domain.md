# Domain library

Pure types and rules shared by the coordinator, worker, application services, and tests.

The domain library does not perform HTTP requests, database access, file access, Docker execution, environment reads, or system-clock reads.

## Dependency direction

```text
Foundation -> Identifiers -> Shared -> Core
```

Higher layers may use lower layers. Lower layers must not import higher layers.

| Namespace | Responsibility |
|---|---|
| `Foundation` | Validated scalar values, timestamps, labels, and statuses |
| `Identifiers` | Distinct UUID types for jobs, workers, and attempts |
| `Shared` | Resources, execution specifications, failures, retries, events, and health rules |
| `Core` | Jobs, attempts, workers, eligibility, and scheduling decisions |

## Public API

```ocaml
Orchestraml_domain.Foundation.Scalar
Orchestraml_domain.Identifiers.Job_id
Orchestraml_domain.Shared.Retry_policy
Orchestraml_domain.Core.Job
```

Public contracts live in `.mli` files. Entity records remain private, and state changes go through explicit transition functions.

## More detail

- [Foundation](foundation/_Foundation.md)
- [Identifiers](identifiers/_Identifiers.md)
- [Shared policies and structures](shared/_Shared.md)
- [Core entities and decisions](core/_Core.md)
