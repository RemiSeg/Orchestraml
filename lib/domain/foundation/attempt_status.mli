(** Lifecycle states for a single execution attempt. *)
type t = Assigned | Running | Succeeded | Failed | Timed_out | Lost | Cancelled
val is_terminal : t -> bool
val to_string : t -> string
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
