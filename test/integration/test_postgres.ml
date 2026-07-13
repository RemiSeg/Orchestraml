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
  (match Services.Job_service.find jobs_b (Job.id created) |> service_ok with
  | None -> Alcotest.fail "job did not survive persistence recreation"
  | Some restored -> Alcotest.(check string) "restored job" "pending"
      (Job.status restored |> Job_status.to_string));
  let worker_id = Orchestraml_domain.Identifiers.Worker_id.of_string
    "00000000-0000-4000-8000-000000000777" |> get_ok in
  let registration : Services.Worker_service.registration = {
    name = "contract-worker"; labels = Foundation.Worker_label.Set.empty;
    max_concurrency = Scalar.Concurrency.create 1 |> get_ok;
    total_resources = Resources.create
      ~cpu:(Scalar.Cpu_millicores.create 1000 |> get_ok)
      ~memory:(Scalar.Memory_mib.create 512 |> get_ok) } in
  let worker_service = Services.Worker_service.create ~persistence:persistence_b ~clock ~ids in
  let register () = Services.Worker_service.register_with_id worker_service worker_id registration in
  let left = ref None and right = ref None in
  Eio.Fiber.both (fun () -> left := Some (register ())) (fun () -> right := Some (register ()));
  let registration_kinds = [Option.get !left; Option.get !right] |> List.map (function
    | Ok (Services.Worker_service.Registered _) -> "registered"
    | Ok (Services.Worker_service.Updated _) -> "updated"
    | Error _ -> "error") |> List.sort String.compare in
  Alcotest.(check (list string)) "concurrent worker upsert"
    ["registered"; "updated"] registration_kinds;
  ignore (Services.Worker_service.heartbeat worker_service worker_id
    { available_slots = 1; active_attempt_ids = [] } |> get_ok);
  let heartbeat = persistence_b.with_transaction (fun repositories ->
    repositories.workers.find_heartbeat worker_id) in
  (match heartbeat with
   | Ok (Ok (Some report)) -> Alcotest.(check int) "heartbeat slots" 1 report.available_slots
   | _ -> Alcotest.fail "heartbeat observation was not persisted");
  let unknown = Orchestraml_domain.Identifiers.Attempt_id.of_string
    "00000000-0000-4000-8000-000000000778" |> get_ok in
  let create_stop () = persistence_b.with_transaction (fun repositories ->
    repositories.controls.create_stop_unknown ~worker_id ~attempt_id:unknown
      ~requested_at:(clock.now ())) in
  let left = ref None and right = ref None in
  Eio.Fiber.both (fun () -> left := Some (create_stop ())) (fun () -> right := Some (create_stop ()););
  let created = [Option.get !left; Option.get !right] |> List.map (function
    | Ok (Ok true) -> "created" | Ok (Ok false) -> "existing" | _ -> "error")
    |> List.sort String.compare in
  Alcotest.(check (list string)) "one unknown stop request" ["created";"existing"] created;
  let controls = Services.Worker_service.poll_controls worker_service worker_id ~limit:10 |> get_ok in
  Alcotest.(check int) "stop control persisted" 1 (List.length controls);
  let wrong_worker = Orchestraml_domain.Identifiers.Worker_id.of_string
    "00000000-0000-4000-8000-000000000779" |> get_ok in
  ignore (Services.Worker_service.register_with_id worker_service wrong_worker registration |> get_ok);
  (match Services.Worker_service.confirm_stop_unknown worker_service wrong_worker unknown with
   | Error (Services.Worker_service.Persistence_error (Ports.Persistence.Conflict _)) -> ()
   | _ -> Alcotest.fail "wrong worker confirmed stop control");
  ignore (Services.Worker_service.confirm_stop_unknown worker_service worker_id unknown |> get_ok);
  ignore (Services.Worker_service.confirm_stop_unknown worker_service worker_id unknown |> get_ok);
  let scheduled_submission = { submission with priority = Scalar.Priority.create 100 } in
  let scheduled_job = Services.Job_service.submit jobs_b scheduled_submission |> service_ok in
  let health_policy = Worker_health.create
    ~suspect_after:(Scalar.Timeout_seconds.create 30 |> get_ok)
    ~offline_after:(Scalar.Timeout_seconds.create 60 |> get_ok) |> get_ok in
  let scheduling = Services.Scheduling_service.create ~persistence:persistence_b ~clock ~ids ~health_policy in
  let poll () = Services.Scheduling_service.poll_for_worker scheduling worker_id in
  let first_poll = ref None and second_poll = ref None in
  Eio.Fiber.both (fun () -> first_poll := Some (poll ())) (fun () -> second_poll := Some (poll ()));
  let poll_kinds = [Option.get !first_poll; Option.get !second_poll] |> List.map (function
    | Ok (Services.Scheduling_service.Assigned _) -> "assigned"
    | Ok Services.Scheduling_service.No_assignment -> "none"
    | Error _ -> "error") |> List.sort String.compare in
  Alcotest.(check (list string)) "concurrent targeted poll" ["assigned"; "none"] poll_kinds;
  Alcotest.(check int) "one attempt" 1
    (Services.Job_service.attempts jobs_b (Job.id scheduled_job) |> service_ok |> List.length);
  let assignment = [Option.get !first_poll; Option.get !second_poll] |> List.find_map (function
    | Ok (Services.Scheduling_service.Assigned value) -> Some value | _ -> None) |> Option.get in
  let logs = Services.Log_service.create ~persistence:persistence_b ~clock in
  let entry payload = Log_entry.create ~attempt_id:(Attempt.id assignment.attempt)
    ~sequence:(Log_entry.sequence 1 |> get_ok) ~stream:Log_entry.Stdout
    ~observed_at:(clock.now ()) ~payload |> get_ok in
  ignore (Services.Log_service.append_batch logs ~worker_id ~attempt_id:(Attempt.id assignment.attempt)
    [entry "durable-output"] |> get_ok);
  ignore (Services.Log_service.append_batch logs ~worker_id ~attempt_id:(Attempt.id assignment.attempt)
    [entry "durable-output"] |> get_ok);
  (match Services.Log_service.append_batch logs ~worker_id ~attempt_id:(Attempt.id assignment.attempt)
      [entry "conflict"] with
   | Error (Services.Log_service.Persistence_error (Ports.Persistence.Conflict _)) -> ()
   | _ -> Alcotest.fail "PostgreSQL accepted conflicting log replay");
  let logs_after_restart = Services.Log_service.create
    ~persistence:(Infrastructure.Postgres.Persistence.create database) ~clock in
  Alcotest.(check int) "logs survive repository recreation" 1
    (Services.Log_service.list logs_after_restart ~attempt_id:(Attempt.id assignment.attempt)
      ~after_sequence:0 ~limit:10 |> get_ok |> List.length);
  let docker_label=Worker_label.create "docker"|>get_ok in
  let docker_registration={registration with labels=Worker_label.Set.singleton docker_label} in
  ignore(Services.Worker_service.register_with_id worker_service wrong_worker docker_registration|>get_ok);
  let container_submission={submission with execution=Execution_spec.container ~image:"alpine:3.21"
      ~command:["true"]|>get_ok;priority=Scalar.Priority.create 200} in
  ignore(Services.Job_service.submit jobs_b container_submission|>service_ok);
  let container_assignment=match Services.Scheduling_service.poll_for_worker scheduling wrong_worker|>get_ok with
    |Services.Scheduling_service.Assigned value->value|_->Alcotest.fail "container was not assigned" in
  let observed=clock.now() in
  let metadata : Ports.Persistence.container_metadata={attempt_id=Attempt.id container_assignment.attempt;
    worker_id=wrong_worker;container_id="postgres-container";container_name="orchestraml-postgres";
    image_reference="alpine:3.21";created_at=observed;started_at=None;finished_at=None;removed_at=None;
    cleanup_outcome=Ports.Persistence.Pending} in
  let containers=Services.Container_service.create ~persistence:persistence_b in
  let record()=Services.Container_service.record containers ~worker_id:wrong_worker ~metadata in
  let left=ref None and right=ref None in Eio.Fiber.both(fun()->left:=Some(record()))(fun()->right:=Some(record()));
  List.iter(function Ok _->()|Error error->Alcotest.failf "concurrent identical metadata failed: %s"
      (match error with Services.Container_service.Persistence_error(Ports.Persistence.Storage_failure message)->message
       |Services.Container_service.Persistence_error(Ports.Persistence.Conflict message)->message
       |Services.Container_service.Persistence_error _->"persistence"
       |Services.Container_service.Invalid_metadata message->message
       |Services.Container_service.Conflict message->message
       |Services.Container_service.Wrong_worker->"wrong worker"
       |Services.Container_service.Not_container_attempt->"not container"))
    [Option.get !left;Option.get !right];
  (match Services.Container_service.record containers ~worker_id:wrong_worker
      ~metadata:{metadata with container_id="conflict"} with
   |Error(Services.Container_service.Conflict _)->()|_->Alcotest.fail "PostgreSQL metadata conflict accepted");
  let removed={metadata with started_at=Some observed;finished_at=Some observed;removed_at=Some observed;
    cleanup_outcome=Ports.Persistence.Removed} in
  (match Services.Container_service.record containers ~worker_id:wrong_worker ~metadata:removed with
   |Ok _->()|Error error->Alcotest.failf "container removal update failed: %s" (match error with
     |Services.Container_service.Persistence_error(Ports.Persistence.Storage_failure message)->message
     |Services.Container_service.Persistence_error(Ports.Persistence.Conflict message)->message
     |Services.Container_service.Persistence_error _->"persistence"
     |Services.Container_service.Invalid_metadata message->message
     |Services.Container_service.Conflict message->message
     |Services.Container_service.Wrong_worker->"wrong worker"
     |Services.Container_service.Not_container_attempt->"not container"));
  let after_restart=Services.Container_service.create
    ~persistence:(Infrastructure.Postgres.Persistence.create database) in
  match Services.Container_service.find after_restart metadata.attempt_id|>get_ok with
  |Some stored->Alcotest.(check bool) "container metadata survives restart" true
      (stored.cleanup_outcome=Ports.Persistence.Removed)
  |None->Alcotest.fail "container metadata did not survive restart"
let () = Alcotest.run "orchestraml-postgres" ["restart",[
  Alcotest.test_case "persist and recreate coordinator dependencies" `Quick run]]
