module type INT_VALUE = sig
  type t
  val create : int -> (t, Validation_error.t) result
  val value : t -> int
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Make_int (Rule : sig
  val field : string
  val valid : int -> bool
  val message : string
end) = struct
  type t = int
  let create value =
    if Rule.valid value then Ok value
    else Error (Validation_error.make ~field:Rule.field Rule.message)
  let value value = value
  let compare = Int.compare
  let pp = Format.pp_print_int
end

module Cpu_millicores = Make_int (struct
  let field = "cpu_millicores"
  let valid value = value >= 0
  let message = "must be non-negative"
end)

module Memory_mib = Make_int (struct
  let field = "memory_mib"
  let valid value = value >= 0
  let message = "must be non-negative"
end)

module Timeout_seconds = Make_int (struct
  let field = "timeout_seconds"
  let valid value = value > 0
  let message = "must be positive"
end)

module Retry_delay_seconds = Make_int (struct
  let field = "retry_delay_seconds"
  let valid value = value > 0
  let message = "must be positive"
end)

module Max_attempts = Make_int (struct
  let field = "max_attempts"
  let valid value = value > 0
  let message = "must be at least one"
end)

module Concurrency = Make_int (struct
  let field = "concurrency"
  let valid value = value > 0
  let message = "must be at least one"
end)

module Attempt_number = Make_int (struct
  let field = "attempt_number"
  let valid value = value > 0
  let message = "must be positive"
end)

module Priority = struct
  type t = int
  let create value = value
  let value value = value
  let compare = Int.compare
  let pp = Format.pp_print_int
end

module Job_name = struct
  type t = string
  let create value =
    let normalized = String.trim value in
    if String.length normalized = 0 then
      Error (Validation_error.make ~field:"job_name" "must not be empty")
    else Ok normalized
  let value value = value
  let compare = String.compare
  let pp = Format.pp_print_string
end
