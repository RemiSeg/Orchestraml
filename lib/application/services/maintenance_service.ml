open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core

type error = Persistence_error of Ports.Persistence.error
  | Execution_error of Execution_service.error | Invalid_time | Reconciliation_did_not_converge
type summary = { retries_released : int; assignments_recovered : int;
  deadlines_requested : int; workers_recovered : int; heartbeats_reconciled : int }
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t;
  health_policy : Worker_health.policy; acknowledgement_timeout : Scalar.Timeout_seconds.t;
  execution_report_grace : Scalar.Timeout_seconds.t; recovery_grace : Scalar.Timeout_seconds.t;
  batch_size : int; max_reconciliation_passes : int; execution : Execution_service.t }

let create ~max_reconciliation_passes ~persistence ~clock ~health_policy ~acknowledgement_timeout
    ~execution_report_grace ~recovery_grace ~batch_size =
  { persistence; clock; health_policy; acknowledgement_timeout; execution_report_grace;
    recovery_grace; batch_size = max 1 batch_size;
    max_reconciliation_passes = max 1 max_reconciliation_passes;
    execution = Execution_service.create ~persistence ~clock }
let before now seconds = Timestamp.add_seconds now (-seconds)
let recover service attempt ~reason failure =
  match Execution_service.recover_lost service.execution (Attempt.id attempt) ~reason ~failure with
  | Ok _ -> Ok () | Error error -> Error (Execution_error error)
let rec recover_all service ~reason failure count = function
  | [] -> Ok count
  | attempt :: rest -> match recover service attempt ~reason (failure ()) with
      | Ok () -> recover_all service ~reason failure (count + 1) rest
      | Error (Execution_error (Execution_service.Invalid_operation _)) ->
          recover_all service ~reason failure count rest
      | Error _ as error -> error

let run_assignment_timeout_cycle service =
  let now = service.clock.now () in
  match before now (Scalar.Timeout_seconds.value service.acknowledgement_timeout) with
  | None -> Error Invalid_time
  | Some cutoff ->
      (match service.persistence.with_transaction (fun r ->
         r.attempts.list_expired_unacknowledged ~before:cutoff ~limit:service.batch_size) with
       | Error error | Ok (Error error) -> Error (Persistence_error error)
       | Ok (Ok attempts) -> recover_all service ~reason:"assignment acknowledgement timed out"
           (fun () -> Failure.create Failure.Assignment_timeout) 0 attempts)

let run_execution_deadline_cycle service =
  let now = service.clock.now () in
  let grace = Scalar.Timeout_seconds.value service.execution_report_grace in
  match service.persistence.with_transaction (fun r ->
    match r.attempts.list_overdue_running ~now ~grace_seconds:grace ~limit:service.batch_size with
    | Error error -> Error error | Ok attempts ->
        let rec add count = function
          | [] -> Ok count
          | attempt :: rest ->
              let request : Ports.Persistence.control_request = {
                attempt_id = Attempt.id attempt; worker_id = Attempt.worker_id attempt;
                kind = Ports.Persistence.Execution_timeout; requested_at = now;
                delivered_at = None; completed_at = None } in
              match r.controls.create_control request with
              | Error error -> Error error | Ok created -> add (if created then count + 1 else count) rest in
        add 0 attempts) with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok count) -> Ok count

let run_worker_recovery_cycle service =
  let now = service.clock.now () in
  let offline_seconds = Worker_health.offline_after service.health_policy
    |> Scalar.Timeout_seconds.value in
  match before now offline_seconds with None -> Error Invalid_time | Some cutoff ->
  match service.persistence.with_transaction (fun r ->
    r.workers.list_stale_workers ~before:cutoff ~limit:service.batch_size) with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok workers) ->
      let offline = workers in
      let rec loop total = function
        | [] -> Ok total
        | worker :: rest ->
            (match service.persistence.with_transaction (fun r ->
               r.attempts.list_active_attempts_for_worker (Worker.id worker)) with
             | Error error | Ok (Error error) -> Error (Persistence_error error)
             | Ok (Ok attempts) -> match recover_all service ~reason:"worker heartbeat expired"
                 (fun () -> Failure.create Failure.Worker_lost) 0 attempts with
                 | Error _ as error -> error | Ok count -> loop (total + count) rest) in
      loop 0 offline

