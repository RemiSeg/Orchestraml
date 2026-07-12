(** Coordinator-side processing of worker lifecycle reports. *)
open Orchestraml_domain
open Identifiers
open Shared
open Core
type completed = { job : Job.t; attempt : Attempt.t; worker : Worker.t }
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t | Capacity_rejected of Worker.capacity_error
  | Entity_mismatch | Invalid_operation of string
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t -> t
val acknowledge_attempt : t -> Attempt_id.t -> (Attempt.t, error) result
val start_attempt : t -> Attempt_id.t -> (Job.t * Attempt.t, error) result
val report_success : t -> Attempt_id.t -> exit_code:int -> (completed, error) result
val report_failure : t -> Attempt_id.t -> failure:Failure.t -> (completed, error) result
val report_timeout : t -> Attempt_id.t -> (completed, error) result
val report_lost : t -> Attempt_id.t -> reason:string -> (completed, error) result
val recover_lost : t -> Attempt_id.t -> reason:string -> failure:Failure.t -> (completed, error) result
val report_cancelled : t -> Attempt_id.t -> (completed, error) result
