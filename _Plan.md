The project should be structured around three executable applications and a shared OCaml library:

Orchestraml
├── Coordinator
├── Worker Agent
├── CLI Client
├── Shared Domain Library
├── PostgreSQL Database
└── Test and Deployment Infrastructure
1. System-level structure
                         ┌─────────────────┐
                         │  Orchestraml CLI│
                         └────────┬────────┘
                                  │ HTTP
                                  ▼
┌─────────────────────────────────────────────────────┐
│                    Coordinator                      │
│                                                     │
│  API → Job Service → Scheduler → Worker Dispatcher │
│                    ↓                                │
│          Retry / Health / Recovery Managers         │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
                ┌──────────────┐
                │ PostgreSQL   │
                │ Jobs         │
                │ Attempts     │
                │ Workers      │
                │ Logs         │
                └──────────────┘

          HTTP polling coordinator-worker protocol
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
    ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ Worker 1 │ │ Worker 2 │ │ Worker 3 │
    │ Executor │ │ Executor │ │ Executor │
    │Heartbeat │ │Heartbeat │ │Heartbeat │
    │Log sender│ │Log sender│ │Log sender│
    └──────────┘ └──────────┘ └──────────┘
2. Main applications
A. Coordinator

The coordinator is the control plane of the system. It does not execute jobs itself.

Its responsibilities are:

Accepting and validating jobs
Persisting jobs before confirming submission
Tracking workers and heartbeats
Selecting eligible workers
Creating execution attempts
Dispatching assignments
Processing completion and failure reports
Retrying failed jobs
Detecting offline workers
Recovering state after restart
Serving the CLI and external clients through an API

The coordinator should be divided into independent modules rather than one large service.

Coordinator
├── HTTP API
├── Job service
├── Scheduler
├── Worker registry
├── Dispatcher
├── Heartbeat monitor
├── Retry manager
├── Timeout monitor
├── Recovery manager
└── Persistence layer
Main coordinator loops

Several operations run concurrently:

HTTP server
Scheduler loop
Worker-health loop
Retry-processing loop
Assignment-timeout loop
Recovery/reconciliation loop

In OCaml, these can run as concurrent Eio fibers. Eio belongs in runtime and infrastructure code only: HTTP serving, scheduling loops, heartbeat monitoring, worker polling, concurrent execution, timeouts, networking, and graceful shutdown. Pure domain rules must not depend on Eio, HTTP, JSON, PostgreSQL, Docker, environment variables, or the real system clock.

B. Worker agent

A worker is the data plane. It performs the actual computation.

Each worker should have:

Worker Agent
├── Registration client
├── Heartbeat sender
├── Assignment receiver
├── Capacity manager
├── Container executor
├── Timeout controller
├── Cancellation controller
├── Log collector
└── Result reporter

The worker lifecycle is:

Start
  ↓
Load configuration
  ↓
Register with coordinator
  ↓
Start heartbeat loop
  ↓
Receive assignment
  ↓
Reserve capacity
  ↓
Execute container
  ↓
Stream logs
  ↓
Report result
  ↓
Release capacity

The worker should not decide whether a failed job is retried. It only reports what occurred. The coordinator owns retry policy.

Initial worker protocol

Workers communicate with the coordinator through HTTP polling for the MVP:

Start
  → Register with coordinator
  → Send recurring heartbeats
  → Poll for an assignment
  → Receive and acknowledge an assigned attempt
  → Report execution started
  → Upload logs incrementally
  → Report the final result
  → Poll again

The coordinator remains responsible for selecting and atomically assigning work; polling only allows a worker to request available work. Cancellation instructions are returned in heartbeat responses initially. This protocol avoids inbound worker ports, works naturally in Docker Compose, and can evolve into long polling without changing the domain model.

C. CLI client

The CLI should remain relatively thin. It should call the coordinator API instead of directly accessing the database.

Example commands:

