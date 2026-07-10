# Identifiers

Strong UUID types. Depends only on `Foundation.Validation_error` and `uuidm`.

| Module | Responsibility | Key API |
|---|---|---|
| `Id` | Shared UUID module contract and implementation | `S`, `Make` |
| `Job_id` | Job identity | `of_string`, `to_string`, `compare` |
| `Worker_id` | Worker identity | `of_string`, `to_string`, `compare` |
| `Attempt_id` | Attempt identity | `of_string`, `to_string`, `compare` |

```ocaml
let job_id = Job_id.of_string "00000000-0000-4000-8000-000000000001"
```

Identifier types are incompatible by design. Generation belongs to an outer application or infrastructure layer.
