open Foundation
open Identifiers
open Shared

type t = {
  id : Job_id.t; name : Scalar.Job_name.t; execution : Execution_spec.t;
  status : Job_status.t; priority : Scalar.Priority.t; requirements : Resources.t;
  required_labels : Worker_label.Set.t; retry_policy : Retry_policy.t;
  timeout : Scalar.Timeout_seconds.t; next_retry_at : Timestamp.t option;
  idempotency_key : Idempotency_key.t option;
  attempts_started : int; created_at : Timestamp.t; updated_at : Timestamp.t;
}
type transition = (t * Domain_event.t, Transition_error.t) result

type snapshot = {
  id : Job_id.t; name : Scalar.Job_name.t; execution : Execution_spec.t;
  status : Job_status.t; priority : Scalar.Priority.t; requirements : Resources.t;
  required_labels : Worker_label.Set.t; retry_policy : Retry_policy.t;
  timeout : Scalar.Timeout_seconds.t; idempotency_key : Idempotency_key.t option;
  next_retry_at : Timestamp.t option; attempts_started : int;
  created_at : Timestamp.t; updated_at : Timestamp.t;
}
let make ?idempotency_key ~id ~name ~execution ~priority ~requirements ~required_labels ~retry_policy ~timeout ~created_at () =
  ({ id; name; execution; status = Job_status.Pending; priority; requirements; required_labels;
    retry_policy; timeout; idempotency_key; next_retry_at = None; attempts_started = 0;
    created_at; updated_at = created_at } : t)
let create ~id ~name ~execution ~priority ~requirements ~required_labels ~retry_policy ~timeout ~created_at =
  make ~id ~name ~execution ~priority ~requirements ~required_labels ~retry_policy ~timeout ~created_at ()
let create_idempotent ~idempotency_key ~id ~name ~execution ~priority ~requirements
    ~required_labels ~retry_policy ~timeout ~created_at =
  make ~idempotency_key ~id ~name ~execution ~priority ~requirements ~required_labels
    ~retry_policy ~timeout ~created_at ()
let id (value : t) = value.id
let name (value : t) = value.name
let execution (value : t) = value.execution
let status (value : t) = value.status
let priority (value : t) = value.priority
let requirements (value : t) = value.requirements
let required_labels (value : t) = value.required_labels
let effective_required_labels (value : t) =
  if Execution_spec.requires_docker value.execution then
    match Worker_label.create "docker" with
    | Ok label -> Worker_label.Set.add label value.required_labels
    | Error _ -> value.required_labels
  else value.required_labels
let retry_policy (value : t) = value.retry_policy
let timeout (value : t) = value.timeout
let idempotency_key (value : t) = value.idempotency_key
let next_retry_at (value : t) = value.next_retry_at
let attempts_started (value : t) = value.attempts_started
let created_at (value : t) = value.created_at
let updated_at (value : t) = value.updated_at
let snapshot (value : t) = { id = value.id; name = value.name; execution = value.execution;
  status = value.status; priority = value.priority; requirements = value.requirements;
  required_labels = value.required_labels; retry_policy = value.retry_policy;
  timeout = value.timeout; idempotency_key = value.idempotency_key;
  next_retry_at = value.next_retry_at; attempts_started = value.attempts_started;
  created_at = value.created_at; updated_at = value.updated_at }
let restore snapshot =
  let value : t = { id = snapshot.id; name = snapshot.name; execution = snapshot.execution;
    status = snapshot.status; priority = snapshot.priority; requirements = snapshot.requirements;
    required_labels = snapshot.required_labels; retry_policy = snapshot.retry_policy;
    timeout = snapshot.timeout; idempotency_key = snapshot.idempotency_key;
    next_retry_at = snapshot.next_retry_at; attempts_started = snapshot.attempts_started;
    created_at = snapshot.created_at; updated_at = snapshot.updated_at } in
  if value.attempts_started < 0 then
    Error (Validation_error.make ~field:"attempts_started" "must be non-negative")
  else if Timestamp.compare value.updated_at value.created_at < 0 then
    Error (Validation_error.make ~field:"updated_at" "cannot precede created_at")
  else match value.status, value.next_retry_at with
    | Job_status.Retry_waiting, None ->
        Error (Validation_error.make ~field:"next_retry_at" "is required for retry_waiting")
    | Job_status.Retry_waiting, Some retry_at when Timestamp.compare retry_at value.updated_at < 0 ->
        Error (Validation_error.make ~field:"next_retry_at" "cannot precede updated_at")
    | Job_status.Retry_waiting, Some _ -> Ok value
    | _, Some _ -> Error (Validation_error.make ~field:"next_retry_at" "is only valid for retry_waiting")
    | _, None -> Ok value

