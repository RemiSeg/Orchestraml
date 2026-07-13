open Orchestraml_domain
open Identifiers
open Shared
type outcome = Succeeded of int | Failed of Failure.t
type termination = Already_exited | Exited_during_grace | Force_killed
type running
val start : sw:Eio.Switch.t -> process_mgr:_ Eio.Process.mgr -> docker_executable:string ->
  worker_id:Worker_id.t -> job_id:Job_id.t -> attempt_id:Attempt_id.t -> resources:Resources.t ->
  on_output:(Log_entry.stream -> string -> unit) -> Execution_spec.t -> (running,Failure.t) result
val activate : running -> (unit,Failure.t) result
val container_metadata : running -> Docker_process.metadata option
val discard : running -> unit
val await : running -> outcome
val stop : clock:_ Eio.Time.clock -> grace:float -> running -> termination
val is_finished : running -> bool
