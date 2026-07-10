# Orchestraml
# Final Project Scope

Orchestraml is a distributed job orchestration platform written primarily in OCaml. It allows users to submit computational or data-processing jobs to a central coordinator, which persistently stores them, schedules them across 
a pool of workers, monitors their execution, and handles failures through retries and reassignment.

The system will contain three main applications: a coordinator service, multiple worker agents, and a command-line interface. The coordinator will expose an HTTP API for submitting, inspecting, cancelling, and monitoring jobs. 
Worker agents will register with the coordinator, advertise their capabilities and execution capacity, send periodic heartbeats, execute assigned jobs, capture logs, and report completion or failure.

Jobs will include a name, command or container configuration, priority, timeout, maximum retry count, required worker labels, and optional CPU or memory requirements. The scheduler will only assign jobs to healthy workers that 
satisfy the job’s labels and have sufficient available capacity. Among eligible workers, the scheduler will prioritize jobs by priority and submission time and select an appropriate available worker.

The coordinator will persist jobs, execution attempts, worker registrations, assignments, timestamps, exit codes, and failure information in a relational database. This persistence will allow the system to retain its state 
after a coordinator restart and preserve the complete execution history of every job.

Workers will send recurring heartbeat messages containing their current status, capacity, and active job count. The coordinator will classify workers as healthy, unavailable, or offline based on their most recent heartbeat. 
When a worker becomes unavailable, the coordinator will mark its active execution attempts as lost and return eligible jobs to the scheduling queue.

Orchestraml will provide at-least-once execution semantics. Because a coordinator may lose communication with a worker without knowing whether the worker has stopped executing a job, the system will not claim exactly-once 
execution. Jobs should therefore be designed to be idempotent when duplicate execution could cause side effects.

Failed or lost jobs will be retried according to a configurable retry policy. Retries will use exponential backoff and will stop once the maximum attempt count has been reached. The system will distinguish between retryable 
failures, such as worker loss or temporary execution errors, and permanent failures, such as invalid configurations or missing executables.

Workers will enforce job timeouts and support cancellation requests. They will capture standard output and standard error and forward execution logs to the coordinator. Users will be able to inspect stored logs through the API 
and CLI and optionally follow logs while a job is running.

The CLI will support commands for submitting jobs, listing jobs, inspecting job status, following logs, cancelling jobs, and viewing registered workers. The entire development environment will run through Docker Compose, 
allowing a coordinator, database, and multiple workers to be launched locally as a small distributed cluster.

The project will include unit tests for scheduling rules, retry policies, state transitions, and worker eligibility. Property-based tests will verify invariants such as preventing workers from exceeding their capacity, ensuring 
running jobs have assigned workers, and preventing terminal jobs from being rescheduled. Integration and fault-injection tests will simulate worker crashes, missed heartbeats, duplicate status messages, job timeouts, and 
coordinator restarts.

The final demonstrable version will include container-based job execution, worker capability labels, priority scheduling, persistent job state, automatic retries, health-aware reassignment, cancellation, timeouts, execution 
logs, and failure recovery.

The project will initially use a single active coordinator. Multi-coordinator consensus, Kubernetes integration, complex workflow DAGs, a production authentication system, and exactly-once execution are explicitly outside the 
primary scope. These may be documented as future extensions but will not be required for the project to be considered complete.

The expected technology stack is OCaml 5, Dune, Eio for structured concurrency, an OCaml HTTP framework for the coordinator API, Yojson for serialization, PostgreSQL for persistence, Alcotest for unit testing, QCheck for 
property-based testing, and Docker Compose for local deployment.


# Orchestraml — Distributed Job Orchestration Platform | OCaml, PostgreSQL, Docker
Developing a fault-tolerant distributed job orchestration platform in OCaml for scheduling and executing containerized computational and data-processing workloads across multiple workers. The system uses a central coordinator 
to persist job state, perform priority- and capability-aware scheduling, monitor worker health through recurring heartbeats, and automatically retry or reassign jobs following execution failures and worker outages. Worker 
agents enforce timeouts and cancellation requests, capture execution logs, and report structured status updates for every attempt. The platform provides at-least-once execution guarantees, durable recovery following coordinator 
restarts, configurable exponential-backoff retries, and a CLI for job submission, monitoring, log inspection, cancellation, and worker management. Reliability is validated through unit, property-based, integration, and 
fault-injection tests covering scheduler invariants, duplicate messages, missed heartbeats, process failures, and cluster recovery.


Dune (Dune is OCaml’s standard build system and project manager. It plays a role similar to Maven/Gradle for Java)
└── Builds and tests the whole project
    ├── Eio: concurrent coordinator and worker operations (Eio is a structured-concurrency library for OCaml 5. It helps applications perform multiple I/O operations concurrently without creating uncontrolled background tasks.)
    ├── Yojson: JSON communication through the HTTP API
    ├── Alcotest: exact, hand-written test cases
    └── QCheck: generated tests of system invariants


Phase 1 — Domain foundation
Build:
Strongly typed job, worker, and attempt identifiers.
Resource and label types.
Job and attempt statuses.
Validated state transitions.
Failure classification and retry policy.
Worker eligibility and scheduling order.
Alcotest unit tests.
Initial QCheck invariants.
Complete when all core rules run without HTTP, PostgreSQL, Eio, or Docker.


Phase 2 — In-memory vertical prototype
Build:
Repository interfaces.
In-memory implementations.
Application services.
Scheduler service.
Fake clock and fake executor.
Simulated worker lifecycle.
Complete when a job can be submitted, assigned, executed, completed, failed, and retried entirely in memory.


Phase 3 — Coordinator and PostgreSQL
Build:
Database migrations.
PostgreSQL repository implementations.
Transactional assignment.
HTTP API and JSON contracts.
Submission, listing, inspection, attempts, and cancellation of pending jobs.
Idempotent submission.
Complete when jobs survive a coordinator restart.


Phase 4 — Real worker communication
Build:
HTTP worker registration.
Heartbeats.
Assignment polling and acknowledgement.
Capacity reporting.
Local process executor.
Result reporting.
Complete when coordinator and worker processes execute a real local command end to end.


Phase 5 — Reliability
Build:
Retry scheduling and exponential backoff.
Heartbeat health classification.
Lost-attempt recovery.
Execution timeout.
Running-job cancellation.
Assignment acknowledgement timeout.
Coordinator startup reconciliation.
Complete when crashes and restarts produce valid, durable states.


Phase 6 — Container execution and logs
Build:
Docker executor.
Incremental stdout and stderr capture.
Ordered log ingestion.
Stored-log retrieval.
Live log following.
Final resource and capability enforcement.
Complete when jobs execute in controlled containers and their logs are observable.


Phase 7 — Cluster validation and demonstration
Build:
Full Docker Compose cluster.
Three differently labelled workers.
Integration and fault-injection tests.
Coordinator-restart tests.
Worker-loss and reassignment tests.
Demonstration script and example jobs.
Final documentation.
Complete when all 20 acceptance criteria in Requirements.md can be demonstrated.