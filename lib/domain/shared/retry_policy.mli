(** Deterministic, capped exponential-backoff retry decisions. *)

open Foundation

type t
type stop_reason = Non_retryable_failure | Attempts_exhausted | Timestamp_overflow
type decision = Retry_at of Timestamp.t | Do_not_retry of stop_reason

val create : max_attempts:Scalar.Max_attempts.t ->
  initial_delay:Scalar.Retry_delay_seconds.t -> multiplier:int ->
  maximum_delay:Scalar.Retry_delay_seconds.t -> retry_timeouts:bool ->
  (t, Validation_error.t) result
val max_attempts : t -> Scalar.Max_attempts.t
val delay_seconds : t -> attempts_started:int -> int
val decide : t -> failure:Failure.t -> attempts_started:int -> now:Timestamp.t -> decision
