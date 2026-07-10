type kind = Temporary_execution_failure | Network_interruption | Worker_lost
  | Assignment_timeout | Execution_timeout | Invalid_command | Missing_executable
  | Invalid_container_image | Invalid_configuration | Permission_denied
  | Cancelled_by_user | Unknown
type t = { kind : kind; message : string option }
let create ?message kind = { kind; message }
let kind value = value.kind
let message value = value.message
let retryable_by_default value = match value.kind with
  | Temporary_execution_failure | Network_interruption | Worker_lost | Assignment_timeout -> true
  | Execution_timeout | Invalid_command | Missing_executable | Invalid_container_image
  | Invalid_configuration | Permission_denied | Cancelled_by_user | Unknown -> false
let kind_to_string = function
  | Temporary_execution_failure -> "temporary_execution_failure"
  | Network_interruption -> "network_interruption" | Worker_lost -> "worker_lost"
  | Assignment_timeout -> "assignment_timeout" | Execution_timeout -> "execution_timeout"
  | Invalid_command -> "invalid_command" | Missing_executable -> "missing_executable"
  | Invalid_container_image -> "invalid_container_image"
  | Invalid_configuration -> "invalid_configuration"
  | Permission_denied -> "permission_denied" | Cancelled_by_user -> "cancelled_by_user"
  | Unknown -> "unknown"
