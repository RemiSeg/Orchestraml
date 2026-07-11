(** Job submission, queries, history, and non-active cancellation. *)
open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core

type submission = {
  name : Scalar.Job_name.t;
  execution : Execution_spec.t;
  priority : Scalar.Priority.t;
  requirements : Resources.t;
  required_labels : Worker_label.Set.t;
  retry_policy : Retry_policy.t;
  timeout : Scalar.Timeout_seconds.t;
}
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t | Invalid_operation of string
  | Idempotency_conflict
type submission_result = Created of Job.t | Replayed of Job.t
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t ->
  ids:Ports.Id_generator.t -> t
val submit : t -> submission -> (Job.t, error) result
val submit_idempotent : t -> key:Idempotency_key.t -> canonical_payload:string ->
  submission -> (submission_result, error) result
val find : t -> Job_id.t -> (Job.t option, error) result
val list : t -> (Job.t list, error) result
val list_page : t -> status:Job_status.t option ->
  before:Ports.Persistence.job_cursor option -> limit:int -> (Job.t list, error) result
val attempts : t -> Job_id.t -> (Attempt.t list, error) result
val events : t -> Job_id.t -> (Domain_event.t list, error) result
val cancel : t -> Job_id.t -> (Job.t, error) result
