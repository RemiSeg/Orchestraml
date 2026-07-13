# Orchestraml

Orchestraml runs jobs across a small pool of workers.

You submit a command or container job to the coordinator. The coordinator stores it in PostgreSQL, selects a compatible worker, and tracks the job until it succeeds, fails, times out, or is cancelled.

The first release includes:

- Priority, label, CPU, and memory-aware scheduling.
- Local-command and Docker-container execution.
- Automatic retries with exponential backoff.
- Cancellation, timeouts, and worker-loss recovery.
- Durable job history and ordered stdout/stderr logs.
- A command-line client and HTTP API.
- A local three-worker Docker Compose cluster.

Orchestraml provides **at-least-once execution**. A job may run more than once after an uncertain worker failure, so jobs with external side effects should be idempotent.

## How it is built

| Part | Technology | Purpose |
|---|---|---|
| Language | OCaml 5 | Domain rules and runtime applications |
| Build | Dune and opam | Builds libraries, executables, and tests |
| Concurrency | Eio | HTTP, worker polling, process execution, and maintenance loops |
| Database | PostgreSQL and Caqti | Durable state and transactions |
| HTTP | Cohttp-eio | Coordinator API and worker protocol |
| JSON | Yojson | API request and response encoding |
| CLI | Cmdliner | User commands and options |
| Execution | Docker CLI | Controlled container creation and cleanup |
| Tests | Alcotest and QCheck | Unit, integration, and property tests |

The repository produces three applications:

```text
orchestraml-coordinator   stores and coordinates work
orchestraml-worker        executes assigned work
orchestraml               CLI client for users
```

The development toolchain is containerized. OCaml and opam are not required on the host.

Build and start the local cluster:

```powershell
docker compose build
docker compose up -d --wait
docker compose ps
```

The coordinator is available at `http://127.0.0.1:18080`. Set `ORCHESTRAML_HOST_PORT` to change the host port.

Stop the cluster while preserving its data:

```powershell
docker compose --profile tools down
```

Remove the cluster and all local Orchestraml data:

```powershell
docker compose --profile tools down --volumes --remove-orphans
```

## Architecture

```text
                       HTTP
CLI or API client --------------> Coordinator
                                      |
                                      | transactions
                                      v
                                  PostgreSQL
                                      ^
                                      |
                         polling and result reports
                                      |
                 +--------------------+--------------------+
                 |                    |                    |
           General worker        Data worker          Local worker
           Docker enabled        Docker enabled       Local commands
```

The responsibilities are intentionally separate:

- The **coordinator** validates jobs, persists state, schedules work, applies retry rules, and performs recovery.
- **PostgreSQL** is authoritative for jobs, attempts, workers, reservations, events, controls, logs, and container metadata.
- A **worker** advertises capacity, executes an assignment, uploads logs, and reports what happened. It does not decide whether to retry.
- The **CLI** calls the coordinator API. It does not connect to PostgreSQL or contain scheduling rules.
- The **domain library** contains pure types and rules. It does not depend on HTTP, PostgreSQL, Docker, Eio, environment variables, or the system clock.

The normal data flow is:

```text
Submit job
-> persist Pending
-> select eligible worker
-> reserve capacity and create attempt
-> worker acknowledges and starts
-> upload stdout/stderr
-> report result
-> complete, retry, fail, or cancel
-> release worker capacity
```

## CLI example

The Compose CLI runs inside the cluster network:

```powershell
docker compose --profile tools run --rm --no-deps cli submit /examples/success.json
```

Example input:

```json
{
  "name": "successful-container",
  "execution": {
    "type": "container",
    "image": "alpine:3.21",
    "command": ["echo", "hello"]
  },
  "priority": 10,
  "timeout_seconds": 30,
  "max_attempts": 2,
  "retry": {
    "initial_delay_seconds": 1,
    "multiplier": 2,
    "maximum_delay_seconds": 4,
    "retry_timeouts": false
  },
  "required_labels": ["shared"],
  "resources": {
    "cpu_millicores": 100,
    "memory_mib": 32
  }
}
```

