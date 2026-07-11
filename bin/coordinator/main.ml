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
let serve () = with_database (fun config env sw database ->
  match Infrastructure.Postgres.Migrations.check_current database ~directory:config.migrations_dir with
  | Error _ -> prerr_endline "database migrations are not current"; exit 1
  | Ok () ->
      let persistence = Infrastructure.Postgres.Persistence.create database in
      let clock = Infrastructure.Runtime.System_clock.create () in
      let ids = Infrastructure.Runtime.Uuid_generator.create () in
      let jobs = Application.Services.Job_service.create ~persistence ~clock ~ids in
      let router = Coordinator.Api.Router.create ~jobs
        ~health:(fun () -> Result.is_ok (Infrastructure.Postgres.Database.health database)) in
      Coordinator.Server.Http_server.run ~sw ~net:env#net
        ~listen_address:config.listen_address ~port:config.port router)
let migrate_cmd = Cmd.v (Cmd.info "migrate" ~doc:"Apply pending database migrations")
  Term.(const migrate $ const ())
let serve_cmd = Cmd.v (Cmd.info "serve" ~doc:"Run the coordinator HTTP server")
  Term.(const serve $ const ())
let () = exit (Cmd.eval (Cmd.group (Cmd.info "orchestraml-coordinator") [migrate_cmd; serve_cmd]))
