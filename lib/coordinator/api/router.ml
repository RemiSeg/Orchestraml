open Orchestraml_domain
open Foundation
open Identifiers
open Core
module Job_service = Orchestraml_application.Services.Job_service
module Job_json = Dto.Job_json
type request = { meth : string; target : string; headers : (string * string) list; body : string }
type response = { status : int; headers : (string * string) list; body : string }
type t = { jobs : Job_service.t; health : unit -> bool }
let create ~jobs ~health = { jobs; health }
let json_response ?(headers=[]) status json = { status;
  headers = ("content-type","application/json") :: headers; body = Yojson.Safe.to_string json }
let error status code message = Dto.Api_error.json ~code ~message () |> json_response status
let header name headers = List.find_map (fun (key,value) ->
  if String.equal (String.lowercase_ascii key) (String.lowercase_ascii name) then Some value else None) headers
let job_id value = match Job_id.of_string value with Ok id -> Ok id | Error _ -> Error (error 400 "invalid_job_id" "job ID is invalid")
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
let handle router request = match request.meth, parse_path request.target with
  | "GET", ["health"] -> if router.health () then json_response 200 (`Assoc ["status",`String "ok"])
      else error 503 "unavailable" "database is unavailable"
  | "POST", ["v1";"jobs"] -> post_job router request
  | "GET", ["v1";"jobs"] -> get_jobs router request.target
  | "GET", ["v1";"jobs";id] -> get_job router id
  | "GET", ["v1";"jobs";id;"attempts"] -> get_attempts router id
  | "GET", ["v1";"jobs";id;"events"] -> get_events router id
  | "POST", ["v1";"jobs";id;"cancel"] -> cancel router id
  | _ -> error 404 "route_not_found" "route was not found"
