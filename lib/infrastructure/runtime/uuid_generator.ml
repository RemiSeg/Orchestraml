open Orchestraml_domain.Identifiers
let create () =
  let generator = Uuidm.v4_gen (Random.State.make_self_init ()) in
  let next parse () = generator () |> Uuidm.to_string |> parse |> Result.get_ok in
  ({ next_job_id = next Job_id.of_string; next_attempt_id = next Attempt_id.of_string;
     next_worker_id = next Worker_id.of_string } : Orchestraml_application.Ports.Id_generator.t)
