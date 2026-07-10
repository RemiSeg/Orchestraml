(** Structured rejection of an invalid state transition. *)
type entity_kind = Job | Attempt
type t = { entity_kind : entity_kind; from_status : string; action : string; reason : string }
val make : entity_kind:entity_kind -> from_status:string -> action:string -> reason:string -> t
val pp : Format.formatter -> t -> unit
