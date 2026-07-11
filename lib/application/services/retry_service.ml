open Orchestraml_domain
open Shared
open Core
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t }
let create ~persistence ~clock = { persistence; clock }
let run_once service =
  let now = service.clock.now () in
  let result = service.persistence.with_transaction (fun repositories ->
    match repositories.jobs.list_retry_ready_jobs ~now with
    | Error error -> Error error
    | Ok jobs ->
        let rec release count = function
          | [] -> Ok (`Released count)
          | job :: rest -> match Job.release_retry ~now job with
              | Error error -> Ok (`Transition error)
              | Ok (pending, event) -> match repositories.jobs.update_job pending with
                  | Error error -> Error error
                  | Ok () -> match repositories.events.append_event event with
                      | Error error -> Error error | Ok () -> release (count + 1) rest in
        release 0 jobs) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok (`Transition error)) -> Error (Transition_rejected error)
  | Ok (Ok (`Released count)) -> Ok count
