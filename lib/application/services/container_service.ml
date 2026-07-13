open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
type error = Persistence_error of Ports.Persistence.error
  | Invalid_metadata of string | Conflict of string | Wrong_worker | Not_container_attempt
type t = { persistence : Ports.Persistence.t }
let create ~persistence = { persistence }
let chronological metadata =
  let not_before earlier = function None -> true | Some later -> Timestamp.compare later earlier >= 0 in
  if not (not_before metadata.Ports.Persistence.created_at metadata.started_at) then
    Error "started_at precedes created_at"
  else if Option.is_some metadata.finished_at && Option.is_none metadata.started_at then
    Error "finished_at requires started_at"
  else if not (match metadata.started_at, metadata.finished_at with
    | Some started, Some finished -> Timestamp.compare finished started >= 0 | _ -> true) then
    Error "finished_at precedes started_at"
  else if not (not_before metadata.created_at metadata.removed_at) then
    Error "removed_at precedes created_at"
  else match metadata.cleanup_outcome, metadata.removed_at with
    | Ports.Persistence.Removed, None -> Error "removed cleanup requires removed_at"
    | (Ports.Persistence.Pending | Ports.Persistence.Cleanup_failed), Some _ ->
        Error "non-removed cleanup cannot contain removed_at"
    | _ -> Ok ()
let same_option equal left right = match left, right with
  | None, _ -> true | Some left, Some right -> equal left right | Some _, None -> false
let same_timestamp left right =
  String.equal (Timestamp.to_rfc3339 left) (Timestamp.to_rfc3339 right)
let immutable_error (stored:Ports.Persistence.container_metadata) (value:Ports.Persistence.container_metadata) =
  if not(Attempt_id.equal stored.attempt_id value.attempt_id) then Some "attempt_id"
  else if not(Worker_id.equal stored.worker_id value.worker_id) then Some "worker_id"
  else if not(String.equal stored.container_id value.container_id) then Some "container_id"
  else if not(String.equal stored.container_name value.container_name) then Some "container_name"
  else if not(String.equal stored.image_reference value.image_reference) then Some "image_reference"
  else if not(same_timestamp stored.created_at value.created_at) then Some
    (Printf.sprintf "created_at (%s stored, %s reported)"
      (Timestamp.to_rfc3339 stored.created_at)(Timestamp.to_rfc3339 value.created_at)) else None
let progressive (stored:Ports.Persistence.container_metadata) (value:Ports.Persistence.container_metadata) =
  same_option same_timestamp stored.Ports.Persistence.started_at value.started_at
  && same_option same_timestamp stored.finished_at value.finished_at
  && same_option same_timestamp stored.removed_at value.removed_at
  && match stored.cleanup_outcome, value.cleanup_outcome with
    | Ports.Persistence.Removed, Ports.Persistence.Removed -> true
    | Ports.Persistence.Removed, _ -> false
    | Ports.Persistence.Cleanup_failed, Ports.Persistence.Pending -> false
    | _ -> true
let record service ~worker_id ~(metadata:Ports.Persistence.container_metadata) =
  match chronological metadata with Error message -> Error (Invalid_metadata message) | Ok () ->
  if not (Worker_id.equal worker_id metadata.Ports.Persistence.worker_id) then Error Wrong_worker else
  match service.persistence.with_transaction (fun repositories ->
    match repositories.attempts.find_attempt metadata.attempt_id with
    | Error error -> Error error
    | Ok None -> Error (Ports.Persistence.Not_found
        (Ports.Persistence.Attempt, Attempt_id.to_string metadata.attempt_id))
    | Ok (Some attempt) when not (Worker_id.equal worker_id (Attempt.worker_id attempt)) -> Ok `Wrong_worker
    | Ok (Some attempt) -> match repositories.workers.find_worker worker_id with
      | Error error -> Error error
      | Ok None -> Error (Ports.Persistence.Not_found
          (Ports.Persistence.Worker, Worker_id.to_string worker_id))
      | Ok (Some _) -> match repositories.jobs.find_job (Attempt.job_id attempt) with
        | Error error -> Error error
        | Ok None -> Error (Ports.Persistence.Not_found
            (Ports.Persistence.Job, Job_id.to_string (Attempt.job_id attempt)))
        | Ok (Some job) when not (Execution_spec.requires_docker (Job.execution job)) -> Ok `Not_container
        | Ok (Some _) -> match repositories.containers.find_container_metadata metadata.attempt_id with
          | Error error -> Error error
          | Ok (Some stored) -> (match immutable_error stored metadata with
              | Some field -> Ok (`Conflict (field^" conflicts with stored container metadata"))
              | None when not(progressive stored metadata) -> Ok (`Conflict "container lifecycle regresses or conflicts")
              | None -> repositories.containers.record_container_metadata metadata
                  |> Result.map (fun stored -> `Recorded stored))
          | Ok None -> repositories.containers.record_container_metadata metadata
              |> Result.map (fun stored -> `Recorded stored)) with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok `Wrong_worker) -> Error Wrong_worker
  | Ok (Ok `Not_container) -> Error Not_container_attempt
  | Ok (Ok (`Conflict message)) -> Error (Conflict message)
  | Ok (Ok (`Recorded value)) -> Ok value
let find service attempt_id = match service.persistence.with_transaction (fun repositories ->
  match repositories.attempts.find_attempt attempt_id with
  | Error error -> Error error
  | Ok None -> Error (Ports.Persistence.Not_found
      (Ports.Persistence.Attempt, Attempt_id.to_string attempt_id))
  | Ok (Some _) -> repositories.containers.find_container_metadata attempt_id) with
  | Ok (Ok value) -> Ok value
  | Error error | Ok (Error error) -> Error (Persistence_error error)
