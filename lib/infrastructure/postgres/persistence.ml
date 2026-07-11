open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
module Port = Orchestraml_application.Ports.Persistence
module R = Caqti_request.Infix
module U = Yojson.Safe.Util

let storage error = Port.Storage_failure (Caqti_error.show error)
let decode decoder value = match decoder value with Ok value -> Ok value | Error error -> Error (Port.Storage_failure error)
let collect decoder values =
  let rec loop output = function [] -> Ok (List.rev output) | value :: rest ->
    match decode decoder value with Ok value -> loop (value :: output) rest | Error _ as error -> error in
  loop [] values
let job_insert = R.(Caqti_type.(t2 string (option string)) ->! Caqti_type.int) {|
WITH d AS (SELECT ?::jsonb AS j, ?::text AS payload),
ins AS (
  INSERT INTO jobs(id,name,status,execution_spec,snapshot,priority,cpu_millicores,memory_mib,
    timeout_seconds,max_attempts,retry_initial_delay_seconds,retry_multiplier,
    retry_maximum_delay_seconds,retry_timeouts,attempts_started,next_retry_at,
    idempotency_key,idempotency_payload,created_at,updated_at)
  SELECT (j->>'id')::uuid,j->>'name',j->>'status',j->'execution',j,
    (j->>'priority')::int,(j->>'cpu')::int,(j->>'memory')::int,(j->>'timeout')::int,
    (j->>'max_attempts')::int,(j->>'initial_delay')::int,(j->>'multiplier')::int,
    (j->>'maximum_delay')::int,(j->>'retry_timeouts')::boolean,(j->>'attempts_started')::int,
    (j->>'next_retry_at')::timestamptz,j->>'idempotency_key',payload,
    (j->>'created_at')::timestamptz,(j->>'updated_at')::timestamptz FROM d RETURNING id),
labels AS (INSERT INTO job_required_labels(job_id,label)
 SELECT ins.id, jsonb_array_elements_text(d.j->'labels') FROM ins CROSS JOIN d)
SELECT count(*)::int FROM ins|}
let job_update = R.(Caqti_type.string ->? Caqti_type.int) {|
UPDATE jobs SET name=j->>'name',status=j->>'status',execution_spec=j->'execution',snapshot=j,
 priority=(j->>'priority')::int,cpu_millicores=(j->>'cpu')::int,memory_mib=(j->>'memory')::int,
 timeout_seconds=(j->>'timeout')::int,max_attempts=(j->>'max_attempts')::int,
 retry_initial_delay_seconds=(j->>'initial_delay')::int,retry_multiplier=(j->>'multiplier')::int,
 retry_maximum_delay_seconds=(j->>'maximum_delay')::int,retry_timeouts=(j->>'retry_timeouts')::boolean,
 attempts_started=(j->>'attempts_started')::int,next_retry_at=(j->>'next_retry_at')::timestamptz,
 updated_at=(j->>'updated_at')::timestamptz
FROM (SELECT ?::jsonb AS j) d WHERE jobs.id=(j->>'id')::uuid RETURNING 1|}
let job_find = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT snapshot::text FROM jobs WHERE id=?::uuid"
let job_all = R.(Caqti_type.unit ->* Caqti_type.string)
  "SELECT snapshot::text FROM jobs ORDER BY created_at DESC,id DESC"
let job_page = R.(Caqti_type.(t4 (option string) (option string) (option string) int)
  ->* Caqti_type.string) {|
WITH p(status,before_at,before_id,lim) AS
  (SELECT ?::text,?::timestamptz,?::uuid,?::int)
SELECT jobs.snapshot::text FROM jobs,p
WHERE (p.status IS NULL OR jobs.status=p.status)
  AND (p.before_at IS NULL OR (jobs.created_at,jobs.id)<(p.before_at,p.before_id))
ORDER BY jobs.created_at DESC,jobs.id DESC LIMIT (SELECT lim FROM p)|}
let job_pending = R.(Caqti_type.unit ->* Caqti_type.string)
  "SELECT snapshot::text FROM jobs WHERE status='pending' ORDER BY priority DESC,created_at,id FOR UPDATE SKIP LOCKED"
let job_retry = R.(Caqti_type.string ->* Caqti_type.string)
  "SELECT snapshot::text FROM jobs WHERE status='retry_waiting' AND next_retry_at<=?::timestamptz ORDER BY next_retry_at FOR UPDATE SKIP LOCKED"
