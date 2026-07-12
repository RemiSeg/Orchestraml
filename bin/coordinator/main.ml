open Cmdliner
module Infrastructure = Orchestraml_infrastructure
module Coordinator = Orchestraml_coordinator
module Application = Orchestraml_application

let configuration () = match Infrastructure.Runtime.Config.load () with
  | Ok value -> value
  | Error errors -> List.iter prerr_endline errors; exit 2
let with_database operation =
  let config = configuration () in
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  match Infrastructure.Postgres.Database.connect ~sw ~env config.database_url with
  | Error error -> prerr_endline error; exit 1
  | Ok database -> operation config env sw database
let migrate () = with_database (fun config _env _sw database ->
  match Infrastructure.Postgres.Migrations.apply database ~directory:config.migrations_dir with
  | Ok () -> print_endline "migrations applied"
  | Error _ -> prerr_endline "migration failed"; exit 1)
let forever ~sw ~clock ~interval name cycle = Eio.Fiber.fork ~sw (fun () ->
  while true do
    (try cycle () with exn -> Format.eprintf "%s cycle failed: %s@." name (Printexc.to_string exn));
    Eio.Time.sleep clock interval
  done)
let serve () = with_database (fun config env sw database ->
  match Infrastructure.Postgres.Migrations.check_current database ~directory:config.migrations_dir with
  | Error _ -> prerr_endline "database migrations are not current"; exit 1
  | Ok () ->
      let persistence = Infrastructure.Postgres.Persistence.create database in
      let clock = Infrastructure.Runtime.System_clock.create () in
      let ids = Infrastructure.Runtime.Uuid_generator.create () in
      let jobs = Application.Services.Job_service.create ~persistence ~clock ~ids in
      let workers = Application.Services.Worker_service.create ~persistence ~clock ~ids in
      let health_policy = Orchestraml_domain.Shared.Worker_health.create
        ~suspect_after:(Orchestraml_domain.Foundation.Scalar.Timeout_seconds.create config.worker_suspect_after |> Result.get_ok)
        ~offline_after:(Orchestraml_domain.Foundation.Scalar.Timeout_seconds.create config.worker_offline_after |> Result.get_ok)
        |> Result.get_ok in
      let scheduling = Application.Services.Scheduling_service.create ~persistence ~clock ~ids ~health_policy in
      let execution = Application.Services.Execution_service.create ~persistence ~clock in
      let retry = Application.Services.Retry_service.create ~persistence ~clock in
      let seconds value = Orchestraml_domain.Foundation.Scalar.Timeout_seconds.create value |> Result.get_ok in
      let maintenance = Application.Services.Maintenance_service.create
        ~max_reconciliation_passes:config.startup_reconciliation_max_passes ~persistence ~clock ~health_policy
        ~acknowledgement_timeout:(seconds config.assignment_ack_timeout)
        ~execution_report_grace:(seconds config.execution_report_grace)
        ~recovery_grace:(seconds config.heartbeat_recovery_grace)
        ~batch_size:config.maintenance_batch_size in
      (match Application.Services.Maintenance_service.reconcile_startup maintenance with
       | Ok _ -> () | Error _ -> prerr_endline "startup reconciliation failed"; exit 1);
      forever ~sw ~clock:env#clock ~interval:config.scheduler_interval "scheduler" (fun () ->
        ignore (Application.Services.Scheduling_service.run_once scheduling));
      forever ~sw ~clock:env#clock ~interval:config.retry_interval "retry" (fun () ->
        ignore (Application.Services.Retry_service.run_once retry));
      forever ~sw ~clock:env#clock ~interval:config.maintenance_interval "assignment-timeout" (fun () ->
        ignore (Application.Services.Maintenance_service.run_assignment_timeout_cycle maintenance));
      forever ~sw ~clock:env#clock ~interval:config.maintenance_interval "execution-deadline" (fun () ->
        ignore (Application.Services.Maintenance_service.run_execution_deadline_cycle maintenance));
      forever ~sw ~clock:env#clock ~interval:config.maintenance_interval "worker-recovery" (fun () ->
        ignore (Application.Services.Maintenance_service.run_worker_recovery_cycle maintenance));
      forever ~sw ~clock:env#clock ~interval:config.maintenance_interval "heartbeat-reconciliation" (fun () ->
        ignore (Application.Services.Maintenance_service.run_heartbeat_reconciliation_cycle maintenance));
      let router = Coordinator.Api.Router.create ~jobs ~workers ~scheduling ~execution
        ~health:(fun () -> Result.is_ok (Infrastructure.Postgres.Database.health database)) in
      Coordinator.Server.Http_server.run ~sw ~net:env#net
        ~listen_address:config.listen_address ~port:config.port router)
let migrate_cmd = Cmd.v (Cmd.info "migrate" ~doc:"Apply pending database migrations")
  Term.(const migrate $ const ())
let serve_cmd = Cmd.v (Cmd.info "serve" ~doc:"Run the coordinator HTTP server")
  Term.(const serve $ const ())
let () = exit (Cmd.eval (Cmd.group (Cmd.info "orchestraml-coordinator") [migrate_cmd; serve_cmd]))
