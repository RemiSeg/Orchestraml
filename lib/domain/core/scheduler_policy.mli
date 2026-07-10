(** Deterministic, side-effect-free job and worker selection. *)
open Foundation
open Shared
val compare_jobs : Job.t -> Job.t -> int
val select_job : Job.t list -> Job.t option
val compare_workers : Worker.t -> Worker.t -> int
val select_worker : health_policy:Worker_health.policy -> now:Timestamp.t ->
  job:Job.t -> Worker.t list -> Worker.t option
