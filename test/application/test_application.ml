open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
open Orchestraml_application
module Support = Orchestraml_test_support

let get_ok = function Ok value -> value | Error _ -> Alcotest.fail "unexpected error"
let timestamp = Timestamp.of_rfc3339 "2026-01-01T00:00:00Z" |> get_ok
let positive create value = create value |> get_ok
let resources cpu memory = Resources.create
  ~cpu:(positive Scalar.Cpu_millicores.create cpu)
  ~memory:(positive Scalar.Memory_mib.create memory)
let retry_policy () = Retry_policy.create
  ~max_attempts:(positive Scalar.Max_attempts.create 3)
  ~initial_delay:(positive Scalar.Retry_delay_seconds.create 5) ~multiplier:2
  ~maximum_delay:(positive Scalar.Retry_delay_seconds.create 20) ~retry_timeouts:true |> get_ok
let health_policy = Worker_health.create
  ~suspect_after:(positive Scalar.Timeout_seconds.create 30)
  ~offline_after:(positive Scalar.Timeout_seconds.create 60) |> get_ok

type fixture = {
  persistence : Ports.Persistence.t;
  clock : Support.Controlled_clock.t;
  jobs : Services.Job_service.t;
  workers : Services.Worker_service.t;
  scheduling : Services.Scheduling_service.t;
  execution : Services.Execution_service.t;
  logs : Services.Log_service.t;
  containers : Services.Container_service.t;
  retries : Services.Retry_service.t;
  maintenance : Services.Maintenance_service.t;
}

let fixture () =
  let persistence = Memory.Persistence.create () in
  let clock = Support.Controlled_clock.create timestamp in
  let clock_port = Support.Controlled_clock.port clock in
  let ids = Support.Deterministic_ids.create () |> Support.Deterministic_ids.port in
  { persistence; clock;
    jobs = Services.Job_service.create ~persistence ~clock:clock_port ~ids;
    workers = Services.Worker_service.create ~persistence ~clock:clock_port ~ids;
    scheduling = Services.Scheduling_service.create ~persistence ~clock:clock_port ~ids ~health_policy;
    execution = Services.Execution_service.create ~persistence ~clock:clock_port;
    logs = Services.Log_service.create ~persistence ~clock:clock_port;
    containers = Services.Container_service.create ~persistence;
    retries = Services.Retry_service.create ~persistence ~clock:clock_port;
    maintenance = Services.Maintenance_service.create ~max_reconciliation_passes:1000
      ~persistence ~clock:clock_port ~health_policy
      ~acknowledgement_timeout:(positive Scalar.Timeout_seconds.create 30)
      ~execution_report_grace:(positive Scalar.Timeout_seconds.create 10)
      ~recovery_grace:(positive Scalar.Timeout_seconds.create 20) ~batch_size:100 }

let submission : Services.Job_service.submission = {
  name = Scalar.Job_name.create "vertical job" |> get_ok;
  execution = Execution_spec.command ~executable:"true" ~arguments:[] |> get_ok;
  priority = Scalar.Priority.create 10;
  requirements = resources 500 256;
  required_labels = Worker_label.Set.empty;
  retry_policy = retry_policy ();
  timeout = positive Scalar.Timeout_seconds.create 30;
}
let registration : Services.Worker_service.registration = {
  name = "worker-1"; labels = Worker_label.Set.empty;
  max_concurrency = positive Scalar.Concurrency.create 2;
  total_resources = resources 2000 2048;
}
let assigned = function
  | Services.Scheduling_service.Assigned assignment -> assignment
  | Services.Scheduling_service.No_assignment -> Alcotest.fail "expected assignment"

let test_transaction_rollback () =
  let fixture = fixture () in
  let worker_id = Worker_id.of_string "00000000-0000-4000-8000-000000000099" |> get_ok in
  let worker = Worker.create ~id:worker_id ~name:"rollback-worker"
    ~labels:Worker_label.Set.empty ~max_concurrency:(positive Scalar.Concurrency.create 1)
    ~active_jobs:0 ~total_resources:(resources 100 100) ~reserved_resources:Resources.zero
    ~last_heartbeat:timestamp |> get_ok in
  let result = fixture.persistence.with_transaction (fun repositories ->
    match repositories.workers.create_worker worker with
    | Error error -> Error error
    | Ok () -> Error (Ports.Persistence.Storage_failure "rollback")) in
  (match result with Ok (Error _) -> () | _ -> Alcotest.fail "transaction did not fail");
  Alcotest.(check int) "worker rolled back" 0
    (Services.Worker_service.list fixture.workers |> get_ok |> List.length)

