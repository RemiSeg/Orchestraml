(** Worker registration and queries. *)
open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
type registration = { name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; total_resources : Resources.t }
type error = Persistence_error of Ports.Persistence.error | Invalid_worker of Validation_error.t
type registration_result = Registered of Worker.t | Updated of Worker.t
type heartbeat = { available_slots : int; active_attempt_ids : Attempt_id.t list }
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t ->
  ids:Ports.Id_generator.t -> t
val register : t -> registration -> (Worker.t, error) result
val register_with_id : t -> Worker_id.t -> registration -> (registration_result, error) result
val heartbeat : t -> Worker_id.t -> heartbeat -> (Worker.t, error) result
val find : t -> Worker_id.t -> (Worker.t option, error) result
val list : t -> (Worker.t list, error) result
val poll_controls : t -> Worker_id.t -> limit:int ->
  (Ports.Persistence.control_request list, error) result
val confirm_stop_unknown : t -> Worker_id.t -> Attempt_id.t -> (unit, error) result
