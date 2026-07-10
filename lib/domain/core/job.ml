open Foundation
open Identifiers
open Shared

type t = {
  id : Job_id.t; name : Scalar.Job_name.t; execution : Execution_spec.t;
  status : Job_status.t; priority : Scalar.Priority.t; requirements : Resources.t;
  required_labels : Worker_label.Set.t; retry_policy : Retry_policy.t;
  timeout : Scalar.Timeout_seconds.t; next_retry_at : Timestamp.t option;
  attempts_started : int; created_at : Timestamp.t; updated_at : Timestamp.t;
}
type transition = (t * Domain_event.t, Transition_error.t) result

let create ~id ~name ~execution ~priority ~requirements ~required_labels ~retry_policy ~timeout ~created_at =
  { id; name; execution; status = Job_status.Pending; priority; requirements; required_labels;
    retry_policy; timeout; next_retry_at = None; attempts_started = 0;
    created_at; updated_at = created_at }
let id value = value.id
let name value = value.name
let execution value = value.execution
let status value = value.status
let priority value = value.priority
let requirements value = value.requirements
let required_labels value = value.required_labels
let retry_policy value = value.retry_policy
let timeout value = value.timeout
let next_retry_at value = value.next_retry_at
let attempts_started value = value.attempts_started
let created_at value = value.created_at
let updated_at value = value.updated_at

let reject value action reason = Error (Transition_error.make ~entity_kind:Job
  ~from_status:(Job_status.to_string value.status) ~action ~reason)
let changed ?reason value ~now ~status =
  if Timestamp.compare now value.updated_at < 0 then
    reject value (Job_status.to_string status) "transition time cannot precede the previous update"
  else
    let event = Domain_event.make ?reason ~entity:(Job value.id)
      ~from_status:(Job_status.to_string value.status) ~to_status:(Job_status.to_string status)
      ~occurred_at:now () in
    Ok ({ value with status; updated_at = now }, event)

let assign ~now value = match value.status with
  | Job_status.Pending ->
      let attempts_started = value.attempts_started + 1 in
      (match changed value ~now ~status:Job_status.Assigned with
       | Ok (updated, event) -> Ok ({ updated with attempts_started }, event)
       | Error _ as error -> error)
  | _ -> reject value "assign" "only pending jobs can be assigned"

let start ~now value = match value.status with
  | Job_status.Assigned -> changed value ~now ~status:Job_status.Running
  | _ -> reject value "start" "only assigned jobs can start"

let complete ~now value = match value.status with
  | Job_status.Running -> changed value ~now ~status:Job_status.Completed
  | _ -> reject value "complete" "only running jobs can complete"

let schedule_retry ~now ~retry_at ~reason value = match value.status with
  | Job_status.Assigned | Job_status.Running | Job_status.Cancelling ->
      if Timestamp.compare retry_at now < 0 then
        reject value "schedule_retry" "retry time cannot precede the transition time"
      else
        (match changed ~reason value ~now ~status:Job_status.Retry_waiting with
         | Ok (updated, event) -> Ok ({ updated with next_retry_at = Some retry_at }, event)
         | Error _ as error -> error)
  | _ -> reject value "schedule_retry" "job is not active"

let release_retry ~now value = match value.status, value.next_retry_at with
  | Job_status.Retry_waiting, Some retry_at when Timestamp.compare now retry_at >= 0 ->
      (match changed value ~now ~status:Job_status.Pending with
       | Ok (updated, event) -> Ok ({ updated with next_retry_at = None }, event)
       | Error _ as error -> error)
  | Job_status.Retry_waiting, Some _ -> reject value "release_retry" "retry deadline has not arrived"
  | Job_status.Retry_waiting, None -> reject value "release_retry" "retry deadline is missing"
  | _ -> reject value "release_retry" "job is not waiting for retry"

let request_cancel ~now value = match value.status with
  | Job_status.Pending | Job_status.Retry_waiting | Job_status.Assigned ->
      (match changed value ~now ~status:Job_status.Cancelled with
       | Ok (updated, event) -> Ok ({ updated with next_retry_at = None }, event)
       | Error _ as error -> error)
  | Job_status.Running -> changed value ~now ~status:Job_status.Cancelling
  | _ -> reject value "request_cancel" "job cannot be cancelled from its current state"

let confirm_cancel ~now value = match value.status with
  | Job_status.Cancelling -> changed value ~now ~status:Job_status.Cancelled
  | _ -> reject value "confirm_cancel" "only cancelling jobs can confirm cancellation"

let permanently_fail ~now ~reason value = match value.status with
  | Job_status.Assigned | Job_status.Running | Job_status.Cancelling ->
      changed ~reason value ~now ~status:Job_status.Permanently_failed
  | _ -> reject value "permanently_fail" "job is not active"
