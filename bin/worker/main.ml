open Cmdliner
module Worker = Orchestraml_worker
let run () =
  let config = match Worker.Runtime.Config.load () with
    | Ok value -> value | Error errors -> List.iter prerr_endline errors; exit 2 in
  let worker_id = match Worker.Runtime.Identity.load_or_create config.identity_file with
    | Ok value -> value | Error message -> prerr_endline message; exit 2 in
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let http = Cohttp_eio.Client.make ~https:None env#net in
  let client = Worker.Client.Coordinator.create ~client:http ~base_uri:config.coordinator_url
    ~clock:env#clock ~request_timeout:10. in
  let control = Worker.Agent.create_control () in
  Worker.Agent.run ~control ~sw ~clock:env#clock ~process_mgr:env#process_mgr
    ~config ~worker_id ~client
let cmd = Cmd.v (Cmd.info "orchestraml-worker" ~doc:"Run an Orchestraml worker agent")
  Term.(const run $ const ())
let () = exit (Cmd.eval cmd)