orchestraml submit job.json
orchestraml jobs
orchestraml status <job-id>
orchestraml attempts <job-id>
orchestraml logs <job-id>
orchestraml logs --follow <job-id>
orchestraml cancel <job-id>
orchestraml workers

The CLI structure could be:

CLI
├── Command parser
├── API client
├── Job formatter
├── Worker formatter
├── Log follower
└── Error formatter

This separation allows another frontend, such as a web dashboard, to use the same API later.

3. Shared domain library

The most important logic should live in reusable library modules rather than inside the HTTP routes.

Shared Domain
├── Job
├── Job attempt
├── Worker
├── Resource requirements
├── Worker capabilities
├── Retry policy
├── Job state machine
├── Scheduling policy
├── Protocol messages
└── Domain errors

For example:

type job_status =
  | Pending
  | Assigned
  | Running
  | Retry_waiting
  | Cancelling
  | Completed
  | Permanently_failed
  | Cancelled

type attempt_status =
  | Assigned
  | Running
  | Succeeded
  | Failed
  | Timed_out
  | Lost
  | Cancelled

`Completed`, `Permanently_failed`, and `Cancelled` are terminal job states. A failed, timed-out, or lost attempt moves its job either to `Retry_waiting` or `Permanently_failed`, according to retry policy. `Submitted` is not persisted separately: after validation and durable insertion, an accepted job begins in `Pending`.

Status values describe lifecycle state only. Worker and attempt identifiers, assignment relationships, and timestamps are stored separately. The active attempt identifies its assigned worker, and `next_retry_at` records when a retry becomes eligible.

State changes should go through validated functions:

val assign :
  worker_id:Worker_id.t ->
  job ->
  (job, transition_error) result

val start :
  attempt_id:Attempt_id.t ->
  job ->
  (job, transition_error) result

val complete :
  job ->
  (job, transition_error) result

This prevents API routes, scheduler code, and recovery logic from making arbitrary state changes.

4. Recommended layered architecture

The cleanest internal structure is:

Transport Layer
      ↓
Application Layer
      ↓
Domain Layer
      ↓
Repository Interfaces
      ↓
Infrastructure Layer
Transport layer

Handles communication:

HTTP routes
JSON parsing
CLI commands
Worker protocol
Streaming logs

It should not contain business logic.

Application layer

Coordinates use cases:

Submit job
Cancel job
Register worker
Handle heartbeat
Schedule next job
Report completion
Retry failed job

Example:

Job_service.submit
Job_service.cancel
Worker_service.register
Worker_service.heartbeat
Execution_service.complete
Domain layer

Contains the rules of the system:

Valid state transitions
Worker eligibility
Retry decisions
Priority ordering
Capacity calculations
Failure classification

This layer should not know about HTTP, JSON, PostgreSQL, or Docker.

Persistence layer

Defines interfaces for storing and retrieving data:

module type JOB_REPOSITORY = sig
  val create : Job.t -> (unit, error) result
  val find : Job_id.t -> (Job.t option, error) result
  val list_pending : unit -> (Job.t list, error) result
  val update : Job.t -> (unit, error) result
end

PostgreSQL then provides an infrastructure implementation of that interface. Repository interfaces belong at the application/domain boundary so that the core rules remain independent of the database.

Infrastructure layer

Contains concrete integrations:

PostgreSQL
Docker execution
HTTP server
System clock
UUID generation
Process management
Structured logging
5. Repository structure

A good initial repository layout would be:

