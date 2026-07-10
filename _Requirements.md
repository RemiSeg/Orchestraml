# Orchestraml — Product Requirements and Use Cases

## 1. Project Definition

Orchestraml is a distributed job orchestration platform written primarily in OCaml. It allows users to submit computational, automation, and data-processing jobs to a central coordinator. The coordinator stores job information, selects an appropriate worker, dispatches the job, monitors its execution, and handles failures through retries or reassignment.

The platform is intended for internal engineering environments where multiple machines or containers are available to execute background workloads such as data ingestion, report generation, database maintenance, backtesting, file processing, validation pipelines, or scheduled automation tasks.

Orchestraml is not intended to replace Kubernetes, Airflow, or a full production cloud orchestration platform. Its purpose is to demonstrate the design and implementation of a reliable distributed system with scheduling, worker coordination, persistence, fault recovery, observability, and explicit execution guarantees.

---

## 2. Main Product Goal

The main goal of Orchestraml is to provide a reliable way to submit and execute jobs across multiple workers without requiring users to manually select machines, monitor processes, detect failures, or restart jobs.

The system should make job execution:

* Centralized
* Persistent
* Observable
* Recoverable
* Capacity-aware
* Fault-tolerant
* Easy to operate through a CLI and API

A user should be able to submit a job once and allow the platform to manage its execution lifecycle.

---

## 3. Problem Being Solved

Engineering teams often rely on independent scripts, cron jobs, manually started processes, and machine-specific automation. These approaches create several problems:

* Jobs may disappear when a machine restarts.
* Users may not know whether a task is still running.
* Failed jobs may require manual intervention.
* Multiple jobs may overload the same machine.
* Work may be assigned to machines without the required tools.
* Logs may be scattered across different systems.
* Duplicate submissions may execute the same work more than once.
* There may be no durable execution history.
* A failed worker may leave jobs permanently stuck.

Orchestraml solves these problems by introducing a coordinator that manages the job lifecycle and a pool of workers that execute jobs under the coordinator’s supervision.

---

## 4. Primary Actors

### 4.1 Job Submitter

A developer, analyst, researcher, or internal service that submits work to Orchestraml.

The job submitter wants to:

* Submit a job
* Check its status
* Inspect its logs
* Cancel it
* Understand why it failed
* Retry it when appropriate

### 4.2 System Operator

A person responsible for monitoring and managing the Orchestraml cluster.

The system operator wants to:

* Inspect registered workers
* Identify unhealthy workers
* Review failed jobs
* Understand system capacity
* Restart services safely
* Confirm that recovery works correctly

### 4.3 Worker Agent

An Orchestraml service running on a worker machine or inside a container.

The worker agent must:

* Register with the coordinator
* Advertise its capabilities
* Report available capacity
* Send heartbeats
* Receive job assignments
* Execute jobs
* Capture logs
* Report completion or failure
* Handle timeout and cancellation requests

### 4.4 Coordinator

The central Orchestraml service responsible for controlling the system.

The coordinator must:

* Accept job submissions
* Persist state
* Schedule jobs
* Track workers
* Dispatch assignments
* Monitor active executions
* Detect worker failures
* Retry eligible jobs
* Recover after restart

### 4.5 External Client

An application or automation system that interacts with Orchestraml through its HTTP API instead of the CLI.

Examples include:

* A web dashboard
* A CI pipeline
* A data-ingestion service
* A research platform
* A scheduled automation service

---

## 5. Core Entities

## 5.1 Job

A job represents a requested unit of work.

A job contains:

* Unique job ID
* Name
* Job description
* Execution command or container specification
* Priority
* Required worker labels
* CPU requirement
* Memory requirement
* Timeout
* Maximum number of attempts
* Retry policy
* Submission timestamp
* Current status
* Idempotency key
* Optional metadata

Example jobs include:

* Import market data
* Generate a daily report
* Run a backtest
* Process an uploaded file
* Validate an external API
* Perform a database backup

---

## 5.2 Job Attempt

