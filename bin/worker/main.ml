open Cmdliner
module Worker = Orchestraml_worker
module Log = Orchestraml_observability.Logger
let log level event message = Log.emit ~level ~component:"worker" ~event ~message ()
let run () =
  let config = match Worker.Runtime.Config.load () with
    | Ok value -> value | Error errors -> List.iter (log Log.Error "configuration_invalid") errors; exit 2 in
  let worker_id = match Worker.Runtime.Identity.load_or_create config.identity_file with
    | Ok value -> value | Error message -> log Log.Error "identity_invalid" message; exit 2 in
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let docker_label = Orchestraml_domain.Foundation.Worker_label.create "docker" |> Result.get_ok in
  let docker_available = Worker.Executor.Docker_process.capability ~sw ~process_mgr:env#process_mgr
    ~executable:(Worker.Runtime.Config.docker_executable config) in
  let labels = if docker_available then Orchestraml_domain.Foundation.Worker_label.Set.add docker_label config.labels
    else Orchestraml_domain.Foundation.Worker_label.Set.remove docker_label config.labels in
  let config = { config with labels } in
  let http = Cohttp_eio.Client.make ~https:None env#net in
  let client = Worker.Client.Coordinator.create ~client:http ~base_uri:config.coordinator_url
    ~clock:env#clock ~request_timeout:10. in
  if docker_available then begin
    let observations=Worker.Executor.Docker_process.cleanup_orphans ~sw ~process_mgr:env#process_mgr
      ~executable:(Worker.Runtime.Config.docker_executable config) ~worker_id in
    List.iter(fun (observation:Worker.Executor.Docker_process.metadata)->match Worker.Client.Coordinator.find_container ~sw client observation.attempt_id with
      |Ok None->()|Error _->log Log.Error "orphan_metadata_lookup_failed" "orphan metadata lookup failed"
      |Ok(Some stored)->
        let updated={stored with removed_at=observation.removed_at;
          cleanup=(match observation.cleanup with Worker.Executor.Docker_process.Removed->Worker.Client.Coordinator.Removed
            |Worker.Executor.Docker_process.Cleanup_failed->Worker.Client.Coordinator.Cleanup_failed
            |Worker.Executor.Docker_process.Pending->stored.cleanup)} in
        let rec report()=match Worker.Client.Coordinator.record_container ~sw client updated with
          |Ok()->()|Error error when Worker.Client.Coordinator.retryable error->Eio.Time.sleep env#clock config.poll_interval;report()
          |Error _->log Log.Error "orphan_metadata_update_failed" "orphan metadata update failed" in
        report()) observations
  end;
  let control = Worker.Agent.create_control () in
  Log.emit ~level:Log.Info ~component:"worker" ~event:"agent_starting"
    ~message:"worker agent starting"
    ~worker_id:(Orchestraml_domain.Identifiers.Worker_id.to_string worker_id) ();
  Worker.Agent.run ~control ~sw ~clock:env#clock ~process_mgr:env#process_mgr
    ~config ~worker_id ~client
let cmd = Cmd.v (Cmd.info "orchestraml-worker" ~doc:"Run an Orchestraml worker agent")
  Term.(const run $ const ())
let () = exit (Cmd.eval cmd)
