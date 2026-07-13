(** Durable ordered attempt-log ingestion and retrieval. *)
open Orchestraml_domain
open Identifiers
open Shared
type error = Persistence_error of Ports.Persistence.error | Invalid_batch of string
  | Wrong_worker | Terminal_attempt
type follow_snapshot = { entries : Log_entry.t list; highest_sequence : int;
  terminal : bool }
type t
val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t -> t
val append_batch : t -> worker_id:Worker_id.t -> attempt_id:Attempt_id.t ->
  Log_entry.t list -> (int, error) result
val list : t -> attempt_id:Attempt_id.t -> after_sequence:int -> limit:int ->
  (Log_entry.t list, error) result
val follow_snapshot : t -> attempt_id:Attempt_id.t -> after_sequence:int -> limit:int ->
  (follow_snapshot, error) result
