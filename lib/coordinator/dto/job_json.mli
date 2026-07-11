(** Explicit JSON contracts for jobs, attempts, and events. *)
open Orchestraml_domain
open Core
type decoded_submission = {
  submission : Orchestraml_application.Services.Job_service.submission;
  canonical_payload : string;
}
val decode_submission : Yojson.Safe.t -> (decoded_submission, string list) result
val job : Job.t -> Yojson.Safe.t
val attempt : Attempt.t -> Yojson.Safe.t
val event : Shared.Domain_event.t -> Yojson.Safe.t
