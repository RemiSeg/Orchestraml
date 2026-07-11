(** One execution attempt for a job. *)

open Foundation
open Identifiers
open Shared

type outcome = Success of int | Failure of Failure.t | Timed_out_outcome
  | Lost_outcome of string | Cancelled_outcome
type t
type transition = (t * Domain_event.t, Transition_error.t) result
type snapshot = { id : Attempt_id.t; job_id : Job_id.t; number : Scalar.Attempt_number.t;
  worker_id : Worker_id.t; status : Attempt_status.t; assigned_at : Timestamp.t;
  started_at : Timestamp.t option; finished_at : Timestamp.t option; outcome : outcome option }

val create : id:Attempt_id.t -> job_id:Job_id.t -> number:Scalar.Attempt_number.t ->
  worker_id:Worker_id.t -> assigned_at:Timestamp.t -> t
val id : t -> Attempt_id.t
val job_id : t -> Job_id.t
val number : t -> Scalar.Attempt_number.t
val worker_id : t -> Worker_id.t
val status : t -> Attempt_status.t
val assigned_at : t -> Timestamp.t
val started_at : t -> Timestamp.t option
val finished_at : t -> Timestamp.t option
val outcome : t -> outcome option
val snapshot : t -> snapshot
val restore : snapshot -> (t, Validation_error.t) result
val start : now:Timestamp.t -> t -> transition
val succeed : now:Timestamp.t -> exit_code:int -> t -> transition
val fail : now:Timestamp.t -> failure:Failure.t -> t -> transition
val time_out : now:Timestamp.t -> t -> transition
val lose : now:Timestamp.t -> reason:string -> t -> transition
val cancel : now:Timestamp.t -> t -> transition
