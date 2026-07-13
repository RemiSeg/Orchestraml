(** Durable Docker-container observations owned by an attempt. *)
open Orchestraml_domain
open Identifiers
type error = Persistence_error of Ports.Persistence.error
  | Invalid_metadata of string | Conflict of string | Wrong_worker | Not_container_attempt
type t
val create : persistence:Ports.Persistence.t -> t
val record : t -> worker_id:Worker_id.t -> metadata:Ports.Persistence.container_metadata ->
  (Ports.Persistence.container_metadata, error) result
val find : t -> Attempt_id.t ->
  (Ports.Persistence.container_metadata option, error) result
