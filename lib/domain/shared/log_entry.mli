(** Ordered binary output captured for one attempt. *)
open Foundation
open Identifiers
type stream = Stdout | Stderr
type sequence
type t
val sequence : int -> (sequence, Validation_error.t) result
val sequence_value : sequence -> int
val create : attempt_id:Attempt_id.t -> sequence:sequence -> stream:stream ->
  observed_at:Timestamp.t -> payload:string -> (t, Validation_error.t) result
val attempt_id : t -> Attempt_id.t
val sequence_number : t -> sequence
val stream : t -> stream
val observed_at : t -> Timestamp.t
val payload : t -> string
val equal : t -> t -> bool
val stream_to_string : stream -> string
val stream_of_string : string -> (stream, Validation_error.t) result
