(** Transport-independent HTTP routing for the coordinator API. *)
type request = { meth : string; target : string; headers : (string * string) list; body : string }
type body = Buffered of string | Follow_logs of {
  attempt_id : Orchestraml_domain.Identifiers.Attempt_id.t; after_sequence : int }
type response = { status : int; headers : (string * string) list; body : body }
type t
val create : jobs:Orchestraml_application.Services.Job_service.t ->
  workers:Orchestraml_application.Services.Worker_service.t ->
  scheduling:Orchestraml_application.Services.Scheduling_service.t ->
  execution:Orchestraml_application.Services.Execution_service.t ->
  logs:Orchestraml_application.Services.Log_service.t ->
  containers:Orchestraml_application.Services.Container_service.t ->
  metrics:Orchestraml_application.Services.Metrics_service.t ->
  health:(unit -> bool) -> t
val handle : t -> request -> response
val follow_snapshot : t -> attempt_id:Orchestraml_domain.Identifiers.Attempt_id.t ->
  after_sequence:int ->
  (Orchestraml_application.Services.Log_service.follow_snapshot,
   Orchestraml_application.Services.Log_service.error) result
