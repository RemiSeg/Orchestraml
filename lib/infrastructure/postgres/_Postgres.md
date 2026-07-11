# PostgreSQL

| Module | Responsibility |
|---|---|
| `Snapshot_codec` | Validated entity row snapshots |
| `Migrations` | Ordered SQL migration checks/application |
| `Persistence` | Caqti repositories and transaction boundary |

SQL and row conversion stay here. Domain decisions remain in domain/application libraries.
