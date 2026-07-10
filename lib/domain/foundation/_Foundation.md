# Foundation

Validated primitive values and state labels. Depends only on the OCaml standard library, `ptime`, and validation primitives within this namespace.

| Module | Responsibility | Key API |
|---|---|---|
| `Validation_error` | Consistent constructor errors | `make`, `pp` |
| `Scalar` | Validated quantities and names | `create`, `value`, `compare` |
| `Timestamp` | UTC instants and time arithmetic | `of_rfc3339`, `add_seconds`, `diff_seconds` |
| `Worker_label` | Normalized capability labels and sets | `create`, `Set` |
| `Job_status` | Overall job lifecycle labels | `is_terminal`, `to_string` |
| `Attempt_status` | Per-attempt lifecycle labels | `is_terminal`, `to_string` |

```ocaml
let timeout = Scalar.Timeout_seconds.create 30
```

Does not contain entities, orchestration decisions, I/O, or generated identifiers.
