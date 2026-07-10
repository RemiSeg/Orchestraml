# Domain Library

Pure domain rules for Orchestraml. No HTTP, persistence, Eio, Docker execution, environment access, or system clock reads.

## Dependency direction

```text
Foundation → Identifiers → Shared → Core
```

`Shared` may use `Foundation` and `Identifiers`. `Core` may use all lower namespaces. Dependencies must never point upward.

| Namespace | Scope |
|---|---|
| `Foundation` | Validated primitive values and lifecycle statuses |
| `Identifiers` | Strong UUID identifier types |
| `Shared` | Cross-entity structures and pure policies |
| `Core` | Entities, eligibility, and scheduling decisions |

## Public paths

```ocaml
Orchestraml_domain.Foundation.Scalar
Orchestraml_domain.Identifiers.Job_id
Orchestraml_domain.Shared.Retry_policy
Orchestraml_domain.Core.Job
```

Entity construction and transitions must use public functions declared in `.mli` files.