A job attempt represents one execution attempt of a job.

A job may have multiple attempts if previous attempts fail, time out, or are lost.

A job attempt contains:

* Unique attempt ID
* Job ID
* Attempt number
* Worker ID
* Start time
* End time
* Status
* Exit code
* Failure reason
* Retry eligibility
* Captured logs

---

## 5.3 Worker

A worker represents a machine, process, or container capable of executing jobs.

A worker contains:

* Unique worker ID
* Worker name
* Advertised labels
* Maximum concurrent job capacity
* Current active job count
* CPU capacity
* Memory capacity
* Current status
* Registration timestamp
* Last heartbeat timestamp

Example worker labels include:

* `python`
* `docker`
* `linux`
* `market-data`
* `backtesting`
* `high-memory`

---

## 5.4 Job Log

A job log represents output produced during execution.

A log entry contains:

* Job ID
* Attempt ID
* Timestamp
* Stream type
* Sequence number
* Message content

The stream type may be:

* Standard output
* Standard error
* System event
* Worker event

---

## 6. Job Lifecycle

A job moves through a controlled state machine.

### Main successful path

```text
Submitted
→ Pending
→ Assigned
→ Running
→ Completed
```

### Failure and retry path

```text
Running
→ Failed
→ Retry Waiting
→ Pending
→ Assigned
→ Running
```

### Timeout path

```text
Running
→ Timed Out
→ Retry Waiting
```

### Worker-loss path

```text
Running
→ Lost
→ Retry Waiting
```

### Cancellation path

```text
Pending
→ Cancelled
```

or:

```text
Running
→ Cancelling
→ Cancelled
```

### Permanent failure path

```text
Failed
→ Permanently Failed
```

A job becomes permanently failed when:

* It has used all permitted attempts.
* The failure is classified as non-retryable.
* Its configuration is invalid.
* The required execution environment does not exist.

---

## 7. User Stories

## 7.1 Job Submission

As a job submitter, I want to submit a job through the CLI or API so that it can be executed by the cluster.

As a job submitter, I want to specify the worker capabilities required by my job so that it is only assigned to compatible workers.

As a job submitter, I want to specify a priority so that urgent jobs can be scheduled before less important work.

As a job submitter, I want to provide an idempotency key so that retrying a submission request does not create duplicate jobs.

---

## 7.2 Job Monitoring

As a job submitter, I want to view the current status of my job so that I know whether it is pending, running, completed, or failed.

As a job submitter, I want to view every execution attempt so that I can understand the complete job history.

As a job submitter, I want to inspect job logs so that I can diagnose execution problems.

As a job submitter, I want to follow logs in real time so that I can monitor long-running jobs.

---

## 7.3 Job Cancellation

As a job submitter, I want to cancel a pending job so that it does not execute unnecessarily.

As a job submitter, I want to cancel a running job so that the worker stops its execution.

As a system operator, I want cancellation to be reflected consistently even if the worker is temporarily unreachable.

---

## 7.4 Scheduling

As a job submitter, I want my job to be assigned only to healthy workers so that execution is not sent to unavailable machines.

As a system operator, I want workers to respect their capacity limits so that machines are not overloaded.

As a job submitter, I want higher-priority jobs to be scheduled before lower-priority jobs.

As a system operator, I want jobs with equal priority to be handled fairly according to submission time.

---

## 7.5 Failure Recovery

As a job submitter, I want temporary failures to be retried automatically so that I do not have to resubmit the job manually.

As a system operator, I want jobs running on a failed worker to be detected and reassigned.

As a system operator, I want retries to use backoff so that repeated failures do not overload the system.

As a job submitter, I want non-retryable failures to stop immediately so that invalid jobs do not consume unnecessary resources.

---

## 7.6 Worker Management

As a worker agent, I want to register with the coordinator so that I can receive work.

As a worker agent, I want to advertise my capabilities so that I only receive compatible jobs.

As a worker agent, I want to send heartbeats so that the coordinator knows I am healthy.

As a system operator, I want workers with missed heartbeats to be marked unavailable.