let test_duplicate_repository_create () =
  let fixture = fixture () in
  let job = Services.Job_service.submit fixture.jobs submission |> get_ok in
  let result = fixture.persistence.with_transaction (fun repositories -> repositories.jobs.create_job job) in
  match result with
  | Ok (Error (Ports.Persistence.Already_exists (Ports.Persistence.Job, _))) -> ()
  | _ -> Alcotest.fail "duplicate job was accepted"

let test_retry_then_success () =
  let fixture = fixture () in
  let submitted = Services.Job_service.submit fixture.jobs submission |> get_ok in
  ignore (Services.Worker_service.register fixture.workers registration |> get_ok);
  let first = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  let executor = Support.Scripted_executor.create [
    Support.Scripted_executor.Failed (Failure.create Failure.Temporary_execution_failure);
    Support.Scripted_executor.Succeeded 0;
  ] in
  let first_result = Support.Simulated_worker.run ~execution_service:fixture.execution ~executor first |> get_ok in
  Alcotest.(check string) "waiting" "retry_waiting"
    (Job.status first_result.job |> Job_status.to_string);
  Alcotest.(check int) "capacity released" 0 (Worker.active_jobs first_result.worker);
  let events_before = Services.Job_service.events fixture.jobs (Job.id submitted) |> get_ok |> List.length in
  (match Services.Execution_service.report_failure fixture.execution (Attempt.id first_result.attempt)
      ~failure:(Failure.create Failure.Temporary_execution_failure) with
   | Ok replayed -> Alcotest.(check string) "duplicate terminal report replayed" "failed"
       (Attempt.status replayed.attempt |> Attempt_status.to_string)
   | Error _ -> Alcotest.fail "identical duplicate terminal report was rejected");
  Alcotest.(check int) "duplicate report changed no events" events_before
    (Services.Job_service.events fixture.jobs (Job.id submitted) |> get_ok |> List.length);
  Support.Controlled_clock.advance fixture.clock ~seconds:5 |> get_ok;
  Alcotest.(check int) "one retry released" 1 (Services.Retry_service.run_once fixture.retries |> get_ok);
  let second = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  let final = Support.Simulated_worker.run ~execution_service:fixture.execution ~executor second |> get_ok in
  Alcotest.(check string) "completed" "completed" (Job.status final.job |> Job_status.to_string);
  Alcotest.(check int) "two attempts" 2
    (Services.Job_service.attempts fixture.jobs (Job.id submitted) |> get_ok |> List.length);
  Alcotest.(check int) "capacity restored" 0 (Worker.active_jobs final.worker);
  Alcotest.(check bool) "events retained" true
    (Services.Job_service.events fixture.jobs (Job.id submitted) |> get_ok |> List.length >= 10)

let test_permanent_failure () =
  let fixture = fixture () in
  let submitted = Services.Job_service.submit fixture.jobs submission |> get_ok in
  ignore (Services.Worker_service.register fixture.workers registration |> get_ok);
  let assignment = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  let executor = Support.Scripted_executor.create [
    Support.Scripted_executor.Failed (Failure.create Failure.Invalid_command)
  ] in
  let final = Support.Simulated_worker.run ~execution_service:fixture.execution ~executor assignment |> get_ok in
  Alcotest.(check string) "permanent" "permanently_failed"
    (Job.status final.job |> Job_status.to_string);
  Alcotest.(check int) "one attempt" 1
    (Services.Job_service.attempts fixture.jobs (Job.id submitted) |> get_ok |> List.length);
  Alcotest.(check int) "no retry ready" 0 (Services.Retry_service.run_once fixture.retries |> get_ok)

let test_no_assignment () =
  let fixture = fixture () in
  ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
  match Services.Scheduling_service.run_once fixture.scheduling |> get_ok with
  | Services.Scheduling_service.No_assignment -> ()
  | Services.Scheduling_service.Assigned _ -> Alcotest.fail "assigned without worker"

