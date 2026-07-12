(** Explicit worker protocol JSON contracts. *)
open Orchestraml_domain
open Core
type heartbeat = Orchestraml_application.Services.Worker_service.heartbeat
type result_report = Succeeded of int | Failed of Shared.Failure.t
  | Timed_out | Lost of string | Cancelled
val decode_registration : Yojson.Safe.t ->
  (Orchestraml_application.Services.Worker_service.registration, string list) result
val decode_heartbeat : Yojson.Safe.t -> (heartbeat, string list) result
val decode_result : Yojson.Safe.t -> (result_report, string list) result
val worker : Worker.t -> Yojson.Safe.t
val assignment : Orchestraml_application.Services.Scheduling_service.assignment -> Yojson.Safe.t
val control : Orchestraml_application.Ports.Persistence.control_request -> Yojson.Safe.t
