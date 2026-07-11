(** Resource requests and reservations in canonical scheduling units. *)

open Foundation

type t
val create : cpu:Scalar.Cpu_millicores.t -> memory:Scalar.Memory_mib.t -> t
val cpu : t -> Scalar.Cpu_millicores.t
val memory : t -> Scalar.Memory_mib.t
val zero : t
val fits : required:t -> available:t -> bool
val add : t -> t -> (t, Validation_error.t) result
val subtract : total:t -> reserved:t -> (t, Validation_error.t) result