let job_idempotent_insert = R.(Caqti_type.(t2 string string) ->? Caqti_type.string) {|
WITH d AS (SELECT ?::jsonb AS j, ?::text AS payload),
ins AS (
 INSERT INTO jobs(id,name,status,execution_spec,snapshot,priority,cpu_millicores,memory_mib,
 timeout_seconds,max_attempts,retry_initial_delay_seconds,retry_multiplier,retry_maximum_delay_seconds,
 retry_timeouts,attempts_started,next_retry_at,idempotency_key,idempotency_payload,created_at,updated_at)
 SELECT (j->>'id')::uuid,j->>'name',j->>'status',j->'execution',j,(j->>'priority')::int,
 (j->>'cpu')::int,(j->>'memory')::int,(j->>'timeout')::int,(j->>'max_attempts')::int,
 (j->>'initial_delay')::int,(j->>'multiplier')::int,(j->>'maximum_delay')::int,
 (j->>'retry_timeouts')::boolean,(j->>'attempts_started')::int,(j->>'next_retry_at')::timestamptz,
 j->>'idempotency_key',payload,(j->>'created_at')::timestamptz,(j->>'updated_at')::timestamptz
 FROM d ON CONFLICT(idempotency_key) DO NOTHING RETURNING id),
labels AS (INSERT INTO job_required_labels(job_id,label)
 SELECT ins.id,jsonb_array_elements_text(d.j->'labels') FROM ins CROSS JOIN d RETURNING 1)
SELECT d.j::text FROM d JOIN ins ON true|}
let job_idempotent_find = R.(Caqti_type.string ->! Caqti_type.(t2 string string))
  "SELECT snapshot::text,idempotency_payload FROM jobs WHERE idempotency_key=?"

let worker_insert = R.(Caqti_type.string ->! Caqti_type.int) {|
WITH d AS (SELECT ?::jsonb AS j), ins AS (
 INSERT INTO workers(id,name,snapshot,max_concurrency,active_jobs,total_cpu_millicores,
 reserved_cpu_millicores,total_memory_mib,reserved_memory_mib,last_heartbeat)
 SELECT (j->>'id')::uuid,j->>'name',j,(j->>'max_concurrency')::int,(j->>'active_jobs')::int,
 (j->>'total_cpu')::int,(j->>'reserved_cpu')::int,(j->>'total_memory')::int,
 (j->>'reserved_memory')::int,(j->>'last_heartbeat')::timestamptz FROM d RETURNING id),
labels AS (INSERT INTO worker_labels(worker_id,label)
 SELECT ins.id,jsonb_array_elements_text(d.j->'labels') FROM ins CROSS JOIN d)
SELECT count(*)::int FROM ins|}
let worker_update = R.(Caqti_type.string ->? Caqti_type.int) {|
UPDATE workers SET name=j->>'name',snapshot=j,max_concurrency=(j->>'max_concurrency')::int,
 active_jobs=(j->>'active_jobs')::int,total_cpu_millicores=(j->>'total_cpu')::int,
 reserved_cpu_millicores=(j->>'reserved_cpu')::int,total_memory_mib=(j->>'total_memory')::int,
 reserved_memory_mib=(j->>'reserved_memory')::int,last_heartbeat=(j->>'last_heartbeat')::timestamptz
FROM (SELECT ?::jsonb AS j) d WHERE workers.id=(j->>'id')::uuid RETURNING 1|}
let worker_find = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT snapshot::text FROM workers WHERE id=?::uuid"
let worker_all = R.(Caqti_type.unit ->* Caqti_type.string)
  "SELECT snapshot::text FROM workers ORDER BY id FOR UPDATE SKIP LOCKED"

let attempt_insert = R.(Caqti_type.string ->. Caqti_type.unit) {|
INSERT INTO job_attempts(id,job_id,worker_id,snapshot,attempt_number,status,assigned_at,started_at,
 finished_at,outcome_kind,exit_code,failure_kind,failure_message,lost_reason)
SELECT (j->>'id')::uuid,(j->>'job_id')::uuid,(j->>'worker_id')::uuid,j,(j->>'number')::int,
 j->>'status',(j->>'assigned_at')::timestamptz,(j->>'started_at')::timestamptz,
 (j->>'finished_at')::timestamptz,j->'outcome'->>'type',(j->'outcome'->>'exit_code')::int,
 j->'outcome'->>'kind',j->'outcome'->>'message',j->'outcome'->>'reason' FROM (SELECT ?::jsonb AS j) d|}
