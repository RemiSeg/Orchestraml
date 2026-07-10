(** UTC instants represented by [Ptime.t]. *)

type t

val of_ptime : Ptime.t -> t
val to_ptime : t -> Ptime.t
val of_rfc3339 : string -> (t, Validation_error.t) result
val to_rfc3339 : t -> string
val compare : t -> t -> int
val equal : t -> t -> bool
val add_seconds : t -> int -> t option
val diff_seconds : later:t -> earlier:t -> int option
val pp : Format.formatter -> t -> unit