orchestraml/
├── dune-project
├── orchestraml.opam
├── README.md
├── docker-compose.yml
│
├── bin/
│   ├── coordinator/
│   │   ├── main.ml
│   │   └── dune
│   ├── worker/
│   │   ├── main.ml
│   │   └── dune
│   └── cli/
│       ├── main.ml
│       └── dune
│
├── lib/
│   ├── domain/
│   │   ├── job.ml
│   │   ├── job.mli
│   │   ├── job_status.ml
│   │   ├── attempt.ml
│   │   ├── worker.ml
│   │   ├── resources.ml
│   │   ├── retry_policy.ml
│   │   ├── failure.ml
│   │   ├── scheduler_policy.ml
│   │   └── dune
│   │
│   ├── application/
│   │   ├── job_service.ml
│   │   ├── worker_service.ml
│   │   ├── scheduling_service.ml
│   │   ├── execution_service.ml
│   │   ├── recovery_service.ml
│   │   └── dune
│   │
│   ├── coordinator/
│   │   ├── api.ml
│   │   ├── routes.ml
│   │   ├── scheduler_loop.ml
│   │   ├── heartbeat_monitor.ml
│   │   ├── retry_loop.ml
│   │   ├── dispatcher.ml
│   │   └── dune
│   │
│   ├── worker/
│   │   ├── agent.ml
│   │   ├── registration.ml
│   │   ├── heartbeat.ml
│   │   ├── assignment_handler.ml
│   │   ├── executor.ml
│   │   ├── log_collector.ml
│   │   ├── cancellation.ml
│   │   └── dune
│   │
│   ├── persistence/
│   │   ├── job_repository.ml
│   │   ├── worker_repository.ml
│   │   ├── attempt_repository.ml
│   │   ├── log_repository.ml
│   │   ├── postgres.ml
│   │   └── dune
│   │
│   ├── protocol/
│   │   ├── job_request.ml
│   │   ├── worker_message.ml
│   │   ├── coordinator_message.ml
│   │   ├── serialization.ml
│   │   └── dune
│   │
│   └── common/
│       ├── job_id.ml
│       ├── worker_id.ml
│       ├── attempt_id.ml
│       ├── clock.ml
│       ├── config.ml
│       ├── logging.ml
│       └── dune
│
├── migrations/
│   ├── 001_create_jobs.sql
│   ├── 002_create_workers.sql
│   ├── 003_create_attempts.sql
│   └── 004_create_logs.sql
│
├── test/
│   ├── unit/
│   │   ├── job_state_test.ml
│   │   ├── scheduler_test.ml
│   │   ├── retry_policy_test.ml
│   │   └── worker_eligibility_test.ml
│   ├── property/
│   │   ├── scheduler_properties.ml
│   │   └── state_machine_properties.ml
│   ├── integration/
│   │   ├── job_execution_test.ml
│   │   ├── worker_failure_test.ml
│   │   └── coordinator_restart_test.ml
│   └── dune
│
├── examples/
│   ├── hello-world.json
│   ├── failing-job.json
│   ├── timeout-job.json
│   └── labelled-job.json
│
├── scripts/
│   ├── start-cluster.sh
│   ├── stop-worker.sh
│   └── demo.sh
│
└── docs/
    ├── requirements.md
    ├── architecture.md
    ├── execution-semantics.md
    ├── api.md
    └── testing.md
6. Database structure

The main database tables should be:

jobs
job_attempts
workers
worker_labels
job_required_labels
job_logs
job_state_transitions
jobs

Stores the requested work and current overall state.

id
name
status
priority
command/container specification
timeout_seconds
max_attempts
current_attempt
created_at
updated_at
next_retry_at
idempotency_key
job_attempts

Stores each individual execution.

id
job_id
attempt_number
worker_id
status
started_at
finished_at
exit_code
failure_type
failure_message
retryable
workers

Stores worker registration and health.

id
name
status
max_concurrency
active_job_count
cpu_capacity_millicores
memory_capacity_mib
last_heartbeat_at
registered_at
job_logs

Stores incremental logs.

id
job_id
attempt_id
sequence_number
stream
message
created_at

job_state_transitions

Stores an audit record for every persisted job state transition.

id
job_id
from_status
to_status
attempt_id
reason
occurred_at

Database invariants

The database reinforces domain rules so concurrent coordinator operations cannot create invalid state:

