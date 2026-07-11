(** Opaque keyset cursors for job listing. *)
open Orchestraml_domain
open Foundation
open Identifiers
type cursor = { created_at : Timestamp.t; job_id : Job_id.t }
val encode : cursor -> string
val decode : string -> (cursor, string) result
val validate_limit : int option -> (int, string) result
