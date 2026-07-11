(** Worker registration and queries. *)
open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
type registration = { name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; total_resources : Resources.t }
type error = Persistence_error of Ports.Persistence.error | Invalid_worker of Validation_error.t
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t ->
  ids:Ports.Id_generator.t -> t
val register : t -> registration -> (Worker.t, error) result
val find : t -> Worker_id.t -> (Worker.t option, error) result
val list : t -> (Worker.t list, error) result
