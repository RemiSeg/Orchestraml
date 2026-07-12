open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
module Services = Orchestraml_application.Services
module U = Yojson.Safe.Util
type heartbeat = Services.Worker_service.heartbeat
type result_report = Succeeded of int | Failed of Failure.t | Timed_out | Lost of string | Cancelled
let unwrap = function Ok value -> value | Error error ->
  raise (Failure (Format.asprintf "%a" Validation_error.pp error))
let protect operation = try Ok (operation ()) with
  | Yojson.Safe.Util.Type_error (message, _) | Yojson.Safe.Util.Undefined (message, _)
  | Failure message -> Error [message]
let member = U.member
let labels json = match member "labels" json with
  | `Null -> Worker_label.Set.empty
  | value -> U.to_list value |> List.fold_left (fun set item ->
      Worker_label.Set.add (U.to_string item |> Worker_label.create |> unwrap) set)
      Worker_label.Set.empty
let decode_registration json = protect (fun () ->
  let resources = member "resources" json in
  ({ Services.Worker_service.name = member "name" json |> U.to_string;
     labels = labels json;
     max_concurrency = member "max_concurrency" json |> U.to_int
       |> Scalar.Concurrency.create |> unwrap;
     total_resources = Resources.create
       ~cpu:(member "cpu_millicores" resources |> U.to_int |> Scalar.Cpu_millicores.create |> unwrap)
       ~memory:(member "memory_mib" resources |> U.to_int |> Scalar.Memory_mib.create |> unwrap) }
   : Services.Worker_service.registration))
let decode_heartbeat json = protect (fun () ->
  let attempts = match member "active_attempt_ids" json with `Null -> [] | value ->
    U.to_list value |> List.map (fun item -> U.to_string item |> Attempt_id.of_string |> unwrap) in
  ({ Services.Worker_service.available_slots = member "available_slots" json |> U.to_int;
     active_attempt_ids = attempts } : heartbeat))
let decode_result json = protect (fun () ->
  match member "type" json |> U.to_string with
  | "succeeded" -> Succeeded (member "exit_code" json |> U.to_int)
  | "failed" -> let failure = member "failure" json in
      Failed (Failure.create
        ?message:(match member "message" failure with `Null -> None | value -> Some (U.to_string value))
        (member "kind" failure |> U.to_string |> Failure.kind_of_string |> unwrap))
  | "timed_out" -> Timed_out
  | "lost" -> Lost (member "reason" json |> U.to_string)
  | "cancelled" -> Cancelled
  | _ -> raise (Failure "result type is invalid"))
let worker value = `Assoc [
  "id",`String (Worker.id value |> Worker_id.to_string); "name",`String (Worker.name value);
  "labels",`List (Worker.labels value |> Worker_label.Set.elements
    |> List.map (fun label -> `String (Worker_label.value label)));
  "max_concurrency",`Int (Worker.max_concurrency value |> Scalar.Concurrency.value);
  "active_jobs",`Int (Worker.active_jobs value);
  "resources",`Assoc [
    "cpu_millicores",`Int (Worker.total_resources value |> Resources.cpu |> Scalar.Cpu_millicores.value);
    "memory_mib",`Int (Worker.total_resources value |> Resources.memory |> Scalar.Memory_mib.value);
    "reserved_cpu_millicores",`Int (Worker.reserved_resources value |> Resources.cpu |> Scalar.Cpu_millicores.value);
    "reserved_memory_mib",`Int (Worker.reserved_resources value |> Resources.memory |> Scalar.Memory_mib.value)];
  "last_heartbeat",`String (Worker.last_heartbeat value |> Timestamp.to_rfc3339)]
let execution value = Execution_spec.fold value
  ~command:(fun executable arguments -> `Assoc ["type",`String "command";
    "executable",`String executable;"arguments",`List (List.map (fun value -> `String value) arguments)])
  ~container:(fun image command -> `Assoc ["type",`String "container";"image",`String image;
    "command",`List (List.map (fun value -> `String value) command)])
let assignment (value : Services.Scheduling_service.assignment) = `Assoc [
  "job_id",`String (Job.id value.job |> Job_id.to_string);
  "attempt_id",`String (Attempt.id value.attempt |> Attempt_id.to_string);
  "attempt_number",`Int (Attempt.number value.attempt |> Scalar.Attempt_number.value);
  "execution",execution (Job.execution value.job);
  "timeout_seconds",`Int (Job.timeout value.job |> Scalar.Timeout_seconds.value);
  "resources",`Assoc [
    "cpu_millicores",`Int (Job.requirements value.job |> Resources.cpu |> Scalar.Cpu_millicores.value);
    "memory_mib",`Int (Job.requirements value.job |> Resources.memory |> Scalar.Memory_mib.value)]]
let control (value : Orchestraml_application.Ports.Persistence.control_request) = `Assoc [
  "attempt_id", `String (Attempt_id.to_string value.attempt_id);
  "type", `String (match value.kind with
    | Orchestraml_application.Ports.Persistence.Cancel -> "cancel"
    | Orchestraml_application.Ports.Persistence.Execution_timeout -> "execution_timeout"
    | Orchestraml_application.Ports.Persistence.Stop_unknown -> "stop_unknown");
  "requested_at", `String (Timestamp.to_rfc3339 value.requested_at)]