---

## 7.7 System Recovery

As a system operator, I want the coordinator to recover its state after a restart so that pending and historical jobs are not lost.

As a system operator, I want the coordinator to reconcile jobs that were running before the restart.

As a job submitter, I want my completed job history to remain available after services restart.

---

## 8. Functional Requirements

## 8.1 Job Submission Requirements

### FR-001

The system shall allow users to submit jobs through an HTTP API.

### FR-002

The system shall allow users to submit jobs through a command-line interface.

### FR-003

Each submitted job shall receive a unique identifier.

### FR-004

The system shall validate job definitions before accepting them.

### FR-005

The system shall reject jobs with missing or invalid required fields.

### FR-006

A job shall support the following configuration:

* Name
* Command or container image
* Arguments
* Priority
* Timeout
* Maximum attempt count
* Required worker labels
* CPU requirement
* Memory requirement
* Optional idempotency key

### FR-007

The system shall return the existing job when a duplicate idempotency key is submitted.

---

## 8.2 Persistence Requirements

### FR-008

The coordinator shall persist job data before confirming successful submission.

### FR-009

The coordinator shall persist every job state transition.

### FR-010

The coordinator shall persist every execution attempt separately.

### FR-011

The coordinator shall persist worker registration and heartbeat information.

### FR-012

The coordinator shall preserve completed and failed job histories after restart.

### FR-013

The coordinator shall use database transactions when assigning jobs.

---

## 8.3 Worker Registration Requirements

### FR-014

A worker shall register before receiving jobs.

### FR-015

A worker registration shall include:

* Worker identifier
* Worker name
* Labels
* Maximum concurrency
* CPU capacity
* Memory capacity

### FR-016

The coordinator shall prevent duplicate active worker registrations using the same worker identifier.

### FR-017

A worker shall periodically send heartbeat messages.

### FR-018

A heartbeat shall include:

* Worker identifier
* Active job count
* Available capacity
* Current worker status
* Optional resource usage

---

## 8.4 Worker Health Requirements

### FR-019

The coordinator shall classify workers using heartbeat recency.

### FR-020

A worker shall be classified as healthy when its heartbeat is recent.

### FR-021

A worker shall be classified as suspect when heartbeats are delayed.

### FR-022

A worker shall be classified as offline when the heartbeat timeout is exceeded.

### FR-023

Offline workers shall not receive new jobs.

### FR-024

The coordinator shall inspect active jobs assigned to a worker that becomes offline.

---

## 8.5 Scheduling Requirements

### FR-025

The scheduler shall only consider jobs in the pending state.

### FR-026

The scheduler shall only assign jobs to healthy workers.

### FR-027

A worker shall only receive a job when it satisfies all required labels.

### FR-028

A worker shall only receive a job when it has sufficient execution capacity.

### FR-029

A worker shall only receive a job when it has sufficient requested CPU and memory capacity.

### FR-030

The scheduler shall prioritize higher-priority jobs.

### FR-031

Jobs with equal priority shall be ordered by submission time.

### FR-032

The scheduler shall prevent the same job from being assigned to multiple workers through concurrent scheduling operations.

### FR-033

The assignment operation shall be atomic.

---

## 8.6 Job Dispatch Requirements

### FR-034

The coordinator shall notify a selected worker when a job has been assigned.

### FR-035

A worker shall explicitly acknowledge receipt of a job.

### FR-036

The coordinator shall return a job to the pending queue when assignment acknowledgement is not received within the configured timeout.

### FR-037

The worker shall reject jobs it cannot execute.

### FR-038

A rejected job shall be returned to the coordinator with a structured failure reason.

---

## 8.7 Execution Requirements

### FR-039

The worker shall execute jobs in an isolated container for the final project version.

### FR-040

The worker shall capture standard output.

### FR-041

The worker shall capture standard error.

### FR-042

The worker shall report when execution starts.

### FR-043

The worker shall report when execution completes.

### FR-044

The worker shall report the process exit code.

### FR-045

