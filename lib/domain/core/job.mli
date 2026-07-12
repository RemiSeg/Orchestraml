(** A requested unit of work and its validated lifecycle. *)

open Foundation
open Identifiers
open Shared

type t
type transition = (t * Domain_event.t, Transition_error.t) result
type snapshot = {
  id : Job_id.t; name : Scalar.Job_name.t; execution : Execution_spec.t;
  status : Job_status.t; priority : Scalar.Priority.t; requirements : Resources.t;
  required_labels : Worker_label.Set.t; retry_policy : Retry_policy.t;
  timeout : Scalar.Timeout_seconds.t; idempotency_key : Idempotency_key.t option;
  next_retry_at : Timestamp.t option; attempts_started : int;
  created_at : Timestamp.t; updated_at : Timestamp.t;
}

val create : id:Job_id.t -> name:Scalar.Job_name.t -> execution:Execution_spec.t ->
  priority:Scalar.Priority.t -> requirements:Resources.t ->
  required_labels:Worker_label.Set.t -> retry_policy:Retry_policy.t ->
  timeout:Scalar.Timeout_seconds.t -> created_at:Timestamp.t -> t
val create_idempotent : idempotency_key:Idempotency_key.t -> id:Job_id.t ->
  name:Scalar.Job_name.t -> execution:Execution_spec.t -> priority:Scalar.Priority.t ->
  requirements:Resources.t -> required_labels:Worker_label.Set.t ->
  retry_policy:Retry_policy.t -> timeout:Scalar.Timeout_seconds.t -> created_at:Timestamp.t -> t
val id : t -> Job_id.t
val name : t -> Scalar.Job_name.t
val execution : t -> Execution_spec.t
val status : t -> Job_status.t
val priority : t -> Scalar.Priority.t
val requirements : t -> Resources.t
val required_labels : t -> Worker_label.Set.t
val retry_policy : t -> Retry_policy.t
val timeout : t -> Scalar.Timeout_seconds.t
val idempotency_key : t -> Idempotency_key.t option
val next_retry_at : t -> Timestamp.t option
val attempts_started : t -> int
val created_at : t -> Timestamp.t
val updated_at : t -> Timestamp.t
val snapshot : t -> snapshot
val restore : snapshot -> (t, Validation_error.t) result

val assign : now:Timestamp.t -> t -> transition
val start : now:Timestamp.t -> t -> transition
val complete : now:Timestamp.t -> t -> transition
val schedule_retry : now:Timestamp.t -> retry_at:Timestamp.t -> reason:string -> t -> transition
val release_retry : now:Timestamp.t -> t -> transition
(* Immediately cancels work which has not been accepted for execution. *)
val cancel_before_execution : now:Timestamp.t -> t -> transition
(* Requests termination of accepted or running work. *)
val request_execution_cancel : now:Timestamp.t -> t -> transition
val request_cancel : now:Timestamp.t -> t -> transition
val confirm_cancel : now:Timestamp.t -> t -> transition
val permanently_fail : now:Timestamp.t -> reason:string -> t -> transition
