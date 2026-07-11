(** Structured execution failures and their default retry classification. *)
open Foundation

type kind = Temporary_execution_failure | Network_interruption | Worker_lost
  | Assignment_timeout | Execution_timeout | Invalid_command | Missing_executable
  | Invalid_container_image | Invalid_configuration | Permission_denied
  | Cancelled_by_user | Unknown
type t
val create : ?message:string -> kind -> t
val kind : t -> kind
val message : t -> string option
val retryable_by_default : t -> bool
val kind_to_string : kind -> string
val kind_of_string : string -> (kind, Validation_error.t) result
