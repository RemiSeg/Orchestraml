(** Direct local command execution without a shell. *)
open Orchestraml_domain.Shared
type outcome = Succeeded of int | Failed of Failure.t
type termination = Exited_during_grace | Force_killed | Already_exited
type running
val start : sw:Eio.Switch.t -> process_mgr:_ Eio.Process.mgr ->
  ?on_output:(Log_entry.stream -> string -> unit) -> Execution_spec.t -> (running, Failure.t) result
val await : running -> outcome
val terminate : running -> unit
val kill : running -> unit
val stop : clock:_ Eio.Time.clock -> grace:float -> running -> termination
val is_finished : running -> bool