Human-readable output:

```text
8df31a68-9d54-4bc8-a8f2-88f447e4ee38  pending             successful-container
```

List jobs:

```powershell
docker compose --profile tools run --rm --no-deps cli jobs
```

```text
8df31a68-9d54-4bc8-a8f2-88f447e4ee38  completed           successful-container
```

Read or follow its logs:

```powershell
docker compose --profile tools run --rm --no-deps cli logs 8df31a68-9d54-4bc8-a8f2-88f447e4ee38 --follow
```

```text
[5e80cc8a-4664-47de-b93b-e50afe27ef70 #1 stdout] hello
```

Add `--json` to any command for machine-readable output:

```powershell
docker compose --profile tools run --rm --no-deps cli status --json 8df31a68-9d54-4bc8-a8f2-88f447e4ee38
```

Main commands:

```text
orchestraml submit <job.json>
orchestraml jobs
orchestraml status <job-id>
orchestraml attempts <job-id>
orchestraml events <job-id>
orchestraml logs <job-id> [--follow]
orchestraml cancel <job-id>
orchestraml workers
orchestraml worker <worker-id>
```

More ready-to-run definitions are in [`examples/`](examples/).

## Documentation map

Start with the system overview:

- [Data flow](lib/_Dataflow.md)

Core rules:

- [Domain library](lib/domain/_Domain.md)
- [Validated values](lib/domain/foundation/_Foundation.md)
- [Typed identifiers](lib/domain/identifiers/_Identifiers.md)
- [Shared policies and structures](lib/domain/shared/_Shared.md)
- [Jobs, attempts, workers, and scheduling](lib/domain/core/_Core.md)

Coordinator and storage:

- [Application layer](lib/application/_Application.md)
- [Application ports](lib/application/ports/_Ports.md)
- [Application services](lib/application/services/_Services.md)
- [In-memory persistence](lib/application/memory/_Memory.md)
- [Infrastructure](lib/infrastructure/_Infrastructure.md)
- [PostgreSQL adapter](lib/infrastructure/postgres/_Postgres.md)
- [Runtime configuration](lib/infrastructure/runtime/_Runtime.md)
- [Coordinator](lib/coordinator/_Coordinator.md)
- [HTTP API](lib/coordinator/api/_Api.md)
- [JSON DTOs](lib/coordinator/dto/_Dto.md)
- [HTTP server](lib/coordinator/server/_Server.md)

Worker and user tools:

- [Worker](lib/worker/_Worker.md)
- [Worker agent](lib/worker/agent/_Agent.md)
- [Coordinator client](lib/worker/client/_Client.md)
- [Executors](lib/worker/executor/_Executor.md)
- [Durable logging pipeline](lib/worker/logging/_Logging.md)
- [Worker runtime](lib/worker/runtime/_Runtime.md)
- [CLI](lib/cli/_Cli.md)
- [Operational logging](lib/observability/_Observability.md)

Tests:

- [Controlled test support](test/support/_Support.md)

## Verification

Run the OCaml tests:

```powershell
docker build -f Dockerfile.dev -t orchestraml-dev:phase7 .
docker run --rm orchestraml-dev:phase7 opam exec -- dune runtest --force
```

Run the complete release acceptance suite:

```powershell
./scripts/test-release.ps1
```

The focused integration scripts are under [`scripts/`](scripts/).

## Current limits

This release is intended for trusted local or internal environments. It has no authentication or TLS and must not be exposed to an untrusted network. Two demonstration workers mount the Docker socket, which gives them authority over the local Docker engine.

The first release also excludes multi-coordinator leadership, exactly-once execution, Kubernetes, workflows, cron scheduling, a web UI, registry credentials, host mounts, and privileged job containers.
