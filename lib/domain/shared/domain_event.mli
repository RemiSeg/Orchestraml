(** State-change facts returned by pure transition functions. *)
open Foundation
open Identifiers
type entity = Job of Job_id.t | Attempt of Attempt_id.t
type t = { entity : entity; from_status : string; to_status : string; occurred_at : Timestamp.t; reason : string option }
val make : ?reason:string -> entity:entity -> from_status:string -> to_status:string -> occurred_at:Timestamp.t -> unit -> t
