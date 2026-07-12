open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core

let get_ok = function Ok value -> value | Error error -> Alcotest.failf "%a" Validation_error.pp error
let timestamp value = Timestamp.of_rfc3339 value |> get_ok
let job_id = Job_id.of_string "00000000-0000-4000-8000-000000000001" |> get_ok
let attempt_id = Attempt_id.of_string "00000000-0000-4000-8000-000000000002" |> get_ok
let worker_id = Worker_id.of_string "00000000-0000-4000-8000-000000000003" |> get_ok
let now = timestamp "2026-01-01T00:00:00Z"
let later seconds = match Timestamp.add_seconds now seconds with Some value -> value | None -> Alcotest.fail "time overflow"
let int_value create value = create value |> get_ok

let retry_policy () = Retry_policy.create
  ~max_attempts:(int_value Scalar.Max_attempts.create 3)
  ~initial_delay:(int_value Scalar.Retry_delay_seconds.create 5)
  ~multiplier:2 ~maximum_delay:(int_value Scalar.Retry_delay_seconds.create 20)
  ~retry_timeouts:false |> get_ok

let labels values = List.fold_left (fun set value ->
  Worker_label.Set.add (Worker_label.create value |> get_ok) set)
  Worker_label.Set.empty values

let resources cpu memory = Resources.create
  ~cpu:(int_value Scalar.Cpu_millicores.create cpu)
  ~memory:(int_value Scalar.Memory_mib.create memory)

let job ?(priority=0) ?(required_labels=Worker_label.Set.empty) ?(created_at=now) () =
  Job.create ~id:job_id ~name:(Scalar.Job_name.create "test job" |> get_ok)
    ~execution:(Execution_spec.command ~executable:"echo" ~arguments:["hello"] |> get_ok)
    ~priority:(Scalar.Priority.create priority) ~requirements:(resources 500 256)
    ~required_labels ~retry_policy:(retry_policy ())
    ~timeout:(int_value Scalar.Timeout_seconds.create 30) ~created_at

let worker ?(active_jobs=0) ?(max_concurrency=2) ?(labels=labels ["linux"])
    ?(total=resources 2000 2048) ?(reserved=resources 0 0) ?(heartbeat=now) () =
  Worker.create ~id:worker_id ~name:"worker" ~labels
    ~max_concurrency:(int_value Scalar.Concurrency.create max_concurrency)
    ~active_jobs ~total_resources:total ~reserved_resources:reserved
    ~last_heartbeat:heartbeat |> get_ok

let health_policy = Worker_health.create
  ~suspect_after:(int_value Scalar.Timeout_seconds.create 10)
  ~offline_after:(int_value Scalar.Timeout_seconds.create 20) |> get_ok

let check_error = function Error _ -> () | Ok _ -> Alcotest.fail "expected an error"
let check_job_status expected value =
  Alcotest.(check string) "job status" (Job_status.to_string expected)
    (Job.status value |> Job_status.to_string)
let check_attempt_status expected value =
  Alcotest.(check string) "attempt status" (Attempt_status.to_string expected)
    (Attempt.status value |> Attempt_status.to_string)

let test_identifiers () =
  Alcotest.(check string) "round trip" "00000000-0000-4000-8000-000000000001" (Job_id.to_string job_id);
  Job_id.of_string "invalid" |> (function Error _ -> () | Ok _ -> Alcotest.fail "invalid UUID accepted")

let test_scalars_and_labels () =
  Scalar.Cpu_millicores.create (-1) |> (function Error _ -> () | Ok _ -> Alcotest.fail "negative CPU accepted");
  Scalar.Timeout_seconds.create 0 |> (function Error _ -> () | Ok _ -> Alcotest.fail "zero timeout accepted");
  let label = Worker_label.create "  LINUX-X86_64 " |> get_ok in
  Alcotest.(check string) "normalized label" "linux-x86_64" (Worker_label.value label);
  Worker_label.create "bad label" |> (function Error _ -> () | Ok _ -> Alcotest.fail "invalid label accepted")

