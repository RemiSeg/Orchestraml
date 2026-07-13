open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
module Job_service = Orchestraml_application.Services.Job_service
module Job_json = Dto.Job_json
module Services = Orchestraml_application.Services
module Worker_json = Dto.Worker_json
type request = { meth : string; target : string; headers : (string * string) list; body : string }
type body = Buffered of string | Follow_logs of { attempt_id : Attempt_id.t; after_sequence : int }
type response = { status : int; headers : (string * string) list; body : body }
type t = { jobs : Job_service.t; workers : Services.Worker_service.t;
  scheduling : Services.Scheduling_service.t; execution : Services.Execution_service.t;
  logs : Services.Log_service.t; containers : Services.Container_service.t;
  metrics : Services.Metrics_service.t;
  health : unit -> bool }
let create ~jobs ~workers ~scheduling ~execution ~logs ~containers ~metrics ~health =
  { jobs; workers; scheduling; execution; logs; containers; metrics; health }
let json_response ?(headers=[]) status json = { status;
  headers = ("content-type","application/json") :: headers; body = Buffered (Yojson.Safe.to_string json) }
let error status code message = Dto.Api_error.json ~code ~message () |> json_response status
let header name headers = List.find_map (fun (key,value) ->
  if String.equal (String.lowercase_ascii key) (String.lowercase_ascii name) then Some value else None) headers
let job_id value = match Job_id.of_string value with Ok id -> Ok id | Error _ -> Error (error 400 "invalid_job_id" "job ID is invalid")
let worker_id value = match Worker_id.of_string value with Ok id -> Ok id | Error _ -> Error (error 400 "invalid_worker_id" "worker ID is invalid")
let attempt_id value = match Attempt_id.of_string value with Ok id -> Ok id | Error _ -> Error (error 400 "invalid_attempt_id" "attempt ID is invalid")
let service_error = function
  | Job_service.Idempotency_conflict -> error 409 "idempotency_conflict" "idempotency key was used for another request"
  | Job_service.Invalid_operation message -> error 409 "invalid_operation" message
  | Job_service.Transition_rejected _ -> error 409 "transition_rejected" "job cannot change from its current state"
  | Job_service.Persistence_error (Orchestraml_application.Ports.Persistence.Not_found _) -> error 404 "not_found" "job was not found"
  | Job_service.Persistence_error _ -> error 500 "storage_error" "the request could not be persisted"
let parse_path target = Uri.of_string target |> Uri.path |> String.split_on_char '/'
  |> List.filter (fun value -> value <> "")
let post_job router (request : request) =
  let decoded = try Job_json.decode_submission (Yojson.Safe.from_string request.body)
    with Yojson.Json_error message -> Error [message] in
  match decoded with
  | Error messages -> Dto.Api_error.json ~code:"validation_error" ~message:"job definition is invalid"
      ~fields:(List.map (fun message -> "request",message) messages) () |> json_response 400
  | Ok decoded ->
      (match header "idempotency-key" request.headers with
       | None -> (match Job_service.submit router.jobs decoded.submission with
           | Ok job -> json_response 201 (Job_json.job job) | Error error -> service_error error)
       | Some raw -> match Idempotency_key.create raw with
           | Error validation -> Dto.Api_error.json ~code:"validation_error" ~message:"idempotency key is invalid"
               ~fields:[validation.field,validation.message] () |> json_response 400
           | Ok key -> match Job_service.submit_idempotent router.jobs ~key
               ~canonical_payload:decoded.canonical_payload decoded.submission with
               | Ok (Job_service.Created job) -> json_response 201 (Job_json.job job)
               | Ok (Job_service.Replayed job) -> json_response ~headers:["idempotency-replayed","true"] 200 (Job_json.job job)
               | Error error -> service_error error)
