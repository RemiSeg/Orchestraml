(** One-cycle deterministic assignment coordination. *)
open Orchestraml_domain
open Identifiers
open Shared
open Core
type assignment = { job : Job.t; attempt : Attempt.t; worker : Worker.t }
type outcome = Assigned of assignment | No_assignment
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t | Capacity_rejected of Worker.capacity_error
  | Invalid_attempt_number
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t ->
  ids:Ports.Id_generator.t -> health_policy:Worker_health.policy -> t
val run_once : t -> (outcome, error) result
val poll_for_worker : t -> Worker_id.t -> (outcome, error) result
