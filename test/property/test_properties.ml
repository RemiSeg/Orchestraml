open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core

let get_ok = function Ok value -> value | Error _ -> failwith "invalid fixture"
let timestamp = Timestamp.of_rfc3339 "2026-01-01T00:00:00Z" |> get_ok
let jid suffix = Printf.sprintf "00000000-0000-4000-8000-%012d" suffix |> Job_id.of_string |> get_ok
let wid suffix = Printf.sprintf "00000000-0000-4000-8000-%012d" suffix |> Worker_id.of_string |> get_ok
let cpu value = Scalar.Cpu_millicores.create value |> get_ok
let memory value = Scalar.Memory_mib.create value |> get_ok
let resources c m = Resources.create ~cpu:(cpu c) ~memory:(memory m)
let retry_policy max_attempts = Retry_policy.create
  ~max_attempts:(Scalar.Max_attempts.create max_attempts |> get_ok)
  ~initial_delay:(Scalar.Retry_delay_seconds.create 2 |> get_ok) ~multiplier:3
  ~maximum_delay:(Scalar.Retry_delay_seconds.create 100 |> get_ok) ~retry_timeouts:false |> get_ok
let make_job ?(required_labels=Worker_label.Set.empty) id priority required_cpu required_memory = Job.create ~id:(jid id)
  ~name:(Scalar.Job_name.create "property job" |> get_ok)
  ~execution:(Execution_spec.command ~executable:"true" ~arguments:[] |> get_ok)
  ~priority:(Scalar.Priority.create priority) ~requirements:(resources required_cpu required_memory)
  ~required_labels ~retry_policy:(retry_policy 5)
  ~timeout:(Scalar.Timeout_seconds.create 10 |> get_ok) ~created_at:timestamp
let health_policy = Worker_health.create
  ~suspect_after:(Scalar.Timeout_seconds.create 10 |> get_ok)
  ~offline_after:(Scalar.Timeout_seconds.create 20 |> get_ok) |> get_ok
let make_worker ?(labels=Worker_label.Set.empty) id active max_concurrency available_cpu available_memory =
  Worker.create ~id:(wid id) ~name:"worker" ~labels
    ~max_concurrency:(Scalar.Concurrency.create max_concurrency |> get_ok) ~active_jobs:active
    ~total_resources:(resources available_cpu available_memory)
    ~reserved_resources:(resources 0 0) ~last_heartbeat:timestamp |> get_ok

let retry_delays_are_capped = QCheck.Test.make ~name:"retry delays are capped" QCheck.(1 -- 1000)
  (fun attempts -> Retry_policy.delay_seconds (retry_policy 1001) ~attempts_started:attempts <= 100)

let retry_limit_is_respected = QCheck.Test.make ~name:"maximum attempts are respected"
  QCheck.(pair (1 -- 20) (1 -- 30)) (fun (maximum, attempts) ->
    match Retry_policy.decide (retry_policy maximum) ~failure:(Failure.create Failure.Worker_lost)
      ~attempts_started:attempts ~now:timestamp with
    | Retry_policy.Retry_at _ -> attempts < maximum
    | Retry_policy.Do_not_retry Retry_policy.Attempts_exhausted -> attempts >= maximum
    | _ -> false)

let selected_worker_is_eligible = QCheck.Test.make ~name:"selected workers are eligible"
  QCheck.(quad (0 -- 4) (1 -- 5) (0 -- 3000) (0 -- 3000))
  (fun (active, maximum, required_cpu, required_memory) ->
    let active = min active maximum in
    let worker = make_worker 1 active maximum 2000 2000 in
    let job = make_job 1 0 required_cpu required_memory in
    match Scheduler_policy.select_worker ~health_policy ~now:timestamp ~job [worker] with
    | None -> true
    | Some selected -> Eligibility.evaluate ~health_policy ~now:timestamp ~job ~worker:selected |> Eligibility.is_eligible)

let higher_priority_wins = QCheck.Test.make ~name:"higher priority job wins"
  QCheck.(pair (int_range (-100) 100) (int_range (-100) 100)) (fun (a, b) ->
    if a = b then true else
    let first = make_job 1 a 0 0 and second = make_job 2 b 0 0 in
    match Scheduler_policy.select_job [first; second] with
    | None -> false
    | Some selected -> Scalar.Priority.value (Job.priority selected) = max a b)

