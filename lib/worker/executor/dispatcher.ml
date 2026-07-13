open Orchestraml_domain
open Shared
type outcome = Succeeded of int | Failed of Failure.t
type termination = Already_exited | Exited_during_grace | Force_killed
type running = Local of Local_process.running | Docker of Docker_process.running
let start ~sw ~process_mgr ~docker_executable ~worker_id ~job_id ~attempt_id ~resources ~on_output specification =
  Execution_spec.fold specification
    ~command:(fun executable arguments -> Local_process.start ~sw ~process_mgr ~on_output
      (Execution_spec.command ~executable ~arguments |> Result.get_ok) |> Result.map (fun x->Local x))
    ~container:(fun image command -> Docker_process.prepare ~sw ~process_mgr ~executable:docker_executable
      ~worker_id ~job_id ~attempt_id ~resources ~on_output ~image ~command |> Result.map(fun x->Docker x))
let activate=function Local _->Ok()|Docker value->Docker_process.activate value
let container_metadata=function Local _->None|Docker value->Some(Docker_process.metadata value)
let discard=function Local _->()|Docker value->Docker_process.discard value
let await=function Local value->(match Local_process.await value with Local_process.Succeeded x->Succeeded x|Local_process.Failed x->Failed x)
  |Docker value->(match Docker_process.await value with Docker_process.Succeeded x->Succeeded x|Docker_process.Failed x->Failed x)
let stop ~clock ~grace=function
  | Local value -> (match Local_process.stop ~clock ~grace value with
      | Local_process.Already_exited -> Already_exited
      | Local_process.Exited_during_grace -> Exited_during_grace
      | Local_process.Force_killed -> Force_killed)
  | Docker value -> Docker_process.stop ~grace value; Exited_during_grace
let is_finished=function Local value->Local_process.is_finished value|Docker value->Docker_process.is_finished value
