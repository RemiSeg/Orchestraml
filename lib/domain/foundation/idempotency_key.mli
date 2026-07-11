(** Validated client-provided submission idempotency keys. *)
type t
val create : string -> (t, Validation_error.t) result
val value : t -> string
val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