let attempt_update = R.(Caqti_type.string ->? Caqti_type.int) {|
UPDATE job_attempts SET snapshot=j,status=j->>'status',started_at=(j->>'started_at')::timestamptz,
 finished_at=(j->>'finished_at')::timestamptz,outcome_kind=j->'outcome'->>'type',
 exit_code=(j->'outcome'->>'exit_code')::int,failure_kind=j->'outcome'->>'kind',
 failure_message=j->'outcome'->>'message',lost_reason=j->'outcome'->>'reason'
FROM (SELECT ?::jsonb AS j) d WHERE job_attempts.id=(j->>'id')::uuid RETURNING 1|}
let attempt_find = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT snapshot::text FROM job_attempts WHERE id=?::uuid"
let attempts_for_job = R.(Caqti_type.string ->* Caqti_type.string)
  "SELECT snapshot::text FROM job_attempts WHERE job_id=?::uuid ORDER BY attempt_number"

let event_json event =
  let entity_kind, entity_id = match event.Domain_event.entity with
    | Domain_event.Job id -> "job", Job_id.to_string id
    | Domain_event.Attempt id -> "attempt", Attempt_id.to_string id in
  `Assoc ["entity_kind",`String entity_kind;"entity_id",`String entity_id;
    "from_status",`String event.from_status;"to_status",`String event.to_status;
    "occurred_at",`String (Timestamp.to_rfc3339 event.occurred_at);
    "reason",(match event.reason with None -> `Null | Some value -> `String value)] |> Yojson.Safe.to_string ~std:true