let test_execution_specs () =
  Execution_spec.command ~executable:" " ~arguments:[] |> (function Error _ -> () | Ok _ -> Alcotest.fail "empty command accepted");
  Execution_spec.container ~image:"alpine:3" ~command:["echo"] |> (function Ok _ -> () | Error e -> Alcotest.failf "%a" Validation_error.pp e)

let test_job_happy_path_and_terminal () =
  let pending = job () in
  let assigned, _ = Job.assign ~now:(later 1) pending |> Result.get_ok in
  let running, _ = Job.start ~now:(later 2) assigned |> Result.get_ok in
  let completed, _ = Job.complete ~now:(later 3) running |> Result.get_ok in
  check_job_status Job_status.Completed completed;
  Alcotest.(check int) "attempt count" 1 (Job.attempts_started completed);
  Job.request_cancel ~now:(later 4) completed |> check_error

let test_job_retry_and_cancel () =
  let assigned, _ = Job.assign ~now:(later 1) (job ()) |> Result.get_ok in
  let waiting, _ = Job.schedule_retry ~now:(later 2) ~retry_at:(later 10) ~reason:"lost" assigned |> Result.get_ok in
  Job.release_retry ~now:(later 9) waiting |> check_error;
  let pending, _ = Job.release_retry ~now:(later 10) waiting |> Result.get_ok in
  check_job_status Job_status.Pending pending;
  let cancelled, _ = Job.request_cancel ~now:(later 11) pending |> Result.get_ok in
  check_job_status Job_status.Cancelled cancelled

let test_running_job_cancellation_and_failure () =
  let assigned, _ = Job.assign ~now:(later 1) (job ()) |> Result.get_ok in
  let running, _ = Job.start ~now:(later 2) assigned |> Result.get_ok in
  let cancelling, _ = Job.request_cancel ~now:(later 3) running |> Result.get_ok in
  check_job_status Job_status.Cancelling cancelling;
  let cancelled, _ = Job.confirm_cancel ~now:(later 4) cancelling |> Result.get_ok in
  check_job_status Job_status.Cancelled cancelled;
  Job.assign ~now:(later 5) cancelled |> check_error;
  let assigned, _ = Job.assign ~now:(later 1) (job ()) |> Result.get_ok in
  let failed, _ = Job.permanently_fail ~now:(later 2) ~reason:"invalid" assigned |> Result.get_ok in
  check_job_status Job_status.Permanently_failed failed;
  Job.request_cancel ~now:(later 3) failed |> check_error

let test_transition_timestamps () =
  let assigned, _ = Job.assign ~now:(later 2) (job ()) |> Result.get_ok in
  Job.start ~now:(later 1) assigned |> check_error;
  Job.schedule_retry ~now:(later 3) ~retry_at:(later 2) ~reason:"bad deadline" assigned |> check_error;
  let number = int_value Scalar.Attempt_number.create 1 in
  let attempt = Attempt.create ~id:attempt_id ~job_id ~number ~worker_id ~assigned_at:(later 2) in
  Attempt.start ~now:(later 1) attempt |> check_error

let test_attempt_transitions () =
  let number = int_value Scalar.Attempt_number.create 1 in
  let assigned = Attempt.create ~id:attempt_id ~job_id ~number ~worker_id ~assigned_at:now in
  Attempt.succeed ~now:(later 1) ~exit_code:0 assigned |> check_error;
  Attempt.start ~now:(later 1) assigned |> check_error;
  let acknowledged = Attempt.acknowledge ~now:(later 1) assigned |> Result.get_ok in
  let acknowledged_again = Attempt.acknowledge ~now:(later 2) acknowledged |> Result.get_ok in
  Alcotest.(check string) "idempotent acknowledgement"
    (Attempt.acknowledged_at acknowledged |> Option.get |> Timestamp.to_rfc3339)
    (Attempt.acknowledged_at acknowledged_again |> Option.get |> Timestamp.to_rfc3339);
  let running, _ = Attempt.start ~now:(later 2) acknowledged |> Result.get_ok in
  let succeeded, _ = Attempt.succeed ~now:(later 2) ~exit_code:0 running |> Result.get_ok in
  check_attempt_status Attempt_status.Succeeded succeeded;
  Attempt.fail ~now:(later 3) ~failure:(Failure.create Failure.Unknown) succeeded |> check_error