let test_pending_cancellation () =
  let fixture = fixture () in
  let job = Services.Job_service.submit fixture.jobs submission |> get_ok in
  let cancelled = Services.Job_service.cancel fixture.jobs (Job.id job) |> get_ok in
  Alcotest.(check string) "cancelled" "cancelled" (Job.status cancelled |> Job_status.to_string);
  match Services.Scheduling_service.run_once fixture.scheduling |> get_ok with
  | Services.Scheduling_service.No_assignment -> ()
  | Services.Scheduling_service.Assigned _ -> Alcotest.fail "cancelled job was scheduled"

let test_timeout_uses_retry_policy () =
  let fixture = fixture () in
  ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
  ignore (Services.Worker_service.register fixture.workers registration |> get_ok);
  let assignment = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  let executor = Support.Scripted_executor.create [Support.Scripted_executor.Timed_out] in
  let result = Support.Simulated_worker.run ~execution_service:fixture.execution ~executor assignment |> get_ok in
  Alcotest.(check string) "timeout retries" "retry_waiting"
    (Job.status result.job |> Job_status.to_string)

let test_maximum_attempts () =
  let fixture = fixture () in
  let submitted = Services.Job_service.submit fixture.jobs submission |> get_ok in
  ignore (Services.Worker_service.register fixture.workers registration |> get_ok);
  let executor = Support.Scripted_executor.create [
    Support.Scripted_executor.Failed (Failure.create Failure.Temporary_execution_failure);
    Support.Scripted_executor.Failed (Failure.create Failure.Temporary_execution_failure);
    Support.Scripted_executor.Failed (Failure.create Failure.Temporary_execution_failure);
  ] in
  let run_failure () =
    let assignment = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
    Support.Simulated_worker.run ~execution_service:fixture.execution ~executor assignment |> get_ok in
  ignore (run_failure ());
  Support.Controlled_clock.advance fixture.clock ~seconds:5 |> get_ok;
  ignore (Services.Retry_service.run_once fixture.retries |> get_ok);
  ignore (run_failure ());
  Support.Controlled_clock.advance fixture.clock ~seconds:10 |> get_ok;
  ignore (Services.Retry_service.run_once fixture.retries |> get_ok);
  let final = run_failure () in
  Alcotest.(check string) "attempts exhausted" "permanently_failed"
    (Job.status final.job |> Job_status.to_string);
  Alcotest.(check int) "three attempts" 3
    (Services.Job_service.attempts fixture.jobs (Job.id submitted) |> get_ok |> List.length)

let test_idempotent_submission () =
  let fixture = fixture () in
  let key = Idempotency_key.create "request-1" |> get_ok in
  let first = Services.Job_service.submit_idempotent fixture.jobs ~key
    ~canonical_payload:"payload-a" submission |> get_ok in
  let first_job = match first with Services.Job_service.Created job -> job
    | Services.Job_service.Replayed _ -> Alcotest.fail "first request replayed" in
  let replay = Services.Job_service.submit_idempotent fixture.jobs ~key
    ~canonical_payload:"payload-a" submission |> get_ok in
  (match replay with Services.Job_service.Replayed job ->
      Alcotest.(check string) "same job" (Job.id first_job |> Job_id.to_string) (Job.id job |> Job_id.to_string)
    | Services.Job_service.Created _ -> Alcotest.fail "duplicate job created");
  (match Services.Job_service.submit_idempotent fixture.jobs ~key
      ~canonical_payload:"payload-b" submission with
   | Error Services.Job_service.Idempotency_conflict -> ()
   | _ -> Alcotest.fail "idempotency conflict not detected")

let test_targeted_poll_and_duplicate_result () =
  let fixture = fixture () in
  let worker = Services.Worker_service.register fixture.workers registration |> get_ok in
  ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
  let assignment = Services.Scheduling_service.poll_for_worker fixture.scheduling (Worker.id worker)
    |> get_ok |> assigned in
  ignore (Services.Execution_service.acknowledge_attempt fixture.execution (Attempt.id assignment.attempt) |> get_ok);
  ignore (Services.Execution_service.start_attempt fixture.execution (Attempt.id assignment.attempt) |> get_ok);
  let completed = Services.Execution_service.report_success fixture.execution
    (Attempt.id assignment.attempt) ~exit_code:0 |> get_ok in
  let replayed = Services.Execution_service.report_success fixture.execution
    (Attempt.id assignment.attempt) ~exit_code:0 |> get_ok in
  Alcotest.(check string) "duplicate result replays" "succeeded"
    (Attempt.status replayed.attempt |> Attempt_status.to_string);
  Alcotest.(check int) "capacity released once" 0 (Worker.active_jobs replayed.worker);
  (match Services.Execution_service.report_failure fixture.execution
      (Attempt.id assignment.attempt) ~failure:(Failure.create Failure.Invalid_command) with
   | Error (Services.Execution_service.Invalid_operation _) -> ()
   | _ -> Alcotest.fail "conflicting terminal result was accepted");
  Alcotest.(check string) "job remains completed" "completed"
    (Job.status completed.job |> Job_status.to_string)

