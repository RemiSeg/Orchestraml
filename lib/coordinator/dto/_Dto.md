# DTO

| Module | Responsibility |
|---|---|
| `Job_json` | Submission decoding and entity encoding |
| `Api_error` | Stable structured errors |
| `Pagination` | Validated opaque cursors and limits |
| `Log_json` | Binary-safe attempt log batches and entries |
| `Container_json` | Container lifecycle snapshot decoding and encoding |

DTOs prevent transport shapes from becoming domain records.
