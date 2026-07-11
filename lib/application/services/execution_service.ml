open Orchestraml_domain
open Identifiers
open Shared
open Core
type completed = { job : Job.t; attempt : Attempt.t; worker : Worker.t }
type error = Persistence_error of Ports.Persistence.error
  | Transition_rejected of Transition_error.t | Capacity_rejected of Worker.capacity_error
  | Entity_mismatch | Invalid_operation of string
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t }
type reported = Success of int | Failure of Failure.t | Timeout | Lost of string | Cancelled
let create ~persistence ~clock = { persistence; clock }
let missing entity id = Ports.Persistence.Not_found (entity, id)
let append_events repository events =
  let rec loop = function
    | [] -> Ok ()
    | event :: rest -> match repository.Ports.Persistence.append_event event with
        | Error error -> Error error | Ok () -> loop rest in
  loop events
let start_attempt service attempt_id =
  let result = service.persistence.with_transaction (fun repositories ->
    match repositories.attempts.find_attempt attempt_id with
    | Error error -> Error error
    | Ok None -> Error (missing Ports.Persistence.Attempt (Attempt_id.to_string attempt_id))
    | Ok (Some attempt) -> match repositories.jobs.find_job (Attempt.job_id attempt) with
        | Error error -> Error error
        | Ok None -> Error (missing Ports.Persistence.Job (Job_id.to_string (Attempt.job_id attempt)))
        | Ok (Some job) ->
            if not (Job_id.equal (Job.id job) (Attempt.job_id attempt)) then Ok (`Mismatch)
            else let now = service.clock.now () in
              match Attempt.start ~now attempt with
              | Error error -> Ok (`Transition error)
              | Ok (running_attempt, attempt_event) -> match Job.start ~now job with
                  | Error error -> Ok (`Transition error)
                  | Ok (running_job, job_event) ->
                      match repositories.attempts.update_attempt running_attempt with
                      | Error error -> Error error
                      | Ok () -> match repositories.jobs.update_job running_job with
                          | Error error -> Error error
                          | Ok () -> match append_events repositories.events [attempt_event; job_event] with
                              | Error error -> Error error
                              | Ok () -> Ok (`Started (running_job, running_attempt))) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok `Mismatch) -> Error Entity_mismatch
  | Ok (Ok (`Transition error)) -> Error (Transition_rejected error)
  | Ok (Ok (`Started values)) -> Ok values

let transition_attempt ~now reported attempt = match reported with
  | Success exit_code -> Attempt.succeed ~now ~exit_code attempt
  | Failure failure -> Attempt.fail ~now ~failure attempt
  | Timeout -> Attempt.time_out ~now attempt
  | Lost reason -> Attempt.lose ~now ~reason attempt
  | Cancelled -> Attempt.cancel ~now attempt

let failure_for_report = function
  | Failure failure -> Some failure
  | Timeout -> Some (Failure.create Failure.Execution_timeout)
  | Lost reason -> Some (Failure.create ~message:reason Failure.Worker_lost)
  | Success _ | Cancelled -> None

let transition_job ~now reported job = match reported with
  | Success _ -> (match Job.complete ~now job with
      | Ok (job, event) -> Ok (job, [event]) | Error error -> Error error)
  | Cancelled ->
      (match Job.request_cancel ~now job with
       | Error error -> Error error
       | Ok (cancelling, request_event) ->
           match Job.confirm_cancel ~now cancelling with
           | Error error -> Error error
           | Ok (cancelled, confirm_event) -> Ok (cancelled, [request_event; confirm_event]))
  | (Failure _ | Timeout | Lost _) as outcome ->
      let failure = Option.get (failure_for_report outcome) in
      match Retry_policy.decide (Job.retry_policy job) ~failure
        ~attempts_started:(Job.attempts_started job) ~now with
      | Retry_policy.Retry_at retry_at ->
          (match Job.schedule_retry ~now ~retry_at ~reason:(Failure.kind_to_string (Failure.kind failure)) job with
           | Ok (job, event) -> Ok (job, [event]) | Error error -> Error error)
      | Retry_policy.Do_not_retry _ ->
          (match Job.permanently_fail ~now ~reason:(Failure.kind_to_string (Failure.kind failure)) job with
           | Ok (job, event) -> Ok (job, [event]) | Error error -> Error error)

let report service attempt_id reported =
  let result = service.persistence.with_transaction (fun repositories ->
    match repositories.attempts.find_attempt attempt_id with
    | Error error -> Error error
    | Ok None -> Error (missing Ports.Persistence.Attempt (Attempt_id.to_string attempt_id))
    | Ok (Some attempt) -> match repositories.jobs.find_job (Attempt.job_id attempt) with
        | Error error -> Error error
        | Ok None -> Error (missing Ports.Persistence.Job (Job_id.to_string (Attempt.job_id attempt)))
        | Ok (Some job) -> match repositories.workers.find_worker (Attempt.worker_id attempt) with
            | Error error -> Error error
            | Ok None -> Error (missing Ports.Persistence.Worker (Worker_id.to_string (Attempt.worker_id attempt)))
            | Ok (Some worker) ->
                if not (Job_id.equal (Job.id job) (Attempt.job_id attempt)
                  && Worker_id.equal (Worker.id worker) (Attempt.worker_id attempt)) then Ok `Mismatch
                else let now = service.clock.now () in
                  match transition_attempt ~now reported attempt with
                  | Error error -> Ok (`Transition error)
                  | Ok (final_attempt, attempt_event) -> match transition_job ~now reported job with
                      | Error error -> Ok (`Transition error)
                      | Ok (final_job, job_events) ->
                          match Worker.release ~requirements:(Job.requirements job) worker with
                          | Error error -> Ok (`Capacity error)
                          | Ok released_worker ->
                              match repositories.attempts.update_attempt final_attempt with
                              | Error error -> Error error
                              | Ok () -> match repositories.jobs.update_job final_job with
                                  | Error error -> Error error
                                  | Ok () -> match repositories.workers.update_worker released_worker with
                                      | Error error -> Error error
                                      | Ok () -> match append_events repositories.events (attempt_event :: job_events) with
                                          | Error error -> Error error
                                          | Ok () -> Ok (`Completed { job = final_job;
                                              attempt = final_attempt; worker = released_worker })) in
  match result with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok `Mismatch) -> Error Entity_mismatch
  | Ok (Ok (`Transition error)) -> Error (Transition_rejected error)
  | Ok (Ok (`Capacity error)) -> Error (Capacity_rejected error)
  | Ok (Ok (`Completed completed)) -> Ok completed

let report_success service id ~exit_code = report service id (Success exit_code)
let report_failure service id ~failure = report service id (Failure failure)
let report_timeout service id = report service id Timeout
let report_lost service id ~reason = report service id (Lost reason)
let report_cancelled service id = report service id Cancelled