let test_heartbeat_validation () =
  let fixture = fixture () in
  let worker = Services.Worker_service.register fixture.workers registration |> get_ok in
  let id = Attempt_id.of_string "00000000-0000-4000-8000-000000000099" |> get_ok in
  (match Services.Worker_service.heartbeat fixture.workers (Worker.id worker)
      { available_slots = 3; active_attempt_ids = [] } with
   | Error (Services.Worker_service.Invalid_worker _) -> ()
   | _ -> Alcotest.fail "heartbeat exceeding concurrency was accepted");
  (match Services.Worker_service.heartbeat fixture.workers (Worker.id worker)
      { available_slots = 1; active_attempt_ids = [id; id] } with
   | Error (Services.Worker_service.Invalid_worker _) -> ()
   | _ -> Alcotest.fail "duplicate heartbeat attempt IDs were accepted")

let test_assignment_timeout_recovery () =
  let fixture = fixture () in
  ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
  ignore (Services.Worker_service.register fixture.workers registration |> get_ok);
  let assignment = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  Support.Controlled_clock.advance fixture.clock ~seconds:31 |> get_ok;
  Alcotest.(check int) "one recovered" 1
    (Services.Maintenance_service.run_assignment_timeout_cycle fixture.maintenance |> get_ok);
  let attempts = Services.Job_service.attempts fixture.jobs (Job.id assignment.job) |> get_ok in
  Alcotest.(check string) "attempt lost" "lost"
    (Attempt.status (List.hd attempts) |> Attempt_status.to_string);
  let worker = Services.Worker_service.find fixture.workers (Worker.id assignment.worker)
    |> get_ok |> Option.get in
  Alcotest.(check int) "capacity released" 0 (Worker.active_jobs worker)

let test_deadline_and_running_cancellation_controls () =
  let fixture = fixture () in
  let worker = Services.Worker_service.register fixture.workers registration |> get_ok in
  ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
  let assignment = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  ignore (Services.Execution_service.acknowledge_attempt fixture.execution (Attempt.id assignment.attempt) |> get_ok);
  ignore (Services.Execution_service.start_attempt fixture.execution (Attempt.id assignment.attempt) |> get_ok);
  Support.Controlled_clock.advance fixture.clock ~seconds:41 |> get_ok;
  Alcotest.(check int) "timeout control created" 1
    (Services.Maintenance_service.run_execution_deadline_cycle fixture.maintenance |> get_ok);
  let controls = Services.Worker_service.poll_controls fixture.workers (Worker.id worker) ~limit:10 |> get_ok in
  Alcotest.(check int) "control delivered" 1 (List.length controls);
  ignore (Services.Job_service.cancel fixture.jobs (Job.id assignment.job) |> get_ok);
  let job = Services.Job_service.find fixture.jobs (Job.id assignment.job) |> get_ok |> Option.get in
  Alcotest.(check string) "cancelling" "cancelling" (Job.status job |> Job_status.to_string)

let test_unknown_process_control () =
  let fixture = fixture () in
  let worker = Services.Worker_service.register fixture.workers registration |> get_ok in
  let unknown = Attempt_id.of_string "00000000-0000-4000-8000-000000000099" |> get_ok in
  ignore (Services.Worker_service.heartbeat fixture.workers (Worker.id worker)
    { available_slots = 1; active_attempt_ids = [unknown] } |> get_ok);
  Alcotest.(check int) "stop created" 1
    (Services.Maintenance_service.run_heartbeat_reconciliation_cycle fixture.maintenance |> get_ok);
  let controls = Services.Worker_service.poll_controls fixture.workers (Worker.id worker) ~limit:10 |> get_ok in
  (match controls with
   | [{ Ports.Persistence.kind = Ports.Persistence.Stop_unknown; _ }] -> ()
   | _ -> Alcotest.fail "expected one stop-unknown control");
  ignore (Services.Worker_service.confirm_stop_unknown fixture.workers (Worker.id worker) unknown |> get_ok);
  Alcotest.(check int) "completed control hidden" 0
    (Services.Worker_service.poll_controls fixture.workers (Worker.id worker) ~limit:10 |> get_ok |> List.length)