The worker shall enforce the configured timeout.

### FR-046

The worker shall terminate a job that exceeds its timeout.

### FR-047

The worker shall limit simultaneous execution according to its configured capacity.

---

## 8.8 Logging Requirements

### FR-048

The worker shall forward job logs to the coordinator.

### FR-049

Logs shall be associated with a specific job attempt.

### FR-050

The system shall preserve the ordering of logs using sequence numbers.

### FR-051

The system shall allow users to retrieve stored logs.

### FR-052

The system shall support following logs while a job is running.

### FR-053

Logs shall remain available after job completion.

---

## 8.9 Retry Requirements

### FR-054

The system shall classify failures as retryable or non-retryable.

### FR-055

Retryable failures may include:

* Worker loss
* Temporary execution failure
* Network interruption
* Job timeout
* Assignment acknowledgement timeout

### FR-056

Non-retryable failures may include:

* Invalid command
* Missing executable
* Invalid container image
* Invalid job configuration
* Permission failure

### FR-057

The system shall not retry a job once its maximum attempt count has been reached.

### FR-058

The system shall use exponential backoff between retry attempts.

### FR-059

The system shall persist the next eligible retry time.

### FR-060

A retried job shall create a new job attempt.

---

## 8.10 Cancellation Requirements

### FR-061

A user shall be able to cancel a pending job.

### FR-062

A pending job cancellation shall prevent future scheduling.

### FR-063

A user shall be able to request cancellation of a running job.

### FR-064

The coordinator shall send a cancellation request to the assigned worker.

### FR-065

The worker shall terminate the running process when cancellation is received.

### FR-066

The worker shall confirm successful cancellation.

### FR-067

A completed or permanently failed job shall not be cancellable.

---

## 8.11 Status and Query Requirements

### FR-068

The system shall allow users to list jobs.

### FR-069

The job list shall support filtering by status.

### FR-070

The job list shall support filtering by submission time.

### FR-071

The system shall allow users to inspect an individual job.

### FR-072

The job detail response shall include:

* Current status
* Job configuration
* Assigned worker
* Attempt history
* Failure information
* Timestamps
* Retry information

### FR-073

The system shall allow users to list workers.

### FR-074

Worker information shall include:

* Health status
* Labels
* Capacity
* Active jobs
* Last heartbeat

---

## 8.12 Coordinator Recovery Requirements

### FR-075

The coordinator shall reload persisted jobs after restart.

### FR-076

The coordinator shall reload persisted workers after restart.

### FR-077

The coordinator shall classify stale workers as offline after restart.

### FR-078

The coordinator shall reconcile jobs that were previously assigned or running.

### FR-079

Jobs with unknown execution status may be requeued according to at-least-once execution semantics.

### FR-080

Terminal jobs shall not be rescheduled during recovery.

---

## 9. Non-Functional Requirements

## 9.1 Reliability

### NFR-001

No accepted job shall be lost following a coordinator restart.

### NFR-002

Every job state transition shall be persisted.

### NFR-003

Duplicate worker status messages shall not corrupt job state.

### NFR-004

Duplicate completion messages shall be handled idempotently.

### NFR-005

A worker crash shall not permanently block its assigned jobs.

---

## 9.2 Consistency

### NFR-006

A job shall have at most one active assignment recorded by the coordinator.

### NFR-007

A running job shall reference an active execution attempt.

### NFR-008

A completed job shall never return to a non-terminal state.

### NFR-009

Attempt numbers shall increase monotonically.

### NFR-010

Worker capacity shall never be recorded below zero or above its configured maximum.

---

## 9.3 Performance

### NFR-011

The system should schedule eligible pending jobs within five seconds under normal local test conditions.

### NFR-012

The coordinator should support at least 100 active jobs in the project demonstration environment.

### NFR-013

The coordinator should support at least 10 workers in the project demonstration environment.

### NFR-014

Job status queries should return within one second under normal local test conditions.

---

## 9.4 Scalability

### NFR-015

