(** A validated description of requested work, without execution behavior. *)

open Foundation

type t
val command : executable:string -> arguments:string list -> (t, Validation_error.t) result
val container : image:string -> command:string list -> (t, Validation_error.t) result
val fold : command:(string -> string list -> 'a) -> container:(string -> string list -> 'a) -> t -> 'a
