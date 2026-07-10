(** Pure worker-health classification from heartbeat recency. *)
open Foundation
type t = Healthy | Suspect | Offline
type policy
val create : suspect_after:Scalar.Timeout_seconds.t -> offline_after:Scalar.Timeout_seconds.t ->
  (policy, Validation_error.t) result
val classify : policy -> now:Timestamp.t -> last_heartbeat:Timestamp.t -> t
val equal : t -> t -> bool
val to_string : t -> string
