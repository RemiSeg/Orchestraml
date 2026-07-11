open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
module U = Yojson.Safe.Util
let unwrap = function Ok value -> value | Error error -> failwith (Format.asprintf "%a" Validation_error.pp error)
let optional_string json name = match U.member name json with `Null -> None | value -> Some (U.to_string value)
let timestamp value = Timestamp.of_rfc3339 value |> unwrap
let timestamp_json = function None -> `Null | Some value -> `String (Timestamp.to_rfc3339 value)
let strings json name = U.member name json |> U.to_list |> List.map U.to_string
let labels values = List.fold_left (fun set value ->
  Worker_label.Set.add (Worker_label.create value |> unwrap) set) Worker_label.Set.empty values
let execution_json value = Execution_spec.fold value
  ~command:(fun executable arguments -> `Assoc ["type",`String "command";"executable",`String executable;
    "arguments",`List (List.map (fun value -> `String value) arguments)])
  ~container:(fun image command -> `Assoc ["type",`String "container";"image",`String image;
    "command",`List (List.map (fun value -> `String value) command)])
let execution json = match U.member "type" json |> U.to_string with
  | "command" -> Execution_spec.command ~executable:(U.member "executable" json |> U.to_string)
      ~arguments:(strings json "arguments") |> unwrap
  | "container" -> Execution_spec.container ~image:(U.member "image" json |> U.to_string)
      ~command:(strings json "command") |> unwrap
  | _ -> failwith "invalid execution type"
let protect operation = try Ok (operation ()) with
  | Failure message -> Error message
  | Yojson.Safe.Util.Type_error (message, _) | Yojson.Safe.Util.Undefined (message, _) -> Error message

let job_to_string job =
  let snapshot = Job.snapshot job and retry = Job.retry_policy job in
  `Assoc ["id",`String (Job_id.to_string snapshot.id);"name",`String (Scalar.Job_name.value snapshot.name);
    "status",`String (Job_status.to_string snapshot.status);"execution",execution_json snapshot.execution;
    "priority",`Int (Scalar.Priority.value snapshot.priority);
    "cpu",`Int (Resources.cpu snapshot.requirements |> Scalar.Cpu_millicores.value);
    "memory",`Int (Resources.memory snapshot.requirements |> Scalar.Memory_mib.value);
    "labels",`List (Worker_label.Set.elements snapshot.required_labels |> List.map (fun v -> `String (Worker_label.value v)));
    "timeout",`Int (Scalar.Timeout_seconds.value snapshot.timeout);
    "max_attempts",`Int (Retry_policy.max_attempts retry |> Scalar.Max_attempts.value);
    "initial_delay",`Int (Retry_policy.initial_delay retry |> Scalar.Retry_delay_seconds.value);
    "multiplier",`Int (Retry_policy.multiplier retry);
    "maximum_delay",`Int (Retry_policy.maximum_delay retry |> Scalar.Retry_delay_seconds.value);
    "retry_timeouts",`Bool (Retry_policy.retry_timeouts retry);
    "idempotency_key",(match snapshot.idempotency_key with None -> `Null | Some key -> `String (Idempotency_key.value key));
    "next_retry_at",timestamp_json snapshot.next_retry_at;"attempts_started",`Int snapshot.attempts_started;
    "created_at",`String (Timestamp.to_rfc3339 snapshot.created_at);
    "updated_at",`String (Timestamp.to_rfc3339 snapshot.updated_at)] |> Yojson.Safe.to_string ~std:true
let job_of_string value = protect (fun () ->
  let json = Yojson.Safe.from_string value in
  let retry_policy = Retry_policy.create
    ~max_attempts:(U.member "max_attempts" json |> U.to_int |> Scalar.Max_attempts.create |> unwrap)
    ~initial_delay:(U.member "initial_delay" json |> U.to_int |> Scalar.Retry_delay_seconds.create |> unwrap)
    ~multiplier:(U.member "multiplier" json |> U.to_int)
    ~maximum_delay:(U.member "maximum_delay" json |> U.to_int |> Scalar.Retry_delay_seconds.create |> unwrap)
    ~retry_timeouts:(U.member "retry_timeouts" json |> U.to_bool) |> unwrap in
  let snapshot : Job.snapshot = {
    id = U.member "id" json |> U.to_string |> Job_id.of_string |> unwrap;
    name = U.member "name" json |> U.to_string |> Scalar.Job_name.create |> unwrap;
    status = U.member "status" json |> U.to_string |> Job_status.of_string |> unwrap;
    execution = U.member "execution" json |> execution;
    priority = U.member "priority" json |> U.to_int |> Scalar.Priority.create;
    requirements = Resources.create
      ~cpu:(U.member "cpu" json |> U.to_int |> Scalar.Cpu_millicores.create |> unwrap)
      ~memory:(U.member "memory" json |> U.to_int |> Scalar.Memory_mib.create |> unwrap);
    required_labels = strings json "labels" |> labels; retry_policy;
    timeout = U.member "timeout" json |> U.to_int |> Scalar.Timeout_seconds.create |> unwrap;
    idempotency_key = optional_string json "idempotency_key" |> Option.map (fun v -> Idempotency_key.create v |> unwrap);
    next_retry_at = optional_string json "next_retry_at" |> Option.map timestamp;
    attempts_started = U.member "attempts_started" json |> U.to_int;
    created_at = U.member "created_at" json |> U.to_string |> timestamp;
    updated_at = U.member "updated_at" json |> U.to_string |> timestamp } in
  Job.restore snapshot |> unwrap)

let outcome_json = function
  | None -> `Null | Some (Attempt.Success code) -> `Assoc ["type",`String "success";"exit_code",`Int code]
  | Some (Attempt.Failure failure) -> `Assoc ["type",`String "failure";
      "kind",`String (Failure.kind failure |> Failure.kind_to_string);
      "message",(match Failure.message failure with None -> `Null | Some v -> `String v)]
  | Some Attempt.Timed_out_outcome -> `Assoc ["type",`String "timed_out"]
  | Some (Attempt.Lost_outcome reason) -> `Assoc ["type",`String "lost";"reason",`String reason]
  | Some Attempt.Cancelled_outcome -> `Assoc ["type",`String "cancelled"]
let outcome = function
  | `Null -> None
  | json -> match U.member "type" json |> U.to_string with
      | "success" -> Some (Attempt.Success (U.member "exit_code" json |> U.to_int))
      | "failure" -> Some (Attempt.Failure (Failure.create
          ?message:(optional_string json "message")
          (U.member "kind" json |> U.to_string |> Failure.kind_of_string |> unwrap)))
      | "timed_out" -> Some Attempt.Timed_out_outcome
      | "lost" -> Some (Attempt.Lost_outcome (U.member "reason" json |> U.to_string))
      | "cancelled" -> Some Attempt.Cancelled_outcome
      | _ -> failwith "invalid attempt outcome"
let attempt_to_string attempt =
  let s = Attempt.snapshot attempt in
  `Assoc ["id",`String (Attempt_id.to_string s.id);"job_id",`String (Job_id.to_string s.job_id);
    "worker_id",`String (Worker_id.to_string s.worker_id);
    "number",`Int (Scalar.Attempt_number.value s.number);"status",`String (Attempt_status.to_string s.status);
    "assigned_at",`String (Timestamp.to_rfc3339 s.assigned_at);"started_at",timestamp_json s.started_at;
    "finished_at",timestamp_json s.finished_at;"outcome",outcome_json s.outcome]
  |> Yojson.Safe.to_string ~std:true
let attempt_of_string value = protect (fun () ->
  let json = Yojson.Safe.from_string value in
  let snapshot : Attempt.snapshot = {
    id = U.member "id" json |> U.to_string |> Attempt_id.of_string |> unwrap;
    job_id = U.member "job_id" json |> U.to_string |> Job_id.of_string |> unwrap;
    worker_id = U.member "worker_id" json |> U.to_string |> Worker_id.of_string |> unwrap;
    number = U.member "number" json |> U.to_int |> Scalar.Attempt_number.create |> unwrap;
    status = U.member "status" json |> U.to_string |> Attempt_status.of_string |> unwrap;
    assigned_at = U.member "assigned_at" json |> U.to_string |> timestamp;
    started_at = optional_string json "started_at" |> Option.map timestamp;
    finished_at = optional_string json "finished_at" |> Option.map timestamp;
    outcome = U.member "outcome" json |> outcome } in
  Attempt.restore snapshot |> unwrap)

let worker_to_string worker = `Assoc [
  "id",`String (Worker.id worker |> Worker_id.to_string);"name",`String (Worker.name worker);
  "labels",`List (Worker.labels worker |> Worker_label.Set.elements |> List.map (fun v -> `String (Worker_label.value v)));
  "max_concurrency",`Int (Worker.max_concurrency worker |> Scalar.Concurrency.value);
  "active_jobs",`Int (Worker.active_jobs worker);
  "total_cpu",`Int (Worker.total_resources worker |> Resources.cpu |> Scalar.Cpu_millicores.value);
  "total_memory",`Int (Worker.total_resources worker |> Resources.memory |> Scalar.Memory_mib.value);
  "reserved_cpu",`Int (Worker.reserved_resources worker |> Resources.cpu |> Scalar.Cpu_millicores.value);
  "reserved_memory",`Int (Worker.reserved_resources worker |> Resources.memory |> Scalar.Memory_mib.value);
  "last_heartbeat",`String (Worker.last_heartbeat worker |> Timestamp.to_rfc3339)] |> Yojson.Safe.to_string ~std:true
let worker_of_string value = protect (fun () ->
  let json = Yojson.Safe.from_string value in
  Worker.create ~id:(U.member "id" json |> U.to_string |> Worker_id.of_string |> unwrap)
    ~name:(U.member "name" json |> U.to_string) ~labels:(strings json "labels" |> labels)
    ~max_concurrency:(U.member "max_concurrency" json |> U.to_int |> Scalar.Concurrency.create |> unwrap)
    ~active_jobs:(U.member "active_jobs" json |> U.to_int)
    ~total_resources:(Resources.create
      ~cpu:(U.member "total_cpu" json |> U.to_int |> Scalar.Cpu_millicores.create |> unwrap)
      ~memory:(U.member "total_memory" json |> U.to_int |> Scalar.Memory_mib.create |> unwrap))
    ~reserved_resources:(Resources.create
      ~cpu:(U.member "reserved_cpu" json |> U.to_int |> Scalar.Cpu_millicores.create |> unwrap)
      ~memory:(U.member "reserved_memory" json |> U.to_int |> Scalar.Memory_mib.create |> unwrap))
    ~last_heartbeat:(U.member "last_heartbeat" json |> U.to_string |> timestamp) |> unwrap)
