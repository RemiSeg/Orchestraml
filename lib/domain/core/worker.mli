(** A worker's advertised capacity and current reservations. *)
open Foundation
open Identifiers
open Shared
type t
type capacity_error = No_concurrency | Insufficient_cpu | Insufficient_memory | Invalid_release
val create : id:Worker_id.t -> name:string -> labels:Worker_label.Set.t ->
  max_concurrency:Scalar.Concurrency.t -> active_jobs:int -> total_resources:Resources.t ->
  reserved_resources:Resources.t -> last_heartbeat:Timestamp.t ->
  (t, Validation_error.t) result
val id : t -> Worker_id.t
val name : t -> string
val labels : t -> Worker_label.Set.t
val max_concurrency : t -> Scalar.Concurrency.t
val active_jobs : t -> int
val total_resources : t -> Resources.t
val reserved_resources : t -> Resources.t
val available_resources : t -> Resources.t
val last_heartbeat : t -> Timestamp.t
val free_slots : t -> int
val reserve : requirements:Resources.t -> t -> (t, capacity_error) result
val release : requirements:Resources.t -> t -> (t, capacity_error) result
val reconfigure : name:string -> labels:Worker_label.Set.t ->
  max_concurrency:Scalar.Concurrency.t -> total_resources:Resources.t -> t ->
  (t, Validation_error.t) result
val heartbeat : now:Timestamp.t -> t -> (t, Validation_error.t) result
