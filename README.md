# Orchestraml

Orchestraml is a distributed job orchestration platform written in OCaml 5. A durable coordinator schedules validated jobs across heartbeat-reporting workers, stores lifecycle history and logs in PostgreSQL, and recovers from process, worker, and coordinator failures.

The first release supports priority and label-aware scheduling, CPU and memory reservations, local and controlled Docker execution, retries with exponential backoff, timeouts, cancellation, worker-loss recovery, durable logs, live log following, a CLI, and a reproducible three-worker Compose cluster.

## Architecture

```text
CLI / HTTP clients
       |
       v
Coordinator ---- PostgreSQL
       |
       | trusted polling protocol
       v
Worker agents ---- local processes or Docker containers
```

- The coordinator validates, persists, schedules, retries, cancels, and recovers work.
- PostgreSQL is authoritative for jobs, attempts, workers, reservations, events, controls, logs, and container evidence.
- Workers advertise capacity, execute assignments, upload ordered output, and report observed outcomes.
- The CLI is an HTTP client. It never reads PostgreSQL or makes lifecycle decisions.
- The pure domain library has no HTTP, database, Docker, Eio, environment, or system-clock dependency.

## Security warning

The first release has no authentication or TLS. Compose publishes the coordinator only on `127.0.0.1:8080`. Do not expose it to an untrusted network: submitted jobs can execute commands.

The two Docker-capable demonstration workers mount `/var/run/docker.sock`. Access to that socket is effectively authority over the local Docker engine. This topology is for trusted local development and demonstration.

Job containers are created without privileged mode, host mounts, extra capabilities, host PID/IPC access, or the Docker socket. The executor applies `--cap-drop ALL` and `no-new-privileges`, plus requested CPU and memory limits.

## Prerequisites

- Docker Desktop with Linux containers.
- Docker Compose v2.
- PowerShell 7 or Windows PowerShell for the provided acceptance scripts.
- Port `18080` available on localhost, or set `ORCHESTRAML_HOST_PORT`.

OCaml and opam are not required on the host.

## Start the local cluster

```powershell
docker compose build
docker compose up -d --wait
docker compose ps
```

This starts PostgreSQL, runs migrations explicitly, starts the coordinator, and registers:

| Worker | Submitted labels | Capacity | Docker |
|---|---|---|---|
| `general-worker` | `linux,general,shared` | 2 slots, 2000m CPU, 1024 MiB | yes |
| `data-worker` | `linux,data,shared` | 1 slot, 1000m CPU, 768 MiB | yes |
| `local-worker` | `linux,local` | 1 slot, 500m CPU, 256 MiB | no |

Docker-capable workers add the `docker` label only after successful `docker version` and `docker info` probes.
Compose publishes the coordinator at `http://127.0.0.1:18080`; set `ORCHESTRAML_HOST_PORT` to change only the host-side port.

Run migrations separately when required:

```powershell
docker compose run --rm migrate
```

The coordinator refuses to start if migrations are missing, modified, or newer than the executable.

## CLI quick start

The Compose CLI reaches the coordinator over the internal network:

```powershell
docker compose --profile tools run --rm --no-deps cli submit /examples/success.json
docker compose --profile tools run --rm --no-deps cli jobs
docker compose --profile tools run --rm --no-deps cli workers
```

When running the executable directly, its default URL is `http://127.0.0.1:8080`. Override it with `--coordinator-url` or `ORCHESTRAML_COORDINATOR_URL`.

```text
orchestraml submit <job.json> [--idempotency-key KEY]
orchestraml jobs [--status STATUS] [--limit N] [--cursor CURSOR]
orchestraml status <job-id>
orchestraml attempts <job-id>
orchestraml events <job-id>
orchestraml logs <job-id> [--attempt ATTEMPT_ID] [--follow]
orchestraml cancel <job-id>
orchestraml workers
orchestraml worker <worker-id>
```

Add `--json` to any command for machine-readable output. `submit -` reads JSON from standard input. CLI exit codes are: `2` invalid local input/response, `3` rejected request, `4` not found, `5` conflict, `6` transport unavailable, and `1` unexpected server failure.

`logs <job-id>` reads attempts in order. `--attempt` selects one exact attempt. `--follow` reconnects from the last sequence and continues when a retry creates another attempt.

## Job behavior

Job JSON explicitly defines execution, timeout, total maximum attempts, retry policy, labels, and resources. See [examples](examples/) for safe definitions.

