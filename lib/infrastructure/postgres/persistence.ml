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
let job_retry_bounded = R.(Caqti_type.(t2 string int) ->* Caqti_type.string)
  "SELECT snapshot::text FROM jobs WHERE status='retry_waiting' AND next_retry_at<=?::timestamptz ORDER BY next_retry_at,id LIMIT ? FOR UPDATE SKIP LOCKED"
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
let worker_upsert = R.(Caqti_type.string ->! Caqti_type.bool) {|
WITH d AS (SELECT ?::jsonb AS j)
INSERT INTO workers(id,name,snapshot,max_concurrency,active_jobs,total_cpu_millicores,
 reserved_cpu_millicores,total_memory_mib,reserved_memory_mib,last_heartbeat)
SELECT (j->>'id')::uuid,j->>'name',j,(j->>'max_concurrency')::int,(j->>'active_jobs')::int,
 (j->>'total_cpu')::int,(j->>'reserved_cpu')::int,(j->>'total_memory')::int,
 (j->>'reserved_memory')::int,(j->>'last_heartbeat')::timestamptz FROM d
ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name,snapshot=EXCLUDED.snapshot,
 max_concurrency=EXCLUDED.max_concurrency,active_jobs=EXCLUDED.active_jobs,
 total_cpu_millicores=EXCLUDED.total_cpu_millicores,
 reserved_cpu_millicores=EXCLUDED.reserved_cpu_millicores,
 total_memory_mib=EXCLUDED.total_memory_mib,reserved_memory_mib=EXCLUDED.reserved_memory_mib,
 last_heartbeat=EXCLUDED.last_heartbeat
RETURNING (xmax = 0)|}
let worker_labels_delete = R.(Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM worker_labels WHERE worker_id=?::uuid"
let worker_label_insert = R.(Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "INSERT INTO worker_labels(worker_id,label) VALUES (?::uuid,?)"
let worker_find = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT snapshot::text FROM workers WHERE id=?::uuid"
let worker_lock = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT snapshot::text FROM workers WHERE id=?::uuid FOR UPDATE"
let worker_all = R.(Caqti_type.unit ->* Caqti_type.string)
  "SELECT snapshot::text FROM workers ORDER BY id FOR UPDATE SKIP LOCKED"
let heartbeat_upsert = R.(Caqti_type.(t4 string string int string) ->. Caqti_type.unit) {|
INSERT INTO worker_heartbeat_reports(worker_id,reported_at,available_slots,active_attempt_ids)
SELECT ?::uuid,?::timestamptz,?::int,
  COALESCE(ARRAY(SELECT jsonb_array_elements_text(?::jsonb)::uuid), '{}')
ON CONFLICT(worker_id) DO UPDATE SET reported_at=EXCLUDED.reported_at,
 available_slots=EXCLUDED.available_slots,active_attempt_ids=EXCLUDED.active_attempt_ids|}
let heartbeat_find = R.(Caqti_type.string ->? Caqti_type.(t3 string int string))
  "SELECT reported_at::text,available_slots,to_json(active_attempt_ids)::text FROM worker_heartbeat_reports WHERE worker_id=?::uuid"

let attempt_insert = R.(Caqti_type.string ->. Caqti_type.unit) {|
INSERT INTO job_attempts(id,job_id,worker_id,snapshot,attempt_number,status,assigned_at,acknowledged_at,started_at,
 finished_at,outcome_kind,exit_code,failure_kind,failure_message,lost_reason)
SELECT (j->>'id')::uuid,(j->>'job_id')::uuid,(j->>'worker_id')::uuid,j,(j->>'number')::int,
 j->>'status',(j->>'assigned_at')::timestamptz,(j->>'acknowledged_at')::timestamptz,(j->>'started_at')::timestamptz,
 (j->>'finished_at')::timestamptz,j->'outcome'->>'type',(j->'outcome'->>'exit_code')::int,
 j->'outcome'->>'kind',j->'outcome'->>'message',j->'outcome'->>'reason' FROM (SELECT ?::jsonb AS j) d|}
let attempt_update = R.(Caqti_type.string ->? Caqti_type.int) {|
UPDATE job_attempts SET snapshot=j,status=j->>'status',acknowledged_at=(j->>'acknowledged_at')::timestamptz,
 started_at=(j->>'started_at')::timestamptz,
 finished_at=(j->>'finished_at')::timestamptz,outcome_kind=j->'outcome'->>'type',
 exit_code=(j->'outcome'->>'exit_code')::int,failure_kind=j->'outcome'->>'kind',
 failure_message=j->'outcome'->>'message',lost_reason=j->'outcome'->>'reason'
FROM (SELECT ?::jsonb AS j) d WHERE job_attempts.id=(j->>'id')::uuid RETURNING 1|}
let attempt_find = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT snapshot::text FROM job_attempts WHERE id=?::uuid"
let attempts_for_job = R.(Caqti_type.string ->* Caqti_type.string)
  "SELECT snapshot::text FROM job_attempts WHERE job_id=?::uuid ORDER BY attempt_number"
let attempts_active_worker = R.(Caqti_type.string ->* Caqti_type.string)
  "SELECT snapshot::text FROM job_attempts WHERE worker_id=?::uuid AND status IN ('assigned','running') ORDER BY assigned_at FOR UPDATE SKIP LOCKED"
let attempts_expired_ack = R.(Caqti_type.(t2 string int) ->* Caqti_type.string)
  "SELECT snapshot::text FROM job_attempts WHERE status='assigned' AND acknowledged_at IS NULL AND assigned_at<=?::timestamptz ORDER BY assigned_at,id LIMIT ? FOR UPDATE SKIP LOCKED"
let attempts_overdue = R.(Caqti_type.(t3 int string int) ->* Caqti_type.string) {|SELECT a.snapshot::text
FROM job_attempts a JOIN jobs j ON j.id=a.job_id
WHERE a.status='running' AND a.started_at + make_interval(secs => j.timeout_seconds + ?) <= ?::timestamptz
ORDER BY a.started_at,a.id LIMIT ? FOR UPDATE OF a SKIP LOCKED|}
let attempt_claim = R.(Caqti_type.(t2 string string) ->? Caqti_type.string) {|WITH candidate AS (
 SELECT id FROM job_attempts WHERE worker_id=?::uuid AND status='assigned'
 AND acknowledged_at IS NULL AND assignment_polled_at IS NULL
 ORDER BY assigned_at,id LIMIT 1 FOR UPDATE SKIP LOCKED)
UPDATE job_attempts a SET assignment_polled_at=?::timestamptz FROM candidate c
WHERE a.id=c.id RETURNING a.snapshot::text|}
let workers_stale = R.(Caqti_type.(t2 string int) ->* Caqti_type.string)
  "SELECT snapshot::text FROM workers WHERE last_heartbeat<=?::timestamptz ORDER BY last_heartbeat,id LIMIT ? FOR UPDATE SKIP LOCKED"

let metrics_snapshot = R.(Caqti_type.(t2 string string) ->! Caqti_type.string) {|
WITH bounds AS (SELECT ?::timestamptz AS suspect_before, ?::timestamptz AS offline_before),
j AS (SELECT
  count(*) FILTER (WHERE status='pending')::int pending,
  count(*) FILTER (WHERE status='assigned')::int assigned,
  count(*) FILTER (WHERE status='running')::int running,
  count(*) FILTER (WHERE status='retry_waiting')::int retry_waiting,
  count(*) FILTER (WHERE status='cancelling')::int cancelling,
  count(*) FILTER (WHERE status='completed')::int completed,
  count(*) FILTER (WHERE status='permanently_failed')::int permanently_failed,
  count(*) FILTER (WHERE status='cancelled')::int cancelled,
  COALESCE(sum(GREATEST(attempts_started-1,0)),0)::int retries,
  COALESCE(avg(EXTRACT(EPOCH FROM (updated_at-created_at)))
    FILTER (WHERE status IN ('completed','permanently_failed','cancelled')),0)::float8 average_duration
  FROM jobs),
w AS (SELECT
  count(*) FILTER (WHERE last_heartbeat>b.suspect_before)::int healthy,
  count(*) FILTER (WHERE last_heartbeat<=b.suspect_before AND last_heartbeat>b.offline_before)::int suspect,
  count(*) FILTER (WHERE last_heartbeat<=b.offline_before)::int offline
  FROM workers CROSS JOIN bounds b),
a AS (SELECT count(*) FILTER (WHERE status IN ('assigned','running'))::int active FROM job_attempts),
c AS (SELECT count(*) FILTER (WHERE cleanup_outcome<>'removed')::int incomplete FROM container_execution_metadata)
SELECT json_build_object('pending',j.pending,'assigned',j.assigned,'running',j.running,
 'retry_waiting',j.retry_waiting,'cancelling',j.cancelling,'completed',j.completed,
 'permanently_failed',j.permanently_failed,'cancelled',j.cancelled,'healthy',w.healthy,
 'suspect',w.suspect,'offline',w.offline,'retries',j.retries,'average_duration',j.average_duration,
 'active_attempts',a.active,'incomplete_cleanups',c.incomplete)::text FROM j,w,a,c|}

let control_insert = R.(Caqti_type.(t4 string string string string) ->? Caqti_type.int) {|INSERT INTO attempt_control_requests(attempt_id,worker_id,kind,requested_at)
VALUES (?::uuid,?::uuid,?,?::timestamptz) ON CONFLICT(attempt_id) DO NOTHING RETURNING 1|}
let control_poll = R.(Caqti_type.(t3 string string int) ->* Caqti_type.(t6 string string string string (option string) (option string))) {|UPDATE attempt_control_requests SET delivered_at=COALESCE(delivered_at,?::timestamptz)
WHERE attempt_id IN (SELECT attempt_id FROM attempt_control_requests WHERE worker_id=?::uuid AND completed_at IS NULL ORDER BY requested_at LIMIT ? FOR UPDATE SKIP LOCKED)
RETURNING attempt_id::text,worker_id::text,kind,requested_at::text,delivered_at::text,completed_at::text|}
let control_find = R.(Caqti_type.string ->? Caqti_type.(t6 string string string string (option string) (option string)))
  "SELECT attempt_id::text,worker_id::text,kind,requested_at::text,delivered_at::text,completed_at::text FROM attempt_control_requests WHERE attempt_id=?::uuid"
let control_complete = R.(Caqti_type.(t2 string string) ->? Caqti_type.int) {|WITH p AS (SELECT ?::timestamptz AS at,?::uuid AS id)
UPDATE attempt_control_requests SET delivered_at=COALESCE(delivered_at,p.at),completed_at=p.at FROM p
WHERE attempt_id=p.id RETURNING 1|}
let recovery_find = R.(Caqti_type.string ->? Caqti_type.string)
  "SELECT missing_since_at::text FROM attempt_recovery_state WHERE attempt_id=?::uuid"
let recovery_set = R.(Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "INSERT INTO attempt_recovery_state(attempt_id,missing_since_at) VALUES (?::uuid,?::timestamptz) ON CONFLICT(attempt_id) DO UPDATE SET missing_since_at=LEAST(attempt_recovery_state.missing_since_at,EXCLUDED.missing_since_at)"
let recovery_clear = R.(Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM attempt_recovery_state WHERE attempt_id=?::uuid"
let stop_insert = R.(Caqti_type.(t3 string string string) ->? Caqti_type.int) {|INSERT INTO worker_stop_requests(worker_id,reported_attempt_id,requested_at)
VALUES (?::uuid,?::uuid,?::timestamptz) ON CONFLICT(worker_id,reported_attempt_id) DO NOTHING RETURNING 1|}
let stop_poll = R.(Caqti_type.(t3 string string int) ->* Caqti_type.(t6 string string string string (option string) (option string))) {|UPDATE worker_stop_requests SET delivered_at=COALESCE(delivered_at,?::timestamptz)
WHERE (worker_id,reported_attempt_id) IN (SELECT worker_id,reported_attempt_id FROM worker_stop_requests
 WHERE worker_id=?::uuid AND completed_at IS NULL ORDER BY requested_at,reported_attempt_id LIMIT ? FOR UPDATE SKIP LOCKED)
RETURNING reported_attempt_id::text,worker_id::text,'stop_unknown',requested_at::text,delivered_at::text,completed_at::text|}
let stop_confirm = R.(Caqti_type.(t3 string string string) ->? Caqti_type.int) {|WITH p AS (SELECT ?::timestamptz at,?::uuid worker,?::uuid attempt)
UPDATE worker_stop_requests SET delivered_at=COALESCE(delivered_at,p.at),completed_at=p.at FROM p
WHERE worker_id=p.worker AND reported_attempt_id=p.attempt RETURNING 1|}
let logs_append = R.(Caqti_type.(t3 string string string) ->! Caqti_type.int) {|WITH input AS (
 SELECT ?::uuid attempt_id,(x->>'sequence')::int sequence_number,x->>'stream' stream,
  (x->>'observed_at')::timestamptz observed_at,decode(x->>'payload','base64') payload,?::timestamptz received_at
 FROM jsonb_array_elements(?::jsonb) x), conflicts AS (
 SELECT 1 FROM input i JOIN attempt_logs l USING(attempt_id,sequence_number)
 WHERE l.stream<>i.stream OR l.observed_at<>i.observed_at OR l.payload<>i.payload), inserted AS (
 INSERT INTO attempt_logs(attempt_id,sequence_number,stream,observed_at,payload,received_at)
 SELECT attempt_id,sequence_number,stream,observed_at,payload,received_at FROM input
 WHERE NOT EXISTS(SELECT 1 FROM conflicts) ON CONFLICT DO NOTHING RETURNING sequence_number)
SELECT CASE WHEN EXISTS(SELECT 1 FROM conflicts) THEN -1 ELSE COALESCE((SELECT max(sequence_number) FROM input),0) END|}
let logs_list = R.(Caqti_type.(t3 string int int) ->* Caqti_type.string) {|SELECT jsonb_build_object(
 'attempt_id',attempt_id::text,'sequence',sequence_number,'stream',stream,
 'observed_at',observed_at::text,'payload',encode(payload,'base64'))::text
FROM attempt_logs WHERE attempt_id=?::uuid AND sequence_number>? ORDER BY sequence_number LIMIT ?|}
let logs_highest = R.(Caqti_type.string ->! Caqti_type.(option int))
  "SELECT max(sequence_number)::int FROM attempt_logs WHERE attempt_id=?::uuid"
let container_find = R.(Caqti_type.(t2 string string) ->! Caqti_type.(option string)) {|WITH locked AS MATERIALIZED (
 SELECT pg_advisory_xact_lock(hashtext(?)::bigint)) SELECT (SELECT jsonb_build_object(
 'attempt_id',attempt_id::text,'worker_id',worker_id::text,'container_id',container_id,'container_name',container_name,
 'image_reference',image_reference,'created_at',created_at::text,'started_at',started_at::text,
 'finished_at',finished_at::text,'removed_at',removed_at::text,'cleanup_outcome',cleanup_outcome)::text
FROM container_execution_metadata WHERE attempt_id=?::uuid) FROM locked|}
let container_record = R.(Caqti_type.string ->? Caqti_type.string) {|WITH j AS (SELECT ?::jsonb value), upserted AS (
INSERT INTO container_execution_metadata(attempt_id,worker_id,container_id,container_name,image_reference,created_at,
 started_at,finished_at,removed_at,cleanup_outcome)
SELECT (value->>'attempt_id')::uuid,(value->>'worker_id')::uuid,value->>'container_id',value->>'container_name',
 value->>'image_reference',(value->>'created_at')::timestamptz,(value->>'started_at')::timestamptz,
 (value->>'finished_at')::timestamptz,(value->>'removed_at')::timestamptz,value->>'cleanup_outcome' FROM j
ON CONFLICT(attempt_id) DO UPDATE SET
 started_at=COALESCE(container_execution_metadata.started_at,EXCLUDED.started_at),
 finished_at=COALESCE(container_execution_metadata.finished_at,EXCLUDED.finished_at),
 removed_at=COALESCE(container_execution_metadata.removed_at,EXCLUDED.removed_at),
 cleanup_outcome=EXCLUDED.cleanup_outcome
WHERE container_execution_metadata.attempt_id=EXCLUDED.attempt_id
 AND container_execution_metadata.worker_id=EXCLUDED.worker_id
 AND container_execution_metadata.container_id=EXCLUDED.container_id
 AND container_execution_metadata.container_name=EXCLUDED.container_name
 AND container_execution_metadata.image_reference=EXCLUDED.image_reference
 AND container_execution_metadata.created_at=EXCLUDED.created_at
 AND (container_execution_metadata.started_at IS NULL OR container_execution_metadata.started_at=EXCLUDED.started_at)
 AND (container_execution_metadata.finished_at IS NULL OR container_execution_metadata.finished_at=EXCLUDED.finished_at)
 AND (container_execution_metadata.removed_at IS NULL OR container_execution_metadata.removed_at=EXCLUDED.removed_at)
RETURNING *) SELECT jsonb_build_object(
 'attempt_id',attempt_id::text,'worker_id',worker_id::text,'container_id',container_id,'container_name',container_name,
 'image_reference',image_reference,'created_at',created_at::text,'started_at',started_at::text,
 'finished_at',finished_at::text,'removed_at',removed_at::text,'cleanup_outcome',cleanup_outcome)::text FROM upserted|}
let container_incomplete = R.(Caqti_type.int ->* Caqti_type.string) {|SELECT jsonb_build_object(
 'attempt_id',attempt_id::text,'worker_id',worker_id::text,'container_id',container_id,'container_name',container_name,
 'image_reference',image_reference,'created_at',created_at::text,'started_at',started_at::text,
 'finished_at',finished_at::text,'removed_at',removed_at::text,'cleanup_outcome',cleanup_outcome)::text
FROM container_execution_metadata WHERE cleanup_outcome<>'removed' ORDER BY created_at LIMIT ? FOR UPDATE SKIP LOCKED|}

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

let log_json entry = `Assoc [
  "sequence", `Int Log_entry.(sequence_number entry |> sequence_value);
  "stream", `String (Log_entry.stream entry |> Log_entry.stream_to_string);
  "observed_at", `String (Log_entry.observed_at entry |> Timestamp.to_rfc3339);
  "payload", `String (Base64.encode_exn (Log_entry.payload entry))]
let log_of_json value = try
  let json = Yojson.Safe.from_string value in
  let attempt_id = U.member "attempt_id" json |> U.to_string |> Attempt_id.of_string |> Result.get_ok in
  let sequence = U.member "sequence" json |> U.to_int |> Log_entry.sequence |> Result.get_ok in
  let stream = U.member "stream" json |> U.to_string |> Log_entry.stream_of_string |> Result.get_ok in
  let observed_at = U.member "observed_at" json |> U.to_string |> Timestamp.of_rfc3339 |> Result.get_ok in
  let payload = U.member "payload" json |> U.to_string |> Base64.decode_exn in
  Log_entry.create ~attempt_id ~sequence ~stream ~observed_at ~payload
  |> Result.map_error (fun _ -> "invalid persisted log entry")
  with _ -> Error "invalid persisted log entry"
let optional_timestamp json name = match U.member name json with `Null -> Ok None | value ->
  U.to_string value |> Timestamp.of_rfc3339 |> Result.map Option.some
let cleanup_to_string = function Port.Pending -> "pending" | Port.Removed -> "removed"
  | Port.Cleanup_failed -> "failed"
let cleanup_of_string = function "pending" -> Ok Port.Pending | "removed" -> Ok Port.Removed
  | "failed" -> Ok Port.Cleanup_failed | _ -> Error "invalid cleanup outcome"
let container_json (value : Port.container_metadata) = `Assoc [
  "attempt_id",`String (Attempt_id.to_string value.attempt_id);
  "worker_id",`String (Worker_id.to_string value.worker_id);
  "container_id",`String value.container_id; "container_name",`String value.container_name;
  "image_reference",`String value.image_reference; "created_at",`String (Timestamp.to_rfc3339 value.created_at);
  "started_at",(Option.fold ~none:`Null ~some:(fun x -> `String (Timestamp.to_rfc3339 x)) value.started_at);
  "finished_at",(Option.fold ~none:`Null ~some:(fun x -> `String (Timestamp.to_rfc3339 x)) value.finished_at);
  "removed_at",(Option.fold ~none:`Null ~some:(fun x -> `String (Timestamp.to_rfc3339 x)) value.removed_at);
  "cleanup_outcome",`String (cleanup_to_string value.cleanup_outcome)] |> Yojson.Safe.to_string ~std:true
let container_of_json value = try
  let json = Yojson.Safe.from_string value in
  match optional_timestamp json "started_at", optional_timestamp json "finished_at",
        optional_timestamp json "removed_at", cleanup_of_string (U.member "cleanup_outcome" json |> U.to_string) with
  | Ok started_at, Ok finished_at, Ok removed_at, Ok cleanup_outcome -> Ok ({
      Port.attempt_id = U.member "attempt_id" json |> U.to_string |> Attempt_id.of_string |> Result.get_ok;
      worker_id = U.member "worker_id" json |> U.to_string |> Worker_id.of_string |> Result.get_ok;
      container_id = U.member "container_id" json |> U.to_string;
      container_name = U.member "container_name" json |> U.to_string;
      image_reference = U.member "image_reference" json |> U.to_string;
      created_at = U.member "created_at" json |> U.to_string |> Timestamp.of_rfc3339 |> Result.get_ok;
      started_at; finished_at; removed_at; cleanup_outcome } : Port.container_metadata)
  | _ -> Error "invalid persisted container metadata"
  with _ -> Error "invalid persisted container metadata"

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
  let control_of_row (attempt_id, worker_id, kind, requested_at, delivered_at, completed_at) =
    match Attempt_id.of_string attempt_id, Worker_id.of_string worker_id,
      Timestamp.of_rfc3339 requested_at with
    | Ok attempt_id, Ok worker_id, Ok requested_at ->
        let timestamp = function None -> Ok None | Some value ->
          Result.map Option.some (Timestamp.of_rfc3339 value) in
        (match timestamp delivered_at, timestamp completed_at with
         | Ok delivered_at, Ok completed_at ->
             let kind = match kind with "cancel" -> Ok Port.Cancel
               | "execution_timeout" -> Ok Port.Execution_timeout
               | "stop_unknown" -> Ok Port.Stop_unknown
               | _ -> Error (Port.Storage_failure "invalid persisted control kind") in
             Result.map (fun kind -> ({ Port.attempt_id; worker_id; kind; requested_at;
               delivered_at; completed_at } : Port.control_request)) kind
         | _ -> Error (Port.Storage_failure "invalid persisted control timestamp"))
    | _ -> Error (Port.Storage_failure "invalid persisted control identity or timestamp") in
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
    list_retry_ready_jobs_bounded = (fun ~now ~limit -> list job_retry_bounded
      Snapshot_codec.job_of_string (Timestamp.to_rfc3339 now, limit));
  } in
  let attempts : Port.attempt_repository = {
    create_attempt = (fun value -> exec attempt_insert (Snapshot_codec.attempt_to_string value));
    find_attempt = (fun id -> find attempt_find Snapshot_codec.attempt_of_string (Attempt_id.to_string id));
    update_attempt = (fun value -> update attempt_update Port.Attempt
      (Attempt_id.to_string (Attempt.id value)) (Snapshot_codec.attempt_to_string value));
    list_attempts_for_job = (fun id -> list attempts_for_job Snapshot_codec.attempt_of_string (Job_id.to_string id));
    list_active_attempts_for_worker = (fun id -> list attempts_active_worker Snapshot_codec.attempt_of_string (Worker_id.to_string id));
    list_expired_unacknowledged = (fun ~before ~limit -> list attempts_expired_ack Snapshot_codec.attempt_of_string (Timestamp.to_rfc3339 before, limit));
    list_overdue_running = (fun ~now ~grace_seconds ~limit -> list attempts_overdue Snapshot_codec.attempt_of_string (grace_seconds, Timestamp.to_rfc3339 now, limit));
    claim_assigned_attempt = (fun worker_id ~polled_at -> find attempt_claim Snapshot_codec.attempt_of_string
      (Worker_id.to_string worker_id, Timestamp.to_rfc3339 polled_at));
  } in
  let workers : Port.worker_repository = {
    create_worker = (fun worker -> match Db.find worker_insert (Snapshot_codec.worker_to_string worker) with
      | Ok _ -> Ok () | Error error -> Error (storage error));
    upsert_worker = (fun worker ->
      let id = Worker.id worker |> Worker_id.to_string in
      match Db.find worker_upsert (Snapshot_codec.worker_to_string worker) with
      | Error error -> Error (storage error)
      | Ok created -> match Db.exec worker_labels_delete id with
          | Error error -> Error (storage error)
          | Ok () ->
              let rec insert = function
                | [] -> Ok created
                | label :: rest -> match Db.exec worker_label_insert (id, Worker_label.value label) with
                    | Ok () -> insert rest | Error error -> Error (storage error) in
              insert (Worker.labels worker |> Worker_label.Set.elements));
    find_worker = (fun id -> find worker_find Snapshot_codec.worker_of_string (Worker_id.to_string id));
    lock_worker = (fun id -> find worker_lock Snapshot_codec.worker_of_string (Worker_id.to_string id));
    update_worker = (fun worker -> update worker_update Port.Worker
      (Worker_id.to_string (Worker.id worker)) (Snapshot_codec.worker_to_string worker));
    list_workers = (fun () -> list worker_all Snapshot_codec.worker_of_string ());
    store_heartbeat = (fun id report ->
      let attempts = `List (List.map (fun attempt -> `String (Attempt_id.to_string attempt))
        report.Port.active_attempt_ids) |> Yojson.Safe.to_string in
      exec heartbeat_upsert (Worker_id.to_string id, Timestamp.to_rfc3339 report.reported_at,
        report.available_slots, attempts));
    find_heartbeat = (fun id -> match Db.find_opt heartbeat_find (Worker_id.to_string id) with
      | Error error -> Error (storage error) | Ok None -> Ok None
      | Ok (Some (reported_at, available_slots, attempts)) ->
          (try
             let active_attempt_ids = Yojson.Safe.from_string attempts |> U.to_list
               |> List.map (fun value -> U.to_string value |> Attempt_id.of_string |> Result.get_ok) in
             let report : Port.heartbeat_report = {
               reported_at = Timestamp.of_rfc3339 reported_at |> Result.get_ok;
               available_slots; active_attempt_ids } in Ok (Some report)
           with _ -> Error (Port.Storage_failure "invalid persisted heartbeat report")));
    list_stale_workers = (fun ~before ~limit -> list workers_stale Snapshot_codec.worker_of_string
      (Timestamp.to_rfc3339 before, limit));
  } in
  let events : Port.event_repository = {
    append_event = (fun event -> exec event_insert (event_json event));
    list_events = (fun () -> list event_all event_of_json ());
    list_events_for_entity = (function
      | Domain_event.Job id -> list event_job event_of_json (Job_id.to_string id)
      | Domain_event.Attempt id -> list event_attempt event_of_json (Attempt_id.to_string id));
  } in
  let controls : Port.control_repository = {
    create_control = (fun request ->
      let kind = match request.Port.kind with Port.Cancel -> "cancel"
        | Port.Execution_timeout -> "execution_timeout" | Port.Stop_unknown -> "stop_unknown" in
      match Db.find_opt control_insert (Attempt_id.to_string request.attempt_id,
        Worker_id.to_string request.worker_id, kind, Timestamp.to_rfc3339 request.requested_at) with
      | Ok (Some _) -> Ok true | Ok None -> Ok false | Error error -> Error (storage error));
    list_controls_for_worker = (fun worker_id ~now ~limit ->
      match Db.collect_list control_poll (Timestamp.to_rfc3339 now, Worker_id.to_string worker_id, limit) with
      | Error error -> Error (storage error) | Ok known_rows ->
          (match Db.collect_list stop_poll (Timestamp.to_rfc3339 now, Worker_id.to_string worker_id, limit) with
           | Error error -> Error (storage error) | Ok stop_rows ->
          let rows = known_rows @ stop_rows in
          let rec take count = function [] -> [] | _ when count <= 0 -> []
            | x :: xs -> x :: take (count - 1) xs in
          let rec decode_rows values = function
            | [] -> Ok (List.rev values |> List.sort (fun (a : Port.control_request) b ->
                let by_time = Timestamp.compare a.requested_at b.requested_at in
                if by_time <> 0 then by_time else Attempt_id.compare a.attempt_id b.attempt_id)
                |> take limit)
            | row :: rest -> (match control_of_row row with
                | Error _ as error -> error | Ok value -> decode_rows (value :: values) rest) in
          decode_rows [] rows));
    complete_control = (fun attempt_id ~completed_at -> update control_complete Port.Attempt
      (Attempt_id.to_string attempt_id) (Timestamp.to_rfc3339 completed_at, Attempt_id.to_string attempt_id));
    find_control = (fun id -> match Db.find_opt control_find (Attempt_id.to_string id) with
      | Error error -> Error (storage error) | Ok None -> Ok None
      | Ok (Some row) -> Result.map Option.some (control_of_row row));
    get_missing_since = (fun id -> match Db.find_opt recovery_find (Attempt_id.to_string id) with
      | Error error -> Error (storage error) | Ok None -> Ok None
      | Ok (Some value) -> (match Timestamp.of_rfc3339 value with Ok at -> Ok (Some at)
          | Error _ -> Error (Port.Storage_failure "invalid recovery timestamp")));
    set_missing_since = (fun id at -> exec recovery_set (Attempt_id.to_string id, Timestamp.to_rfc3339 at));
    clear_missing_since = (fun id -> exec recovery_clear (Attempt_id.to_string id));
    create_stop_unknown = (fun ~worker_id ~attempt_id ~requested_at ->
      match Db.find_opt stop_insert (Worker_id.to_string worker_id, Attempt_id.to_string attempt_id,
        Timestamp.to_rfc3339 requested_at) with
      | Ok (Some _) -> Ok true | Ok None -> Ok false | Error error -> Error (storage error));
    confirm_stop_unknown = (fun ~worker_id ~attempt_id ~completed_at ->
      match Db.find_opt stop_confirm (Timestamp.to_rfc3339 completed_at,
        Worker_id.to_string worker_id, Attempt_id.to_string attempt_id) with
      | Ok (Some _) -> Ok () | Ok None -> Error (Port.Conflict "stop control does not belong to worker")
      | Error error -> Error (storage error));
  } in
  let logs : Port.log_repository = {
    append_log_batch = (fun ~attempt_id ~entries ~received_at ->
      let json = `List (List.map log_json entries) |> Yojson.Safe.to_string ~std:true in
      match Db.find logs_append (Attempt_id.to_string attempt_id, Timestamp.to_rfc3339 received_at, json) with
      | Ok value when value >= 0 -> Ok value
      | Ok _ -> Error (Port.Conflict "log sequence content conflicts")
      | Error error -> Error (storage error));
    list_logs = (fun ~attempt_id ~after_sequence ~limit -> list logs_list log_of_json
      (Attempt_id.to_string attempt_id, after_sequence, limit));
    highest_log_sequence = (fun id -> match Db.find logs_highest (Attempt_id.to_string id) with
      | Ok value -> Ok value | Error error -> Error (storage error));
  } in
  let containers : Port.container_repository = {
    record_container_metadata = (fun value -> match Db.find_opt container_record (container_json value) with
      | Ok (Some stored) -> container_of_json stored |> Result.map_error (fun message -> Port.Storage_failure message)
      | Ok None -> Error (Port.Conflict "container metadata conflicts with stored lifecycle")
      | Error error -> Error (storage error));
    find_container_metadata = (fun id -> let value=Attempt_id.to_string id in
      match Db.find container_find (value,value) with
      |Error error->Error(storage error)|Ok None->Ok None|Ok(Some json)->
        container_of_json json|>Result.map Option.some|>Result.map_error(fun message->Port.Storage_failure message));
    list_incomplete_container_cleanup = (fun ~limit -> list container_incomplete container_of_json limit);
  } in
  let metrics : Port.metrics_repository = {
    snapshot = (fun ~now:_ ~suspect_before ~offline_before ->
      match Db.find metrics_snapshot
        (Timestamp.to_rfc3339 suspect_before, Timestamp.to_rfc3339 offline_before) with
      | Error error -> Error (storage error)
      | Ok encoded ->
          (try
             let json = Yojson.Safe.from_string encoded in
             let int name = U.member name json |> U.to_int in
             let float name = match U.member name json with
               | `Int value -> float_of_int value | value -> U.to_float value in
             Ok { Port.pending_jobs = int "pending"; assigned_jobs = int "assigned";
               running_jobs = int "running"; retry_waiting_jobs = int "retry_waiting";
               cancelling_jobs = int "cancelling"; completed_jobs = int "completed";
               permanently_failed_jobs = int "permanently_failed"; cancelled_jobs = int "cancelled";
               healthy_workers = int "healthy"; suspect_workers = int "suspect";
               offline_workers = int "offline"; retry_count = int "retries";
               average_terminal_job_duration_seconds = float "average_duration";
               active_attempts = int "active_attempts";
               incomplete_container_cleanups = int "incomplete_cleanups" }
           with Yojson.Json_error message | Yojson.Safe.Util.Type_error (message, _) ->
             Error (Port.Storage_failure ("invalid metrics snapshot: " ^ message))));
  } in
  { Port.jobs; attempts; workers; events; controls; logs; containers; metrics }

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