let get_jobs router target =
  let uri = Uri.of_string target in
  let status = match Uri.get_query_param uri "status" with
    | None -> Ok None
    | Some value -> Job_status.of_string value |> Result.map Option.some
        |> Result.map_error (fun _ -> "status is invalid") in
  let limit = match Uri.get_query_param uri "limit" with
    | None -> Ok None
    | Some value -> (match int_of_string_opt value with
        | Some value -> Ok (Some value) | None -> Error "limit must be an integer") in
  let cursor = match Uri.get_query_param uri "cursor" with
    | None -> Ok None
    | Some value -> Dto.Pagination.decode value |> Result.map Option.some in
  match status, limit, cursor with
  | Error message, _, _ | _, Error message, _ | _, _, Error message ->
      error 400 "invalid_pagination" message
  | Ok status, Ok limit, Ok cursor -> match Dto.Pagination.validate_limit limit with
      | Error message -> error 400 "invalid_pagination" message
      | Ok limit ->
          let before = Option.map (fun value : Orchestraml_application.Ports.Persistence.job_cursor ->
            { created_at = value.Dto.Pagination.created_at; job_id = value.job_id }) cursor in
          match Job_service.list_page router.jobs ~status ~before ~limit:(limit + 1) with
          | Error error_value -> service_error error_value
          | Ok jobs ->
              let rec take count values = match count, values with
                | 0,_ | _,[] -> [] | n,x::xs -> x::take (n-1) xs in
              let items = take limit jobs in
              let next_cursor = if List.length jobs <= limit then `Null else
                match List.rev items with
                | [] -> `Null
                | last :: _ -> `String (Dto.Pagination.encode {
                    created_at = Job.created_at last; job_id = Job.id last }) in
              json_response 200 (`Assoc ["items",`List (List.map Job_json.job items);
                "next_cursor",next_cursor])
let get_job router id = match job_id id with Error response -> response | Ok id ->
  match Job_service.find router.jobs id with
  | Error error_value -> service_error error_value
  | Ok None -> error 404 "not_found" "job was not found"
  | Ok (Some job) -> json_response 200 (Job_json.job job)
let get_attempts router id = match job_id id with Error response -> response | Ok id ->
  match Job_service.attempts router.jobs id with
  | Error error_value -> service_error error_value
  | Ok attempts -> json_response 200 (`Assoc ["items",`List (List.map Job_json.attempt attempts)])
let get_events router id = match job_id id with Error response -> response | Ok id ->
  match Job_service.events router.jobs id with
  | Error error_value -> service_error error_value
  | Ok events -> json_response 200 (`Assoc ["items",`List (List.map Job_json.event events)])
let cancel router id = match job_id id with Error response -> response | Ok id ->
  match Job_service.cancel router.jobs id with
  | Ok job -> json_response 200 (Job_json.job job) | Error error_value -> service_error error_value
let decode decoder body = try decoder (Yojson.Safe.from_string body)
  with Yojson.Json_error message -> Error [message]
let validation messages = Dto.Api_error.json ~code:"validation_error" ~message:"request is invalid"
  ~fields:(List.map (fun message -> "request",message) messages) () |> json_response 400
let worker_service_error = function
  | Services.Worker_service.Invalid_worker _ -> error 409 "invalid_worker" "worker configuration conflicts with current capacity"
  | Services.Worker_service.Persistence_error (Orchestraml_application.Ports.Persistence.Not_found _) -> error 404 "not_found" "worker was not found"
  | Services.Worker_service.Persistence_error (Orchestraml_application.Ports.Persistence.Conflict message) -> error 409 "control_conflict" message
  | Services.Worker_service.Persistence_error _ -> error 500 "storage_error" "worker state could not be persisted"
let execution_error = function
  | Services.Execution_service.Persistence_error (Orchestraml_application.Ports.Persistence.Not_found _) -> error 404 "not_found" "attempt was not found"
  | Services.Execution_service.Persistence_error _ -> error 500 "storage_error" "attempt state could not be persisted"
  | Services.Execution_service.Transition_rejected _ | Services.Execution_service.Invalid_operation _
  | Services.Execution_service.Entity_mismatch | Services.Execution_service.Capacity_rejected _ ->
      error 409 "invalid_operation" "attempt report conflicts with current state"
let register_worker router id (request : request) = match worker_id id with Error response -> response | Ok id ->
  match decode Worker_json.decode_registration request.body with
  | Error messages -> validation messages
  | Ok registration -> match Services.Worker_service.register_with_id router.workers id registration with
      | Ok (Services.Worker_service.Registered worker) -> json_response 201 (Worker_json.worker worker)
      | Ok (Services.Worker_service.Updated worker) -> json_response 200 (Worker_json.worker worker)
      | Error value -> worker_service_error value
let heartbeat router id (request : request) = match worker_id id with Error response -> response | Ok id ->
  match decode Worker_json.decode_heartbeat request.body with
  | Error messages -> validation messages
  | Ok heartbeat when heartbeat.available_slots < 0 -> validation ["available_slots must be non-negative"]
  | Ok heartbeat -> match Services.Worker_service.heartbeat router.workers id heartbeat with
      | Ok worker -> json_response 200 (Worker_json.worker worker)
      | Error value -> worker_service_error value
let poll router id = match worker_id id with Error response -> response | Ok id ->
  match Services.Scheduling_service.poll_for_worker router.scheduling id with
  | Ok Services.Scheduling_service.No_assignment -> { status = 204; headers = []; body = Buffered "" }
  | Ok (Services.Scheduling_service.Assigned assignment) -> json_response 200 (Worker_json.assignment assignment)
  | Error (Services.Scheduling_service.Persistence_error (Orchestraml_application.Ports.Persistence.Not_found _)) ->
      error 404 "not_found" "worker was not found"
  | Error _ -> error 409 "no_assignment" "worker cannot accept an assignment"
let poll_controls router id = match worker_id id with Error response -> response | Ok id ->
  match Services.Worker_service.poll_controls router.workers id ~limit:100 with
  | Ok [] -> { status = 204; headers = []; body = Buffered "" }
  | Ok controls -> json_response 200 (`Assoc ["items", `List (List.map Worker_json.control controls)])
  | Error value -> worker_service_error value
let confirm_stopped router worker attempt = match worker_id worker, attempt_id attempt with
  | Error response, _ | _, Error response -> response
  | Ok worker_id, Ok attempt_id -> match Services.Worker_service.confirm_stop_unknown
      router.workers worker_id attempt_id with
    | Ok () -> { status = 204; headers = []; body = Buffered "" }
    | Error value -> worker_service_error value
let list_workers router = match Services.Worker_service.list router.workers with
  | Ok workers -> json_response 200 (`Assoc ["items",`List (List.map Worker_json.worker workers)])
  | Error value -> worker_service_error value
let get_worker router id = match worker_id id with Error response -> response | Ok id ->
  match Services.Worker_service.find router.workers id with
  | Ok None -> error 404 "not_found" "worker was not found"
  | Ok (Some worker) -> json_response 200 (Worker_json.worker worker)
  | Error value -> worker_service_error value
let acknowledge router id = match attempt_id id with Error response -> response | Ok id ->
  match Services.Execution_service.acknowledge_attempt router.execution id with
  | Ok attempt -> json_response 200 (Job_json.attempt attempt) | Error value -> execution_error value
let start router id = match attempt_id id with Error response -> response | Ok id ->
  match Services.Execution_service.start_attempt router.execution id with
  | Ok (_, attempt) -> json_response 200 (Job_json.attempt attempt) | Error value -> execution_error value
let result router id (request : request) = match attempt_id id with Error response -> response | Ok id ->
  match decode Worker_json.decode_result request.body with
  | Error messages -> validation messages
  | Ok report -> let reported = match report with
      | Worker_json.Succeeded code -> Services.Execution_service.report_success router.execution id ~exit_code:code
      | Worker_json.Failed failure -> Services.Execution_service.report_failure router.execution id ~failure
      | Worker_json.Timed_out -> Services.Execution_service.report_timeout router.execution id
      | Worker_json.Lost reason -> Services.Execution_service.report_lost router.execution id ~reason
      | Worker_json.Cancelled -> Services.Execution_service.report_cancelled router.execution id in
      match reported with Ok completed -> json_response 200 (Job_json.attempt completed.attempt)
      | Error value -> execution_error value
let log_error = function
  | Services.Log_service.Persistence_error (Orchestraml_application.Ports.Persistence.Not_found _) ->
      error 404 "not_found" "attempt was not found"
  | Services.Log_service.Persistence_error (Orchestraml_application.Ports.Persistence.Conflict message) ->
      error 409 "log_conflict" message
  | Services.Log_service.Persistence_error _ -> error 500 "storage_error" "logs could not be persisted"
  | Services.Log_service.Invalid_batch message -> error 400 "invalid_log_batch" message
  | Services.Log_service.Wrong_worker -> error 409 "wrong_worker" "worker does not own attempt"
  | Services.Log_service.Terminal_attempt -> error 409 "terminal_attempt" "new logs cannot be added after terminal state"
let upload_logs router id (request : request) = match attempt_id id with Error response -> response | Ok id ->
  match decode (Dto.Log_json.decode_batch ~attempt_id:id) request.body with
  | Error messages -> validation messages
  | Ok (worker_id, entries) -> match Services.Log_service.append_batch router.logs
      ~worker_id ~attempt_id:id entries with
    | Ok highest -> json_response 200 (`Assoc ["highest_accepted_sequence",`Int highest])
    | Error value -> log_error value
let query_int uri name default = match Uri.get_query_param uri name with None -> Ok default
  | Some value -> match int_of_string_opt value with Some value -> Ok value
      | None -> Error (name ^ " must be an integer")
let get_logs router id target = match attempt_id id with Error response -> response | Ok id ->
  let uri = Uri.of_string target in
  match query_int uri "after_sequence" 0, query_int uri "limit" 1000 with
  | Error message, _ | _, Error message -> error 400 "invalid_log_query" message
  | Ok after_sequence, Ok limit -> match Services.Log_service.list router.logs ~attempt_id:id ~after_sequence ~limit with
    | Error value -> log_error value
    | Ok entries ->
        let next_sequence = if List.length entries < limit then `Null else match List.rev entries with
          | [] -> `Null | last :: _ -> `Int Log_entry.(sequence_number last |> sequence_value) in
        json_response 200 (`Assoc ["items",`List (List.map Dto.Log_json.entry entries);
          "next_sequence",next_sequence])
let follow_logs router id (request : request) = match attempt_id id with Error response -> response | Ok id ->
  let uri = Uri.of_string request.target in
  let after = match Uri.get_query_param uri "after_sequence" with
    | Some value -> int_of_string_opt value |> Option.to_result ~none:"after_sequence must be an integer"
    | None -> (match header "last-event-id" request.headers with
      | None -> Ok 0
      | Some value -> int_of_string_opt value |> Option.to_result ~none:"Last-Event-ID must be an integer") in
  match after with Error message -> error 400 "invalid_log_query" message
  | Ok after_sequence -> match Services.Log_service.follow_snapshot router.logs ~attempt_id:id ~after_sequence ~limit:5000 with
    | Error value -> log_error value
    | Ok _ -> { status=200; headers=["content-type","text/event-stream";"cache-control","no-cache"];
        body=Follow_logs { attempt_id=id; after_sequence } }
let follow_snapshot router ~attempt_id ~after_sequence =
  Services.Log_service.follow_snapshot router.logs ~attempt_id ~after_sequence ~limit:5000
let container_error = function
  | Services.Container_service.Persistence_error (Orchestraml_application.Ports.Persistence.Not_found _) ->
      error 404 "not_found" "attempt or worker was not found"
  | Services.Container_service.Persistence_error (Orchestraml_application.Ports.Persistence.Conflict message) ->
      error 409 "container_conflict" message
  | Services.Container_service.Persistence_error _ -> error 500 "storage_error" "container metadata could not be persisted"
  | Services.Container_service.Invalid_metadata message -> error 400 "invalid_container_metadata" message
  | Services.Container_service.Conflict message -> error 409 "container_conflict" message
  | Services.Container_service.Wrong_worker -> error 409 "wrong_worker" "worker does not own attempt"
  | Services.Container_service.Not_container_attempt -> error 409 "not_container_attempt" "attempt does not execute a container"
let put_container router id (request : request) = match attempt_id id with Error response -> response | Ok id ->
  match decode (Dto.Container_json.decode ~attempt_id:id) request.body with
  | Error messages -> validation messages
  | Ok (worker_id,metadata) -> match Services.Container_service.record router.containers ~worker_id ~metadata with
    | Ok stored -> json_response 200 (Dto.Container_json.encode stored)
    | Error value -> container_error value
let get_container router id = match attempt_id id with Error response -> response | Ok id ->
  match Services.Container_service.find router.containers id with
  | Ok (Some stored) -> json_response 200 (Dto.Container_json.encode stored)
  | Ok None -> error 404 "not_found" "container metadata was not found"
  | Error value -> container_error value
let metrics router =
  match Services.Metrics_service.snapshot router.metrics with
  | Error _ -> error 500 "metrics_unavailable" "metrics could not be collected"
  | Ok value ->
      let line name value = Printf.sprintf "orchestraml_%s %d\n" name value in
      let body = String.concat "" [
        line "jobs_pending" value.pending_jobs; line "jobs_assigned" value.assigned_jobs;
        line "jobs_running" value.running_jobs; line "jobs_retry_waiting" value.retry_waiting_jobs;
        line "jobs_cancelling" value.cancelling_jobs; line "jobs_completed" value.completed_jobs;
        line "jobs_permanently_failed" value.permanently_failed_jobs;
        line "jobs_cancelled" value.cancelled_jobs; line "workers_healthy" value.healthy_workers;
        line "workers_suspect" value.suspect_workers; line "workers_offline" value.offline_workers;
        line "retries_total" value.retry_count; line "attempts_active" value.active_attempts;
        line "container_cleanups_incomplete" value.incomplete_container_cleanups;
        Printf.sprintf "orchestraml_job_terminal_duration_seconds_average %.6f\n"
          value.average_terminal_job_duration_seconds ] in
      { status=200; headers=["content-type","text/plain; version=0.0.4; charset=utf-8"];
        body=Buffered body }
let handle router request = match request.meth, parse_path request.target with
  | "GET", ["health"] -> if router.health () then json_response 200 (`Assoc ["status",`String "ok"])
      else error 503 "unavailable" "database is unavailable"
  | "GET", ["metrics"] -> metrics router
  | "POST", ["v1";"jobs"] -> post_job router request
  | "GET", ["v1";"jobs"] -> get_jobs router request.target
  | "GET", ["v1";"jobs";id] -> get_job router id
  | "GET", ["v1";"jobs";id;"attempts"] -> get_attempts router id
  | "GET", ["v1";"jobs";id;"events"] -> get_events router id
  | "POST", ["v1";"jobs";id;"cancel"] -> cancel router id
  | "PUT", ["v1";"workers";id;"registration"] -> register_worker router id request
  | "POST", ["v1";"workers";id;"heartbeat"] -> heartbeat router id request
  | "POST", ["v1";"workers";id;"assignments";"poll"] -> poll router id
  | "POST", ["v1";"workers";id;"controls";"poll"] -> poll_controls router id
  | "POST", ["v1";"workers";worker;"controls";attempt;"stopped"] -> confirm_stopped router worker attempt
  | "GET", ["v1";"workers"] -> list_workers router
  | "GET", ["v1";"workers";id] -> get_worker router id
  | "POST", ["v1";"attempts";id;"acknowledge"] -> acknowledge router id
  | "POST", ["v1";"attempts";id;"started"] -> start router id
  | "POST", ["v1";"attempts";id;"result"] -> result router id request
  | "POST", ["v1";"attempts";id;"logs"] -> upload_logs router id request
  | "GET", ["v1";"attempts";id;"logs"] -> get_logs router id request.target
  | "GET", ["v1";"attempts";id;"logs";"follow"] -> follow_logs router id request
  | "PUT", ["v1";"attempts";id;"container"] -> put_container router id request
  | "GET", ["v1";"attempts";id;"container"] -> get_container router id
  | _ -> error 404 "route_not_found" "route was not found"