let run_heartbeat_reconciliation_cycle service =
  let now = service.clock.now () in
  match service.persistence.with_transaction (fun r -> r.workers.list_workers ()) with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok workers) ->
      let grace = Scalar.Timeout_seconds.value service.recovery_grace in
      let rec workers_loop count = function
        | [] -> Ok count
        | worker :: rest ->
            if not (Worker_health.equal (Worker_health.classify service.health_policy ~now
              ~last_heartbeat:(Worker.last_heartbeat worker)) Worker_health.Healthy)
            then workers_loop count rest
            else match service.persistence.with_transaction (fun r ->
              match r.workers.find_heartbeat (Worker.id worker),
                    r.attempts.list_active_attempts_for_worker (Worker.id worker) with
              | Error e, _ | _, Error e -> Error e
              | Ok None, _ -> Ok ([], 0)
              | Ok (Some heartbeat), Ok attempts ->
                  let known = List.map Attempt.id attempts in
                  let unknown = List.filter (fun id -> not (List.exists (Attempt_id.equal id) known))
                    heartbeat.active_attempt_ids in
                  let rec add_unknown count = function
                    | [] -> Ok count
                    | id :: tail -> (match r.controls.create_stop_unknown ~worker_id:(Worker.id worker)
                        ~attempt_id:id ~requested_at:now with
                      | Error e -> Error e | Ok created -> add_unknown (count + if created then 1 else 0) tail) in
                  let rec inspect due = function
                    | [] -> (match add_unknown 0 unknown with Ok created -> Ok (due, created) | Error e -> Error e)
                    | attempt :: tail ->
                        let present = List.exists (Attempt_id.equal (Attempt.id attempt)) heartbeat.active_attempt_ids in
                        if present then (match r.controls.clear_missing_since (Attempt.id attempt) with
                          | Error e -> Error e | Ok () -> inspect due tail)
                        else match r.controls.get_missing_since (Attempt.id attempt) with
                          | Error e -> Error e
                          | Ok None -> (match r.controls.set_missing_since (Attempt.id attempt) now with
                              | Error e -> Error e | Ok () -> inspect due tail)
                          | Ok (Some since) -> match Timestamp.add_seconds since grace with
                              | Some deadline when Timestamp.compare deadline now <= 0 -> inspect (attempt :: due) tail
                              | _ -> inspect due tail in
                  inspect [] attempts) with
              | Error error | Ok (Error error) -> Error (Persistence_error error)
              | Ok (Ok (due, created)) -> match recover_all service ~reason:"attempt missing from worker heartbeat"
                  (fun () -> Failure.create Failure.Worker_lost) 0 due with
                  | Error _ as error -> error | Ok recovered -> workers_loop (count + recovered + created) rest in
      workers_loop 0 workers

let reconcile_startup service =
  let retry = Retry_service.create ~persistence:service.persistence ~clock:service.clock in
  let rec pass number total =
  if number > service.max_reconciliation_passes then Error Reconciliation_did_not_converge else
  match Retry_service.run_once retry with Error error -> Error (Execution_error
      (Execution_service.Invalid_operation (match error with Retry_service.Persistence_error _ -> "retry reconciliation failed" | Retry_service.Transition_rejected _ -> "retry transition rejected")))
  | Ok retries_released ->
      match run_assignment_timeout_cycle service with Error _ as e -> e | Ok assignments_recovered ->
      match run_execution_deadline_cycle service with Error _ as e -> e | Ok deadlines_requested ->
      match run_worker_recovery_cycle service with Error _ as e -> e | Ok workers_recovered ->
      match run_heartbeat_reconciliation_cycle service with Error _ as e -> e | Ok heartbeats_reconciled ->
      let current = retries_released + assignments_recovered + deadlines_requested
        + workers_recovered + heartbeats_reconciled in
      let total = { retries_released = total.retries_released + retries_released;
        assignments_recovered = total.assignments_recovered + assignments_recovered;
        deadlines_requested = total.deadlines_requested + deadlines_requested;
        workers_recovered = total.workers_recovered + workers_recovered;
        heartbeats_reconciled = total.heartbeats_reconciled + heartbeats_reconciled } in
      if current = 0 then Ok total else pass (number + 1) total in
  pass 1 { retries_released=0; assignments_recovered=0; deadlines_requested=0;
    workers_recovered=0; heartbeats_reconciled=0 }