let reject (value : t) action reason = Error (Transition_error.make ~entity_kind:Job
  ~from_status:(Job_status.to_string value.status) ~action ~reason)
let changed ?reason (value : t) ~now ~status =
  if Timestamp.compare now value.updated_at < 0 then
    reject value (Job_status.to_string status) "transition time cannot precede the previous update"
  else
    let event = Domain_event.make ?reason ~entity:(Job value.id)
      ~from_status:(Job_status.to_string value.status) ~to_status:(Job_status.to_string status)
      ~occurred_at:now () in
    Ok ({ value with status; updated_at = now }, event)

let assign ~now (value : t) = match value.status with
  | Job_status.Pending ->
      let attempts_started = value.attempts_started + 1 in
      (match changed value ~now ~status:Job_status.Assigned with
       | Ok (updated, event) -> Ok ({ updated with attempts_started }, event)
       | Error _ as error -> error)
  | _ -> reject value "assign" "only pending jobs can be assigned"

let start ~now (value : t) = match value.status with
  | Job_status.Assigned -> changed value ~now ~status:Job_status.Running
  | _ -> reject value "start" "only assigned jobs can start"

let complete ~now (value : t) = match value.status with
  | Job_status.Running -> changed value ~now ~status:Job_status.Completed
  | _ -> reject value "complete" "only running jobs can complete"

let schedule_retry ~now ~retry_at ~reason (value : t) = match value.status with
  | Job_status.Assigned | Job_status.Running | Job_status.Cancelling ->
      if Timestamp.compare retry_at now < 0 then
        reject value "schedule_retry" "retry time cannot precede the transition time"
      else
        (match changed ~reason value ~now ~status:Job_status.Retry_waiting with
         | Ok (updated, event) -> Ok ({ updated with next_retry_at = Some retry_at }, event)
         | Error _ as error -> error)
  | _ -> reject value "schedule_retry" "job is not active"

let release_retry ~now (value : t) = match value.status, value.next_retry_at with
  | Job_status.Retry_waiting, Some retry_at when Timestamp.compare now retry_at >= 0 ->
      (match changed value ~now ~status:Job_status.Pending with
       | Ok (updated, event) -> Ok ({ updated with next_retry_at = None }, event)
       | Error _ as error -> error)
  | Job_status.Retry_waiting, Some _ -> reject value "release_retry" "retry deadline has not arrived"
  | Job_status.Retry_waiting, None -> reject value "release_retry" "retry deadline is missing"
  | _ -> reject value "release_retry" "job is not waiting for retry"

let cancel_before_execution ~now (value : t) = match value.status with
  | Job_status.Pending | Job_status.Retry_waiting | Job_status.Assigned ->
      (match changed value ~now ~status:Job_status.Cancelled with
       | Ok (updated, event) -> Ok ({ updated with next_retry_at = None }, event)
       | Error _ as error -> error)
  | _ -> reject value "cancel_before_execution" "job has already entered execution"

let request_execution_cancel ~now (value : t) = match value.status with
  | Job_status.Assigned | Job_status.Running -> changed value ~now ~status:Job_status.Cancelling
  | _ -> reject value "request_execution_cancel" "job is not accepted or running"

let request_cancel ~now (value : t) = match value.status with
  | Job_status.Pending | Job_status.Retry_waiting -> cancel_before_execution ~now value
  | Job_status.Assigned | Job_status.Running -> request_execution_cancel ~now value
  | _ -> reject value "request_cancel" "job cannot be cancelled from its current state"

let confirm_cancel ~now (value : t) = match value.status with
  | Job_status.Cancelling -> changed value ~now ~status:Job_status.Cancelled
  | _ -> reject value "confirm_cancel" "only cancelling jobs can confirm cancellation"

let permanently_fail ~now ~reason (value : t) = match value.status with
  | Job_status.Assigned | Job_status.Running | Job_status.Cancelling ->
      changed ~reason value ~now ~status:Job_status.Permanently_failed
  | _ -> reject value "permanently_fail" "job is not active"