The worker model shall allow additional workers to be added without restarting the coordinator.

### NFR-016

The scheduling logic shall not depend on a fixed number of workers.

### NFR-017

Logs shall be stored incrementally rather than entirely in memory.

---

## 9.5 Maintainability

### NFR-018

The system shall separate domain logic, persistence, scheduling, API, and execution concerns.

### NFR-019

Core domain types shall prevent invalid identifier usage.

### NFR-020

State transitions shall be implemented through explicit validated functions.

### NFR-021

Public modules shall include documentation.

### NFR-022

Database schema changes shall be managed through migrations.

---

## 9.6 Testability

### NFR-023

Scheduler logic shall be testable independently from the HTTP API.

### NFR-024

The system clock shall be abstracted where required for retry and timeout tests.

### NFR-025

Worker failures shall be reproducible through fault-injection tests.

### NFR-026

External process execution shall be mockable for unit tests.

---

## 9.7 Observability

### NFR-027

Coordinator events shall use structured logs.

### NFR-028

Worker events shall use structured logs.

### NFR-029

Every log entry shall include relevant identifiers such as job ID, attempt ID, or worker ID.

### NFR-030

The system shall expose basic metrics including:

* Pending job count
* Running job count
* Completed job count
* Failed job count
* Healthy worker count
* Offline worker count
* Retry count
* Average job duration

---

## 9.8 Security

### NFR-031

The final system shall not expose unauthenticated arbitrary command execution to external networks.

### NFR-032

Job execution shall occur inside controlled containers.

### NFR-033

Sensitive values shall not be included directly in job logs.

### NFR-034

Configuration secrets shall be provided through environment variables or mounted secret files.

### NFR-035

The coordinator and worker communication model shall be designed so authentication can be added later.

A full production authentication and authorization system is outside the initial scope.

---

## 10. Detailed Use Cases

## UC-001: Submit a Valid Job

### Actor

Job Submitter

### Preconditions

* The coordinator is running.
* The submitted job definition is valid.
* At least one compatible worker may exist, although it does not need to be currently available.

### Main Flow

1. The user submits a job through the CLI or API.
2. The coordinator validates the job definition.
3. The coordinator checks the idempotency key.
4. The coordinator creates a job record.
5. The coordinator stores the job in the database.
6. The job enters the pending state.
7. The coordinator returns the job ID and current status.

### Expected Result

The job is durably stored and available for scheduling.

### Alternative Flow

If no worker currently satisfies the requirements, the job remains pending.

---

## UC-002: Reject an Invalid Job

### Actor

Job Submitter

### Preconditions

The submitted job is missing required data or contains invalid values.

### Main Flow

1. The user submits the job.
2. The coordinator validates the job.
3. Validation fails.
4. The coordinator rejects the request.
5. The coordinator returns structured validation errors.

### Expected Result

No job is created.

---

## UC-003: Schedule a Pending Job

### Actor

Coordinator

### Preconditions

* A pending job exists.
* At least one healthy compatible worker has available capacity.

### Main Flow

1. The scheduler selects the highest-priority pending job.
2. It identifies eligible workers.
3. It removes workers lacking required labels or resources.
4. It selects the most appropriate worker.
5. It creates a new job attempt.
6. It atomically records the assignment.
7. It dispatches the assignment to the worker.

### Expected Result

The job enters the assigned state.

---

## UC-004: Execute a Job Successfully

### Actor

Worker Agent

### Preconditions

* The worker has received a valid job assignment.
* The worker has sufficient capacity.
* The required container image or execution environment is available.

### Main Flow

1. The worker acknowledges the assignment.
2. The worker starts the container.
3. The worker informs the coordinator that execution has started.
4. The worker captures stdout and stderr.
5. The worker streams logs.
6. The process completes with exit code zero.
7. The worker reports successful completion.
8. The coordinator stores the result.
9. The job enters the completed state.

### Expected Result

The job is marked completed and its logs remain available.

---

## UC-005: Retry a Failed Job

### Actor

Coordinator

### Preconditions

