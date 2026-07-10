type t = Pending | Assigned | Running | Retry_waiting | Cancelling
  | Completed | Permanently_failed | Cancelled
let is_terminal = function Completed | Permanently_failed | Cancelled -> true | _ -> false
let to_string = function
  | Pending -> "pending" | Assigned -> "assigned" | Running -> "running"
  | Retry_waiting -> "retry_waiting" | Cancelling -> "cancelling"
  | Completed -> "completed" | Permanently_failed -> "permanently_failed"
  | Cancelled -> "cancelled"
let equal left right = left = right
let pp formatter value = Format.pp_print_string formatter (to_string value)