let event_of_json value = try
  let json = Yojson.Safe.from_string value in
  let entity = match U.member "entity_kind" json |> U.to_string with
    | "job" -> Domain_event.Job (U.member "entity_id" json |> U.to_string |> Job_id.of_string |> Result.get_ok)
    | "attempt" -> Domain_event.Attempt (U.member "entity_id" json |> U.to_string |> Attempt_id.of_string |> Result.get_ok)
    | _ -> failwith "invalid event entity" in
  Ok (Domain_event.make ~entity ~from_status:(U.member "from_status" json |> U.to_string)
    ~to_status:(U.member "to_status" json |> U.to_string)
    ~occurred_at:(U.member "occurred_at" json |> U.to_string |> Timestamp.of_rfc3339 |> Result.get_ok)
    ?reason:(match U.member "reason" json with `Null -> None | v -> Some (U.to_string v)) ())
  with _ -> Error "invalid persisted transition event"
let event_insert = R.(Caqti_type.string ->. Caqti_type.unit) {|
WITH d AS (SELECT ?::jsonb AS j)
INSERT INTO transition_events(job_id,attempt_id,entity_kind,snapshot,from_status,to_status,occurred_at,reason)
SELECT CASE WHEN j->>'entity_kind'='job' THEN (j->>'entity_id')::uuid ELSE a.job_id END,
 CASE WHEN j->>'entity_kind'='attempt' THEN (j->>'entity_id')::uuid END,j->>'entity_kind',j,
 j->>'from_status',j->>'to_status',(j->>'occurred_at')::timestamptz,j->>'reason'
FROM d LEFT JOIN job_attempts a ON a.id=(j->>'entity_id')::uuid AND j->>'entity_kind'='attempt'|}
let event_all = R.(Caqti_type.unit ->* Caqti_type.string)
  "SELECT snapshot::text FROM transition_events ORDER BY id"
let event_job = R.(Caqti_type.string ->* Caqti_type.string)
  "SELECT snapshot::text FROM transition_events WHERE job_id=?::uuid ORDER BY id"
let event_attempt = R.(Caqti_type.string ->* Caqti_type.string)
  "SELECT snapshot::text FROM transition_events WHERE attempt_id=?::uuid ORDER BY id"

let repositories (module Db : Caqti_eio.CONNECTION) =
  let exec request value = match Db.exec request value with Ok () -> Ok () | Error error -> Error (storage error) in
  let find request decoder value = match Db.find_opt request value with
    | Ok None -> Ok None | Ok (Some raw) -> (match decode decoder raw with Ok v -> Ok (Some v) | Error _ as e -> e)
    | Error error -> Error (storage error) in
  let list request decoder value = match Db.collect_list request value with
    | Ok values -> collect decoder values | Error error -> Error (storage error) in
  let update request entity id value = match Db.find_opt request value with
    | Ok (Some _) -> Ok ()
    | Ok None -> Error (Port.Not_found (entity, id))
    | Error error -> Error (storage error) in
  let jobs : Port.job_repository = {
    create_job = (fun job -> match Db.find job_insert (Snapshot_codec.job_to_string job, None) with
      | Ok _ -> Ok () | Error error -> Error (storage error));
    create_job_idempotent = (fun job ~canonical_payload ->
      match Db.find_opt job_idempotent_insert (Snapshot_codec.job_to_string job, canonical_payload) with
      | Error error -> Error (storage error)
      | Ok (Some snapshot) ->
          (match Snapshot_codec.job_of_string snapshot with
           | Error error -> Error (Port.Storage_failure error)
           | Ok job -> Ok (Port.Idempotency_created job))
      | Ok None ->
          match Job.idempotency_key job with
          | None -> Error (Port.Storage_failure "idempotent job is missing its key")
          | Some key -> match Db.find job_idempotent_find (Idempotency_key.value key) with
              | Error error -> Error (storage error)
              | Ok (_, payload) when not (String.equal payload canonical_payload) ->
                  Ok Port.Idempotency_conflict
              | Ok (snapshot, _) -> match Snapshot_codec.job_of_string snapshot with
                  | Error error -> Error (Port.Storage_failure error)
                  | Ok job -> Ok (Port.Idempotency_replayed job));
    find_job = (fun id -> find job_find Snapshot_codec.job_of_string (Job_id.to_string id));
    update_job = (fun job -> update job_update Port.Job
      (Job_id.to_string (Job.id job)) (Snapshot_codec.job_to_string job));
    list_jobs = (fun () -> list job_all Snapshot_codec.job_of_string ());
    list_jobs_page = (fun ~status ~before ~limit ->
      let status = Option.map Job_status.to_string status in
      let before_at, before_id = match before with
        | None -> None, None
        | Some cursor -> Some (Timestamp.to_rfc3339 cursor.created_at),
            Some (Job_id.to_string cursor.job_id) in
      list job_page Snapshot_codec.job_of_string (status, before_at, before_id, limit));
    list_pending_jobs = (fun () -> list job_pending Snapshot_codec.job_of_string ());
    list_retry_ready_jobs = (fun ~now -> list job_retry Snapshot_codec.job_of_string (Timestamp.to_rfc3339 now));
  } in
  let attempts : Port.attempt_repository = {
    create_attempt = (fun value -> exec attempt_insert (Snapshot_codec.attempt_to_string value));
    find_attempt = (fun id -> find attempt_find Snapshot_codec.attempt_of_string (Attempt_id.to_string id));
    update_attempt = (fun value -> update attempt_update Port.Attempt
      (Attempt_id.to_string (Attempt.id value)) (Snapshot_codec.attempt_to_string value));
    list_attempts_for_job = (fun id -> list attempts_for_job Snapshot_codec.attempt_of_string (Job_id.to_string id));
  } in
  let workers : Port.worker_repository = {
    create_worker = (fun worker -> match Db.find worker_insert (Snapshot_codec.worker_to_string worker) with
      | Ok _ -> Ok () | Error error -> Error (storage error));
    find_worker = (fun id -> find worker_find Snapshot_codec.worker_of_string (Worker_id.to_string id));
    update_worker = (fun worker -> update worker_update Port.Worker
      (Worker_id.to_string (Worker.id worker)) (Snapshot_codec.worker_to_string worker));
    list_workers = (fun () -> list worker_all Snapshot_codec.worker_of_string ());
  } in
  let events : Port.event_repository = {
    append_event = (fun event -> exec event_insert (event_json event));
    list_events = (fun () -> list event_all event_of_json ());
    list_events_for_entity = (function
      | Domain_event.Job id -> list event_job event_of_json (Job_id.to_string id)
      | Domain_event.Attempt id -> list event_attempt event_of_json (Attempt_id.to_string id));
  } in
  { Port.jobs; attempts; workers; events }

let create pool =
  { Port.with_transaction = fun operation ->
      match Caqti_eio.Pool.use (fun ((module Db : Caqti_eio.CONNECTION) as connection) ->
        match Db.start () with
        | Error error -> Ok (`Database_error (storage error))
        | Ok () ->
            match operation (repositories connection) with
            | Ok value -> (match Db.commit () with
                | Ok () -> Ok (`Callback (Ok value))
                | Error error -> ignore (Db.rollback ()); Ok (`Database_error (storage error)))
            | Error error -> ignore (Db.rollback ()); Ok (`Callback (Error error))) pool with
      | Error error -> Error (storage error)
      | Ok (`Database_error error) -> Error error
      | Ok (`Callback result) -> Ok result }
