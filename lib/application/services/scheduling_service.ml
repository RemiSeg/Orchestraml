open Orchestraml_domain
open Foundation
open Shared
open Core
type assignment = { job : Job.t; attempt : Attempt.t; worker : Worker.t }
type outcome = Assigned of assignment | No_assignment
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t | Capacity_rejected of Worker.capacity_error
  | Invalid_attempt_number
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t;
  ids : Ports.Id_generator.t; health_policy : Worker_health.policy }
let create ~persistence ~clock ~ids ~health_policy = { persistence; clock; ids; health_policy }
let run_once service =
  let result = service.persistence.with_transaction (fun repositories ->
    match repositories.jobs.list_pending_jobs (), repositories.workers.list_workers () with
    | Error error, _ | _, Error error -> Error error
    | Ok jobs, Ok workers -> match Scheduler_policy.select_job jobs with
        | None -> Ok (`Outcome No_assignment)
        | Some job ->
            let now = service.clock.now () in
            match Scheduler_policy.select_worker ~health_policy:service.health_policy ~now ~job workers with
            | None -> Ok (`Outcome No_assignment)
            | Some worker -> match Worker.reserve ~requirements:(Job.requirements job) worker with
                | Error error -> Ok (`Capacity error)
                | Ok reserved_worker -> match Job.assign ~now job with
                    | Error error -> Ok (`Transition error)
                    | Ok (assigned_job, event) ->
                        match Scalar.Attempt_number.create (Job.attempts_started assigned_job) with
                        | Error _ -> Ok `Attempt_number
                        | Ok number ->
                            let attempt = Attempt.create ~id:(service.ids.next_attempt_id ())
                              ~job_id:(Job.id assigned_job) ~number
                              ~worker_id:(Worker.id reserved_worker) ~assigned_at:now in
                            match repositories.jobs.update_job assigned_job with
                            | Error error -> Error error
                            | Ok () -> match repositories.attempts.create_attempt attempt with
                                | Error error -> Error error
                                | Ok () -> match repositories.workers.update_worker reserved_worker with
                                    | Error error -> Error error
                                    | Ok () -> match repositories.events.append_event event with
                                        | Error error -> Error error
                                        | Ok () -> Ok (`Outcome (Assigned {
                                            job = assigned_job; attempt; worker = reserved_worker }))) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok (`Outcome outcome)) -> Ok outcome
  | Ok (Ok (`Capacity error)) -> Error (Capacity_rejected error)
  | Ok (Ok (`Transition error)) -> Error (Transition_rejected error)
  | Ok (Ok `Attempt_number) -> Error Invalid_attempt_number
