(** Read-only operational metrics derived from durable state. *)
type t
type error = Persistence_error of Ports.Persistence.error | Invalid_clock

val create : persistence:Ports.Persistence.t -> clock:Ports.Clock.t ->
  suspect_after_seconds:int -> offline_after_seconds:int -> t
val snapshot : t -> (Ports.Persistence.metrics_snapshot, error) result
