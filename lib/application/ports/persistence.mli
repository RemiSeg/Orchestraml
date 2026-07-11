(** Repository contracts and their atomic unit-of-work boundary. *)
open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core

type entity = Job | Attempt | Worker
type error = Already_exists of entity * string | Not_found of entity * string
  | Storage_failure of string
type idempotent_create = Idempotency_created of Job.t
  | Idempotency_replayed of Job.t | Idempotency_conflict
type job_cursor = { created_at : Timestamp.t; job_id : Job_id.t }

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
}

type attempt_repository = {
  create_attempt : Attempt.t -> (unit, error) result;
  find_attempt : Attempt_id.t -> (Attempt.t option, error) result;
  update_attempt : Attempt.t -> (unit, error) result;
  list_attempts_for_job : Job_id.t -> (Attempt.t list, error) result;
}

type worker_repository = {
  create_worker : Worker.t -> (unit, error) result;
  find_worker : Worker_id.t -> (Worker.t option, error) result;
  update_worker : Worker.t -> (unit, error) result;
  list_workers : unit -> (Worker.t list, error) result;
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
}

type t = {
  with_transaction : 'a 'e.
    (repositories -> ('a, 'e) result) ->
    (('a, 'e) result, error) result;
}