let test_retry_policy () =
  let policy = retry_policy () in
  Alcotest.(check int) "attempt 1" 5 (Retry_policy.delay_seconds policy ~attempts_started:1);
  Alcotest.(check int) "attempt 2" 10 (Retry_policy.delay_seconds policy ~attempts_started:2);
  Alcotest.(check int) "capped" 20 (Retry_policy.delay_seconds policy ~attempts_started:30);
  (match Retry_policy.decide policy ~failure:(Failure.create Failure.Worker_lost) ~attempts_started:1 ~now with
   | Retry_policy.Retry_at value -> Alcotest.(check string) "retry time" (Timestamp.to_rfc3339 (later 5)) (Timestamp.to_rfc3339 value)
   | _ -> Alcotest.fail "retryable failure not retried");
  (match Retry_policy.decide policy ~failure:(Failure.create Failure.Invalid_command) ~attempts_started:1 ~now with
   | Retry_policy.Do_not_retry Retry_policy.Non_retryable_failure -> ()
   | _ -> Alcotest.fail "permanent failure retried")

let test_health_and_eligibility () =
  Alcotest.(check string) "healthy" "healthy"
    (Worker_health.classify health_policy ~now:(later 5) ~last_heartbeat:now |> Worker_health.to_string);
  Alcotest.(check string) "suspect" "suspect"
    (Worker_health.classify health_policy ~now:(later 10) ~last_heartbeat:now |> Worker_health.to_string);
  Alcotest.(check string) "offline" "offline"
    (Worker_health.classify health_policy ~now:(later 20) ~last_heartbeat:now |> Worker_health.to_string);
  let required_labels = labels ["linux"; "docker"] in
  match Eligibility.evaluate ~health_policy ~now ~job:(job ~required_labels ()) ~worker:(worker ()) with
  | Eligibility.Ineligible reasons -> Alcotest.(check bool) "has rejection" true (List.length reasons > 0)
  | Eligibility.Eligible -> Alcotest.fail "incompatible worker accepted"

let test_scheduler () =
  let early = job ~priority:1 () in
  let high = job ~priority:10 ~created_at:(later 1) () in
  match Scheduler_policy.select_job [early; high] with
  | Some selected -> Alcotest.(check int) "highest priority" 10 (Job.priority selected |> Scalar.Priority.value)
  | None -> Alcotest.fail "no job selected"

let test_worker_capacity () =
  let original = worker () in
  let reserved = Worker.reserve ~requirements:(resources 500 256) original |> Result.get_ok in
  Alcotest.(check int) "active after reserve" 1 (Worker.active_jobs reserved);
  Alcotest.(check int) "available cpu" 1500
    (Worker.available_resources reserved |> Resources.cpu |> Scalar.Cpu_millicores.value);
  let released = Worker.release ~requirements:(resources 500 256) reserved |> Result.get_ok in
  Alcotest.(check int) "active after release" 0 (Worker.active_jobs released);
  Worker.release ~requirements:(resources 500 256) released
  |> (function Error Worker.Invalid_release -> () | _ -> Alcotest.fail "invalid release accepted")

