open Orchestraml_domain
open Identifiers
open Shared
type outcome = Succeeded of int | Failed of Failure.t
type cleanup = Pending | Removed | Cleanup_failed
type metadata = { attempt_id:Attempt_id.t; worker_id:Worker_id.t; container_id:string;
  container_name:string; image_reference:string; created_at:Foundation.Timestamp.t;
  started_at:Foundation.Timestamp.t option; finished_at:Foundation.Timestamp.t option;
  removed_at:Foundation.Timestamp.t option; cleanup:cleanup }
type running
val capability : sw:Eio.Switch.t -> process_mgr:_ Eio.Process.mgr -> executable:string -> bool
val prepare : sw:Eio.Switch.t -> process_mgr:_ Eio.Process.mgr -> executable:string ->
  worker_id:Worker_id.t -> job_id:Job_id.t -> attempt_id:Attempt_id.t -> resources:Resources.t ->
  on_output:(Log_entry.stream -> string -> unit) -> image:string -> command:string list ->
  (running, Failure.t) result
val activate : running -> (unit, Failure.t) result
val metadata : running -> metadata
val discard : running -> unit
val await : running -> outcome
val stop : grace:float -> running -> unit
val is_finished : running -> bool
val cleanup_orphans : sw:Eio.Switch.t -> process_mgr:_ Eio.Process.mgr -> executable:string ->
  worker_id:Worker_id.t -> metadata list