let maintenance fixture ~batch ~passes = Services.Maintenance_service.create
  ~max_reconciliation_passes:passes ~persistence:fixture.persistence
  ~clock:(Support.Controlled_clock.port fixture.clock) ~health_policy
  ~acknowledgement_timeout:(positive Scalar.Timeout_seconds.create 30)
  ~execution_report_grace:(positive Scalar.Timeout_seconds.create 10)
  ~recovery_grace:(positive Scalar.Timeout_seconds.create 20) ~batch_size:batch

let test_reconciliation_batches_and_limit () =
  let fixture = fixture () in
  let large_registration = { registration with
    max_concurrency = positive Scalar.Concurrency.create 4 } in
  ignore (Services.Worker_service.register fixture.workers large_registration |> get_ok);
  for _ = 1 to 3 do
    ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
    ignore (Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned)
  done;
  Support.Controlled_clock.advance fixture.clock ~seconds:31 |> get_ok;
  let summary = Services.Maintenance_service.reconcile_startup
    (maintenance fixture ~batch:1 ~passes:10) |> get_ok in
  Alcotest.(check int) "all batches drained" 3 summary.assignments_recovered;
  let unknown = Attempt_id.of_string "00000000-0000-4000-8000-000000000088" |> get_ok in
  let worker = Services.Worker_service.list fixture.workers |> get_ok |> List.hd in
  ignore (Services.Worker_service.heartbeat fixture.workers (Worker.id worker)
    { available_slots = 4; active_attempt_ids = [unknown] } |> get_ok);
  match Services.Maintenance_service.reconcile_startup (maintenance fixture ~batch:1 ~passes:1) with
  | Error Services.Maintenance_service.Reconciliation_did_not_converge -> ()
  | _ -> Alcotest.fail "reconciliation pass limit was not enforced"

let test_durable_logs () =
  let fixture = fixture () in
  ignore (Services.Job_service.submit fixture.jobs submission |> get_ok);
  let worker = Services.Worker_service.register fixture.workers registration |> get_ok in
  let assignment = Services.Scheduling_service.run_once fixture.scheduling |> get_ok |> assigned in
  let make sequence stream payload = Log_entry.create ~attempt_id:(Attempt.id assignment.attempt)
    ~sequence:(Log_entry.sequence sequence |> get_ok) ~stream ~observed_at:timestamp ~payload |> get_ok in
  let entries = [make 1 Log_entry.Stdout "one"; make 2 Log_entry.Stderr "\000two"] in
  Alcotest.(check int) "highest accepted" 2
    (Services.Log_service.append_batch fixture.logs ~worker_id:(Worker.id worker)
      ~attempt_id:(Attempt.id assignment.attempt) entries |> get_ok);
  Alcotest.(check int) "replay accepted" 2
    (Services.Log_service.append_batch fixture.logs ~worker_id:(Worker.id worker)
      ~attempt_id:(Attempt.id assignment.attempt) entries |> get_ok);
  (match Services.Log_service.append_batch fixture.logs ~worker_id:(Worker.id worker)
      ~attempt_id:(Attempt.id assignment.attempt) [make 2 Log_entry.Stderr "different"] with
   | Error (Services.Log_service.Persistence_error (Ports.Persistence.Conflict _)) -> ()
   | _ -> Alcotest.fail "conflicting sequence was accepted");
  let snapshot = Services.Log_service.follow_snapshot fixture.logs
    ~attempt_id:(Attempt.id assignment.attempt) ~after_sequence:0 ~limit:10 |> get_ok in
  Alcotest.(check int) "ordered logs" 2 (List.length snapshot.entries);
  ignore (Services.Execution_service.acknowledge_attempt fixture.execution
    (Attempt.id assignment.attempt) |> get_ok);
  ignore (Services.Execution_service.start_attempt fixture.execution
    (Attempt.id assignment.attempt) |> get_ok);
  ignore (Services.Execution_service.report_success fixture.execution
    (Attempt.id assignment.attempt) ~exit_code:0 |> get_ok);
  ignore (Services.Log_service.append_batch fixture.logs ~worker_id:(Worker.id worker)
    ~attempt_id:(Attempt.id assignment.attempt) entries |> get_ok);
  match Services.Log_service.append_batch fixture.logs ~worker_id:(Worker.id worker)
      ~attempt_id:(Attempt.id assignment.attempt) [make 3 Log_entry.Stdout "late"] with
  | Error Services.Log_service.Terminal_attempt -> ()
  | _ -> Alcotest.fail "new terminal log was accepted"

