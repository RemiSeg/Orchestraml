(** Validation failures produced while constructing domain values. *)

type t = { field : string; message : string }

val make : field:string -> string -> t
val pp : Format.formatter -> t -> unit
