open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
type registration = { name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; total_resources : Resources.t }
type error = Persistence_error of Ports.Persistence.error | Invalid_worker of Validation_error.t
type registration_result = Registered of Worker.t | Updated of Worker.t
type heartbeat = { available_slots : int; active_attempt_ids : Identifiers.Attempt_id.t list }
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t; ids : Ports.Id_generator.t }
let create ~persistence ~clock ~ids = { persistence; clock; ids }
let transact service operation = match service.persistence.with_transaction operation with
  | Ok (Ok value) -> Ok value
  | Ok (Error error) | Error error -> Error (Persistence_error error)
let register service request =
  match Worker.create ~id:(service.ids.next_worker_id ()) ~name:request.name
    ~labels:request.labels ~max_concurrency:request.max_concurrency ~active_jobs:0
    ~total_resources:request.total_resources ~reserved_resources:Resources.zero
    ~last_heartbeat:(service.clock.now ()) with
  | Error error -> Error (Invalid_worker error)
  | Ok worker -> transact service (fun repositories ->
      match repositories.workers.create_worker worker with Ok () -> Ok worker | Error error -> Error error)
let register_with_id service id request =
  let result = service.persistence.with_transaction (fun repositories ->
    match repositories.workers.lock_worker id with
    | Error error -> Error error
    | Ok None -> (match Worker.create ~id ~name:request.name ~labels:request.labels
        ~max_concurrency:request.max_concurrency ~active_jobs:0
        ~total_resources:request.total_resources ~reserved_resources:Resources.zero
        ~last_heartbeat:(service.clock.now ()) with
        | Error error -> Ok (`Invalid error)
        | Ok worker -> match repositories.workers.upsert_worker worker with
            | Error error -> Error error
            | Ok true -> Ok (`Registered worker)
            | Ok false -> Ok (`Updated worker))
    | Ok (Some existing) -> match Worker.reconfigure ~name:request.name ~labels:request.labels
        ~max_concurrency:request.max_concurrency ~total_resources:request.total_resources existing with
        | Error error -> Ok (`Invalid error)
        | Ok configured -> match Worker.heartbeat ~now:(service.clock.now ()) configured with
            | Error error -> Ok (`Invalid error)
            | Ok worker -> match repositories.workers.upsert_worker worker with
                | Error error -> Error error | Ok _ -> Ok (`Updated worker)) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok (`Invalid error)) -> Error (Invalid_worker error)
  | Ok (Ok (`Registered worker)) -> Ok (Registered worker)
  | Ok (Ok (`Updated worker)) -> Ok (Updated worker)
let heartbeat service id report =
  let result = service.persistence.with_transaction (fun repositories ->
    match repositories.workers.lock_worker id with
    | Error error -> Error error
    | Ok None -> Error (Ports.Persistence.Not_found (Ports.Persistence.Worker, Identifiers.Worker_id.to_string id))
    | Ok (Some worker) ->
        let rec unique = function [] -> true | value :: rest ->
          not (List.exists (Identifiers.Attempt_id.equal value) rest) && unique rest in
        if report.available_slots < 0
          || report.available_slots > Scalar.Concurrency.value (Worker.max_concurrency worker) then
          Ok (`Invalid (Validation_error.make ~field:"available_slots" "must be within worker concurrency"))
        else if not (unique report.active_attempt_ids) then
          Ok (`Invalid (Validation_error.make ~field:"active_attempt_ids" "must not contain duplicates"))
        else match Worker.heartbeat ~now:(service.clock.now ()) worker with
        | Error error -> Ok (`Invalid error)
        | Ok updated -> match repositories.workers.update_worker updated with
            | Error error -> Error error
            | Ok () -> let stored : Ports.Persistence.heartbeat_report = {
                reported_at = Worker.last_heartbeat updated; available_slots = report.available_slots;
                active_attempt_ids = report.active_attempt_ids } in
                match repositories.workers.store_heartbeat id stored with
                | Error error -> Error error | Ok () -> Ok (`Worker updated)) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok (`Invalid error)) -> Error (Invalid_worker error)
  | Ok (Ok (`Worker worker)) -> Ok worker
let find service id = transact service (fun repositories -> repositories.workers.find_worker id)
let list service = transact service (fun repositories -> repositories.workers.list_workers ())
let poll_controls service worker_id ~limit = transact service (fun repositories ->
  match repositories.workers.find_worker worker_id with
  | Error error -> Error error
  | Ok None -> Error (Ports.Persistence.Not_found (Ports.Persistence.Worker, Worker_id.to_string worker_id))
  | Ok (Some _) -> repositories.controls.list_controls_for_worker worker_id
      ~now:(service.clock.now ()) ~limit:(max 1 limit))
let confirm_stop_unknown service worker_id attempt_id = transact service (fun repositories ->
  match repositories.workers.find_worker worker_id with
  | Error error -> Error error
  | Ok None -> Error (Ports.Persistence.Not_found (Ports.Persistence.Worker, Worker_id.to_string worker_id))
  | Ok (Some _) -> repositories.controls.confirm_stop_unknown ~worker_id ~attempt_id
      ~completed_at:(service.clock.now ()))