let test_container_metadata () =
  let fixture=fixture() in
  let container_submission={submission with execution=Execution_spec.container ~image:"alpine:3.21"
      ~command:["true"]|>get_ok;required_labels=Worker_label.Set.empty} in
  ignore(Services.Job_service.submit fixture.jobs container_submission|>get_ok);
  let docker_label=Worker_label.create "docker"|>get_ok in
  let worker=Services.Worker_service.register fixture.workers
    {registration with labels=Worker_label.Set.singleton docker_label}|>get_ok in
  let assignment=Services.Scheduling_service.run_once fixture.scheduling|>get_ok|>assigned in
  let metadata : Ports.Persistence.container_metadata={attempt_id=Attempt.id assignment.attempt;
    worker_id=Worker.id worker;container_id="container-id";container_name="orchestraml-test";
    image_reference="alpine:3.21";created_at=timestamp;started_at=None;finished_at=None;
    removed_at=None;cleanup_outcome=Ports.Persistence.Pending} in
  ignore(Services.Container_service.record fixture.containers ~worker_id:(Worker.id worker) ~metadata|>get_ok);
  ignore(Services.Container_service.record fixture.containers ~worker_id:(Worker.id worker) ~metadata|>get_ok);
  let started={metadata with started_at=Some timestamp} in
  ignore(Services.Container_service.record fixture.containers ~worker_id:(Worker.id worker) ~metadata:started|>get_ok);
  (match Services.Container_service.record fixture.containers ~worker_id:(Worker.id worker)
      ~metadata:{started with container_id="changed"} with
   |Error(Services.Container_service.Conflict _)->()|_->Alcotest.fail "immutable identity changed");
  (match Services.Container_service.record fixture.containers ~worker_id:(Worker.id worker) ~metadata with
   |Error(Services.Container_service.Conflict _)->()|_->Alcotest.fail "lifecycle regressed");
  let removed={started with finished_at=Some timestamp;removed_at=Some timestamp;
    cleanup_outcome=Ports.Persistence.Removed} in
  ignore(Services.Container_service.record fixture.containers ~worker_id:(Worker.id worker) ~metadata:removed|>get_ok);
  match Services.Container_service.find fixture.containers metadata.attempt_id|>get_ok with
  |Some stored->Alcotest.(check bool) "removed persisted" true
      (stored.cleanup_outcome=Ports.Persistence.Removed)
  |None->Alcotest.fail "container metadata missing"

let () = Alcotest.run "orchestraml-application" [
  "memory", [
    Alcotest.test_case "transaction rollback" `Quick test_transaction_rollback;
    Alcotest.test_case "duplicate create" `Quick test_duplicate_repository_create;
  ];
  "vertical", [
    Alcotest.test_case "retry then success" `Quick test_retry_then_success;
    Alcotest.test_case "permanent failure" `Quick test_permanent_failure;
    Alcotest.test_case "no assignment" `Quick test_no_assignment;
    Alcotest.test_case "pending cancellation" `Quick test_pending_cancellation;
    Alcotest.test_case "timeout retry policy" `Quick test_timeout_uses_retry_policy;
    Alcotest.test_case "maximum attempts" `Quick test_maximum_attempts;
    Alcotest.test_case "idempotent submission" `Quick test_idempotent_submission;
    Alcotest.test_case "targeted poll and duplicate result" `Quick test_targeted_poll_and_duplicate_result;
    Alcotest.test_case "heartbeat validation" `Quick test_heartbeat_validation;
    Alcotest.test_case "assignment timeout recovery" `Quick test_assignment_timeout_recovery;
    Alcotest.test_case "deadline and cancellation controls" `Quick test_deadline_and_running_cancellation_controls;
    Alcotest.test_case "unknown process control" `Quick test_unknown_process_control;
    Alcotest.test_case "reconciliation batches and limit" `Quick test_reconciliation_batches_and_limit;
    Alcotest.test_case "durable logs" `Quick test_durable_logs;
    Alcotest.test_case "container metadata" `Quick test_container_metadata;
  ];
]