* `jobs.idempotency_key` is unique when present; a separate idempotency table is not required initially.
* `(job_id, attempt_number)` is unique and attempt numbers start at one.
* A partial unique index permits at most one assigned or running attempt per job.
* `(attempt_id, sequence_number)` is unique and log sequence numbers are non-negative.
* Capacity, CPU, memory, timeout, attempt count, and active-job values cannot be negative; active jobs cannot exceed worker concurrency.
* Foreign keys connect attempts, workers, jobs, logs, and transition history.
* Assignment selects a pending job, rechecks worker capacity, creates an attempt, changes job state, records the transition, and reserves capacity in one transaction.

Resource units

Resource and time values use explicit canonical units throughout the domain, API, and database:

* CPU is represented in millicores (`1000` means one logical CPU).
* Memory is represented in MiB.
* Timeout and retry durations are represented in seconds.
* Stored timestamps use UTC.
* Concurrency is represented as a whole number of job slots.

API field names include their units, such as `cpu_millicores`, `memory_mib`, and `timeout_seconds`. Validated domain constructors prevent invalid values from entering the system. During early phases these resources control scheduling eligibility; the Docker executor later enforces container limits.

7. Main communication flows
Job submission flow
CLI
 → Coordinator API
 → Validation
 → Job Service
 → Database
 → Pending Queue
 → Scheduler
Job execution flow
Worker polls coordinator
 → Coordinator selects compatible pending job
 → Create Attempt
 → Persist Assignment
 → Return Assignment to Worker
 → Worker Acknowledges
 → Execute Container
 → Stream Logs
 → Report Result
 → Persist Final State
Worker failure flow
Heartbeat Stops
 → Health Monitor Detects Timeout
 → Worker Marked Offline
 → Active Attempts Marked Lost
 → Retry Policy Evaluated
 → Job Enters Retry Waiting
 → Job Returns to Pending
 → Scheduler Selects Another Worker
Coordinator recovery flow
Coordinator Starts
 → Load Non-terminal Jobs
 → Load Workers
 → Mark Stale Workers Offline
 → Reconcile Assigned/Running Attempts
 → Requeue Uncertain Jobs
 → Resume Scheduler
8. Phase 1 domain foundation design

Purpose

Phase 1 establishes Orchestraml's pure domain rulebook. It contains no HTTP, PostgreSQL, Eio, Docker, environment-variable, or real-clock dependencies. Infrastructure and application layers will consume these rules in later phases.

Domain modules

* Strong UUID-backed `Job_id`, `Worker_id`, and `Attempt_id` types prevent identifiers from being mixed accidentally. Random generation remains outside state-transition functions so tests can use deterministic identifiers.
* Validated scalar types cover CPU millicores, memory MiB, timeout seconds, retry delays, maximum attempts, concurrency, priority, attempt numbers, job names, and worker labels.
* Worker labels are normalized and represented as sets. A job's required labels must be a subset of a worker's labels.
* Private job, attempt, and worker records are created and changed only through validated public functions.
* Job execution specifications distinguish local commands from container specifications while remaining independent of process and Docker implementations.

State machines

Jobs and attempts use separate state machines. Status values contain no identifiers or timestamps.

Job states:

Pending → Assigned → Running → Completed
Assigned or Running → Retry_waiting → Pending
Pending or Retry_waiting → Cancelled
Assigned → Cancelled when execution has not started
Running → Cancelling → Cancelled
Assigned or Running → Permanently_failed when retry is forbidden or exhausted

`Completed`, `Permanently_failed`, and `Cancelled` are terminal job states.

Attempt states:

Assigned → Running → Succeeded
Assigned or Running → Failed, Lost, or Cancelled
Running → Timed_out

All terminal attempt states are immutable. Validated transition functions return structured errors for forbidden transitions and produce domain events for later persistence by the application layer.

Failure and retry policy

