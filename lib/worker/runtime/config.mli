open Orchestraml_domain.Foundation
open Orchestraml_domain.Shared
type t = { coordinator_url : Uri.t; identity_file : string; name : string;
  labels : Worker_label.Set.t; max_concurrency : Scalar.Concurrency.t;
  resources : Resources.t; heartbeat_interval : float; poll_interval : float;
  control_poll_interval : float; termination_grace : float; docker_executable_value:string;
  log_batch_bytes_value:int; log_flush_interval_value:float; log_pending_limit_value:int }
val docker_executable : t -> string
val log_batch_bytes : t -> int
val log_flush_interval : t -> float
val log_pending_limit : t -> int
val load : unit -> (t, string list) result
