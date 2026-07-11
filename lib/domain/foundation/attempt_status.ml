type t = Assigned | Running | Succeeded | Failed | Timed_out | Lost | Cancelled
let is_terminal = function Assigned | Running -> false | _ -> true
let to_string = function
  | Assigned -> "assigned" | Running -> "running" | Succeeded -> "succeeded"
  | Failed -> "failed" | Timed_out -> "timed_out" | Lost -> "lost"
  | Cancelled -> "cancelled"
let of_string = function
  | "assigned" -> Ok Assigned | "running" -> Ok Running | "succeeded" -> Ok Succeeded
  | "failed" -> Ok Failed | "timed_out" -> Ok Timed_out | "lost" -> Ok Lost
  | "cancelled" -> Ok Cancelled
  | _ -> Error (Validation_error.make ~field:"attempt_status" "is not a recognized status")
let equal left right = left = right
let pp formatter value = Format.pp_print_string formatter (to_string value)