* Failures use structured categories rather than classification based on log text.
* Worker loss, network interruption, assignment timeout, and temporary execution failures are retryable by default.
* Invalid commands, missing executables, invalid images or configuration, permission failures, user cancellation, and unknown failures are non-retryable by default.
* Execution-timeout retry is configurable.
* `max_attempts` means the total number of executions, including the initial attempt.
* Retry delay uses deterministic capped exponential backoff. Random jitter is deferred until operational evidence shows it is needed.
* Retry decisions are pure functions of policy, failure, attempt count, and an explicitly supplied UTC timestamp.

Worker eligibility and scheduling

A worker is eligible only when it is healthy, contains every required label, has a free concurrency slot, and has sufficient unreserved CPU and memory. Eligibility returns structured rejection reasons for diagnostics.

Pending jobs are ordered by higher numeric priority, earlier submission time, then job ID for deterministic ties. Eligible workers are ordered by lowest concurrency utilization, remaining resources, then worker ID. CPU and memory are hard eligibility constraints. Scheduling functions select candidates but do not mutate jobs, reserve capacity, or create attempts.

Testing strategy

Alcotest covers validated constructors, the complete job and attempt transition matrices, terminal-state immutability, failure classification, retry limits and backoff, worker eligibility, and deterministic scheduling examples.

Initial QCheck properties verify that terminal states never transition, retry delays remain capped, retry limits are respected, selected workers are always eligible and within capacity, higher-priority jobs are selected first, and identical inputs always produce identical scheduling decisions.

Implementation increments

1. Dune project skeleton, UUID identifiers, and validated scalar types.
2. Labels, resources, timestamps, execution specifications, and job, attempt, and worker models.
3. Separate job and attempt transition functions with complete Alcotest transition matrices.
4. Structured failures and deterministic retry policy.
5. Worker eligibility and deterministic job and worker ordering.
6. QCheck properties, public module documentation, and final Phase 1 verification.

Phase 1 acceptance criteria

* Every public domain module has a documented `.mli` interface.
* Invalid primitive values and invalid state changes cannot enter through public APIs.
* Job and attempt transitions are explicit and exhaustively unit tested.
* Retry, eligibility, and scheduling decisions are deterministic and independently testable.
* No selected worker can violate label, health, concurrency, CPU, or memory requirements.
* Terminal job and attempt states cannot become active again.
* Alcotest and QCheck suites pass through Dune.
* The complete domain library builds and tests without HTTP, PostgreSQL, Eio, or Docker.

9. Suggested implementation order

The project should be built vertically, not by creating every empty module first.

Phase 1: Domain foundation
Job and worker types
Identifiers
Separate job and attempt state machines
Retry policy
Worker eligibility
Unit tests
Initial property-based invariants
Complete when the core rules build and pass without HTTP, PostgreSQL, Eio, or Docker.
Phase 2: Single-process prototype
In-memory repositories
Scheduler
Fake workers
Simulated job execution
Fake clock and executor interfaces
Complete when jobs can be submitted, assigned, completed, failed, and retried entirely in memory.
Phase 3: Coordinator API and database
HTTP API
PostgreSQL repositories
Job submission
Status queries
Atomic assignment
Idempotent submission
Complete when accepted jobs and their history survive a coordinator restart.
Phase 4: Real worker agent
Registration
Heartbeats
HTTP assignment polling and acknowledgement
Local process execution
Completion reporting
Complete when separate coordinator and worker processes execute a real local command end to end.
Phase 5: Reliability
Retry waiting
Worker failure detection
Timeouts
Cancellation
Coordinator recovery
Assignment acknowledgement timeout
Complete when worker crashes and coordinator restarts produce valid, durable states.
Phase 6: Container execution and logs
Docker executor
Incremental log upload
Live log following
Resource and label matching
Complete when jobs run in controlled containers and their ordered logs remain observable.
Phase 7: Testing and demo
Property-based tests
Integration cluster
Fault injection
Docker Compose
Demonstration script
Complete when the acceptance criteria in Requirements.md pass in the demonstrable local cluster.

The central design principle should be:

The coordinator decides and persists; workers execute and report; the domain layer validates every important rule.