* A job attempt has failed.
* The failure is retryable.
* The maximum number of attempts has not been reached.

### Main Flow

1. The worker reports the failure.
2. The coordinator stores the failed attempt.
3. The coordinator calculates the retry delay.
4. The job enters retry waiting.
5. The retry delay expires.
6. The job returns to pending.
7. The scheduler assigns it again.
8. A new attempt is created.

### Expected Result

The job is retried without losing its previous attempt history.

---

## UC-006: Handle a Non-Retryable Failure

### Actor

Coordinator

### Preconditions

A worker reports a permanent failure.

### Main Flow

1. The worker reports the failure.
2. The coordinator stores the failure reason.
3. The coordinator classifies the error as non-retryable.
4. The job enters permanently failed.

### Expected Result

The job is not retried.

---

## UC-007: Detect a Failed Worker

### Actor

Coordinator

### Preconditions

A worker stops sending heartbeats.

### Main Flow

1. The health monitor observes a delayed heartbeat.
2. The worker is marked suspect.
3. The heartbeat timeout is exceeded.
4. The worker is marked offline.
5. The coordinator identifies active attempts assigned to that worker.
6. Those attempts are marked lost.
7. Retryable jobs enter retry waiting.
8. The jobs may later be assigned to other workers.

### Expected Result

The failed worker receives no additional jobs, and unfinished work is recoverable.

---

## UC-008: Cancel a Pending Job

### Actor

Job Submitter

### Preconditions

The job is pending or waiting for retry.

### Main Flow

1. The user submits a cancellation request.
2. The coordinator validates that the job can be cancelled.
3. The coordinator changes the state to cancelled.
4. The scheduler ignores the job.

### Expected Result

The job never executes.

---

## UC-009: Cancel a Running Job

### Actor

Job Submitter

### Preconditions

The job is currently running.

### Main Flow

1. The user submits a cancellation request.
2. The coordinator changes the job state to cancelling.
3. The coordinator sends a cancellation request to the worker.
4. The worker terminates the process or container.
5. The worker confirms cancellation.
6. The coordinator marks the attempt and job as cancelled.

### Expected Result

Execution stops and the job is not retried automatically.

---

## UC-010: Enforce a Job Timeout

### Actor

Worker Agent

### Preconditions

A running job exceeds its configured timeout.

### Main Flow

1. The timeout expires.
2. The worker sends a termination signal.
3. The worker stops the process or container.
4. The worker reports the timeout.
5. The coordinator stores the timed-out attempt.
6. The coordinator applies the retry policy.

### Expected Result

The job does not run indefinitely.

---

## UC-011: Recover After Coordinator Restart

### Actor

System Operator

### Preconditions

The coordinator has stopped unexpectedly or been restarted.

### Main Flow

1. The coordinator starts.
2. It connects to the database.
3. It reloads jobs, workers, and attempts.
4. It marks stale workers offline.
5. It inspects assigned and running jobs.
6. It reconciles uncertain attempts.
7. Eligible jobs are requeued.
8. Terminal jobs remain unchanged.
9. Normal scheduling resumes.

### Expected Result

No accepted job is lost, and the system returns to a consistent state.

---

## UC-012: Prevent Duplicate Submission

### Actor

Job Submitter

### Preconditions

A job has already been created using a particular idempotency key.

### Main Flow

1. The client repeats the submission with the same key.
2. The coordinator detects the existing key.
3. The coordinator returns the previously created job.
4. No additional job is created.

### Expected Result

Client retries do not create duplicate work.

---

## UC-013: Inspect Job History

### Actor

Job Submitter

### Preconditions

The job exists.

### Main Flow

1. The user requests job details.
2. The coordinator loads the job.
3. The coordinator loads all attempts.
4. It returns statuses, timestamps, workers, exit codes, and failure reasons.

### Expected Result

The user can understand the complete lifecycle of the job.

---

## UC-014: Follow Job Logs

### Actor

Job Submitter

### Preconditions

A job is running or already has logs.

### Main Flow

