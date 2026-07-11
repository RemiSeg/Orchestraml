(** Transport-independent HTTP routing for the coordinator API. *)
type request = { meth : string; target : string; headers : (string * string) list; body : string }
type response = { status : int; headers : (string * string) list; body : string }
type t
val create : jobs:Orchestraml_application.Services.Job_service.t ->
  health:(unit -> bool) -> t
val handle : t -> request -> response
