open Orchestraml_domain
open Foundation
open Shared
open Core
open Orchestraml_application
module Infrastructure = Orchestraml_infrastructure
let get_ok = function Ok value -> value | Error _ -> Alcotest.fail "integration fixture failure"
let service_ok = function
  | Ok value -> value
  | Error (Services.Job_service.Persistence_error (Ports.Persistence.Storage_failure message)) ->
      Alcotest.failf "storage failure: %s" message
  | Error (Services.Job_service.Persistence_error _) -> Alcotest.fail "repository failure"
  | Error (Services.Job_service.Transition_rejected _) -> Alcotest.fail "transition rejected"
  | Error (Services.Job_service.Invalid_operation message) -> Alcotest.failf "invalid operation: %s" message
  | Error Services.Job_service.Idempotency_conflict -> Alcotest.fail "idempotency conflict"
let positive create value = create value |> get_ok
let resources = Resources.create ~cpu:(positive Scalar.Cpu_millicores.create 100)
  ~memory:(positive Scalar.Memory_mib.create 64)
let submission : Services.Job_service.submission = {
  name = Scalar.Job_name.create "durable-job" |> get_ok;
  execution = Execution_spec.command ~executable:"true" ~arguments:[] |> get_ok;
  priority = Scalar.Priority.create 1; requirements = resources;
  required_labels = Worker_label.Set.empty;
  retry_policy = Retry_policy.create ~max_attempts:(positive Scalar.Max_attempts.create 2)
    ~initial_delay:(positive Scalar.Retry_delay_seconds.create 5) ~multiplier:2
    ~maximum_delay:(positive Scalar.Retry_delay_seconds.create 20) ~retry_timeouts:true |> get_ok;
  timeout = positive Scalar.Timeout_seconds.create 30;
}
let run () =
  let database_url = Sys.getenv_opt "TEST_DATABASE_URL"
    |> Option.value ~default:"postgresql://orchestraml:orchestraml@postgres:5432/orchestraml" |> Uri.of_string in
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let database = match Infrastructure.Postgres.Database.connect ~sw ~env database_url with
    | Ok database -> database
    | Error message -> Alcotest.failf "database connection failed: %s" message in
  (match Infrastructure.Postgres.Migrations.apply database ~directory:"migrations" with
   | Ok () -> ()
   | Error (Infrastructure.Postgres.Migrations.Invalid_files message) ->
       Alcotest.failf "invalid migrations: %s" message
   | Error (Infrastructure.Postgres.Migrations.Database_error message) ->
       Alcotest.failf "migration database error: %s" message);
  Infrastructure.Postgres.Migrations.apply database ~directory:"migrations" |> get_ok;
  Infrastructure.Postgres.Migrations.check_current database ~directory:"migrations" |> get_ok;
  let clock = Infrastructure.Runtime.System_clock.create () in
  let ids = Infrastructure.Runtime.Uuid_generator.create () in
  let persistence_a = Infrastructure.Postgres.Persistence.create database in
  let jobs_a = Services.Job_service.create ~persistence:persistence_a ~clock ~ids in
  let created = Services.Job_service.submit jobs_a submission |> service_ok in
  let key = Idempotency_key.create "integration-request" |> get_ok in
  ignore (Services.Job_service.submit_idempotent jobs_a ~key ~canonical_payload:"stable" submission |> service_ok);
  let concurrent_key = Idempotency_key.create "integration-concurrent" |> get_ok in
  let submit () = Services.Job_service.submit_idempotent jobs_a ~key:concurrent_key
      ~canonical_payload:"concurrent-stable" submission in
  let left = ref None and right = ref None in
  Eio.Fiber.both (fun () -> left := Some (submit ()))
    (fun () -> right := Some (submit ()));
  let left = Option.get !left and right = Option.get !right in
  let classifications = [left; right] |> List.map (function
    | Ok (Services.Job_service.Created _) -> "created"
    | Ok (Services.Job_service.Replayed _) -> "replayed"
    | Error _ -> "error") |> List.sort String.compare in
  Alcotest.(check (list string)) "one concurrent create and one replay"
    ["created"; "replayed"] classifications;
  let persistence_b = Infrastructure.Postgres.Persistence.create database in
  let jobs_b = Services.Job_service.create ~persistence:persistence_b ~clock ~ids in
  match Services.Job_service.find jobs_b (Job.id created) |> service_ok with
  | None -> Alcotest.fail "job did not survive persistence recreation"
  | Some restored -> Alcotest.(check string) "restored job" "pending"
      (Job.status restored |> Job_status.to_string)
let () = Alcotest.run "orchestraml-postgres" ["restart",[
  Alcotest.test_case "persist and recreate coordinator dependencies" `Quick run]]
