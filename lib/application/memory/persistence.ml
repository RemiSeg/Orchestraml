open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
open Ports

module Store = struct
  type t = {
    jobs : (Job_id.t, Job.t) Hashtbl.t;
    attempts : (Attempt_id.t, Attempt.t) Hashtbl.t;
    workers : (Worker_id.t, Worker.t) Hashtbl.t;
    idempotency : (string, string * Job_id.t) Hashtbl.t;
    mutable events : Domain_event.t list;
  }
  let create () = { jobs = Hashtbl.create 32; attempts = Hashtbl.create 32;
    workers = Hashtbl.create 16; idempotency = Hashtbl.create 16; events = [] }
  let snapshot value = { jobs = Hashtbl.copy value.jobs;
    attempts = Hashtbl.copy value.attempts; workers = Hashtbl.copy value.workers;
    idempotency = Hashtbl.copy value.idempotency;
    events = value.events }
  let replace target source =
    Hashtbl.clear target;
    Hashtbl.iter (Hashtbl.replace target) source
  let restore value saved =
    replace value.jobs saved.jobs;
    replace value.attempts saved.attempts;
    replace value.workers saved.workers;
    replace value.idempotency saved.idempotency;
    value.events <- saved.events
  let jobs value = value.jobs
  let attempts value = value.attempts
  let workers value = value.workers
  let events value = value.events
  let append_event value event = value.events <- value.events @ [event]
end

let duplicate entity id = Persistence.Already_exists (entity, id)
let missing entity id = Persistence.Not_found (entity, id)

let event_entity_equal left right = match left, right with
  | Domain_event.Job left, Domain_event.Job right -> Job_id.equal left right
  | Domain_event.Attempt left, Domain_event.Attempt right -> Attempt_id.equal left right
  | _ -> false

let repositories store =
  let jobs = Store.jobs store and attempts = Store.attempts store and workers = Store.workers store in
  let create table entity id id_string value =
    if Hashtbl.mem table id then Error (duplicate entity id_string)
    else (Hashtbl.add table id value; Ok ()) in
  let update table entity id id_string value =
    if Hashtbl.mem table id then (Hashtbl.replace table id value; Ok ())
    else Error (missing entity id_string) in
  let all table = Hashtbl.fold (fun _ value values -> value :: values) table [] in
  let job_repository : Persistence.job_repository = {
    create_job = (fun job -> let id = Job.id job in
      create jobs Persistence.Job id (Job_id.to_string id) job);
    create_job_idempotent = (fun job ~canonical_payload ->
      match Job.idempotency_key job with
      | None -> Error (Persistence.Storage_failure "idempotent job is missing its key")
      | Some key ->
          let key = Idempotency_key.value key in
          match Hashtbl.find_opt store.idempotency key with
          | Some (stored_payload, stored_id) ->
              if String.equal stored_payload canonical_payload then
                (match Hashtbl.find_opt jobs stored_id with
                 | Some existing -> Ok (Persistence.Idempotency_replayed existing)
                 | None -> Error (Persistence.Storage_failure "idempotency index references a missing job"))
              else Ok Persistence.Idempotency_conflict
          | None ->
              let id = Job.id job in
              match create jobs Persistence.Job id (Job_id.to_string id) job with
              | Error error -> Error error
              | Ok () -> Hashtbl.add store.idempotency key (canonical_payload, id);
                  Ok (Persistence.Idempotency_created job));
    find_job = (fun id -> Ok (Hashtbl.find_opt jobs id));
    update_job = (fun job -> let id = Job.id job in
      update jobs Persistence.Job id (Job_id.to_string id) job);
    list_jobs = (fun () -> Ok (all jobs));
    list_jobs_page = (fun ~status ~before ~limit ->
      let compare_job left right =
        let by_time = Timestamp.compare (Job.created_at right) (Job.created_at left) in
        if by_time <> 0 then by_time else Job_id.compare (Job.id right) (Job.id left) in
      let before_cursor job = match before with
        | None -> true
        | Some cursor ->
            Timestamp.compare (Job.created_at job) cursor.created_at < 0
            || (Timestamp.equal (Job.created_at job) cursor.created_at
                && Job_id.compare (Job.id job) cursor.job_id < 0) in
      let rec take count = function
        | _ when count = 0 -> [] | [] -> []
        | value :: rest -> value :: take (count - 1) rest in
      Ok (all jobs |> List.filter (fun job ->
        (match status with None -> true | Some expected -> Job_status.equal expected (Job.status job))
        && before_cursor job) |> List.sort compare_job |> take limit));
    list_pending_jobs = (fun () -> Ok (all jobs |> List.filter
      (fun job -> Job_status.equal (Job.status job) Job_status.Pending)));
    list_retry_ready_jobs = (fun ~now -> Ok (all jobs |> List.filter (fun job ->
      Job_status.equal (Job.status job) Job_status.Retry_waiting
      && match Job.next_retry_at job with Some at -> Timestamp.compare at now <= 0 | None -> false)));
  } in
  let attempt_repository : Persistence.attempt_repository = {
    create_attempt = (fun attempt -> let id = Attempt.id attempt in
      create attempts Persistence.Attempt id (Attempt_id.to_string id) attempt);
    find_attempt = (fun id -> Ok (Hashtbl.find_opt attempts id));
    update_attempt = (fun attempt -> let id = Attempt.id attempt in
      update attempts Persistence.Attempt id (Attempt_id.to_string id) attempt);
    list_attempts_for_job = (fun job_id -> Ok (all attempts |> List.filter
      (fun attempt -> Job_id.equal (Attempt.job_id attempt) job_id) |> List.sort
      (fun left right -> Scalar.Attempt_number.compare (Attempt.number left) (Attempt.number right))));
  } in
  let worker_repository : Persistence.worker_repository = {
    create_worker = (fun worker -> let id = Worker.id worker in
      create workers Persistence.Worker id (Worker_id.to_string id) worker);
    find_worker = (fun id -> Ok (Hashtbl.find_opt workers id));
    update_worker = (fun worker -> let id = Worker.id worker in
      update workers Persistence.Worker id (Worker_id.to_string id) worker);
    list_workers = (fun () -> Ok (all workers));
  } in
  let event_repository : Persistence.event_repository = {
    append_event = (fun event -> Store.append_event store event; Ok ());
    list_events = (fun () -> Ok (Store.events store));
    list_events_for_entity = (fun entity -> Ok (Store.events store |> List.filter
      (fun event -> event_entity_equal event.Domain_event.entity entity)));
  } in
  { Persistence.jobs = job_repository; attempts = attempt_repository;
    workers = worker_repository; events = event_repository }

let create () =
  let store = Store.create () in
  let repository_set = repositories store in
  { Persistence.with_transaction = fun operation ->
      let saved = Store.snapshot store in
      match operation repository_set with
      | Ok _ as success -> Ok success
      | Error _ as failure -> Store.restore store saved; Ok failure
      | exception error -> Store.restore store saved; raise error }
