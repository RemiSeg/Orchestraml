open Foundation
open Identifiers
open Shared

type outcome = Success of int | Failure of Failure.t | Timed_out_outcome
  | Lost_outcome of string | Cancelled_outcome
type t = {
  id : Attempt_id.t; job_id : Job_id.t; number : Scalar.Attempt_number.t;
  worker_id : Worker_id.t; status : Attempt_status.t; assigned_at : Timestamp.t;
  acknowledged_at : Timestamp.t option; started_at : Timestamp.t option;
  finished_at : Timestamp.t option; outcome : outcome option;
}
type snapshot = { id : Attempt_id.t; job_id : Job_id.t; number : Scalar.Attempt_number.t;
  worker_id : Worker_id.t; status : Attempt_status.t; assigned_at : Timestamp.t;
  acknowledged_at : Timestamp.t option; started_at : Timestamp.t option;
  finished_at : Timestamp.t option; outcome : outcome option }
type transition = (t * Domain_event.t, Transition_error.t) result
let create ~id ~job_id ~number ~worker_id ~assigned_at =
  ({ id; job_id; number; worker_id; status = Attempt_status.Assigned; assigned_at;
    acknowledged_at = None; started_at = None; finished_at = None; outcome = None } : t)
let id (value : t) = value.id
let job_id (value : t) = value.job_id
let number (value : t) = value.number
let worker_id (value : t) = value.worker_id
let status (value : t) = value.status
let assigned_at (value : t) = value.assigned_at
let acknowledged_at (value : t) = value.acknowledged_at
let started_at (value : t) = value.started_at
let finished_at (value : t) = value.finished_at
let outcome (value : t) = value.outcome
let snapshot (value : t) = { id = value.id; job_id = value.job_id; number = value.number;
  worker_id = value.worker_id; status = value.status; assigned_at = value.assigned_at;
  acknowledged_at = value.acknowledged_at; started_at = value.started_at;
  finished_at = value.finished_at; outcome = value.outcome }
let outcome_matches status outcome = match outcome, status with
  | Some (Success _), Attempt_status.Succeeded
  | Some (Failure _), Attempt_status.Failed
  | Some Timed_out_outcome, Attempt_status.Timed_out
  | Some (Lost_outcome _), Attempt_status.Lost
  | Some Cancelled_outcome, Attempt_status.Cancelled -> true
  | _ -> false
let restore snapshot =
  let value : t = { id = snapshot.id; job_id = snapshot.job_id; number = snapshot.number;
    worker_id = snapshot.worker_id; status = snapshot.status; assigned_at = snapshot.assigned_at;
    acknowledged_at = snapshot.acknowledged_at; started_at = snapshot.started_at;
    finished_at = snapshot.finished_at; outcome = snapshot.outcome } in
  let chronological =
    (match value.acknowledged_at with None -> true | Some at -> Timestamp.compare at value.assigned_at >= 0)
    && (match value.acknowledged_at, value.started_at with
        | _, None -> true | None, Some _ -> false
        | Some acknowledged, Some started -> Timestamp.compare started acknowledged >= 0)
    && (match value.started_at, value.finished_at with
        | _, None -> true | None, Some finished -> Timestamp.compare finished value.assigned_at >= 0
        | Some started, Some finished -> Timestamp.compare finished started >= 0) in
  if not chronological then Error (Validation_error.make ~field:"attempt_timestamps" "are not chronological")
  else match value.status with
    | Attempt_status.Assigned when value.started_at = None && value.finished_at = None && value.outcome = None -> Ok value
    | Attempt_status.Running when value.acknowledged_at <> None && value.started_at <> None && value.finished_at = None && value.outcome = None -> Ok value
    | Attempt_status.Succeeded | Attempt_status.Timed_out
      when value.started_at <> None && value.finished_at <> None && outcome_matches value.status value.outcome -> Ok value
    | Attempt_status.Failed | Attempt_status.Lost | Attempt_status.Cancelled
      when value.finished_at <> None && outcome_matches value.status value.outcome
        && (value.started_at <> None || value.status <> Attempt_status.Failed
            || value.acknowledged_at <> None) -> Ok value
    | _ -> Error (Validation_error.make ~field:"attempt_snapshot" "status, timestamps, and outcome are inconsistent")
let reject (value : t) action reason = Error (Transition_error.make ~entity_kind:Attempt
  ~from_status:(Attempt_status.to_string value.status) ~action ~reason)
let changed ?reason (value : t) ~now ~status =
  let earliest = match value.started_at with Some timestamp -> timestamp | None -> value.assigned_at in
  if Timestamp.compare now earliest < 0 then
    reject value (Attempt_status.to_string status) "transition time cannot precede the current attempt timeline"
  else
    let event = Domain_event.make ?reason ~entity:(Attempt value.id)
      ~from_status:(Attempt_status.to_string value.status) ~to_status:(Attempt_status.to_string status)
      ~occurred_at:now () in
    Ok ({ value with status }, event)
let acknowledge ~now (value : t) = match value.status, value.acknowledged_at with
  | Attempt_status.Assigned, Some _ -> Ok value
  | Attempt_status.Assigned, None when Timestamp.compare now value.assigned_at >= 0 ->
      Ok { value with acknowledged_at = Some now }
  | Attempt_status.Assigned, None -> reject value "acknowledge" "acknowledgement cannot precede assignment"
  | _ -> reject value "acknowledge" "only assigned attempts can be acknowledged"
let start ~now (value : t) = match value.status with
  | Attempt_status.Assigned when value.acknowledged_at <> None ->
      (match changed value ~now ~status:Attempt_status.Running with
       | Ok (updated, event) -> Ok ({ updated with started_at = Some now }, event)
       | Error _ as error -> error)
  | Attempt_status.Assigned -> reject value "start" "attempt must be acknowledged before start"
  | _ -> reject value "start" "only assigned attempts can start"
let finish (value : t) ~now ~status ~outcome ?reason () =
  match changed ?reason value ~now ~status with
  | Ok (updated, event) -> Ok ({ updated with finished_at = Some now; outcome = Some outcome }, event)
  | Error _ as error -> error
let succeed ~now ~exit_code (value : t) = match value.status with
  | Attempt_status.Running -> finish value ~now ~status:Attempt_status.Succeeded ~outcome:(Success exit_code) ()
  | _ -> reject value "succeed" "only running attempts can succeed"
let fail ~now ~failure (value : t) = match value.status with
  | Attempt_status.Assigned | Attempt_status.Running ->
      finish value ~now ~status:Attempt_status.Failed ~outcome:(Failure failure)
        ?reason:(Failure.message failure) ()
  | _ -> reject value "fail" "attempt is not active"
let time_out ~now (value : t) = match value.status with
  | Attempt_status.Running -> finish value ~now ~status:Attempt_status.Timed_out ~outcome:Timed_out_outcome ()
  | _ -> reject value "time_out" "only running attempts can time out"
let lose ~now ~reason (value : t) = match value.status with
  | Attempt_status.Assigned | Attempt_status.Running ->
      finish value ~now ~status:Attempt_status.Lost ~outcome:(Lost_outcome reason) ~reason ()
  | _ -> reject value "lose" "attempt is not active"
let cancel ~now (value : t) = match value.status with
  | Attempt_status.Assigned | Attempt_status.Running ->
      finish value ~now ~status:Attempt_status.Cancelled ~outcome:Cancelled_outcome ()
  | _ -> reject value "cancel" "attempt is not active"