- Higher priority jobs rank first; submission time and job ID break ties deterministically.
- Only healthy workers satisfying effective labels, free slots, CPU, and memory are eligible.
- Container jobs automatically require `docker`; submitted labels are not rewritten.
- Reservations are persisted before an assignment is returned.
- Retry delay is capped exponential backoff.
- Cancellation and timeout terminate and reap the process/container before releasing the worker slot.
- Offline or missing-worker attempts become lost and may be retried.
- Container metadata records creation, start, finish, removal, and cleanup failure independently from attempt state.

## Execution guarantee

Orchestraml provides **at-least-once execution**, not exactly-once execution. During uncertain worker or network failure, a replacement attempt may start before it is possible to prove the old computation never produced an external side effect.

Jobs with external side effects should be idempotent: use the job ID as an output key, check existing output, use transactions, or write temporary output before committing it. Submission idempotency prevents duplicate job records; it does not change execution semantics.

## Logs and observability

Workers assign one increasing sequence across stdout and stderr, upload bounded idempotent batches, and apply backpressure instead of silently dropping output. Stored logs survive coordinator restart. SSE following supports replay and reconnect.

```text
GET /health
GET /metrics
GET /v1/attempts/{attempt_id}/logs
GET /v1/attempts/{attempt_id}/logs/follow
```

`/metrics` uses Prometheus text exposition and includes job states, worker health, retries, average terminal duration, active attempts, and incomplete container cleanup. Coordinator and worker operational events are JSON lines with timestamps, severity, component, event name, and relevant entity IDs. Credentials, environment configuration, job output, and job payloads are not operational log fields.

## Configuration

Coordinator essentials:

- `DATABASE_URL` required.
- `LISTEN_ADDRESS` default `127.0.0.1`; `PORT` default `8080`.
- `DB_POOL_SIZE` default `10`.
- `MIGRATIONS_DIR` default `migrations`.
- Scheduler and retry intervals default to 1 second; maintenance defaults to 5 seconds.
- Worker suspect/offline thresholds default to 30/60 seconds.
- Assignment acknowledgement timeout defaults to 30 seconds.
- Execution-report and heartbeat-recovery grace default to 10/20 seconds.

Worker essentials:

- `COORDINATOR_URL` and `WORKER_NAME` required.
- `WORKER_LABELS`, concurrency, CPU millicores, and memory MiB define advertised capacity.
- Identity defaults to `/var/lib/orchestraml/worker-id` and must be persisted.
- Heartbeat, assignment, and control polling intervals are configurable.
- Docker and durable-log buffer/batch settings are validated at startup.

Secrets belong in environment variables or mounted secret files, never job definitions or source control.

## Testing and demonstration

Unit and property tests in the pinned toolchain:

```powershell
docker build -f Dockerfile.dev -t orchestraml-dev:phase7 .
docker run --rm orchestraml-dev:phase7 opam exec -- dune runtest --force
```

Focused suites:

```powershell
./scripts/test-integration.ps1
./scripts/test-reliability.ps1
./scripts/test-container-logs.ps1
./scripts/demo.ps1 -Clean
```

Complete release acceptance:

```powershell
./scripts/test-release.ps1
```

The release runner builds and tests the OCaml code, exercises PostgreSQL concurrency and restart, injects worker/coordinator failures, validates Docker execution and logs, runs the three-worker CLI demonstration, checks the Git diff, and cleans test resources.

## Troubleshooting and cleanup

```powershell
docker compose ps
docker compose logs coordinator worker-general worker-data worker-local postgres
docker ps -a --filter label=orchestraml.managed=true
```

Stop while preserving data and identities:

```powershell
docker compose --profile tools down
```

Destructively remove local database and worker identities:

```powershell
docker compose --profile tools down --volumes --remove-orphans
```

Malformed identity files are intentionally not replaced. Fix or explicitly remove the affected identity volume. If a Docker worker cannot access the engine, verify Docker Desktop and socket permissions; it will remain available for local commands but will not advertise `docker`.

## Limitations

Version one supports a single active coordinator and trusted HTTP communication. It does not include authentication, TLS, exactly-once execution, multi-coordinator leadership, Kubernetes, workflows, cron scheduling, a web UI, registry credentials, production secret distribution, host mounts, privileged job containers, or a durable worker-side log spool.

Engineering references: [_Plan.md](_Plan.md), [_Requirements.md](_Requirements.md), and the concise module documents under [`lib/`](lib/).
