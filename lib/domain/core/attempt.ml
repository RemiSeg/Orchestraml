open Foundation
open Identifiers
open Shared

type outcome = Success of int | Failure of Failure.t | Timed_out_outcome
  | Lost_outcome of string | Cancelled_outcome
type t = {
  id : Attempt_id.t; job_id : Job_id.t; number : Scalar.Attempt_number.t;
  worker_id : Worker_id.t; status : Attempt_status.t; assigned_at : Timestamp.t;
  started_at : Timestamp.t option; finished_at : Timestamp.t option; outcome : outcome option;
}
type transition = (t * Domain_event.t, Transition_error.t) result
let create ~id ~job_id ~number ~worker_id ~assigned_at =
  { id; job_id; number; worker_id; status = Attempt_status.Assigned; assigned_at;
    started_at = None; finished_at = None; outcome = None }
let id value = value.id
let job_id value = value.job_id
let number value = value.number
let worker_id value = value.worker_id
let status value = value.status
let assigned_at value = value.assigned_at
let started_at value = value.started_at
let finished_at value = value.finished_at
let outcome value = value.outcome
let reject value action reason = Error (Transition_error.make ~entity_kind:Attempt
  ~from_status:(Attempt_status.to_string value.status) ~action ~reason)
let changed ?reason value ~now ~status =
  let earliest = match value.started_at with Some timestamp -> timestamp | None -> value.assigned_at in
  if Timestamp.compare now earliest < 0 then
    reject value (Attempt_status.to_string status) "transition time cannot precede the current attempt timeline"
  else
    let event = Domain_event.make ?reason ~entity:(Attempt value.id)
      ~from_status:(Attempt_status.to_string value.status) ~to_status:(Attempt_status.to_string status)
      ~occurred_at:now () in
    Ok ({ value with status }, event)
let start ~now value = match value.status with
  | Attempt_status.Assigned ->
      (match changed value ~now ~status:Attempt_status.Running with
       | Ok (updated, event) -> Ok ({ updated with started_at = Some now }, event)
       | Error _ as error -> error)
  | _ -> reject value "start" "only assigned attempts can start"
let finish value ~now ~status ~outcome ?reason () =
  match changed ?reason value ~now ~status with
  | Ok (updated, event) -> Ok ({ updated with finished_at = Some now; outcome = Some outcome }, event)
  | Error _ as error -> error
let succeed ~now ~exit_code value = match value.status with
  | Attempt_status.Running -> finish value ~now ~status:Attempt_status.Succeeded ~outcome:(Success exit_code) ()
  | _ -> reject value "succeed" "only running attempts can succeed"
let fail ~now ~failure value = match value.status with
  | Attempt_status.Assigned | Attempt_status.Running ->
      finish value ~now ~status:Attempt_status.Failed ~outcome:(Failure failure)
        ?reason:(Failure.message failure) ()
  | _ -> reject value "fail" "attempt is not active"
let time_out ~now value = match value.status with
  | Attempt_status.Running -> finish value ~now ~status:Attempt_status.Timed_out ~outcome:Timed_out_outcome ()
  | _ -> reject value "time_out" "only running attempts can time out"
let lose ~now ~reason value = match value.status with
  | Attempt_status.Assigned | Attempt_status.Running ->
      finish value ~now ~status:Attempt_status.Lost ~outcome:(Lost_outcome reason) ~reason ()
  | _ -> reject value "lose" "attempt is not active"
let cancel ~now value = match value.status with
  | Attempt_status.Assigned | Attempt_status.Running ->
      finish value ~now ~status:Attempt_status.Cancelled ~outcome:Cancelled_outcome ()
  | _ -> reject value "cancel" "attempt is not active"