let test_worker_capacity_rejections () =
  Worker.reserve ~requirements:(resources 1 1) (worker ~active_jobs:2 ~max_concurrency:2 ())
  |> (function Error Worker.No_concurrency -> () | _ -> Alcotest.fail "full worker accepted");
  Worker.reserve ~requirements:(resources 201 1)
    (worker ~total:(resources 200 200) ())
  |> (function Error Worker.Insufficient_cpu -> () | _ -> Alcotest.fail "insufficient CPU accepted");
  Worker.reserve ~requirements:(resources 1 201)
    (worker ~total:(resources 200 200) ())
  |> (function Error Worker.Insufficient_memory -> () | _ -> Alcotest.fail "insufficient memory accepted")

let test_worker_reconfiguration_and_heartbeat () =
  let reserved = Worker.reserve ~requirements:(resources 500 256) (worker ()) |> Result.get_ok in
  (match Worker.reconfigure ~name:"smaller" ~labels:Worker_label.Set.empty
      ~max_concurrency:(int_value Scalar.Concurrency.create 1)
      ~total_resources:(resources 100 100) reserved with
   | Error _ -> () | Ok _ -> Alcotest.fail "reconfiguration below reservations succeeded");
  let updated = Worker.heartbeat ~now:(later 5) reserved |> Result.get_ok in
  Alcotest.(check int) "heartbeat preserves active jobs" 1 (Worker.active_jobs updated);
  Alcotest.(check int) "heartbeat preserves CPU reservation" 500
    (Worker.reserved_resources updated |> Resources.cpu |> Scalar.Cpu_millicores.value)

let test_persistence_restoration () =
  let pending = job () in
  let restored = Job.snapshot pending |> Job.restore |> Result.get_ok in
  Alcotest.(check string) "job restored" "pending" (Job.status restored |> Job_status.to_string);
  let invalid : Job.snapshot = { (Job.snapshot pending) with attempts_started = -1 } in
  (match Job.restore invalid with Error _ -> () | Ok _ -> Alcotest.fail "invalid job restored");
  let number = int_value Scalar.Attempt_number.create 1 in
  let assigned = Attempt.create ~id:attempt_id ~job_id ~number ~worker_id ~assigned_at:now in
  let restored_attempt = Attempt.snapshot assigned |> Attempt.restore |> Result.get_ok in
  check_attempt_status Attempt_status.Assigned restored_attempt;
  let invalid_attempt : Attempt.snapshot = { (Attempt.snapshot assigned) with status = Attempt_status.Succeeded } in
  (match Attempt.restore invalid_attempt with Error _ -> () | Ok _ -> Alcotest.fail "invalid attempt restored")

let () = Alcotest.run "orchestraml-domain" [
  "values", [
    Alcotest.test_case "identifiers" `Quick test_identifiers;
    Alcotest.test_case "scalars and labels" `Quick test_scalars_and_labels;
    Alcotest.test_case "execution specs" `Quick test_execution_specs;
  ];
  "state machines", [
    Alcotest.test_case "job happy path" `Quick test_job_happy_path_and_terminal;
    Alcotest.test_case "job retry and cancel" `Quick test_job_retry_and_cancel;
    Alcotest.test_case "running cancellation and failure" `Quick test_running_job_cancellation_and_failure;
    Alcotest.test_case "timestamp consistency" `Quick test_transition_timestamps;
    Alcotest.test_case "attempt transitions" `Quick test_attempt_transitions;
  ];
  "policies", [
    Alcotest.test_case "retry" `Quick test_retry_policy;
    Alcotest.test_case "health and eligibility" `Quick test_health_and_eligibility;
    Alcotest.test_case "scheduler" `Quick test_scheduler;
    Alcotest.test_case "worker capacity" `Quick test_worker_capacity;
    Alcotest.test_case "worker capacity rejections" `Quick test_worker_capacity_rejections;
    Alcotest.test_case "worker reconfiguration and heartbeat" `Quick test_worker_reconfiguration_and_heartbeat;
    Alcotest.test_case "persistence restoration" `Quick test_persistence_restoration;
  ];
]
