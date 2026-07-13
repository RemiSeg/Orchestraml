open Orchestraml_domain
open Identifiers
open Shared
val decode_batch : attempt_id:Attempt_id.t -> Yojson.Safe.t ->
  (Worker_id.t * Log_entry.t list, string list) result
val entry : Log_entry.t -> Yojson.Safe.t
