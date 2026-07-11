open Orchestraml_domain.Identifiers
type t = { mutable job : int; mutable attempt : int; mutable worker : int }
let create () = { job = 0; attempt = 0; worker = 0 }
let uuid counter = Printf.sprintf "00000000-0000-4000-8000-%012d" counter
let next get set parse value =
  let counter = get value + 1 in
  set value counter;
  parse (uuid counter) |> Result.get_ok
let port value : Orchestraml_application.Ports.Id_generator.t = {
  next_job_id = (fun () -> next (fun t -> t.job) (fun t n -> t.job <- n) Job_id.of_string value);
  next_attempt_id = (fun () -> next (fun t -> t.attempt) (fun t n -> t.attempt <- n) Attempt_id.of_string value);
  next_worker_id = (fun () -> next (fun t -> t.worker) (fun t n -> t.worker <- n) Worker_id.of_string value);
}
