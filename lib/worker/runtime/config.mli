open Orchestraml_domain.Foundation
open Orchestraml_domain.Shared
type t = { coordinator_url : Uri.t; identity_file : string; name : string;
  labels : Worker_label.Set.t; max_concurrency : Scalar.Concurrency.t;
  resources : Resources.t; heartbeat_interval : float; poll_interval : float;
  control_poll_interval : float; termination_grace : float }
val load : unit -> (t, string list) result