let deterministic_selection = QCheck.Test.make ~name:"worker selection is deterministic" QCheck.(1 -- 20)
  (fun count ->
    let workers = List.init count (fun index -> make_worker (index + 1) 0 2 2000 2000) in
    let job = make_job 1 0 10 10 in
    match Scheduler_policy.select_worker ~health_policy ~now:timestamp ~job workers,
          Scheduler_policy.select_worker ~health_policy ~now:timestamp ~job workers with
    | Some left, Some right -> Worker_id.equal (Worker.id left) (Worker.id right)
    | None, None -> true | _ -> false)

let terminal_jobs_never_reactivate = QCheck.Test.make ~name:"terminal jobs never reactivate"
  QCheck.(oneof_list [`Completed; `Cancelled; `Failed]) (fun terminal ->
    let original = make_job 1 0 0 0 in
    let assigned, _ = Job.assign ~now:timestamp original |> Result.get_ok in
    let terminal_job = match terminal with
      | `Completed ->
          let running, _ = Job.start ~now:timestamp assigned |> Result.get_ok in
          fst (Job.complete ~now:timestamp running |> Result.get_ok)
      | `Cancelled -> fst (Job.request_cancel ~now:timestamp original |> Result.get_ok)
      | `Failed -> fst (Job.permanently_fail ~now:timestamp ~reason:"failure" assigned |> Result.get_ok)
    in
    match Job.assign ~now:timestamp terminal_job, Job.start ~now:timestamp terminal_job,
          Job.request_cancel ~now:timestamp terminal_job with
    | Error _, Error _, Error _ -> true | _ -> false)

let missing_required_labels_prevent_selection =
  QCheck.Test.make ~name:"missing required labels prevent selection" QCheck.bool (fun include_label ->
    let docker = Worker_label.create "docker" |> get_ok in
    let required_labels = Worker_label.Set.singleton docker in
    let worker_labels = if include_label then required_labels else Worker_label.Set.empty in
    let job = make_job ~required_labels 1 0 0 0 in
    let worker = make_worker ~labels:worker_labels 1 0 1 100 100 in
    match Scheduler_policy.select_worker ~health_policy ~now:timestamp ~job [worker] with
    | Some _ -> include_label
    | None -> not include_label)

let terminal_attempts_never_transition =
  QCheck.Test.make ~name:"terminal attempts never transition" QCheck.bool (fun succeed ->
    let attempt_id = Attempt_id.of_string "00000000-0000-4000-8000-000000000099" |> get_ok in
    let number = Scalar.Attempt_number.create 1 |> get_ok in
    let assigned = Attempt.create ~id:attempt_id ~job_id:(jid 99) ~number ~worker_id:(wid 99)
      ~assigned_at:timestamp in
    let acknowledged = Attempt.acknowledge ~now:timestamp assigned |> Result.get_ok in
    let running, _ = Attempt.start ~now:timestamp acknowledged |> Result.get_ok in
    let terminal = if succeed then
        fst (Attempt.succeed ~now:timestamp ~exit_code:0 running |> Result.get_ok)
      else fst (Attempt.time_out ~now:timestamp running |> Result.get_ok) in
    let failure = Failure.create Failure.Unknown in
    match Attempt.start ~now:timestamp terminal,
          Attempt.succeed ~now:timestamp ~exit_code:0 terminal,
          Attempt.fail ~now:timestamp ~failure terminal,
          Attempt.cancel ~now:timestamp terminal with
    | Error _, Error _, Error _, Error _ -> true | _ -> false)

let worker_capacity_round_trip =
  QCheck.Test.make ~name:"worker capacity reserve/release round trip"
    QCheck.(pair (0 -- 2000) (0 -- 2000)) (fun (required_cpu, required_memory) ->
      let worker = make_worker 1 0 2 2000 2000 in
      let requirements = resources required_cpu required_memory in
      match Worker.reserve ~requirements worker with
      | Error _ -> false
      | Ok reserved ->
          match Worker.release ~requirements reserved with
          | Error _ -> false
          | Ok released -> Worker.active_jobs released = 0
            && Scalar.Cpu_millicores.value (Resources.cpu (Worker.available_resources released)) = 2000
            && Scalar.Memory_mib.value (Resources.memory (Worker.available_resources released)) = 2000)

let () = Alcotest.run "orchestraml-domain-properties" [
  "properties", List.map QCheck_alcotest.to_alcotest [
    retry_delays_are_capped; retry_limit_is_respected; selected_worker_is_eligible;
    higher_priority_wins; deterministic_selection; terminal_jobs_never_reactivate;
    missing_required_labels_prevent_selection; terminal_attempts_never_transition;
    worker_capacity_round_trip;
  ]
]
