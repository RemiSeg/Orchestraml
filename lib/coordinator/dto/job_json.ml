open Orchestraml_domain
open Foundation
open Shared
open Core
module Job_service = Orchestraml_application.Services.Job_service
module U = Yojson.Safe.Util

type decoded_submission = { submission : Job_service.submission; canonical_payload : string }
let get_result = function Ok value -> value | Error error -> raise (Failure (Format.asprintf "%a" Validation_error.pp error))
let member name json = U.member name json
let int_default name default json = match member name json with `Null -> default | value -> U.to_int value
let strings_default name json = match member name json with `Null -> [] | value -> U.to_list value |> List.map U.to_string
let execution_of_json json =
  match member "type" json |> U.to_string with
  | "command" -> Execution_spec.command
      ~executable:(member "executable" json |> U.to_string)
      ~arguments:(strings_default "arguments" json) |> get_result
  | "container" -> Execution_spec.container
      ~image:(member "image" json |> U.to_string)
      ~command:(strings_default "command" json) |> get_result
  | _ -> raise (Failure "execution.type must be 'command' or 'container'")
let labels_of_strings values = List.fold_left (fun labels value ->
  Worker_label.Set.add (Worker_label.create value |> get_result) labels)
  Worker_label.Set.empty values
let execution_json execution = Execution_spec.fold execution
  ~command:(fun executable arguments -> `Assoc ["type", `String "command";
    "executable", `String executable; "arguments", `List (List.map (fun value -> `String value) arguments)])
  ~container:(fun image command -> `Assoc ["type", `String "container";
    "image", `String image; "command", `List (List.map (fun value -> `String value) command)])
let canonical_submission (submission : Job_service.submission) =
  `Assoc [
    "name", `String (Scalar.Job_name.value submission.name);
    "execution", execution_json submission.execution;
    "priority", `Int (Scalar.Priority.value submission.priority);
    "timeout_seconds", `Int (Scalar.Timeout_seconds.value submission.timeout);
    "max_attempts", `Int (Retry_policy.max_attempts submission.retry_policy |> Scalar.Max_attempts.value);
    "retry", `Assoc [
      "initial_delay_seconds", `Int (Retry_policy.initial_delay submission.retry_policy |> Scalar.Retry_delay_seconds.value);
      "multiplier", `Int (Retry_policy.multiplier submission.retry_policy);
      "maximum_delay_seconds", `Int (Retry_policy.maximum_delay submission.retry_policy |> Scalar.Retry_delay_seconds.value);
      "retry_timeouts", `Bool (Retry_policy.retry_timeouts submission.retry_policy)];
    "required_labels", `List (Worker_label.Set.elements submission.required_labels
      |> List.map (fun label -> `String (Worker_label.value label)));
    "resources", `Assoc [
      "cpu_millicores", `Int (Resources.cpu submission.requirements |> Scalar.Cpu_millicores.value);
      "memory_mib", `Int (Resources.memory submission.requirements |> Scalar.Memory_mib.value)]
  ] |> Yojson.Safe.to_string ~std:true
let decode_submission json =
  try
    let retry = member "retry" json in
    let resources = match member "resources" json with `Null -> `Assoc [] | value -> value in
    let submission : Job_service.submission = {
      name = member "name" json |> U.to_string |> Scalar.Job_name.create |> get_result;
      execution = member "execution" json |> execution_of_json;
      priority = Scalar.Priority.create (int_default "priority" 0 json);
      timeout = member "timeout_seconds" json |> U.to_int |> Scalar.Timeout_seconds.create |> get_result;
      requirements = Resources.create
        ~cpu:(int_default "cpu_millicores" 0 resources |> Scalar.Cpu_millicores.create |> get_result)
        ~memory:(int_default "memory_mib" 0 resources |> Scalar.Memory_mib.create |> get_result);
      required_labels = strings_default "required_labels" json |> labels_of_strings;
      retry_policy = Retry_policy.create
        ~max_attempts:(member "max_attempts" json |> U.to_int |> Scalar.Max_attempts.create |> get_result)
        ~initial_delay:(member "initial_delay_seconds" retry |> U.to_int |> Scalar.Retry_delay_seconds.create |> get_result)
        ~multiplier:(member "multiplier" retry |> U.to_int)
        ~maximum_delay:(member "maximum_delay_seconds" retry |> U.to_int |> Scalar.Retry_delay_seconds.create |> get_result)
        ~retry_timeouts:(member "retry_timeouts" retry |> U.to_bool) |> get_result;
    } in
    Ok { submission; canonical_payload = canonical_submission submission }
  with
  | Yojson.Safe.Util.Type_error (message, _) -> Error [message]
  | Yojson.Safe.Util.Undefined (message, _) -> Error [message]
  | Failure message -> Error [message]

let job value = `Assoc [
  "id", `String (Job.id value |> Identifiers.Job_id.to_string);
  "name", `String (Job.name value |> Scalar.Job_name.value);
  "status", `String (Job.status value |> Job_status.to_string);
  "execution", execution_json (Job.execution value);
  "priority", `Int (Job.priority value |> Scalar.Priority.value);
  "resources", `Assoc ["cpu_millicores", `Int (Job.requirements value |> Resources.cpu |> Scalar.Cpu_millicores.value);
    "memory_mib", `Int (Job.requirements value |> Resources.memory |> Scalar.Memory_mib.value)];
  "required_labels", `List (Job.required_labels value |> Worker_label.Set.elements
    |> List.map (fun label -> `String (Worker_label.value label)));
  "timeout_seconds", `Int (Job.timeout value |> Scalar.Timeout_seconds.value);
  "attempts_started", `Int (Job.attempts_started value);
  "next_retry_at", (match Job.next_retry_at value with None -> `Null | Some value -> `String (Timestamp.to_rfc3339 value));
  "created_at", `String (Job.created_at value |> Timestamp.to_rfc3339);
  "updated_at", `String (Job.updated_at value |> Timestamp.to_rfc3339)
]
let attempt value = `Assoc [
  "id", `String (Attempt.id value |> Identifiers.Attempt_id.to_string);
  "job_id", `String (Attempt.job_id value |> Identifiers.Job_id.to_string);
  "worker_id", `String (Attempt.worker_id value |> Identifiers.Worker_id.to_string);
  "attempt_number", `Int (Attempt.number value |> Scalar.Attempt_number.value);
  "status", `String (Attempt.status value |> Attempt_status.to_string);
  "assigned_at", `String (Attempt.assigned_at value |> Timestamp.to_rfc3339);
  "started_at", (match Attempt.started_at value with None -> `Null | Some value -> `String (Timestamp.to_rfc3339 value));
  "finished_at", (match Attempt.finished_at value with None -> `Null | Some value -> `String (Timestamp.to_rfc3339 value))
]
let event value = `Assoc [
  "entity", `String (match value.Domain_event.entity with Domain_event.Job _ -> "job" | Domain_event.Attempt _ -> "attempt");
  "from_status", `String value.from_status; "to_status", `String value.to_status;
  "occurred_at", `String (Timestamp.to_rfc3339 value.occurred_at);
  "reason", (match value.reason with None -> `Null | Some value -> `String value)
]
