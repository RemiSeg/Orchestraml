(** Releases retry-ready jobs back to the pending queue. *)
open Orchestraml_domain.Shared
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t -> t
val run_once : t -> (int, error) result
