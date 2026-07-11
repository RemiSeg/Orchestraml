open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
type submission = { name : Scalar.Job_name.t; execution : Execution_spec.t;
  priority : Scalar.Priority.t; requirements : Resources.t;
  required_labels : Worker_label.Set.t; retry_policy : Retry_policy.t;
  timeout : Scalar.Timeout_seconds.t }
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t | Invalid_operation of string
  | Idempotency_conflict
type submission_result = Created of Job.t | Replayed of Job.t
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t; ids : Ports.Id_generator.t }
let create ~persistence ~clock ~ids = { persistence; clock; ids }
let transact service operation = match service.persistence.with_transaction operation with
  | Ok (Ok value) -> Ok value
  | Ok (Error error) | Error error -> Error (Persistence_error error)
let submit service request = transact service (fun repositories ->
  let created_at = service.clock.now () in
  let job = Job.create ~id:(service.ids.next_job_id ()) ~name:request.name
    ~execution:request.execution ~priority:request.priority ~requirements:request.requirements
    ~required_labels:request.required_labels ~retry_policy:request.retry_policy
    ~timeout:request.timeout ~created_at in
  match repositories.jobs.create_job job with Ok () -> Ok job | Error error -> Error error)
let submit_idempotent service ~key ~canonical_payload request =
  let result = service.persistence.with_transaction (fun repositories ->
    let created_at = service.clock.now () in
    let job = Job.create_idempotent ~idempotency_key:key ~id:(service.ids.next_job_id ())
      ~name:request.name ~execution:request.execution ~priority:request.priority
      ~requirements:request.requirements ~required_labels:request.required_labels
      ~retry_policy:request.retry_policy ~timeout:request.timeout ~created_at in
    repositories.jobs.create_job_idempotent job ~canonical_payload) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok (Ports.Persistence.Idempotency_created job)) -> Ok (Created job)
  | Ok (Ok (Ports.Persistence.Idempotency_replayed job)) -> Ok (Replayed job)
  | Ok (Ok Ports.Persistence.Idempotency_conflict) -> Error Idempotency_conflict
let find service id = transact service (fun repositories -> repositories.jobs.find_job id)
let list service = transact service (fun repositories -> repositories.jobs.list_jobs ())
let list_page service ~status ~before ~limit = transact service (fun repositories ->
  repositories.jobs.list_jobs_page ~status ~before ~limit)
let attempts service id = transact service (fun repositories -> repositories.attempts.list_attempts_for_job id)
let entity_matches job_id attempt_ids event = match event.Domain_event.entity with
  | Domain_event.Job id -> Job_id.equal id job_id
  | Domain_event.Attempt id -> List.exists (Attempt_id.equal id) attempt_ids
let events service id = transact service (fun repositories ->
  match repositories.attempts.list_attempts_for_job id with
  | Error error -> Error error
  | Ok attempts ->
      let attempt_ids = List.map Attempt.id attempts in
      match repositories.events.list_events () with
      | Error error -> Error error
      | Ok events -> Ok (List.filter (entity_matches id attempt_ids) events))
let cancel service id =
  match service.persistence.with_transaction (fun repositories ->
    match repositories.jobs.find_job id with
    | Error error -> Error error
    | Ok None -> Error (Ports.Persistence.Not_found (Ports.Persistence.Job, Job_id.to_string id))
    | Ok (Some job) ->
        if Job_status.equal (Job.status job) Job_status.Cancelled then Ok (`Cancelled job)
        else if not (Job_status.equal (Job.status job) Job_status.Pending
          || Job_status.equal (Job.status job) Job_status.Retry_waiting) then
          Ok (`Invalid "only pending or retry-waiting jobs can be cancelled here")
        else match Job.request_cancel ~now:(service.clock.now ()) job with
          | Error error -> Ok (`Transition error)
          | Ok (cancelled, event) ->
              match repositories.jobs.update_job cancelled with
              | Error error -> Error error
              | Ok () -> match repositories.events.append_event event with
                  | Error error -> Error error | Ok () -> Ok (`Cancelled cancelled)) with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok (`Invalid reason)) -> Error (Invalid_operation reason)
  | Ok (Ok (`Transition error)) -> Error (Transition_rejected error)
  | Ok (Ok (`Cancelled job)) -> Ok job
