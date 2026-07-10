(** Normalized worker capability labels. *)

type t
val create : string -> (t, Validation_error.t) result
val value : t -> string
val compare : t -> t -> int
val pp : Format.formatter -> t -> unit

module Set : Set.S with type elt = t
