(** Overall job lifecycle states. *)
type t = Pending | Assigned | Running | Retry_waiting | Cancelling
  | Completed | Permanently_failed | Cancelled
val is_terminal : t -> bool
val to_string : t -> string
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
