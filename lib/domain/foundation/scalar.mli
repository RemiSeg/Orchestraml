(** Validated numeric and textual domain values. *)

module type INT_VALUE = sig
  type t
  val create : int -> (t, Validation_error.t) result
  val value : t -> int
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Cpu_millicores : INT_VALUE
module Memory_mib : INT_VALUE
module Timeout_seconds : INT_VALUE
module Retry_delay_seconds : INT_VALUE
module Max_attempts : INT_VALUE
module Concurrency : INT_VALUE
module Attempt_number : INT_VALUE

module Priority : sig
  type t
  val create : int -> t
  val value : t -> int
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Job_name : sig
  type t
  val create : string -> (t, Validation_error.t) result
  val value : t -> string
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end
