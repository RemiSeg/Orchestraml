open Foundation

type t = {
  max_attempts : Scalar.Max_attempts.t;
  initial_delay : Scalar.Retry_delay_seconds.t;
  multiplier : int;
  maximum_delay : Scalar.Retry_delay_seconds.t;
  retry_timeouts : bool;
}
type stop_reason = Non_retryable_failure | Attempts_exhausted | Timestamp_overflow
type decision = Retry_at of Timestamp.t | Do_not_retry of stop_reason

let create ~max_attempts ~initial_delay ~multiplier ~maximum_delay ~retry_timeouts =
  if multiplier < 1 then Error (Validation_error.make ~field:"retry_multiplier" "must be at least one")
  else if Scalar.Retry_delay_seconds.compare initial_delay maximum_delay > 0 then
    Error (Validation_error.make ~field:"maximum_delay" "must be at least the initial delay")
  else Ok { max_attempts; initial_delay; multiplier; maximum_delay; retry_timeouts }

let max_attempts value = value.max_attempts

let delay_seconds policy ~attempts_started =
  let cap = Scalar.Retry_delay_seconds.value policy.maximum_delay in
  let initial = Scalar.Retry_delay_seconds.value policy.initial_delay in
  let rec multiply value remaining =
    if remaining <= 0 || value >= cap then min value cap
    else if policy.multiplier > 0 && value > cap / policy.multiplier then cap
    else multiply (value * policy.multiplier) (remaining - 1)
  in
  multiply initial (max 0 (attempts_started - 1))

let retryable policy failure =
  match Failure.kind failure with
  | Failure.Execution_timeout -> policy.retry_timeouts
  | _ -> Failure.retryable_by_default failure

let decide policy ~failure ~attempts_started ~now =
  if attempts_started >= Scalar.Max_attempts.value policy.max_attempts then Do_not_retry Attempts_exhausted
  else if not (retryable policy failure) then Do_not_retry Non_retryable_failure
  else match Timestamp.add_seconds now (delay_seconds policy ~attempts_started) with
    | Some timestamp -> Retry_at timestamp
    | None -> Do_not_retry Timestamp_overflow
