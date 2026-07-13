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
    heartbeats : (Worker_id.t, Persistence.heartbeat_report) Hashtbl.t;
    controls : (Attempt_id.t, Persistence.control_request) Hashtbl.t;
    missing_since : (Attempt_id.t, Timestamp.t) Hashtbl.t;
    claimed_assignments : (Attempt_id.t, Timestamp.t) Hashtbl.t;
    stop_requests : (string, Persistence.control_request) Hashtbl.t;
    logs : (string, Log_entry.t) Hashtbl.t;
    containers : (Attempt_id.t, Persistence.container_metadata) Hashtbl.t;
  }
  let create () = { jobs = Hashtbl.create 32; attempts = Hashtbl.create 32;
    workers = Hashtbl.create 16; idempotency = Hashtbl.create 16; events = [];
    heartbeats = Hashtbl.create 16; controls = Hashtbl.create 16;
    missing_since = Hashtbl.create 16; claimed_assignments = Hashtbl.create 16;
    stop_requests = Hashtbl.create 16; logs = Hashtbl.create 64; containers = Hashtbl.create 16 }
  let snapshot value = { jobs = Hashtbl.copy value.jobs;
    attempts = Hashtbl.copy value.attempts; workers = Hashtbl.copy value.workers;
    idempotency = Hashtbl.copy value.idempotency;
    events = value.events; heartbeats = Hashtbl.copy value.heartbeats;
    controls = Hashtbl.copy value.controls; missing_since = Hashtbl.copy value.missing_since;
    claimed_assignments = Hashtbl.copy value.claimed_assignments;
    stop_requests = Hashtbl.copy value.stop_requests; logs = Hashtbl.copy value.logs;
    containers = Hashtbl.copy value.containers }
  let replace target source =
    Hashtbl.clear target;
    Hashtbl.iter (Hashtbl.replace target) source
  let restore value saved =
    replace value.jobs saved.jobs;
    replace value.attempts saved.attempts;
    replace value.workers saved.workers;
    replace value.idempotency saved.idempotency;
    replace value.heartbeats saved.heartbeats;
    replace value.controls saved.controls;
    replace value.missing_since saved.missing_since;
    replace value.claimed_assignments saved.claimed_assignments;
    replace value.stop_requests saved.stop_requests;
    replace value.logs saved.logs;
    replace value.containers saved.containers;
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
  let rec take count = function
    | _ when count <= 0 -> [] | [] -> []
    | value :: rest -> value :: take (count - 1) rest in
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
    list_retry_ready_jobs_bounded = (fun ~now ~limit -> Ok (all jobs |> List.filter (fun job ->
      Job_status.equal (Job.status job) Job_status.Retry_waiting
      && match Job.next_retry_at job with Some at -> Timestamp.compare at now <= 0 | None -> false)
      |> List.sort (fun a b -> Option.compare Timestamp.compare (Job.next_retry_at a) (Job.next_retry_at b))
      |> take limit));
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
    list_active_attempts_for_worker = (fun worker_id -> Ok (all attempts |> List.filter (fun attempt ->
      Worker_id.equal worker_id (Attempt.worker_id attempt)
      && (Attempt_status.equal (Attempt.status attempt) Attempt_status.Assigned
          || Attempt_status.equal (Attempt.status attempt) Attempt_status.Running))));
    list_expired_unacknowledged = (fun ~before ~limit -> Ok (all attempts |> List.filter (fun attempt ->
      Attempt_status.equal (Attempt.status attempt) Attempt_status.Assigned
      && Attempt.acknowledged_at attempt = None
      && Timestamp.compare (Attempt.assigned_at attempt) before <= 0)
      |> List.sort (fun a b -> Timestamp.compare (Attempt.assigned_at a) (Attempt.assigned_at b))
      |> take limit));
    list_overdue_running = (fun ~now ~grace_seconds ~limit -> Ok (all attempts |> List.filter (fun attempt ->
      match Attempt.started_at attempt, Hashtbl.find_opt jobs (Attempt.job_id attempt) with
      | Some started, Some job when Attempt_status.equal (Attempt.status attempt) Attempt_status.Running ->
          let timeout = Scalar.Timeout_seconds.value (Job.timeout job) + grace_seconds in
          (match Timestamp.add_seconds started timeout with Some deadline -> Timestamp.compare deadline now <= 0 | None -> false)
      | _ -> false) |> take limit));
    claim_assigned_attempt = (fun worker_id ~polled_at ->
      match all attempts |> List.filter (fun attempt -> Worker_id.equal worker_id (Attempt.worker_id attempt)
        && Attempt_status.equal (Attempt.status attempt) Attempt_status.Assigned
        && Attempt.acknowledged_at attempt = None
        && not (Hashtbl.mem store.claimed_assignments (Attempt.id attempt)))
        |> List.sort (fun a b -> Timestamp.compare (Attempt.assigned_at a) (Attempt.assigned_at b)) with
      | [] -> Ok None
      | attempt :: _ -> Hashtbl.add store.claimed_assignments (Attempt.id attempt) polled_at; Ok (Some attempt));
  } in
  let worker_repository : Persistence.worker_repository = {
    create_worker = (fun worker -> let id = Worker.id worker in
      create workers Persistence.Worker id (Worker_id.to_string id) worker);
    upsert_worker = (fun worker -> let id = Worker.id worker in
      let created = not (Hashtbl.mem workers id) in Hashtbl.replace workers id worker; Ok created);
    find_worker = (fun id -> Ok (Hashtbl.find_opt workers id));
    lock_worker = (fun id -> Ok (Hashtbl.find_opt workers id));
    update_worker = (fun worker -> let id = Worker.id worker in
      update workers Persistence.Worker id (Worker_id.to_string id) worker);
    list_workers = (fun () -> Ok (all workers));
    store_heartbeat = (fun id report -> if Hashtbl.mem workers id then
      (Hashtbl.replace store.heartbeats id report; Ok ()) else Error (missing Persistence.Worker (Worker_id.to_string id)));
    find_heartbeat = (fun id -> Ok (Hashtbl.find_opt store.heartbeats id));
    list_stale_workers = (fun ~before ~limit -> Ok (all workers |> List.filter
      (fun worker -> Timestamp.compare (Worker.last_heartbeat worker) before <= 0) |> take limit));
  } in
  let event_repository : Persistence.event_repository = {
    append_event = (fun event -> Store.append_event store event; Ok ());
    list_events = (fun () -> Ok (Store.events store));
    list_events_for_entity = (fun entity -> Ok (Store.events store |> List.filter
      (fun event -> event_entity_equal event.Domain_event.entity entity)));
  } in
  let controls : Persistence.control_repository = {
    create_control = (fun request ->
      if Hashtbl.mem store.controls request.attempt_id then Ok false
      else (Hashtbl.add store.controls request.attempt_id request; Ok true));
    list_controls_for_worker = (fun worker_id ~now ~limit ->
      let values = (all store.controls @ all store.stop_requests) |> List.filter (fun (request : Persistence.control_request) ->
        Worker_id.equal worker_id request.worker_id && request.completed_at = None)
        |> List.sort (fun (a : Persistence.control_request) (b : Persistence.control_request) ->
          Timestamp.compare a.requested_at b.requested_at) |> take limit in
      List.iter (fun (request : Persistence.control_request) -> Hashtbl.replace store.controls request.attempt_id
        { request with delivered_at = Some now }) (List.filter (fun (r : Persistence.control_request) -> r.kind <> Persistence.Stop_unknown) values);
      List.iter (fun (request : Persistence.control_request) -> Hashtbl.replace store.stop_requests
        (Worker_id.to_string request.worker_id ^ Attempt_id.to_string request.attempt_id)
        { request with delivered_at = Some now }) (List.filter (fun (r : Persistence.control_request) -> r.kind = Persistence.Stop_unknown) values);
      Ok (List.map (fun (request : Persistence.control_request) -> { request with delivered_at = Some now }) values));
    complete_control = (fun attempt_id ~completed_at -> match Hashtbl.find_opt store.controls attempt_id with
      | None -> Error (missing Persistence.Attempt (Attempt_id.to_string attempt_id))
      | Some request -> Hashtbl.replace store.controls attempt_id { request with completed_at = Some completed_at }; Ok ());
    find_control = (fun id -> Ok (Hashtbl.find_opt store.controls id));
    get_missing_since = (fun id -> Ok (Hashtbl.find_opt store.missing_since id));
    set_missing_since = (fun id at -> if Hashtbl.mem attempts id then
      (Hashtbl.replace store.missing_since id at; Ok ())
      else Error (missing Persistence.Attempt (Attempt_id.to_string id)));
    clear_missing_since = (fun id -> Hashtbl.remove store.missing_since id; Ok ());
    create_stop_unknown = (fun ~worker_id ~attempt_id ~requested_at ->
      let key = Worker_id.to_string worker_id ^ Attempt_id.to_string attempt_id in
      if Hashtbl.mem store.stop_requests key then Ok false else
        (Hashtbl.add store.stop_requests key { Persistence.attempt_id; worker_id;
          kind = Persistence.Stop_unknown; requested_at; delivered_at = None; completed_at = None }; Ok true));
    confirm_stop_unknown = (fun ~worker_id ~attempt_id ~completed_at ->
      let key = Worker_id.to_string worker_id ^ Attempt_id.to_string attempt_id in
      match Hashtbl.find_opt store.stop_requests key with
      | None -> Error (Persistence.Conflict "stop control does not belong to worker")
      | Some request -> Hashtbl.replace store.stop_requests key
          { request with delivered_at = Some (Option.value ~default:completed_at request.delivered_at);
            completed_at = Some completed_at }; Ok ());
  } in
  let log_key attempt_id sequence = Attempt_id.to_string attempt_id ^ ":" ^ string_of_int sequence in
  let logs : Persistence.log_repository = {
    append_log_batch = (fun ~attempt_id ~entries ~received_at:_ ->
      if not (Hashtbl.mem attempts attempt_id) then Error (missing Persistence.Attempt (Attempt_id.to_string attempt_id))
      else
        let rec append highest = function
          | [] -> Ok highest
          | entry :: rest ->
              let sequence = Log_entry.sequence_number entry |> Log_entry.sequence_value in
              if not (Attempt_id.equal attempt_id (Log_entry.attempt_id entry)) then
                Error (Persistence.Conflict "log entry attempt does not match request")
              else let key = log_key attempt_id sequence in
                match Hashtbl.find_opt store.logs key with
                | Some stored when Log_entry.equal stored entry -> append (max highest sequence) rest
                | Some _ -> Error (Persistence.Conflict "log sequence content conflicts")
                | None -> Hashtbl.add store.logs key entry; append (max highest sequence) rest in
        append 0 entries);
    list_logs = (fun ~attempt_id ~after_sequence ~limit ->
      if not (Hashtbl.mem attempts attempt_id) then Error (missing Persistence.Attempt (Attempt_id.to_string attempt_id))
      else Ok (all store.logs |> List.filter (fun entry ->
        Attempt_id.equal attempt_id (Log_entry.attempt_id entry)
        && Log_entry.(sequence_number entry |> sequence_value) > after_sequence)
        |> List.sort (fun a b -> Int.compare Log_entry.(sequence_number a |> sequence_value)
          Log_entry.(sequence_number b |> sequence_value)) |> take limit));
    highest_log_sequence = (fun attempt_id ->
      if not (Hashtbl.mem attempts attempt_id) then Error (missing Persistence.Attempt (Attempt_id.to_string attempt_id))
      else Ok (all store.logs |> List.filter (fun entry -> Attempt_id.equal attempt_id (Log_entry.attempt_id entry))
        |> List.fold_left (fun value entry -> max value Log_entry.(sequence_number entry |> sequence_value)) 0
        |> function 0 -> None | value -> Some value));
  } in
  let containers : Persistence.container_repository = {
    record_container_metadata = (fun value ->
      Hashtbl.replace store.containers value.attempt_id value; Ok value);
    find_container_metadata = (fun id -> Ok (Hashtbl.find_opt store.containers id));
    list_incomplete_container_cleanup = (fun ~limit -> Ok (all store.containers |> List.filter
      (fun value -> value.Persistence.cleanup_outcome <> Persistence.Removed) |> take limit));
  } in
  let metrics : Persistence.metrics_repository = {
    snapshot = (fun ~now:_ ~suspect_before ~offline_before ->
      let jobs_values = all jobs and worker_values = all workers
      and attempt_values = all attempts in
      let count_status status = List.fold_left (fun count job ->
        if Job_status.equal (Job.status job) status then count + 1 else count) 0 jobs_values in
      let healthy, suspect, offline = List.fold_left (fun (healthy, suspect, offline) worker ->
        let heartbeat = Worker.last_heartbeat worker in
        if Timestamp.compare heartbeat offline_before <= 0 then (healthy, suspect, offline + 1)
        else if Timestamp.compare heartbeat suspect_before <= 0 then (healthy, suspect + 1, offline)
        else (healthy + 1, suspect, offline)) (0, 0, 0) worker_values in
      let terminal_durations = List.filter_map (fun job ->
        match Job.status job with
        | Job_status.Completed | Job_status.Permanently_failed | Job_status.Cancelled ->
            Timestamp.diff_seconds ~later:(Job.updated_at job) ~earlier:(Job.created_at job)
        | _ -> None) jobs_values in
      let average = match terminal_durations with
        | [] -> 0.
        | values -> float_of_int (List.fold_left ( + ) 0 values) /. float_of_int (List.length values) in
      Ok { Persistence.pending_jobs = count_status Job_status.Pending;
        assigned_jobs = count_status Job_status.Assigned; running_jobs = count_status Job_status.Running;
        retry_waiting_jobs = count_status Job_status.Retry_waiting;
        cancelling_jobs = count_status Job_status.Cancelling;
        completed_jobs = count_status Job_status.Completed;
        permanently_failed_jobs = count_status Job_status.Permanently_failed;
        cancelled_jobs = count_status Job_status.Cancelled;
        healthy_workers = healthy; suspect_workers = suspect; offline_workers = offline;
        retry_count = List.fold_left (fun count job -> count + max 0 (Job.attempts_started job - 1)) 0 jobs_values;
        average_terminal_job_duration_seconds = average;
        active_attempts = List.fold_left (fun count attempt -> match Attempt.status attempt with
          | Attempt_status.Assigned | Attempt_status.Running -> count + 1 | _ -> count) 0 attempt_values;
        incomplete_container_cleanups = List.fold_left (fun count value ->
          if value.Persistence.cleanup_outcome = Persistence.Removed then count else count + 1)
          0 (all store.containers) });
  } in
  { Persistence.jobs = job_repository; attempts = attempt_repository;
    workers = worker_repository; events = event_repository; controls; logs; containers; metrics }

let create () =
  let store = Store.create () in
  let repository_set = repositories store in
  { Persistence.with_transaction = fun operation ->
      let saved = Store.snapshot store in
      match operation repository_set with
      | Ok _ as success -> Ok success
      | Error _ as failure -> Store.restore store saved; Ok failure
      | exception error -> Store.restore store saved; raise error }