1. The user starts the log-following command.
2. Existing logs are returned.
3. New log entries are streamed as they arrive.
4. The stream ends when the job reaches a terminal state or the user disconnects.

### Expected Result

The user can monitor execution in real time.

---

## 11. Scheduler Rules

The initial scheduler shall use the following rules:

1. Only pending jobs are schedulable.
2. Jobs are ordered by priority.
3. Higher numeric priority is scheduled first.
4. Equal-priority jobs are ordered by submission time.
5. Only healthy workers are eligible.
6. Workers must satisfy all required labels.
7. Workers must have sufficient free concurrency.
8. Workers must have sufficient CPU and memory.
9. The least-loaded eligible worker is preferred.
10. The assignment is recorded atomically.
11. A job cannot have more than one active coordinator assignment.

This scheduling strategy is intentionally understandable and testable. More advanced policies may be introduced later.

---

## 12. Execution Guarantee

Orchestraml provides at-least-once execution semantics.

The coordinator may retry a job when it cannot confirm whether a previous worker stopped executing it. This means that, during network partitions or worker failures, the same job may execute more than once.

Orchestraml does not claim exactly-once execution.

Users should design jobs to be idempotent where possible. Examples include:

* Writing results using a unique job ID
* Checking whether output already exists
* Using database transactions
* Using idempotency keys when calling external services
* Writing to temporary locations before committing results

This limitation shall be clearly documented.

---

## 13. MVP Requirements

The minimum viable product is complete when it includes:

* A central coordinator
* A relational database
* Worker registration
* Worker heartbeats
* Worker health classification
* Job submission through API and CLI
* Persistent job state
* Basic priority scheduling
* Worker label matching
* Worker capacity tracking
* Container-based job execution
* Job attempts
* Execution logs
* Job status inspection
* Automatic retry
* Exponential backoff
* Job timeout
* Pending and running job cancellation
* Worker failure detection
* Job reassignment
* Coordinator restart recovery
* Docker Compose deployment
* Unit tests
* Property-based tests
* Integration tests
* Fault-injection tests

---

## 14. Explicitly Out of Scope

The following features are not required for the first complete version:

* Multiple active coordinators
* Consensus algorithms
* Leader election
* Exactly-once execution
* Kubernetes integration
* Cloud provider integration
* Full graphical dashboard
* Complex workflow DAGs
* Cron scheduling
* User accounts
* Role-based access control
* Multi-tenant resource isolation
* Dynamic autoscaling
* GPU scheduling
* Cross-region execution
* Production secret management
* Billing or usage accounting

These may appear in a future roadmap but should not delay the core project.

---

## 15. Acceptance Criteria

The project shall be considered functionally complete when the following demonstration succeeds:

1. A Docker Compose cluster starts with one coordinator, one PostgreSQL database, and at least three workers.
2. Workers register and appear as healthy.
3. A user submits multiple jobs through the CLI.
4. Jobs are assigned according to worker labels and capacity.
5. A successful job completes and stores its logs.
6. A failing job is retried with backoff.
7. A non-retryable job becomes permanently failed.
8. A long-running job is cancelled.
9. A timed-out job is terminated.
10. A worker is deliberately stopped.
11. The coordinator detects the missing heartbeat.
12. The worker is marked offline.
13. Its unfinished job is marked lost and reassigned.
14. The coordinator is restarted.
15. Existing job history remains available.
16. Pending work resumes.
17. Property-based tests confirm scheduler invariants.
18. Integration tests pass automatically.
19. The repository can be run from documented setup instructions.
20. The README clearly explains the architecture, execution guarantees, and limitations.

---

## 16. Final Product Statement

Orchestraml is a fault-tolerant distributed job orchestration platform written in OCaml. It coordinates containerized jobs across a dynamic pool of workers using durable job state, capability-aware scheduling, worker heartbeats, automatic retries, execution timeouts, cancellation, structured logging, and failure recovery. The system provides at-least-once execution guarantees and is validated through unit, property-based, integration, and fault-injection testing.
