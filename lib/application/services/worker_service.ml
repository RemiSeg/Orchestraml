open Orchestraml_domain
open Foundation
open Shared
open Core
type registration = { name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; total_resources : Resources.t }
type error = Persistence_error of Ports.Persistence.error | Invalid_worker of Validation_error.t
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
let find service id = transact service (fun repositories -> repositories.workers.find_worker id)
let list service = transact service (fun repositories -> repositories.workers.list_workers ())
