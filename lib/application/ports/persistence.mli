(** Repository contracts and their atomic unit-of-work boundary. *)
open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core

type entity = Job | Attempt | Worker
type error = Already_exists of entity * string | Not_found of entity * string
  | Storage_failure of string | Conflict of string
type idempotent_create = Idempotency_created of Job.t
  | Idempotency_replayed of Job.t | Idempotency_conflict
type job_cursor = { created_at : Timestamp.t; job_id : Job_id.t }
type heartbeat_report = { reported_at : Timestamp.t; available_slots : int;
  active_attempt_ids : Attempt_id.t list }
type control_kind = Cancel | Execution_timeout | Stop_unknown
type control_request = { attempt_id : Attempt_id.t; worker_id : Worker_id.t;
  kind : control_kind; requested_at : Timestamp.t; delivered_at : Timestamp.t option;
  completed_at : Timestamp.t option }

type job_repository = {
  create_job : Job.t -> (unit, error) result;
  create_job_idempotent : Job.t -> canonical_payload:string -> (idempotent_create, error) result;
  find_job : Job_id.t -> (Job.t option, error) result;
  update_job : Job.t -> (unit, error) result;
  list_jobs : unit -> (Job.t list, error) result;
  list_jobs_page : status:Job_status.t option -> before:job_cursor option ->
    limit:int -> (Job.t list, error) result;
  list_pending_jobs : unit -> (Job.t list, error) result;
  list_retry_ready_jobs : now:Timestamp.t -> (Job.t list, error) result;
  list_retry_ready_jobs_bounded : now:Timestamp.t -> limit:int -> (Job.t list, error) result;
}

type attempt_repository = {
  create_attempt : Attempt.t -> (unit, error) result;
  find_attempt : Attempt_id.t -> (Attempt.t option, error) result;
  update_attempt : Attempt.t -> (unit, error) result;
  list_attempts_for_job : Job_id.t -> (Attempt.t list, error) result;
  list_active_attempts_for_worker : Worker_id.t -> (Attempt.t list, error) result;
  list_expired_unacknowledged : before:Timestamp.t -> limit:int -> (Attempt.t list, error) result;
  list_overdue_running : now:Timestamp.t -> grace_seconds:int -> limit:int -> (Attempt.t list, error) result;
  claim_assigned_attempt : Worker_id.t -> polled_at:Timestamp.t -> (Attempt.t option, error) result;
}

type worker_repository = {
  create_worker : Worker.t -> (unit, error) result;
  upsert_worker : Worker.t -> (bool, error) result;
  find_worker : Worker_id.t -> (Worker.t option, error) result;
  lock_worker : Worker_id.t -> (Worker.t option, error) result;
  update_worker : Worker.t -> (unit, error) result;
  list_workers : unit -> (Worker.t list, error) result;
  store_heartbeat : Worker_id.t -> heartbeat_report -> (unit, error) result;
  find_heartbeat : Worker_id.t -> (heartbeat_report option, error) result;
  list_stale_workers : before:Timestamp.t -> limit:int -> (Worker.t list, error) result;
}
type control_repository = {
  create_control : control_request -> (bool, error) result;
  list_controls_for_worker : Worker_id.t -> now:Timestamp.t -> limit:int -> (control_request list, error) result;
  complete_control : Attempt_id.t -> completed_at:Timestamp.t -> (unit, error) result;
  find_control : Attempt_id.t -> (control_request option, error) result;
  get_missing_since : Attempt_id.t -> (Timestamp.t option, error) result;
  set_missing_since : Attempt_id.t -> Timestamp.t -> (unit, error) result;
  clear_missing_since : Attempt_id.t -> (unit, error) result;
  create_stop_unknown : worker_id:Worker_id.t -> attempt_id:Attempt_id.t ->
    requested_at:Timestamp.t -> (bool, error) result;
  confirm_stop_unknown : worker_id:Worker_id.t -> attempt_id:Attempt_id.t ->
    completed_at:Timestamp.t -> (unit, error) result;
}

type event_repository = {
  append_event : Domain_event.t -> (unit, error) result;
  list_events : unit -> (Domain_event.t list, error) result;
  list_events_for_entity : Domain_event.entity -> (Domain_event.t list, error) result;
}

type repositories = {
  jobs : job_repository;
  attempts : attempt_repository;
  workers : worker_repository;
  events : event_repository;
  controls : control_repository;
}

type t = {
  with_transaction : 'a 'e.
    (repositories -> ('a, 'e) result) ->
    (('a, 'e) result, error) result;
}
