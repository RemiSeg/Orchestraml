(** Bounded reliability and recovery cycles. *)
open Orchestraml_domain
open Foundation
open Shared

type error = Persistence_error of Ports.Persistence.error
  | Execution_error of Execution_service.error | Invalid_time | Reconciliation_did_not_converge
type summary = { retries_released : int; assignments_recovered : int;
  deadlines_requested : int; workers_recovered : int; heartbeats_reconciled : int }
type t
val create : max_reconciliation_passes:int -> persistence:Ports.Persistence.t -> clock:Ports.Clock.t ->
  health_policy:Worker_health.policy -> acknowledgement_timeout:Scalar.Timeout_seconds.t ->
  execution_report_grace:Scalar.Timeout_seconds.t -> recovery_grace:Scalar.Timeout_seconds.t ->
  batch_size:int -> t
val run_assignment_timeout_cycle : t -> (int, error) result
val run_execution_deadline_cycle : t -> (int, error) result
val run_worker_recovery_cycle : t -> (int, error) result
val run_heartbeat_reconciliation_cycle : t -> (int, error) result
val reconcile_startup : t -> (summary, error) result
