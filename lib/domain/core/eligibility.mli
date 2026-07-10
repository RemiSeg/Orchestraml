(** Explainable worker eligibility for a job. *)
open Foundation
open Shared
type rejection_reason = Worker_not_healthy of Worker_health.t
  | Missing_labels of Worker_label.Set.t | No_concurrency
  | Insufficient_cpu | Insufficient_memory
type t = Eligible | Ineligible of rejection_reason list
val evaluate : health_policy:Worker_health.policy -> now:Timestamp.t -> job:Job.t -> worker:Worker.t -> t
val is_eligible : t -> bool
