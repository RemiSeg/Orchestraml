open Foundation
open Identifiers
type stream = Stdout | Stderr
type sequence = int
type t = { attempt_id : Attempt_id.t; sequence : sequence; stream : stream;
  observed_at : Timestamp.t; payload : string }
let sequence value = if value > 0 then Ok value else
  Error (Validation_error.make ~field:"sequence" "must be positive")
let sequence_value value = value
let create ~attempt_id ~sequence ~stream ~observed_at ~payload =
  if String.length payload > 16 * 1024 then
    Error (Validation_error.make ~field:"payload" "must not exceed 16384 bytes")
  else Ok { attempt_id; sequence; stream; observed_at; payload }
let attempt_id value = value.attempt_id
let sequence_number value = value.sequence
let stream value = value.stream
let observed_at value = value.observed_at
let payload value = value.payload
let equal left right = Attempt_id.equal left.attempt_id right.attempt_id
  && left.sequence = right.sequence && left.stream = right.stream
  && Timestamp.equal left.observed_at right.observed_at && String.equal left.payload right.payload
let stream_to_string = function Stdout -> "stdout" | Stderr -> "stderr"
let stream_of_string = function "stdout" -> Ok Stdout | "stderr" -> Ok Stderr
  | _ -> Error (Validation_error.make ~field:"stream" "must be stdout or stderr")
