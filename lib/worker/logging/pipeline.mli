(** Bounded sequenced attempt-log buffering and upload. *)
open Orchestraml_domain
open Identifiers
open Shared
type t
val create : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> client:Client.Coordinator.t ->
  worker_id:Worker_id.t -> attempt_id:Attempt_id.t -> batch_bytes:int ->
  pending_limit:int -> flush_interval:float -> t
val emit : t -> Log_entry.stream -> string -> unit
val close_and_flush : t -> (unit, Client.Coordinator.error) result
